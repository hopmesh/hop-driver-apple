import Foundation
import CryptoKit

public enum HopStorage {
    private static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hop", isDirectory: true)
    }

    /// Return an app-support URL under a directory explicitly excluded from device backups. Existing
    /// Documents files are copied into place and verified before the old copy is removed.
    public static func applicationSupportURL(fileName: String) throws -> URL {
        guard !fileName.isEmpty, fileName == URL(fileURLWithPath: fileName).lastPathComponent else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try excludeFromBackup(root)
        let destination = root.appendingPathComponent(fileName)
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if fileName == "media" {
            let legacy = documents.appendingPathComponent(fileName)
            if manager.fileExists(atPath: legacy.path) {
                if !manager.fileExists(atPath: destination.path) {
                    try manager.moveItem(at: legacy, to: destination)
                    try excludeFromBackup(destination)
                } else {
                    let quarantine = root.appendingPathComponent("media.legacy-quarantine-\(UUID().uuidString)")
                    try manager.moveItem(at: legacy, to: quarantine)
                }
            }
            return destination
        }
        let names = fileName == "hop.db" ? [fileName, "hop.db-wal", "hop.db-shm"] : [fileName]
        var committed: [(legacy: URL, current: URL)] = []
        for name in names {
            let legacy = documents.appendingPathComponent(name)
            let current = root.appendingPathComponent(name)
            guard manager.fileExists(atPath: legacy.path) else { continue }
            if !manager.fileExists(atPath: current.path) {
                let temporary = root.appendingPathComponent(".\(name).migration-\(UUID().uuidString)")
                try manager.copyItem(at: legacy, to: temporary)
                try excludeFromBackup(temporary)
                try manager.moveItem(at: temporary, to: current)
            }
            committed.append((legacy, current))
        }
        // Every old file remains until all copies above are committed.
        for pair in committed where manager.fileExists(atPath: pair.current.path) {
            try manager.removeItem(at: pair.legacy)
        }
        return destination
    }

    public static func excludeFromBackup(_ url: URL) throws {
        var value = URLResourceValues()
        value.isExcludedFromBackup = true
        var mutable = url
        try mutable.setResourceValues(value)
    }
}

/// The on-disk UI-history mirror layer, extracted out of the HopBearer god-object so persistence is one
/// cohesive concern. It owns the mirror file URLs, the Codable on-disk DTOs, the encode/decode + write
/// policy, and the TEST/AUTOMATION plaintext dump gate: everything that is pure file I/O. HopBearer keeps
/// only the @Published state + the debounce/throttle orchestration (which is coupled to the observable
/// surface) and delegates every read/write here. Behavior is unchanged: the same file paths, the same
/// protection class, the same encode/decode, moved verbatim.
///
/// The mirror files live in the process-global Documents dir (as in production), and the node's SQLCipher
/// `hop.db` remains the source of truth; these files only back the chat list the UI reads on relaunch.
enum MirrorStore {
    private static let writer = CoalescingWriter()
    private static let mediaDisk = MediaDisk(
        directory: mediaDirectoryURL,
        limits: RetentionPolicy.defaults,
        writeOptions: uiMirrorProtection,
        didCreate: { try? HopStorage.excludeFromBackup($0) }
    )
    private static var mediaReady = true

    static func flush() { writer.flush() }

    // MARK: - Write policy

