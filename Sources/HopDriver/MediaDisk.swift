import Foundation
import CryptoKit

struct MediaDiskReference: Hashable {
    let name: String
    let peer: String
    let conversation: String
}

struct MediaDiskBlob {
    let bytes: Data
    let peer: String
    let conversation: String
}

struct MediaDiskSnapshot {
    let references: [MediaDiskReference]
    let valid: Bool

    init(references: [MediaDiskReference], valid: Bool = true) {
        self.references = references
        self.valid = valid
    }
}

enum MediaDiskResult: Equatable {
    case committed
    case quota
    case ioError
}

/// Serializes directory reconciliation, quota admission, blob writes, durable commit, and rollback.
final class MediaDisk {
    private let directory: URL
    private let transactionDirectory: URL
    private let quarantineDirectory: URL
    private let limits: RetentionLimits
    private let writeOptions: Data.WritingOptions
    private let encode: (Data) -> Data?
    private let decode: (Data) -> Data?
    private let didCreate: (URL) -> Void
    private let lock = NSRecursiveLock()
    private let manager = FileManager.default

    init(directory: URL, limits: RetentionLimits,
         writeOptions: Data.WritingOptions = [],
         encode: @escaping (Data) -> Data? = { $0 },
         decode: @escaping (Data) -> Data? = { $0 },
         didCreate: @escaping (URL) -> Void = { _ in }) {
        self.directory = directory
        self.transactionDirectory = directory.deletingLastPathComponent()
            .appendingPathComponent(".\(directory.lastPathComponent).transaction")
        self.quarantineDirectory = directory.deletingLastPathComponent()
            .appendingPathComponent("\(directory.lastPathComponent).quarantine")
        self.limits = limits
        self.writeOptions = writeOptions
        self.encode = encode
        self.decode = decode
        self.didCreate = didCreate
    }

