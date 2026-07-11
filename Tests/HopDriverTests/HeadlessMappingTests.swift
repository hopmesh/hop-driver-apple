// Snapshot-mapping coverage (cov/apple-driver). The node drains its outputs into plain FFI records, and the
// driver maps them onto @Published UI state on main. These helpers are the single biggest chunk of
// HopBearer.swift (applyRefresh alone is ~165 lines), so we build the FFI records directly and call the
// (internal) mapping methods synchronously on the test's main thread - exactly where they run in the app.

import XCTest
import Foundation
@testable import HopDriver

final class HeadlessMappingTests: XCTestCase {

    private func addr(_ b: UInt8) -> Data { Data(repeating: b, count: 32) }

    // MARK: applyInbox

    func testApplyInboxSurfacesIncomingTextAndCreatesContact() {
        let b = makeHeadlessBearer()
        let from = addr(0xA1)
        let msg = InboxMessage(from: from, contentType: "text/plain", body: Data("hi".utf8),
                               hops: 3, createdAt: HopBearer.nowMs() - 500, trace: [])
        b.applyInbox([msg])
        XCTAssertEqual(b.messages.last?.text, "hi")
        XCTAssertTrue(b.messages.last?.incoming ?? false)
        XCTAssertEqual(b.messages.last?.hops, 3)
        XCTAssertNotNil(b.messages.last?.latencyMs)
        XCTAssertTrue(b.contactList.contains { $0.address == from }, "an unknown sender becomes a contact so the chat exists")
        XCTAssertEqual(b.totalUnread, 1, "a message from a peer not on screen bumps unread")
    }

    func testApplyInboxImageMessage() {
        let b = makeHeadlessBearer()
        let img = Data([0xff, 0xd8, 0x00, 0x11])
        let msg = InboxMessage(from: addr(0xA2), contentType: "image/png", body: img,
                               hops: 1, createdAt: HopBearer.nowMs(), trace: [])
        b.applyInbox([msg])
        XCTAssertEqual(b.messages.last?.imageData, img)
        XCTAssertEqual(b.messages.last?.text, "", "an image carries no body text")
    }

    func testApplyInboxMultipartSplitsTextAndImages() {
        let b = makeHeadlessBearer()
        let img = Data([0x01, 0x02, 0x03])
        let body = HopBearer.encodeMultipart([("text/plain", Data("cap".utf8)), ("image/jpeg", img)])
        let msg = InboxMessage(from: addr(0xA3), contentType: "multipart/mixed", body: body,
                               hops: 2, createdAt: HopBearer.nowMs(), trace: [])
        b.applyInbox([msg])
        XCTAssertEqual(b.messages.last?.text, "cap")
        XCTAssertEqual(b.messages.last?.images, [img])
    }

    func testApplyInboxDoesNotCountTheChatOnScreen() {
        let b = makeHeadlessBearer()
        let from = addr(0xA4)
        let who = HopBearer.shortHex(from)   // unknown sender ⇒ display name is the short id
        b.openChat(who)                      // that chat is on screen
        b.applyInbox([InboxMessage(from: from, contentType: "text/plain", body: Data("seen".utf8),
                                   hops: 0, createdAt: HopBearer.nowMs(), trace: [])])
        XCTAssertEqual(b.totalUnread, 0, "a message for the open chat is not badged")
    }

    // MARK: applyOutgoing

    func testApplyOutgoingWithNoMatchingLinkIsInert() {
        let b = makeHeadlessBearer()
        // No shared-bearer link, no Multipeer peer, no endpoint WS for id 999 ⇒ the packet is dropped
        // without touching any radio. Exercises the routing else-chain safely.
        b.applyOutgoing([OutPacket(link: 999, bytes: Data([0x00, 0x01]))])
    }

    // MARK: applyServiceRequests / applyServiceResponses

