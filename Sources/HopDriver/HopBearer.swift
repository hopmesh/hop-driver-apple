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

/// The Hop identity secret is a **random 32-byte value generated once and kept in the device
/// Keychain** (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, non-syncable, SE-wrapped where
/// available) - see `HopKeychain` and sec-priv-02. The secret is the keypair is the address, so
/// reading the same Keychain value back every launch keeps the node routeable.
///
/// This replaces the old `SHA-256(identifierForVendor)` derivation, which gave the long-term
/// identity only the entropy of a NON-secret device id (readable by any in-sandbox code, backups,
/// or forensics) and made the db key derivable the same way. The Keychain value is a real secret
/// that never leaves the device. `note` is shown in the UI for transparency.
///
/// Migration: the legacy value was deterministic and unrecoverable as a random secret, so the first
/// launch after this change generates fresh secrets - a ONE-TIME identity reset (new address) and a
/// fresh db key. Every launch after that is stable from the Keychain.
public enum IdentityStore {
    public static var note = "init"

    /// The 32-byte Ed25519 identity seed. Random, stored once in the Keychain, stable across launches
    /// (and reboots after first unlock). Not derivable from any non-secret device attribute.
    public static func deviceSeed() -> Data {
        let r = HopKeychain.secret(account: HopKeychain.identityAccount)
        note = "identity: \(r.origin.rawValue)"
        return r.bytes
    }

