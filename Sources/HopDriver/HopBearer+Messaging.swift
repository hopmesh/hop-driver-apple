import Foundation
import HopFFIBindings

// Outbound + inbound direct messaging (DESIGN.md §20): add-a-contact, clear-queue, the send family
// (text / image / multipart), in-place retry, and the inbound-surface path. Grouped out of the HopBearer
// class body into this sibling extension so the concern is one cohesive file; behavior is unchanged (methods
// moved verbatim). The @Published `messages` / `unread` state + the contact/name bookkeeping are stored on
// the class; these methods drive the node on `core` and mutate that state on main exactly as before.
extension HopBearer {

    /// Add a contact to the address book by base58 address. An empty `name` falls back to
    /// the address (and hop.identify will fill in the device's own name if it has one); a
    /// provided name is kept as your local alias. Returns false if the address is invalid.
    @discardableResult
    public func addContact(name: String, address base58: String) -> Bool {
        let addr = addressFromBase58(text: base58.trimmingCharacters(in: .whitespacesAndNewlines))
        guard addr.count == 32, addr != myAddrCache else { return false }
        guard RetentionPolicy.canAddContact(
            currentCount: contacts.count,
            alreadyKnown: contacts[addr] != nil
        ) else { return false }
        let alias = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = alias.isEmpty ? HopBearer.shortHex(addr) : alias
        nameByAddr[addr] = label
        contacts[addr] = Peer(address: addr, name: label, hops: 0)
        if alias.isEmpty {
            queueIdentify(addr)   // resolve their device name if they set one
        } else {
            userNamed.insert(addr) // keep my alias
        }
        saveContacts(force: true)
        pump()
        return true
    }

    /// Clear the relay queue (our undelivered messages + bundles held for peers).
    /// Anything of ours still in flight is now abandoned, so mark those bubbles "not sent"
    /// instead of leaving them stuck on "Sending…".
    public func clearQueue() {
        core.async { [weak self] in self?.node.clearQueue() }
        for i in messages.indices where !messages[i].incoming && !messages[i].delivered {
            messages[i].failed = true
        }
        pump()
    }

    /// Send a message on `core`, then stamp the returned bundleId onto its placeholder bubble (main)
    /// so delivery tracking can re-query it. The bubble is appended by the caller before this runs.
    private func sendBundle(dst: Data, contentType: String, body: Data, messageId: UUID) {
        core.async { [weak self] in
            guard let self else { return }
            // A thrown send is a real store/seal error (the peer-unreachable case defers with a valid
            // id), so `id == nil` must mark the bubble failed - otherwise it shows "Sending…" forever
            // and the "Not sent · tap to retry" path never engages (F-15).
            var id: Data? = nil
            do {
                id = try self.node.sendMessage(dst: dst, contentType: contentType, body: body, requestAck: true)
            } catch {
                NSLog("HOPLOG sendMessage threw for \(messageId): \(error)")
            }
            let sentId = id
            DispatchQueue.main.async {
                if let i = self.messages.firstIndex(where: { $0.id == messageId }) {
                    if let sentId { self.messages[i].bundleId = sentId }
                    else { self.messages[i].failed = true }
                }
                self.pump()
            }
        }
    }

    @discardableResult
    public func send(_ text: String, to peer: Peer) -> SendResult {
        let msg = Message(peer: peer.name, text: text, incoming: false, peerAddr: peer.address)
        guard reservePending(msg) else { return .overloaded }
        rememberContact(peer)   // messaging someone adds them to your address book
        messages.append(msg)
        sendBundle(dst: peer.address, contentType: "text/plain; charset=utf-8",
                   body: Data(text.utf8), messageId: msg.id)
        return .queued
    }

