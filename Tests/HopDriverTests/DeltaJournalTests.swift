import CryptoKit
import Foundation
import XCTest
@testable import HopDriver

final class DeltaJournalTests: XCTestCase {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hop-delta-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func journal(_ url: URL, maximumBytes: Int = 1_024,
                         maximumRecords: Int = 2, maximumRecordBytes: Int = 128) -> DeltaJournal {
        DeltaJournal(url: url, maximumBytes: maximumBytes, maximumRecords: maximumRecords,
                     maximumRecordBytes: maximumRecordBytes)
    }

    func testAppendReplayRecordCapAndReset() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("messages.delta")
            let subject = journal(url)

            XCTAssertTrue(subject.replay().records.isEmpty)
            XCTAssertFalse(subject.append(id: Data(), payload: Data()))
            XCTAssertFalse(subject.append(id: Data(repeating: 1, count: 65), payload: Data()))
            XCTAssertFalse(subject.append(id: Data([1]), payload: Data(repeating: 1, count: 129)))
            XCTAssertTrue(subject.append(id: Data([1]), payload: Data("one".utf8)))
            XCTAssertTrue(subject.append(id: Data([2]), payload: nil))
            XCTAssertFalse(subject.append(id: Data([3]), payload: Data("three".utf8)))

            let replay = subject.replay()
            XCTAssertFalse(replay.quarantined)
            XCTAssertEqual(replay.records.count, 2)
            XCTAssertEqual(replay.records.map(\.id), [Data([1]), Data([2])])
            XCTAssertEqual(replay.records.map(\.payload), [Data("one".utf8), nil])

            XCTAssertTrue(subject.reset())
            XCTAssertTrue(subject.replay().records.isEmpty)
            XCTAssertTrue(subject.append(id: Data([4]), payload: Data()))
        }
    }

    func testEachAppendIsBoundedIndependentlyOfSnapshotSize() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("messages.delta")
            let subject = journal(url, maximumBytes: 59, maximumRecords: 8, maximumRecordBytes: 8)

            XCTAssertTrue(subject.append(id: Data([1]), payload: Data(repeating: 7, count: 4)))
            let firstSize = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            XCTAssertEqual(firstSize, 59)
            XCTAssertFalse(subject.append(id: Data([2]), payload: Data()))
            XCTAssertEqual(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, firstSize)
        }
    }

    func testChecksumCorruptionIsQuarantinedAndTheStableIdCanRetry() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("channels.delta")
            XCTAssertTrue(journal(url).append(id: Data([1]), payload: Data("secret".utf8)))
            var bytes = try Data(contentsOf: url)
            bytes[bytes.index(before: bytes.endIndex)] ^= 1
            try bytes.write(to: url)

            let restarted = journal(url)
            XCTAssertFalse(restarted.append(id: Data([2]), payload: Data("retry".utf8)))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("channels.delta.quarantine").path
            ))
            XCTAssertTrue(restarted.append(id: Data([2]), payload: Data("retry".utf8)))
            XCTAssertEqual(restarted.replay().records.single?.id, Data([2]))
        }
    }

    func testOversizedAndMalformedJournalsAreQuarantinedBeforeReplay() throws {
        try withDirectory { directory in
            let oversized = directory.appendingPathComponent("oversized.delta")
            try Data(repeating: 0, count: 1_025).write(to: oversized)
            let oversizedReplay = journal(oversized).replay()
            XCTAssertTrue(oversizedReplay.quarantined)
            XCTAssertTrue(oversizedReplay.records.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: oversized.path + ".quarantine"))

            let malformed = directory.appendingPathComponent("malformed.delta")
            try Data(repeating: 0, count: 10).write(to: malformed)
            let malformedReplay = journal(malformed).replay()
            XCTAssertTrue(malformedReplay.quarantined)
            XCTAssertTrue(malformedReplay.records.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: malformed.path + ".quarantine"))
        }
    }

    func testTruncatedTailReplaysOnlyCompleteSyncedPrefix() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("messages.delta")
            let writer = journal(url, maximumRecords: 4)
            XCTAssertTrue(writer.append(id: Data([1]), payload: Data("complete".utf8)))
            XCTAssertTrue(writer.append(id: Data([2]), payload: Data("truncated".utf8)))
            let size = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(size - 1))
            try handle.close()

            let replay = journal(url, maximumRecords: 4).replay()
            XCTAssertTrue(replay.quarantined)
            XCTAssertEqual(replay.records.map(\.id), [Data([1])])
        }
    }

    func testSemanticallyInvalidAuthenticatedRecordIsQuarantined() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("messages.delta")
            var core = Data([2, 1, 0, 1, 0, 0, 0, 0, 7])
            core.append(Data(SHA256.hash(data: core)))
            var file = Data("HOPDELTA1\n".utf8)
            let count = core.count
            file.append(contentsOf: [UInt8(count >> 24), UInt8(count >> 16),
                                     UInt8(count >> 8), UInt8(count)])
            file.append(core)
            try file.write(to: url)

            let replay = journal(url).replay()
            XCTAssertTrue(replay.quarantined)
            XCTAssertTrue(replay.records.isEmpty)
        }
    }

    func testAppendRetriesAfterParentIoFailure() throws {
        try withDirectory { directory in
            let parent = directory.appendingPathComponent("not-a-directory")
            try Data([1]).write(to: parent)
            let subject = journal(parent.appendingPathComponent("messages.delta"))

            XCTAssertFalse(subject.append(id: Data([1]), payload: Data("one".utf8)))
            try FileManager.default.removeItem(at: parent)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            XCTAssertTrue(subject.append(id: Data([1]), payload: Data("one".utf8)))
        }
    }
}

private extension Array {
    var single: Element? { count == 1 ? self[0] : nil }
}