    /// The 32-byte SQLCipher key for the on-device `hop.db` (F-25). Random, stored once in the
    /// Keychain (distinct account from the identity), so it is: (a) stable every launch, (b) a real
    /// secret that is NOT derivable from the vendor id, and (c) NOT present in the db file - a pulled
    /// or backed-up `hop.db` is useless without the device's Keychain. Only encrypts when libhop is
    /// built `--features sqlcipher` (otherwise the key is accepted but the db stays plain).
    public static func dbKey() -> Data {
        HopKeychain.secret(account: HopKeychain.dbKeyAccount).bytes
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
    /// node + the cloud relay ONLY - NO BLE (no advertise/scan), no LAN, no Wi-Fi - so the only
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
    var isFull: Bool { config.role == .full }
    /// Relay-and-nothing-else: no BLE (advertise/scan), no LAN, no Wi-Fi - the relay is the only bearer.
    private var isRelayOnly: Bool { config.role == .relayOnly }
    /// Whether this host should connect the cloud relay link (full app, or a relay-only test client).
    private var wantsRelay: Bool { isFull || isRelayOnly }

    // Threading model (Stage C - move BLE + node off main):
    //  • `core`     - the ONLY queue that may touch `node`. UniFFI HopNode is NOT thread-safe, so a
    //                 single serial funnel is mandatory. Node outputs are drained here into plain-data
    //                 snapshots, then applied on main.
    //  • `bleQueue` - the CoreBluetooth managers' delegate-callback queue. iOS 18+ silently drops CB
    //                 callbacks delivered on a busy main runloop, so they must NOT land on main; each
    //                 delegate hops to main (bookkeeping) / core (node).
    //  • IOThread   - the L2CAP streams + their keepalive/watchdog timers (HopLink), off main.
    //  • main       - every @Published / SwiftUI mutation, and all bearer bookkeeping dictionaries
    //                 (link routing, contacts, identities…). Single-homing them on main avoids racing
    //                 the heavily-shared routing tables across queues.
    // Internal (not private) so the headless-node test suite can drain queued node work deterministically
    // (`core.sync {}` as a barrier) - see cov/apple-driver. Widening to internal does not change the
    // package's public surface (the demo app uses only `public` API).
    let core = DispatchQueue(label: "hop.core")
    private let bleQueue = DispatchQueue(label: "hop.ble")

    /// Run `block` on main (home of @Published + bookkeeping). Direct if already on main so we don't
    /// reorder synchronous UI calls behind queued work.
    func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
    /// Deliver inbound link bytes to the node (on `core`) then pump. Ordering holds: both are async on
    /// the serial `core` queue, so `received` runs before the subsequent drain.
    func deliver(link: UInt64, bytes: Data) {
        core.async { [weak self] in self?.node.received(link: link, bytes: bytes) }
        pump()
    }
    /// A transport link came up - drive the Noise handshake (on `core`) then pump.
    func linkUp(_ id: UInt64, initiator: Bool) {
        core.async { [weak self] in self?.node.connected(link: id, initiator: initiator) }
        pump()
    }
    /// A transport link dropped - tell the node (on `core`) then refresh the UI.
    func linkDown(_ id: UInt64) {
        core.async { [weak self] in self?.node.disconnected(link: id) }
        scheduleRefresh()
    }
    /// Run an arbitrary node mutation on `core` (no return value), then pump.
    func nodeDo(_ work: @escaping (HopNode) -> Void) {
        core.async { [weak self] in guard let self else { return }; work(self.node) }
        pump()
    }

    public init(config: Config) {
        self.config = config
        // Persistent message store on disk - survives restarts; bounded (older relayed messages
        // are evicted). Identity is derived from the host-supplied seed (stable address every
        // launch, no storage to fail). The app secret isolates this app's hps:// channels/services
        // from other apps: only apps built with the same secret can discover/join them (§32).
        // F-25: open the store SQLCipher-encrypted with the device-derived db key (empty key ⇒ plain,
        // same as open). Only actually encrypts when libhop is built `--features sqlcipher`.
        self.node = HopNode.openKeyed(dbPath: config.dbPath, secret: config.deviceSeed,
                                      appSecret: config.appSecret, key: config.dbKey)
        // Our address is immutable (derived from the seed). Cache it now - at init no queue is
        // running yet, so this lone read is safe - so UI/render paths never touch `node` for it.
        self.myAddrCache = node.address()
        self.myShortAddr = HopBearer.shortData(myAddrCache)
        super.init()
    }

    /// Our own raw 32-byte address, cached at init (immutable). Lets UI/render read it without
    /// hopping to `core`. Internal (not private) so the per-concern sibling extension files (Hps/Services)
    /// can reach it; still module-private.
    let myAddrCache: Data
    let myShortAddr: Data   // 8-byte short form (for resolving our own trace hops, §27)

    // NOTE: the legacy BLE service/characteristic UUIDs (F09000xx…) and the iBeacon proximity UUID moved
    // to the shared bearer with the transport code. HopBearerBle owns SERVICE_UUID / ENDPOINT_CHAR and
    // the byte-matched BEACON_UUID (monitor + emission), so the driver no longer declares them (F-40).
    public static let refreshTaskId = "sh.hopme.refresh"
    /// Longer background-processing task (runs idle/charging) to drain a backlog - e.g. a
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

    // The UI value types (Peer / Message / QueueRow / TransportStatus / HnsCacheRow / HpsTopic /
    // HpsMsgRow / HpsHostSnapshot / HopResponse) live in HopModels.swift as `extension HopBearer`, so they
    // remain `HopBearer.Peer` etc. but no longer bulk up the class body.

    @Published public var myAddress = ""
    @Published public var myName = ""
    /// Privacy: when on, we stop broadcasting our presence advert (name + address), so we don't
    /// show up by name in others' nearby lists. We stay fully relay-capable and reachable by anyone
    /// who already has our address (e.g. via a scanned QR / manual add). Persisted.
    @Published public var privateMode: Bool = UserDefaults.standard.bool(forKey: "hop.privateMode") {
        didSet {
            UserDefaults.standard.set(privateMode, forKey: "hop.privateMode")
            if privateMode { retractPresence() } else { publishPresence() }
            // apple-03: also (un)advertise the Wi-Fi (Multipeer) bearer so private mode actually stops
            // broadcasting on every transport, not just the relay presence.
            if privateMode { mcAdvertiser?.stopAdvertisingPeer() } else { mcAdvertiser?.startAdvertisingPeer() }
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
    /// relay - routing is anycast - so pinning overrides the default anycast target for testing
    /// a specific relay, rather than publishing presence to several at once.
    @Published public var pinnedRelay: String? = UserDefaults.standard.string(forKey: "hop.pinnedRelay")
    @Published public var linkTransports: [Data: Set<String>] = [:]  // direct peer → transport(s) carrying it
    @Published public var relays: [Peer] = []   // connected cloud relays (named by their domain via hop.identify)
    @Published public var endpoints: [Peer] = []   // directly-dialed hops:// endpoints (§30; not relays)
    @Published public var hnsCache: [HnsCacheRow] = []   // live HNS cache w/ ticking TTLs (§30, debug)

    // hps:// pub/sub - services & channels (§32). Topics we host or subscribe to, the messages
    // per topic (one thread each), per-topic unread, and invites we've received.
    @Published public var hpsTopics: [HpsTopic] = []
    @Published public var hpsThreads: [String: [HpsMsgRow]] = [:] { didSet { scheduleChannelSave() } }   // topic id → its messages
    @Published public var hpsUnread: [String: Int] = [:]            // topic id → unread count
    @Published public var hpsInvites: [HpsInvite] = []              // invites received (FFI record)
    var activeTopic: String?                                 // topic on screen (not counted)

    /// Resolved display name per 8-byte short address, for resolving trace hops (§27/§29).
    @Published public var nameByShort: [Data: String] = [:]
    @Published public var serviceLog: [String] = []   // hop.identify + custom service-call activity (§29)
    var identities: [Data: IdentityInfo] = [:]   // address → identify record (internal: test seam)
    var identifyAsked = Set<Data>()              // addresses we've sent hop.identify to (internal: sibling files)
    var identifyReqs = Set<Data>()               // outstanding identify request bundle ids (internal: test seam)
    @Published public var messages: [Message] = [] { didSet { scheduleMessageSave() } }
    /// Latest hops:// result per domain, rendered for the UI ("200 · <body>" or an error).
    @Published public var hopsResults: [String: String] = [:]   // domain → rendered text (§30)
    @Published public var queue: [QueueRow] = []
    @Published public var unread: [String: Int] = [:] { didSet { updateAppBadge() } }   // peer name → unread incoming count
    var activePeer: String?              // chat currently on screen (not counted) (internal: sibling files)
    private var loadingMessages = false          // suppress save while restoring history
    private var messageSaveWork: DispatchWorkItem?  // debounced history write
    private var channelSaveWork: DispatchWorkItem?  // debounced channel-thread write

    /// The Hop node - created in `init(config:)` from the host's db path / identity seed / app
    /// secret. Identity is derived from the seed (stable address every launch, no storage to
    /// fail); the db persists *messages*.
    let node: HopNode

    /// Shared app secret for Hop Debug - all our demo devices use it so they interoperate. A
    /// different app (different secret) can't see or join these channels. Exposed so a host can
    /// build the dev `Config`; to test cross-app isolation, change it on one device.
    public static let appSecret = Data(repeating: 0x48, count: 32) // "H" ×32 - dev build only
    // Wi-Fi bearer (MultipeerConnectivity) - a second transport feeding the same node.
    var mcPeerID: MCPeerID?
    var mcSession: MCSession?
    var mcAdvertiser: MCNearbyServiceAdvertiser?
    var mcBrowser: MCNearbyServiceBrowser?
    var mcLinkByPeer: [MCPeerID: UInt64] = [:]
    var mcPeerByLink: [UInt64: MCPeerID] = [:]
    var mcNextLinkId: UInt64 = 10_000   // distinct id range from BLE links
    var wifiBlocked = false             // MC failed to start (e.g. local-network denied)
    // Cloud relay is owned ENTIRELY by the shared RelayBearer (bearers/apple/HopBearerRelay), registered
    // in startSharedBearers(). apple-r2-01: the legacy in-driver relay dial (WS/TCP on relayLinkId 20000)
    // was deleted. It was dead code whose only public entry (connectRelay) could open a SECOND concurrent
    // relay socket and reintroduce the split-brain the apple-06 fix removed. `relaySession` below is kept
    // because the direct hops:// endpoint dialer (§30) reuses one URLSession for all endpoint links.
    var relaySession: URLSession?
    // Direct WS links to hops:// endpoints (DESIGN.md §30). The client dials the endpoint at
    // wss://<domain> - it does NOT transit our relay (domain traffic stays off the fleet) - so
    // the endpoint authenticates via Noise as its HNS-published address and becomes a direct
    // peer we can seal requests to. Keyed by a distinct link-id range.
    var endpointWS: [UInt64: URLSessionWebSocketTask] = [:]
    var endpointLinkByDomain: [String: UInt64] = [:]
    var nextEndpointLinkId: UInt64 = 30_000
    // NOTE: the legacy in-driver BLE (L2CAP HopLink + GATT-data fallback) and LAN (mDNS + TCP LanLink)
    // transport state was removed in the app cutover. Those transports are now owned entirely by the
    // shared BleBearer / LanBearer (HopBearerBle / HopBearerLan), which mint their links through the
    // BearerManager. Multipeer (Wi-Fi P2P), the cloud relay, and hops:// endpoints remain in-driver.
    var nameByAddr: [Data: String] = [:]       // internal: test seam
    var contacts: [Data: Peer] = [:]   // app-side contact book (address → peer) (internal: test seam)
    /// Our own raw 32-byte address (for marking our own hps posts).
    public var myAddressData: Data { myAddrCache }
    /// True once `start()` has wired the runtime (bearers up, `myAddress` published). Used by the
    /// TEST/AUTOMATION cold-launch send to retry until the runtime is live rather than fire blind.
    public var isReady: Bool { !myAddress.isEmpty }
    /// Contacts as a sorted list (for the invite picker).
    public var contactList: [Peer] { contacts.values.sorted { $0.name.lowercased() < $1.name.lowercased() } }
    var userNamed = Set<Data>()        // contacts the user named (identify won't override) (internal: sibling files)
    // hops:// fetches awaiting an HNS resolution: domain → the path to request once the
    // record resolves (DESIGN.md §30).
    var pendingHops: [String: String] = [:]   // internal: test seam
    // In-flight hops:// requests: request id → the domain it's for, so a response can be
    // matched back and rendered into `hopsResults`.
    var hopsReqs: [Data: String] = [:]   // internal: test seam
    // The hops:// WebView path (DESIGN.md §30): callback-style fetches that feed a WKWebView
    // (the manual `hopsResults` field above is for the text test box only). Request id →
    // completion, and per-domain queues for requests issued before HNS resolves.
    var hopsWebReqs: [Data: (HopResponse) -> Void] = [:]   // internal: test seam
    var hopsWebPending: [String: [(path: String, completion: (HopResponse) -> Void)]] = [:]   // internal: test seam
    /// Test seam (cov/apple-hns): when set, `openHops`/`hopsFetch` ask this closure for the domain's
    /// `HnsLookupResult` instead of the real node. A fresh headless node with no peers and no internet
    /// always settles `resolveHns` to `.pending` (hop-core queues a retry and defers - it can never itself
    /// produce `.cached` or `.needsResolver` without a live peer or a completed DoH round trip), so a unit
    /// test cannot reach those two branches through the real node. Defaults to nil, so production is
    /// unchanged: always resolves through the real `node.resolveHns`.
    var resolveHnsForTest: ((String) -> HnsLookupResult)?
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
    let bearerMgr = BearerManager(baseLinkId: 1_000_000)
    /// One stable transport id for this process, shared by every registered bearer (the BLE/LAN HELLO id
    /// + the greater-id dedup tiebreaker). This is a TRANSPORT-layer id, distinct from the Hop node
    /// address (SPEC R11) - the node still negotiates Noise over the bearer's DATA frames.
    private let bearerId: Data = HopContract.randomNodeId()
    /// The shared BLE bearer, kept as a ref so a background wake can poke its `wake()` to re-arm
    /// scanning + re-adopt connected peripherals promptly (it self-recovers on `.poweredOn` too).
    /// A central-only host (hopmac) suppresses advertising so it scans/dials but stays undiscoverable.
    private lazy var bleBearer = BleBearer(myId: bearerId, suppressAdvertising: config.role == .centralOnly)
    /// Link ids currently owned by the `BearerManager`, so `applyOutgoing` routes their packets to it.
    /// Written from the sink callbacks (BLE I/O thread / LAN queue) and read in `applyOutgoing` (main) -
    /// guarded by `bearerLinksLock`.
    var bearerLinks = Set<UInt64>()
    let bearerLinksLock = NSLock()
    /// Strong ref to the sink adapter - `BearerManager.sink` holds it weakly.
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
        //  • setName - what hop.identify reports for us (§29).
        //  • tick - set the node clock to real time BEFORE any advert. The node starts at now_ms=0,
        //    so a prekey/presence advert stamped created_at=0 would be judged expired (1970 + TTL)
        //    and dropped instantly. Presence re-publishes and recovers, but the prekey is published
        //    once: without this peers never learn it and every message defers forever (§25).
        //  • subscribe - presence is an app-level service (§23): publish our name on "presence" and
        //    subscribe so discovered records are retained. The protocol knows nothing about names.
        //  • publishPrekey - once; long TTL + link-up gossip re-offer it to new neighbours (§25).
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
            // word until we return - peers show that as our state). The shared LAN and Relay
            // bearers manage their own lifecycle/backoff, so foreground only needs the flag + Wi-Fi.
            let nc = NotificationCenter.default
            nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.appActive = true
                // apple-02: setBackground(false) resets the liveness deadline AND ends the bg-task
                // assertion (nothing to protect in the foreground).
                self.bleBearer.setBackground(false)
                self.publishPresence(); self.restartWiFi()
                self.pump()
            }
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.appActive = false
                // apple-02: setBackground(true) relaxes the liveness deadline AND takes a bg-task
                // assertion when links are live, so a suspend doesn't kill an in-flight receive.
                self.bleBearer.setBackground(true)
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
                    // Declare whether we can reach the public internet (any interface - Wi-Fi,
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
    /// rename propagates. The advert's publisher field is our address - that's all a
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
        // apple-r3-01: a backgroundTick is a background/locked wake. Its pump can drain a received
        // message out of the node inbox into `messages`; flush the mirror synchronously once that inbox
        // has been applied so the message survives if iOS suspends/kills us before the 1s save-debounce
        // fires (otherwise it's gone from the node inbox but never reached messages.json).
        pump(flushAfter: true)
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

    // Outbound + inbound messaging (addContact / clearQueue / send / sendTo / sendImage / sendMultipart /
    // retry / encodeMultipart / decodeMultipart / applyInbox) lives in HopBearer+Messaging.swift. The
    // @Published messages/unread + contact bookkeeping stay on this class.

    // MARK: - Wi-Fi (MultipeerConnectivity) bearer

    // apple-r2-05: this Multipeer (Wi-Fi P2P) transport is RETAINED IN-DRIVER, on purpose. There is no
    // "MultipeerBearer" package and it was never extracted behind the shared Bearer/LinkSink contract, so
    // any doc/memory that calls it "the deleted MultipeerBearer" is inaccurate: MC is the one transport
    // still minted by the driver itself (its own mcNextLinkId 10000 space + lifecycle, routed in
    // applyOutgoing via mcPeerByLink). BLE/LAN/Relay are the extracted bearers; MC and the direct hops://
    // endpoint links are not. Extracting MC into a HopBearerP2P package for parity is future work, not a
    // regression, so it is left in place here.

    /// A random per-PROCESS Multipeer transport id, used as the MCPeerID displayName instead of the node
    /// address (apple-03). The Bonjour/AWDL display name is broadcast in cleartext to every nearby Wi-Fi
    /// observer, so it must NOT carry the stable long-term node address (that would let a passive observer
    /// harvest + correlate the device across locations, defeating §39 untraceable-by-default). The
    /// displayName is only used for the lexicographic initiator/responder tiebreak below; a random hex id
    /// preserves that. Node identity is still negotiated over Noise on the link, exactly like BLE.
    let mcTransportId: String = HopContract.hex(HopContract.randomNodeId())

    // startWiFi() / restartWiFi() moved to HopBearer+Radios.swift (device/radio surface, excluded from
    // the coverage denominator). The MC stored state above stays on the class.

    // NOTE: The legacy in-driver LAN transport (a Bonjour `_hoplan._tcp` listener + browser + LanLink)
    // was removed in the app cutover. The shared LanBearer (registered by startSharedBearers on a full
    // host) now owns the entire mDNS + TCP LAN path.

    // MARK: - Shared HopBearers wiring (BLE + LAN + relay through one BearerManager)

    /// Stand up the shared transport layer. First point the BLE transport's iOS host hooks at the
    /// driver's existing infrastructure - the dedicated `bleQueue` (CoreBluetooth callbacks) and the
    /// long-lived `IOThread` runloop (L2CAP streams + timers), REUSED rather than spinning a second I/O
    /// thread - and seed the background flag. Then register the bearers this ROLE wants and start. Every
    /// link surfaces through `bearerSink`, which drives the node seam (`linkUp` / `deliver` / `linkDown`).
    /// `BleBearer` is pure-L2CAP by design (no GATT-data fallback). Registration is role-aware:
    ///   • .full        - BLE (advertising) + LAN + cloud relay (if a relay is configured).
    ///   • .centralOnly - BLE ONLY, advertising suppressed (scan/dial but stay undiscoverable): the
    ///                    headless macOS test node (hopmac). No LAN, no relay.
    ///   • .relayOnly   - cloud relay ONLY, NO BLE (never appears on Bluetooth) and no LAN (relaymac).
    private func startSharedBearers() {
        HopBearerBle.bleQueue = bleQueue
        HopBearerBle.bleRunLoop = IOThread.shared.runLoop
        bleBearer.setBackground(!appActive)   // seed liveness flag (no links yet, so no assertion taken)
        bearerMgr.sink = bearerSink
        if !isRelayOnly {
            bearerMgr.register(bleBearer)   // BLE (central-only suppresses advertising via config.role)
        }
        if isFull {
            bearerMgr.register(LanBearer(myId: bearerId))   // LAN (mDNS + TCP) - full host only
        }
        // Cloud relay (WebSocket) as a shared bearer - ONE outbound link to the backbone, on any host that
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
    /// apple-06: the global link id of the live shared RelayBearer link (nil when the relay is down), so
    /// the UI's `relayStatus` tracks the REAL shared relay socket instead of the never-invoked legacy
    /// WS/TCP path. Read/written on the bearer work queue + main; touched under `bearerLinksLock`.
    var relayBearerLinkId: UInt64?
    // bearerLinkUp / bearerDeliver / bearerLinkDown moved to HopBearer+Radios.swift (fire only on a real
    // radio link; excluded from the coverage denominator). The link-id state above stays on the class.

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
        // apple-06: the ACTIVE relay is the shared RelayBearer (registered with `pinnedRelay ?? default`
        // at startup). Dialing the legacy connectRelay path here opened a SECOND concurrent relay link to
        // a different relay while the shared bearer kept its original socket (split-brain: duplicated
        // presence/traffic, confounded relay tests). The shared BearerManager has no live re-register, so
        // the pin is persisted and takes effect on next start; we do NOT open the legacy link.
        relayStatus = "pin set - restart to switch relay"
    }

    // dialEndpoint / receiveEndpoint / endpointLink(for:) moved to HopBearer+Radios.swift (direct hops://
    // endpoint WebSocket I/O; excluded from the coverage denominator). The endpoint state above stays on
    // the class.

    // MARK: - plumbing

    /// Drain ALL node outputs on `core` (the only queue allowed to touch `node`), then apply the
    /// resulting plain-data snapshots on main (link routing + @Published + bookkeeping). Safe to call
    /// from any thread.
    /// Drain the node and apply results on the main actor. `flushAfter` (set by a background wake, see
    /// `backgroundTick`) forces the debounced mirror writes to disk synchronously once the inbox has been
    /// applied, so a message received during a short/locked background wake can't be lost to the 1s save
    /// debounce if iOS suspends us (apple-r3-01).
    func pump(flushAfter: Bool = false) {
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
                // apple-r3-01: persist NOW (don't wait out the 1s debounce) on a background wake.
                if flushAfter { self.flushPendingSaves() }
            }
        }
    }

