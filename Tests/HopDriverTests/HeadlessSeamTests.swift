// The node seam (cov/apple-driver): the transport-agnostic entry points every bearer drives — a link came
// up / delivered bytes / dropped — plus a raw node mutation. These just funnel into the real HopNode on the
// `core` queue, so they're safe to drive directly with synthetic link ids (no radio). Also pins the
// remaining applyRefresh advert-collapse branch (a stale advert arriving AFTER a fresher one).

import XCTest
import Foundation
@testable import HopDriver

final class HeadlessSeamTests: XCTestCase {

    private func addr(_ b: UInt8) -> Data { Data(repeating: b, count: 32) }

    func testLinkSeamsDriveTheNodeWithoutARadio() {
        let b = makeHeadlessBearer()
        b.linkUp(7, initiator: true)                 // node.connected
        b.deliver(link: 7, bytes: Data([0x00, 0x01, 0x02]))   // node.received (a non-handshake frame is dropped)
        b.linkDown(7)                                // node.disconnected
        b.nodeDo { node in _ = node.address() }      // arbitrary node mutation
        settle(b)   // reaching here without a crash exercises the whole seam
    }

    func testApplyRefreshRefreshesHopsWhenAStaleAdvertArrivesAfterAFresherOne() {
        let b = makeHeadlessBearer()
        let a = addr(0x51)
        let now = HopBearer.nowMs()
        // Fresher advert first, then an OLDER one for the same publisher — the older one must only refresh
        // the hop distance, never overwrite the current name/state.
        let newer = ServiceHit(publisher: a, service: "presence", title: "Current", summary: "fg|ios|App",
                               tags: [], hops: 3, createdAt: now)
        let older = ServiceHit(publisher: a, service: "presence", title: "Stale", summary: "bg|android|App",
                               tags: [], hops: 1, createdAt: now - 20_000)
        b.applyRefresh(HopBearer.RefreshSnapshot(browse: [newer, older], peerLinks: [], secured: [], routed: [],
                                                 queue: [], hnsCache: [], statuses: [:]))
        XCTAssertEqual(b.reachable.count, 1)
        XCTAssertEqual(b.reachable.first?.name, "Current", "the fresher advert keeps the display name")
        XCTAssertEqual(b.reachable.first?.hops, 1, "the stale advert still contributes its nearer hop count")
    }
}
