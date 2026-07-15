<p align="center">
  <img alt="Hop" src="https://hopme.sh/hop-mark.svg" width="200">
</p>

<h1 align="center">HopDriver</h1>

<p align="center">
  <b>The Apple client for Hop: a node, every bearer, storage, and a clean send/receive API in one package.</b><br>
  Embed one thing and your iOS or macOS app is a full mesh peer.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-5.9-F05138" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/platforms-iOS%2016%20%C2%B7%20macOS%2013-1f6feb" alt="iOS 16 · macOS 13">
  <img src="https://img.shields.io/badge/license-Apache--2.0-3ddc84" alt="license Apache-2.0">
</p>

---

Hop is a **delay-tolerant, end-to-end-encrypted mesh**: messages hop device to device over BLE, Wi-Fi,
and the internet until they reach the person or service you meant. Held, never dropped.

**HopDriver is the app-facing client.** It owns a `hop-core` node, wires up the BLE, LAN, and cloud-relay
bearers, persists chat and identity, and exposes an `ObservableObject` with `send`, `addContact`, and
published `messages` / `reachable`, so a SwiftUI app binds one object instead of stitching a node,
radios, and a store together itself.

## Install

Add the package with Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/hopmesh/hop-driver-apple.git", branch: "main"),
]
```

Depend on the `HopDriver` product. It pulls the Rust core (packaged as an xcframework) and the bearer
packages transitively; you don't wire those up.

## Usage

```swift
import HopDriver

let hop = HopBearer(config: .init(
    dbPath: NSHomeDirectory() + "/Documents/hop.db",
    deviceSeed: IdentityStore.deviceSeed(),   // 32-byte identity seed, kept in the Keychain
    appSecret: HopBearer.appSecret,           // scopes who can see whom
    displayName: "Jason's iPhone",
    defaultRelay: HopBearer.defaultRelay      // wss://relay.hopme.sh/
))

hop.start(name: "Jason's iPhone")             // brings up the node + every bearer

// address someone by their base58 address, or by a peer you've discovered
_ = hop.addContact(name: "Ada", address: "3Qm…")
hop.send("ping", to: peer)                    // forward-secret, delivered when they're reachable
```

`HopBearer` is an `ObservableObject`, so SwiftUI reads its state directly:

```swift
struct Inbox: View {
    @ObservedObject var hop: HopBearer
    var body: some View {
        List(hop.reachable, id: \.address) { peer in
            Text(peer.name)
        }
        // hop.messages, hop.secured, hop.transports, hop.unread are all @Published too
    }
}
```

## What it owns

One `HopBearer` composes the whole stack so your app doesn't:

- **The node.** A `hop-core` node over the C ABI (the same `libhop` every Hop SDK binds), funneled
  through a single serial queue because the node isn't thread-safe.
- **The bearers.** BLE (GATT + L2CAP + background wake), LAN (mDNS + TCP), and the cloud relay, all
  running at once through the `BearerManager`, plus Wi-Fi P2P and directly dialed `hops://` endpoints.
- **Storage.** Chat history and contacts in `hop.db`, encrypted at rest via SQLCipher when `libhop` is
  built with it; the identity seed and db key live in the Keychain (Secure Enclave wrapped where present).
- **The surface.** Text, images, and multipart send; contacts; HNS name resolution; the HPS channel/topic
  layer; and per-peer transport and delivery state, all as plain published values.

## Send and receive

| You call                              | What happens                                              |
| ------------------------------------- | --------------------------------------------------------- |
| `hop.send(_:to:)`                     | forward-secret text to a peer, queued until deliverable   |
| `hop.sendTo(addressBase58:text:)`     | send by raw address, no prior contact                     |
| `hop.sendImage(_:to:)` / `sendMultipart` | image and mixed text+image messages                    |
| `hop.addContact(name:address:)`       | pin a base58 address under a name                         |
| `hop.setName(_:)`                     | change your advertised display name                       |
| `hop.messages` (published)            | the live conversation, incoming and outgoing              |

Device-to-device content is always forward-secret (Double Ratchet); a send without a live session is a
bug, never a static seal.

## Beyond the app

The package also ships two headless macOS executables that drive the same driver: `hopmac` (a
BLE-central test node) and `relaymac` (a relay-only client), used to reproduce mesh behavior off-device.

## Status

Prototype, and the furthest-along path: cross-platform device-to-device delivery is verified on real
hardware (Android to iOS in a few seconds, with a crypto delivery ACK), and identities survive a
reinstall. The app-facing logic is unit-tested headlessly behind a node seam; the device and thread
bound layers (the BLE radio, the L2CAP runloop, the Keychain) are excluded from the coverage
denominator and covered by the on-device workflow.

## The Hop family

Hop is one protocol with many faces. The endpoint SDKs, same surface in your language:
[node](https://github.com/hopmesh/hop-sdk-node) ·
[python](https://github.com/hopmesh/hop-sdk-python) ·
[go](https://github.com/hopmesh/hop-sdk-go) ·
[ruby](https://github.com/hopmesh/hop-sdk-ruby) ·
[crystal](https://github.com/hopmesh/hop-sdk-crystal) ·
[elixir](https://github.com/hopmesh/hop-sdk-elixir) ·
[apple](https://github.com/hopmesh/hop-sdk-apple) ·
[android](https://github.com/hopmesh/hop-sdk-android).
The protocol core is [hop-core](https://github.com/hopmesh/hop-core) / [libhop](https://github.com/hopmesh/libhop).

## License

[Apache-2.0](./LICENSE.md), use it freely. Only the protocol core (`hop-core`) is FSL-1.1-ALv2,
source-available and converting to Apache-2.0 after two years.
