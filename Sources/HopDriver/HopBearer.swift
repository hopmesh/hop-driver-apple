import Foundation
import CoreBluetooth
import MultipeerConnectivity
import Network
import UserNotifications
import CryptoKit
import HopObjC
// The shared cross-platform transport layer (sibling SwiftPM package). Core = Bearer/LinkSink contract
// + BearerManager registry + randomNodeId/log; Ble/Lan/Relay = the proven clean-room bearers. The
// driver forms BLE + LAN + cloud-relay links through these (one BearerManager, role-aware).
import HopContract
import HopBearerBle
import HopBearerLan
import HopBearerRelay
// Re-export the generated FFI types (HopNode records like HpsTopicInfo, HpsAccess, TraceHopInfo…)
// so a host that imports HopDriver sees them without importing HopFFIBindings directly.
@_exported import HopFFIBindings
#if canImport(UIKit)
import UIKit
#endif

/// The Hop identity secret is derived **deterministically from the device's vendor
/// id** — so the keypair (and thus the address) is identical every launch *by
/// construction*, with no dependency on Keychain/file storage (which proved
/// unreliable on dev-installed builds, wiping the address on reinstall). The secret
/// is the keypair is the address; re-deriving the same seed keeps the node routeable.
/// `note` is shown in the UI for transparency.
public enum IdentityStore {
    public static var note = "init"

    /// A 32-byte Ed25519 seed from the vendor id (stable across launches/reinstall,
    /// until every app from this vendor is removed).
    public static func deviceSeed() -> Data {
        #if canImport(UIKit)
        let vid = UIDevice.current.identifierForVendor?.uuidString
        #else
        let vid: String? = nil
        #endif
        note = vid != nil ? "device-derived" : "random (no vendor id)"
        let basis = vid ?? UUID().uuidString
        return Data(SHA256.hash(data: Data("hop.identity.v1|\(basis)".utf8)))
    }

    /// The 32-byte SQLCipher key for the on-device `hop.db` (F-25). Derived from the SAME vendor-id
    /// basis as the identity, but domain-separated, so it is: (a) stable every launch with no storage
    /// to fail, (b) tied to identity lifetime — a full vendor reinstall resets identity AND the db key
    /// together (a fresh install starts clean either way), and (c) NOT present in the db file, so a
    /// pulled/backed-up `hop.db` is useless without the device. A random key in the Secure Enclave /
    /// Keychain is the stronger upgrade; it's avoided here for the same reinstall-wipe reliability
    /// reason the identity seed avoids Keychain. Only active when libhop is built `--features sqlcipher`.
    public static func dbKey() -> Data {
        #if canImport(UIKit)
        let vid = UIDevice.current.identifierForVendor?.uuidString
        #else
        let vid: String? = nil
        #endif
        let basis = vid ?? UUID().uuidString
        return Data(SHA256.hash(data: Data("hop.db.key.v1|\(basis)".utf8)))
    }
}

/// Foreground CoreBluetooth + L2CAP bearer for Hop, plus iBeacon region monitoring
/// for background wake (DESIGN.md §11, §22). It shuttles the node's opaque byte
/// packets and surfaces peers/messages/queue to the UI; all protocol logic is in
/// `hop-core`.
public final class HopBearer: NSObject, ObservableObject {
    /// How a host drives the runtime. `.full` = every transport + background/advertising
    /// (the iOS app). `.centralOnly` = node + BLE central scanning only, no advertising /
    /// Wi-Fi / LAN / relay / beacon (the headless `hopmac` macOS test node). `.relayOnly` =
    /// node + the cloud relay ONLY — NO BLE (no advertise/scan), no LAN, no Wi-Fi — so the only
    /// path to a peer is the relay (a clean relay-path test client; it must NOT appear on BLE).
    public enum Role { case full, centralOnly, relayOnly }

    /// The host-supplied seam that replaces the formerly-hardcoded db path, identity seed,
    /// app secret, display name and default relay (DESIGN.md §32 app isolation). The host owns
    /// storage + identity; the driver owns the protocol.
    public struct Config {
        public var dbPath: String
        public var deviceSeed: Data
        public var appSecret: Data
        public var displayName: String
        public var defaultRelay: String?
        public var role: Role
        /// 32-byte SQLCipher key for `hop.db` at rest (F-25). Defaults to the device-derived
        /// [`IdentityStore.dbKey()`]; empty = open unencrypted. Only encrypts when libhop is built
        /// `--features sqlcipher` (otherwise the key is accepted but the db stays plain).
        public var dbKey: Data
        public init(dbPath: String, deviceSeed: Data, appSecret: Data,
                    displayName: String, defaultRelay: String?, role: Role = .full,
                    dbKey: Data = IdentityStore.dbKey()) {
            self.dbPath = dbPath; self.deviceSeed = deviceSeed; self.appSecret = appSecret
            self.displayName = displayName; self.defaultRelay = defaultRelay; self.role = role
            self.dbKey = dbKey
        }
    }

    private let config: Config
    /// `.full` host (iOS app) vs a stripped central-only node (hopmac).
    private var isFull: Bool { config.role == .full }
    /// Relay-and-nothing-else: no BLE (advertise/scan), no LAN, no Wi-Fi — the relay is the only bearer.
    private var isRelayOnly: Bool { config.role == .relayOnly }
    /// Whether this host should connect the cloud relay link (full app, or a relay-only test client).
    private var wantsRelay: Bool { isFull || isRelayOnly }

    // Threading model (Stage C — move BLE + node off main):
    //  • `core`     — the ONLY queue that may touch `node`. UniFFI HopNode is NOT thread-safe, so a
    //                 single serial funnel is mandatory. Node outputs are drained here into plain-data
    //                 snapshots, then applied on main.
    //  • `bleQueue` — the CoreBluetooth managers' delegate-callback queue. iOS 18+ silently drops CB
    //                 callbacks delivered on a busy main runloop, so they must NOT land on main; each
    //                 delegate hops to main (bookkeeping) / core (node).
    //  • IOThread   — the L2CAP streams + their keepalive/watchdog timers (HopLink), off main.
    //  • main       — every @Published / SwiftUI mutation, and all bearer bookkeeping dictionaries
    //                 (link routing, contacts, identities…). Single-homing them on main avoids racing
    //                 the heavily-shared routing tables across queues.
    private let core = DispatchQueue(label: "hop.core")
    private let bleQueue = DispatchQueue(label: "hop.ble")

    /// Run `block` on main (home of @Published + bookkeeping). Direct if already on main so we don't
    /// reorder synchronous UI calls behind queued work.
    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
    /// Deliver inbound link bytes to the node (on `core`) then pump. Ordering holds: both are async on
    /// the serial `core` queue, so `received` runs before the subsequent drain.
    private func deliver(link: UInt64, bytes: Data) {
        core.async { [weak self] in self?.node.received(link: link, bytes: bytes) }
        pump()
    }
    /// A transport link came up — drive the Noise handshake (on `core`) then pump.
    private func linkUp(_ id: UInt64, initiator: Bool) {
        core.async { [weak self] in self?.node.connected(link: id, initiator: initiator) }
        pump()
    }
    /// A transport link dropped — tell the node (on `core`) then refresh the UI.
    private func linkDown(_ id: UInt64) {
        core.async { [weak self] in self?.node.disconnected(link: id) }
        scheduleRefresh()
    }
    /// Run an arbitrary node mutation on `core` (no return value), then pump.
    private func nodeDo(_ work: @escaping (HopNode) -> Void) {
        core.async { [weak self] in guard let self else { return }; work(self.node) }
        pump()
    }

    public init(config: Config) {
        self.config = config
        // Persistent message store on disk — survives restarts; bounded (older relayed messages
        // are evicted). Identity is derived from the host-supplied seed (stable address every
        // launch, no storage to fail). The app secret isolates this app's hps:// channels/services
        // from other apps: only apps built with the same secret can discover/join them (§32).
        // F-25: open the store SQLCipher-encrypted with the device-derived db key (empty key ⇒ plain,
        // same as open). Only actually encrypts when libhop is built `--features sqlcipher`.
        self.node = HopNode.openKeyed(dbPath: config.dbPath, secret: config.deviceSeed,
                                      appSecret: config.appSecret, key: config.dbKey)
        // Our address is immutable (derived from the seed). Cache it now — at init no queue is
        // running yet, so this lone read is safe — so UI/render paths never touch `node` for it.
        self.myAddrCache = node.address()
        self.myShortAddr = HopBearer.shortData(myAddrCache)
        super.init()
    }

    /// Our own raw 32-byte address, cached at init (immutable). Lets UI/render read it without
    /// hopping to `core`.
    private let myAddrCache: Data
    private let myShortAddr: Data   // 8-byte short form (for resolving our own trace hops, §27)

    // NOTE: the legacy BLE service/characteristic UUIDs (F09000xx…) and the iBeacon proximity UUID moved
    // to the shared bearer with the transport code. HopBearerBle owns SERVICE_UUID / ENDPOINT_CHAR and
    // the byte-matched BEACON_UUID (monitor + emission), so the driver no longer declares them (F-40).
    public static let refreshTaskId = "sh.hopme.refresh"
    /// Longer background-processing task (runs idle/charging) to drain a backlog — e.g. a
    /// large image accumulating across wakes (DESIGN.md §22, §28).
    public static let processTaskId = "sh.hopme.process"
    /// App-level presence service: title = display name (DESIGN.md §23).
    static let presenceService = "presence"
    /// MultipeerConnectivity service type for the Wi-Fi bearer (≤15 chars).
    static let mcServiceType = "hop-mesh"
    /// Default cloud relay: the anycast address resolves to the device's nearest node,
    /// which it checks into for pending messages (DESIGN.md §28).
    public static let defaultRelay = "wss://relay.hopme.sh/"
    /// How long a presence advert lives before it must be refreshed (10 min).
    static let presenceTtlMs: UInt32 = 600_000

    public struct Peer: Identifiable, Hashable {
        public let address: Data; public let name: String; public var hops: UInt8
        public var active: Bool = true       // peer's app foreground (vs backgrounded)
        public var platform: String = ""     // "ios" / "android"
        public var app: String = ""          // the app embedding Hop on that device
        public var id: Data { address }
        // Identity is the address — metadata updates don't churn navigation.
        public static func == (l: Peer, r: Peer) -> Bool { l.address == r.address }
        public func hash(into h: inout Hasher) { h.combine(address) }
    }
    public struct Message: Identifiable {
        public let id = UUID()
        public let peer: String; public let text: String; public let incoming: Bool
        public var peerAddr: Data? = nil   // the other party's address — stable across renames
        public var contentType: String = "text/plain"
        public var imageData: Data? = nil  // raw bytes for a single-image message (content_type image/*)
        public var images: [Data] = []     // one or more images (a multipart/mixed message)
        public var bundleId: Data? = nil
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
    public struct QueueRow: Identifiable {
        public let id: Data; public let own: Bool; public let to: String; public let priority: UInt8; public let hops: UInt8
    }
    public struct TransportStatus: Identifiable, Hashable {
        public let id: String      // "Bluetooth" / "Wi-Fi"
        public let active: Bool    // radio up + bearer running
        public let links: Int      // live links on this transport
    }

    @Published public var myAddress = ""
    @Published public var myName = ""
    /// Privacy: when on, we stop broadcasting our presence advert (name + address), so we don't
    /// show up by name in others' nearby lists. We stay fully relay-capable and reachable by anyone
    /// who already has our address (e.g. via a scanned QR / manual add). Persisted.
    @Published public var privateMode: Bool = UserDefaults.standard.bool(forKey: "hop.privateMode") {
        didSet {
            UserDefaults.standard.set(privateMode, forKey: "hop.privateMode")
            if privateMode { retractPresence() } else { publishPresence() }
        }
    }
    @Published public var idNote = ""   // identity persistence outcome (diagnostic)
    @Published public var status = "starting…" { didSet { NSLog("HOPLOG status: \(status)") } }
    @Published public var reachable: [Peer] = []   // discovered now (direct + mesh)
    @Published public var seen: [Peer] = []        // historical, not currently reachable
    @Published public var secured: Set<Data> = []  // addresses we have a forward-secret session with
    @Published public var routed: Set<Data> = []   // addresses we've learned a live route to (§27)
    @Published public var transports: [TransportStatus] = []  // per-bearer status (all run at once)
    @Published public var relayStatus = "not connected"        // cloud relay link state
    /// A relay the user pinned by direct address (persisted). A device only ever talks to ONE
    /// relay — routing is anycast — so pinning overrides the default anycast target for testing
    /// a specific relay, rather than publishing presence to several at once.
    @Published public var pinnedRelay: String? = UserDefaults.standard.string(forKey: "hop.pinnedRelay")
    @Published public var linkTransports: [Data: Set<String>] = [:]  // direct peer → transport(s) carrying it
    @Published public var relays: [Peer] = []   // connected cloud relays (named by their domain via hop.identify)
    @Published public var endpoints: [Peer] = []   // directly-dialed hops:// endpoints (§30; not relays)
    @Published public var hnsCache: [HnsCacheRow] = []   // live HNS cache w/ ticking TTLs (§30, debug)

