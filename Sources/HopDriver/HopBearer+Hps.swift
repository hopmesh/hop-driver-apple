import Foundation
import HopFFIBindings

// The hps:// pub/sub concern (DESIGN.md §32). Services & channels: host / subscribe / publish / invite /
// moderate / browse, plus the received-message + invite apply paths. Grouped out of the HopBearer class
// body into this sibling extension so the concern is one cohesive file; behavior is unchanged (methods
// moved verbatim). The @Published topic/thread/unread/invite state stays on the class (SwiftUI observes it
// there); these methods drive the node on `core` and mutate that state on main exactly as before.
extension HopBearer {

    // MARK: - hps:// pub/sub (DESIGN.md §32)

    /// Host a new topic at `path`: a channel (anyone with the key reads + writes) or a service
    /// (only we broadcast). Keys are minted + persisted in the node. Returns the service public
    /// key for a service (empty for a channel).
    @discardableResult
    public func hpsRegister(path: String, channel: Bool, access: HpsAccess = .open,
                     discoverable: Bool = false) -> Data {
        let p = path.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return Data() }
        // Synchronous return to the UI (mints + persists keys): a brief core.sync. Deadlock-free - no
        // core callback ever sync-waits back on main (they all hop to main via DispatchQueue.main.async,
        // never .sync), so `core.sync` from main can never deadlock. It CAN still stall the UI behind
        // whatever is queued on the serial core queue (a packet drain, a message seal); this variant
        // exists only for the caller that genuinely needs the service pubkey inline. A caller that does
        // NOT need the pubkey (e.g. a "Create" button that dismisses) should use `hpsRegister(..., then:)`
        // below, which is the same async-snapshot shape as `hpsHostSnapshot` and never touches the
        // render path with a sync.
        let pk = core.sync {
            node.registerService(path: p, kind: channel ? .channel : .service,
                                 access: access, visibility: discoverable ? .discoverable : .private)
        }
        insertHostedTopic(p, channel: channel, access: access)
        return pk
    }

    /// Async host-a-topic: mint + persist keys OFF the render path (on the core queue), then deliver the
    /// service pubkey on main. Same async-snapshot shape as `hpsHostSnapshot` (apple-10) - a caller that
    /// does not need the pubkey inline should prefer this so registration never does a `core.sync` from
    /// the SwiftUI render path (which stalls the UI behind the core serial queue under congestion, the
    /// 0x8BADF00D class the apple-10 mitigation removed). `then` is optional and runs on main.
    public func hpsRegister(path: String, channel: Bool, access: HpsAccess = .open,
                            discoverable: Bool = false, then completion: ((Data) -> Void)? = nil) {
        let p = path.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { completion?(Data()); return }
        // Mirror the sync path's optimistic UI insert immediately (on main), so the topic row appears
        // without waiting on the core queue; the key mint runs async and the pubkey is delivered back.
        insertHostedTopic(p, channel: channel, access: access)
        core.async { [weak self] in
            guard let self else { return }
            let pk = self.node.registerService(path: p, kind: channel ? .channel : .service,
                                                access: access,
                                                visibility: discoverable ? .discoverable : .private)
            DispatchQueue.main.async { completion?(pk) }
        }
    }

    /// Optimistic UI insert for a topic we host (main-thread @Published mutation). Shared by both the
    /// sync and async `hpsRegister` so the two never drift.
    private func insertHostedTopic(_ p: String, channel: Bool, access: HpsAccess) {
        if !hpsTopics.contains(where: { $0.host == myAddrCache && $0.path == p }) {
            hpsTopics.insert(HpsTopic(host: myAddrCache, path: p, isChannel: channel,
                                      hosting: true, access: access), at: 0)
        }
    }

    /// Subscribe to `hps://{hostBase58}/{path}` - request the topic's keys from its host.
    public func hpsSubscribe(hostBase58: String, path: String) {
        let host = addressFromBase58(text: hostBase58.trimmingCharacters(in: .whitespacesAndNewlines))
        let p = path.trimmingCharacters(in: .whitespaces)
        guard host.count == 32, !p.isEmpty else { return }
        hpsSubscribe(host: host, path: p, isChannel: true)
    }

    private func hpsSubscribe(host: Data, path: String, isChannel: Bool) {
        core.async { [weak self] in _ = try? self?.node.hpsSubscribe(host: host, path: path) }
        if !hpsTopics.contains(where: { $0.host == host && $0.path == path }) {
            hpsTopics.insert(HpsTopic(host: host, path: path, isChannel: isChannel, hosting: false), at: 0)
        }
        pump()
    }

    /// Join a discoverable topic from a browse result.
    public func hpsJoin(_ t: HpsTopicInfo) {
        hpsSubscribe(host: t.host, path: t.path, isChannel: t.kind == .channel)
    }

    /// Publish text to a topic we host or (for a channel) belong to. Floods to all subscribers.
    public func hpsPublish(topic: HpsTopic, text: String) {
        guard !text.isEmpty, let body = text.data(using: .utf8) else { return }
        let path = topic.path
        core.async { [weak self] in _ = try? self?.node.hpsPublish(path: path, body: body) }
        // Echo our own post locally - broadcasts don't loop back to the sender.
        appendThread(topic.id, HpsMsgRow(path: topic.path, sender: myAddrCache, text: text, at: HopBearer.nowMs()))
        pump()
    }

    /// Host → contact: invite an address to a topic we host (Invite mode).
    public func hpsInvite(topic: HpsTopic, to address: Data) {
        guard topic.hosting, address.count == 32 else { return }
        let path = topic.path
        core.async { [weak self] in _ = try? self?.node.hpsInvite(path: path, dest: address) }
        pump()
    }

    /// Accept an invite we received - joins the topic once the host seals us the keys.
    public func hpsAcceptInvite(_ inv: HpsInvite) {
        let host = inv.host, path = inv.path
        core.async { [weak self] in _ = try? self?.node.hpsAcceptInvite(host: host, path: path) }
        hpsInvites.removeAll { $0.path == inv.path && $0.host == inv.host }
        if !hpsTopics.contains(where: { $0.host == inv.host && $0.path == inv.path }) {
            hpsTopics.insert(HpsTopic(host: inv.host, path: inv.path,
                                      isChannel: inv.kind == .channel, hosting: false), at: 0)
        }
        pump()
    }

    public func hpsDeclineInvite(_ inv: HpsInvite) {
        let host = inv.host, path = inv.path   // durable: won't reappear
        core.async { [weak self] in try? self?.node.hpsDeclineInvite(host: host, path: path) }
        hpsInvites.removeAll { $0.path == inv.path && $0.host == inv.host }
    }

    /// Host: pending join requests (RequestToJoin) for a topic. LEGACY synchronous read - do NOT call
    /// from a SwiftUI render path; it does a `core.sync` that stalls the UI behind the core serial queue
    /// under congestion (the apple-10 stall class). Deadlock-free (no core callback sync-waits on main),
    /// but render-path callers should use `hpsHostSnapshot` (which fetches reach + pending + members off
    /// the core queue in one hop) instead. Retained only for off-render-path / test callers.
    public func hpsPending(_ topic: HpsTopic) -> [Data] { core.sync { node.hpsPending(path: topic.path) } }
    public func hpsApprove(_ topic: HpsTopic, _ who: Data) {
        let path = topic.path
        core.async { [weak self] in _ = try? self?.node.hpsApprove(path: path, requester: who) }
        pump()
    }
    public func hpsDeny(_ topic: HpsTopic, _ who: Data) {
        let path = topic.path
        core.async { [weak self] in try? self?.node.hpsDeny(path: path, requester: who) }
    }
    /// Host: reach (unique acking members) + the retained-member set. LEGACY synchronous reads - same
    /// caveat as `hpsPending`: do NOT call from a SwiftUI render path (they `core.sync`). Render-path
    /// callers should use `hpsHostSnapshot`, which reads all three off the core queue in one hop.
    public func hpsReach(_ topic: HpsTopic) -> Int { core.sync { Int(node.hpsReach(path: topic.path)) } }
    public func hpsMembers(_ topic: HpsTopic) -> [Data] { core.sync { node.hpsMembers(path: topic.path) } }

    /// apple-10: fetch a snapshot of a hosted topic's reach + pending join-requests + members OFF the
    /// SwiftUI render path (see `HopBearer.HpsHostSnapshot` in HopModels.swift). The three underlying node
    /// reads run once on the core queue and the result is delivered on main, so the channel-info sheet never
    /// does a `core.sync` inside its body (the 0x8BADF00D stall class under core congestion). Callers hold
    /// the result in @State and re-fetch on appear / after a mutating action.
    public func hpsHostSnapshot(_ topic: HpsTopic, _ completion: @escaping (HpsHostSnapshot) -> Void) {
        let path = topic.path
        core.async { [weak self] in
            guard let self else { return }
            let snap = HpsHostSnapshot(reach: Int(self.node.hpsReach(path: path)),
                                       pending: self.node.hpsPending(path: path),
                                       members: self.node.hpsMembers(path: path))
            DispatchQueue.main.async { completion(snap) }
        }
    }
    /// Host: rotate keys, optionally removing members (revocation).
    public func hpsRekey(_ topic: HpsTopic, remove: [Data] = []) {
        let path = topic.path
        core.async { [weak self] in _ = try? self?.node.hpsRekey(path: path, newPath: "", remove: remove) }
        pump()
    }

    /// Leave / unsubscribe a topic we follow.
    public func hpsLeave(_ topic: HpsTopic) {
        var retainedThreads = hpsThreads
        retainedThreads[topic.id] = nil
        guard MirrorStore.saveChannels(retainedThreads) else {
            persistenceError = "failed to persist channel deletion"
            return
        }
        durableHpsIds.replace(with: retainedThreads.values.flatMap { $0 }.compactMap(\.inboxId))
        let path = topic.path
        core.async { [weak self] in _ = try? self?.node.hpsLeave(path: path) }
        hpsTopics.removeAll { $0.id == topic.id }
        hpsThreads = retainedThreads
        hpsUnread[topic.id] = nil
        pump()
    }

    /// Discover same-app topics on the mesh (decrypted descriptors). apple-r2-04: fetched OFF the main
    /// thread (the Browse tab called this from onAppear/onChange/Refresh, and a `core.sync` from main
    /// blocks the UI behind whatever is queued on the core serial queue, e.g. a packet drain / message
    /// seal, so the Browse tab hitched under load). Same async-snapshot shape as `hpsHostSnapshot`: read
    /// once on the core queue, deliver the result on main.
    public func hpsBrowse(_ completion: @escaping ([HpsTopicInfo]) -> Void) {
        core.async { [weak self] in
            guard let self else { return }
            let found = self.node.browseDiscoverable()
            DispatchQueue.main.async { completion(found) }
        }
    }

    /// Rebuild the channel list from the node's persisted topics (hosted + subscribed) at startup.
    /// apple-r2-04: reads on the core queue and applies to `hpsTopics` (a main-thread @Published) back on
    /// main, so startup never blocks the main thread behind the core serial queue. Internal (not private)
    /// so `start()` in the class file can call it.
    func loadHpsTopics() {
        core.async { [weak self] in
            guard let self else { return }
            let mine = self.node.hpsMyTopics()
            DispatchQueue.main.async {
                for t in mine {
                    let topic = HpsTopic(host: t.host, path: t.path, isChannel: t.kind == .channel,
                                         hosting: t.hosting, access: t.access)
                    if !self.hpsTopics.contains(where: { $0.id == topic.id }) { self.hpsTopics.append(topic) }
                }
            }
        }
    }

    /// Mark a topic's thread as read (called when its screen is open).
    public func openTopic(_ id: String) { activeTopic = id; hpsUnread[id] = 0 }
    public func closeTopic() { activeTopic = nil }

    @discardableResult
    private func appendThread(_ id: String, _ row: HpsMsgRow) -> Bool {
        guard hpsThreads[id] != nil || hpsThreads.count < RetentionPolicy.defaults.conversations else {
            return false
        }
        hpsThreads[id, default: []].append(row)
        while let thread = hpsThreads[id],
              thread.count > RetentionPolicy.defaults.conversationMessages ||
                thread.reduce(0, { $0 + Data($1.text.utf8).count }) > RetentionPolicy.defaults.conversationMessageBytes {
            hpsThreads[id]!.removeFirst()
        }
        while hpsThreads.values.reduce(0, { $0 + $1.count }) > RetentionPolicy.defaults.globalMessages ||
                hpsThreads.values.flatMap({ $0 }).reduce(0, { $0 + Data($1.text.utf8).count }) >
                    RetentionPolicy.defaults.globalMessageBytes {
            var candidates: [(String, HpsMsgRow)] = []
            for (key, rows) in hpsThreads { candidates.append(contentsOf: rows.map { (key, $0) }) }
            guard let oldest = candidates.min(by: {
                $0.1.at == $1.1.at ? $0.0 < $1.0 : $0.1.at < $1.1.at
            }),
                  let index = hpsThreads[oldest.0]?.firstIndex(where: { $0.id == oldest.1.id }) else { break }
            hpsThreads[oldest.0]!.remove(at: index)
        }
        return hpsThreads[id]?.contains(where: { $0.id == row.id }) == true
    }

    /// Apply received pub/sub messages into per-topic threads (main).
    func applyHpsMessages(_ msgs: [HpsMessage]) {
        var accepted: [Data] = []
        var journalChanged = false
        for m in msgs {
            let duplicate = durableHpsIds.contains(m.id) || hpsThreads.values
                .flatMap { $0 }
                .contains { $0.inboxId == m.id }
            if duplicate {
                accepted.append(m.id)
                continue
            }
            let text = String(data: m.body, encoding: .utf8) ?? "<\(m.body.count) bytes>"
            // Match the message to a topic we follow (by path; host is whoever we subscribed to).
            let topic = hpsTopics.first { $0.path == m.path }
            let id = topic?.id ?? m.path
            let keep = Data(text.utf8).count <= RetentionPolicy.defaults.conversationMessageBytes &&
                (hpsThreads[id] != nil || hpsThreads.count < RetentionPolicy.defaults.conversations)
            let row = HpsMsgRow(path: m.path, sender: m.sender, text: text,
                                at: HopBearer.nowMs(), inboxId: m.id)
            let persisted = persistHpsForTest?(m.id, id, keep ? row : nil) ??
                MirrorStore.appendChannelDelta(id: m.id, topic: id, row: keep ? row : nil)
            guard persisted else {
                persistenceError = "failed to append channel journal"
                continue
            }
            durableHpsIds.insert(m.id)
            journalChanged = true
            if keep, appendThread(id, row) {
                if id != activeTopic { hpsUnread[id, default: 0] += 1 }
                queueIdentify(m.sender)
            }
            accepted.append(m.id)
        }
        if journalChanged { scheduleChannelJournalCompaction() }
        if !accepted.isEmpty {
            core.async { [weak self] in
                guard let self else { return }
                for id in accepted {
                    if let acceptHpsForTest = self.acceptHpsForTest { _ = acceptHpsForTest(id) }
                    else { _ = try? self.node.acceptHpsMessage(id: id) }
                }
            }
        }
    }

    /// Surface new pub/sub invites (main).
    func applyHpsInvites(_ invites: [HpsInvite]) {
        for inv in invites {
            if !hpsInvites.contains(where: { $0.path == inv.path && $0.host == inv.host }) {
                hpsInvites.append(inv)
                queueIdentify(inv.host)
            }
        }
    }
}