    /// Route outgoing packets to their link (main). The shared BearerManager owns BLE + LAN + relay;
    /// Multipeer and the direct hops:// endpoint links are the only transports the driver still mints
    /// itself. (apple-r2-01: the legacy in-driver relay dial on relayLinkId was deleted; relay is the
    /// shared RelayBearer only.)
    func applyOutgoing(_ outgoing: [OutPacket]) {
        for pkt in outgoing {
            if bearerLinksContains(pkt.link) {              // shared BearerManager (BLE + LAN + relay) owns it
                bearerMgr.send(pkt.bytes, on: pkt.link)
            } else if let peer = mcPeerByLink[pkt.link] {
                try? mcSession?.send(pkt.bytes, toPeers: [peer], with: .reliable) // Wi-Fi (Multipeer) link
            } else if let ws = endpointWS[pkt.link] {
                ws.send(.data(pkt.bytes)) { _ in }         // direct hops:// endpoint link (§30)
            }
        }
    }

    // applyInbox(_:), which surfaces received messages into the UI, lives in HopBearer+Messaging.swift.

    // MARK: - hps:// pub/sub (DESIGN.md §32)
    // The hps:// pub/sub methods (register / subscribe / publish / invite / moderate / browse + the
    // received-message + invite apply paths) live in HopBearer+Hps.swift. The @Published topic/thread/
    // unread/invite state stays on this class; that sibling file drives the node + mutates it exactly as
    // before.