    func testApplyServiceRequestsLogsAnd501s() {
        let b = makeHeadlessBearer()
        let req = ServiceReq(from: addr(0xB1), requestId: addr(0xB2), service: "echo", method: "ping", args: Data())
        b.applyServiceRequests([req])
        XCTAssertTrue(b.serviceLog.first?.contains("echo/ping") ?? false)
        XCTAssertTrue(b.serviceLog.first?.contains("501") ?? false, "no custom services ⇒ a definite 501 reply")
        settle(b)
    }

    func testApplyServiceResponsesLogsANonIdentityReply() {
        let b = makeHeadlessBearer()
        // A response whose request id is not an outstanding identify ⇒ the generic service-log branch.
        let resp = ServiceResp(from: addr(0xB3), forRequestId: addr(0xB4), status: 200, body: Data("pong".utf8))
        b.applyServiceResponses([resp])
        XCTAssertTrue(b.serviceLog.first?.contains("pong") ?? false)
    }

    func testApplyServiceResponsesConsumesAnIdentifyRequestIdOnNonZeroStatus() {
        let b = makeHeadlessBearer()
        let reqId = addr(0xB5)
        b.identifyReqs.insert(reqId)   // pretend we sent an identify with this id
        // status != 0 ⇒ not a successful identify body, so it removes the outstanding id and logs generic.
        b.applyServiceResponses([ServiceResp(from: addr(0xB6), forRequestId: reqId, status: 5, body: Data())])
        XCTAssertFalse(b.identifyReqs.contains(reqId), "the outstanding identify id is consumed")
    }

    // MARK: applyHnsResults / applyHttpResponses / applyDnsLookups

    func testApplyHnsResultsNegativeRecordErrorsThePendingTextFetch() {
        let b = makeHeadlessBearer()
        b.pendingHops["acme.hop"] = "/"
        b.applyHnsResults([HnsRecord(domain: "acme.hop", address: Data())])   // empty address = cached negative
        XCTAssertEqual(b.hopsResults["acme.hop"], "error: no hops endpoint for acme.hop")
    }

    func testApplyHnsResultsNegativeRecordFailsQueuedWebFetch() {
        let b = makeHeadlessBearer()
        let done = expectation(description: "web fetch 502")
        b.hopsWebPending["shop.hop"] = [("/x", { resp in
            XCTAssertEqual(resp.status, 502); done.fulfill()
        })]
        b.applyHnsResults([HnsRecord(domain: "shop.hop", address: Data())])
        wait(for: [done], timeout: 2)
    }

    func testApplyHttpResponsesCompletesAWebRequestThenTheTextBox() {
        let b = makeHeadlessBearer()
        // WebView completion path (takes priority).
        let webId = addr(0xC1)
        let webDone = expectation(description: "web http")
        b.hopsWebReqs[webId] = { resp in
            XCTAssertEqual(resp.status, 201); XCTAssertEqual(resp.body, Data("page".utf8)); webDone.fulfill()
        }
        b.applyHttpResponses([HttpResp(from: addr(0xC2), forRequestId: webId, status: 201,
                                       contentType: "text/html", body: Data("page".utf8))])
        wait(for: [webDone], timeout: 2)
        // Text-box path (rendered into hopsResults).
        let textId = addr(0xC3)
        b.hopsReqs[textId] = "news.hop"
        b.applyHttpResponses([HttpResp(from: addr(0xC4), forRequestId: textId, status: 200,
                                       contentType: "text/plain", body: Data("headline".utf8))])
        XCTAssertEqual(b.hopsResults["news.hop"], "200 · headline")
    }

    func testApplyDnsLookupsEmptyIsInert() {
        let b = makeHeadlessBearer()
        b.applyDnsLookups([])   // no domains ⇒ no DoH network I/O
    }

    // MARK: applyHpsMessages / applyHpsInvites

