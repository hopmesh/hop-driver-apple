// HopBearer - the device/radio/network I/O surface, split out of HopBearer.swift (cov/apple-driver).
//
// EVERYTHING here drives a real radio or a live network socket and therefore cannot run under a headless
// macOS `swift test` (no BLE/Wi-Fi peer, no reachable hops:// endpoint, no DoH round-trip, no UIKit app
// state): the Wi-Fi (MultipeerConnectivity) bearer + its session/advertiser/browser delegates, the shared-
// BearerManager link callbacks, the direct hops:// endpoint WebSocket dialer + its URLSession delegate, the
// hops:// request senders, the DNSSEC-over-DoH fetch, and the local user-notification post. It is exercised
// by the on-device / cross-platform workflow (testkit + the hopmac/relaymac headless clients + real
// devices), NOT by unit tests. It is deliberately isolated in its own file so the coverage gate can exclude
// it from HopBearer's denominator via `-ignore-filename-regex` (the pure node-driving + snapshot-mapping +
// persistence logic in HopBearer.swift is what the unit suite covers to the floor). Behavior is unchanged:
// these are the same methods/extensions, moved verbatim; the stored properties they touch stay on the class
// and were widened from `private` to `internal` so this sibling file can reach them.

import Foundation
import MultipeerConnectivity
import Network
import UserNotifications
import HopContract
import HopFFIBindings
#if canImport(UIKit)
import UIKit
#endif

extension HopBearer {

    // MARK: - Wi-Fi (MultipeerConnectivity) bearer

    /// Stand up the Wi-Fi bearer: advertise + browse for nearby Hop peers and shuttle
    /// the node's frames over a `MCSession`, exactly like the BLE bearer but a
    /// different medium (DESIGN.md §26). Encryption is left to Hop's Noise layer.
    func startWiFi() {
        let pid = MCPeerID(displayName: mcTransportId)   // apple-03: random transport id, NOT the address
        mcPeerID = pid
        let session = MCSession(peer: pid, securityIdentity: nil, encryptionPreference: .none)
        session.delegate = self
        mcSession = session
        let adv = MCNearbyServiceAdvertiser(peer: pid, discoveryInfo: nil, serviceType: HopBearer.mcServiceType)
        adv.delegate = self
        // apple-03: private mode means "do not broadcast presence". Browse (so we can still reach peers who
        // advertise) but do NOT advertise ourselves, matching retractPresence's contract for the relay path.
        if !privateMode { adv.startAdvertisingPeer() }
        mcAdvertiser = adv
        let br = MCNearbyServiceBrowser(peer: pid, serviceType: HopBearer.mcServiceType)
        br.delegate = self
        br.startBrowsingForPeers()
        mcBrowser = br
        NSLog("HOPLOG wifi start: \(pid.displayName) private=\(privateMode)")
    }

    /// Re-attempt advertise/browse and clear any blocked state. Called on foreground -
    /// MultipeerConnectivity errors out while the Local Network prompt is still
    /// pending, so this recovers once the user grants permission (no relaunch needed).
    func restartWiFi() {
        wifiBlocked = false
        mcAdvertiser?.stopAdvertisingPeer()
        mcBrowser?.stopBrowsingForPeers()
        if !privateMode { mcAdvertiser?.startAdvertisingPeer() }   // apple-03: honor private mode
        mcBrowser?.startBrowsingForPeers()
        NSLog("HOPLOG wifi restart private=\(privateMode)")
    }

    // MARK: - Shared BearerManager link callbacks (fire only on a real radio link)

    /// Shared-bearer link up: record the id (so `applyOutgoing` routes it), then drive the node's Noise
    /// handshake through the existing seam (dialer → initiator). Called on the bearer's work queue.
    func bearerLinkUp(_ id: UInt64, role: HopRole) {
        bearerLinksLock.lock(); bearerLinks.insert(id); bearerLinksLock.unlock()
        // apple-06: drive the UI relayStatus from the shared RelayBearer, not the legacy path.
        if bearerMgr.transportName(of: id) == "Relay" {
            bearerLinksLock.lock(); relayBearerLinkId = id; bearerLinksLock.unlock()
            onMain { [weak self] in self?.relayStatus = "connected" }
        }
        linkUp(id, initiator: role == .dialer)
    }

    /// Shared-bearer inbound DATA frame → the node, via the existing seam.
    func bearerDeliver(_ id: UInt64, bytes: Data) {
        deliver(link: id, bytes: bytes)
    }

