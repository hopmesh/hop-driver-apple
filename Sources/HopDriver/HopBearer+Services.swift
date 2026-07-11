import Foundation
import HopFFIBindings

// Services & commands (DESIGN.md §29): the built-in `hop.identify` round-trip (name/kind resolution used
// across peers, contacts, relays, and trace hops) plus the generic custom-service request/response drain.
// Grouped out of the HopBearer class body into this sibling extension so the concern is one cohesive file;
// behavior is unchanged (methods moved verbatim). The identity bookkeeping (`identifyAsked` / `identifyReqs`
// / `identities` / `userNamed` / `nameByAddr` / `nameByShort` / `serviceLog`) are stored properties and so
// stay on the class; these methods drive them exactly as before.
extension HopBearer {

    // MARK: - Services & commands (DESIGN.md §29)

    /// Queue a built-in identity call to `address` (once per session per address) so we
    /// learn its display name / a relay's domain - and can resolve it in traces. Does not
    /// pump (safe to call from `refresh`); the next tick flushes it. Internal (not private) so the sibling
    /// extension files (Hps/Messaging) that surface inbound senders can trigger identity resolution.
    func queueIdentify(_ address: Data) {
        guard !identifyAsked.contains(address) else { return }   // main: bookkeeping
        identifyAsked.insert(address)
        core.async { [weak self] in
            guard let self else { return }
            let id = try? self.node.sendServiceRequest(dst: address, service: serviceIdentify(),
                                                       method: "", args: Data())
            if let id { DispatchQueue.main.async { self.identifyReqs.insert(id) } }
        }
    }

    /// Identify `address` now (from the UI), flushing immediately.
    public func identify(_ address: Data) {
        queueIdentify(address)
        pump()
    }

    /// The resolved identity (name + kind) we've learned for an address, if any.
    public func identity(_ address: Data) -> IdentityInfo? { identities[address] }

    /// Best display name for a full address: an identify name, a known peer/relay's name,
    /// else the short address.
    public func displayName(_ address: Data) -> String {
        if let info = identities[address], !info.name.isEmpty { return info.name }
        if let p = (reachable + relays + seen).first(where: { $0.address == address }) {
            return p.name
        }
        return HopBearer.shortHex(address)
    }

    /// Resolve a trace hop to a display label: a known node's name (or a relay's domain),
    /// else the carrying-app label + the hop's short address in hex (§27).
    public func traceLabel(_ hop: TraceHopInfo) -> String {
        if hop.node.allSatisfy({ $0 == 0 }) { return hop.appLabel }   // anonymized device hop (§27)
        if hop.node == myShortAddr { return "you" }
        if let name = nameByShort[hop.node], !name.isEmpty { return name }
        return "\(hop.appLabel) \(HopBearer.hex(hop.node))"
    }

    /// Drain identify replies and custom service traffic. Identify replies update the
    /// address book (names + relay domains); custom requests get a "not implemented"
    /// reply so callers aren't left hanging (the demo registers no app services yet).
    func applyServiceResponses(_ responses: [ServiceResp]) {
        for resp in responses {
            if identifyReqs.remove(resp.forRequestId) != nil, resp.status == 0,
               let info = decodeIdentity(body: resp.body) {
                identities[Data(info.address)] = info
                let addr = Data(info.address)
                let label = info.name.isEmpty ? HopBearer.shortHex(addr) : info.name
                // Keep the contact's display name in sync (the chat is keyed by address,
                // so renames are safe) - this is how an unknown sender gets its real name.
                // A contact the user named locally keeps that alias.
                if !userNamed.contains(addr) {
                    nameByAddr[addr] = label
                }
                if let c = contacts[addr], !userNamed.contains(addr) {
                    contacts[addr] = Peer(address: addr, name: label, hops: c.hops,
                                          active: c.active, platform: c.platform, app: c.app)
                }
                serviceLog.insert("identify ← \(label) (\(info.kind))", at: 0)
                scheduleRefresh()
            } else {
                let text = String(data: resp.body, encoding: .utf8) ?? "<\(resp.body.count) bytes>"
                serviceLog.insert("service ← \(resp.status): \(text.prefix(120))", at: 0)
            }
        }
    }

    func applyServiceRequests(_ requests: [ServiceReq]) {
        for req in requests {
            // No custom services registered in the demo yet - reply 501 so the caller
            // gets a definite answer instead of a timeout.
            serviceLog.insert("service → \(req.service)/\(req.method) (501)", at: 0)
            let from = req.from, reqId = req.requestId
            core.async { [weak self] in
                _ = try? self?.node.sendServiceResponse(to: from, forRequestId: reqId,
                                                        status: 501, body: Data())
            }
        }
    }
}
