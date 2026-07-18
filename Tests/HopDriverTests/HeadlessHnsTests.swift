// HopBearer+Hns.swift coverage (cov/apple-hns). A pass-4 audit found this file at ~59% line coverage
// while the package's AGGREGATE gate stayed green (the other pure-logic files pulled the average up),
// so a regression here could hide behind it indefinitely. openHops/hopsFetch dispatch on the real node's
// `resolveHns` result (.cached / .pending / .needsResolver, DESIGN.md §30); a fresh headless node with no
// peers always settles `resolveHns` to `.pending` when online (hop-core queues a retry and defers - it
// never itself produces `.cached` without a completed well-known fetch), so the real node can never drive
// the cached/needs-resolver branches in a unit test. `resolveHnsForTest`
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
        b.dialEndpointForTest = { _ in 1 }
        b.backgroundTick()
        settle(b)
        b.openHops("hops://no-network.invalid/page")
        settle(b)
        XCTAssertEqual(b.hopsResults["no-network.invalid"], "fetching…", "a cached positive address fires the request")
        XCTAssertEqual(b.nameByAddr[endpoint], "no-network.invalid", "the endpoint is labeled by its resolved domain")
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
        b.dialEndpointForTest = { _ in 1 }
        b.backgroundTick()
        settle(b)
        // fireHopsWeb's own completion only fires over a real (nonexistent) mesh round trip or a 30s
        // timeout, so assert its synchronous side effect instead of waiting on the callback.
        b.hopsFetch(domain: "no-network.invalid", path: "/x") { _ in }
        settle(b)
        XCTAssertEqual(b.nameByAddr[endpoint], "no-network.invalid", "a cached positive address dials the web fetch")
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
        b.dialEndpointForTest = { _ in 1 }
        b.pendingHops["no-network.invalid"] = "/page"
        b.applyHnsResults([HnsRecord(domain: "no-network.invalid", address: Data(repeating: 0x93, count: 32))])
        XCTAssertEqual(b.hopsResults["no-network.invalid"], "fetching…", "a positive record fires the queued text-box fetch")
    }

    func testApplyHnsResultsPositiveRecordFiresQueuedWebFetches() {
        let b = makeHeadlessBearer()
        let endpoint = Data(repeating: 0x94, count: 32)
        b.dialEndpointForTest = { _ in 1 }
        b.hopsWebPending["no-network.invalid"] = [("/a", { _ in }), ("/b", { _ in })]
        b.applyHnsResults([HnsRecord(domain: "no-network.invalid", address: endpoint)])
        XCTAssertEqual(b.nameByAddr[endpoint], "no-network.invalid", "each queued web fetch dials the resolved endpoint")
    }

    // MARK: reachRecord(fromWellKnown:) - the pure /.well-known/hop body parser (§30)

    func testReachRecordParsesBase64ReachField() {
        let raw = Data([0, 1, 2, 3, 250, 251, 252, 253])
        let body = Data("{\"address\":\"abc\",\"endpoint\":\"wss://x/_hop\",\"reach\":\"\(raw.base64EncodedString())\"}".utf8)
        XCTAssertEqual(HopBearer.reachRecord(fromWellKnown: body), raw, "the base64 reach field decodes to the raw record bytes")
    }

    func testReachRecordEmptyOnMissingFieldOrGarbage() {
        XCTAssertTrue(HopBearer.reachRecord(fromWellKnown: nil).isEmpty, "nil body -> empty")
        XCTAssertTrue(HopBearer.reachRecord(fromWellKnown: Data("not json".utf8)).isEmpty, "malformed JSON -> empty")
        XCTAssertTrue(HopBearer.reachRecord(fromWellKnown: Data("{\"address\":\"abc\"}".utf8)).isEmpty, "no reach field -> empty")
        XCTAssertTrue(HopBearer.reachRecord(fromWellKnown: Data("{\"reach\":\"!!! not base64 !!!\"}".utf8)).isEmpty, "bad base64 -> empty")
    }

    func testReachRecordRequiresExactOriginStatusContentTypeAndBounds() {
        let expected = HopBearer.canonicalReachRecordURL(domain: "bound.example")!
        let raw = Data([1, 2, 3])
        let body = Data("{\"reach\":\"\(raw.base64EncodedString())\"}".utf8)
        func response(_ url: URL = expected, _ status: Int = 200,
                      _ headers: [String: String] = ["Content-Type": "application/json"]) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        }

        XCTAssertEqual(HopBearer.validatedReachRecord(data: body, response: response(), expectedURL: expected), raw)
        XCTAssertTrue(HopBearer.validatedReachRecord(data: body, response: response(expected, 201), expectedURL: expected).isEmpty)
        XCTAssertTrue(HopBearer.validatedReachRecord(
            data: body, response: response(expected, 200, ["Content-Type": "text/plain"]), expectedURL: expected
        ).isEmpty)
        XCTAssertTrue(HopBearer.validatedReachRecord(
            data: Data(repeating: 0, count: HopBearer.hnsMaxBodyBytes + 1),
            response: response(), expectedURL: expected
        ).isEmpty)
        XCTAssertTrue(HopBearer.validatedReachRecord(
            data: body,
            response: response(expected, 200, ["Content-Type": "application/json", "X-Large": String(repeating: "x", count: HopBearer.hnsMaxHeaderBytes)]),
            expectedURL: expected
        ).isEmpty)
    }

    func testRedirectResponseFromAnotherOriginCannotBindOriginalDomain() {
        let expected = HopBearer.canonicalReachRecordURL(domain: "bound.example")!
        let redirected = URL(string: "https://evil.example/.well-known/hop")!
        let raw = Data([7, 8, 9])
        let body = Data("{\"reach\":\"\(raw.base64EncodedString())\"}".utf8)
        let response = HTTPURLResponse(
            url: redirected, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        XCTAssertTrue(HopBearer.validatedReachRecord(data: body, response: response, expectedURL: expected).isEmpty)
    }

    func testCanonicalReachURLRejectsCredentialsPortsAndAmbiguousHosts() {
        XCTAssertEqual(HopBearer.canonicalReachRecordURL(domain: "EXAMPLE.HOP")?.absoluteString,
                       "https://example.hop/.well-known/hop")
        for domain in ["user@host.hop", "host.hop:443", "host.hop.", "host\\evil.hop", "a..hop"] {
            XCTAssertNil(HopBearer.canonicalReachRecordURL(domain: domain), domain)
        }
    }
}