    // MARK: - Services & commands (DESIGN.md §29)
    // The hop.identify round-trip (queueIdentify / identify / identity / displayName / traceLabel) and the
    // generic service request/response drain live in HopBearer+Services.swift. The identity bookkeeping
    // stored properties stay on this class; that sibling file drives them exactly as before.

    // Open-web HTTP fetch via a third-party gateway was removed: a gateway that fetches
    // https:// on your behalf terminates TLS = a MitM (DESIGN.md §25). The model is now
    // origin-run gateways reached via `hops://<domain>` (the gateway serves *its own*
    // service over the mesh, no third party in the middle).

    // MARK: - HNS & hops:// (DESIGN.md §30)
    // The HNS + hops:// node-driving methods (openHops / hopsFetch / parseHops + the applyHnsResults /
    // applyHttpResponses / applyDnsLookups drains) live in HopBearer+Hns.swift. The network-bound senders
    // (fireHops / fireHopsWeb / fetchDnssecChain) stay in HopBearer+Radios.swift.

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

    // MARK: - Persistence (delegated to MirrorStore)
    //
    // The on-disk UI-history mirror (messages/channels/contacts.json) + the TEST/AUTOMATION plaintext dump
    // are owned by `MirrorStore` (pure file I/O + Codable DTOs + write policy). HopBearer keeps only the
    // pieces coupled to its @Published state: the debounce/throttle timers and the `loadingMessages` guard
    // that suppresses save-on-load. The static forwarders below preserve the existing test/host API surface
    // (`HopBearer.messagesFileURL` / `.uiMirrorProtection` / `.automationMirrorEnabled`).

