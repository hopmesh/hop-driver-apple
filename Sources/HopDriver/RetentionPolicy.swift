import Foundation

struct RetentionLimits {
    var globalMessages = 5_000
    var globalMessageBytes = 64 * 1024 * 1024
    var peerMessages = 1_000
    var peerMessageBytes = 16 * 1024 * 1024
    var conversationMessages = 500
    var conversationMessageBytes = 8 * 1024 * 1024
    var contacts = 1_000
    var attachmentBytes = 8 * 1024 * 1024
    var peerMediaBytes = 32 * 1024 * 1024
    var conversationMediaBytes = 16 * 1024 * 1024
    var globalMediaBytes = 128 * 1024 * 1024
    var mediaDirectoryFiles = 16_384
    var mediaDirectoryScanBytes = 256 * 1024 * 1024
    var pendingGlobalMessages = 512
    var pendingGlobalBytes = 32 * 1024 * 1024
    var pendingPeerMessages = 128
    var pendingPeerBytes = 8 * 1024 * 1024
    var pendingConversationMessages = 64
    var pendingConversationBytes = 4 * 1024 * 1024
    var metadataEntries = 1_000
    var conversations = 1_000
    var messageMirrorBytes = 96 * 1024 * 1024
    var channelMirrorBytes = 64 * 1024 * 1024
    var contactMirrorBytes = 4 * 1024 * 1024
    var journalBytes = 64 * 1024 * 1024
    var journalRecords = 4_096
    var journalRecordBytes = 16 * 1024 * 1024
}

enum PendingAdmission: Equatable {
    case accepted
    case globalCount, globalBytes
    case peerCount, peerBytes
    case conversationCount, conversationBytes
}

final class PendingQuota {
    private struct Entry { let peer: String; let conversation: String; let bytes: Int }
    private let limits: RetentionLimits
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    init(limits: RetentionLimits = RetentionPolicy.defaults) { self.limits = limits }

    func reserve(id: UUID, peer: String, conversation: String, bytes: Int) -> PendingAdmission {
        lock.lock(); defer { lock.unlock() }
        if entries[id] != nil { return .accepted }
        if entries.count >= limits.pendingGlobalMessages { return .globalCount }
        if bytes > limits.pendingGlobalBytes - entries.values.reduce(0, { $0 + $1.bytes }) { return .globalBytes }
        let peerEntries = entries.values.filter { $0.peer == peer }
        if peerEntries.count >= limits.pendingPeerMessages { return .peerCount }
        if bytes > limits.pendingPeerBytes - peerEntries.reduce(0, { $0 + $1.bytes }) { return .peerBytes }
        let conversations = entries.values.filter { $0.conversation == conversation }
        if conversations.count >= limits.pendingConversationMessages { return .conversationCount }
        if bytes > limits.pendingConversationBytes - conversations.reduce(0, { $0 + $1.bytes }) {
            return .conversationBytes
        }
        entries[id] = Entry(peer: peer, conversation: conversation, bytes: bytes)
        return .accepted
    }

    func release(_ id: UUID) { lock.lock(); entries[id] = nil; lock.unlock() }

    func reconcile(_ messages: [HopBearer.Message]) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll(keepingCapacity: true)
        for message in messages where !message.incoming && !message.delivered && !message.failed {
            let peer = RetentionPolicy.peerKey(message)
            entries[message.id] = Entry(peer: peer, conversation: peer,
                                        bytes: RetentionPolicy.messageBytes(message))
        }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
}

final class BoundedLruMap<Key: Hashable, Value> {
    private let maximum: Int
    private let lock = NSLock()
    private var values: [Key: Value] = [:]
    private var order: [Key] = []

    init(maximum: Int) { self.maximum = maximum }

