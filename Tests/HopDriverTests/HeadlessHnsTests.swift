// HopBearer+Hns.swift coverage (cov/apple-hns). A pass-4 audit found this file at ~59% line coverage
// while the package's AGGREGATE gate stayed green (the other pure-logic files pulled the average up),
// so a regression here could hide behind it indefinitely. openHops/hopsFetch dispatch on the real node's
// `resolveHns` result (.cached / .pending / .needsResolver, DESIGN.md §30); a fresh headless node with no
// peers and no internet always settles `resolveHns` to `.pending` (hop-core queues a retry and defers -
// it never itself produces `.cached` or `.needsResolver` without a live peer or a completed DoH round
// trip), so the real node can never drive those two branches in a unit test. `resolveHnsForTest`
// (declared on HopBearer in HopBearer.swift) is the minimal seam that lets a test substitute a synthetic
// `HnsLookupResult` for exactly those branches; production leaves it nil and always asks the real node,
// so behavior is unchanged. The domains below that flow into `fireHops`/`fireHopsWeb` (in
// HopBearer+Radios.swift, excluded from the coverage denominator) deliberately contain a space, which
// fails Foundation's `URL(string:)`, so `dialEndpoint` bails out before opening any real socket - the
// Hns.swift call site still executes (and is covered) without a live network attempt.

import XCTest
import Foundation
@testable import HopDriver

final class HeadlessHnsTests: XCTestCase {

    // MARK: openHops via the resolveHnsForTest seam

    func testOpenHopsCachedNegativeSetsNoEndpointError() {
        let b = makeHeadlessBearer()
        b.resolveHnsForTest = { _ in .cached(address: Data()) }
        b.openHops("hops://cached-neg.hop/page")
        settle(b)
        XCTAssertEqual(b.hopsResults["cached-neg.hop"], "error: no hops endpoint for cached-neg.hop")
    }

    func testOpenHopsCachedPositiveFiresHops() {
        let b = makeHeadlessBearer()
        let endpoint = Data(repeating: 0x91, count: 32)
        b.resolveHnsForTest = { _ in .cached(address: endpoint) }
        b.openHops("hops://no url domain/page")   // the space defeats URL(string:) in dialEndpoint
        settle(b)
        XCTAssertEqual(b.hopsResults["no url domain"], "fetching…", "a cached positive address fires the request")
        XCTAssertEqual(b.nameByAddr[endpoint], "no url domain", "the endpoint is labeled by its resolved domain")
    }

    func testOpenHopsNeedsResolverSetsOfflineError() {
        let b = makeHeadlessBearer()
        b.resolveHnsForTest = { _ in .needsResolver }
        b.openHops("hops://needs-resolver.hop/page")
        settle(b)
        XCTAssertEqual(b.hopsResults["needs-resolver.hop"],
                      "error: offline - no internet or peers to resolve needs-resolver.hop")
    }

    // MARK: hopsFetch via the same seam

    func testHopsFetchCachedNegativeCompletesWith502() {
        let b = makeHeadlessBearer()
        b.resolveHnsForTest = { _ in .cached(address: Data()) }
        let done = expectation(description: "cached negative resolves to a 502")
        b.hopsFetch(domain: "shop.hop", path: "/x") { resp in
            XCTAssertEqual(resp.status, 502)
            XCTAssertTrue(String(data: resp.body, encoding: .utf8)?.contains("shop.hop") ?? false)
            done.fulfill()
        }
        settle(b)
        wait(for: [done], timeout: 2)
    }

    func testHopsFetchCachedPositiveFiresHopsWeb() {
        let b = makeHeadlessBearer()
        let endpoint = Data(repeating: 0x92, count: 32)
        b.resolveHnsForTest = { _ in .cached(address: endpoint) }
        // fireHopsWeb's own completion only fires over a real (nonexistent) mesh round trip or a 30s
        // timeout, so assert its synchronous side effect instead of waiting on the callback.
        b.hopsFetch(domain: "no url web", path: "/x") { _ in }
        settle(b)
        XCTAssertEqual(b.nameByAddr[endpoint], "no url web", "a cached positive address dials the web fetch")
    }

    func testHopsFetchPendingQueuesTheWebCompletion() {
        let b = makeHeadlessBearer()
        b.resolveHnsForTest = { _ in .pending }
        b.hopsFetch(domain: "pending.hop", path: "/y") { _ in }
        settle(b)
        XCTAssertEqual(b.hopsWebPending["pending.hop"]?.count, 1, "the fetch is queued until the HNS record lands")
        XCTAssertEqual(b.hopsWebPending["pending.hop"]?.first?.path, "/y")
    }

    func testHopsFetchNeedsResolverCompletesWith503() {
        let b = makeHeadlessBearer()
        b.resolveHnsForTest = { _ in .needsResolver }
        let done = expectation(description: "needs resolver resolves to a 503")
        b.hopsFetch(domain: "isolated.hop", path: "/") { resp in
            XCTAssertEqual(resp.status, 503)
            done.fulfill()
        }
        settle(b)
        wait(for: [done], timeout: 2)
    }

    // MARK: applyHnsResults positive branches (the fireHops / fireHopsWeb call sites)

    func testApplyHnsResultsPositiveRecordFiresTheTextFetch() {
        let b = makeHeadlessBearer()
        b.pendingHops["no url text"] = "/page"
        b.applyHnsResults([HnsRecord(domain: "no url text", address: Data(repeating: 0x93, count: 32))])
        XCTAssertEqual(b.hopsResults["no url text"], "fetching…", "a positive record fires the queued text-box fetch")
    }

    func testApplyHnsResultsPositiveRecordFiresQueuedWebFetches() {
        let b = makeHeadlessBearer()
        let endpoint = Data(repeating: 0x94, count: 32)
        b.hopsWebPending["no url multi"] = [("/a", { _ in }), ("/b", { _ in })]
        b.applyHnsResults([HnsRecord(domain: "no url multi", address: endpoint)])
        XCTAssertEqual(b.nameByAddr[endpoint], "no url multi", "each queued web fetch dials the resolved endpoint")
    }
}
