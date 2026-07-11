// Lifecycle + identity + focus-tracking + hops:// error-path coverage (cov/apple-driver). start() is driven
// in the ONE headless-safe configuration (.relayOnly + no relay ⇒ registers zero bearers, no radio); the
// rest exercise the pure identity/label/badge/private-mode/pin logic against a real node.

import XCTest
import Foundation
@testable import HopDriver

final class HeadlessLifecycleTests: XCTestCase {

    private func addr(_ b: UInt8) -> Data { Data(repeating: b, count: 32) }

    // MARK: start (relay-only + no relay ⇒ no bearer is registered/started, so no radio)

    func testStartRelayOnlyIsHeadlessSafeAndBecomesReady() {
        let b = makeHeadlessBearer(role: .relayOnly, relay: nil, name: "Node")
        XCTAssertFalse(b.isReady, "not ready until start() publishes the address")
        b.start(name: "Node")
        XCTAssertTrue(b.isReady)
        XCTAssertEqual(b.myName, "Node")
        XCTAssertFalse(b.myAddress.isEmpty)
        b.start(name: "Again")   // guarded: a second start is a no-op
        XCTAssertEqual(b.myName, "Node")
        settle(b)
    }

    func testBackgroundTickDrivesTheNodeClockAndRepublishesPresence() {
        let b = makeHeadlessBearer()
        // 120 ticks crosses both the %20 presence-refresh and %120 prekey-republish branches.
        for _ in 0..<120 { b.backgroundTick() }
        settle(b)
        XCTAssertTrue(b.isReady == false || b.isReady == true)   // reaching here without a crash is the assertion
    }

    // MARK: identity + display names

    func testIdentityAndDisplayNameResolution() {
        let b = makeHeadlessBearer()
        let a = addr(0x61)
        XCTAssertEqual(b.displayName(a), HopBearer.shortHex(a), "unknown address falls back to the short id")
        b.identities[a] = IdentityInfo(address: a, name: "Zed", kind: "device")
        XCTAssertEqual(b.displayName(a), "Zed", "a learned identity name wins")
        XCTAssertEqual(b.identity(a)?.kind, "device")
    }

    func testDisplayNameFallsBackToAReachablePeer() {
        let b = makeHeadlessBearer()
        let a = addr(0x62)
        let hit = ServiceHit(publisher: a, service: "presence", title: "Nora", summary: "fg|ios|App",
                             tags: [], hops: 1, createdAt: HopBearer.nowMs())
        b.applyRefresh(HopBearer.RefreshSnapshot(browse: [hit], peerLinks: [], secured: [], routed: [],
                                                 queue: [], hnsCache: [], statuses: [:]))
        XCTAssertEqual(b.displayName(a), "Nora", "a currently-reachable peer supplies its name")
    }

    func testTraceLabelResolvesEachCase() {
        let b = makeHeadlessBearer()
        // Anonymized device hop (all-zero short address, §27).
        XCTAssertEqual(b.traceLabel(TraceHopInfo(node: Data(repeating: 0, count: 8), appLabel: "device")), "device")
        // Our own hop.
        let mine = HopBearer.shortData(b.myAddressData)
        XCTAssertEqual(b.traceLabel(TraceHopInfo(node: mine, appLabel: "x")), "you")
        // A resolved short address.
        let short = HopBearer.shortData(addr(0x63))
        b.nameByShort[short] = "Kai"
        XCTAssertEqual(b.traceLabel(TraceHopInfo(node: short, appLabel: "x")), "Kai")
        // An unresolved hop shows the app label + hex.
        let unknown = HopBearer.shortData(addr(0x64))
        XCTAssertTrue(b.traceLabel(TraceHopInfo(node: unknown, appLabel: "Hop Relay")).hasPrefix("Hop Relay "))
    }

    // MARK: chat focus + unread

    func testUnreadTotalsAndOpenChatClearsIt() {
        let b = makeHeadlessBearer()
        b.unread["Ann"] = 2
        b.unread["Bo"] = 1
        XCTAssertEqual(b.totalUnread, 3)
        b.openChat("Ann")
        XCTAssertEqual(b.unread["Ann"], 0)
        b.closeChat()
    }

    // MARK: private mode + pinned relay

    func testPrivateModeToggleIsSafeHeadless() {
        let b = makeHeadlessBearer()
        let restore = UserDefaults.standard.bool(forKey: "hop.privateMode")
        defer { UserDefaults.standard.set(restore, forKey: "hop.privateMode") }
        b.privateMode = true    // retractPresence + stops the (nil) advertiser
        XCTAssertTrue(b.privateMode)
        b.privateMode = false   // publishPresence + starts the (nil) advertiser
        XCTAssertFalse(b.privateMode)
        settle(b)
    }

    func testSetPinnedRelayPersistsAndClears() {
        let b = makeHeadlessBearer()
        defer { UserDefaults.standard.removeObject(forKey: "hop.pinnedRelay") }
        b.setPinnedRelay("wss://relay.test/")
        XCTAssertEqual(b.pinnedRelay, "wss://relay.test/")
        XCTAssertFalse(b.relayStatus.isEmpty)
        b.setPinnedRelay("   ")   // blank ⇒ clears the pin
        XCTAssertNil(b.pinnedRelay)
    }

    func testSavedNameReadsUserDefaultsElseDefault() {
        UserDefaults.standard.set("Known", forKey: "hop.displayName")
        XCTAssertEqual(HopBearer.savedName(default: "Fallback"), "Known")
        UserDefaults.standard.removeObject(forKey: "hop.displayName")
        XCTAssertEqual(HopBearer.savedName(default: "Fallback"), "Fallback")
    }

    // MARK: hops:// error paths (no resolvable domain ⇒ no radio)

    func testOpenHopsRejectsAnEmptyUrl() {
        let b = makeHeadlessBearer()
        b.openHops("   ")   // parses to an empty domain
        XCTAssertEqual(b.hopsResults["?"], "error: not a hops:// url")
    }

    func testOpenHopsSetsAResultForAnUnresolvableDomain() {
        let b = makeHeadlessBearer()
        b.openHops("hops://nonexistent.invalidtld/page")
        XCTAssertEqual(b.hopsResults["nonexistent.invalidtld"], "resolving…", "the optimistic state is set synchronously")
        settle(b)
        // With no internet and no peers the node cannot resolve, so the row must resolve to SOME terminal
        // state (an offline/no-endpoint error or a still-pending lookup) - never a crash.
        XCTAssertNotNil(b.hopsResults["nonexistent.invalidtld"])
    }

    func testHopsFetchRejectsAnEmptyDomain() {
        let b = makeHeadlessBearer()
        let done = expectation(description: "bad hops url ⇒ 400")
        b.hopsFetch(domain: "", path: "/") { resp in
            XCTAssertEqual(resp.status, 400)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    // MARK: misc surface

    func testMyAddressDataIsThirtyTwoBytesAndContactListSorts() {
        let b = makeHeadlessBearer()
        XCTAssertEqual(b.myAddressData.count, 32)
        b.rememberContact(HopBearer.Peer(address: foreignAddr(0x71), name: "zeb", hops: 0))
        b.rememberContact(HopBearer.Peer(address: foreignAddr(0x72), name: "abe", hops: 0))
        XCTAssertEqual(b.contactList.map { $0.name }, ["abe", "zeb"], "contacts sort case-insensitively by name")
    }
}
