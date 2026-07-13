// Shared harness for the headless-node integration suite (cov/apple-driver). The driver's biggest file
// (HopBearer.swift) was ~12.8% covered because the node-driving + snapshot-mapping + persistence surface
// was never exercised without a device. BackgroundFlushTests proved a real (headless) libhop `HopNode` is
// instantiable on macOS from a temp db, so these tests drive the PUBLIC API against that real node and
// call the internal snapshot-mapping helpers directly with constructed FFI records. No radio, no UIKit:
// every bearer is built `.centralOnly`/`.relayOnly` (isFull=false) and `start()` is only ever called in
// the relay-only + no-relay configuration that registers zero bearers, so no CoreBluetooth / Multipeer /
// WebSocket / well-known I/O is ever touched. The genuinely device/radio-bound surface lives in
// HopBearer+Radios.swift (and HopLink.swift) and is excluded from the coverage denominator.

import XCTest
import Foundation
@testable import HopDriver

extension XCTestCase {

    /// A headless `HopBearer` over a fresh temp db + plain (no-SQLCipher) store, with NO radio. Distinct
    /// `seed` ⇒ distinct node address. `.centralOnly` keeps `isFull` false (so the notification / app-badge
    /// paths short-circuit), and callers never invoke `start()` unless they pass `.relayOnly` + no relay.
    func makeHeadlessBearer(seed: UInt8 = 0x11, role: HopBearer.Role = .centralOnly,
                            relay: String? = nil, name: String = "hl") -> HopBearer {
        let db = FileManager.default.temporaryDirectory
            .appendingPathComponent("hop-hl-\(UUID().uuidString).db").path
        return HopBearer(config: .init(
            dbPath: db,
            deviceSeed: Data(repeating: seed, count: 32),
            appSecret: Data(repeating: 0x48, count: 32),
            displayName: name,
            defaultRelay: relay,
            role: role,
            dbKey: Data()))   // plain store - headless test, no key material needed
    }

    /// Drain queued node work (`core` is serial, so a `sync {}` is a barrier) plus the main-queue
    /// callbacks the node's `pump`/`refresh` re-dispatch back, so async round-trips settle deterministically
    /// before assertions. XCTest runs on the main thread, so `RunLoop.current` is the main runloop.
    func settle(_ b: HopBearer, rounds: Int = 8) {
        for _ in 0..<rounds {
            b.core.sync {}
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// A valid 32-byte address filled with `seed`, and its base58 form - a foreign target for
    /// sends/contacts/subscribes. The app-side guards only check length + "not me"; the node defers a
    /// send to any address, so a synthetic one drives every app path without a second live node.
    func foreignAddr(_ seed: UInt8 = 0x33) -> Data { Data(repeating: seed, count: 32) }
    func base58(_ d: Data) -> String { addressBase58(address: d) }
}
