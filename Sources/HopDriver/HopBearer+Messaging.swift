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

    public func send(_ text: String, to peer: Peer) {
        rememberContact(peer)   // messaging someone adds them to your address book
        let msg = Message(peer: peer.name, text: text, incoming: false, peerAddr: peer.address)
        messages.append(msg)
        sendBundle(dst: peer.address, contentType: "text/plain; charset=utf-8",
                   body: Data(text.utf8), messageId: msg.id)
    }

    /// TEST/AUTOMATION hook: send `text` to a base58 ADDRESS, building a minimal peer (no UI
    /// selection needed). Drives the headless automation surface (the `hopdemo://send` URL scheme
    /// and the `HOP_AUTO` launch env var); not on any normal user path. The node defers/ratchets
    /// to an as-yet-unreachable address like any send, so the target need not be discovered yet.
    public func sendTo(addressBase58 b58: String, text: String) {
        onMain { [weak self] in
            guard let self else { return }
            let addr = addressFromBase58(text: b58.trimmingCharacters(in: .whitespacesAndNewlines))
            guard addr.count == 32, addr != self.myAddrCache else { return }
            self.send(text, to: Peer(address: addr, name: self.displayName(addr), hops: 0))
        }
    }

    /// Send an image. It's just a message with an image content type and the raw bytes as
    /// the body - the core auto-streams it in chunks if it's too big for one bundle, and
    /// the far side reassembles it back into one message (DESIGN.md §20).
    public func sendImage(_ data: Data, to peer: Peer) {
        rememberContact(peer)
        let msg = Message(peer: peer.name, text: "", incoming: false, peerAddr: peer.address,
                          contentType: "image/jpeg", imageData: data)
        messages.append(msg)
        sendBundle(dst: peer.address, contentType: "image/jpeg", body: data, messageId: msg.id)
    }

    /// Send text and/or one-or-more images as ONE message (`multipart/mixed`) - a single sealed
    /// payload, carrier-chunked + reassembled like any message (DESIGN.md §20). The wire format
    /// is shared with Android: `[u32 partCount][ per part: u16 ctLen, ct, u32 bodyLen, body ]`.
    public func sendMultipart(text: String, images: [Data], to peer: Peer) {
        var parts: [(String, Data)] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(("text/plain", Data(trimmed.utf8))) }
        for img in images { parts.append(("image/jpeg", img)) }
        guard !parts.isEmpty else { return }
        let body = HopBearer.encodeMultipart(parts)
        let msg = Message(peer: peer.name, text: trimmed, incoming: false, peerAddr: peer.address,
                          contentType: "multipart/mixed", images: images)
        messages.append(msg)
        sendBundle(dst: peer.address, contentType: "multipart/mixed", body: body, messageId: msg.id)
    }

    /// Re-send a failed ("Not sent") message in place - rebuilds the same payload from its
    /// content type and dispatches fresh, so the node defers/ratchets + tracks delivery again.
    /// Recovery for a message that gave up (queue cleared, or still unsent at a restart).
    public func retry(_ m: Message) {
        guard !m.incoming, let addr = m.peerAddr else { return }
        let body: Data
        let ct: String
        switch m.contentType {
        case let c where c.hasPrefix("image/"):
            guard let d = m.imageData else { return }
            body = d; ct = "image/jpeg"
        case "multipart/mixed":
            var parts: [(String, Data)] = []
            if !m.text.isEmpty { parts.append(("text/plain", Data(m.text.utf8))) }
            for img in (m.imageData.map { [$0] } ?? m.images) { parts.append(("image/jpeg", img)) }
            guard !parts.isEmpty else { return }
            body = HopBearer.encodeMultipart(parts); ct = "multipart/mixed"
        default:
            body = Data(m.text.utf8); ct = "text/plain; charset=utf-8"
        }
        if let i = messages.firstIndex(where: { $0.id == m.id }) {
            messages[i].failed = false
            messages[i].delivered = false
            messages[i].sentAt = Date()
        }
        sendBundle(dst: addr, contentType: ct, body: body, messageId: m.id)
    }

    /// Encode `(contentType, bytes)` parts into the shared multipart wire format. Forwards to the
    /// single-responsibility `Multipart` codec; kept as a static entry point for existing call sites + tests.
    static func encodeMultipart(_ parts: [(String, Data)]) -> Data { Multipart.encode(parts) }

    /// Decode the shared multipart wire format into `(contentType, bytes)` parts. Forwards to `Multipart`.
    static func decodeMultipart(_ data: Data) -> [(String, Data)] { Multipart.decode(data) }

    /// Surface received messages into the UI (main).
    func applyInbox(_ inbox: [InboxMessage]) {
        for m in inbox {
            let who = nameByAddr[m.from] ?? HopBearer.shortHex(m.from)
            let isImage = m.contentType.hasPrefix("image/")
            let isMultipart = m.contentType == "multipart/mixed"
            var text = isImage ? "" : (String(data: m.body, encoding: .utf8) ?? "<\(m.body.count) bytes>")
            var images: [Data] = []
            if isMultipart {
                let parts = HopBearer.decodeMultipart(m.body)
                text = parts.first(where: { $0.0.hasPrefix("text/") })
                    .flatMap { String(data: $0.1, encoding: .utf8) } ?? ""
                images = parts.filter { $0.0.hasPrefix("image/") }.map { $0.1 }
            }
            let now = HopBearer.nowMs()
            let latency = now >= m.createdAt ? now - m.createdAt : 0  // clamp clock skew
            messages.append(Message(peer: who, text: text, incoming: true,
                                    peerAddr: m.from, contentType: m.contentType,
                                    imageData: isImage ? m.body : nil, images: images,
                                    hops: m.hops, latencyMs: latency, trace: m.trace))
            // A sender that isn't in our nearby/contacts must still be reachable in the UI,
            // or the message vanishes. Make them a contact (so a row + chat exist) and run
            // hop.identify to resolve their name (their input, or their id if unset, §29).
            if contacts[m.from] == nil {
                contacts[m.from] = Peer(address: m.from, name: who, hops: m.hops)
            }
            queueIdentify(m.from)
            if who != activePeer { unread[who, default: 0] += 1 }  // badge unless viewing
            notifyIfBackgrounded(from: who, text: text)
        }
    }
}
