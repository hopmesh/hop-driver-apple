import Foundation
import HopFFIBindings

// HNS + hops:// (DESIGN.md §30): the node-driving + result-draining half of Hop's name system and origin
// fetch: resolve a domain, open a hops:// fetch (text-box + WebView callback shapes), the pure URL splitter,
// and the drains for finished HNS resolutions / HTTP responses / host DNS lookups. Grouped out of the
// HopBearer class body into this sibling extension so the concern is one cohesive file; behavior is
// unchanged (methods moved verbatim). The genuinely network-bound senders (fireHops / fireHopsWeb /
// fetchReachRecord) stay in HopBearer+Radios.swift, excluded from the coverage denominator.
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
                        // A cached negative - the domain has no reachable hops endpoint.
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
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.contains("\\") else { return ("", "/") }
        let absolute = input.contains("://") ? input : "hops://\(input)"
        guard let components = URLComponents(string: absolute),
              components.scheme?.lowercased() == "hops",
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil,
              let rawHost = components.host,
              let domain = canonicalHnsDomain(rawHost) else { return ("", "/") }
        var path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery, !query.isEmpty { path += "?\(query)" }
        return (domain, path)
    }

    /// Drain finished HNS resolutions (firing any queued hops:// fetch) and hops:// HTTP
    /// responses (matching them back to the in-flight request). The core caches records,
    /// so we keep no extra cache here. Separately, any domains the node wants resolved are
    /// fetched from their `/.well-known/hop` off the main queue and fed back via
    /// `provideReachRecord` (see `applyDnsLookups`, DESIGN.md §30).
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
        var accepted: [Data] = []
        for resp in responses {
            // WebView completion (per-resource) takes priority over the text box.
            if let completion = hopsWebReqs.removeValue(forKey: resp.forRequestId) {
                completion(HopResponse(status: Int(resp.status),
                                       contentType: resp.contentType, body: resp.body))
                accepted.append(resp.id)
                continue
            }
            if let domain = hopsReqs.removeValue(forKey: resp.forRequestId) {
                let text = String(data: resp.body, encoding: .utf8) ?? "<\(resp.body.count) bytes>"
                hopsResults[domain] = "\(resp.status) · \(text)"
            }
            accepted.append(resp.id)
        }
        if !accepted.isEmpty {
            core.async { [weak self] in
                guard let self else { return }
                for id in accepted {
                    if let accept = self.acceptHttpResponseForTest { _ = accept(id) }
                    else { _ = try? self.node.acceptHttpResponse(id: id) }
                }
            }
        }
    }

    /// Host resolver hook (DESIGN.md §30): for each domain the node wants resolved, fetch its
    /// `/.well-known/hop` reach record over HTTPS and hand core the raw record bytes - core verifies the
    /// self-certifying signature and decides the address (the domain's TLS cert proved the domain).
    func applyDnsLookups(_ domains: [String]) {
        for domain in domains { fetchReachRecord(domain) }
    }

    /// Pull the `reach` field out of a `/.well-known/hop` JSON body (`{address, endpoint, reach}`, where
    /// `reach` is the base64-std reach record) and decode it to the raw record bytes. Returns empty on a
    /// missing field / malformed JSON / bad base64. Pure (no network), so it's unit-testable apart from
    /// the URLSession GET in `fetchReachRecord` (which is excluded from the coverage denominator).
    static func reachRecord(fromWellKnown body: Data?) -> Data {
        guard let body, body.count <= hnsMaxBodyBytes,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let reach = obj["reach"] as? String,
              let bytes = Data(base64Encoded: reach), bytes.count <= hnsMaxRecordBytes else { return Data() }
        return bytes
    }

    static func canonicalReachRecordURL(domain: String) -> URL? {
        guard let host = canonicalHnsDomain(domain) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.percentEncodedPath = "/.well-known/hop"
        guard components.user == nil, components.password == nil, components.port == nil,
              let url = components.url else { return nil }
        return url
    }

    static func validatedReachRecord(data: Data?, response: URLResponse?, expectedURL: URL) -> Data {
        guard let http = response as? HTTPURLResponse,
              http.url == expectedURL,
              http.statusCode == 200,
              http.mimeType?.lowercased() == "application/json",
              http.allHeaderFields.reduce(0, { total, item in
                  total + String(describing: item.key).utf8.count + String(describing: item.value).utf8.count + 4
              }) <= hnsMaxHeaderBytes,
              let data, data.count <= hnsMaxBodyBytes else { return Data() }
        return reachRecord(fromWellKnown: data)
    }

    private static func canonicalHnsDomain(_ raw: String) -> String? {
        let host = raw.lowercased()
        guard (1...253).contains(host.count), !host.hasSuffix("."), host.unicodeScalars.allSatisfy({
            (0x21...0x7e).contains(Int($0.value))
        }) else { return nil }
        guard host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
            (1...63).contains(label.count) && label.first != "-" && label.last != "-" &&
                label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }) else { return nil }
        return host
    }

    static let hnsMaxHeaderBytes = 32 * 1024
    static let hnsMaxBodyBytes = 64 * 1024
    static let hnsMaxRecordBytes = 32 * 1024
}