    func testApplyHpsMessagesAppendsToMatchingThreadAndBadges() {
        let b = makeHeadlessBearer()
        b.hpsSubscribe(hostBase58: base58(addr(0xD1)), path: "topic-x")
        let topic = b.hpsTopics.first { $0.path == "topic-x" }!
        b.applyHpsMessages([HpsMessage(path: "topic-x", sender: addr(0xD2), body: Data("posted".utf8))])
        XCTAssertEqual(b.hpsThreads[topic.id]?.last?.text, "posted")
        XCTAssertEqual(b.hpsUnread[topic.id], 1, "a message for a topic not on screen is badged")
        settle(b)
    }

    func testApplyHpsMessagesForOpenTopicIsNotBadged() {
        let b = makeHeadlessBearer()
        b.hpsSubscribe(hostBase58: base58(addr(0xD3)), path: "topic-y")
        let topic = b.hpsTopics.first { $0.path == "topic-y" }!
        b.openTopic(topic.id)
        b.applyHpsMessages([HpsMessage(path: "topic-y", sender: addr(0xD4), body: Data("live".utf8))])
        XCTAssertEqual(b.hpsUnread[topic.id] ?? 0, 0)
        settle(b)
    }

    func testApplyHpsInvitesDeduplicates() {
        let b = makeHeadlessBearer()
        let inv = HpsInvite(path: "party", host: addr(0xD5), kind: .channel)
        b.applyHpsInvites([inv])
        b.applyHpsInvites([inv])   // same host+path ⇒ not re-added
        XCTAssertEqual(b.hpsInvites.filter { $0.path == "party" }.count, 1)
        settle(b)
    }

    // MARK: applyRefresh - the big one

    private func snapshot(browse: [ServiceHit] = [], peerLinks: [PeerLink] = [],
                          secured: Set<Data> = [], routed: Set<Data> = [],
                          queue: [QueueItem] = [], hnsCache: [HnsCacheEntry] = [],
                          statuses: [Data: MessageStatus] = [:]) -> HopBearer.RefreshSnapshot {
        HopBearer.RefreshSnapshot(browse: browse, peerLinks: peerLinks, secured: secured,
                                  routed: routed, queue: queue, hnsCache: hnsCache, statuses: statuses)
    }

    func testApplyRefreshMapsPresenceBrowseToReachable() {
        let b = makeHeadlessBearer()
        let a = addr(0xE1)
        let hit = ServiceHit(publisher: a, service: "presence", title: "Alice",
                             summary: "fg|ios|HopDemo", tags: [], hops: 2, createdAt: HopBearer.nowMs())
        b.applyRefresh(snapshot(browse: [hit]))
        XCTAssertEqual(b.reachable.first?.name, "Alice")
        XCTAssertEqual(b.reachable.first?.platform, "ios")
        XCTAssertEqual(b.reachable.first?.app, "HopDemo")
        XCTAssertTrue(b.reachable.first?.active ?? false)
    }

    func testApplyRefreshCollapsesMultipleAdvertsPerPublisherToNearestHops() {
        let b = makeHeadlessBearer()
        let a = addr(0xE2)
        let now = HopBearer.nowMs()
        let older = ServiceHit(publisher: a, service: "presence", title: "Old", summary: "bg|ios|App",
                               tags: [], hops: 4, createdAt: now - 10_000)
        let newer = ServiceHit(publisher: a, service: "presence", title: "New", summary: "fg|android|App",
                               tags: [], hops: 2, createdAt: now)
        b.applyRefresh(snapshot(browse: [older, newer]))
        XCTAssertEqual(b.reachable.count, 1, "many adverts per publisher collapse to one row")
        XCTAssertEqual(b.reachable.first?.name, "New", "newest advert wins for the display name/state")
        XCTAssertEqual(b.reachable.first?.hops, 2, "nearest hop count is kept")
    }

