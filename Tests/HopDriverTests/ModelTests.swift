// Value-semantics coverage for the driver's UI models. These are the invariants SwiftUI relies on:
//
//   • Peer identity is the 32-byte address, NOT the name, so a rename (identify/presence update) does
//     not churn list diffing / navigation (the comment on Peer.== spells this out). Equality + hashing
//     must key on address only.
//   • HpsTopic.writable gates the compose box: a channel (anyone writes) or a service we host.
//   • HpsMsgRow is Codable (it is persisted to channels.json), so it must round-trip losslessly.
//
// All pure value types, no node/radio, so they run headlessly on macOS.

import XCTest
import Foundation
@testable import HopDriver

final class ModelTests: XCTestCase {

    private func addr(_ b: UInt8) -> Data { Data(repeating: b, count: 32) }

    // MARK: Peer. Identity is the address; name/metadata do not affect equality or hashing.

    func testPeersWithSameAddressAreEqualRegardlessOfName() {
        let a = HopBearer.Peer(address: addr(0x01), name: "Alice", hops: 0)
        let b = HopBearer.Peer(address: addr(0x01), name: "Alice (renamed)", hops: 3, active: false,
                               platform: "android", app: "Other")
        XCTAssertEqual(a, b, "same address -> same peer, even after a rename or metadata change")
        XCTAssertEqual(a.hashValue, b.hashValue, "equal peers must hash equal (Set/Dictionary key stability)")
    }

    func testPeersWithDifferentAddressesDiffer() {
        let a = HopBearer.Peer(address: addr(0x01), name: "Same", hops: 0)
        let b = HopBearer.Peer(address: addr(0x02), name: "Same", hops: 0)
        XCTAssertNotEqual(a, b, "different address -> different peer even with the same name")
    }

    func testPeerIdIsItsAddress() {
        let p = HopBearer.Peer(address: addr(0x07), name: "n", hops: 1)
        XCTAssertEqual(p.id, addr(0x07), "Identifiable id is the raw address")
    }

    func testPeerDedupesByAddressInASet() {
        // A Set keyed on Peer must collapse two sightings of one address (different names/hops) to one.
        let set: Set<HopBearer.Peer> = [
            HopBearer.Peer(address: addr(0x09), name: "first", hops: 0),
            HopBearer.Peer(address: addr(0x09), name: "second", hops: 2),
            HopBearer.Peer(address: addr(0x0A), name: "other", hops: 0),
        ]
        XCTAssertEqual(set.count, 2, "one entry per distinct address")
    }

    // MARK: HpsTopic.writable. Channel OR a service we host.

    func testChannelIsAlwaysWritable() {
        let t = HopBearer.HpsTopic(host: addr(0x01), path: "chat", isChannel: true, hosting: false)
        XCTAssertTrue(t.writable, "a channel is writable by anyone")
    }

    func testHostedServiceIsWritable() {
        let t = HopBearer.HpsTopic(host: addr(0x01), path: "svc", isChannel: false, hosting: true)
        XCTAssertTrue(t.writable, "a service we host is writable by us")
    }

    func testSubscribedServiceIsNotWritable() {
        let t = HopBearer.HpsTopic(host: addr(0x01), path: "svc", isChannel: false, hosting: false)
        XCTAssertFalse(t.writable, "a service we only follow is read-only")
    }

    // MARK: HpsMsgRow. Codable round-trip (persisted to channels.json).

    func testHpsMsgRowCodableRoundTrip() throws {
        let row = HopBearer.HpsMsgRow(path: "room/1", sender: addr(0x22), text: "gm", at: 1_725_000_000_000)
        let data = try JSONEncoder().encode(row)
        let back = try JSONDecoder().decode(HopBearer.HpsMsgRow.self, from: data)
        XCTAssertEqual(back.path, "room/1")
        XCTAssertEqual(back.sender, addr(0x22))
        XCTAssertEqual(back.text, "gm")
        XCTAssertEqual(back.at, 1_725_000_000_000)
    }
}
