import XCTest
import Foundation
@testable import HopDriver

final class MediaDiskTests: XCTestCase {
    private var root: URL!
    private var media: URL { root.appendingPathComponent("media") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hop-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func limits(global: Int = 8, peer: Int = 8, conversation: Int = 8,
                        attachment: Int = 8, files: Int = 32,
                        scanBytes: Int = 256) -> RetentionLimits {
        var value = RetentionLimits()
        value.globalMediaBytes = global
        value.peerMediaBytes = peer
        value.conversationMediaBytes = conversation
        value.attachmentBytes = attachment
        value.mediaDirectoryFiles = files
        value.mediaDirectoryScanBytes = scanBytes
        return value
    }

    private func disk(_ limits: RetentionLimits? = nil) -> MediaDisk {
        MediaDisk(directory: media, limits: limits ?? self.limits())
    }

    private func reference(_ disk: MediaDisk, _ data: Data,
                           peer: String = "p", conversation: String = "c") -> MediaDiskReference {
        MediaDiskReference(name: disk.name(data), peer: peer, conversation: conversation)
    }

    private func mediaFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: media, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    func testCapAndCapPlusOneUseActualFilesystemBytes() {
        let subject = disk()
        let first = Data([1, 2, 3, 4])
        let second = Data([5, 6, 7, 8])
        let extra = Data([9])
        var durable: [MediaDiskReference] = []

        for data in [first, second] {
            let ref = reference(subject, data)
            let projected = durable + [ref]
            XCTAssertEqual(subject.commit(
                durableSnapshot: { MediaDiskSnapshot(references: durable) },
                blobs: [MediaDiskBlob(bytes: data, peer: "p", conversation: "c")],
                resultingReferences: projected,
                durableCommit: { durable = projected; return true }
            ), .committed)
        }
        XCTAssertEqual(subject.usageBytesForTest(), 8)

        let extraRef = reference(subject, extra)
        XCTAssertEqual(subject.commit(
            durableSnapshot: { MediaDiskSnapshot(references: durable) },
            blobs: [MediaDiskBlob(bytes: extra, peer: "p", conversation: "c")],
            resultingReferences: durable + [extraRef],
            durableCommit: { XCTFail("over-cap content reached the durable commit"); return true }
        ), .quota)
        XCTAssertEqual(subject.usageBytesForTest(), 8)
    }

    func testSustainedUniqueAttachmentChurnDeletesEachEvictionSynchronously() {
        let subject = disk(limits(global: 4, peer: 4, conversation: 4, attachment: 4))
        var durable: [MediaDiskReference] = []
        for value in 0..<100 {
            let data = Data([UInt8(value), UInt8(value >> 8), 0xaa, 0x55])
            let ref = reference(subject, data)
            XCTAssertEqual(subject.commit(
                durableSnapshot: { MediaDiskSnapshot(references: durable) },
                blobs: [MediaDiskBlob(bytes: data, peer: "p", conversation: "c")],
                resultingReferences: [ref],
                durableCommit: { durable = [ref]; return true }
            ), .committed)
            XCTAssertEqual(subject.usageBytesForTest(), 4)
            XCTAssertEqual(mediaFiles().map(\.lastPathComponent), [ref.name])
        }
    }

    func testJournalSnapshotAndInsertionFailureAfterBlobWriteRollBackTheNewFile() throws {
        let subject = disk()
        let data = Data([1, 3, 5, 7])
        let ref = reference(subject, data)
        var durable: [MediaDiskReference] = []
        let journalURL = root.appendingPathComponent("messages.delta")
        try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: false)
        let journal = DeltaJournal(url: journalURL, maximumBytes: 1_024,
                                   maximumRecords: 4, maximumRecordBytes: 128)
        let snapshotURL = root.appendingPathComponent("messages.json")
        try FileManager.default.createDirectory(at: snapshotURL, withIntermediateDirectories: false)
        let failures: [(String, () -> Bool)] = [
            ("journal", { journal.append(id: Data([1]), payload: Data([2])) }),
            ("snapshot", {
                do { try Data([1]).write(to: snapshotURL); return true } catch { return false }
            }),
            ("insertion", { false }),
        ]

        for (failure, commit) in failures {
            XCTAssertEqual(subject.commit(
                durableSnapshot: { MediaDiskSnapshot(references: durable) },
                blobs: [MediaDiskBlob(bytes: data, peer: "p", conversation: "c")],
                resultingReferences: [ref],
                durableCommit: {
                    XCTAssertTrue(FileManager.default.fileExists(atPath: self.media
                        .appendingPathComponent(ref.name).path), "\(failure) fails after the blob write")
                    return commit()
                }
            ), .ioError)
            XCTAssertTrue(mediaFiles().isEmpty)
            XCTAssertTrue(durable.isEmpty)
        }
    }

