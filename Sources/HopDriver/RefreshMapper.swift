import Foundation
import HopFFIBindings

/// The pure snapshot -> UI-row mapping, lifted out of `HopBearer.applyRefresh` (the single biggest method
/// in the driver). Everything here is a value-in / value-out transform with no node, no radio, and no
/// @Published mutation, so it is unit-testable in isolation and keeps `applyRefresh` down to the parts that
/// genuinely need instance state (the bearer-manager link ownership, the identity book, the @Published
/// assignment). Behavior is unchanged: the logic is moved verbatim.
enum RefreshMapper {

    /// Collapse the many retained presence adverts per publisher into one reachable `Peer` each, plus the
    /// name-by-address updates the caller merges. Rules (DESIGN.md §23), preserved exactly:
    ///   • nearest hop count wins for distance,
    ///   • the newest advert (max `createdAt`) wins for the display name/state/platform/app,
    ///   • the returned `names` map is last-write-in-browse-order (which can differ from the newest-advert
    ///     peer name (that pre-existing quirk is retained), keyed by publisher,
    ///   • the reachable list is sorted by the stable address so rows don't jump as hops/names churn.
    static func aggregatePresence(_ hits: [ServiceHit]) -> (reachable: [HopBearer.Peer], names: [Data: String]) {
        struct Agg { var minHops: UInt8; var newestAt: UInt64; var peer: HopBearer.Peer }
        var agg = [Data: Agg]()
        var names = [Data: String]()
        for p in hits {
            let name = p.title.isEmpty ? HopBearer.shortHex(p.publisher) : p.title
            let parts = p.summary.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let active = parts.indices.contains(0) ? parts[0] != "bg" : true
            let platform = parts.indices.contains(1) ? parts[1] : ""
            let app = parts.indices.contains(2) ? parts[2] : ""
            let hops = agg[p.publisher].map { min($0.minHops, p.hops) } ?? p.hops
            if let ex = agg[p.publisher], p.createdAt < ex.newestAt {
                agg[p.publisher] = Agg(minHops: hops, newestAt: ex.newestAt, peer: ex.peer) // older: just refresh hops
            } else {
                let peer = HopBearer.Peer(address: p.publisher, name: name, hops: hops,
                                          active: active, platform: platform, app: app)
                agg[p.publisher] = Agg(minHops: hops, newestAt: p.createdAt, peer: peer)
            }
            names[p.publisher] = name
        }
        var byAddr = [Data: HopBearer.Peer]()
        for (addr, a) in agg {
            let peer = a.peer
            byAddr[addr] = HopBearer.Peer(address: addr, name: peer.name, hops: a.minHops,
                                          active: peer.active, platform: peer.platform, app: peer.app)
        }
        let reachable = byAddr.values.sorted { $0.address.lexicographicallyPrecedes($1.address) }
        return (reachable, names)
    }

    /// The legacy link-id -> transport tag mapping, for a link the node still mints itself (Multipeer,
    /// legacy relay/endpoints) rather than the shared BearerManager. Kept as the fall-back the manager's
    /// real `transportName` takes priority over.
    static func legacyTransportTag(_ link: UInt64) -> String {
        switch link {
        case ..<10_000:  return "BT"
        case ..<20_000:  return "P2P"       // MultipeerConnectivity / AWDL - peer-to-peer Wi-Fi, no router
        case ..<40_000:  return "Relay"     // relay (20k) + hops:// endpoints (30k) aren't local
        default:          return "LAN"        // 40k+ = LAN TCP over a shared network (mDNS)
        }
    }

    /// Per-transport status rows: several bearers run at once, so the headline count is the actual
    /// transport-level connection count from the BearerManager (`active` short-tag -> live-link count),
    /// with Peer-to-Peer (Multipeer, not a shared bearer) added from its own live-link/radio signal.
    static func transportStatuses(active: [String: Int], p2pActive: Bool,
                                  p2pLinks: Int) -> [HopBearer.TransportStatus] {
        var ts: [HopBearer.TransportStatus] = []
        if let n = active["BT"]    { ts.append(HopBearer.TransportStatus(id: "Bluetooth", active: true, links: n)) }
        ts.append(HopBearer.TransportStatus(id: "Peer-to-Peer", active: p2pActive, links: p2pLinks))
        if let n = active["LAN"]   { ts.append(HopBearer.TransportStatus(id: "Local Net", active: true, links: n)) }
        if let n = active["Relay"] { ts.append(HopBearer.TransportStatus(id: "Relay", active: true, links: n)) }
        return ts
    }

    /// Map the node's send/relay queue into display rows (an empty destination renders as "broadcast").
    static func mapQueue(_ items: [QueueItem]) -> [HopBearer.QueueRow] {
        items.map {
            HopBearer.QueueRow(id: $0.id, own: $0.own,
                               to: $0.to.isEmpty ? "broadcast" : HopBearer.shortHex($0.to),
                               priority: $0.priority, hops: $0.hops)
        }
    }

    /// Map the node's live HNS cache into display rows (ticks down each refresh as the node clock advances).
    static func mapHnsCache(_ entries: [HnsCacheEntry]) -> [HopBearer.HnsCacheRow] {
        entries.map { HopBearer.HnsCacheRow(domain: $0.domain, address: $0.address, ttl: $0.ttlSecs) }
    }
}
