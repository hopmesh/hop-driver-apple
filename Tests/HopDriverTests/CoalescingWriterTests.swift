import XCTest
import Foundation
@testable import HopDriver

final class CoalescingWriterTests: XCTestCase {
    func testBurstWritesOnlyTheRunningAndLatestPendingSnapshot() {
        let writer = CoalescingWriter()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var writes: [Int] = []
        writer.submit(key: "messages") {
            started.signal()
            release.wait()
            lock.lock(); writes.append(0); lock.unlock()
        }
        started.wait()
        for value in 1...100 {
            writer.submit(key: "messages") { lock.lock(); writes.append(value); lock.unlock() }
        }
        release.signal()
        writer.flush()
        XCTAssertEqual(writes, [0, 100])
    }

    func testAllMirrorTypesAreSerialized() {
        let writer = CoalescingWriter()
        let lock = NSLock()
        var active = 0
        var maximum = 0
        for key in ["messages", "contacts", "channels"] {
            writer.submit(key: key) {
                lock.lock(); active += 1; maximum = max(maximum, active); lock.unlock()
                Thread.sleep(forTimeInterval: 0.01)
                lock.lock(); active -= 1; lock.unlock()
            }
        }
        writer.flush()
        XCTAssertEqual(maximum, 1)
    }

    func testContinuousUpdatesCannotMoveCompactionPastTheFirstDirtyDeadline() {
        var deadline = CompactionDeadline()
        XCTAssertEqual(deadline.nextDelay(now: 10, debounce: 1, maximumDelay: 5), 1)
        XCTAssertEqual(deadline.nextDelay(now: 12, debounce: 1, maximumDelay: 5), 1)
        XCTAssertEqual(deadline.nextDelay(now: 14.75, debounce: 1, maximumDelay: 5), 0.25)
        XCTAssertEqual(deadline.nextDelay(now: 15, debounce: 1, maximumDelay: 5), 0)
        deadline.clear()
        XCTAssertEqual(deadline.nextDelay(now: 20, debounce: 1, maximumDelay: 5), 1)
    }
}
