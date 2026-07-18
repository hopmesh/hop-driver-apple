// Mirror-persistence round-trips (cov/apple-driver): messages.json / contacts.json / channels.json are the
// on-disk UI history the chat list reads on relaunch. Save on one bearer, load on a fresh one, assert the
// content survived. The mirror files live in a process-global Documents dir (as in production), so each
// test clears them before/after - matching BackgroundFlushTests' existing pattern.

import XCTest
import Foundation
@testable import HopDriver

final class HeadlessPersistenceTests: XCTestCase {

    private func clearMirrors() {
        let fm = FileManager.default
        MirrorStore.flush()
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for name in ["messages.json", "contacts.json", "channels.json", "automation.json"] {
            try? fm.removeItem(at: docs.appendingPathComponent(name))
        }
        for url in [MirrorStore.messagesFileURL, MirrorStore.contactsFileURL, MirrorStore.channelsFileURL,
                    MirrorStore.messagesJournalURL, MirrorStore.channelsJournalURL] {
            try? fm.removeItem(at: url)
            try? fm.removeItem(at: url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).quarantine"))
        }
        for file in (try? fm.contentsOfDirectory(at: MirrorStore.mediaDirectoryURL,
                                                 includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: file)
        }
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
                                             contentType: "image/jpeg", imageData: Data([0x01, 0x02]),
                                             inboxId: foreignAddr(0x98)))
        a.flushPendingSaves()   // synchronous write

        let bearer2 = makeHeadlessBearer(seed: 0x12)
        bearer2.loadMessages()
        XCTAssertEqual(bearer2.messages.count, 2)
        XCTAssertEqual(bearer2.messages.first?.text, "persist me")
        XCTAssertTrue(bearer2.messages.first?.delivered ?? false, "delivery state survives a restart")
        XCTAssertEqual(bearer2.messages.first?.bundleId, foreignAddr(0x99), "the in-flight bundle id is restored for status re-query")
        XCTAssertEqual(bearer2.messages.last?.imageData, Data([0x01, 0x02]))
        XCTAssertEqual(bearer2.messages.last?.inboxId, foreignAddr(0x98))
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

    func testMediaAndConversationDeletionPersistAndCollectFiles() {
        let bearer = makeHeadlessBearer()
        let peer = HopBearer.Peer(address: foreignAddr(0x61), name: "Delete", hops: 0)
        bearer.send("text", to: peer)
        bearer.sendImage(Data(repeating: 5, count: 64), to: peer)
        settle(bearer)
        bearer.flushPendingSaves()
        let mediaFiles = (try? FileManager.default.contentsOfDirectory(
            at: MirrorStore.mediaDirectoryURL, includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertFalse(mediaFiles.isEmpty)
        XCTAssertEqual(try? MirrorStore.mediaDirectoryURL
            .resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(try? mediaFiles[0]
            .resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

        bearer.deleteMedia(for: peer)
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(
            at: MirrorStore.mediaDirectoryURL, includingPropertiesForKeys: nil
        ))?.isEmpty ?? false)
        XCTAssertTrue(bearer.messages.allSatisfy { $0.imageData == nil && $0.images.isEmpty })

        bearer.deleteConversation(peer)
        XCTAssertTrue(bearer.messages.isEmpty)
        let restarted = makeHeadlessBearer(seed: 0x62)
        restarted.loadMessages()
        XCTAssertTrue(restarted.messages.isEmpty)
    }

    func testStartupReconciliationDeletesOnlyOwnedOrphanMedia() throws {
        let directory = MirrorStore.mediaDirectoryURL
        let orphan = directory.appendingPathComponent(String(repeating: "a", count: 64))
        let foreign = directory.appendingPathComponent("do-not-delete")
        try Data([1, 2, 3]).write(to: orphan)
        try Data("foreign".utf8).write(to: foreign)

        let bearer = makeHeadlessBearer()
        bearer.loadMessages()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: foreign.path))
        let quarantine = directory.deletingLastPathComponent().appendingPathComponent("media.quarantine")
        XCTAssertFalse(((try? FileManager.default.contentsOfDirectory(
            at: quarantine, includingPropertiesForKeys: nil
        )) ?? []).isEmpty)
    }

    func testDiskWriteFailureIsReportedAsNotDurable() throws {
        let url = MirrorStore.messagesFileURL
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(MirrorStore.saveMessages([
            HopBearer.Message(peer: "x", text: "cannot write", incoming: true),
        ]))
    }

    func testStartupReplaysMessageJournalAndDeduplicatesEitherCompactionCrashPoint() throws {
        let id = foreignAddr(0x71)
        var message = HopBearer.Message(
            peer: "Journal", text: "journal-only", incoming: true, peerAddr: foreignAddr(0x72)
        )
        message.inboxId = id
        XCTAssertTrue(MirrorStore.appendMessageDelta(id: id, message: message))

        let beforeSnapshot = makeHeadlessBearer(seed: 0x73)
        beforeSnapshot.loadMessages()
        XCTAssertEqual(beforeSnapshot.messages.filter { $0.inboxId == id }.count, 1)
        XCTAssertTrue(DeltaJournal(
            url: MirrorStore.messagesJournalURL,
            maximumBytes: RetentionPolicy.defaults.journalBytes,
            maximumRecords: RetentionPolicy.defaults.journalRecords,
            maximumRecordBytes: RetentionPolicy.defaults.journalRecordBytes
        ).replay().records.isEmpty)

        XCTAssertTrue(MirrorStore.appendMessageDelta(id: id, message: message))
        let afterSnapshot = makeHeadlessBearer(seed: 0x74)
        afterSnapshot.loadMessages()
        XCTAssertEqual(afterSnapshot.messages.filter { $0.inboxId == id }.count, 1)
    }

    func testStartupReplaysChannelJournalAndDeduplicatesEitherCompactionCrashPoint() {
        let id = foreignAddr(0x75)
        let topic = "host/topic"
        let row = HopBearer.HpsMsgRow(
            path: "topic", sender: foreignAddr(0x76), text: "journal-only", at: 42, inboxId: id
        )
        XCTAssertTrue(MirrorStore.appendChannelDelta(id: id, topic: topic, row: row))

        let beforeSnapshot = makeHeadlessBearer(seed: 0x77)
        beforeSnapshot.loadChannels()
        XCTAssertEqual(beforeSnapshot.hpsThreads[topic]?.filter { $0.inboxId == id }.count, 1)
        XCTAssertTrue(DeltaJournal(
            url: MirrorStore.channelsJournalURL,
            maximumBytes: RetentionPolicy.defaults.journalBytes,
            maximumRecords: RetentionPolicy.defaults.journalRecords,
            maximumRecordBytes: RetentionPolicy.defaults.journalRecordBytes
        ).replay().records.isEmpty)

        XCTAssertTrue(MirrorStore.appendChannelDelta(id: id, topic: topic, row: row))
        let afterSnapshot = makeHeadlessBearer(seed: 0x78)
        afterSnapshot.loadChannels()
        XCTAssertEqual(afterSnapshot.hpsThreads[topic]?.filter { $0.inboxId == id }.count, 1)
    }

    func testJournalBackedConversationDeletionSurvivesRestart() {
        let peer = HopBearer.Peer(address: foreignAddr(0x79), name: "Delete journal", hops: 0)
        let id = foreignAddr(0x7a)
        var message = HopBearer.Message(peer: peer.name, text: "delete me", incoming: true,
                                        peerAddr: peer.address)
        message.inboxId = id
        XCTAssertTrue(MirrorStore.appendMessageDelta(id: id, message: message))

        let bearer = makeHeadlessBearer(seed: 0x7b)
        bearer.loadMessages()
        XCTAssertEqual(bearer.messages.filter { $0.inboxId == id }.count, 1)
        bearer.deleteConversation(peer)

        let restarted = makeHeadlessBearer(seed: 0x7c)
        restarted.loadMessages()
        XCTAssertTrue(restarted.messages.allSatisfy { $0.inboxId != id })
    }

    func testJournalBackedChannelDeletionSurvivesRestart() {
        let host = foreignAddr(0x7d)
        let topic = HopBearer.HpsTopic(host: host, path: "delete-channel", isChannel: true, hosting: false)
        let id = foreignAddr(0x7e)
        let row = HopBearer.HpsMsgRow(
            path: topic.path, sender: foreignAddr(0x7f), text: "delete me", at: 42, inboxId: id
        )
        XCTAssertTrue(MirrorStore.appendChannelDelta(id: id, topic: topic.id, row: row))

        let bearer = makeHeadlessBearer(seed: 0x80)
        bearer.loadChannels()
        bearer.hpsTopics = [topic]
        XCTAssertEqual(bearer.hpsThreads[topic.id]?.filter { $0.inboxId == id }.count, 1)
        bearer.hpsLeave(topic)
        settle(bearer)

        let restarted = makeHeadlessBearer(seed: 0x81)
        restarted.loadChannels()
        XCTAssertNil(restarted.hpsThreads[topic.id])
    }

    func testOversizedMirrorsAreQuarantinedBeforeDecode() throws {
        for (url, maximum) in [
            (MirrorStore.messagesFileURL, RetentionPolicy.defaults.messageMirrorBytes),
            (MirrorStore.channelsFileURL, RetentionPolicy.defaults.channelMirrorBytes),
        ] {
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(maximum + 1))
            try handle.close()
        }

        XCTAssertNotNil(MirrorStore.loadMessages())
        XCTAssertNotNil(MirrorStore.loadChannels())
        XCTAssertTrue(FileManager.default.fileExists(atPath: MirrorStore.messagesFileURL.path + ".quarantine"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: MirrorStore.channelsFileURL.path + ".quarantine"))
    }
}
