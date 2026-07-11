import Foundation

/// The on-disk UI-history mirror layer, extracted out of the HopBearer god-object so persistence is one
/// cohesive concern. It owns the mirror file URLs, the Codable on-disk DTOs, the encode/decode + write
/// policy, and the TEST/AUTOMATION plaintext dump gate: everything that is pure file I/O. HopBearer keeps
/// only the @Published state + the debounce/throttle orchestration (which is coupled to the observable
/// surface) and delegates every read/write here. Behavior is unchanged: the same file paths, the same
/// protection class, the same encode/decode, moved verbatim.
///
/// The mirror files live in the process-global Documents dir (as in production), and the node's SQLCipher
/// `hop.db` remains the source of truth; these files only back the chat list the UI reads on relaunch.
enum MirrorStore {

    // MARK: - Write policy

    /// apple-r2-03: the write options for the plaintext UI-history mirrors (messages/channels/contacts).
    /// These are appended to on an INBOUND receive, which can happen while the device is LOCKED in the
    /// background (background BLE/relay wake). `.completeFileProtection` DENIES writes while locked, so a
    /// locked background receive would fail to persist and, since `takeInbox` already drained the node
    /// inbox into the in-memory array, the message could vanish from the UI on the next relaunch (a
    /// user-visible history gap; the SQLCipher node store still has it, but the chat list reads this
    /// mirror). `.completeFileProtectionUntilFirstUserAuthentication` (the `Data.WritingOptions` spelling
    /// of NSFileProtectionCompleteUntilFirstUserAuthentication) keeps the bytes encrypted at rest yet lets
    /// the write SUCCEED any time after the first post-boot unlock, so a locked background receive
    /// persists. The node store (hop.db) remains the source of truth; this only closes the mirror gap.
    static let uiMirrorProtection: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var messagesFileURL: URL { documents.appendingPathComponent("messages.json") }
    static var channelsFileURL: URL { documents.appendingPathComponent("channels.json") }
    static var contactsFileURL: URL { documents.appendingPathComponent("contacts.json") }
    static var automationFileURL: URL { documents.appendingPathComponent("automation.json") }

    // MARK: - Message history (survives app restart)

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

    /// Encode the chat history and write the mirror (encrypted-at-rest, locked-write-safe). Returns nothing;
    /// a failure is silent (best-effort mirror, node store is source of truth).
    static func saveMessages(_ messages: [HopBearer.Message]) {
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
        // apple-04/apple-r2-03: encrypt this history at rest (so plaintext chat + image bytes don't sit
        // unprotected beside the SQLCipher hop.db or leak via a device backup), but with
        // completeFileProtectionUntilFirstUnlock so a locked background receive can still persist (see
        // uiMirrorProtection). No-op on macOS (no data protection), effective on iOS.
        try? data.write(to: messagesFileURL, options: uiMirrorProtection)
    }

    /// Read the chat-history mirror back into `Message`s (nil if there is no file / it is unreadable).
    /// An outgoing message still in flight when we quit KEEPS sending: the node persists the bundle and
    /// re-sprays it after restart until its delivery ACK (node.rs rehydrate). So we restore it in-flight
    /// with its bundleId - refresh() re-queries messageStatus and it flips to Delivered when the ACK lands -
    /// rather than falsely marking it "Not sent".
    static func loadMessages() -> [HopBearer.Message]? {
        guard let data = try? Data(contentsOf: messagesFileURL),
              let stored = try? JSONDecoder().decode([StoredMessage].self, from: data) else { return nil }
        return stored.map { s in
            HopBearer.Message(peer: s.peer, text: s.text, incoming: s.incoming, peerAddr: s.peerAddr,
                              contentType: s.contentType, imageData: s.imageData, images: s.images,
                              bundleId: s.bundleId,
                              hops: s.hops, latencyMs: s.latencyMs, sentAt: s.sentAt,
                              deliveredAt: s.deliveredAt, relayed: s.relayed, delivered: s.delivered,
                              deliveryHops: s.deliveryHops, failed: s.failed)
        }
    }

    // MARK: - Channel (hps) threads