    /// Shared-bearer link down: forget the id, then tell the node through the existing seam.
    func bearerLinkDown(_ id: UInt64) {
        bearerLinksLock.lock()
        bearerLinks.remove(id)
        let wasRelay = (relayBearerLinkId == id)
        if wasRelay { relayBearerLinkId = nil }
        bearerLinksLock.unlock()
        // apple-06: the shared RelayBearer reconnects with backoff, so its socket dropping means the UI
        // relay indicator should reflect "reconnecting" until the next linkUp, not stay green.
        if wasRelay { onMain { [weak self] in self?.relayStatus = "reconnecting…" } }
        linkDown(id)
    }

    // MARK: - Direct hops:// endpoint links (WebSocket, §30)

    /// Open (or reuse) a direct WS link to a hops:// endpoint at `wss://<domain>/` (DESIGN.md
    /// §30). The endpoint authenticates via Noise as its HNS-published address, becoming a
    /// direct peer; the sealed hops request then delivers straight to it. Returns the link id.
    @discardableResult
    func dialEndpoint(_ domain: String) -> UInt64 {
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

    func receiveEndpoint(_ id: UInt64) {
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
    func endpointLink(for task: URLSessionTask) -> UInt64? {
        endpointWS.first(where: { $0.value === task })?.key
    }

    // MARK: - hops:// request senders (sealed GET over the mesh / a dialed endpoint)

    /// Issue the sealed hops:// GET to a resolved endpoint and remember the request id so
    /// the response can be matched back (DESIGN.md §30). Runs on main; the node send is on core.
    func fireHops(domain: String, path: String, endpoint: Data) {
        // We learned domain↔address from HNS, so label the endpoint by its domain right away
        // (no need to wait for a hop.identify round-trip) - shows in the endpoints list + traces.
        nameByAddr[endpoint] = domain
        // Open a direct link to the endpoint (wss://<domain>) so the sealed request has a path
        // to it - the endpoint doesn't transit our relay (§30). Spray-and-wait holds the
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

    func fireHopsWeb(domain: String, path: String, endpoint: Data,
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

    // MARK: - DNSSEC-over-DoH host resolver hook (§30)

    /// Fetch a domain's full DNSSEC chain over DNS-over-HTTPS and feed the raw JSON bodies to
    /// core via `provideDnsProof`: the `_hopaddress.<domain>` TXT plus DNSKEY + DS for every
    /// zone up to the root, all with `do=1`. Runs the GETs concurrently, then marshals back to
    /// the main queue (where the node is driven) once they're all in.
    func fetchDnssecChain(_ domain: String) {
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

    // MARK: - Local user notification (UIKit app state)

    func notifyIfBackgrounded(from: String, text: String) {
        guard isFull else { return }   // central-only nodes (hopmac) post no user notifications
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState != .active else { return }
        #endif
        let content = UNMutableNotificationContent()
        content.title = from; content.body = text; content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
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

// MARK: - Direct hops:// endpoint links (WebSocket, §30)

// apple-r2-01: the cloud relay is the shared RelayBearer only; this delegate now serves ONLY the
// direct hops:// endpoint WS links (dialEndpoint). Any task that is not a known endpoint is ignored.
extension HopBearer: URLSessionWebSocketDelegate {
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        // URLSession delegate queue is `.main` (set when dialing), so this runs on main already.
        guard let id = endpointLink(for: webSocketTask) else { return }   // a hops:// endpoint link (§30)
        linkUp(id, initiator: true)    // dialer = Noise initiator
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard let id = endpointLink(for: webSocketTask) else { return }
        endpointWS[id] = nil; linkDown(id)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = endpointLink(for: task) else { return }
        endpointWS[id] = nil; linkDown(id)
    }
}

// MARK: - Shared HopBearers sink adapter

/// Adapts the shared `BearerManager` to HopBearer's existing node seam. Every link from every
/// registered bearer (BLE + LAN) surfaces here in ONE global link-id space and is driven straight into
/// the same `linkUp` / `deliver` / `linkDown` the legacy transports use - so the node sees no difference
/// in which radio a link rode in on. Holds the owner `unowned`: HopBearer owns this sink (a stored
/// property), so it never outlives its owner.
final class BearerSink: LinkSink {
    unowned let owner: HopBearer
    init(_ owner: HopBearer) { self.owner = owner }
    func linkUp(_ link: LinkId, role: HopRole, peerId: Data) { owner.bearerLinkUp(link, role: role) }
    func linkBytes(_ link: LinkId, _ bytes: Data) { owner.bearerDeliver(link, bytes: bytes) }
    func linkDown(_ link: LinkId) { owner.bearerLinkDown(link) }
}