    func testSharedBlobSurvivesUntilItsLastReferenceIsEvicted() {
        let subject = disk()
        let data = Data([2, 4, 6, 8])
        let alice = reference(subject, data, peer: "alice", conversation: "a")
        let bob = reference(subject, data, peer: "bob", conversation: "b")
        var durable: [MediaDiskReference] = []

        XCTAssertEqual(subject.commit(
            durableSnapshot: { MediaDiskSnapshot(references: durable) },
            blobs: [MediaDiskBlob(bytes: data, peer: "alice", conversation: "a")],
            resultingReferences: [alice, bob],
            durableCommit: { durable = [alice, bob]; return true }
        ), .committed)
        XCTAssertEqual(mediaFiles().count, 1)

        XCTAssertEqual(subject.commit(
            durableSnapshot: { MediaDiskSnapshot(references: durable) }, blobs: [],
            resultingReferences: [bob], durableCommit: { durable = [bob]; return true }
        ), .committed)
        XCTAssertEqual(mediaFiles().count, 1)

        XCTAssertEqual(subject.commit(
            durableSnapshot: { MediaDiskSnapshot(references: durable) }, blobs: [],
            resultingReferences: [], durableCommit: { durable = []; return true }
        ), .committed)
        XCTAssertTrue(mediaFiles().isEmpty)
    }

    func testPeerAndConversationCapsCountSharedFilesPerOwner() {
        let subject = disk(limits(global: 16, peer: 8, conversation: 4, attachment: 8))
        let first = Data([1, 1, 1, 1])
        let second = Data([2])
        let firstRef = reference(subject, first, peer: "p", conversation: "c")
        let secondRef = reference(subject, second, peer: "p", conversation: "c")
        var durable: [MediaDiskReference] = []
        XCTAssertEqual(subject.commit(
            durableSnapshot: { MediaDiskSnapshot(references: durable) },
            blobs: [MediaDiskBlob(bytes: first, peer: "p", conversation: "c")],
            resultingReferences: [firstRef], durableCommit: { durable = [firstRef]; return true }
        ), .committed)
        XCTAssertEqual(subject.commit(
            durableSnapshot: { MediaDiskSnapshot(references: durable) },
            blobs: [MediaDiskBlob(bytes: second, peer: "p", conversation: "c")],
            resultingReferences: [firstRef, secondRef],
            durableCommit: { XCTFail("conversation cap must reject cap plus one"); return true }
        ), .quota)
    }

    func testRestartDeletesOrphansAndQuarantinesForeignAndNonRegularEntries() throws {
        let subject = disk()
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let orphan = Data([9, 8, 7])
        try orphan.write(to: media.appendingPathComponent(subject.name(orphan)))
        try Data([1]).write(to: media.appendingPathComponent("foreign"))
        let outside = root.appendingPathComponent("outside")
        try Data([2]).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: media.appendingPathComponent(String(repeating: "a", count: 64)),
            withDestinationURL: outside
        )
        try FileManager.default.createDirectory(
            at: media.appendingPathComponent(String(repeating: "b", count: 64)),
            withIntermediateDirectories: false
        )

        XCTAssertEqual(subject.reconcile(MediaDiskSnapshot(references: [])), .committed)
        XCTAssertTrue(mediaFiles().isEmpty)
        XCTAssertEqual(try Data(contentsOf: outside), Data([2]))
        let quarantine = root.appendingPathComponent("media.quarantine")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: quarantine, includingPropertiesForKeys: nil
        ).count, 3)
    }

    func testRestartRestoresInterruptedEvictionAndBoundsDirectoryEnumeration() throws {
        let data = Data([4, 3, 2, 1])
        let subject = disk(limits(global: 8, peer: 8, conversation: 8, attachment: 8, files: 4))
        let ref = reference(subject, data)
        let transaction = root.appendingPathComponent(".media.transaction")
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        try data.write(to: transaction.appendingPathComponent(ref.name))
        XCTAssertEqual(subject.reconcile(MediaDiskSnapshot(references: [ref])), .committed)
        XCTAssertEqual(subject.read(ref.name), data)

        let bounded = disk(limits(global: 8, peer: 8, conversation: 8, attachment: 8, files: 1))
        try Data([7]).write(to: media.appendingPathComponent(bounded.name(Data([7]))))
        try Data([8]).write(to: media.appendingPathComponent(bounded.name(Data([8]))))
        XCTAssertEqual(bounded.reconcile(MediaDiskSnapshot(references: [])), .ioError)

        try? FileManager.default.removeItem(at: media)
        let byteBounded = disk(limits(global: 8, peer: 8, conversation: 8,
                                      attachment: 8, files: 4, scanBytes: 1))
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data([1, 2]).write(to: media.appendingPathComponent(byteBounded.name(Data([1, 2]))))
        XCTAssertEqual(byteBounded.reconcile(MediaDiskSnapshot(references: [])), .ioError)
    }

    func testConcurrentAdmissionCannotExceedTheGlobalCap() {
        final class State: @unchecked Sendable {
            var references: [MediaDiskReference] = []
            var accepted = 0
        }
        let subject = disk(limits(global: 8, peer: 8, conversation: 8, attachment: 2))
        let state = State()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "media-admission", attributes: .concurrent)
        for value in 0..<32 {
            group.enter()
            queue.async {
                let data = Data([UInt8(value), 0xff])
                let ref = self.reference(subject, data)
                var projected: [MediaDiskReference] = []
                _ = subject.commit(
                    durableSnapshot: { MediaDiskSnapshot(references: state.references) },
                    blobs: [MediaDiskBlob(bytes: data, peer: "p", conversation: "c")],
                    resultingReferences: {
                        projected = state.references + [ref]
                        return projected
                    },
                    durableCommit: {
                        state.references = projected
                        state.accepted += 1
                        return true
                    }
                )
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(state.accepted, 4)
        XCTAssertEqual(subject.usageBytesForTest(), 8)
        XCTAssertEqual(mediaFiles().count, 4)
    }
}
