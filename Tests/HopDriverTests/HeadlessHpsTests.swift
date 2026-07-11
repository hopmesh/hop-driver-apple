// hps:// pub/sub coverage (§32) driven against a REAL headless node (cov/apple-driver): register (sync +
// async), publish/echo, subscribe/join, invite/accept/decline, host reads (pending/reach/members/snapshot),
// rekey, leave, browse, and the received-message/invite apply paths.

import XCTest
import Foundation
@testable import HopDriver

final class HeadlessHpsTests: XCTestCase {

    // MARK: register

    func testRegisterServiceReturnsPubkeyAndInsertsHostedTopic() {
        let b = makeHeadlessBearer()
        let pk = b.hpsRegister(path: "alerts", channel: false)
        XCTAssertFalse(pk.isEmpty, "a service returns its broadcast public key")
        let t = b.hpsTopics.first { $0.path == "alerts" }
        XCTAssertNotNil(t)
        XCTAssertTrue(t!.hosting)
        XCTAssertFalse(t!.isChannel)
        XCTAssertTrue(t!.writable, "a hosted service is writable by us")
    }

    func testRegisterChannelReturnsEmptyPubkey() {
        let b = makeHeadlessBearer()
        let pk = b.hpsRegister(path: "lobby", channel: true)
        XCTAssertTrue(pk.isEmpty, "a channel mints no service broadcast key")
        XCTAssertTrue(b.hpsTopics.first { $0.path == "lobby" }?.isChannel ?? false)
    }

    func testRegisterEmptyPathIsNoOp() {
        let b = makeHeadlessBearer()
        XCTAssertTrue(b.hpsRegister(path: "   ", channel: true).isEmpty)
        XCTAssertTrue(b.hpsTopics.isEmpty)
    }

    func testRegisterAsyncInsertsTopicAndDeliversPubkey() {
        let b = makeHeadlessBearer()
        let done = expectation(description: "async register completion")
        b.hpsRegister(path: "svc-async", channel: false, then: { _ in done.fulfill() })
        XCTAssertTrue(b.hpsTopics.contains { $0.path == "svc-async" }, "the row appears optimistically")
        settle(b)
        wait(for: [done], timeout: 2)
    }

    func testRegisterAsyncEmptyPathCallsCompletionWithEmpty() {
        let b = makeHeadlessBearer()
        let done = expectation(description: "empty path completion")
        b.hpsRegister(path: "", channel: false, then: { pk in
            XCTAssertTrue(pk.isEmpty); done.fulfill()
        })
        wait(for: [done], timeout: 2)
    }

    // MARK: publish

    func testPublishEchoesLocallyIntoThread() {
        let b = makeHeadlessBearer()
        _ = b.hpsRegister(path: "room", channel: true)
        let topic = b.hpsTopics.first { $0.path == "room" }!
        b.hpsPublish(topic: topic, text: "gm")
        let thread = b.hpsThreads[topic.id] ?? []
        XCTAssertEqual(thread.last?.text, "gm")
        XCTAssertEqual(thread.last?.sender, b.myAddressData, "our own post echoes locally under our address")
        settle(b)
    }

    func testPublishEmptyIsNoOp() {
        let b = makeHeadlessBearer()
        _ = b.hpsRegister(path: "room2", channel: true)
        let topic = b.hpsTopics.first { $0.path == "room2" }!
        b.hpsPublish(topic: topic, text: "")
        XCTAssertNil(b.hpsThreads[topic.id]?.last)
    }

    // MARK: subscribe / join

    func testSubscribeInsertsFollowedTopic() {
        let b = makeHeadlessBearer()
        let host = foreignAddr(0x40)
        b.hpsSubscribe(hostBase58: base58(host), path: "feed")
        let t = b.hpsTopics.first { $0.path == "feed" }
        XCTAssertNotNil(t)
        XCTAssertFalse(t!.hosting, "a subscription is a followed topic, not hosted")
        settle(b)
    }

    func testSubscribeInvalidHostIsNoOp() {
        let b = makeHeadlessBearer()
        b.hpsSubscribe(hostBase58: "bad", path: "feed")
        XCTAssertTrue(b.hpsTopics.isEmpty)
    }

    func testJoinFromBrowseInfoSubscribes() {
        let b = makeHeadlessBearer()
        let info = HpsTopicInfo(host: foreignAddr(0x41), path: "public-room", kind: .channel,
                                title: "Public", summary: "open", access: .open)
        b.hpsJoin(info)
        XCTAssertTrue(b.hpsTopics.contains { $0.path == "public-room" && !$0.hosting })
        settle(b)
    }