    /// apple-r2-03 write options for the UI-history mirrors (see `MirrorStore.uiMirrorProtection`).
    static var uiMirrorProtection: Data.WritingOptions { MirrorStore.uiMirrorProtection }
    /// The chat-history mirror path (the apple-r3-01 flush test reads it).
    static var messagesFileURL: URL { MirrorStore.messagesFileURL }

    /// Coalesce rapid mutations into one disk write (≤1 write/sec) so appending a burst of
    /// messages doesn't re-encode the whole history each time.
    private func scheduleMessageSave() {
        guard !loadingMessages else { return }   // don't echo the load back to disk
        messageSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveMessages() }
        messageSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// apple-r3-01: flush any pending debounced mirror writes SYNCHRONOUSLY. The 1s debounce in
    /// `scheduleMessageSave`/`scheduleChannelSave` coalesces write bursts, but it also opens a window:
    /// a background/locked wake drains the node inbox into `messages` (destructive `takeInbox`), yet the
    /// mirror write is deferred 1s. If iOS suspends or kills the app inside that window, the received
    /// message is gone from the node inbox but not yet in messages.json, so it vanishes from chat history
    /// on relaunch. Calling this at the end of a background pump and on scenePhase==.background cancels the
    /// pending debounce and writes NOW, closing the window. Idempotent and cheap when nothing is pending
    /// (only writes if a save was actually queued). Must be called on the main actor (touches `messages`).
    public func flushPendingSaves() {
        if messageSaveWork != nil {
            messageSaveWork?.cancel()
            messageSaveWork = nil
            saveMessages()
        }
        if channelSaveWork != nil {
            channelSaveWork?.cancel()
            channelSaveWork = nil
            saveChannels()
        }
    }

