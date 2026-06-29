// HopDriver — the thin platform glue that composes the whole transport stack for an Apple host.
//
// It makes a Hop node (over libhop's C ABI, via the Hop SDK), a HopRuntime, registers the bearer
// packages the build wants, and runs a pump loop that ferries the node's outbound bytes to the radios
// and advances the clock. It contains NO transport code and NO beacon code — every radio (including
// the BLE iBeacon/CoreLocation wake) lives in its own bearer package. The app owns identity/db config
// and the UI; this owns only the node+bearer wiring.

import Foundation
import Hop
import HopContract
import HopBearerBle
import HopBearerLan
import HopBearerMultipeer
import HopBearerRelay

public final class HopDriver {
    public let runtime: HopRuntime
    /// One transport-layer id shared by every bearer (the BLE/LAN HELLO id + the dedup tiebreaker) —
    /// distinct from the Hop node address.
    private let bearerId = randomNodeId()
    private var pumpTimer: Timer?

    public struct Config {
        public var dbPath: String
        public var secret: Data
        public var appSecret: Data
        public var relayURL: String?
        public var enableBle: Bool
        public var enableLan: Bool
        public var enableMultipeer: Bool

        public init(dbPath: String, secret: Data = Data(), appSecret: Data = Data(),
                    relayURL: String? = nil, enableBle: Bool = true, enableLan: Bool = true,
                    enableMultipeer: Bool = true) {
            self.dbPath = dbPath; self.secret = secret; self.appSecret = appSecret
            self.relayURL = relayURL
            self.enableBle = enableBle; self.enableLan = enableLan; self.enableMultipeer = enableMultipeer
        }
    }

    public init(config: Config) {
        let node = HopNode.open(dbPath: config.dbPath, secret: config.secret, appSecret: config.appSecret)
            ?? .ephemeral()
        runtime = HopRuntime(node: node)
        // Register only the transports this build wants — each is an isolated package.
        if config.enableBle { runtime.register(BleBearer(myId: bearerId)) }
        if config.enableLan { runtime.register(LanBearer(myId: bearerId)) }
        if config.enableMultipeer { runtime.register(MultipeerBearer(myId: bearerId)) }
        if let relay = config.relayURL { runtime.register(RelayBearer(relayURL: relay)) }
    }

    /// The node, for messaging (send/inbox/hops://) and identity.
    public var node: HopNode { runtime.node }

    /// Start the bearers + a ~10 Hz pump that advances the clock and drains the node to the radios.
    /// On iOS the host should set `HopBearerBle.bleQueue` / `bleRunLoop` BEFORE calling this (iOS 18
    /// drops CB callbacks on the main queue). The bearer owns its own beacon/wake.
    public func start() {
        runtime.start()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.runtime.tick(nowMs: nowMs())
            self.runtime.pump()
        }
        RunLoop.main.add(t, forMode: .common)
        pumpTimer = t
    }

    public func stop() {
        pumpTimer?.invalidate(); pumpTimer = nil
        runtime.stop()
    }
}
