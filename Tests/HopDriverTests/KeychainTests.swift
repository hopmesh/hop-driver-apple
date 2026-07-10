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

    func testSecretIsStableAcrossCallsAnd32Bytes() {
        let acct = freshAccount()
        let first = HopKeychain.secret(account: acct)
        XCTAssertEqual(first.bytes.count, 32)
        XCTAssertEqual(first.origin, .created, "first read for a new account generates + stores it")

        let second = HopKeychain.secret(account: acct)
        XCTAssertEqual(second.bytes, first.bytes, "the same account returns the identical secret")
        XCTAssertEqual(second.origin, .loaded, "the second read is a keychain load, not a regenerate")
    }

    func testDistinctAccountsGetDistinctSecrets() {
        let a = HopKeychain.secret(account: freshAccount()).bytes
        let b = HopKeychain.secret(account: freshAccount()).bytes
        XCTAssertNotEqual(a, b, "identity and db-key secrets must be independent")
    }

    func testSecretIsHighEntropyNotADeviceDerivation() {
        // A SHA-256(vendorId) would be deterministic and identical for two fresh accounts on the same
        // device basis; a real CSPRNG secret differs, and is not all-zero / low-entropy.
        let s = HopKeychain.secret(account: freshAccount()).bytes
        XCTAssertNotEqual(s, Data(repeating: 0, count: 32))
        XCTAssertGreaterThan(Set(s).count, 8, "32 random bytes should have many distinct byte values")
    }

    func testRandomBytesAreUnique() {
        let a = HopKeychain.randomBytes(32)
        let b = HopKeychain.randomBytes(32)
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
    }

    /// The SE-wrap round-trips (or cleanly no-ops when the Enclave is unavailable, which is the case
    /// on the CI/macOS test host). unwrap() of a non-SE blob returns nil so the caller treats it raw.
    func testSecureEnclaveWrapRoundTripsOrNoOps() {
        let secret = HopKeychain.randomBytes(32)
        if let wrapped = SecureEnclaveWrap.wrap(secret) {
            XCTAssertNotEqual(wrapped, secret, "a wrap must not be the plaintext")
            XCTAssertEqual(SecureEnclaveWrap.unwrap(wrapped), secret, "unwrap recovers the secret")
        } else {
            XCTAssertFalse(SecureEnclaveWrap.available, "wrap only returns nil when no Enclave is present")
        }
        // A raw (non-SE) blob is not mistaken for a wrapped one.
        XCTAssertNil(SecureEnclaveWrap.unwrap(secret), "raw bytes are not an SE-wrapped blob")
    }
}