    /// One HNS cache entry for the debug view: domain → address, with remaining TTL (seconds).
    public struct HnsCacheRow: Identifiable {
        public var id: String { domain }
        public let domain: String
        public let address: Data    // empty = a cached negative (no such endpoint)
        public let ttl: UInt32      // remaining lifetime, ticking down to expiry
    }
    // hps:// pub/sub — services & channels (§32). Topics we host or subscribe to, the messages
    // per topic (one thread each), per-topic unread, and invites we've received.
    @Published public var hpsTopics: [HpsTopic] = []
    @Published public var hpsThreads: [String: [HpsMsgRow]] = [:] { didSet { scheduleChannelSave() } }   // topic id → its messages
    @Published public var hpsUnread: [String: Int] = [:]            // topic id → unread count
    @Published public var hpsInvites: [HpsInvite] = []              // invites received (FFI record)
    var activeTopic: String?                                 // topic on screen (not counted)

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
        public var id = UUID()
        public let path: String
        public let sender: Data
        public let text: String
        public let at: UInt64
    }

    /// Resolved display name per 8-byte short address, for resolving trace hops (§27/§29).
    @Published public var nameByShort: [Data: String] = [:]
    @Published public var serviceLog: [String] = []   // hop.identify + custom service-call activity (§29)
    private var identities: [Data: IdentityInfo] = [:]   // address → identify record
    private var identifyAsked = Set<Data>()              // addresses we've sent hop.identify to
    private var identifyReqs = Set<Data>()               // outstanding identify request bundle ids
    @Published public var messages: [Message] = [] { didSet { scheduleMessageSave() } }
    /// Latest hops:// result per domain, rendered for the UI ("200 · <body>" or an error).
    @Published public var hopsResults: [String: String] = [:]   // domain → rendered text (§30)
    @Published public var queue: [QueueRow] = []
    @Published public var unread: [String: Int] = [:] { didSet { updateAppBadge() } }   // peer name → unread incoming count
    private var activePeer: String?              // chat currently on screen (not counted)
    private var loadingMessages = false          // suppress save while restoring history
    private var messageSaveWork: DispatchWorkItem?  // debounced history write
    private var channelSaveWork: DispatchWorkItem?  // debounced channel-thread write

    /// The Hop node — created in `init(config:)` from the host's db path / identity seed / app
    /// secret. Identity is derived from the seed (stable address every launch, no storage to
    /// fail); the db persists *messages*.
    private let node: HopNode

    /// Shared app secret for Hop Debug — all our demo devices use it so they interoperate. A
    /// different app (different secret) can't see or join these channels. Exposed so a host can
    /// build the dev `Config`; to test cross-app isolation, change it on one device.
    public static let appSecret = Data(repeating: 0x48, count: 32) // "H" ×32 — dev build only
    // Wi-Fi bearer (MultipeerConnectivity) — a second transport feeding the same node.
    private var mcPeerID: MCPeerID?
    private var mcSession: MCSession?
    private var mcAdvertiser: MCNearbyServiceAdvertiser?
    private var mcBrowser: MCNearbyServiceBrowser?
    private var mcLinkByPeer: [MCPeerID: UInt64] = [:]
    private var mcPeerByLink: [UInt64: MCPeerID] = [:]
    private var mcNextLinkId: UInt64 = 10_000   // distinct id range from BLE links
    private var wifiBlocked = false             // MC failed to start (e.g. local-network denied)
    // Cloud relay bearer — reaches a hop-relayd over the internet (DESIGN.md §19, §21).
    // Two flavors share one link id: raw TCP (path A, the VM) and WebSocket (path B,
    // Cloud Run behind the global LB, wss:// terminating TLS at the balancer).
    private var relayConn: NWConnection?
    private var relayWS: URLSessionWebSocketTask?
    private var relaySession: URLSession?
    private var relayURL: String?              // last relay endpoint (for auto check-in)
    private var lastRelayDialMs: UInt64 = 0    // throttle background reconnect attempts
    private var relayReconnectScheduled = false
    private let relayLinkId: UInt64 = 20_000    // distinct id range from BLE/Wi-Fi
    // Direct WS links to hops:// endpoints (DESIGN.md §30). The client dials the endpoint at
    // wss://<domain> — it does NOT transit our relay (domain traffic stays off the fleet) — so
    // the endpoint authenticates via Noise as its HNS-published address and becomes a direct
    // peer we can seal requests to. Keyed by a distinct link-id range.
    private var endpointWS: [UInt64: URLSessionWebSocketTask] = [:]
    private var endpointLinkByDomain: [String: UInt64] = [:]
    private var nextEndpointLinkId: UInt64 = 30_000
    // NOTE: the legacy in-driver BLE (L2CAP HopLink + GATT-data fallback) and LAN (mDNS + TCP LanLink)
    // transport state was removed in the app cutover. Those transports are now owned entirely by the
    // shared BleBearer / LanBearer (HopBearerBle / HopBearerLan), which mint their links through the
    // BearerManager. Multipeer (Wi-Fi P2P), the cloud relay, and hops:// endpoints remain in-driver.
    private var nameByAddr: [Data: String] = [:]
    private var contacts: [Data: Peer] = [:]   // app-side contact book (address → peer)
    /// Our own raw 32-byte address (for marking our own hps posts).
    public var myAddressData: Data { myAddrCache }
    /// Contacts as a sorted list (for the invite picker).
    public var contactList: [Peer] { contacts.values.sorted { $0.name.lowercased() < $1.name.lowercased() } }
    private var userNamed = Set<Data>()        // contacts the user named (identify won't override)
    // hops:// fetches awaiting an HNS resolution: domain → the path to request once the
    // record resolves (DESIGN.md §30).
    private var pendingHops: [String: String] = [:]
    // In-flight hops:// requests: request id → the domain it's for, so a response can be
    // matched back and rendered into `hopsResults`.
    private var hopsReqs: [Data: String] = [:]
    // The hops:// WebView path (DESIGN.md §30): callback-style fetches that feed a WKWebView
    // (the manual `hopsResults` field above is for the text test box only). Request id →
    // completion, and per-domain queues for requests issued before HNS resolves.
    private var hopsWebReqs: [Data: (HopResponse) -> Void] = [:]
    private var hopsWebPending: [String: [(path: String, completion: (HopResponse) -> Void)]] = [:]
    private var lastRelayLog = -1
    private var lastReachLog = -1
    private var tickTimer: Timer?
    private var started = false
    private var appActive = true   // our app foreground state, carried in presence
    // Real Wi-Fi availability (MC's session object stays non-nil even when the radio is
    // off in Settings, so we can't infer the radio from it).
    private let pathMonitor = NWPathMonitor()
    private var wifiUp = false

    // MARK: - Shared HopBearers transport layer (BLE + LAN + relay)
    /// The shared bearer registry/multiplexer. Its global link-id space starts high (1_000_000) so the
    /// ids it mints can never collide with the legacy / Multipeer / relay / endpoint / LAN / GATT ranges
    /// (1, 10k, 20k, 30k, 40k, 60k) that `nextLinkId` & friends still serve for the non-shared transports.
    private let bearerMgr = BearerManager(baseLinkId: 1_000_000)
    /// One stable transport id for this process, shared by every registered bearer (the BLE/LAN HELLO id
    /// + the greater-id dedup tiebreaker). This is a TRANSPORT-layer id, distinct from the Hop node
    /// address (SPEC R11) — the node still negotiates Noise over the bearer's DATA frames.
    private let bearerId: Data = HopContract.randomNodeId()
    /// The shared BLE bearer, kept as a ref so a background wake can poke its `wake()` to re-arm
    /// scanning + re-adopt connected peripherals promptly (it self-recovers on `.poweredOn` too).
    /// A central-only host (hopmac) suppresses advertising so it scans/dials but stays undiscoverable.
    private lazy var bleBearer = BleBearer(myId: bearerId, suppressAdvertising: config.role == .centralOnly)
    /// Link ids currently owned by the `BearerManager`, so `applyOutgoing` routes their packets to it.
    /// Written from the sink callbacks (BLE I/O thread / LAN queue) and read in `applyOutgoing` (main) —
    /// guarded by `bearerLinksLock`.
    private var bearerLinks = Set<UInt64>()
    private let bearerLinksLock = NSLock()
    /// Strong ref to the sink adapter — `BearerManager.sink` holds it weakly.
    private lazy var bearerSink = BearerSink(self)

    /// The app embedding Hop on this device (shown to peers via presence).
    static let appName: String =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "HopDemo"

