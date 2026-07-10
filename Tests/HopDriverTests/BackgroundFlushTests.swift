// apple-r3-01: a message received during a short/locked BACKGROUND wake is drained out of the node inbox
// (destructive takeInbox) into the in-memory `messages` array, but the messages.json mirror write is
// DEBOUNCED by 1s (scheduleMessageSave). If iOS suspends/kills the app inside that 1s window the message
// is gone from the node inbox yet never reached the mirror, so it vanishes from chat history on relaunch.
// The fix is a synchronous `flushPendingSaves()` (cancels the debounce, writes NOW), called at the end of
// a background pump (backgroundTick -> pump(flushAfter:true)) and on scenePhase==.background.
//
// This test drives that seam with a real (headless) HopNode against a temp db: it appends a message (which
// schedules the 1s debounce but does NOT write yet), proves the mirror is not on disk, then calls
// flushPendingSaves() and proves the message is now persisted immediately. Fails-before (no flush ⇒ the
// file only appears after the 1s debounce, so an immediate read finds nothing) / passes-after.

import XCTest
import Foundation
@testable import HopDriver

final class BackgroundFlushTests: XCTestCase {

    private func makeBearer() -> HopBearer {
        let db = FileManager.default.temporaryDirectory
            .appendingPathComponent("hop-flush-\(UUID().uuidString).db").path
        return HopBearer(config: .init(
            dbPath: db,
            deviceSeed: Data(repeating: 0x11, count: 32),
            appSecret: Data(repeating: 0x48, count: 32),
            displayName: "flush-test",
            defaultRelay: nil,
            role: .full,
            dbKey: Data()))   // plain store (no SQLCipher key) for the headless test
    }

    /// Clear the shared mirror so this test isn't reading a leftover from a prior run / real use.
    private func clearMirror() {
        try? FileManager.default.removeItem(at: HopBearer.messagesFileURL)
    }

    /// THE apple-r3-01 regression guard. Appending a message schedules the 1s debounce; an IMMEDIATE read
    /// must NOT find the mirror (proving the write really is deferred, the exact window the bug lives in),
    /// and `flushPendingSaves()` must then persist it SYNCHRONOUSLY so a background suspend can't lose it.
    func testFlushPersistsAppendedMessageSynchronously() throws {
        clearMirror()
        defer { clearMirror() }
        let bearer = makeBearer()

        // Append like applyInbox does on a background receive; didSet -> scheduleMessageSave (1s debounce).
        bearer.messages.append(HopBearer.Message(peer: "peerX", text: "background-marker", incoming: true))

        // The debounce has NOT fired yet: the mirror must not exist on disk. (If it does, the debounce
        // isn't actually deferring and this test can't distinguish flush from the timer, so assert it.)
        XCTAssertFalse(FileManager.default.fileExists(atPath: HopBearer.messagesFileURL.path),
                       "mirror should not be written before the 1s debounce fires or an explicit flush")

        // The fix: force the pending write to disk now.
        bearer.flushPendingSaves()

        // It must be persisted synchronously and contain the message.
        let path = HopBearer.messagesFileURL.path
        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                      "flushPendingSaves must write the mirror synchronously (apple-r3-01)")
        let data = try Data(contentsOf: HopBearer.messagesFileURL)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("background-marker"),
                      "the flushed mirror must contain the message drained on the background wake")
    }

    /// flushPendingSaves must be a no-op (and not crash / not write a stale file) when nothing is pending,
    /// so calling it on every scenePhase==.background transition is cheap and safe. Adversarial self-check:
    /// the fix must not itself churn the disk or resurrect a deleted mirror when there's no queued write.
    func testFlushWithNothingPendingDoesNotWrite() {
        clearMirror()
        defer { clearMirror() }
        let bearer = makeBearer()
        // No mutation → no debounced work queued. Flush must not create the file.
        bearer.flushPendingSaves()
        XCTAssertFalse(FileManager.default.fileExists(atPath: HopBearer.messagesFileURL.path),
                       "flush with no pending save must not write a mirror")
    }
}
