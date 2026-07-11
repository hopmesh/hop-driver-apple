// Pure display-formatting coverage for the Apple driver (apple-driver was ~5%/F). These are the
// device-independent label helpers the UI renders on every peer row, message bubble, and trace hop:
// compact elapsed-time (3s/5m/2h/4d), the hops label ("direct" vs "N hops"), the raw-bytes hex helper,
// and the short base58 display prefix. None of them touch the node, a radio, or the clock (compactDuration
// takes an explicit ms), so they run headlessly on macOS. A silent change to any of these formats is a
// visible UI regression; these tests pin the exact strings.

import XCTest
import Foundation
@testable import HopDriver

final class FormattingTests: XCTestCase {

    // MARK: compactDuration. The ladder is s -> m -> h -> d, each unit only until the next fills.

    func testCompactDurationSeconds() {
        XCTAssertEqual(HopBearer.compactDuration(0), "0s")
        XCTAssertEqual(HopBearer.compactDuration(3_000), "3s")
        XCTAssertEqual(HopBearer.compactDuration(59_000), "59s", "just under a minute is still seconds")
    }

    func testCompactDurationMinutes() {
        XCTAssertEqual(HopBearer.compactDuration(60_000), "1m", "exactly 60s rolls to minutes")
        XCTAssertEqual(HopBearer.compactDuration(90_000), "1m", "truncates, does not round")
        XCTAssertEqual(HopBearer.compactDuration(3_540_000), "59m", "just under an hour is still minutes")
    }

    func testCompactDurationHours() {
        XCTAssertEqual(HopBearer.compactDuration(3_600_000), "1h", "exactly 60m rolls to hours")
        XCTAssertEqual(HopBearer.compactDuration(86_340_000), "23h", "just under a day is still hours")
    }

    func testCompactDurationDays() {
        XCTAssertEqual(HopBearer.compactDuration(86_400_000), "1d", "exactly 24h rolls to days")
        XCTAssertEqual(HopBearer.compactDuration(4 * 86_400_000), "4d")
    }

    // MARK: hopsLabel. 0/1 links to the destination read as "direct"; >=2 shows the count.

    func testHopsLabelDirectForZeroAndOne() {
        XCTAssertEqual(HopBearer.hopsLabel(0), "direct", "no relay is direct")
        XCTAssertEqual(HopBearer.hopsLabel(1), "direct", "a single link is still direct")
    }

    func testHopsLabelCountsFromTwo() {
        XCTAssertEqual(HopBearer.hopsLabel(2), "2 hops")
        XCTAssertEqual(HopBearer.hopsLabel(9), "9 hops")
        XCTAssertEqual(HopBearer.hopsLabel(255), "255 hops", "the UInt8 ceiling still formats")
    }

    // MARK: hex. Lowercase, zero-padded, one byte -> two chars, in order.

    func testHexIsLowercaseZeroPaddedBigEndianOrder() {
        XCTAssertEqual(HopBearer.hex(Data([0x00, 0x0f, 0xff])), "000fff")
        XCTAssertEqual(HopBearer.hex(Data([0xde, 0xad, 0xbe, 0xef])), "deadbeef")
    }

    func testHexOfEmptyIsEmpty() {
        XCTAssertEqual(HopBearer.hex(Data()), "")
    }

    // MARK: shortHex. The 8-char base58 display prefix (exercises the FFI base58 + the prefix cut).

    func testShortHexIsEightBase58Chars() {
        // A full 32-byte address base58-encodes to well over 8 chars, so the prefix is exactly 8.
        let addr = Data((0..<32).map { UInt8($0) })
        let short = HopBearer.shortHex(addr)
        XCTAssertEqual(short.count, 8, "the peer-row short id is an 8-char base58 prefix")
        // It must be a stable prefix of the full base58 form, not some other encoding.
        XCTAssertTrue(HopBearer.base58(addr).hasPrefix(short))
    }
}