    public func start(name: String) {
        guard !started else { return }
        started = true
        loadMessages()   // restore chat history from the previous run
        loadContacts()   // restore the address book so past conversations are reachable when offline
        loadChannels()   // restore channel (hps) message threads
        loadHpsTopics()  // restore hosted/subscribed channels (the node persists them)
        myName = name
        myAddress = HopBearer.base58(myAddrCache)   // address is cached + immutable (no node call)
        idNote = "\(IdentityStore.note) → \(myAddress.prefix(8))"
        // Node setup runs on `core` (the only queue allowed to touch the node), in order:
        //  • setName — what hop.identify reports for us (§29).
        //  • tick — set the node clock to real time BEFORE any advert. The node starts at now_ms=0,
        //    so a prekey/presence advert stamped created_at=0 would be judged expired (1970 + TTL)
        //    and dropped instantly. Presence re-publishes and recovers, but the prekey is published
        //    once: without this peers never learn it and every message defers forever (§25).
        //  • subscribe — presence is an app-level service (§23): publish our name on "presence" and
        //    subscribe so discovered records are retained. The protocol knows nothing about names.
        //  • publishPrekey — once; long TTL + link-up gossip re-offer it to new neighbours (§25).
        // We deliberately do NOT stamp our app id into trace hops (§27 privacy).
        core.async { [weak self] in
            guard let self else { return }
            self.node.setName(name: name)
            self.node.tick(nowMs: HopBearer.nowMs())
            self.node.subscribe(topic: HopBearer.presenceService)
            _ = try? self.node.publishPrekey()
        }
        publishPresence()   // enqueues its node.publishService on core after the block above

        if isFull {
            #if os(iOS)
            // User-notification auth is an iOS-app concern; on a bare macOS CLI host (hopmac)
            // `UNUserNotificationCenter.current()` throws (no bundle/entitlement). Guard it.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            #endif

            #if canImport(UIKit)
            // Re-publish presence with our foreground/background state on each transition
            // (iOS suspends us shortly after backgrounding, so the "bg" advert is our last
            // word until we return — peers show that as our state). The shared LAN and Relay
            // bearers manage their own lifecycle/backoff, so foreground only needs the flag + Wi-Fi.
            let nc = NotificationCenter.default
            nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.appActive = true
                HopBearerBle.bleAppInBackground = false   // shared BLE: foreground liveness deadline
                self.publishPresence(); self.restartWiFi()
                self.pump()
            }
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.appActive = false
                HopBearerBle.bleAppInBackground = true    // shared BLE: relaxed background deadline
                self.publishPresence(); self.pump()
            }
            #endif
        }

        // Shared transport layer (HopBearers): pure-L2CAP BLE + LAN + cloud relay, multiplexed by one
        // BearerManager. Role-aware (see startSharedBearers): full = BLE(advertising)+LAN+relay,
        // centralOnly = BLE scan-only (no advertising/LAN/relay), relayOnly = relay only.
        startSharedBearers()

        if isFull {
            startWiFi()

            // Reflect the real Wi-Fi radio in the indicator (MC's session stays non-nil even
            // when Wi-Fi is switched off, which kept it showing green).
            pathMonitor.pathUpdateHandler = { [weak self] path in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.wifiUp = path.status == .satisfied && path.usesInterfaceType(.wifi)
                    // Declare whether we can reach the public internet (any interface — Wi-Fi,
                    // cellular or wired). An internet-connected phone resolves HNS itself by
                    // servicing `takeDnsLookups()` in `pump()` (DESIGN.md §30).
                    let on = path.status == .satisfied
                    self.core.async { self.node.setInternet(on: on) }   // node on core
                    self.refresh()
                }
            }
            pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
            // NOTE: the iBeacon background-wake MONITOR is owned by the shared BleBearer (BeaconWake);
            // the driver no longer runs its own CLLocationManager facade.
        }

        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.backgroundTick()
        }

        // TEST/AUTOMATION: publish the self-address mirror immediately so a headless harness can
        // learn this device's address before any message flows (see writeAutomationDump).
        writeAutomationDump()
    }

    private var tickCount = 0

    /// Re-publish our presence advert so it stays live (it carries a TTL) and any
    /// rename propagates. The advert's publisher field is our address — that's all a
    /// peer needs to seal a message back to us (DESIGN.md §4, §23).
    private func publishPresence() {
        guard !privateMode else { return }   // private: don't broadcast our name/address
        // summary carries app-level metadata: "state|platform|app". Read main state, publish on core.
        let meta = "\(appActive ? "fg" : "bg")|ios|\(HopBearer.appName)"
        let title = myName
        core.async { [weak self] in
            _ = try? self?.node.publishService(service: HopBearer.presenceService,
                                               title: title, summary: meta, tags: [],
                                               ttlMs: HopBearer.presenceTtlMs)
        }
    }

    /// Supersede our live presence with a near-instantly-expiring one so peers drop our name now
    /// (rather than waiting out the old advert's TTL) when we switch to private.
    private func retractPresence() {
        let meta = "\(appActive ? "fg" : "bg")|ios|\(HopBearer.appName)"
        let title = myName
        core.async { [weak self] in
            _ = try? self?.node.publishService(service: HopBearer.presenceService,
                                               title: title, summary: meta, tags: [], ttlMs: 1000)
        }
        pump()
    }

    public func backgroundTick() {
        let now = HopBearer.nowMs()
        tickCount += 1
        let doPrekey = tickCount % 120 == 0
        // Tick the node clock (+ periodic prekey re-publish) on core.
        core.async { [weak self] in
            guard let self else { return }
            self.node.tick(nowMs: now)
            // Re-publish our prekey periodically so a neighbour whose cached copy lapsed (or who
            // arrived after ours did) can always open a forward-secret session to us (§25).
            if doPrekey { _ = try? self.node.publishPrekey() }
        }
        // Refresh presence periodically so it never lapses its TTL (link-up gossip
        // also shares it to new neighbours immediately). The shared RelayBearer owns its own
        // reconnect/check-in backoff (DESIGN.md §28), so the driver no longer redials the relay here.
        if tickCount % 20 == 0 { publishPresence() }
        pump()
    }

    /// Persisted display name to use across launches (falls back to the device name).
    public static func savedName(default deviceName: String) -> String {
        UserDefaults.standard.string(forKey: "hop.displayName") ?? deviceName
    }

    /// Change this device's name; persists it and re-publishes presence so peers update.
    public func setName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != myName else { return }
        myName = trimmed
        core.async { [weak self] in self?.node.setName(name: trimmed) }   // hop.identify (§29)
        UserDefaults.standard.set(trimmed, forKey: "hop.displayName")
        publishPresence()
        pump()
    }

    /// Add a contact to the address book by base58 address. An empty `name` falls back to
    /// the address (and hop.identify will fill in the device's own name if it has one); a
    /// provided name is kept as your local alias. Returns false if the address is invalid.
    @discardableResult
    public func addContact(name: String, address base58: String) -> Bool {
        let addr = addressFromBase58(text: base58.trimmingCharacters(in: .whitespacesAndNewlines))
        guard addr.count == 32, addr != myAddrCache else { return false }
        let alias = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = alias.isEmpty ? HopBearer.shortHex(addr) : alias
        nameByAddr[addr] = label
        contacts[addr] = Peer(address: addr, name: label, hops: 0)
        if alias.isEmpty {
            queueIdentify(addr)   // resolve their device name if they set one
        } else {
            userNamed.insert(addr) // keep my alias
        }
        saveContacts(force: true)
        pump()
        return true
    }

    /// Clear the relay queue (our undelivered messages + bundles held for peers).
    /// Anything of ours still in flight is now abandoned, so mark those bubbles "not sent"
    /// instead of leaving them stuck on "Sending…".
    public func clearQueue() {
        core.async { [weak self] in self?.node.clearQueue() }
        for i in messages.indices where !messages[i].incoming && !messages[i].delivered {
            messages[i].failed = true
        }
        pump()
    }

    /// Send a message on `core`, then stamp the returned bundleId onto its placeholder bubble (main)
    /// so delivery tracking can re-query it. The bubble is appended by the caller before this runs.
    private func sendBundle(dst: Data, contentType: String, body: Data, messageId: UUID) {
        core.async { [weak self] in
            guard let self else { return }
            // A thrown send is a real store/seal error (the peer-unreachable case defers with a valid
            // id), so `id == nil` must mark the bubble failed — otherwise it shows "Sending…" forever
            // and the "Not sent · tap to retry" path never engages (F-15).
            var id: Data? = nil
            do {
                id = try self.node.sendMessage(dst: dst, contentType: contentType, body: body, requestAck: true)
            } catch {
                NSLog("HOPLOG sendMessage threw for \(messageId): \(error)")
            }
            let sentId = id
            DispatchQueue.main.async {
                if let i = self.messages.firstIndex(where: { $0.id == messageId }) {
                    if let sentId { self.messages[i].bundleId = sentId }
                    else { self.messages[i].failed = true }
                }
                self.pump()
            }
        }
    }

    public func send(_ text: String, to peer: Peer) {
        rememberContact(peer)   // messaging someone adds them to your address book
        let msg = Message(peer: peer.name, text: text, incoming: false, peerAddr: peer.address)
        messages.append(msg)
        sendBundle(dst: peer.address, contentType: "text/plain; charset=utf-8",
                   body: Data(text.utf8), messageId: msg.id)
    }

    /// TEST/AUTOMATION hook: send `text` to a base58 ADDRESS, building a minimal peer (no UI
    /// selection needed). Drives the headless automation surface (the `hopdemo://send` URL scheme
    /// and the `HOP_AUTO` launch env var); not on any normal user path. The node defers/ratchets
    /// to an as-yet-unreachable address like any send, so the target need not be discovered yet.
    public func sendTo(addressBase58 b58: String, text: String) {
        onMain { [weak self] in
            guard let self else { return }
            let addr = addressFromBase58(text: b58.trimmingCharacters(in: .whitespacesAndNewlines))
            guard addr.count == 32, addr != self.myAddrCache else { return }
            self.send(text, to: Peer(address: addr, name: self.displayName(addr), hops: 0))
        }
    }

    /// Send an image. It's just a message with an image content type and the raw bytes as
    /// the body — the core auto-streams it in chunks if it's too big for one bundle, and
    /// the far side reassembles it back into one message (DESIGN.md §20).
    public func sendImage(_ data: Data, to peer: Peer) {
        rememberContact(peer)
        let msg = Message(peer: peer.name, text: "", incoming: false, peerAddr: peer.address,
                          contentType: "image/jpeg", imageData: data)
        messages.append(msg)
        sendBundle(dst: peer.address, contentType: "image/jpeg", body: data, messageId: msg.id)
    }

    /// Send text and/or one-or-more images as ONE message (`multipart/mixed`) — a single sealed
    /// payload, carrier-chunked + reassembled like any message (DESIGN.md §20). The wire format
    /// is shared with Android: `[u32 partCount][ per part: u16 ctLen, ct, u32 bodyLen, body ]`.
    public func sendMultipart(text: String, images: [Data], to peer: Peer) {
        var parts: [(String, Data)] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(("text/plain", Data(trimmed.utf8))) }
        for img in images { parts.append(("image/jpeg", img)) }
        guard !parts.isEmpty else { return }
        let body = HopBearer.encodeMultipart(parts)
        let msg = Message(peer: peer.name, text: trimmed, incoming: false, peerAddr: peer.address,
                          contentType: "multipart/mixed", images: images)
        messages.append(msg)
        sendBundle(dst: peer.address, contentType: "multipart/mixed", body: body, messageId: msg.id)
    }

    /// Re-send a failed ("Not sent") message in place — rebuilds the same payload from its
    /// content type and dispatches fresh, so the node defers/ratchets + tracks delivery again.
    /// Recovery for a message that gave up (queue cleared, or still unsent at a restart).
    public func retry(_ m: Message) {
        guard !m.incoming, let addr = m.peerAddr else { return }
        let body: Data
        let ct: String
        switch m.contentType {
        case let c where c.hasPrefix("image/"):
            guard let d = m.imageData else { return }
            body = d; ct = "image/jpeg"
        case "multipart/mixed":
            var parts: [(String, Data)] = []
            if !m.text.isEmpty { parts.append(("text/plain", Data(m.text.utf8))) }
            for img in (m.imageData.map { [$0] } ?? m.images) { parts.append(("image/jpeg", img)) }
            guard !parts.isEmpty else { return }
            body = HopBearer.encodeMultipart(parts); ct = "multipart/mixed"
        default:
            body = Data(m.text.utf8); ct = "text/plain; charset=utf-8"
        }
        if let i = messages.firstIndex(where: { $0.id == m.id }) {
            messages[i].failed = false
            messages[i].delivered = false
            messages[i].sentAt = Date()
        }
        sendBundle(dst: addr, contentType: ct, body: body, messageId: m.id)
    }

    /// Encode `(contentType, bytes)` parts into the shared multipart wire format.
    static func encodeMultipart(_ parts: [(String, Data)]) -> Data {
        var out = Data()
        var count = UInt32(parts.count).bigEndian
        withUnsafeBytes(of: &count) { out.append(contentsOf: $0) }
        for (ct, body) in parts {
            let ctd = Data(ct.utf8)
            var cl = UInt16(ctd.count).bigEndian
            withUnsafeBytes(of: &cl) { out.append(contentsOf: $0) }
            out.append(ctd)
            var bl = UInt32(body.count).bigEndian
            withUnsafeBytes(of: &bl) { out.append(contentsOf: $0) }
            out.append(body)
        }
        return out
    }

    /// Decode the shared multipart wire format into `(contentType, bytes)` parts.
    static func decodeMultipart(_ data: Data) -> [(String, Data)] {
        let b = [UInt8](data)
        var i = 0
        func u(_ n: Int) -> Int? {
            guard i + n <= b.count else { return nil }
            var v = 0
            for _ in 0..<n { v = (v << 8) | Int(b[i]); i += 1 }
            return v
        }
        var parts: [(String, Data)] = []
        guard let count = u(4) else { return [] }
        for _ in 0..<count {
            guard let cl = u(2), i + cl <= b.count else { break }
            let ct = String(decoding: b[i..<i + cl], as: UTF8.self); i += cl
            guard let bl = u(4), i + bl <= b.count else { break }
            parts.append((ct, Data(b[i..<i + bl]))); i += bl
        }
        return parts
    }

    // MARK: - Wi-Fi (MultipeerConnectivity) bearer

    /// Stand up the Wi-Fi bearer: advertise + browse for nearby Hop peers and shuttle
    /// the node's frames over a `MCSession`, exactly like the BLE bearer but a
    /// different medium (DESIGN.md §26). Encryption is left to Hop's Noise layer.
    private func startWiFi() {
        let pid = MCPeerID(displayName: String(myAddress.prefix(60)))
        mcPeerID = pid
        let session = MCSession(peer: pid, securityIdentity: nil, encryptionPreference: .none)
        session.delegate = self
        mcSession = session
        let adv = MCNearbyServiceAdvertiser(peer: pid, discoveryInfo: nil, serviceType: HopBearer.mcServiceType)
        adv.delegate = self
        adv.startAdvertisingPeer()
        mcAdvertiser = adv
        let br = MCNearbyServiceBrowser(peer: pid, serviceType: HopBearer.mcServiceType)
        br.delegate = self
        br.startBrowsingForPeers()
        mcBrowser = br
        NSLog("HOPLOG wifi start: \(pid.displayName)")
    }

    /// Re-attempt advertise/browse and clear any blocked state. Called on foreground —
    /// MultipeerConnectivity errors out while the Local Network prompt is still
    /// pending, so this recovers once the user grants permission (no relaunch needed).
    private func restartWiFi() {
        wifiBlocked = false
        mcAdvertiser?.stopAdvertisingPeer()
        mcBrowser?.stopBrowsingForPeers()
        mcAdvertiser?.startAdvertisingPeer()
        mcBrowser?.startBrowsingForPeers()
        NSLog("HOPLOG wifi restart")
    }

    // NOTE: The legacy in-driver LAN transport (a Bonjour `_hoplan._tcp` listener + browser + LanLink)
    // was removed in the app cutover. The shared LanBearer (registered by startSharedBearers on a full
    // host) now owns the entire mDNS + TCP LAN path.

    // MARK: - Shared HopBearers wiring (BLE + LAN + relay through one BearerManager)

    /// Stand up the shared transport layer. First point the BLE transport's iOS host hooks at the
    /// driver's existing infrastructure — the dedicated `bleQueue` (CoreBluetooth callbacks) and the
    /// long-lived `IOThread` runloop (L2CAP streams + timers), REUSED rather than spinning a second I/O
    /// thread — and seed the background flag. Then register the bearers this ROLE wants and start. Every
    /// link surfaces through `bearerSink`, which drives the node seam (`linkUp` / `deliver` / `linkDown`).
    /// `BleBearer` is pure-L2CAP by design (no GATT-data fallback). Registration is role-aware:
    ///   • .full        — BLE (advertising) + LAN + cloud relay (if a relay is configured).
    ///   • .centralOnly — BLE ONLY, advertising suppressed (scan/dial but stay undiscoverable): the
    ///                    headless macOS test node (hopmac). No LAN, no relay.
    ///   • .relayOnly   — cloud relay ONLY, NO BLE (never appears on Bluetooth) and no LAN (relaymac).
    private func startSharedBearers() {
        HopBearerBle.bleQueue = bleQueue
        HopBearerBle.bleRunLoop = IOThread.shared.runLoop
        HopBearerBle.bleAppInBackground = !appActive
        bearerMgr.sink = bearerSink
        if !isRelayOnly {
            bearerMgr.register(bleBearer)   // BLE (central-only suppresses advertising via config.role)
        }
        if isFull {
            bearerMgr.register(LanBearer(myId: bearerId))   // LAN (mDNS + TCP) — full host only
        }
        // Cloud relay (WebSocket) as a shared bearer — ONE outbound link to the backbone, on any host that
        // wants a relay (full app, or the relay-only test client) with a relay configured.
        if wantsRelay, let relay = config.defaultRelay {
            bearerMgr.register(RelayBearer(relayURL: pinnedRelay ?? relay))
        }
        bearerMgr.start()
        let tags = [isRelayOnly ? nil : "BLE", isFull ? "LAN" : nil,
                    (wantsRelay && config.defaultRelay != nil) ? "Relay" : nil].compactMap { $0 }.joined(separator: "+")
        NSLog("HOPLOG shared bearers started (\(tags)) id=\(HopBearer.shortHex(bearerId))")
    }

    /// True iff `link` is owned by the shared `BearerManager` (read on main in `applyOutgoing`).
    fileprivate func bearerLinksContains(_ link: UInt64) -> Bool {
        bearerLinksLock.lock(); defer { bearerLinksLock.unlock() }
        return bearerLinks.contains(link)
    }

    /// Shared-bearer link up: record the id (so `applyOutgoing` routes it), then drive the node's Noise
    /// handshake through the existing seam (dialer → initiator). Called on the bearer's work queue.
    fileprivate func bearerLinkUp(_ id: UInt64, role: HopRole) {
        bearerLinksLock.lock(); bearerLinks.insert(id); bearerLinksLock.unlock()
        linkUp(id, initiator: role == .dialer)
    }

    /// Shared-bearer inbound DATA frame → the node, via the existing seam.
    fileprivate func bearerDeliver(_ id: UInt64, bytes: Data) {
        deliver(link: id, bytes: bytes)
    }

    /// Shared-bearer link down: forget the id, then tell the node through the existing seam.
    fileprivate func bearerLinkDown(_ id: UInt64) {
        bearerLinksLock.lock(); bearerLinks.remove(id); bearerLinksLock.unlock()
        linkDown(id)
    }

    // MARK: - Cloud relay bearer (→ hop-relayd)

    /// Connect to a `hop-relayd`. Accepts either a `host:port` (raw TCP, path A) or a
    /// `ws://`/`wss://` URL (WebSocket, path B). The device dials, so it's the Noise
    /// initiator. Once connected, presence floods over this link, so two devices on the
    /// same relay discover and message each other across the internet (DESIGN.md §19, §21).
    /// Pin this device to a single relay by direct address (persisted), or pass nil to clear the
    /// pin and fall back to the anycast default. Switches the one relay connection over now; the
    /// old relay's presence simply lapses (we never publish to two at once).
    public func setPinnedRelay(_ url: String?) {
        let trimmed = url?.trimmingCharacters(in: .whitespaces)
        let pinned = (trimmed?.isEmpty == false) ? trimmed : nil
        pinnedRelay = pinned
        if let pinned { UserDefaults.standard.set(pinned, forKey: "hop.pinnedRelay") }
        else { UserDefaults.standard.removeObject(forKey: "hop.pinnedRelay") }
        connectRelay(pinned ?? HopBearer.defaultRelay)   // connectRelay tears down the old link first
    }

    public func connectRelay(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        relayURL = trimmed   // remembered so we auto-reconnect (check-in) on drop (§28)
        if trimmed.hasPrefix("ws://") || trimmed.hasPrefix("wss://") {
            connectRelayWS(trimmed)
        } else {
            connectRelayTCP(trimmed)
        }
    }

    /// Reconnect to the last relay after a backoff — this is the device "check-in"
    /// (DESIGN.md §28): reconnecting to the anycast address wakes our nearest node and
    /// pulls any pending messages. Triggered on drop and on foreground.
    private func scheduleRelayReconnect() {
        guard let url = relayURL, !relayReconnectScheduled else { return }
        relayReconnectScheduled = true
        let delay = 5.0 + Double.random(in: 0...3)   // small backoff + jitter
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.relayReconnectScheduled = false
            // Only reconnect if we're not already connected.
            if self.relayStatus != "connected" { self.connectRelay(url) }
        }
    }

    /// WebSocket bearer: each link packet is one binary frame (no length framing — WS
    /// supplies it). The LB terminates TLS, so `wss://relay.hopme.sh/` reaches `ws://`
    /// inside the container.
    private func connectRelayWS(_ urlStr: String) {
        guard let url = URL(string: urlStr) else { relayStatus = "bad url"; return }
        relayConn?.cancel(); relayConn = nil
        relayWS?.cancel(with: .goingAway, reason: nil)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        relaySession = session
        let task = session.webSocketTask(with: url)
        relayWS = task
        relayStatus = "connecting…"
        task.resume()   // node.connected fires on didOpenWithProtocol
    }

    private func receiveRelayWS() {
        relayWS?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .data(let d) = message { self.deliver(link: self.relayLinkId, bytes: d) }
                self.receiveRelayWS()
            case .failure:
                self.onMain { self.relayStatus = "disconnected" }
                self.linkDown(self.relayLinkId)
            }
        }
    }

    /// Open (or reuse) a direct WS link to a hops:// endpoint at `wss://<domain>/` (DESIGN.md
    /// §30). The endpoint authenticates via Noise as its HNS-published address, becoming a
    /// direct peer; the sealed hops request then delivers straight to it. Returns the link id.
    @discardableResult
    private func dialEndpoint(_ domain: String) -> UInt64 {
        if let id = endpointLinkByDomain[domain], endpointWS[id] != nil { return id }
        let id = nextEndpointLinkId; nextEndpointLinkId += 1
        endpointLinkByDomain[domain] = id
        guard let url = URL(string: "wss://\(domain)/") else { return id }
        let session = relaySession ?? URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        relaySession = session
        let task = session.webSocketTask(with: url)
        endpointWS[id] = task
        task.resume()   // node.connected fires in didOpenWithProtocol (we're the initiator)
        receiveEndpoint(id)
        return id
    }

    private func receiveEndpoint(_ id: UInt64) {
        endpointWS[id]?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .data(let d) = message { self.deliver(link: id, bytes: d) }
                self.receiveEndpoint(id)
            case .failure:
                self.onMain { self.endpointWS[id] = nil }
                self.linkDown(id)
            }
        }
    }

    /// The endpoint link id whose WS task is `task`, if any (used by the URLSession delegate).
    private func endpointLink(for task: URLSessionTask) -> UInt64? {
        endpointWS.first(where: { $0.value === task })?.key
    }

    /// Connect to a `hop-relayd` at `host:port` over TCP. Framing matches the daemon
    /// (4-byte big-endian length prefix).
    private func connectRelayTCP(_ hostPort: String) {
        let parts = hostPort.split(separator: ":")
        guard parts.count == 2, let port = NWEndpoint.Port(String(parts[1])) else {
            relayStatus = "bad address"; return
        }
        relayWS?.cancel(with: .goingAway, reason: nil); relayWS = nil
        relayConn?.cancel()
        let conn = NWConnection(host: NWEndpoint.Host(String(parts[0])), port: port, using: .tcp)
        relayConn = conn
        let link = relayLinkId
        relayStatus = "connecting…"
        conn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .ready:
                    self.relayStatus = "connected"
                    self.receiveRelayFrame(conn, link: link)
                    self.linkUp(link, initiator: true)
                case .failed(let e):
                    self.relayStatus = "failed: \(e.localizedDescription)"
                    self.linkDown(link)
                case .cancelled:
                    self.relayStatus = "disconnected"
                    self.linkDown(link)
                default: break
                }
            }
        }
        conn.start(queue: .main)
    }

    private func receiveRelayFrame(_ conn: NWConnection, link: UInt64) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] hdr, _, done, err in
            guard let self else { return }
            guard let hdr, hdr.count == 4, err == nil else {
                if done || err != nil { self.linkDown(link) }
                return
            }
            let b = [UInt8](hdr)
            let n = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            guard n > 0, n <= 1 << 20 else { return }
            conn.receive(minimumIncompleteLength: n, maximumLength: n) { [weak self] payload, _, done2, err2 in
                guard let self else { return }
                if let payload, payload.count == n {
                    self.deliver(link: link, bytes: payload)
                    self.receiveRelayFrame(conn, link: link)
                } else if done2 || err2 != nil {
                    self.linkDown(link)
                }
            }
        }
    }

    private func relaySend(_ bytes: Data) {
        if let ws = relayWS {
            ws.send(.data(bytes)) { _ in }   // one link packet = one WS binary frame
            return
        }
        var len = UInt32(bytes.count).bigEndian
        var frame = Data(bytes: &len, count: 4)
        frame.append(bytes)
        relayConn?.send(content: frame, completion: .contentProcessed { _ in })
    }

    // MARK: - plumbing

    /// Drain ALL node outputs on `core` (the only queue allowed to touch `node`), then apply the
    /// resulting plain-data snapshots on main (link routing + @Published + bookkeeping). Safe to call
    /// from any thread.
    private func pump() {
        core.async { [weak self] in
            guard let self else { return }
            let outgoing = self.node.drainOutgoing()
            let inbox = self.node.takeInbox()
            let svcResponses = self.node.takeServiceResponses()
            let svcRequests = self.node.takeServiceRequests()
            let hnsResults = self.node.takeHnsResults()
            let httpResponses = self.node.takeHttpResponses()
            let dnsLookups = self.node.takeDnsLookups()
            let hpsMsgs = self.node.takeHpsMessages()
            let hpsInvs = self.node.takeHpsInvites()
            DispatchQueue.main.async {
                self.applyOutgoing(outgoing)
                self.scheduleRefresh()
                self.applyInbox(inbox)
                self.applyServiceResponses(svcResponses)
                self.applyServiceRequests(svcRequests)
                self.applyHnsResults(hnsResults)
                self.applyHttpResponses(httpResponses)
                self.applyDnsLookups(dnsLookups)
                self.applyHpsMessages(hpsMsgs)
                self.applyHpsInvites(hpsInvs)
            }
        }
    }

    /// Route outgoing packets to their link (main). The shared BearerManager owns BLE + LAN + relay;
    /// Multipeer and the direct hops:// endpoint links are the only transports the driver still mints
    /// itself. The legacy relay dial (via `setPinnedRelay`) also serves `relayLinkId` for runtime re-pin.
    private func applyOutgoing(_ outgoing: [OutPacket]) {
        for pkt in outgoing {
            if bearerLinksContains(pkt.link) {              // shared BearerManager (BLE + LAN + relay) owns it
                bearerMgr.send(pkt.bytes, on: pkt.link)
            } else if let peer = mcPeerByLink[pkt.link] {
                try? mcSession?.send(pkt.bytes, toPeers: [peer], with: .reliable) // Wi-Fi (Multipeer) link
            } else if pkt.link == relayLinkId {
                relaySend(pkt.bytes)                       // legacy relay dial (runtime re-pin via setPinnedRelay)
            } else if let ws = endpointWS[pkt.link] {
                ws.send(.data(pkt.bytes)) { _ in }         // direct hops:// endpoint link (§30)
            }
        }
    }

    /// Surface received messages into the UI (main).
    private func applyInbox(_ inbox: [InboxMessage]) {
        for m in inbox {
            let who = nameByAddr[m.from] ?? HopBearer.shortHex(m.from)
            let isImage = m.contentType.hasPrefix("image/")
            let isMultipart = m.contentType == "multipart/mixed"
            var text = isImage ? "" : (String(data: m.body, encoding: .utf8) ?? "<\(m.body.count) bytes>")
            var images: [Data] = []
            if isMultipart {
                let parts = HopBearer.decodeMultipart(m.body)
                text = parts.first(where: { $0.0.hasPrefix("text/") })
                    .flatMap { String(data: $0.1, encoding: .utf8) } ?? ""
                images = parts.filter { $0.0.hasPrefix("image/") }.map { $0.1 }
            }
            let now = HopBearer.nowMs()
            let latency = now >= m.createdAt ? now - m.createdAt : 0  // clamp clock skew
            messages.append(Message(peer: who, text: text, incoming: true,
                                    peerAddr: m.from, contentType: m.contentType,
                                    imageData: isImage ? m.body : nil, images: images,
                                    hops: m.hops, latencyMs: latency, trace: m.trace))
            // A sender that isn't in our nearby/contacts must still be reachable in the UI,
            // or the message vanishes. Make them a contact (so a row + chat exist) and run
            // hop.identify to resolve their name (their input, or their id if unset, §29).
            if contacts[m.from] == nil {
                contacts[m.from] = Peer(address: m.from, name: who, hops: m.hops)
            }
            queueIdentify(m.from)
            if who != activePeer { unread[who, default: 0] += 1 }  // badge unless viewing
            notifyIfBackgrounded(from: who, text: text)
        }
    }

    // MARK: - hps:// pub/sub (DESIGN.md §32)

    /// Host a new topic at `path`: a channel (anyone with the key reads + writes) or a service
    /// (only we broadcast). Keys are minted + persisted in the node. Returns the service public
    /// key for a service (empty for a channel).
    @discardableResult
    public func hpsRegister(path: String, channel: Bool, access: HpsAccess = .open,
                     discoverable: Bool = false) -> Data {
        let p = path.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return Data() }
        // Synchronous return to the UI (mints + persists keys): a brief core.sync. Deadlock-free —
        // core never sync-waits back on main.
        let pk = core.sync {
            node.registerService(path: p, kind: channel ? .channel : .service,
                                 access: access, visibility: discoverable ? .discoverable : .private)
        }
        if !hpsTopics.contains(where: { $0.host == myAddrCache && $0.path == p }) {
            hpsTopics.insert(HpsTopic(host: myAddrCache, path: p, isChannel: channel,
                                      hosting: true, access: access), at: 0)
        }
        return pk
    }

    /// Subscribe to `hps://{hostBase58}/{path}` — request the topic's keys from its host.
    public func hpsSubscribe(hostBase58: String, path: String) {
        let host = addressFromBase58(text: hostBase58.trimmingCharacters(in: .whitespacesAndNewlines))
        let p = path.trimmingCharacters(in: .whitespaces)
        guard host.count == 32, !p.isEmpty else { return }
        hpsSubscribe(host: host, path: p, isChannel: true)
    }

    private func hpsSubscribe(host: Data, path: String, isChannel: Bool) {
        core.async { [weak self] in _ = try? self?.node.hpsSubscribe(host: host, path: path) }
        if !hpsTopics.contains(where: { $0.host == host && $0.path == path }) {
            hpsTopics.insert(HpsTopic(host: host, path: path, isChannel: isChannel, hosting: false), at: 0)
        }
        pump()
    }

    /// Join a discoverable topic from a browse result.
    public func hpsJoin(_ t: HpsTopicInfo) {
        hpsSubscribe(host: t.host, path: t.path, isChannel: t.kind == .channel)
    }

    /// Publish text to a topic we host or (for a channel) belong to. Floods to all subscribers.
    public func hpsPublish(topic: HpsTopic, text: String) {
        guard !text.isEmpty, let body = text.data(using: .utf8) else { return }
        let path = topic.path
        core.async { [weak self] in _ = try? self?.node.hpsPublish(path: path, body: body) }
        // Echo our own post locally — broadcasts don't loop back to the sender.
        appendThread(topic.id, HpsMsgRow(path: topic.path, sender: myAddrCache, text: text, at: HopBearer.nowMs()))
        pump()
    }

    /// Host → contact: invite an address to a topic we host (Invite mode).
    public func hpsInvite(topic: HpsTopic, to address: Data) {
        guard topic.hosting, address.count == 32 else { return }
        let path = topic.path
        core.async { [weak self] in _ = try? self?.node.hpsInvite(path: path, dest: address) }
        pump()
    }

    /// Accept an invite we received — joins the topic once the host seals us the keys.
    public func hpsAcceptInvite(_ inv: HpsInvite) {
        let host = inv.host, path = inv.path
        core.async { [weak self] in _ = try? self?.node.hpsAcceptInvite(host: host, path: path) }
        hpsInvites.removeAll { $0.path == inv.path && $0.host == inv.host }
        if !hpsTopics.contains(where: { $0.host == inv.host && $0.path == inv.path }) {
            hpsTopics.insert(HpsTopic(host: inv.host, path: inv.path,
                                      isChannel: inv.kind == .channel, hosting: false), at: 0)
        }
        pump()
    }

    public func hpsDeclineInvite(_ inv: HpsInvite) {
        let host = inv.host, path = inv.path   // durable: won't reappear
        core.async { [weak self] in try? self?.node.hpsDeclineInvite(host: host, path: path) }
        hpsInvites.removeAll { $0.path == inv.path && $0.host == inv.host }
    }

    /// Host: pending join requests (RequestToJoin) for a topic. Synchronous UI read → brief core.sync.
    public func hpsPending(_ topic: HpsTopic) -> [Data] { core.sync { node.hpsPending(path: topic.path) } }
    public func hpsApprove(_ topic: HpsTopic, _ who: Data) {
        let path = topic.path
        core.async { [weak self] in _ = try? self?.node.hpsApprove(path: path, requester: who) }
        pump()
    }
    public func hpsDeny(_ topic: HpsTopic, _ who: Data) {
        let path = topic.path
        core.async { [weak self] in try? self?.node.hpsDeny(path: path, requester: who) }
    }
    /// Host: reach (unique acking members) + the retained-member set. Synchronous UI reads.
    public func hpsReach(_ topic: HpsTopic) -> Int { core.sync { Int(node.hpsReach(path: topic.path)) } }
    public func hpsMembers(_ topic: HpsTopic) -> [Data] { core.sync { node.hpsMembers(path: topic.path) } }
    /// Host: rotate keys, optionally removing members (revocation).
    public func hpsRekey(_ topic: HpsTopic, remove: [Data] = []) {
        let path = topic.path
        core.async { [weak self] in _ = try? self?.node.hpsRekey(path: path, newPath: "", remove: remove) }
        pump()
    }

    /// Leave / unsubscribe a topic we follow.
    public func hpsLeave(_ topic: HpsTopic) {
        let path = topic.path
        core.async { [weak self] in _ = try? self?.node.hpsLeave(path: path) }
        hpsTopics.removeAll { $0.id == topic.id }
        hpsThreads[topic.id] = nil
        hpsUnread[topic.id] = nil
        pump()
    }

    /// Discover same-app topics on the mesh (decrypted descriptors). Synchronous UI read.
    public func hpsBrowse() -> [HpsTopicInfo] { core.sync { node.browseDiscoverable() } }

    /// Rebuild the channel list from the node's persisted topics (hosted + subscribed) at startup.
    private func loadHpsTopics() {
        let mine = core.sync { node.hpsMyTopics() }
        for t in mine {
            let topic = HpsTopic(host: t.host, path: t.path, isChannel: t.kind == .channel,
                                 hosting: t.hosting, access: t.access)
            if !hpsTopics.contains(where: { $0.id == topic.id }) { hpsTopics.append(topic) }
        }
    }

    /// Mark a topic's thread as read (called when its screen is open).
    public func openTopic(_ id: String) { activeTopic = id; hpsUnread[id] = 0 }
    public func closeTopic() { activeTopic = nil }

    private func appendThread(_ id: String, _ row: HpsMsgRow) {
        hpsThreads[id, default: []].append(row)
        if hpsThreads[id]!.count > 500 { hpsThreads[id]!.removeFirst(hpsThreads[id]!.count - 500) }
    }

    /// Apply received pub/sub messages into per-topic threads (main).
    private func applyHpsMessages(_ msgs: [HpsMessage]) {
        for m in msgs {
            let text = String(data: m.body, encoding: .utf8) ?? "<\(m.body.count) bytes>"
            // Match the message to a topic we follow (by path; host is whoever we subscribed to).
            let topic = hpsTopics.first { $0.path == m.path }
            let id = topic?.id ?? m.path
            appendThread(id, HpsMsgRow(path: m.path, sender: m.sender, text: text, at: HopBearer.nowMs()))
            if id != activeTopic { hpsUnread[id, default: 0] += 1 }
            queueIdentify(m.sender)
        }
    }

    /// Surface new pub/sub invites (main).
    private func applyHpsInvites(_ invites: [HpsInvite]) {
        for inv in invites {
            if !hpsInvites.contains(where: { $0.path == inv.path && $0.host == inv.host }) {
                hpsInvites.append(inv)
                queueIdentify(inv.host)
            }
        }
    }

    // MARK: - Services & commands (DESIGN.md §29)

    /// Queue a built-in identity call to `address` (once per session per address) so we
    /// learn its display name / a relay's domain — and can resolve it in traces. Does not
    /// pump (safe to call from `refresh`); the next tick flushes it.
    private func queueIdentify(_ address: Data) {
        guard !identifyAsked.contains(address) else { return }   // main: bookkeeping
        identifyAsked.insert(address)
        core.async { [weak self] in
            guard let self else { return }
            let id = try? self.node.sendServiceRequest(dst: address, service: serviceIdentify(),
                                                       method: "", args: Data())
            if let id { DispatchQueue.main.async { self.identifyReqs.insert(id) } }
        }
    }

    /// Identify `address` now (from the UI), flushing immediately.
    public func identify(_ address: Data) {
        queueIdentify(address)
        pump()
    }

    /// The resolved identity (name + kind) we've learned for an address, if any.
    public func identity(_ address: Data) -> IdentityInfo? { identities[address] }

    /// Best display name for a full address: an identify name, a known peer/relay's name,
    /// else the short address.
    public func displayName(_ address: Data) -> String {
        if let info = identities[address], !info.name.isEmpty { return info.name }
        if let p = (reachable + relays + seen).first(where: { $0.address == address }) {
            return p.name
        }
        return HopBearer.shortHex(address)
    }

    /// Resolve a trace hop to a display label: a known node's name (or a relay's domain),
    /// else the carrying-app label + the hop's short address in hex (§27).
    public func traceLabel(_ hop: TraceHopInfo) -> String {
        if hop.node.allSatisfy({ $0 == 0 }) { return hop.appLabel }   // anonymized device hop (§27)
        if hop.node == myShortAddr { return "you" }
        if let name = nameByShort[hop.node], !name.isEmpty { return name }
        return "\(hop.appLabel) \(HopBearer.hex(hop.node))"
    }

    /// Drain identify replies and custom service traffic. Identify replies update the
    /// address book (names + relay domains); custom requests get a "not implemented"
    /// reply so callers aren't left hanging (the demo registers no app services yet).
    private func applyServiceResponses(_ responses: [ServiceResp]) {
        for resp in responses {
            if identifyReqs.remove(resp.forRequestId) != nil, resp.status == 0,
               let info = decodeIdentity(body: resp.body) {
                identities[Data(info.address)] = info
                let addr = Data(info.address)
                let label = info.name.isEmpty ? HopBearer.shortHex(addr) : info.name
                // Keep the contact's display name in sync (the chat is keyed by address,
                // so renames are safe) — this is how an unknown sender gets its real name.
                // A contact the user named locally keeps that alias.
                if !userNamed.contains(addr) {
                    nameByAddr[addr] = label
                }
                if let c = contacts[addr], !userNamed.contains(addr) {
                    contacts[addr] = Peer(address: addr, name: label, hops: c.hops,
                                          active: c.active, platform: c.platform, app: c.app)
                }
                serviceLog.insert("identify ← \(label) (\(info.kind))", at: 0)
                scheduleRefresh()
            } else {
                let text = String(data: resp.body, encoding: .utf8) ?? "<\(resp.body.count) bytes>"
                serviceLog.insert("service ← \(resp.status): \(text.prefix(120))", at: 0)
            }
        }
    }

    private func applyServiceRequests(_ requests: [ServiceReq]) {
        for req in requests {
            // No custom services registered in the demo yet — reply 501 so the caller
            // gets a definite answer instead of a timeout.
            serviceLog.insert("service → \(req.service)/\(req.method) (501)", at: 0)
            let from = req.from, reqId = req.requestId
            core.async { [weak self] in
                _ = try? self?.node.sendServiceResponse(to: from, forRequestId: reqId,
                                                        status: 501, body: Data())
            }
        }
    }

    // Open-web HTTP fetch via a third-party gateway was removed: a gateway that fetches
    // https:// on your behalf terminates TLS = a MitM (DESIGN.md §25). The model is now
    // origin-run gateways reached via `hops://<domain>` (the gateway serves *its own*
    // service over the mesh, no third party in the middle).

    // MARK: - HNS & hops:// (DESIGN.md §30)

    /// Open a `hops://<domain>/<path>` URL (a bare `<domain>` is also accepted). Resolves
    /// the domain to its hops endpoint address via the Hop Name System, then sends a GET
    /// over the mesh. The endpoint validates `host`, so we always pass the bare domain.
    public func openHops(_ urlString: String) {
        let (domain, path) = Self.parseHops(urlString)
        guard !domain.isEmpty else {
            hopsResults["?"] = "error: not a hops:// url"
            return
        }
        hopsResults[domain] = "resolving…"
        core.async { [weak self] in
            guard let self else { return }
            let res = self.node.resolveHns(domain: domain)
            DispatchQueue.main.async {
                switch res {
                case .cached(let address):
                    if address.isEmpty {
                        // A cached negative — the domain has no `_hopaddress` record.
                        self.hopsResults[domain] = "error: no hops endpoint for \(domain)"
                    } else {
                        self.fireHops(domain: domain, path: path, endpoint: address)
                    }
                case .pending:
                    // A lookup was kicked off — our own DNS (if we have internet) or a query
                    // broadcast to connected peers. Fire when its record lands in takeHnsResults().
                    self.pendingHops[domain] = path
                case .needsResolver:
                    // Genuinely isolated: no internet AND no connected peers to resolve through.
                    self.hopsResults[domain] = "error: offline — no internet or peers to resolve \(domain)"
                }
                self.pump()
            }
        }
    }

    /// Issue the sealed hops:// GET to a resolved endpoint and remember the request id so
    /// the response can be matched back (DESIGN.md §30). Runs on main; the node send is on core.
    private func fireHops(domain: String, path: String, endpoint: Data) {
        // We learned domain↔address from HNS, so label the endpoint by its domain right away
        // (no need to wait for a hop.identify round-trip) — shows in the endpoints list + traces.
        nameByAddr[endpoint] = domain
        // Open a direct link to the endpoint (wss://<domain>) so the sealed request has a path
        // to it — the endpoint doesn't transit our relay (§30). Spray-and-wait holds the
        // bundle and delivers it the moment the Noise handshake on this link completes.
        dialEndpoint(domain)
        hopsResults[domain] = "fetching…"
        core.async { [weak self] in
            guard let self else { return }
            let id = try? self.node.sendHopsRequest(endpoint: endpoint, host: domain,
                                                    method: "GET", url: path,
                                                    body: Data(), maxResp: 8 * 1024 * 1024)
            DispatchQueue.main.async {
                if let id { self.hopsReqs[id] = domain }
                else { self.hopsResults[domain] = "error: could not send request to \(domain)" }
                self.pump()
            }
        }
    }

    // MARK: - hops:// for the WebView (callback-style, per-resource)

    /// One hops:// HTTP response handed to the WebView's scheme handler.
    public struct HopResponse {
        public let status: Int
        public let contentType: String
        public let body: Data
    }

    /// Fetch a single hops:// resource (the WebView's document or any sub-resource) and call
    /// `completion` when the sealed response returns over the mesh. Resolves the domain via
    /// HNS (cached after the first hit, so sub-resources fire immediately), dials the endpoint
    /// if needed, and times out gracefully. Drives everything on the main queue.
    public func hopsFetch(domain: String, path: String, completion: @escaping (HopResponse) -> Void) {
        guard !domain.isEmpty else {
            completion(HopResponse(status: 400, contentType: "text/plain; charset=utf-8", body: Data("bad hops url".utf8)))
            return
        }
        core.async { [weak self] in
            guard let self else { return }
            let res = self.node.resolveHns(domain: domain)
            DispatchQueue.main.async {
                switch res {
                case .cached(let address):
                    if address.isEmpty {
                        completion(HopResponse(status: 502, contentType: "text/plain; charset=utf-8",
                                               body: Data("no hops endpoint for \(domain)".utf8)))
                    } else {
                        self.fireHopsWeb(domain: domain, path: path, endpoint: address, completion: completion)
                    }
                case .pending:
                    // Our own DNS, or (no internet) a query broadcast to connected peers (§30).
                    self.hopsWebPending[domain, default: []].append((path, completion))
                case .needsResolver:
                    completion(HopResponse(status: 503, contentType: "text/plain; charset=utf-8",
                                           body: Data("offline — no internet or peers to resolve \(domain)".utf8)))
                }
                self.pump()
            }
        }
    }

    private func fireHopsWeb(domain: String, path: String, endpoint: Data,
                             completion: @escaping (HopResponse) -> Void) {
        nameByAddr[endpoint] = domain   // label by domain from HNS (no identify needed)
        dialEndpoint(domain)   // direct link to the endpoint (§30)
        core.async { [weak self] in
            guard let self else { return }
            let id = try? self.node.sendHopsRequest(endpoint: endpoint, host: domain,
                                                    method: "GET", url: path,
                                                    body: Data(), maxResp: 8 * 1024 * 1024)
            DispatchQueue.main.async {
                guard let id else {
                    completion(HopResponse(status: 502, contentType: "text/plain; charset=utf-8",
                                           body: Data("could not send request".utf8)))
                    return
                }
                self.hopsWebReqs[id] = completion
                // Fail gracefully if nothing comes back (the request is still held & retried by the
                // node, but the WebView shouldn't spin forever).
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                    guard let self, let done = self.hopsWebReqs.removeValue(forKey: id) else { return }
                    done(HopResponse(status: 504, contentType: "text/plain; charset=utf-8",
                                     body: Data("hops timeout for \(domain)\(path)".utf8)))
                }
                self.pump()
            }
        }
    }

    /// Split `hops://<domain>/<path>` (or a bare `<domain>`) into (domain, path). The path
    /// defaults to "/" and is path+query only — what `sendHopsRequest` expects.
    private static func parseHops(_ raw: String) -> (domain: String, path: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "hops://") { s.removeSubrange(s.startIndex..<r.upperBound) }
        guard let slash = s.firstIndex(of: "/") else { return (s, "/") }
        let domain = String(s[s.startIndex..<slash])
        let path = String(s[slash...])
        return (domain, path.isEmpty ? "/" : path)
    }

    /// Drain finished HNS resolutions (firing any queued hops:// fetch) and hops:// HTTP
    /// responses (matching them back to the in-flight request). The core caches records,
    /// so we keep no extra cache here. Also service the host DNS hook: any `_hopaddress`
    /// TXT lookups the node needs are resolved over DNS-over-HTTPS off the main queue and
    /// fed back via `provideDnsAnswer` (DESIGN.md §30).
    private func applyHnsResults(_ results: [HnsRecord]) {
        for rec in results {
            // The manual text-box fetch (one path per domain).
            if let path = pendingHops.removeValue(forKey: rec.domain) {
                if rec.address.isEmpty {
                    hopsResults[rec.domain] = "error: no hops endpoint for \(rec.domain)"
                } else {
                    fireHops(domain: rec.domain, path: path, endpoint: rec.address)
                }
            }
            // WebView fetches queued on this domain's resolution (may be several).
            if let queued = hopsWebPending.removeValue(forKey: rec.domain) {
                for (path, completion) in queued {
                    if rec.address.isEmpty {
                        completion(HopResponse(status: 502, contentType: "text/plain; charset=utf-8",
                                               body: Data("no hops endpoint for \(rec.domain)".utf8)))
                    } else {
                        fireHopsWeb(domain: rec.domain, path: path, endpoint: rec.address,
                                    completion: completion)
                    }
                }
            }
        }
    }

    private func applyHttpResponses(_ responses: [HttpResp]) {
        for resp in responses {
            // WebView completion (per-resource) takes priority over the text box.
            if let completion = hopsWebReqs.removeValue(forKey: resp.forRequestId) {
                completion(HopResponse(status: Int(resp.status),
                                       contentType: resp.contentType, body: resp.body))
                continue
            }
            guard let domain = hopsReqs.removeValue(forKey: resp.forRequestId) else { continue }
            let text = String(data: resp.body, encoding: .utf8) ?? "<\(resp.body.count) bytes>"
            hopsResults[domain] = "\(resp.status) · \(text)"
        }
    }

    /// Host DNS hook (DESIGN.md §30): for each domain the node wants resolved, fetch its full DNSSEC
    /// chain over DoH and hand core the raw response bodies — core validates the chain to the root
    /// anchors and decides the address; the app never does.
    private func applyDnsLookups(_ domains: [String]) {
        for domain in domains { fetchDnssecChain(domain) }
    }

    /// Fetch a domain's full DNSSEC chain over DNS-over-HTTPS and feed the raw JSON bodies to
    /// core via `provideDnsProof`: the `_hopaddress.<domain>` TXT plus DNSKEY + DS for every
    /// zone up to the root, all with `do=1`. Runs the GETs concurrently, then marshals back to
    /// the main queue (where the node is driven) once they're all in.
    private func fetchDnssecChain(_ domain: String) {
        // The DoH queries: TXT for the record, then DNSKEY+DS for each zone up to root.
        var queries: [(String, Int)] = [("_hopaddress.\(domain)", 16)]
        var zone = domain
        while true {
            queries.append((zone, 48)) // DNSKEY
            if zone == "." { break }
            queries.append((zone, 43)) // DS
            zone = zone.contains(".") ? String(zone[zone.index(after: zone.firstIndex(of: ".")!)...]) : "."
        }

        let group = DispatchGroup()
        var bodies: [String] = []
        let lock = NSLock()
        for (name, qtype) in queries {
            guard let url = URL(string: "https://dns.google/resolve?name=\(name)&type=\(qtype)&do=1") else { continue }
            group.enter()
            URLSession.shared.dataTask(with: url) { data, _, _ in
                if let data, let body = String(data: data, encoding: .utf8) {
                    lock.lock(); bodies.append(body); lock.unlock()
                }
                group.leave()
            }.resume()
        }
        group.notify(queue: core) { [weak self] in   // node access on core
            guard let self else { return }
            self.node.provideDnsProof(domain: domain, bodies: bodies)
            self.pump()
        }
    }

    /// The chat for `peer` is on screen: clear its badge and stop counting it.
    public func openChat(_ peer: String) { activePeer = peer; unread[peer] = 0 }
    /// The chat closed.
    public func closeChat() { activePeer = nil }
    /// Total unread across all peers (for the title badge).
    public var totalUnread: Int { unread.values.reduce(0, +) }

    /// Mirror total unread onto the app icon badge so it shows even when the app is
    /// backgrounded/closed. iOS 16+ API; ignore the completion error (best-effort).
    private func updateAppBadge() {
        #if canImport(UIKit)
        let n = totalUnread
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(n)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = n
        }
        #endif
    }

    // MARK: - Message history persistence (survives app restart)

    /// On-disk form of a chat message. Omits `trace` (FFI type, incoming-path debug only) but KEEPS
    /// `bundleId`: the node persists undelivered own-bundles and keeps spraying them after a restart
    /// (node.rs rehydrate), and for an established session the bundle id is stable, so we re-query
    /// `messageStatus(bundleId)` on relaunch and the message flips to Delivered when its ACK lands.
    private struct StoredMessage: Codable {
        var peer: String; var text: String; var incoming: Bool
        var peerAddr: Data?; var contentType: String
        var imageData: Data?; var images: [Data]
        var hops: UInt8; var latencyMs: UInt64?
        var sentAt: Date; var deliveredAt: Date?
        var relayed: UInt32; var delivered: Bool; var deliveryHops: UInt8; var failed: Bool
        var bundleId: Data?
    }

    private static var messagesFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("messages.json")
    }

    /// Coalesce rapid mutations into one disk write (≤1 write/sec) so appending a burst of
    /// messages doesn't re-encode the whole history each time.
    private func scheduleMessageSave() {
        guard !loadingMessages else { return }   // don't echo the load back to disk
        messageSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveMessages() }
        messageSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func saveMessages() {
        let stored = messages.map {
            StoredMessage(peer: $0.peer, text: $0.text, incoming: $0.incoming,
                          peerAddr: $0.peerAddr, contentType: $0.contentType,
                          imageData: $0.imageData, images: $0.images,
                          hops: $0.hops, latencyMs: $0.latencyMs,
                          sentAt: $0.sentAt, deliveredAt: $0.deliveredAt,
                          relayed: $0.relayed, delivered: $0.delivered,
                          deliveryHops: $0.deliveryHops, failed: $0.failed,
                          bundleId: $0.bundleId)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: HopBearer.messagesFileURL, options: .atomic)
        writeAutomationDump()   // TEST/AUTOMATION: mirror self-addr + rx/tx for the headless harness
    }

    // MARK: - Automation control surface (TEST/AUTOMATION hook — headless harness only)

    /// A PLAINTEXT mirror of our self-address + recent rx/tx, written to `Documents/automation.json`.
    /// The encrypted hop.db has no plaintext mirror, so this is the ONLY way an external test harness
    /// (which pulls the file via `xcrun devicectl device copy from`) can discover this device's
    /// address (`self`) for targeting and verify iOS-side message receipt. Not a normal user path.
    private struct AutomationDump: Codable {
        struct Rx: Codable { let from: String; let text: String; let at: Int64 }
        struct Tx: Codable { let to: String; let text: String; let delivered: Bool; let deliveryMs: UInt32; let at: Int64 }
        let `self`: String
        let name: String
        let rx: [Rx]
        let tx: [Tx]
    }
    static var automationFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("automation.json")
    }
    /// Rewrite the automation mirror (last ~100 rx + tx). Called on every message change (from
    /// `saveMessages`) and once at startup so `self` is discoverable even before any traffic.
    func writeAutomationDump() {
        let rx = messages.filter { $0.incoming }.suffix(100).map {
            AutomationDump.Rx(from: $0.peerAddr.map(HopBearer.base58) ?? $0.peer,
                              text: $0.text, at: Int64($0.sentAt.timeIntervalSince1970 * 1000))
        }
        let tx = messages.filter { !$0.incoming }.suffix(100).map {
            AutomationDump.Tx(to: $0.peerAddr.map(HopBearer.base58) ?? $0.peer,
                              text: $0.text, delivered: $0.delivered, deliveryMs: $0.deliveryMs,
                              at: Int64($0.sentAt.timeIntervalSince1970 * 1000))
        }
        let dump = AutomationDump(self: myAddress, name: myName, rx: Array(rx), tx: Array(tx))
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(dump) else { return }
        try? data.write(to: HopBearer.automationFileURL, options: .atomic)
    }

    private static var channelsFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("channels.json")
    }
    private func scheduleChannelSave() {
        guard !loadingMessages else { return }
        channelSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let data = try? JSONEncoder().encode(self.hpsThreads) else { return }
            try? data.write(to: HopBearer.channelsFileURL, options: .atomic)
        }
        channelSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
    private func loadChannels() {
        guard let data = try? Data(contentsOf: HopBearer.channelsFileURL),
              let stored = try? JSONDecoder().decode([String: [HpsMsgRow]].self, from: data) else { return }
        loadingMessages = true
        hpsThreads = stored
        loadingMessages = false
    }

    private func loadMessages() {
        guard let data = try? Data(contentsOf: HopBearer.messagesFileURL),
              let stored = try? JSONDecoder().decode([StoredMessage].self, from: data) else { return }
        loadingMessages = true
        // An outgoing message still in flight when we quit KEEPS sending: the node persists the
        // bundle and re-sprays it after restart until its delivery ACK (node.rs rehydrate). So we
        // restore it in-flight with its bundleId — refresh() re-queries messageStatus and it flips
        // to Delivered when the ACK lands — rather than falsely marking it "Not sent".
        messages = stored.map { s in
            Message(peer: s.peer, text: s.text, incoming: s.incoming, peerAddr: s.peerAddr,
                    contentType: s.contentType, imageData: s.imageData, images: s.images,
                    bundleId: s.bundleId,
                    hops: s.hops, latencyMs: s.latencyMs, sentAt: s.sentAt,
                    deliveredAt: s.deliveredAt, relayed: s.relayed, delivered: s.delivered,
                    deliveryHops: s.deliveryHops, failed: s.failed)
        }
        loadingMessages = false
    }

    // MARK: - Address book persistence (past conversations survive restart + going out of range)

    private struct StoredContact: Codable { var address: Data; var name: String; var platform: String; var app: String }
    private static var contactsFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("contacts.json")
    }
    private var lastContactSaveAt = Date.distantPast
    /// Persist the address book, throttled (refresh runs often). Anyone we've seen, messaged, or
    /// been messaged by is kept, so their conversation is reachable even when offline / out of range.
    /// Add a peer to the address book and persist immediately (e.g. on send / manual add) so the
    /// conversation is reachable even if we quit before the next throttled save.
    public func rememberContact(_ peer: Peer) {
        if contacts[peer.address] == nil { contacts[peer.address] = peer }
        nameByAddr[peer.address] = peer.name
        saveContacts(force: true)
    }
    private func saveContacts(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastContactSaveAt) > 4 else { return }
        lastContactSaveAt = Date()
        let snapshot = contacts.values.map {
            StoredContact(address: $0.address, name: $0.name, platform: $0.platform, app: $0.app)
        }
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: HopBearer.contactsFileURL, options: .atomic)
        }
    }
    private func loadContacts() {
        guard let data = try? Data(contentsOf: HopBearer.contactsFileURL),
              let stored = try? JSONDecoder().decode([StoredContact].self, from: data) else { return }
        for c in stored where contacts[c.address] == nil {
            contacts[c.address] = Peer(address: c.address, name: c.name, hops: 0,
                                       active: false, platform: c.platform, app: c.app)
            nameByAddr[c.address] = c.name
        }
    }

    private var refreshScheduled = false

    /// Coalesced UI refresh. `refresh()` does synchronous SQLite work (browse, queue, per-message
    /// status) and is far too expensive to run on every `pump()` — which fires on every received
    /// packet across BLE/Wi-Fi/LAN/relay. Running it per-packet saturates the main thread (watchdog
    /// 0x8BADF00D + cpu_resource kills, sluggish UI). Coalesce to ~4 Hz; the hot path still drains
    /// outgoing and the inbox immediately, only the heavy snapshot is throttled.
    private func scheduleRefresh() {
        // Callable from any thread (link callbacks fire off-main); `refreshScheduled` is main-only.
        onMain { [self] in
            guard !refreshScheduled else { return }
            refreshScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                self.refreshScheduled = false
                self.refresh()
            }
        }
    }

    /// One node-read snapshot for `refresh` — gathered entirely on `core`, applied on main.
    private struct RefreshSnapshot {
        let browse: [ServiceHit]
        let peerLinks: [PeerLink]
        let secured: Set<Data>
        let routed: Set<Data>
        let queue: [QueueItem]
        let hnsCache: [HnsCacheEntry]
        let statuses: [Data: MessageStatus]   // outgoing bundleId → delivery status
    }

    /// Coalesced UI refresh: read everything the node knows on `core` (the only queue allowed to
    /// touch it) into a plain snapshot, then apply it to @Published + bookkeeping on main.
    private func refresh() {
        // main: gather the bookkeeping inputs the node reads need.
        let contactKeys = Array(contacts.keys)
        let bundleIds = messages.compactMap { $0.incoming ? nil : $0.bundleId }
        core.async { [weak self] in
            guard let self else { return }
            let mine = self.node.address()
            let browse = self.node.browse(service: HopBearer.presenceService, tag: "")
                .filter { $0.publisher != mine }
            let peerLinks = self.node.peerLinks()
            let secured = Set(contactKeys.filter { self.node.isSecured(address: $0) })
            let routed = Set(contactKeys.filter { self.node.knowsRoute(address: $0) })
            let queue = self.node.queue()
            let hns = self.node.hnsCache()
            var statuses = [Data: MessageStatus]()
            for bid in bundleIds where statuses[bid] == nil { statuses[bid] = self.node.messageStatus(id: bid) }
            let snap = RefreshSnapshot(browse: browse, peerLinks: peerLinks, secured: secured,
                                       routed: routed, queue: queue, hnsCache: hns, statuses: statuses)
            DispatchQueue.main.async { self.applyRefresh(snap) }
        }
    }

    /// Apply a node-read snapshot to @Published state + bookkeeping (main).
    private func applyRefresh(_ snap: RefreshSnapshot) {
        // Discover peers by browsing the app-level "presence" service. A device may
        // re-publish several presence adverts (one per refresh); collapse to one per
        // address, keeping the nearest hop count — the contact-book logic the
        // protocol no longer carries (DESIGN.md §23).
        // Collapse the many retained presence adverts per publisher: nearest hops for
        // distance, newest advert (max createdAt) for current name/state/platform/app.
        struct Agg { var minHops: UInt8; var newestAt: UInt64; var peer: Peer }
        var agg = [Data: Agg]()
        for p in snap.browse {
            let name = p.title.isEmpty ? HopBearer.shortHex(p.publisher) : p.title
            let parts = p.summary.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let active = parts.indices.contains(0) ? parts[0] != "bg" : true
            let platform = parts.indices.contains(1) ? parts[1] : ""
            let app = parts.indices.contains(2) ? parts[2] : ""
            let hops = agg[p.publisher].map { min($0.minHops, p.hops) } ?? p.hops
            if let ex = agg[p.publisher], p.createdAt < ex.newestAt {
                agg[p.publisher] = Agg(minHops: hops, newestAt: ex.newestAt, peer: ex.peer) // older: just refresh hops
            } else {
                let peer = Peer(address: p.publisher, name: name, hops: hops,
                                active: active, platform: platform, app: app)
                agg[p.publisher] = Agg(minHops: hops, newestAt: p.createdAt, peer: peer)
            }
            nameByAddr[p.publisher] = name
        }
        var byAddr = [Data: Peer]()
        for (addr, a) in agg {
            var peer = a.peer
            peer = Peer(address: addr, name: peer.name, hops: a.minHops,
                        active: peer.active, platform: peer.platform, app: peer.app)
            byAddr[addr] = peer
        }
        // Sort by the stable address, not last-seen hops/name — otherwise rows jump around as
        // hop counts fluctuate and generic names ("iPhone"/"iPad") tie. Address is fixed, so a
        // peer keeps its position.
        reachable = byAddr.values.sorted { $0.address.lexicographicallyPrecedes($1.address) }

        // Accumulate everyone we've ever seen into the (persisted) contact book; those not
        // currently reachable form the "seen" list — reachable across restarts + out-of-range.
        for (addr, peer) in byAddr { contacts[addr] = peer }
        let here = Set(byAddr.keys)
        seen = contacts.filter { !here.contains($0.key) }
            .map { Peer(address: $0.key, name: $0.value.name, hops: 0,
                        active: false, platform: $0.value.platform, app: $0.value.app) }
            .sorted { $0.address.lexicographicallyPrecedes($1.address) }
        saveContacts()   // throttled — persist the address book

        // Forward-secret sessions (lock icon) + learned live routes (§27) — computed on core.
        secured = snap.secured
        routed = snap.routed

        // Per-transport status — several bearers run at once (DESIGN.md §26). The headline
        // count is the *actual transport-level connections* (what the user means by
        // "linked"), not just handshake-complete Hop links — otherwise a peer that's
        // connected but mid-Noise-handshake shows as zero. The expandable list below
        // shows the identified peers (and notes any still establishing).
        // MC keeps its session object even when Wi-Fi is off; trust the real radio (or
        // the presence of live MC links) instead. Peer-to-Peer (MultipeerConnectivity/AWDL, no router)
        // is NOT a shared bearer, so it keeps its own live-link/radio signal.
        let p2pActive = !wifiBlocked && (wifiUp || !mcPeerByLink.isEmpty)
        let pls = snap.peerLinks
        // The shared bearers mint links through the BearerManager (baseLinkId 1_000_000+), NOT any legacy
        // radio object, so per-transport status comes from the manager's live links — each short tag mapped
        // to its display id. Multipeer (Peer-to-Peer) is not a shared bearer, so it's added separately.
        let active = bearerMgr.activeTransports()          // short tag → live link count
        var ts: [TransportStatus] = []
        if let n = active["BT"]    { ts.append(TransportStatus(id: "Bluetooth", active: true, links: n)) }
        ts.append(TransportStatus(id: "Peer-to-Peer", active: p2pActive, links: mcPeerByLink.count))
        if let n = active["LAN"]   { ts.append(TransportStatus(id: "Local Net", active: true, links: n)) }
        if let n = active["Relay"] { ts.append(TransportStatus(id: "Relay", active: true, links: n)) }
        transports = ts

        // Map each direct neighbour to the transport(s) carrying it (the route). Shared-bearer links are
        // minted by the BearerManager (baseLinkId 1_000_000+), so the legacy link-id ranges can't tag
        // them — ask the manager for the owning bearer's REAL transport first, then fall back to the
        // legacy ranges for any link the node still mints itself (Multipeer, legacy relay/endpoints).
        var lt = [Data: Set<String>]()
        for pl in pls {
            let t: String
            if bearerLinksContains(pl.link), let tag = bearerMgr.transportName(of: pl.link) {
                t = tag                          // shared bearer: real transport ("BT"/"LAN"/"Relay")
            } else {
                switch pl.link {
                case ..<10_000:  t = "BT"
                case ..<20_000:  t = "P2P"       // MultipeerConnectivity / AWDL — peer-to-peer Wi-Fi, no router
                case ..<40_000:  t = "Relay"     // relay (20k) + hops:// endpoints (30k) aren't local
                default:          t = "LAN"        // 40k+ = LAN TCP over a shared network (mDNS)
                }
            }
            lt[pl.address, default: []].insert(t)
        }
        linkTransports = lt

        // A live local radio link (BLE / Wi-Fi P2P) IS a 1-hop path, so force the hop count to 1
        // for those peers — even if a stale presence advert arrived via the relay at 2 hops. This
        // keeps "direct" honest: a peer is direct iff hops <= 1, so a live-linked peer shows
        // "1 hop · BT" (never "2 hops"), and a peer with no live link at 2 hops stays in the mesh.
        reachable = reachable.map { p in
            var p = p
            if let t = lt[p.address], t.contains("BT") || t.contains("P2P") || t.contains("LAN") { p.hops = 1 }
            return p
        }

        // Connected cloud relays (the relay-link range 20_000–29_999), named by their region
        // domain via hop.identify (§29). Endpoints (≥30_000) are NOT relays — they're dialed
        // directly and never join the backbone (§30) — so they're listed separately below.
        relays = pls.filter { (20_000..<30_000).contains($0.link) }.map { pl in
            let name = identities[pl.address]?.name.isEmpty == false
                ? identities[pl.address]!.name
                : (nameByAddr[pl.address] ?? HopBearer.shortHex(pl.address))
            return Peer(address: pl.address, name: name, hops: 1, platform: "cloud", app: "Hop Relay")
        }
        .sorted { $0.name < $1.name }

        // Connected hops:// endpoints (the directly-dialed origin links, the legacy 30_000–39_999
        // range). NOT the relay backbone; we reach them straight (DESIGN.md §30). Bounded to that
        // range so the new shared-bearer links (BearerManager baseLinkId 1_000_000+ — ordinary
        // BLE/LAN peers) are NOT misclassified as endpoints. Named by the domain via hop.identify.
        endpoints = pls.filter { (30_000..<40_000).contains($0.link) }.map { pl in
            let name = identities[pl.address]?.name.isEmpty == false
                ? identities[pl.address]!.name
                : (nameByAddr[pl.address] ?? HopBearer.shortHex(pl.address))
            return Peer(address: pl.address, name: name, hops: 1, platform: "cloud", app: "hops endpoint")
        }
        .sorted { $0.name < $1.name }

        // Learn the name/kind of everyone we're directly linked to (the relay's domain,
        // a peer's kind) so traces resolve and relays show by domain (§29).
        for pl in pls { queueIdentify(pl.address) }

        // Index every known full address by its 8-byte short form so trace hops (§27)
        // resolve to display names.
        var ns = [Data: String]()
        for (addr, name) in nameByAddr { ns[HopBearer.shortData(addr)] = name }
        nameByShort = ns

        queue = snap.queue.map {
            QueueRow(id: $0.id, own: $0.own,
                     to: $0.to.isEmpty ? "broadcast" : HopBearer.shortHex($0.to),
                     priority: $0.priority, hops: $0.hops)
        }
        // Live HNS cache snapshot (ticks down each refresh as the node clock advances, §30).
        hnsCache = snap.hnsCache.map {
            HnsCacheRow(domain: $0.domain, address: $0.address, ttl: $0.ttlSecs)
        }
        if reachable.count != lastReachLog { NSLog("HOPLOG reachable=\(reachable.count)"); lastReachLog = reachable.count }
        let relayN = queue.filter { !$0.own }.count
        if relayN != lastRelayLog { NSLog("HOPLOG relayQueue=\(relayN) total=\(queue.count)"); lastRelayLog = relayN }

        for i in messages.indices where !messages[i].incoming {
            guard let bid = messages[i].bundleId, let s = snap.statuses[bid] else { continue }
            messages[i].relayed = s.relayed
            messages[i].deliveryHops = s.deliveryHops
            messages[i].deliveryMs = s.deliveryMs   // forward-path (A→B) latency from the ACK
            if s.delivered && messages[i].deliveredAt == nil {
                messages[i].delivered = true
                messages[i].deliveredAt = Date()  // our clock: send→delivered is skew-free
            }
        }
    }

    private func notifyIfBackgrounded(from: String, text: String) {
        guard isFull else { return }   // central-only nodes (hopmac) post no user notifications
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState != .active else { return }
        #endif
        let content = UNMutableNotificationContent()
        content.title = from; content.body = text; content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    static func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
    /// Compact elapsed-time label: 3s / 5m / 2h / 4d.
    public static func compactDuration(_ ms: UInt64) -> String {
        let s = ms / 1000
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h" }
        return "\(h / 24)d"
    }
    /// A single link to the destination is "direct" (0 relays); ≥2 shows the count.
    /// Matches the peer-row convention.
    public static func hopsLabel(_ h: UInt8) -> String { h <= 1 ? "direct" : "\(h) hops" }
    /// Compact base58 prefix for display (full base58 via `addressBase58`).
    public static func shortHex(_ d: Data) -> String { String(addressBase58(address: d).prefix(8)) }
    static func base58(_ d: Data) -> String { addressBase58(address: d) }
    /// The 8-byte short form of a full address — matches what trace hops carry (§27).
    static func shortData(_ d: Data) -> Data { shortAddress(address: d) }
    /// Hex of an arbitrary byte string (for an unresolved short trace hop).
    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
}