    func saveMessages() {
        MirrorStore.saveMessages(messages)
        writeAutomationDump()   // TEST/AUTOMATION: mirror self-addr + rx/tx for the headless harness
    }

    // MARK: - Automation control surface (TEST/AUTOMATION hook - headless harness only)

    /// TEST/AUTOMATION: the HOP_AUTO launch env this process observed at init, mirrored into the dump so
    /// the harness can confirm the env actually reached the app (vs a silent send failure). Not a user path.
    public static var autoEnvSeen: String = ""
    /// The plaintext-mirror GATE, pure + testable (see `MirrorStore.automationMirrorEnabled`). Forwarded so
    /// the existing test pins `HopBearer.automationMirrorEnabled(isDebug:hopAutoEnv:)` are unchanged.
    static func automationMirrorEnabled(isDebug: Bool, hopAutoEnv: String?) -> Bool {
        MirrorStore.automationMirrorEnabled(isDebug: isDebug, hopAutoEnv: hopAutoEnv)
    }
    /// Rewrite the automation mirror (last ~100 rx + tx). Called on every message change (from
    /// `saveMessages`) and once at startup so `self` is discoverable even before any traffic.
    func writeAutomationDump() {
        MirrorStore.writeAutomationDump(messages: messages, myAddress: myAddress,
                                        myName: myName, autoEnvSeen: HopBearer.autoEnvSeen)
    }

