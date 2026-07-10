// apple-r2-03: the plaintext UI-history mirrors (messages/channels/contacts.json) must (a) still be
// encrypted at rest, but (b) with a protection class that a LOCKED background receive can still WRITE, so
// a message received while the phone is locked isn't dropped from the UI history mirror. And the plaintext
// automation.json mirror must NEVER be written in a shipped RELEASE build (it would defeat SQLCipher).
// These are pure-policy assertions (no node, no radio), so they run headlessly on macOS.

import XCTest
import Foundation
@testable import HopDriver

final class MirrorPersistenceTests: XCTestCase {

    // MARK: apple-r2-03: UI-mirror file protection lets a locked background receive persist

    /// The mirror write options must be atomic AND use completeFileProtectionUntilFirstUserAuthentication
    /// (NSFileProtectionCompleteUntilFirstUserAuthentication), the class that stays writable after the
    /// first post-boot unlock. This is the exact bit that lets a locked-screen background receive persist.
    func testUiMirrorProtectionUsesUntilFirstUserAuthentication() {
        XCTAssertTrue(HopBearer.uiMirrorProtection.contains(.completeFileProtectionUntilFirstUserAuthentication))
        XCTAssertTrue(HopBearer.uiMirrorProtection.contains(.atomic))
    }

    /// THE apple-r2-03 regression guard: the mirror must NOT use `.completeFileProtection`, which DENIES
    /// writes while the device is locked. Before this fix the mirrors used `.completeFileProtection`, so a
    /// locked background receive silently failed to persist and vanished from the UI on relaunch. If a
    /// future edit reintroduces `.completeFileProtection` this test fails.
    func testUiMirrorProtectionIsNotLockedOutCompleteProtection() {
        XCTAssertFalse(HopBearer.uiMirrorProtection.contains(.completeFileProtection),
                       "messages/channels/contacts mirror must not use completeFileProtection (denies locked-screen writes)")
    }

    // MARK: plaintext-mirror gating: automation.json is never written in a shipped RELEASE build

    /// A RELEASE build (isDebug=false) with no HOP_AUTO env must NOT enable the plaintext mirror. This is
    /// the invariant that keeps SQLCipher-at-rest intact: the shipped app never drops a plaintext mirror.
    func testAutomationMirrorDisabledInReleaseWithoutHarnessEnv() {
        XCTAssertFalse(HopBearer.automationMirrorEnabled(isDebug: false, hopAutoEnv: nil))
    }

    /// The mirror is enabled ONLY for the harness: a DEBUG build, or any build launched with HOP_AUTO.
    func testAutomationMirrorEnabledForHarnessPathsOnly() {
        XCTAssertTrue(HopBearer.automationMirrorEnabled(isDebug: true, hopAutoEnv: nil))       // debug build
        XCTAssertTrue(HopBearer.automationMirrorEnabled(isDebug: false, hopAutoEnv: "1"))      // release + harness env
        XCTAssertTrue(HopBearer.automationMirrorEnabled(isDebug: true, hopAutoEnv: "1"))       // both
        XCTAssertFalse(HopBearer.automationMirrorEnabled(isDebug: false, hopAutoEnv: nil))     // shipped release
        // An empty string is still a set env (the harness may launch with HOP_AUTO=""), so it enables.
        XCTAssertTrue(HopBearer.automationMirrorEnabled(isDebug: false, hopAutoEnv: ""))
    }
}