    func name(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func commit(durableSnapshot: () -> MediaDiskSnapshot,
                blobs: [MediaDiskBlob],
                resultingReferences: [MediaDiskReference],
                durableCommit: () -> Bool) -> MediaDiskResult {
        commit(durableSnapshot: durableSnapshot, blobs: blobs,
               resultingReferences: { resultingReferences }, durableCommit: durableCommit)
    }

    func commit(durableSnapshot: () -> MediaDiskSnapshot,
                blobs: [MediaDiskBlob],
                resultingReferences: () -> [MediaDiskReference],
                durableCommit: () -> Bool) -> MediaDiskResult {
        lock.lock(); defer { lock.unlock() }
        guard blobs.allSatisfy({ $0.bytes.count <= limits.attachmentBytes }) else { return .quota }
        let before = durableSnapshot()
        guard before.valid else { return .ioError }
        let beforeNames = Set(before.references.map(\.name))
        guard ensureDirectory(), recoverTransaction(referenced: beforeNames),
              let files = scanAndReconcile(referenced: beforeNames) else { return .ioError }

        let projectedReferences = resultingReferences()
        let resultingNames = Set(projectedReferences.map(\.name))
        var prepared: [String: Data] = [:]
        for blob in blobs {
            let blobName = name(blob.bytes)
            if resultingNames.contains(blobName), prepared[blobName] == nil, files[blobName] == nil {
                guard let stored = encode(blob.bytes) else { return .ioError }
                prepared[blobName] = stored
            }
        }
        var projectedSizes = files.filter { resultingNames.contains($0.key) }
        for (fileName, bytes) in prepared { projectedSizes[fileName] = bytes.count }
        guard withinQuota(references: projectedReferences, sizes: projectedSizes) else { return .quota }

        var staged: [String] = []
        var created: [String] = []
        do {
            try manager.createDirectory(at: transactionDirectory, withIntermediateDirectories: true)
            for fileName in files.keys.sorted() where !resultingNames.contains(fileName) {
                try atomicMove(directory.appendingPathComponent(fileName),
                               transactionDirectory.appendingPathComponent(fileName))
                staged.append(fileName)
            }
            for (fileName, bytes) in prepared {
                let destination = directory.appendingPathComponent(fileName)
                try writeAtomic(bytes, to: destination)
                created.append(fileName)
            }
        } catch {
            _ = finishTransaction(target: beforeNames, staged: staged, created: created)
            return .ioError
        }

        let committed = durableCommit()
        let target: Set<String>
        if committed {
            target = resultingNames
        } else {
            let after = durableSnapshot()
            target = after.valid ? Set(after.references.map(\.name)) : beforeNames
        }
        let cleaned = finishTransaction(target: target, staged: staged, created: created)
        return committed && cleaned ? .committed : .ioError
    }

    func reconcile(_ snapshot: MediaDiskSnapshot) -> MediaDiskResult {
        guard snapshot.valid else { return .ioError }
        return commit(durableSnapshot: { snapshot }, blobs: [],
                      resultingReferences: snapshot.references) { true }
    }

    func read(_ name: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard isOwnedName(name), ensureDirectory() else { return nil }
        let url = directory.appendingPathComponent(name)
        guard let values = values(url), values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= limits.attachmentBytes + 256,
              url.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL,
              let stored = try? Data(contentsOf: url, options: .mappedIfSafe),
              let plaintext = decode(stored), plaintext.count <= limits.attachmentBytes,
              self.name(plaintext) == name else {
            if manager.fileExists(atPath: url.path) { _ = quarantine(url) }
            return nil
        }
        return plaintext
    }

    func usageBytesForTest() -> Int {
        lock.lock(); defer { lock.unlock() }
        guard ensureDirectory(), let enumerator = topLevelEnumerator(directory) else { return Int.max }
        var total = 0
        for case let url as URL in enumerator {
            guard let size = values(url)?.fileSize else { continue }
            let (next, overflow) = total.addingReportingOverflow(size)
            if overflow { return Int.max }
            total = next
        }
        return total
    }

    private func withinQuota(references: [MediaDiskReference], sizes: [String: Int]) -> Bool {
        var global = 0
        for size in sizes.values {
            let (next, overflow) = global.addingReportingOverflow(size)
            if overflow { return false }
            global = next
        }
        guard global <= limits.globalMediaBytes else { return false }
        for peer in Dictionary(grouping: references, by: \.peer).values {
            let bytes = Set(peer.map(\.name)).reduce(0) { $0 + (sizes[$1] ?? 0) }
            if bytes > limits.peerMediaBytes { return false }
        }
        for conversation in Dictionary(grouping: references, by: \.conversation).values {
            let bytes = Set(conversation.map(\.name)).reduce(0) { $0 + (sizes[$1] ?? 0) }
            if bytes > limits.conversationMediaBytes { return false }
        }
        return true
    }

    private func scanAndReconcile(referenced: Set<String>) -> [String: Int]? {
        guard let enumerator = topLevelEnumerator(directory) else { return nil }
        var files: [String: Int] = [:]
        var entries = 0
        var inspectedBytes = 0
        for case let url as URL in enumerator {
            entries += 1
            guard entries <= limits.mediaDirectoryFiles else { return nil }
            let fileName = url.lastPathComponent
            if let size = values(url)?.fileSize {
                let (next, overflow) = inspectedBytes.addingReportingOverflow(size)
                guard !overflow, next <= limits.mediaDirectoryScanBytes else { return nil }
                inspectedBytes = next
            }
            guard isOwnedName(fileName), let resource = values(url), resource.isRegularFile == true,
                  resource.isSymbolicLink != true,
                  (resource.fileSize ?? Int.max) <= limits.attachmentBytes + 256 else {
                guard quarantine(url) else { return nil }
                continue
            }
            if referenced.contains(fileName) {
                files[fileName] = resource.fileSize ?? 0
            } else {
                do { try manager.removeItem(at: url) } catch { return nil }
            }
        }
        return files
    }

    private func recoverTransaction(referenced: Set<String>) -> Bool {
        guard manager.fileExists(atPath: transactionDirectory.path) else { return true }
        guard let directoryValues = values(transactionDirectory), directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true,
              let enumerator = topLevelEnumerator(transactionDirectory) else {
            return quarantine(transactionDirectory)
        }
        var entries = 0
        var inspectedBytes = 0
        do {
            for case let staged as URL in enumerator {
                entries += 1
                guard entries <= limits.mediaDirectoryFiles, isOwnedName(staged.lastPathComponent),
                      let resource = values(staged), resource.isRegularFile == true,
                      resource.isSymbolicLink != true else { throw MediaDiskError.invalidEntry }
                let (next, overflow) = inspectedBytes.addingReportingOverflow(resource.fileSize ?? 0)
                guard !overflow, next <= limits.mediaDirectoryScanBytes else {
                    throw MediaDiskError.invalidEntry
                }
                inspectedBytes = next
                let target = directory.appendingPathComponent(staged.lastPathComponent)
                if referenced.contains(staged.lastPathComponent), !manager.fileExists(atPath: target.path) {
                    try atomicMove(staged, target)
                } else {
                    try manager.removeItem(at: staged)
                }
            }
            try manager.removeItem(at: transactionDirectory)
            return true
        } catch {
            _ = quarantine(transactionDirectory)
            return false
        }
    }

    private func finishTransaction(target: Set<String>, staged: [String], created: [String]) -> Bool {
        var success = true
        for fileName in created where !target.contains(fileName) {
            do { try manager.removeItem(at: directory.appendingPathComponent(fileName)) }
            catch { success = false }
        }
        for fileName in staged {
            let backup = transactionDirectory.appendingPathComponent(fileName)
            guard manager.fileExists(atPath: backup.path) else { continue }
            let destination = directory.appendingPathComponent(fileName)
            do {
                if target.contains(fileName), !manager.fileExists(atPath: destination.path) {
                    try atomicMove(backup, destination)
                } else {
                    try manager.removeItem(at: backup)
                }
            } catch { success = false }
        }
        if manager.fileExists(atPath: transactionDirectory.path) {
            do { try manager.removeItem(at: transactionDirectory) } catch { success = false }
        }
        return success
    }

    private func ensureDirectory() -> Bool {
        do {
            try manager.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: directory.path) {
                let resource = values(directory)
                if resource?.isDirectory != true || resource?.isSymbolicLink == true {
                    guard quarantine(directory) else { return false }
                }
            }
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            didCreate(directory)
            return true
        } catch { return false }
    }

    private func writeAtomic(_ data: Data, to destination: URL) throws {
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: temporary) }
        var options = writeOptions
        options.remove(.atomic)
        try data.write(to: temporary, options: options)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        try atomicMove(temporary, destination)
        didCreate(destination)
    }

    private func atomicMove(_ source: URL, _ destination: URL) throws {
        try manager.moveItem(at: source, to: destination)
    }

    private func quarantine(_ url: URL) -> Bool {
        do {
            try manager.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
            let target = quarantineDirectory.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try manager.moveItem(at: url, to: target)
            return true
        } catch { return false }
    }

    private func topLevelEnumerator(_ url: URL) -> FileManager.DirectoryEnumerator? {
        manager.enumerator(at: url,
                           includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey,
                                                        .isSymbolicLinkKey, .fileSizeKey],
                           options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants])
    }

    private func values(_ url: URL) -> URLResourceValues? {
        try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey,
                                         .isSymbolicLinkKey, .fileSizeKey])
    }

    private func isOwnedName(_ name: String) -> Bool {
        name.count == 64 && name.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private enum MediaDiskError: Error { case invalidEntry }
}
