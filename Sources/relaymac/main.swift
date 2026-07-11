// relaymac - a headless macOS Hop client that drives the HopDriver runtime in RELAY-ONLY mode
// (`role: .relayOnly`): it connects ONLY the cloud relay - NO BLE (no advertise/scan), no LAN, no
// Wi-Fi - so it never appears on Bluetooth and the ONLY path to a peer is the relay. Used to test
// the relay routing path in isolation (it stands in for a remote sender): it sends a §39 PRIVATE
// message to a target address over the relay and reports whether it routes + Delivers.
//
//   swift run relaymac <base58-target-address>
import Foundation
import HopDriver

func log(_ s: String) {
    let t = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100000)
    print("[\(String(format: "%.1f", t))] \(s)")
}
setvbuf(stdout, nil, _IONBF, 0)

let target = CommandLine.arguments.dropFirst().first ?? "qwZi1GToZBJSJpggAD4Rr2cp6ibqXR4QqedKayvPzxe"
let marker = "relayonly-\(Int(Date().timeIntervalSince1970) % 100000)"

let config = HopBearer.Config(
    dbPath: NSTemporaryDirectory() + "relaymac-\(UUID().uuidString).db",
    deviceSeed: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
    appSecret: HopBearer.appSecret,
    displayName: "MacRelayOnly",
    defaultRelay: HopBearer.defaultRelay,   // wss://relay.hopme.sh/
    role: .relayOnly)                       // relay and NOTHING else - no BLE/LAN/Wi-Fi (role-enforced)

let bearer = HopBearer(config: config)
bearer.start(name: "MacRelayOnly")          // also publishes our prekey (so the private ACK can seal back)
log("relay-only client up - addr \(bearer.myAddress.prefix(8)) → target \(target.prefix(8)) marker=\(marker)")

var sent = false
var ticks = 0
Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
    ticks += 1
    let rs = bearer.relayStatus
    if rs.contains("connected") && !sent {
        sent = true
        bearer.sendTo(addressBase58: target, text: marker)
        log("sent PRIVATE '\(marker)' to \(target.prefix(8)) over the relay")
    }
    let mine = bearer.messages.first { !$0.incoming && $0.text == marker }
    let delivered = mine?.delivered ?? false
    for m in bearer.messages where m.incoming {
        log("RX from \(m.peer) [\(m.contentType)] hops=\(m.hops): \(m.text)")
    }
    if ticks % 3 == 0 {
        log("status: relay=\(rs) reachable=\(bearer.reachable.count) secured=\(bearer.secured.count) delivered=\(delivered)")
    }
    if delivered { log("DELIVERED - relay→device routing works (P4)"); exit(0) }
}
RunLoop.main.run()