    private func scheduleChannelSave() {
        guard !loadingMessages else { return }
        channelSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveChannels() }
        channelSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
    func saveChannels() { MirrorStore.saveChannels(hpsThreads) }
    func loadChannels() {
        guard let stored = MirrorStore.loadChannels() else { return }
        loadingMessages = true
        hpsThreads = stored
        loadingMessages = false
    }

    func loadMessages() {
        guard let restored = MirrorStore.loadMessages() else { return }
        loadingMessages = true
        // An outgoing message still in flight when we quit KEEPS sending: the node persists the bundle and
        // re-sprays it after restart until its delivery ACK (node.rs rehydrate). MirrorStore restores it
        // in-flight with its bundleId - refresh() re-queries messageStatus and it flips to Delivered when
        // the ACK lands - rather than falsely marking it "Not sent".
        messages = restored
        loadingMessages = false
    }

    // MARK: - Address book persistence (past conversations survive restart + going out of range)

    private var lastContactSaveAt = Date.distantPast
    /// Add a peer to the address book and persist immediately (e.g. on send / manual add) so the
    /// conversation is reachable even if we quit before the next throttled save.
    public func rememberContact(_ peer: Peer) {
        if contacts[peer.address] == nil { contacts[peer.address] = peer }
        nameByAddr[peer.address] = peer.name
        saveContacts(force: true)
    }
    /// Persist the address book, throttled (refresh runs often). Anyone we've seen, messaged, or been
    /// messaged by is kept, so their conversation is reachable even when offline / out of range. The
    /// throttle decision stays here (owns `lastContactSaveAt`); MirrorStore does the snapshot + async write.
    func saveContacts(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastContactSaveAt) > 4 else { return }
        lastContactSaveAt = Date()
        MirrorStore.saveContacts(Array(contacts.values))
    }
    func loadContacts() {
        guard let loaded = MirrorStore.loadContacts() else { return }
        for c in loaded where contacts[c.address] == nil {
            contacts[c.address] = c
            nameByAddr[c.address] = c.name
        }
    }

    private var refreshScheduled = false

    /// Coalesced UI refresh. `refresh()` does synchronous SQLite work (browse, queue, per-message
    /// status) and is far too expensive to run on every `pump()` - which fires on every received
    /// packet across BLE/Wi-Fi/LAN/relay. Running it per-packet saturates the main thread (watchdog
    /// 0x8BADF00D + cpu_resource kills, sluggish UI). Coalesce to ~4 Hz; the hot path still drains
    /// outgoing and the inbox immediately, only the heavy snapshot is throttled. Internal (not private) so
    /// the sibling extension files (Services) can request a coalesced refresh after mutating shared state.
    func scheduleRefresh() {
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

    /// One node-read snapshot for `refresh` - gathered entirely on `core`, applied on main.
    struct RefreshSnapshot {
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
    func refresh() {
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
    func applyRefresh(_ snap: RefreshSnapshot) {
        // Discover peers by browsing the app-level "presence" service. A device may re-publish several
        // presence adverts (one per refresh); RefreshMapper collapses them to one row per address (nearest
        // hop count for distance, newest advert for name/state) - the contact-book logic the protocol no
        // longer carries (DESIGN.md §23). Sorted by the stable address so rows don't jump as hops/names churn.
        let (reachablePeers, names) = RefreshMapper.aggregatePresence(snap.browse)
        for (addr, name) in names { nameByAddr[addr] = name }
        reachable = reachablePeers

        // Accumulate everyone we've ever seen into the (persisted) contact book; those not
        // currently reachable form the "seen" list - reachable across restarts + out-of-range.
        for peer in reachable { contacts[peer.address] = peer }
        let here = Set(reachable.map { $0.address })
        seen = contacts.filter { !here.contains($0.key) }
            .map { Peer(address: $0.key, name: $0.value.name, hops: 0,
                        active: false, platform: $0.value.platform, app: $0.value.app) }
            .sorted { $0.address.lexicographicallyPrecedes($1.address) }
        saveContacts()   // throttled - persist the address book

        // Forward-secret sessions (lock icon) + learned live routes (§27) - computed on core.
        secured = snap.secured
        routed = snap.routed

        // Per-transport status - several bearers run at once (DESIGN.md §26). The headline
        // count is the *actual transport-level connections* (what the user means by
        // "linked"), not just handshake-complete Hop links - otherwise a peer that's
        // connected but mid-Noise-handshake shows as zero. The expandable list below
        // shows the identified peers (and notes any still establishing).
        // MC keeps its session object even when Wi-Fi is off; trust the real radio (or
        // the presence of live MC links) instead. Peer-to-Peer (MultipeerConnectivity/AWDL, no router)
        // is NOT a shared bearer, so it keeps its own live-link/radio signal.
        let p2pActive = !wifiBlocked && (wifiUp || !mcPeerByLink.isEmpty)
        let pls = snap.peerLinks
        // The shared bearers mint links through the BearerManager (baseLinkId 1_000_000+), NOT any legacy
        // radio object, so per-transport status comes from the manager's live links - each short tag mapped
        // to its display id. Multipeer (Peer-to-Peer) is not a shared bearer, so it's added separately.
        let active = bearerMgr.activeTransports()          // short tag → live link count
        transports = RefreshMapper.transportStatuses(active: active, p2pActive: p2pActive,
                                                     p2pLinks: mcPeerByLink.count)

        // Map each direct neighbour to the transport(s) carrying it (the route). Shared-bearer links are
        // minted by the BearerManager (baseLinkId 1_000_000+), so the legacy link-id ranges can't tag
        // them - ask the manager for the owning bearer's REAL transport first, then fall back to the
        // legacy ranges for any link the node still mints itself (Multipeer, legacy relay/endpoints).
        var lt = [Data: Set<String>]()
        for pl in pls {
            let t: String
            if bearerLinksContains(pl.link), let tag = bearerMgr.transportName(of: pl.link) {
                t = tag                          // shared bearer: real transport ("BT"/"LAN"/"Relay")
            } else {
                t = RefreshMapper.legacyTransportTag(pl.link)   // node-minted link (Multipeer / legacy)
            }
            lt[pl.address, default: []].insert(t)
        }
        linkTransports = lt

        // A live local radio link (BLE / Wi-Fi P2P) IS a 1-hop path, so force the hop count to 1
        // for those peers - even if a stale presence advert arrived via the relay at 2 hops. This
        // keeps "direct" honest: a peer is direct iff hops <= 1, so a live-linked peer shows
        // "1 hop · BT" (never "2 hops"), and a peer with no live link at 2 hops stays in the mesh.
        reachable = reachable.map { p in
            var p = p
            if let t = lt[p.address], t.contains("BT") || t.contains("P2P") || t.contains("LAN") { p.hops = 1 }
            return p
        }

        // Connected cloud relays, named by their region domain via hop.identify (§29). apple-r2-01: the
        // relay is now the SHARED RelayBearer (its link surfaces via the BearerManager with transportName
        // "Relay", link id 1_000_000+), NOT the deleted legacy 20_000 dial. So classify by the bearer's
        // real transport tag; fall back to the legacy 20_000..<30_000 range only for any node-minted relay
        // link (there are none after the cutover, kept for safety). Endpoints (30_000+) are dialed directly
        // and never join the backbone (§30), so they're listed separately below.
        relays = pls.filter { pl in
            if bearerLinksContains(pl.link) { return bearerMgr.transportName(of: pl.link) == "Relay" }
            return (20_000..<30_000).contains(pl.link)
        }.map { pl in
            let name = identities[pl.address]?.name.isEmpty == false
                ? identities[pl.address]!.name
                : (nameByAddr[pl.address] ?? HopBearer.shortHex(pl.address))
            return Peer(address: pl.address, name: name, hops: 1, platform: "cloud", app: "Hop Relay")
        }
        .sorted { $0.name < $1.name }

        // Connected hops:// endpoints (the directly-dialed origin links, the legacy 30_000-39_999
        // range). NOT the relay backbone; we reach them straight (DESIGN.md §30). Bounded to that
        // range so the new shared-bearer links (BearerManager baseLinkId 1_000_000+ - ordinary
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

        queue = RefreshMapper.mapQueue(snap.queue)
        // Live HNS cache snapshot (ticks down each refresh as the node clock advances, §30).
        hnsCache = RefreshMapper.mapHnsCache(snap.hnsCache)
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

    // notifyIfBackgrounded(from:text:) moved to HopBearer+Radios.swift (posts a UIKit-app-state user
    // notification; excluded from the coverage denominator).

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
    /// The 8-byte short form of a full address - matches what trace hops carry (§27).
    static func shortData(_ d: Data) -> Data { shortAddress(address: d) }
    /// Hex of an arbitrary byte string (for an unresolved short trace hop).
    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
}