    subscript(key: Key) -> Value? {
        get {
            lock.lock(); defer { lock.unlock() }
            guard let value = values[key] else { return nil }
            touch(key)
            return value
        }
        set {
            lock.lock(); defer { lock.unlock() }
            if let newValue {
                values[key] = newValue
                touch(key)
                while values.count > maximum, let oldest = order.first {
                    order.removeFirst()
                    values[oldest] = nil
                }
            } else {
                values[key] = nil
                order.removeAll { $0 == key }
            }
        }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    var snapshot: [Key: Value] { lock.lock(); defer { lock.unlock() }; return values }
    func removeAll() {
        lock.lock()
        values.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

final class BoundedLruSet<Element: Hashable> {
    private let values: BoundedLruMap<Element, Bool>
    init(maximum: Int) { values = BoundedLruMap(maximum: maximum) }
    func contains(_ value: Element) -> Bool { values[value] != nil }
    @discardableResult func insert(_ value: Element) -> (inserted: Bool, memberAfterInsert: Element) {
        let inserted = values[value] == nil
        values[value] = true
        return (inserted, value)
    }
    @discardableResult func remove(_ value: Element) -> Element? {
        guard values[value] != nil else { return nil }
        values[value] = nil
        return value
    }
    func replace<S: Sequence>(with replacement: S) where S.Element == Element {
        values.removeAll()
        for value in replacement { values[value] = true }
    }
    var count: Int { values.count }
}

enum RetentionPolicy {
    static let defaults = RetentionLimits()

    static func retain(_ messages: [HopBearer.Message], limits: RetentionLimits = defaults) -> [HopBearer.Message] {
        var kept = messages
        while true {
            let globalCountExceeded = kept.count > limits.globalMessages
            let globalBytesExceeded = kept.reduce(0) { $0 + messageBytes($1) } > limits.globalMessageBytes
            let peers = Dictionary(grouping: kept, by: peerKey)
            let peerCountExceeded = Set(peers.filter { $0.value.count > limits.peerMessages }.keys)
            let peerBytesExceeded = Set(peers.filter {
                $0.value.reduce(0) { $0 + messageBytes($1) } > limits.peerMessageBytes
            }.keys)
            let conversations = Dictionary(grouping: kept, by: conversationKey)
            let conversationCountExceeded = Set(conversations.filter {
                $0.value.count > limits.conversationMessages
            }.keys)
            let conversationBytesExceeded = Set(conversations.filter {
                $0.value.reduce(0) { $0 + messageBytes($1) } > limits.conversationMessageBytes
            }.keys)
            if !globalCountExceeded && !globalBytesExceeded && peerCountExceeded.isEmpty &&
                peerBytesExceeded.isEmpty && conversationCountExceeded.isEmpty &&
                conversationBytesExceeded.isEmpty { break }

            let candidate = kept.enumerated().filter { _, message in
                message.incoming || message.delivered || message.failed
            }.filter { _, message in
                globalCountExceeded || globalBytesExceeded || peerCountExceeded.contains(peerKey(message)) ||
                    peerBytesExceeded.contains(peerKey(message)) ||
                    conversationCountExceeded.contains(conversationKey(message)) ||
                    conversationBytesExceeded.contains(conversationKey(message))
            }.min { left, right in
                left.element.sentAt == right.element.sentAt
                    ? left.offset < right.offset
                    : left.element.sentAt < right.element.sentAt
            }
            guard let candidate else { break }
            kept.remove(at: candidate.offset)
        }
        return kept
    }

    static func acceptsMedia(_ messages: [HopBearer.Message], peer: Data?, fallbackPeer: String,
                             attachments: [Data], knownIdentity: Bool,
                             limits: RetentionLimits = defaults) -> Bool {
        guard knownIdentity, attachments.allSatisfy({ $0.count <= limits.attachmentBytes }) else { return false }
        let added = attachments.reduce(0) { $0 + $1.count }
        let key = peer.map { $0.base64EncodedString() } ?? fallbackPeer
        let global = messages.reduce(0) { $0 + mediaBytes($1) }
        let perPeer = messages.filter { peerKey($0) == key }.reduce(0) { $0 + mediaBytes($1) }
        return added <= limits.globalMediaBytes - global && added <= limits.peerMediaBytes - perPeer
    }

    static func messageBytes(_ message: HopBearer.Message) -> Int {
        Data(message.text.utf8).count + Data(message.peer.utf8).count +
            Data(message.contentType.utf8).count + mediaBytes(message) +
            (message.bundleId?.count ?? 0) + (message.inboxId?.count ?? 0)
    }

    static func mediaBytes(_ message: HopBearer.Message) -> Int {
        (message.imageData?.count ?? 0) + message.images.reduce(0) { $0 + $1.count }
    }

    static func canAddContact(currentCount: Int, alreadyKnown: Bool,
                              limits: RetentionLimits = defaults) -> Bool {
        alreadyKnown || currentCount < limits.contacts
    }

    static func peerKey(_ message: HopBearer.Message) -> String {
        message.peerAddr?.base64EncodedString() ?? message.peer
    }

    private static func conversationKey(_ message: HopBearer.Message) -> String { peerKey(message) }
}
