// Messaging + contacts + delivery-status coverage driven against a REAL headless node (cov/apple-driver).
// send / sendTo / sendImage / sendMultipart / retry / clearQueue / addContact / rememberContact / setName.

import XCTest
import Foundation
@testable import HopDriver

final class HeadlessMessagingTests: XCTestCase {

    private func peer(_ seed: UInt8 = 0x33, name: String = "Bob") -> HopBearer.Peer {
        HopBearer.Peer(address: foreignAddr(seed), name: name, hops: 0)
    }

    // MARK: send

    func testSendAppendsOutgoingBubbleAndStampsBundleId() {
        let b = makeHeadlessBearer()
        b.send("hello there", to: peer())
        XCTAssertEqual(b.messages.count, 1)
        XCTAssertEqual(b.messages[0].text, "hello there")
        XCTAssertFalse(b.messages[0].incoming)
        XCTAssertEqual(b.messages[0].peerAddr, foreignAddr(0x33))
        settle(b)
        // The node defers an undeliverable send with a valid bundle id (not a throw), so the bubble must
        // carry that id (used to re-query delivery status), not be marked failed.
        XCTAssertNotNil(b.messages[0].bundleId, "a deferred send must stamp its bundle id for status tracking")
        XCTAssertFalse(b.messages[0].failed)
        // messaging someone adds them to the address book.
        XCTAssertTrue(b.contactList.contains { $0.address == foreignAddr(0x33) })
    }

    func testSendToValidAddressAppendsMessage() {
        let b = makeHeadlessBearer()
        b.sendTo(addressBase58: base58(foreignAddr(0x44)), text: "yo")
        settle(b)
        XCTAssertEqual(b.messages.count, 1)
        XCTAssertEqual(b.messages[0].text, "yo")
        XCTAssertEqual(b.messages[0].peerAddr, foreignAddr(0x44))
    }

    func testSendToOwnAddressIsRejected() {
        let b = makeHeadlessBearer()
        b.sendTo(addressBase58: b.myAddress, text: "self")
        settle(b)
        XCTAssertTrue(b.messages.isEmpty, "a device must not message itself")
    }

    func testSendToInvalidAddressIsRejected() {
        let b = makeHeadlessBearer()
        b.sendTo(addressBase58: "not-a-real-address", text: "x")
        settle(b)
        XCTAssertTrue(b.messages.isEmpty)
    }

    func testSendImageAppendsImageBubble() {
        let b = makeHeadlessBearer()
        let img = Data([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10])   // jpeg-ish bytes
        b.sendImage(img, to: peer())
        XCTAssertEqual(b.messages.count, 1)
        XCTAssertEqual(b.messages[0].contentType, "image/jpeg")
        XCTAssertEqual(b.messages[0].imageData, img)
        XCTAssertTrue(b.messages[0].text.isEmpty)
        settle(b)
        XCTAssertNotNil(b.messages[0].bundleId)
    }

    func testSendMultipartCombinesTextAndImages() {
        let b = makeHeadlessBearer()
        let imgs = [Data([0x01, 0x02]), Data([0x03, 0x04])]
        b.sendMultipart(text: "caption", images: imgs, to: peer())
        XCTAssertEqual(b.messages.count, 1)
        XCTAssertEqual(b.messages[0].contentType, "multipart/mixed")
        XCTAssertEqual(b.messages[0].text, "caption")
        XCTAssertEqual(b.messages[0].images, imgs)
        settle(b)
        XCTAssertNotNil(b.messages[0].bundleId)
    }

    func testSendMultipartWithNoPartsIsNoOp() {
        let b = makeHeadlessBearer()
        b.sendMultipart(text: "   ", images: [], to: peer())
        XCTAssertTrue(b.messages.isEmpty, "no text and no images ⇒ nothing to send")
    }

    // MARK: retry

    func testRetryResendsAFailedTextMessage() {
        let b = makeHeadlessBearer()
        b.send("first", to: peer())
        settle(b)
        b.messages[0].failed = true
        b.messages[0].delivered = false
        b.retry(b.messages[0])
        settle(b)
        XCTAssertFalse(b.messages[0].failed, "retry clears the failed flag and re-dispatches")
        XCTAssertNotNil(b.messages[0].bundleId)
    }

    func testRetryRebuildsImageAndMultipartPayloads() {
        let b = makeHeadlessBearer()
        b.sendImage(Data([0x09, 0x08]), to: peer())
        b.sendMultipart(text: "hi", images: [Data([0x01])], to: peer(0x55, name: "Cara"))
        settle(b)
        b.messages[0].failed = true
        b.messages[1].failed = true
        b.retry(b.messages[0])   // image branch
        b.retry(b.messages[1])   // multipart branch
        settle(b)
        XCTAssertFalse(b.messages[0].failed)
        XCTAssertFalse(b.messages[1].failed)
    }

    func testRetryIgnoresIncomingMessages() {
        let b = makeHeadlessBearer()
        let incoming = HopBearer.Message(peer: "X", text: "in", incoming: true)
        b.messages.append(incoming)
        b.retry(incoming)   // guard !m.incoming ⇒ no-op
        XCTAssertEqual(b.messages.count, 1)
    }

    // MARK: clearQueue

    func testClearQueueMarksUndeliveredOwnMessagesFailed() {
        let b = makeHeadlessBearer()
        b.send("a", to: peer())
        b.send("b", to: peer(0x66, name: "Dee"))
        settle(b)
        b.clearQueue()
        settle(b)
        XCTAssertTrue(b.messages.allSatisfy { $0.failed }, "cleared, still-undelivered own messages become 'Not sent'")
    }

    // MARK: contacts

    func testAddContactWithNameSucceeds() {
        let b = makeHeadlessBearer()
        XCTAssertTrue(b.addContact(name: "Alice", address: base58(foreignAddr(0x77))))
        XCTAssertTrue(b.contactList.contains { $0.name == "Alice" })
    }

    func testAddContactWithEmptyNameFallsBackToShortId() {
        let b = makeHeadlessBearer()
        let addr = foreignAddr(0x78)
        XCTAssertTrue(b.addContact(name: "   ", address: base58(addr)))
        let c = b.contactList.first { $0.address == addr }
        XCTAssertEqual(c?.name, HopBearer.shortHex(addr), "an empty alias shows the short address until identify resolves")
    }

    func testAddContactRejectsOwnAndInvalidAddresses() {
        let b = makeHeadlessBearer()
        XCTAssertFalse(b.addContact(name: "me", address: b.myAddress), "cannot add yourself")
        XCTAssertFalse(b.addContact(name: "bad", address: "zzz"), "invalid base58 is rejected")
    }

    func testRememberContactAddsToBook() {
        let b = makeHeadlessBearer()
        b.rememberContact(peer(0x79, name: "Eve"))
        XCTAssertTrue(b.contactList.contains { $0.name == "Eve" })
    }

    // MARK: setName

    func testSetNameUpdatesAndIgnoresEmptyOrUnchanged() {
        let b = makeHeadlessBearer(name: "Old")
        b.myName = "Old"
        b.setName("Fresh")
        XCTAssertEqual(b.myName, "Fresh")
        b.setName("   ")            // empty ⇒ ignored
        XCTAssertEqual(b.myName, "Fresh")
        b.setName("Fresh")          // unchanged ⇒ ignored
        XCTAssertEqual(b.myName, "Fresh")
        settle(b)
    }
}