// NOTE: The legacy in-driver BLE transport (the CBPeripheralManagerDelegate / CBCentralManagerDelegate /
// CBPeripheralDelegate extensions: pure-L2CAP HopLink + the GATT-data fallback + advert cycle) was removed
// in the app cutover. The shared BleBearer (HopBearerBle) now owns the whole BLE role for every host.

// MARK: - Wi-Fi bearer delegates (MultipeerConnectivity)

extension HopBearer: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, mcSession) // accept; role arbitration is on the browser side
    }

    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String: String]?) {
        // Only the lexicographically-smaller address invites, so each pair forms one
        // session with a clear initiator/responder (matches Noise XX roles).
        guard let me = mcPeerID, me.displayName < peerID.displayName, let s = mcSession else { return }
        browser.invitePeer(peerID, to: s, withContext: nil, timeout: 15)
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        NSLog("HOPLOG wifi advertise failed: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in self?.wifiBlocked = true; self?.refresh() }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        NSLog("HOPLOG wifi browse failed: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in self?.wifiBlocked = true; self?.refresh() }
    }

    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch state {
            case .connected:
                guard self.mcLinkByPeer[peerID] == nil else { return }
                let id = self.mcNextLinkId; self.mcNextLinkId += 1
                self.mcLinkByPeer[peerID] = id
                self.mcPeerByLink[id] = peerID
                let initiator = (self.mcPeerID?.displayName ?? "") < peerID.displayName
                self.status = "linked (wifi)"
                self.linkUp(id, initiator: initiator)
            case .notConnected:
                if let id = self.mcLinkByPeer[peerID] {
                    self.mcLinkByPeer[peerID] = nil
                    self.mcPeerByLink[id] = nil
                    self.linkDown(id)
                }
            case .connecting: break
            @unknown default: break
            }
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let id = self.mcLinkByPeer[peerID] else { return }
            self.deliver(link: id, bytes: data)
        }
    }

    // Unused transfer modes (protocol requires them).
    public func session(_ s: MCSession, didReceive stream: InputStream, withName n: String, fromPeer p: MCPeerID) {}
    public func session(_ s: MCSession, didStartReceivingResourceWithName n: String, fromPeer p: MCPeerID, with progress: Progress) {}
    public func session(_ s: MCSession, didFinishReceivingResourceWithName n: String, fromPeer p: MCPeerID, at u: URL?, withError e: Error?) {}
}