    /// TEST/AUTOMATION hook: send `text` to a base58 ADDRESS, building a minimal peer (no UI
    /// selection needed). Drives the headless automation surface (the `hopdemo://send` URL scheme
    /// and the `HOP_AUTO` launch env var); not on any normal user path. The node defers/ratchets
    /// to an as-yet-unreachable address like any send, so the target need not be discovered yet.
    @discardableResult
    public func sendTo(addressBase58 b58: String, text: String) -> SendResult {
        let operation = { [weak self] () -> SendResult in
            guard let self else { return .invalid }
            let addr = addressFromBase58(text: b58.trimmingCharacters(in: .whitespacesAndNewlines))
            guard addr.count == 32, addr != self.myAddrCache else { return .invalid }
            return self.send(text, to: Peer(address: addr, name: self.displayName(addr), hops: 0))
        }
        return Thread.isMainThread ? operation() : DispatchQueue.main.sync(execute: operation)
    }

    /// Send an image. It's just a message with an image content type and the raw bytes as
    /// the body - the core auto-streams it in chunks if it's too big for one bundle, and
    /// the far side reassembles it back into one message (DESIGN.md §20).
    @discardableResult
    public func sendImage(_ data: Data, to peer: Peer) -> SendResult {
        guard data.count <= RetentionPolicy.defaults.attachmentBytes else { return .overloaded }
        let msg = Message(peer: peer.name, text: "", incoming: false, peerAddr: peer.address,
                          contentType: "image/jpeg", imageData: data)
        guard reservePending(msg) else { return .overloaded }
        let durable = RetentionPolicy.retain(messages + [msg])
        guard MirrorStore.saveMessages(durable) else {
            pendingQuota.release(msg.id)
            return .overloaded
        }
        rememberContact(peer)
        messages.append(msg)
        sendBundle(dst: peer.address, contentType: "image/jpeg", body: data, messageId: msg.id)
        return .queued
    }

