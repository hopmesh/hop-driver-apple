// Mirror-persistence round-trips (cov/apple-driver): messages.json / contacts.json / channels.json are the
// on-disk UI history the chat list reads on relaunch. Save on one bearer, load on a fresh one, assert the
// content survived. The mirror files live in a process-global Documents dir (as in production), so each
// test clears them before/after — matching BackgroundFlushTests' existing pattern.

import XCTest
import Foundation
@testable import HopDriver

final class HeadlessPersistenceTests: XCTestCase {

    private func clearMirrors() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for name in ["messages.json", "contacts.json", "channels.json", "automation.json"] {
            try? fm.removeItem(at: docs.appendingPathComponent(name))
        }
        try? fm.removeItem(at: HopBearer.messagesFileURL)
    }

    override func setUp() { super.setUp(); clearMirrors() }
    override func tearDown() { clearMirrors(); super.tearDown() }

    func testMessagesRoundTripThroughDisk() {
        let a = makeHeadlessBearer()
        var text = HopBearer.Message(peer: "Bob", text: "persist me", incoming: false, peerAddr: foreignAddr(0x51))
        text.bundleId = foreignAddr(0x99)
        text.delivered = true
        a.messages.append(text)
        a.messages.append(HopBearer.Message(peer: "Bob", text: "", incoming: true, peerAddr: foreignAddr(0x51),
                                            contentType: "image/jpeg", imageData: Data([0x01, 0x02])))
        a.flushPendingSaves()   // synchronous write

        let bearer2 = makeHeadlessBearer(seed: 0x12)
        bearer2.loadMessages()
        XCTAssertEqual(bearer2.messages.count, 2)
        XCTAssertEqual(bearer2.messages.first?.text, "persist me")
        XCTAssertTrue(bearer2.messages.first?.delivered ?? false, "delivery state survives a restart")
        XCTAssertEqual(bearer2.messages.first?.bundleId, foreignAddr(0x99), "the in-flight bundle id is restored for status re-query")
        XCTAssertEqual(bearer2.messages.last?.imageData, Data([0x01, 0x02]))
    }

    func testLoadMessagesWithNoFileIsANoOp() {
        let b = makeHeadlessBearer()
        b.loadMessages()   // nothing on disk ⇒ guard returns, messages stay empty
        XCTAssertTrue(b.messages.isEmpty)
    }

    func testContactsRoundTripThroughDisk() {
        let a = makeHeadlessBearer()
        XCTAssertTrue(a.addContact(name: "Persisted", address: base58(foreignAddr(0x52))))
        a.saveContacts(force: true)
        // saveContacts writes on a utility queue; give it a beat to land.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        let bearer2 = makeHeadlessBearer(seed: 0x13)
        bearer2.loadContacts()
        XCTAssertTrue(bearer2.contactList.contains { $0.name == "Persisted" })
    }

    func testChannelsRoundTripThroughDisk() {
        let a = makeHeadlessBearer()
        let row = HopBearer.HpsMsgRow(path: "room/1", sender: foreignAddr(0x53), text: "channel history", at: 42)
        a.hpsThreads["somehost/room/1"] = [row]   // @Published didSet ⇒ scheduleChannelSave (debounced)
        a.flushPendingSaves()                      // force the channel write now

        let bearer2 = makeHeadlessBearer(seed: 0x14)
        bearer2.loadChannels()
        XCTAssertEqual(bearer2.hpsThreads["somehost/room/1"]?.first?.text, "channel history")
    }

    func testSaveMessagesWritesTheMirrorFile() {
        let a = makeHeadlessBearer()
        a.messages.append(HopBearer.Message(peer: "Z", text: "direct save", incoming: true))
        a.saveMessages()
        XCTAssertTrue(FileManager.default.fileExists(atPath: HopBearer.messagesFileURL.path))
    }
}
