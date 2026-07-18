// sec-priv-02: the Keychain-backed identity/db-key store must (a) return a stable 32-byte secret
// across calls (so the identity/address is fixed), (b) return DIFFERENT secrets for different
// accounts (identity vs db key are independent), (c) generate a high-entropy random value (not a
// derivation of a device attribute), and (d) round-trip the Secure-Enclave wrap when present. These
// run headlessly against the macOS login keychain (SE-absent path); a test account is used so the
// real identity item is never touched.

import XCTest
import Foundation
import Security
@testable import HopDriver

final class KeychainTests: XCTestCase {

    /// A per-run test account, cleaned up in tearDown, so we never touch the real identity item.
    private var accounts: [String] = []

    private func freshAccount() -> String {
        let a = "test-\(UUID().uuidString)"
        accounts.append(a)
        return a
    }

    override func tearDown() {
        for a in accounts {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: HopKeychain.service,
                kSecAttrAccount as String: a,
            ]
            SecItemDelete(q as CFDictionary)
        }
        accounts.removeAll()
        super.tearDown()
    }

    func testSecretIsStableAcrossCallsAnd32Bytes() throws {
        let acct = freshAccount()
        let first = try HopKeychain.secret(account: acct)
        XCTAssertEqual(first.bytes.count, 32)
        XCTAssertEqual(first.origin, .created, "first read for a new account generates + stores it")

        let second = try HopKeychain.secret(account: acct)
        XCTAssertEqual(second.bytes, first.bytes, "the same account returns the identical secret")
        XCTAssertEqual(second.origin, .loaded, "the second read is a keychain load, not a regenerate")
    }

    func testDistinctAccountsGetDistinctSecrets() throws {
        let a = try HopKeychain.secret(account: freshAccount()).bytes
        let b = try HopKeychain.secret(account: freshAccount()).bytes
        XCTAssertNotEqual(a, b, "identity and db-key secrets must be independent")
    }

    func testSecretIsHighEntropyNotADeviceDerivation() throws {
        // A SHA-256(vendorId) would be deterministic and identical for two fresh accounts on the same
        // device basis; a real CSPRNG secret differs, and is not all-zero / low-entropy.
        let s = try HopKeychain.secret(account: freshAccount()).bytes
        XCTAssertNotEqual(s, Data(repeating: 0, count: 32))
        XCTAssertGreaterThan(Set(s).count, 8, "32 random bytes should have many distinct byte values")
    }

    func testRandomBytesAreUnique() throws {
        let a = try HopKeychain.randomBytes(32)
        let b = try HopKeychain.randomBytes(32)
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
    }

    /// The SE-wrap round-trips (or cleanly no-ops when the Enclave is unavailable, which is the case
    /// on the CI/macOS test host). unwrap() of a non-SE blob returns nil so the caller treats it raw.
    func testSecureEnclaveWrapRoundTripsOrNoOps() throws {
        let secret = try HopKeychain.randomBytes(32)
        if let wrapped = try SecureEnclaveWrap.wrap(secret) {
            XCTAssertNotEqual(wrapped, secret, "a wrap must not be the plaintext")
            XCTAssertEqual(try SecureEnclaveWrap.unwrap(wrapped), secret, "unwrap recovers the secret")
        } else {
            XCTAssertFalse(SecureEnclaveWrap.available, "wrap only returns nil when no Enclave is present")
        }
        XCTAssertFalse(SecureEnclaveWrap.isWrapped(secret), "raw bytes are not an SE-wrapped blob")
    }

    private final class FakeState {
        var read: HopKeychain.ItemRead = .missing
        var adds = 0
    }

    private func operations(_ state: FakeState,
                            random: Data = Data(repeating: 0x42, count: 32),
                            unwrap: @escaping (Data) throws -> Data = { $0 }) -> HopKeychain.Operations {
        HopKeychain.Operations(
            read: { _ in state.read },
            add: { _, data in state.adds += 1; state.read = .value(data); return errSecSuccess },
            random: { _ in random },
            isWrapped: { $0.starts(with: Data("wrapped".utf8)) },
            wrap: { $0 },
            unwrap: unwrap
        )
    }

    func testOnlyItemNotFoundCreatesASecret() throws {
        let missing = FakeState()
        _ = try HopKeychain.resolve(account: "missing", operations: operations(missing))
        XCTAssertEqual(missing.adds, 1)

        let failed = FakeState()
        failed.read = .failure(errSecAuthFailed)
        XCTAssertThrowsError(try HopKeychain.resolve(account: "failed", operations: operations(failed))) { error in
            XCTAssertEqual(error as? HopKeychainError,
                           .status(operation: "SecItemCopyMatching", code: errSecAuthFailed))
        }
        XCTAssertEqual(failed.adds, 0)
    }

    func testMalformedLengthAndUnwrapFailureStopWithoutReplacement() {
        let malformed = FakeState()
        malformed.read = .value(Data(repeating: 1, count: 31))
        XCTAssertThrowsError(try HopKeychain.resolve(account: "short", operations: operations(malformed))) { error in
            XCTAssertEqual(error as? HopKeychainError, .invalidLength(31))
        }
        XCTAssertEqual(malformed.adds, 0)

        let wrapped = FakeState()
        wrapped.read = .value(Data("wrapped-bad-ciphertext".utf8))
        XCTAssertThrowsError(try HopKeychain.resolve(
            account: "unwrap",
            operations: operations(wrapped, unwrap: { _ in throw HopKeychainError.unwrapFailed })
        )) { error in
            XCTAssertEqual(error as? HopKeychainError, .unwrapFailed)
        }
        XCTAssertEqual(wrapped.adds, 0)
    }

    func testFailedWriteOrVerificationNeverReturnsEphemeralIdentity() {
        let writeFailure = FakeState()
        var ops = operations(writeFailure)
        ops.add = { _, _ in errSecDiskFull }
        XCTAssertThrowsError(try HopKeychain.resolve(account: "full", operations: ops))

        let verificationFailure = FakeState()
        var verifyOps = operations(verificationFailure)
        verifyOps.add = { _, _ in
            verificationFailure.read = .value(Data(repeating: 9, count: 32))
            return errSecSuccess
        }
        XCTAssertThrowsError(try HopKeychain.resolve(account: "verify", operations: verifyOps)) { error in
            XCTAssertEqual(error as? HopKeychainError, .verificationFailed)
        }
    }
}