    /// apple-r2-03: the write options for the plaintext UI-history mirrors (messages/channels/contacts).
    /// These are appended to on an INBOUND receive, which can happen while the device is LOCKED in the
    /// background (background BLE/relay wake). `.completeFileProtection` DENIES writes while locked, so
    /// local history could not be durably accepted until the next unlock. The core inbox now retains that
    /// item until this mirror succeeds. `.completeFileProtectionUntilFirstUserAuthentication` (the
    /// `Data.WritingOptions` spelling
    /// of NSFileProtectionCompleteUntilFirstUserAuthentication) keeps the bytes encrypted at rest yet lets
    /// the write SUCCEED any time after the first post-boot unlock, so a locked background receive
    /// persists. The node store (hop.db) remains the source of truth; this only closes the mirror gap.
    static let uiMirrorProtection: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    static var messagesFileURL: URL { try! HopStorage.applicationSupportURL(fileName: "messages.json") }
    static var channelsFileURL: URL { try! HopStorage.applicationSupportURL(fileName: "channels.json") }
    static var contactsFileURL: URL { try! HopStorage.applicationSupportURL(fileName: "contacts.json") }
    static var messagesJournalURL: URL { try! HopStorage.applicationSupportURL(fileName: "messages.delta") }
    static var channelsJournalURL: URL { try! HopStorage.applicationSupportURL(fileName: "channels.delta") }
    private static let messagesJournal = DeltaJournal(
        url: messagesJournalURL,
        maximumBytes: RetentionPolicy.defaults.journalBytes,
        maximumRecords: RetentionPolicy.defaults.journalRecords,
        maximumRecordBytes: RetentionPolicy.defaults.journalRecordBytes,
        protection: uiMirrorProtection
    )
    private static let channelsJournal = DeltaJournal(
        url: channelsJournalURL,
        maximumBytes: RetentionPolicy.defaults.journalBytes,
        maximumRecords: RetentionPolicy.defaults.journalRecords,
        maximumRecordBytes: RetentionPolicy.defaults.journalRecordBytes,
        protection: uiMirrorProtection
    )
    static var mediaDirectoryURL: URL {
        let url = try! HopStorage.applicationSupportURL(fileName: "media")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? HopStorage.excludeFromBackup(url)
        return url
    }
    static var automationFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("automation.json")
    }

    // MARK: - Message history (survives app restart)

    /// On-disk form of a chat message. Omits `trace` (FFI type, incoming-path debug only) but KEEPS
    /// `bundleId`: the node persists undelivered own-bundles and keeps spraying them after a restart
    /// (node.rs rehydrate), and for an established session the bundle id is stable, so we re-query
    /// `messageStatus(bundleId)` on relaunch and the message flips to Delivered when its ACK lands.
    struct StoredMessage: Codable {
        var peer: String; var text: String; var incoming: Bool
        var peerAddr: Data?; var contentType: String
        var imageRef: String?; var imageRefs: [String]?
        var imageData: Data?; var images: [Data]?
        var hops: UInt8; var latencyMs: UInt64?
        var sentAt: Date; var deliveredAt: Date?
        var relayed: UInt32; var delivered: Bool; var deliveryHops: UInt8; var failed: Bool
        var deliveryMs: UInt32?
        var bundleId: Data?
        var inboxId: Data?
    }

    /// Encode the chat history and atomically write the mirror. The result gates durable core acceptance.
    @discardableResult
    static func saveMessages(_ messages: [HopBearer.Message]) -> Bool {
        writer.runNow(key: "messages") {
            do {
                let stored = messages.map(storedMessage)
                guard validStoredMessages(stored) else { return false }
                let data = try JSONEncoder().encode(stored)
                guard data.count <= RetentionPolicy.defaults.messageMirrorBytes else { return false }
                let result = mediaDisk.commit(
                    durableSnapshot: durableMediaSnapshot,
                    blobs: mediaBlobs(messages),
                    resultingReferences: mediaReferences(messages)
                ) {
                    do { try writeDurable(data, to: messagesFileURL) } catch { return false }
                    return messagesJournal.reset()
                }
                if result == .committed { mediaReady = true }
                return result == .committed
            } catch {
                return false
            }
        }
    }

    /// Read the chat-history mirror back into `Message`s (nil if there is no file / it is unreadable).
    /// An outgoing message still in flight when we quit KEEPS sending: the node persists the bundle and
    /// re-sprays it after restart until its delivery ACK (node.rs rehydrate). So we restore it in-flight
    /// with its bundleId - refresh() re-queries messageStatus and it flips to Delivered when the ACK lands -
    /// rather than falsely marking it "Not sent".
    struct LoadedMessages {
        let messages: [HopBearer.Message]
        let durableIds: Set<Data>
    }

    static func loadMessages() -> LoadedMessages? {
        writer.runNow(key: "messages") {
            let snapshot: [StoredMessage]
            var quarantinedSnapshot = false
            if FileManager.default.fileExists(atPath: messagesFileURL.path) {
                if let data = readBounded(messagesFileURL,
                                          maximum: RetentionPolicy.defaults.messageMirrorBytes),
                   let decoded = try? JSONDecoder().decode([StoredMessage].self, from: data),
                   validStoredMessages(decoded) {
                    snapshot = decoded
                } else {
                    quarantine(messagesFileURL)
                    snapshot = []
                    quarantinedSnapshot = true
                }
            } else {
                snapshot = []
            }
            let durable = durableMediaSnapshot()
            mediaReady = durable.valid && mediaDisk.reconcile(durable) == .committed
            guard mediaReady else { return nil }
            let loaded = loadMessages(snapshot: snapshot)
            if !quarantinedSnapshot && loaded.messages.isEmpty && snapshot.isEmpty &&
                !FileManager.default.fileExists(atPath: messagesJournalURL.path) {
                mediaReady = mediaDisk.reconcile(MediaDiskSnapshot(references: [])) == .committed
                return nil
            }
            return loaded
        }
    }

    static func appendMessageDelta(id: Data, message: HopBearer.Message?,
                                   resultingMessages: [HopBearer.Message]? = nil) -> Bool {
        writer.runNow(key: "messages") {
            do {
                guard mediaReady else { return false }
                let stored = message.map(storedMessage)
                let payload = try stored.map { try JSONEncoder().encode($0) }
                let before = durableMediaSnapshot()
                guard before.valid else { return false }
                let resultingReferences = resultingMessages.map { mediaReferences($0) } ??
                    (before.references + (stored.map { mediaReferences($0) } ?? []))
                let removed = Set(before.references.map(\.name))
                    .subtracting(resultingReferences.map(\.name))
                let compact = resultingMessages != nil && !removed.isEmpty
                let result = mediaDisk.commit(
                    durableSnapshot: durableMediaSnapshot,
                    blobs: resultingMessages.map { mediaBlobs($0) } ?? message.map { mediaBlobs($0) } ?? [],
                    resultingReferences: resultingReferences
                ) {
                    guard messagesJournal.append(id: id, payload: payload) else { return false }
                    guard compact, let resultingMessages else { return true }
                    do {
                        let encoded = try JSONEncoder().encode(resultingMessages.map(storedMessage))
                        guard encoded.count <= RetentionPolicy.defaults.messageMirrorBytes else { return false }
                        try writeDurable(encoded, to: messagesFileURL)
                        return messagesJournal.reset()
                    } catch { return false }
                }
                return result == .committed
            } catch {
                return false
            }
        }
    }

    private static func loadMessages(snapshot: [StoredMessage]) -> LoadedMessages {
        var byId: [Data: HopBearer.Message] = [:]
        var withoutId: [HopBearer.Message] = []
        for value in snapshot {
            let message = message(from: value)
            if let id = message.inboxId { byId[id] = message } else { withoutId.append(message) }
        }
        var durableIds = Set(byId.keys)
        for record in messagesJournal.replay().records {
            durableIds.insert(record.id)
            guard let payload = record.payload,
                  let stored = try? JSONDecoder().decode(StoredMessage.self, from: payload),
                  validStoredMessages([stored]) else { continue }
            byId[record.id] = message(from: stored)
        }
        return LoadedMessages(messages: withoutId + byId.values, durableIds: durableIds)
    }

    private static func storedMessage(_ message: HopBearer.Message) -> StoredMessage {
        let single = message.imageData.map(mediaDisk.name)
        let multiple = message.images.map(mediaDisk.name)
        return StoredMessage(
            peer: message.peer, text: message.text, incoming: message.incoming,
            peerAddr: message.peerAddr, contentType: message.contentType,
            imageRef: single, imageRefs: multiple.isEmpty ? nil : multiple,
            imageData: nil, images: nil,
            hops: message.hops, latencyMs: message.latencyMs,
            sentAt: message.sentAt, deliveredAt: message.deliveredAt,
            relayed: message.relayed, delivered: message.delivered,
            deliveryHops: message.deliveryHops, failed: message.failed,
            deliveryMs: message.deliveryMs,
            bundleId: message.bundleId, inboxId: message.inboxId
        )
    }

    private static func message(from value: StoredMessage) -> HopBearer.Message {
        let single = value.imageRef.flatMap(getMedia) ?? value.imageData.flatMap(cappedLegacyMedia)
        let multiple = value.imageRefs?.compactMap(getMedia) ?? (value.images ?? []).compactMap(cappedLegacyMedia)
        var message = HopBearer.Message(
            peer: value.peer, text: value.text, incoming: value.incoming, peerAddr: value.peerAddr,
            contentType: value.contentType, imageData: single, images: multiple,
            bundleId: value.bundleId, inboxId: value.inboxId,
            hops: value.hops, latencyMs: value.latencyMs, sentAt: value.sentAt,
            deliveredAt: value.deliveredAt, relayed: value.relayed, delivered: value.delivered,
            deliveryHops: value.deliveryHops, failed: value.failed
        )
        message.deliveryMs = value.deliveryMs ?? 0
        return message
    }

    private static func validStoredMessages(_ messages: [StoredMessage]) -> Bool {
        guard messages.count <= RetentionPolicy.defaults.globalMessages +
                RetentionPolicy.defaults.pendingGlobalMessages else { return false }
        var aggregate = 0
        for stored in messages {
            let references = [stored.imageRef].compactMap { $0 } + (stored.imageRefs ?? [])
            guard references.count <= 32, references.allSatisfy(isOwnedMediaName),
                  (stored.images ?? []).count <= 32,
                  (stored.imageData?.count ?? 0) <= RetentionPolicy.defaults.attachmentBytes,
                  (stored.images ?? []).allSatisfy({ $0.count <= RetentionPolicy.defaults.attachmentBytes })
            else { return false }
            aggregate += Data(stored.peer.utf8).count + Data(stored.text.utf8).count +
                Data(stored.contentType.utf8).count + (stored.peerAddr?.count ?? 0) +
                (stored.imageData?.count ?? 0) + (stored.images ?? []).reduce(0, { $0 + $1.count }) +
                Data(stored.imageRef?.utf8 ?? "".utf8).count +
                (stored.imageRefs ?? []).reduce(0, { $0 + Data($1.utf8).count }) +
                (stored.bundleId?.count ?? 0) + (stored.inboxId?.count ?? 0)
            if aggregate > RetentionPolicy.defaults.messageMirrorBytes { return false }
        }
        return true
    }

    private static func getMedia(_ name: String) -> Data? {
        mediaDisk.read(name)
    }

    private static func cappedLegacyMedia(_ data: Data) -> Data? {
        data.count <= RetentionPolicy.defaults.attachmentBytes ? data : nil
    }

    static func gcMedia(_ messages: [HopBearer.Message]) {
        mediaReady = mediaDisk.reconcile(MediaDiskSnapshot(references: mediaReferences(messages))) == .committed
    }

    private static func isOwnedMediaName(_ name: String) -> Bool {
        name.count == 64 && name.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func mediaBlobs(_ message: HopBearer.Message) -> [MediaDiskBlob] {
        mediaBlobs([message])
    }

    private static func mediaBlobs(_ messages: [HopBearer.Message]) -> [MediaDiskBlob] {
        messages.flatMap { message in
            let peer = RetentionPolicy.peerKey(message)
            let data = (message.imageData.map { [$0] } ?? []) + message.images
            return data.map { MediaDiskBlob(bytes: $0, peer: peer, conversation: peer) }
        }
    }

    private static func mediaReferences(_ message: StoredMessage) -> [MediaDiskReference] {
        let peer = message.peerAddr?.base64EncodedString() ?? message.peer
        return ([message.imageRef].compactMap { $0 } + (message.imageRefs ?? []))
            .map { MediaDiskReference(name: $0, peer: peer, conversation: peer) }
    }

    private static func mediaReferences(_ messages: [HopBearer.Message]) -> [MediaDiskReference] {
        messages.flatMap { message in
            let peer = RetentionPolicy.peerKey(message)
            return ((message.imageData.map { [mediaDisk.name($0)] } ?? []) + message.images.map(mediaDisk.name))
                .map { MediaDiskReference(name: $0, peer: peer, conversation: peer) }
        }
    }

    private static func durableMediaSnapshot() -> MediaDiskSnapshot {
        var snapshot: [StoredMessage] = []
        if FileManager.default.fileExists(atPath: messagesFileURL.path) {
            guard let data = readBounded(messagesFileURL, maximum: RetentionPolicy.defaults.messageMirrorBytes),
                  let decoded = try? JSONDecoder().decode([StoredMessage].self, from: data),
                  validStoredMessages(decoded) else { return MediaDiskSnapshot(references: [], valid: false) }
            snapshot = decoded
        }
        var withoutId: [StoredMessage] = []
        var byId: [Data: StoredMessage] = [:]
        for message in snapshot {
            if let id = message.inboxId { byId[id] = message } else { withoutId.append(message) }
        }
        let replay = messagesJournal.replay()
        guard !replay.quarantined else { return MediaDiskSnapshot(references: [], valid: false) }
        for record in replay.records {
            guard let payload = record.payload else { byId[record.id] = nil; continue }
            guard let stored = try? JSONDecoder().decode(StoredMessage.self, from: payload),
                  validStoredMessages([stored]) else { return MediaDiskSnapshot(references: [], valid: false) }
            byId[record.id] = stored
        }
        return MediaDiskSnapshot(references: (withoutId + byId.values).flatMap(mediaReferences))
    }

    // MARK: - Channel (hps) threads

    private struct StoredChannelDelta: Codable {
        let topic: String
        let row: HopBearer.HpsMsgRow?
    }

    struct LoadedChannels {
        let threads: [String: [HopBearer.HpsMsgRow]]
        let durableIds: Set<Data>
    }

    @discardableResult
    static func saveChannels(_ threads: [String: [HopBearer.HpsMsgRow]]) -> Bool {
        writer.runNow(key: "channels") {
            guard validChannels(threads) else { return false }
            guard let data = try? JSONEncoder().encode(threads) else { return false }
            guard data.count <= RetentionPolicy.defaults.channelMirrorBytes else { return false }
            do {
                try writeDurable(data, to: channelsFileURL)
                return channelsJournal.reset()
            } catch { return false }
        }
    }

    static func loadChannels() -> LoadedChannels? {
        writer.runNow(key: "channels") {
            var stored: [String: [HopBearer.HpsMsgRow]] = [:]
            if FileManager.default.fileExists(atPath: channelsFileURL.path) {
                guard let data = readBounded(channelsFileURL,
                                             maximum: RetentionPolicy.defaults.channelMirrorBytes),
                      let decoded = try? JSONDecoder().decode([String: [HopBearer.HpsMsgRow]].self,
                                                              from: data),
                      validChannels(decoded) else {
                    quarantine(channelsFileURL)
                    stored = [:]
                    return loadChannels(snapshot: stored)
                }
                stored = decoded
            }
            let loaded = loadChannels(snapshot: stored)
            if loaded.threads.isEmpty && stored.isEmpty &&
                !FileManager.default.fileExists(atPath: channelsJournalURL.path) { return nil }
            return loaded
        }
    }

    static func appendChannelDelta(id: Data, topic: String, row: HopBearer.HpsMsgRow?) -> Bool {
        writer.runNow(key: "channels") {
            guard let payload = try? JSONEncoder().encode(StoredChannelDelta(topic: topic, row: row)) else {
                return false
            }
            return channelsJournal.append(id: id, payload: payload)
        }
    }

    private static func loadChannels(snapshot: [String: [HopBearer.HpsMsgRow]]) -> LoadedChannels {
        var threads = snapshot
        var durableIds = Set(snapshot.values.flatMap { $0 }.compactMap(\.inboxId))
        for record in channelsJournal.replay().records {
            durableIds.insert(record.id)
            guard let payload = record.payload,
                  let delta = try? JSONDecoder().decode(StoredChannelDelta.self, from: payload),
                  let row = delta.row else { continue }
            let duplicate = threads.values.flatMap { $0 }.contains { $0.inboxId == record.id }
            if !duplicate { threads[delta.topic, default: []].append(row) }
        }
        return LoadedChannels(threads: threads, durableIds: durableIds)
    }

    private static func validChannels(_ threads: [String: [HopBearer.HpsMsgRow]]) -> Bool {
        guard threads.count <= RetentionPolicy.defaults.conversations else { return false }
        var elements = 0
        var aggregate = 0
        for (topic, rows) in threads {
            elements += rows.count
            aggregate += Data(topic.utf8).count
            for row in rows {
                aggregate += Data(row.path.utf8).count + row.sender.count + Data(row.text.utf8).count +
                    (row.inboxId?.count ?? 0)
            }
            if elements > RetentionPolicy.defaults.globalMessages ||
                aggregate > RetentionPolicy.defaults.globalMessageBytes { return false }
        }
        return true
    }

    // MARK: - Address book (past conversations survive restart + going out of range)

    private struct StoredContact: Codable { var address: Data; var name: String; var platform: String; var app: String }

    /// Snapshot + write the address book off the main thread (a utility queue), as the throttled `refresh`
    /// caller expects. The throttle decision itself stays on HopBearer (it owns `lastContactSaveAt`).
    static func saveContacts(_ peers: [HopBearer.Peer], completion: ((Bool) -> Void)? = nil) {
        let snapshot = peers.map {
            StoredContact(address: $0.address, name: $0.name, platform: $0.platform, app: $0.app)
        }
        writer.submit(key: "contacts") {
            guard let data = try? JSONEncoder().encode(snapshot) else { completion?(false); return }
            guard data.count <= RetentionPolicy.defaults.contactMirrorBytes else { completion?(false); return }
            do {
                try writeDurable(data, to: contactsFileURL)
                completion?(true)
            } catch { completion?(false) }
        }
    }

    /// Read the address book back as `Peer`s (hops=0, not-active, since they are historical until re-seen).
    /// The caller merges these into its live contact map (keeping any already-present entry).
    static func loadContacts() -> [HopBearer.Peer]? {
        writer.flush()
        guard FileManager.default.fileExists(atPath: contactsFileURL.path) else { return nil }
        guard let data = readBounded(contactsFileURL, maximum: RetentionPolicy.defaults.contactMirrorBytes),
              let stored = try? JSONDecoder().decode([StoredContact].self, from: data),
              stored.count <= RetentionPolicy.defaults.contacts else {
            quarantine(contactsFileURL)
            return nil
        }
        var aggregate = 0
        for contact in stored {
            aggregate += contact.address.count + Data(contact.name.utf8).count +
                Data(contact.platform.utf8).count + Data(contact.app.utf8).count
            if aggregate > RetentionPolicy.defaults.contactMirrorBytes {
                quarantine(contactsFileURL)
                return nil
            }
        }
        return stored.map {
            HopBearer.Peer(address: $0.address, name: $0.name, hops: 0,
                           active: false, platform: $0.platform, app: $0.app)
        }
    }

    static func quarantine(_ url: URL) {
        let target = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).quarantine")
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.moveItem(at: url, to: target)
    }

    private static func readBounded(_ url: URL, maximum: Int) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= maximum else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    private static func writeDurable(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: uiMirrorProtection)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
        try HopStorage.excludeFromBackup(url)
    }

    // MARK: - Automation control surface (TEST/AUTOMATION hook - headless harness only)

    /// A PLAINTEXT mirror of our self-address + recent rx/tx, written to `Documents/automation.json`.
    /// The encrypted hop.db has no plaintext mirror, so this is the ONLY way an external test harness
    /// (which pulls the file via `xcrun devicectl device copy from`) can discover this device's
    /// address (`self`) for targeting and verify iOS-side message receipt. Not a normal user path.
    private struct AutomationDump: Codable {
        struct Rx: Codable { let from: String; let text: String; let at: Int64 }
        struct Tx: Codable { let to: String; let text: String; let delivered: Bool; let deliveryMs: UInt32; let at: Int64 }
        let `self`: String
        let name: String
        let rx: [Rx]
        let tx: [Tx]
        let auto: String   // TEST/AUTOMATION breadcrumb: the raw HOP_AUTO launch env this process saw ("" if none)
    }

    /// apple-04/apple-r2-03: the plaintext-mirror GATE, pure + testable. A plaintext automation.json (self
    /// address + recent messages) defeats SQLCipher-at-rest if it ships, so it is written ONLY when this is
    /// a DEBUG build OR the process was launched under the harness (a HOP_AUTO env real users never set).
    /// The critical invariant, which the test pins: a RELEASE build with no HOP_AUTO returns false, so the
    /// mirror is NEVER written in a shipped app.
    static func automationMirrorEnabled(isDebug: Bool, hopAutoEnv: String?) -> Bool {
        return isDebug || (hopAutoEnv != nil)
    }
    static var automationMirrorEnabled: Bool {
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        return automationMirrorEnabled(isDebug: isDebug,
                                       hopAutoEnv: ProcessInfo.processInfo.environment["HOP_AUTO"])
    }

    /// Rewrite the automation mirror (last ~100 rx + tx). Called on every message change (from
    /// `saveMessages`) and once at startup so `self` is discoverable even before any traffic.
    static func writeAutomationDump(messages: [HopBearer.Message], myAddress: String,
                                    myName: String, autoEnvSeen: String) {
        guard automationMirrorEnabled else { return }   // apple-04: never a plaintext mirror in shipped release
        let rx = messages.filter { $0.incoming }.suffix(100).map {
            AutomationDump.Rx(from: $0.peerAddr.map(HopBearer.base58) ?? $0.peer,
                              text: $0.text, at: Int64($0.sentAt.timeIntervalSince1970 * 1000))
        }
        let tx = messages.filter { !$0.incoming }.suffix(100).map {
            AutomationDump.Tx(to: $0.peerAddr.map(HopBearer.base58) ?? $0.peer,
                              text: $0.text, delivered: $0.delivered, deliveryMs: $0.deliveryMs,
                              at: Int64($0.sentAt.timeIntervalSince1970 * 1000))
        }
        let dump = AutomationDump(self: myAddress, name: myName, rx: Array(rx), tx: Array(tx),
                                  auto: autoEnvSeen)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(dump) else { return }
        // completeFileProtection even for the debug/harness mirror (defense in depth; harness reads it
        // over devicectl while the device is unlocked).
        writer.submit(key: "automation") {
            try? data.write(to: automationFileURL, options: [.atomic, .completeFileProtection])
            try? HopStorage.excludeFromBackup(automationFileURL)
        }
    }
}
