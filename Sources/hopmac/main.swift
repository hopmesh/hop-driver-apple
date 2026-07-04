// hopmac — a headless macOS Hop node that drives the HopDriver runtime in BLE-central-only mode,
// for testing cross-platform BLE end-to-end from a controllable Mac instead of debugging iPhones.
//
// It runs the REAL hop-core (via the HopDriver package) and the SAME bearer the iOS app uses — just
// configured `.centralOnly`: BLE central scanning + the node, no advertising / Wi-Fi / LAN / relay /
// beacon. It connects to Hop peripherals over L2CAP exactly like the app's central path, then sends a
// test message to each peer it reaches and prints anything received.
import Foundation
import HopDriver

func hex(_ d: Data) -> String { d.prefix(6).map { String(format: "%02x", $0) }.joined() }
func log(_ s: String) {
    let t = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100000)
    print("[\(String(format: "%.1f", t))] \(s)")
}

setvbuf(stdout, nil, _IONBF, 0)   // unbuffered so logs flush immediately (even under `timeout`)

// A fresh random identity + temp db every run; the dev app secret ("H"×32) so we interoperate with
// the HopDemo dev builds. No relay, central-only role: `role: .centralOnly` makes the shared path
// register BLE only and suppress advertising (scan/dial but stay undiscoverable), which is exactly
// hopmac's documented behavior now that the legacy in-driver central path is gone.
let config = HopBearer.Config(
    dbPath: NSTemporaryDirectory() + "hopmac-\(UUID().uuidString).db",
    deviceSeed: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
    appSecret: HopBearer.appSecret,
    displayName: "MacHopTest",
    defaultRelay: nil,
    role: .centralOnly)

let bearer = HopBearer(config: config)
bearer.start(name: "MacHopTest")
log("hopmac started (central-only) — address \(bearer.myAddress.prefix(8)); Ctrl-C to quit")

// Message each peer we reach once, and surface incoming messages + link state.
var sentTo = Set<Data>()
var printedMsgs = Set<UUID>()
var ticks = 0
Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
    ticks += 1
    for peer in bearer.reachable where !sentTo.contains(peer.address) {
        sentTo.insert(peer.address)
        bearer.send("hello from MacHopTest over BLE", to: peer)
        log("➡️  sent to \(peer.name) \(hex(peer.address)) secured=\(bearer.secured.contains(peer.address))")
    }
    for m in bearer.messages where m.incoming && !printedMsgs.contains(m.id) {
        printedMsgs.insert(m.id)
        log("📥 RX from \(m.peer) [\(m.contentType)] hops=\(m.hops): \(m.text)")
    }
    if ticks % 5 == 0 {
        log("status: reachable=\(bearer.reachable.count) secured=\(bearer.secured.count)")
    }
}

RunLoop.main.run()
