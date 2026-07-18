import Foundation
import CryptoKit

struct DeltaRecord {
    let id: Data
    let payload: Data?
}

struct DeltaReplay {
    let records: [DeltaRecord]
    let quarantined: Bool
}

/// Length-framed, checksummed append-only records. Every successful append is synchronized to disk.
final class DeltaJournal {
    private static let magic = Data("HOPDELTA1\n".utf8)
    private static let version: UInt8 = 1
    private let url: URL
    private let maximumBytes: Int
    private let maximumRecords: Int
    private let maximumRecordBytes: Int
    private let protection: Data.WritingOptions
    private var knownRecords: Int?
    private let lock = NSLock()

    init(url: URL, maximumBytes: Int, maximumRecords: Int, maximumRecordBytes: Int,
         protection: Data.WritingOptions = []) {
        self.url = url
        self.maximumBytes = maximumBytes
        self.maximumRecords = maximumRecords
        self.maximumRecordBytes = maximumRecordBytes
        self.protection = protection
    }

    func append(id: Data, payload: Data?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !id.isEmpty, id.count <= 64, (payload?.count ?? 0) <= maximumRecordBytes else { return false }
        if knownRecords == nil {
            let replay = replayUnlocked()
            knownRecords = replay.records.count
            if replay.quarantined { return false }
        }
        guard knownRecords! < maximumRecords else { return false }
        let record = encode(id: id, payload: payload)
        let frame = uint32(record.count) + record
        let current = fileSize() ?? Self.magic.count
        guard frame.count <= maximumBytes - current else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                try writeAndSync(Self.magic, to: url)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: frame)
            try handle.synchronize()
            try handle.close()
            knownRecords! += 1
            return true
        } catch {
            return false
        }
    }

    func replay() -> DeltaReplay {
        lock.lock(); defer { lock.unlock() }
        let replay = replayUnlocked()
        knownRecords = replay.records.count
        return replay
    }

    func reset() -> Bool {
        lock.lock(); defer { lock.unlock() }
        do {
            try writeAndSync(Self.magic, to: url)
            knownRecords = 0
            return true
        } catch {
            return false
        }
    }

    private func replayUnlocked() -> DeltaReplay {
        guard FileManager.default.fileExists(atPath: url.path) else { return DeltaReplay(records: [], quarantined: false) }
        guard let size = fileSize(), size >= Self.magic.count, size <= maximumBytes else {
            quarantine()
            return DeltaReplay(records: [], quarantined: true)
        }
        var records: [DeltaRecord] = []
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard try readExactly(Self.magic.count, from: handle) == Self.magic else { throw JournalError.corrupt }
            var consumed = Self.magic.count
            while consumed < size {
                guard records.count < maximumRecords,
                      let lengthData = try readExactly(4, from: handle) else { throw JournalError.corrupt }
                consumed += 4
                let length = Int(readUInt32(lengthData))
                guard length > 0, length <= maximumRecordBytes + 128, length <= size - consumed,
                      let bytes = try readExactly(length, from: handle) else { throw JournalError.corrupt }
                consumed += length
                records.append(try decode(bytes))
            }
            return DeltaReplay(records: records, quarantined: false)
        } catch {
            quarantine()
            return DeltaReplay(records: records, quarantined: true)
        }
    }

    private func encode(id: Data, payload: Data?) -> Data {
        var core = Data([Self.version, payload == nil ? 0 : 1])
        core.append(uint16(id.count))
        core.append(uint32(payload?.count ?? 0))
        core.append(id)
        if let payload { core.append(payload) }
        core.append(Data(SHA256.hash(data: core)))
        return core
    }

    private func decode(_ data: Data) throws -> DeltaRecord {
        guard data.count >= 1 + 1 + 2 + 4 + 1 + 32 else { throw JournalError.corrupt }
        let core = data.dropLast(32)
        guard Data(SHA256.hash(data: core)) == data.suffix(32) else { throw JournalError.corrupt }
        let bytes = Data(core)
        guard bytes[0] == Self.version, bytes[1] <= 1 else { throw JournalError.corrupt }
        let idLength = Int(readUInt16(bytes.subdata(in: 2..<4)))
        let payloadLength = Int(readUInt32(bytes.subdata(in: 4..<8)))
        guard (1...64).contains(idLength), payloadLength <= maximumRecordBytes,
              bytes.count == 8 + idLength + payloadLength,
              bytes[1] == 1 || payloadLength == 0 else { throw JournalError.corrupt }
        let id = bytes.subdata(in: 8..<(8 + idLength))
        let payload = bytes[1] == 1 ? bytes.subdata(in: (8 + idLength)..<bytes.count) : nil
        return DeltaRecord(id: id, payload: payload)
    }

    private func writeAndSync(_ data: Data, to destination: URL) throws {
        try data.write(to: destination, options: protection.union(.atomic))
        let handle = try FileHandle(forWritingTo: destination)
        try handle.synchronize()
        try handle.close()
        try? HopStorage.excludeFromBackup(destination)
    }

    private func readExactly(_ count: Int, from handle: FileHandle) throws -> Data? {
        var result = Data()
        while result.count < count {
            guard let chunk = try handle.read(upToCount: count - result.count), !chunk.isEmpty else { return nil }
            result.append(chunk)
        }
        return result
    }

    private func fileSize() -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.intValue
    }

    private func quarantine() {
        let target = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).quarantine")
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.moveItem(at: url, to: target)
        knownRecords = nil
    }

    private func uint16(_ value: Int) -> Data {
        Data([UInt8((value >> 8) & 0xff), UInt8(value & 0xff)])
    }

    private func uint32(_ value: Int) -> Data {
        Data([UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
              UInt8((value >> 8) & 0xff), UInt8(value & 0xff)])
    }

    private func readUInt16(_ data: Data) -> UInt16 {
        (UInt16(data[0]) << 8) | UInt16(data[1])
    }

    private func readUInt32(_ data: Data) -> UInt32 {
        (UInt32(data[0]) << 24) | (UInt32(data[1]) << 16) | (UInt32(data[2]) << 8) | UInt32(data[3])
    }

    private enum JournalError: Error { case corrupt }
}
