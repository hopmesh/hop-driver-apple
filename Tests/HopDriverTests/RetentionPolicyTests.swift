import XCTest
import Foundation
@testable import HopDriver

final class RetentionPolicyTests: XCTestCase {
    private func message(_ id: Int, peer: UInt8 = 1, text: String = "x", incoming: Bool = true,
                         delivered: Bool = false, failed: Bool = false, media: Int = 0) -> HopBearer.Message {
        var message = HopBearer.Message(
            peer: "peer-\(peer)", text: text, incoming: incoming,
            peerAddr: Data(repeating: peer, count: 32),
            imageData: media > 0 ? Data(repeating: 7, count: media) : nil
        )
        message.sentAt = Date(timeIntervalSince1970: TimeInterval(id))
        message.delivered = delivered
        message.failed = failed
        return message
    }

    private var limits: RetentionLimits {
        var limits = RetentionLimits()
        limits.globalMessages = 100
        limits.globalMessageBytes = 10_000
        limits.peerMessages = 100
        limits.peerMessageBytes = 10_000
        limits.conversationMessages = 2
        limits.conversationMessageBytes = 10_000
        limits.attachmentBytes = 10
        limits.peerMediaBytes = 10
        limits.globalMediaBytes = 20
        return limits
    }

    func testQuotaBoundaryAndDeterministicOldestEviction() {
        let boundary = [message(1), message(2)]
        XCTAssertEqual(RetentionPolicy.retain(boundary, limits: limits).map(\.sentAt), boundary.map(\.sentAt))
        XCTAssertEqual(RetentionPolicy.retain(boundary + [message(3)], limits: limits).map(\.sentAt),
                       [boundary[1].sentAt, Date(timeIntervalSince1970: 3)])
    }

    func testPeerAndGlobalByteQuotas() {
        var limits = self.limits
        limits.conversationMessages = 100
        limits.peerMessageBytes = 25
        limits.globalMessageBytes = 40
        let kept = RetentionPolicy.retain([
            message(1, text: "1234"), message(2, text: "12"), message(3, peer: 2, text: "1234"),
        ], limits: limits)
        XCTAssertEqual(kept.map(\.sentAt), [Date(timeIntervalSince1970: 2), Date(timeIntervalSince1970: 3)])
    }

    func testPendingOutgoingSafety() {
        var limits = self.limits
        limits.globalMessages = 1
        let pending = [message(1, incoming: false), message(2, incoming: false), message(3, incoming: false)]
        XCTAssertEqual(RetentionPolicy.retain(pending, limits: limits).count, 3)
    }

    func testUnknownAndOverQuotaMediaAreRejectedAtBoundaries() {
        let existing = [message(1, media: 6), message(2, peer: 2, media: 4)]
        XCTAssertFalse(RetentionPolicy.acceptsMedia(
            existing, peer: Data(repeating: 1, count: 32), fallbackPeer: "a",
            attachments: [Data(count: 1)], knownIdentity: false, limits: limits
        ))
        XCTAssertFalse(RetentionPolicy.acceptsMedia(
            existing, peer: Data(repeating: 1, count: 32), fallbackPeer: "a",
            attachments: [Data(count: 11)], knownIdentity: true, limits: limits
        ))
        XCTAssertTrue(RetentionPolicy.acceptsMedia(
            existing, peer: Data(repeating: 1, count: 32), fallbackPeer: "a",
            attachments: [Data(count: 4)], knownIdentity: true, limits: limits
        ))
        XCTAssertFalse(RetentionPolicy.acceptsMedia(
            existing, peer: Data(repeating: 1, count: 32), fallbackPeer: "a",
            attachments: [Data(count: 5)], knownIdentity: true, limits: limits
        ))
    }

    func testManySybilIdentitiesCannotExceedContactLimit() {
        var contacts = 0
        for _ in 0..<10_000 where RetentionPolicy.canAddContact(currentCount: contacts, alreadyKnown: false) {
            contacts += 1
        }
        XCTAssertEqual(contacts, RetentionPolicy.defaults.contacts)
        XCTAssertTrue(RetentionPolicy.canAddContact(currentCount: contacts, alreadyKnown: true))
    }

    func testPendingQuotaRejectsCapPlusOneAndReleasesCapacity() {
        var limits = RetentionLimits()
        limits.pendingGlobalMessages = 3
        limits.pendingGlobalBytes = 1_000
        limits.pendingPeerMessages = 3
        limits.pendingPeerBytes = 1_000
        limits.pendingConversationMessages = 3
        limits.pendingConversationBytes = 1_000
        let quota = PendingQuota(limits: limits)
        let ids = (0..<4).map { _ in UUID() }

        for id in ids.prefix(3) {
            XCTAssertEqual(quota.reserve(id: id, peer: "peer", conversation: "chat", bytes: 10), .accepted)
        }
        XCTAssertEqual(quota.count, 3)
        XCTAssertEqual(quota.reserve(id: ids[3], peer: "peer", conversation: "chat", bytes: 10), .globalCount)
        XCTAssertEqual(quota.reserve(id: ids[0], peer: "peer", conversation: "chat", bytes: 10), .accepted)

        quota.release(ids[0])
        XCTAssertEqual(quota.reserve(id: ids[3], peer: "peer", conversation: "chat", bytes: 10), .accepted)
        XCTAssertEqual(quota.count, 3)
    }