    static func saveChannels(_ threads: [String: [HopBearer.HpsMsgRow]]) {
        guard let data = try? JSONEncoder().encode(threads) else { return }
        try? data.write(to: channelsFileURL, options: uiMirrorProtection)  // apple-04/apple-r2-03
    }

    static func loadChannels() -> [String: [HopBearer.HpsMsgRow]]? {
        guard let data = try? Data(contentsOf: channelsFileURL),
              let stored = try? JSONDecoder().decode([String: [HopBearer.HpsMsgRow]].self, from: data) else { return nil }
        return stored
    }

    // MARK: - Address book (past conversations survive restart + going out of range)

    private struct StoredContact: Codable { var address: Data; var name: String; var platform: String; var app: String }

    /// Snapshot + write the address book off the main thread (a utility queue), as the throttled `refresh`
    /// caller expects. The throttle decision itself stays on HopBearer (it owns `lastContactSaveAt`).
    static func saveContacts(_ peers: [HopBearer.Peer]) {
        let snapshot = peers.map {
            StoredContact(address: $0.address, name: $0.name, platform: $0.platform, app: $0.app)
        }
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: contactsFileURL, options: uiMirrorProtection)  // apple-04/apple-r2-03
        }
    }

    /// Read the address book back as `Peer`s (hops=0, not-active, since they are historical until re-seen).
    /// The caller merges these into its live contact map (keeping any already-present entry).
    static func loadContacts() -> [HopBearer.Peer]? {
        guard let data = try? Data(contentsOf: contactsFileURL),
              let stored = try? JSONDecoder().decode([StoredContact].self, from: data) else { return nil }
        return stored.map {
            HopBearer.Peer(address: $0.address, name: $0.name, hops: 0,
                           active: false, platform: $0.platform, app: $0.app)
        }
    }

    // MARK: - Automation control surface (TEST/AUTOMATION hook - headless harness only)

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
        let auto: String   // TEST/AUTOMATION breadcrumb: the raw HOP_AUTO launch env this process saw ("" if none)
    }

    /// apple-04/apple-r2-03: the plaintext-mirror GATE, pure + testable. A plaintext automation.json (self
    /// address + recent messages) defeats SQLCipher-at-rest if it ships, so it is written ONLY when this is
    /// a DEBUG build OR the process was launched under the harness (a HOP_AUTO env real users never set).
    /// The critical invariant, which the test pins: a RELEASE build with no HOP_AUTO returns false, so the
    /// mirror is NEVER written in a shipped app.
    static func automationMirrorEnabled(isDebug: Bool, hopAutoEnv: String?) -> Bool {
        return isDebug || (hopAutoEnv != nil)
    }
    static var automationMirrorEnabled: Bool {
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        return automationMirrorEnabled(isDebug: isDebug,
                                       hopAutoEnv: ProcessInfo.processInfo.environment["HOP_AUTO"])
    }

    /// Rewrite the automation mirror (last ~100 rx + tx). Called on every message change (from
    /// `saveMessages`) and once at startup so `self` is discoverable even before any traffic.
    static func writeAutomationDump(messages: [HopBearer.Message], myAddress: String,
                                    myName: String, autoEnvSeen: String) {
        guard automationMirrorEnabled else { return }   // apple-04: never a plaintext mirror in shipped release
        let rx = messages.filter { $0.incoming }.suffix(100).map {
            AutomationDump.Rx(from: $0.peerAddr.map(HopBearer.base58) ?? $0.peer,
                              text: $0.text, at: Int64($0.sentAt.timeIntervalSince1970 * 1000))
        }
        let tx = messages.filter { !$0.incoming }.suffix(100).map {
            AutomationDump.Tx(to: $0.peerAddr.map(HopBearer.base58) ?? $0.peer,
                              text: $0.text, delivered: $0.delivered, deliveryMs: $0.deliveryMs,
                              at: Int64($0.sentAt.timeIntervalSince1970 * 1000))
        }
        let dump = AutomationDump(self: myAddress, name: myName, rx: Array(rx), tx: Array(tx),
                                  auto: autoEnvSeen)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(dump) else { return }
        // completeFileProtection even for the debug/harness mirror (defense in depth; harness reads it
        // over devicectl while the device is unlocked).
        try? data.write(to: automationFileURL, options: [.atomic, .completeFileProtection])
    }
}