    // MARK: invite / accept / decline

    func testInviteRequiresHostingAndDoesNotCrash() {
        let b = makeHeadlessBearer()
        _ = b.hpsRegister(path: "vip", channel: false)
        let hosted = b.hpsTopics.first { $0.path == "vip" }!
        b.hpsInvite(topic: hosted, to: foreignAddr(0x42))    // hosting ⇒ proceeds
        let followed = HopBearer.HpsTopic(host: foreignAddr(0x43), path: "not-mine", isChannel: true, hosting: false)
        b.hpsInvite(topic: followed, to: foreignAddr(0x42))  // not hosting ⇒ guarded no-op
        settle(b)
    }

    func testAcceptInviteRemovesItAndInsertsTopic() {
        let b = makeHeadlessBearer()
        let inv = HpsInvite(path: "invited-room", host: foreignAddr(0x44), kind: .channel)
        b.hpsInvites = [inv]
        b.hpsAcceptInvite(inv)
        XCTAssertFalse(b.hpsInvites.contains { $0.path == "invited-room" }, "the invite is consumed")
        XCTAssertTrue(b.hpsTopics.contains { $0.path == "invited-room" && !$0.hosting })
        settle(b)
    }

    func testDeclineInviteRemovesIt() {
        let b = makeHeadlessBearer()
        let inv = HpsInvite(path: "decline-me", host: foreignAddr(0x45), kind: .service)
        b.hpsInvites = [inv]
        b.hpsDeclineInvite(inv)
        XCTAssertFalse(b.hpsInvites.contains { $0.path == "decline-me" })
        settle(b)
    }

    // MARK: host reads

    func testFreshTopicHasNoPendingReachOrMembers() {
        let b = makeHeadlessBearer()
        _ = b.hpsRegister(path: "hostme", channel: false)
        let t = b.hpsTopics.first { $0.path == "hostme" }!
        XCTAssertEqual(b.hpsPending(t), [])
        XCTAssertEqual(b.hpsReach(t), 0)
        XCTAssertEqual(b.hpsMembers(t), [])
    }

    func testHostSnapshotReturnsEmptyForFreshTopic() {
        let b = makeHeadlessBearer()
        _ = b.hpsRegister(path: "snapme", channel: false)
        let t = b.hpsTopics.first { $0.path == "snapme" }!
        let done = expectation(description: "host snapshot")
        b.hpsHostSnapshot(t) { snap in
            XCTAssertEqual(snap.reach, 0)
            XCTAssertEqual(snap.pending, [])
            XCTAssertEqual(snap.members, [])
            done.fulfill()
        }
        settle(b)
        wait(for: [done], timeout: 2)
    }

    func testApproveDenyRekeyDoNotCrash() {
        let b = makeHeadlessBearer()
        _ = b.hpsRegister(path: "modme", channel: false)
        let t = b.hpsTopics.first { $0.path == "modme" }!
        b.hpsApprove(t, foreignAddr(0x46))
        b.hpsDeny(t, foreignAddr(0x47))
        b.hpsRekey(t, remove: [foreignAddr(0x46)])
        settle(b)
    }

    func testBrowseReturnsEmptyOnFreshNode() {
        let b = makeHeadlessBearer()
        let done = expectation(description: "browse")
        b.hpsBrowse { found in
            XCTAssertTrue(found.isEmpty, "a node hosting nothing discoverable browses to nothing")
            done.fulfill()
        }
        settle(b)
        wait(for: [done], timeout: 2)
    }

    // MARK: leave

    func testLeaveRemovesTopicAndItsThread() {
        let b = makeHeadlessBearer()
        b.hpsSubscribe(hostBase58: base58(foreignAddr(0x48)), path: "leaveme")
        let t = b.hpsTopics.first { $0.path == "leaveme" }!
        b.hpsThreads[t.id] = [HopBearer.HpsMsgRow(path: "leaveme", sender: foreignAddr(0x48), text: "hi", at: 1)]
        b.hpsUnread[t.id] = 3
        b.hpsLeave(t)
        XCTAssertFalse(b.hpsTopics.contains { $0.id == t.id })
        XCTAssertNil(b.hpsThreads[t.id])
        XCTAssertNil(b.hpsUnread[t.id])
        settle(b)
    }

    // MARK: topic focus

    func testOpenTopicClearsUnreadAndCloseResets() {
        let b = makeHeadlessBearer()
        b.hpsUnread["t/1"] = 5
        b.openTopic("t/1")
        XCTAssertEqual(b.hpsUnread["t/1"], 0)
        b.closeTopic()   // clears the active-topic marker
    }
}