    func testPendingQuotaEnforcesEveryByteAndScopeLimit() {
        var limits = RetentionLimits()
        limits.pendingGlobalMessages = 10
        limits.pendingGlobalBytes = 10
        limits.pendingPeerMessages = 10
        limits.pendingPeerBytes = 10
        limits.pendingConversationMessages = 10
        limits.pendingConversationBytes = 10
        var quota = PendingQuota(limits: limits)
        XCTAssertEqual(quota.reserve(id: UUID(), peer: "a", conversation: "a", bytes: 6), .accepted)
        XCTAssertEqual(quota.reserve(id: UUID(), peer: "b", conversation: "b", bytes: 5), .globalBytes)

        limits.pendingGlobalBytes = 100
        limits.pendingPeerMessages = 1
        quota = PendingQuota(limits: limits)
        XCTAssertEqual(quota.reserve(id: UUID(), peer: "a", conversation: "one", bytes: 1), .accepted)
        XCTAssertEqual(quota.reserve(id: UUID(), peer: "a", conversation: "two", bytes: 1), .peerCount)

        limits.pendingPeerMessages = 10
        limits.pendingPeerBytes = 6
        quota = PendingQuota(limits: limits)
        XCTAssertEqual(quota.reserve(id: UUID(), peer: "a", conversation: "one", bytes: 4), .accepted)
        XCTAssertEqual(quota.reserve(id: UUID(), peer: "a", conversation: "two", bytes: 3), .peerBytes)

        limits.pendingPeerBytes = 100
        limits.pendingConversationMessages = 1
        quota = PendingQuota(limits: limits)
        XCTAssertEqual(quota.reserve(id: UUID(), peer: "a", conversation: "chat", bytes: 1), .accepted)
        XCTAssertEqual(quota.reserve(id: UUID(), peer: "b", conversation: "chat", bytes: 1), .conversationCount)

        limits.pendingConversationMessages = 10
        limits.pendingConversationBytes = 6
        quota = PendingQuota(limits: limits)
        XCTAssertEqual(quota.reserve(id: UUID(), peer: "a", conversation: "chat", bytes: 4), .accepted)
        XCTAssertEqual(quota.reserve(id: UUID(), peer: "b", conversation: "chat", bytes: 3), .conversationBytes)
    }

    func testPendingQuotaReconcilesOnlyUnresolvedOutgoingMessages() {
        let pending = message(1, incoming: false)
        let incoming = message(2)
        let delivered = message(3, incoming: false, delivered: true)
        let failed = message(4, incoming: false, failed: true)
        let quota = PendingQuota()

        quota.reconcile([pending, incoming, delivered, failed])
        XCTAssertEqual(quota.count, 1)
        quota.release(pending.id)
        XCTAssertEqual(quota.count, 0)
    }

    func testMetadataLruStaysBoundedUnderTenThousandPeerIds() {
        let values = BoundedLruMap<Data, Int>(maximum: 1_000)
        for value in 0..<10_000 {
            values[Data("peer-\(value)".utf8)] = value
        }

        XCTAssertEqual(values.count, 1_000)
        XCTAssertNil(values[Data("peer-0".utf8)])
        XCTAssertEqual(values[Data("peer-9999".utf8)], 9_999)
    }

    func testLruTouchUpdateRemovalAndSetSemantics() {
        let values = BoundedLruMap<String, Int>(maximum: 2)
        values["a"] = 1
        values["b"] = 2
        XCTAssertEqual(values["a"], 1)
        values["c"] = 3
        XCTAssertNil(values["b"], "reading a must make b the least recently used entry")
        values["a"] = 4
        XCTAssertEqual(values.snapshot, ["a": 4, "c": 3])
        values["c"] = nil
        XCTAssertEqual(values.count, 1)

        let set = BoundedLruSet<String>(maximum: 2)
        XCTAssertTrue(set.insert("a").inserted)
        XCTAssertFalse(set.insert("a").inserted)
        XCTAssertTrue(set.contains("a"))
        XCTAssertNil(set.remove("missing"))
        XCTAssertEqual(set.remove("a"), "a")
        XCTAssertFalse(set.contains("a"))
        set.replace(with: (0..<10_000).map(String.init))
        XCTAssertEqual(set.count, 2)
        XCTAssertFalse(set.contains("0"))
        XCTAssertTrue(set.contains("9999"))
    }
}
