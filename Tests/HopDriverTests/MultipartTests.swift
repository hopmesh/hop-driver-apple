// Wire-format coverage for the driver's multipart/mixed codec (DESIGN.md §20). One text-and/or-images
// message is packed into ONE sealed body as `[u32 partCount][ per part: u16 ctLen, ct, u32 bodyLen, body ]`
// and the far side (Android or iOS) reassembles it. The format is SHARED with Android, so a silent
// endianness or field-order slip here would break cross-platform image messages. encodeMultipart /
// decodeMultipart are pure byte math (no node, no radio), so the round-trip + the truncation guards run
// headlessly. These pin the exact bytes and the decoder's partial-input safety.

import XCTest
import Foundation
@testable import HopDriver

final class MultipartTests: XCTestCase {

    private func parts(_ decoded: [(String, Data)]) -> [(String, Data)] { decoded }

    // MARK: round-trip.

    func testTextOnlyRoundTrips() {
        let input: [(String, Data)] = [("text/plain", Data("hello".utf8))]
        let out = HopBearer.decodeMultipart(HopBearer.encodeMultipart(input))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].0, "text/plain")
        XCTAssertEqual(out[0].1, Data("hello".utf8))
    }

    func testTextPlusMultipleImagesRoundTripsInOrder() {
        let img1 = Data([0xFF, 0xD8, 0x01, 0x02])
        let img2 = Data([0xFF, 0xD8, 0x03, 0x04, 0x05])
        let input: [(String, Data)] = [("text/plain", Data("caption".utf8)),
                                       ("image/jpeg", img1), ("image/jpeg", img2)]
        let out = HopBearer.decodeMultipart(HopBearer.encodeMultipart(input))
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out.map { $0.0 }, ["text/plain", "image/jpeg", "image/jpeg"])
        XCTAssertEqual(out[0].1, Data("caption".utf8))
        XCTAssertEqual(out[1].1, img1)
        XCTAssertEqual(out[2].1, img2, "parts come back in encode order")
    }

    func testEmptyPartListRoundTripsToEmpty() {
        let out = HopBearer.decodeMultipart(HopBearer.encodeMultipart([]))
        XCTAssertTrue(out.isEmpty)
    }

    func testEmptyBodyPartPreservesZeroLength() {
        // A zero-length body part (e.g. an empty text segment) must survive the round-trip as empty, not
        // get dropped or mis-lengthed.
        let input: [(String, Data)] = [("text/plain", Data()), ("image/jpeg", Data([0xAB]))]
        let out = HopBearer.decodeMultipart(HopBearer.encodeMultipart(input))
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].1.count, 0)
        XCTAssertEqual(out[1].1, Data([0xAB]))
    }

    func testUnicodeContentTypeAndBodyRoundTrip() {
        // ct + body are length-delimited bytes, so UTF-8 multibyte content survives verbatim.
        let input: [(String, Data)] = [("text/plain; charset=utf-8", Data("héllo · 世界".utf8))]
        let out = HopBearer.decodeMultipart(HopBearer.encodeMultipart(input))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].0, "text/plain; charset=utf-8")
        XCTAssertEqual(String(data: out[0].1, encoding: .utf8), "héllo · 世界")
    }

    // MARK: exact wire bytes (the format shared with Android).

    func testEncodedPrefixIsBigEndianPartCount() {
        let data = HopBearer.encodeMultipart([("a", Data([0x00])), ("b", Data([0x01]))])
        // First 4 bytes = part count (2), big-endian.
        XCTAssertEqual(Array(data.prefix(4)), [0x00, 0x00, 0x00, 0x02])
    }

    func testEncodedFieldLayoutForOnePart() {
        // One part: [u32 count=1][u16 ctLen=1]["x"][u32 bodyLen=2][0xAA,0xBB].
        let data = HopBearer.encodeMultipart([("x", Data([0xAA, 0xBB]))])
        XCTAssertEqual(Array(data), [0x00, 0x00, 0x00, 0x01,   // count
                                     0x00, 0x01,               // ctLen
                                     0x78,                     // "x"
                                     0x00, 0x00, 0x00, 0x02,   // bodyLen
                                     0xAA, 0xBB])              // body
    }

    // MARK: decoder safety on truncated / malformed input (a hostile or clipped payload must not crash).

    func testDecodeEmptyDataIsEmpty() {
        XCTAssertTrue(HopBearer.decodeMultipart(Data()).isEmpty, "no count header -> no parts, no crash")
    }

    func testDecodeTruncatedAfterCountYieldsNoParts() {
        // Claims 5 parts but supplies no part bytes: the decoder must break cleanly, not over-read.
        let data = Data([0x00, 0x00, 0x00, 0x05])
        XCTAssertTrue(HopBearer.decodeMultipart(data).isEmpty)
    }

    func testDecodeTruncatedMidBodyRejectsTheWholePayload() {
        let good = HopBearer.encodeMultipart([("a", Data([0x01])), ("b", Data([0x02]))])
        var mutated = good
        // Append a malformed 3rd-part header claiming a huge body with no bytes behind it, and bump count.
        mutated[0] = 0; mutated[1] = 0; mutated[2] = 0; mutated[3] = 3   // count now says 3
        mutated.append(contentsOf: [0x00, 0x01, 0x63])                  // ctLen=1, "c"
        mutated.append(contentsOf: [0x7F, 0xFF, 0xFF, 0xFF])            // bodyLen ~2GiB, absent
        let out = HopBearer.decodeMultipart(mutated)
        XCTAssertTrue(out.isEmpty, "attacker-controlled multipart never yields partial success")
    }
}