    /// Send text and/or one-or-more images as ONE message (`multipart/mixed`) - a single sealed
    /// payload, carrier-chunked + reassembled like any message (DESIGN.md §20). The wire format
    /// is shared with Android: `[u32 partCount][ per part: u16 ctLen, ct, u32 bodyLen, body ]`.
    @discardableResult
    public func sendMultipart(text: String, images: [Data], to peer: Peer) -> SendResult {
        var parts: [(String, Data)] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(("text/plain", Data(trimmed.utf8))) }
        for img in images { parts.append(("image/jpeg", img)) }
        guard !parts.isEmpty else { return .invalid }
        guard images.allSatisfy({ $0.count <= RetentionPolicy.defaults.attachmentBytes }) else {
            return .overloaded
        }
        guard let body = encodedMultipart(parts) else { return .invalid }
        let msg = Message(peer: peer.name, text: trimmed, incoming: false, peerAddr: peer.address,
                          contentType: "multipart/mixed", images: images)
        guard reservePending(msg) else { return .overloaded }
        let durable = RetentionPolicy.retain(messages + [msg])
        guard MirrorStore.saveMessages(durable) else {
            pendingQuota.release(msg.id)
            return .overloaded
        }
        messages.append(msg)
        sendBundle(dst: peer.address, contentType: "multipart/mixed", body: body, messageId: msg.id)
        return .queued
    }

    /// Re-send a failed ("Not sent") message in place - rebuilds the same payload from its
    /// content type and dispatches fresh, so the node defers/ratchets + tracks delivery again.
    /// Recovery for a message that gave up (queue cleared, or still unsent at a restart).
    @discardableResult
    public func retry(_ m: Message) -> SendResult {
        guard !m.incoming, let addr = m.peerAddr,
              let index = messages.firstIndex(where: { $0.id == m.id }) else { return .invalid }
        let body: Data
        let ct: String
        switch m.contentType {
        case let c where c.hasPrefix("image/"):
            guard let d = m.imageData else { return .invalid }
            body = d; ct = "image/jpeg"
        case "multipart/mixed":
            var parts: [(String, Data)] = []
            if !m.text.isEmpty { parts.append(("text/plain", Data(m.text.utf8))) }
            for img in (m.imageData.map { [$0] } ?? m.images) { parts.append(("image/jpeg", img)) }
            guard !parts.isEmpty, let encoded = encodedMultipart(parts) else { return .invalid }
            body = encoded; ct = "multipart/mixed"
        default:
            body = Data(m.text.utf8); ct = "text/plain; charset=utf-8"
        }
        var pending = m
        pending.failed = false
        pending.delivered = false
        pending.sentAt = Date()
        guard reservePending(pending) else { return .overloaded }
        messages[index] = pending
        sendBundle(dst: addr, contentType: ct, body: body, messageId: m.id)
        return .queued
    }

    private func reservePending(_ message: Message) -> Bool {
        let peer = RetentionPolicy.peerKey(message)
        return pendingQuota.reserve(id: message.id, peer: peer, conversation: peer,
                                    bytes: RetentionPolicy.messageBytes(message)) == .accepted
    }

    private func encodedMultipart(_ parts: [(String, Data)]) -> Data? {
        guard parts.count <= 32 else { return nil }
        var aggregate = 0
        for (contentType, body) in parts {
            let contentBytes = Data(contentType.utf8).count
            guard contentBytes <= 1_024, body.count <= RetentionPolicy.defaults.attachmentBytes,
                  aggregate <= 15 * 1024 * 1024 - contentBytes - body.count else { return nil }
            aggregate += contentBytes + body.count
        }
        return HopBearer.encodeMultipart(parts)
    }

    public func deleteConversation(_ peer: Peer) {
        mutateHistory { messages in
            messages.filter { message in
                if let address = message.peerAddr { return address != peer.address }
                return message.peer != peer.name
            }
        }
        unread[peer.name] = 0
    }

    public func deleteHistory() {
        mutateHistory { _ in [] }
        unread.removeAll()
    }

    public func deleteMedia(for peer: Peer? = nil) {
        mutateHistory { messages in
            messages.map { message in
                let matches = peer.map { target in
                    message.peerAddr.map { $0 == target.address } ?? (message.peer == target.name)
                } ?? true
                guard matches, message.imageData != nil || !message.images.isEmpty else { return message }
                var updated = message
                updated.contentType = "text/plain"
                updated.imageData = nil
                updated.images = []
                return updated
            }
        }
    }

    private func mutateHistory(_ transform: ([Message]) -> [Message]) {
        let updated = transform(messages)
        guard MirrorStore.saveMessages(updated) else {
            persistenceError = "failed to persist history deletion"
            return
        }
        durableInboxIds.replace(with: updated.compactMap(\.inboxId))
        loadingMessages = true
        messages = updated
        loadingMessages = false
    }

    /// Encode `(contentType, bytes)` parts into the shared multipart wire format. Forwards to the
    /// single-responsibility `Multipart` codec; kept as a static entry point for existing call sites + tests.
    static func encodeMultipart(_ parts: [(String, Data)]) -> Data { Multipart.encode(parts) }

    /// Decode the shared multipart wire format into `(contentType, bytes)` parts. Forwards to `Multipart`.
    static func decodeMultipart(_ data: Data) -> [(String, Data)] { Multipart.decode(data) }

    /// Surface received messages into the UI (main).
    func applyInbox(_ inbox: [InboxMessage]) {
        var accepted: [Data] = []
        var updated = messages
        var notifications: [(message: Message, who: String, text: String)] = []
        var journalChanged = false
        for m in inbox {
            if durableInboxIds.contains(m.id) || updated.contains(where: { $0.inboxId == m.id }) {
                accepted.append(m.id)
                continue
            }
            let who = nameByAddr[m.from] ?? HopBearer.shortHex(m.from)
            let knownIdentity = contacts[m.from] != nil
            let isImage = m.contentType.hasPrefix("image/")
            let isMultipart = m.contentType == "multipart/mixed"
            var text = isImage ? "" : (String(data: m.body, encoding: .utf8) ?? "<\(m.body.count) bytes>")
            var images: [Data] = []
            if isMultipart {
                let parts = HopBearer.decodeMultipart(m.body)
                if parts.isEmpty {
                    if persistInboxForTest?(m.id, nil) ?? MirrorStore.appendMessageDelta(id: m.id, message: nil) {
                        durableInboxIds.insert(m.id); accepted.append(m.id); journalChanged = true
                    }
                    continue
                }
                text = parts.first(where: { $0.0.hasPrefix("text/") })
                    .flatMap { String(data: $0.1, encoding: .utf8) } ?? ""
                images = parts.filter { $0.0.hasPrefix("image/") }.map { $0.1 }
            }
            let attachments = isImage ? [m.body] : images
            let mediaShapeAccepted = attachments.isEmpty ||
                (knownIdentity && attachments.allSatisfy { $0.count <= RetentionPolicy.defaults.attachmentBytes })
            if isImage && !mediaShapeAccepted {
                if !knownIdentity && (persistInboxForTest?(m.id, nil) ??
                    MirrorStore.appendMessageDelta(id: m.id, message: nil)) {
                    durableInboxIds.insert(m.id); accepted.append(m.id); journalChanged = true
                }
                continue
            }
            if isMultipart && !mediaShapeAccepted {
                if knownIdentity { continue }
                images = []
                if text.isEmpty {
                    if persistInboxForTest?(m.id, nil) ?? MirrorStore.appendMessageDelta(id: m.id, message: nil) {
                        durableInboxIds.insert(m.id); accepted.append(m.id); journalChanged = true
                    }
                    continue
                }
            }
            let now = HopBearer.nowMs()
            let latency = now >= m.createdAt ? now - m.createdAt : 0  // clamp clock skew
            let contentType = isMultipart && images.isEmpty ? "text/plain" : m.contentType
            let message = Message(peer: who, text: text, incoming: true,
                                  peerAddr: m.from, contentType: contentType,
                                  imageData: isImage ? m.body : nil, images: images,
                                  inboxId: m.id, hops: m.hops, latencyMs: latency, trace: m.trace)
            let retained = RetentionPolicy.retain(updated + [message])
            let retainedMessage = retained.contains { $0.id == message.id }
            let persisted = persistInboxForTest?(m.id, retainedMessage ? message : nil) ??
                MirrorStore.appendMessageDelta(id: m.id, message: retainedMessage ? message : nil,
                                               resultingMessages: retained)
            guard persisted else {
                persistenceError = "failed to append inbox journal"
                continue
            }
            durableInboxIds.insert(m.id)
            accepted.append(m.id)
            journalChanged = true
            updated = retained
            // A sender that isn't in our nearby/contacts must still be reachable in the UI,
            // or the message vanishes. Make them a contact (so a row + chat exist) and run
            // hop.identify to resolve their name (their input, or their id if unset, §29).
            if !knownIdentity && RetentionPolicy.canAddContact(
                currentCount: contacts.count,
                alreadyKnown: false
            ) {
                contacts[m.from] = Peer(address: m.from, name: who, hops: m.hops)
                saveContacts(force: true)
            }
            queueIdentify(m.from)
            if retainedMessage { notifications.append((message, who, isImage ? "Photo" : text)) }
        }
        guard !accepted.isEmpty else { return }
        if updated.map(\.id) != messages.map(\.id) { messages = updated }
        else if journalChanged { scheduleMessageJournalCompaction() }
        let retainedIds = Set(updated.map(\.id))
        for item in notifications where retainedIds.contains(item.message.id) {
            if item.who != activePeer { unread[item.who, default: 0] += 1 }
            notifyIfBackgrounded(from: item.who, text: item.text)
        }
        // The core queue owns HopNode. Release ACK/vaccine only after each stable-id delta is synced.
        core.async { [weak self] in
            guard let self else { return }
            for id in accepted {
                if let acceptInboxForTest = self.acceptInboxForTest {
                    _ = acceptInboxForTest(id)
                } else {
                    _ = try? self.node.acceptInbox(id: id)
                }
            }
            self.pump()
        }
    }
}
