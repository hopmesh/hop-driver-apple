import Foundation
import HopFFIBindings

// The driver's UI value types, grouped out of the HopBearer class body so the class file is the runtime
// (node seam + lifecycle + @Published state + composition) and the models live on their own. These stay
// NESTED on HopBearer (declared in an extension) so every existing reference (`HopBearer.Peer`,
// `HopBearer.Message`, `HopBearer.HpsTopic`, … in the app + tests) is unchanged. Pure value semantics,
// no behavior.
extension HopBearer {

    public enum SendResult: Equatable { case queued, invalid, overloaded }

    /// A discovered/known peer. Identity is the 32-byte address, NOT the name, so a rename (identify /
    /// presence update) does not churn SwiftUI list diffing / navigation.
    public struct Peer: Identifiable, Hashable {
        public let address: Data; public let name: String; public var hops: UInt8
        public var active: Bool = true       // peer's app foreground (vs backgrounded)
        public var platform: String = ""     // "ios" / "android"
        public var app: String = ""          // the app embedding Hop on that device
        public var id: Data { address }
        // Identity is the address - metadata updates don't churn navigation.
        public static func == (l: Peer, r: Peer) -> Bool { l.address == r.address }
        public func hash(into h: inout Hasher) { h.combine(address) }
    }

    /// One chat message bubble (incoming or outgoing) with its render + delivery-tracking metadata.
    public struct Message: Identifiable {
        public let id = UUID()
        public let peer: String; public let text: String; public let incoming: Bool
        public var peerAddr: Data? = nil   // the other party's address - stable across renames
        public var contentType: String = "text/plain"
        public var imageData: Data? = nil  // raw bytes for a single-image message (content_type image/*)
        public var images: [Data] = []     // one or more images (a multipart/mixed message)
        public var bundleId: Data? = nil
        public var inboxId: Data? = nil    // stable incoming id, persisted before core acceptance
        // Incoming metadata (shown under the bubble).
        public var hops: UInt8 = 0
        public var latencyMs: UInt64? = nil      // received time − sender's send time
        public var trace: [TraceHopInfo] = []    // each forwarding hop, resolved at render (§27)
        // Outgoing delivery tracking.
        public var sentAt: Date = Date()
        public var deliveredAt: Date? = nil
        public var relayed: UInt32 = 0
        public var delivered: Bool = false
        public var deliveryHops: UInt8 = 0
        public var deliveryMs: UInt32 = 0   // forward-path (A→B) latency the recipient reported, ms
        public var failed: Bool = false   // gave up (e.g. the queue was cleared before it sent)
    }

    /// One row of the node's send/relay queue (debug view).
    public struct QueueRow: Identifiable {
        public let id: Data; public let own: Bool; public let to: String; public let priority: UInt8; public let hops: UInt8
    }

    /// Per-bearer status (all transports run at once).
    public struct TransportStatus: Identifiable, Hashable {
        public let id: String      // "Bluetooth" / "Wi-Fi"
        public let active: Bool    // radio up + bearer running
        public let links: Int      // live links on this transport
    }

    /// One HNS cache entry for the debug view: domain → address, with remaining TTL (seconds).
    public struct HnsCacheRow: Identifiable {
        public var id: String { domain }
        public let domain: String
        public let address: Data    // empty = a cached negative (no such endpoint)
        public let ttl: UInt32      // remaining lifetime, ticking down to expiry
    }

    /// An hps:// topic we host (`hosting`) or follow (`subscribed`), keyed by host+path.
    public struct HpsTopic: Identifiable {
        public var id: String { "\(HopBearer.base58(host))/\(path)" }
        public let host: Data        // the node that hosts the topic (us, if hosting)
        public let path: String
        public let isChannel: Bool   // channel (anyone writes) vs service (only owner broadcasts)
        public let hosting: Bool     // true = we registered it; false = we subscribed to it
        public var access: HpsAccess = .open   // key-handoff policy (for topics we host)
        /// Whether we can post: a channel (anyone), or a service we host.
        public var writable: Bool { isChannel || hosting }
    }

    /// One received hps:// message, decrypted + sender-verified (§32).
    public struct HpsMsgRow: Identifiable, Codable {
        public var id: UUID
        public let path: String
        public let sender: Data
        public let text: String
        public let at: UInt64
        public let inboxId: Data?

        public init(id: UUID = UUID(), path: String, sender: Data, text: String, at: UInt64,
                    inboxId: Data? = nil) {
            self.id = id
            self.path = path
            self.sender = sender
            self.text = text
            self.at = at
            self.inboxId = inboxId
        }
    }

    /// apple-10: a snapshot of a hosted topic's reach + pending join-requests + members, fetched OFF
    /// the SwiftUI render path. The three underlying node reads run once on the core queue and the
    /// result is delivered on main, so the channel-info sheet never does a `core.sync` inside its body
    /// (which blocked the main thread behind the packet drain and re-created the 0x8BADF00D class of
    /// stall under core congestion). Callers hold the result in @State and re-fetch on appear / after
    /// a mutating action.
    public struct HpsHostSnapshot: Equatable {
        public var reach: Int = 0
        public var pending: [Data] = []
        public var members: [Data] = []
        // Swift's synthesized memberwise init is internal even on a public struct, so the app module
        // (ContentView, apple-10 off-core-queue snapshot) could not construct it. Expose a public one.
        public init(reach: Int = 0, pending: [Data] = [], members: [Data] = []) {
            self.reach = reach
            self.pending = pending
            self.members = members
        }
    }

    /// One hops:// HTTP response handed to the WebView's scheme handler.
    public struct HopResponse {
        public let status: Int
        public let contentType: String
        public let body: Data
    }
}