// NOTE: The iBeacon background-wake MONITOR (a CLLocationManager region monitor) used to live here as a
// facade in the driver. It is now owned entirely by the shared BLE bearer (HopBearerBle.BeaconWake),
// which arms the SAME BEACON_UUID region on start and pokes its own Central.wake() on a region cross.
// The driver keeps no CLLocationManager: monitor AND emission both live in the shared bearer.

// MARK: - Cloud relay (WebSocket)

extension HopBearer: URLSessionWebSocketDelegate {
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        // URLSession delegate queue is `.main` (set when dialing), so this runs on main already.
        if let id = endpointLink(for: webSocketTask) {   // a hops:// endpoint link (§30)
            linkUp(id, initiator: true)    // dialer = Noise initiator
            return
        }
        relayStatus = "connected"
        receiveRelayWS()
        linkUp(relayLinkId, initiator: true)   // dialer = Noise initiator
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if let id = endpointLink(for: webSocketTask) {
            endpointWS[id] = nil; linkDown(id)
            return
        }
        relayStatus = "disconnected"
        relayWS = nil
        scheduleRelayReconnect()   // re-check-in (§28)
        linkDown(relayLinkId)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let id = endpointLink(for: task) {
            endpointWS[id] = nil; linkDown(id)
            return
        }
        guard task === relayWS else { return }
        if let error { relayStatus = "failed: \(error.localizedDescription)" }
        relayWS = nil
        scheduleRelayReconnect()   // re-check-in (§28)
        linkDown(relayLinkId)
    }
}

// MARK: - Shared HopBearers sink adapter

/// Adapts the shared `BearerManager` to HopBearer's existing node seam. Every link from every
/// registered bearer (BLE + LAN) surfaces here in ONE global link-id space and is driven straight into
/// the same `linkUp` / `deliver` / `linkDown` the legacy transports use — so the node sees no difference
/// in which radio a link rode in on. Holds the owner `unowned`: HopBearer owns this sink (a stored
/// property), so it never outlives its owner.
private final class BearerSink: LinkSink {
    unowned let owner: HopBearer
    init(_ owner: HopBearer) { self.owner = owner }
    func linkUp(_ link: LinkId, role: HopRole, peerId: Data) { owner.bearerLinkUp(link, role: role) }
    func linkBytes(_ link: LinkId, _ bytes: Data) { owner.bearerDeliver(link, bytes: bytes) }
    func linkDown(_ link: LinkId) { owner.bearerLinkDown(link) }
}
