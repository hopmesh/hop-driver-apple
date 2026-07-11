// Coverage for the hops:// URL splitter (DESIGN.md §30). parseHops strips the scheme, splits the first
// slash into (domain, path), and defaults an absent/empty path to "/". This is what turns a user-typed
// "hops://acme.hop/page" (or a bare "acme.hop") into the domain the HNS resolver looks up and the path the
// endpoint is asked for. Pure string math, no network, so it is unit-testable headlessly. A slip here
// (e.g. dropping the leading slash or mis-defaulting the path) silently misroutes every hops:// fetch.

import XCTest
import Foundation
@testable import HopDriver

final class HopsUrlParseTests: XCTestCase {

    func testSchemeAndPathAreSplit() {
        let r = HopBearer.parseHops("hops://acme.hop/page")
        XCTAssertEqual(r.domain, "acme.hop")
        XCTAssertEqual(r.path, "/page")
    }

    func testBareDomainDefaultsPathToSlash() {
        let r = HopBearer.parseHops("acme.hop")
        XCTAssertEqual(r.domain, "acme.hop")
        XCTAssertEqual(r.path, "/", "no slash present -> path defaults to root")
    }

    func testSchemeWithNoPathDefaultsToSlash() {
        let r = HopBearer.parseHops("hops://acme.hop")
        XCTAssertEqual(r.domain, "acme.hop")
        XCTAssertEqual(r.path, "/")
    }

    func testTrailingSlashOnlyIsRoot() {
        let r = HopBearer.parseHops("hops://acme.hop/")
        XCTAssertEqual(r.domain, "acme.hop")
        XCTAssertEqual(r.path, "/", "a lone trailing slash is the root path")
    }

    func testDeepPathIsKeptWhole() {
        let r = HopBearer.parseHops("hops://acme.hop/a/b/c?q=1")
        XCTAssertEqual(r.domain, "acme.hop")
        XCTAssertEqual(r.path, "/a/b/c?q=1", "everything from the first slash on is the path")
    }

    func testSurroundingWhitespaceIsTrimmed() {
        let r = HopBearer.parseHops("   hops://acme.hop/page   ")
        XCTAssertEqual(r.domain, "acme.hop")
        XCTAssertEqual(r.path, "/page")
    }

    func testBareDomainWithoutSchemeButWithPath() {
        // A user can omit the scheme and still give a path; the split must still work.
        let r = HopBearer.parseHops("acme.hop/status")
        XCTAssertEqual(r.domain, "acme.hop")
        XCTAssertEqual(r.path, "/status")
    }
}
