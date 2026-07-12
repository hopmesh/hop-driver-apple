import Foundation
import HopFFIBindings

// HNS + hops:// (DESIGN.md §30): the node-driving + result-draining half of Hop's name system and origin
// fetch: resolve a domain, open a hops:// fetch (text-box + WebView callback shapes), the pure URL splitter,
// and the drains for finished HNS resolutions / HTTP responses / host DNS lookups. Grouped out of the
// HopBearer class body into this sibling extension so the concern is one cohesive file; behavior is
// unchanged (methods moved verbatim). The genuinely network-bound senders (fireHops / fireHopsWeb /
// fetchDnssecChain) stay in HopBearer+Radios.swift, excluded from the coverage denominator.
extension HopBearer {

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
            // cov/apple-hns: `resolveHnsForTest`, when set by a test, substitutes the outcome below
            // instead of asking the real node (see its declaration in HopBearer.swift for why).
            let res = self.resolveHnsForTest?(domain) ?? self.node.resolveHns(domain: domain)
            DispatchQueue.main.async {
                switch res {
                case .cached(let address):
                    if address.isEmpty {
                        // A cached negative - the domain has no `_hopaddress` record.
                        self.hopsResults[domain] = "error: no hops endpoint for \(domain)"
                    } else {
                        self.fireHops(domain: domain, path: path, endpoint: address)
                    }
                case .pending:
                    // A lookup was kicked off - our own DNS (if we have internet) or a query
                    // broadcast to connected peers. Fire when its record lands in takeHnsResults().
                    self.pendingHops[domain] = path
                case .needsResolver:
                    // Genuinely isolated: no internet AND no connected peers to resolve through.
                    self.hopsResults[domain] = "error: offline - no internet or peers to resolve \(domain)"
                }
                self.pump()
            }
        }
    }

    // MARK: - hops:// for the WebView (callback-style, per-resource)
    // The `HopResponse` value type lives in HopModels.swift (still `HopBearer.HopResponse`).

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
            // cov/apple-hns: same test seam as openHops above.
            let res = self.resolveHnsForTest?(domain) ?? self.node.resolveHns(domain: domain)
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
                                           body: Data("offline - no internet or peers to resolve \(domain)".utf8)))
                }
                self.pump()
            }
        }
    }

    /// Split `hops://<domain>/<path>` (or a bare `<domain>`) into (domain, path). The path
    /// defaults to "/" and is path+query only - what `sendHopsRequest` expects.
    // Internal (not private) so the pure hops:// URL split (strip scheme, split domain/path, default the
    // path to "/") is unit-testable without a node or a live fetch.
    static func parseHops(_ raw: String) -> (domain: String, path: String) {
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
    func applyHnsResults(_ results: [HnsRecord]) {
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

    func applyHttpResponses(_ responses: [HttpResp]) {
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
    /// chain over DoH and hand core the raw response bodies - core validates the chain to the root
    /// anchors and decides the address; the app never does.
    func applyDnsLookups(_ domains: [String]) {
        for domain in domains { fetchDnssecChain(domain) }
    }
}