    func testApplyRefreshTagsPeerLinksByTransportRangeAndListsRelaysAndEndpoints() {
        let b = makeHeadlessBearer()
        let bt = addr(0x10), p2p = addr(0x11), relay = addr(0x12), endpoint = addr(0x13), lan = addr(0x14)
        let links = [
            PeerLink(address: bt, link: 5_000),        // < 10k ⇒ BT
            PeerLink(address: p2p, link: 15_000),      // < 20k ⇒ P2P
            PeerLink(address: relay, link: 25_000),    // 20k..<30k ⇒ Relay backbone
            PeerLink(address: endpoint, link: 35_000), // 30k..<40k ⇒ hops:// endpoint
            PeerLink(address: lan, link: 45_000),      // 40k+ ⇒ LAN
        ]
        b.applyRefresh(snapshot(peerLinks: links))
        XCTAssertEqual(b.linkTransports[bt], ["BT"])
        XCTAssertEqual(b.linkTransports[p2p], ["P2P"])
        XCTAssertEqual(b.linkTransports[lan], ["LAN"])
        XCTAssertTrue(b.relays.contains { $0.address == relay }, "a 20k-range link is a cloud relay")
        XCTAssertTrue(b.endpoints.contains { $0.address == endpoint }, "a 30k-range link is a hops:// endpoint")
    }

    func testApplyRefreshForcesLocalLinkedPeerToOneHop() {
        let b = makeHeadlessBearer()
        let a = addr(0xE3)
        // Advert says 3 hops (arrived via relay) but a live BT link means it's actually a direct neighbour.
        let hit = ServiceHit(publisher: a, service: "presence", title: "Near", summary: "fg|ios|App",
                             tags: [], hops: 3, createdAt: HopBearer.nowMs())
        b.applyRefresh(snapshot(browse: [hit], peerLinks: [PeerLink(address: a, link: 5_000)]))
        XCTAssertEqual(b.reachable.first { $0.address == a }?.hops, 1, "a live local link is a 1-hop path")
    }

    func testApplyRefreshPublishesSecuredAndRoutedSets() {
        let b = makeHeadlessBearer()
        let s = addr(0xE4), r = addr(0xE5)
        b.applyRefresh(snapshot(secured: [s], routed: [r]))
        XCTAssertTrue(b.secured.contains(s))
        XCTAssertTrue(b.routed.contains(r))
    }

    func testApplyRefreshMapsQueueRowsIncludingBroadcast() {
        let b = makeHeadlessBearer()
        let q = [
            QueueItem(id: addr(0x20), own: true, to: addr(0x21), priority: 2, hops: 0),
            QueueItem(id: addr(0x22), own: false, to: Data(), priority: 0, hops: 3),   // empty to ⇒ broadcast
        ]
        b.applyRefresh(snapshot(queue: q))
        XCTAssertEqual(b.queue.count, 2)
        XCTAssertTrue(b.queue.contains { $0.to == "broadcast" }, "an empty destination renders as 'broadcast'")
    }

    func testApplyRefreshPublishesHnsCache() {
        let b = makeHeadlessBearer()
        b.applyRefresh(snapshot(hnsCache: [HnsCacheEntry(domain: "acme.hop", address: addr(0x30), ttlSecs: 90)]))
        XCTAssertEqual(b.hnsCache.first?.domain, "acme.hop")
        XCTAssertEqual(b.hnsCache.first?.ttl, 90)
    }

    func testApplyRefreshFlipsAnOutgoingMessageToDeliveredFromStatus() {
        let b = makeHeadlessBearer()
        let bid = addr(0x40)
        var m = HopBearer.Message(peer: "Bob", text: "sent", incoming: false, peerAddr: addr(0x41))
        m.bundleId = bid
        b.messages.append(m)
        let status = MessageStatus(relayed: 4, delivered: true, deliveryHops: 2, deliveryMs: 120)
        b.applyRefresh(snapshot(statuses: [bid: status]))
        XCTAssertTrue(b.messages[0].delivered)
        XCTAssertNotNil(b.messages[0].deliveredAt)
        XCTAssertEqual(b.messages[0].relayed, 4)
        XCTAssertEqual(b.messages[0].deliveryHops, 2)
        XCTAssertEqual(b.messages[0].deliveryMs, 120)
    }
}
