// Keychain.swift - the device-only secret store behind IdentityStore (sec-priv-02).
//
// The Hop identity seed and the SQLCipher db key used to be SHA-256(identifierForVendor): at most
// ~122 bits of a value that is NOT secret (any on-device code in the app sandbox, a backup, or a
// forensic pull can read the vendor id and re-derive both). For an untraceable-by-default messenger
// the long-term Ed25519 identity must be a real random secret that never leaves the device.
//
// This keeps a random 32-byte secret per (service, account) in the Keychain with
// kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly (survives reboot once unlocked, never leaves the
// device, is excluded from iCloud/iTunes backups by "ThisDeviceOnly"). Where the Secure Enclave is
// present the stored secret is wrapped by an SE-resident P-256 key so the plaintext secret only
// exists transiently in memory after an SE-gated unwrap; without the Enclave the secret is stored
// directly under the same device-only protection.
//
// Migration note: the legacy vendor-id-derived value is deterministic and unrecoverable as a random
// secret, so the FIRST launch after this change generates fresh secrets. That is a ONE-TIME identity
// reset (new address) and a fresh db key (the old encrypted db, if any, is quarantined by the node's
// keyed-open path). Every launch after that is stable from the Keychain with no re-derivation.

import Foundation
import Security
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum HopKeychain {
    /// Where Keychain items live. One service, distinct accounts per secret.
    static let service = "sh.hop.identity"
    static let identityAccount = "device-seed.v2"
    static let dbKeyAccount = "db-key.v2"
    /// Account holding the wrapping material (SE public key + salt) when SE wrapping is in use.

    public enum Origin: String {
        case loaded = "keychain-loaded"     // an existing secret was read back
        case created = "keychain-created"   // a new random secret was generated + stored (one-time)
        case memory = "in-memory (keychain unavailable)"  // could not use the Keychain; ephemeral
    }

    /// Result of resolving a secret: the 32 bytes plus how they were obtained (for the UI `note`).
    public struct Resolved {
        public let bytes: Data
        public let origin: Origin
    }

    // A process-lifetime fallback so a device with no usable Keychain (e.g. a misconfigured test
    // host) still gets a STABLE secret for the run rather than a fresh identity per call.
    private static var memoryFallback: [String: Data] = [:]
    private static let memoryLock = NSLock()

    /// Get the 32-byte secret for `account`, creating + persisting a fresh random one on first use.
    public static func secret(account: String) -> Resolved {
        if let existing = load(account: account) {
            return Resolved(bytes: existing, origin: .loaded)
        }
        let fresh = randomBytes(32)
        if store(fresh, account: account) {
            return Resolved(bytes: fresh, origin: .created)
        }
        // Keychain write failed (rare: locked device before first unlock, entitlement issue). Use a
        // process-stable in-memory value so the node stays coherent for this run.
        memoryLock.lock(); defer { memoryLock.unlock() }
        if let m = memoryFallback[account] { return Resolved(bytes: m, origin: .memory) }
        memoryFallback[account] = fresh
        return Resolved(bytes: fresh, origin: .memory)
    }

    // MARK: - raw Keychain

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func load(account: String) -> Data? {
        var q = baseQuery(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let stored = out as? Data else { return nil }
        // Stored form is either the raw 32-byte secret (no SE) or an SE-wrapped blob. Unwrap first;
        // a 32-byte plaintext round-trips through unwrap unchanged.
        let secret = SecureEnclaveWrap.unwrap(stored) ?? stored
        return secret.count == 32 ? secret : nil
    }

    @discardableResult
    private static func store(_ bytes: Data, account: String) -> Bool {
        // Delete any stale/short item first so an add can't collide.
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        var q = baseQuery(account: account)
        // Where the Secure Enclave is present, persist an SE-wrapped blob so the plaintext secret
        // exists only transiently in memory after an SE-gated unwrap. Otherwise store it directly
        // under the same device-only protection (the Keychain's own keys are SE-protected anyway).
        q[kSecValueData as String] = SecureEnclaveWrap.wrap(bytes) ?? bytes
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    /// 32 CSPRNG bytes (SecRandom, falling back to arc4random only if that ever fails).
    static func randomBytes(_ n: Int) -> Data {
        var d = Data(count: n)
        let rc = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        if rc != errSecSuccess {
            d = Data((0..<n).map { _ in UInt8.random(in: .min ... .max) })
        }
        return d
    }
}

/// Secure-Enclave wrapping for the stored secret (sec-priv-02). When the Enclave is present the
/// secret is sealed under an SE-resident P-256 key so its plaintext lives only briefly in memory
/// after an SE-gated unwrap. The SE key's own (opaque, non-exportable) representation is itself kept
/// in the Keychain. On hardware WITHOUT an Enclave (older sim/macOS), wrap/unwrap are no-ops and the
/// secret is stored directly under the Keychain's device-only protection.
enum SecureEnclaveWrap {
    private static let magic = Data("HOPSE1".utf8)   // marks an SE-wrapped blob
    private static let seKeyService = HopKeychain.service
    private static let seKeyAccount = "se-wrap-key.v2"

    /// True on devices with a usable Secure Enclave.
    static var available: Bool {
        #if canImport(CryptoKit)
        return SecureEnclave.isAvailable
        #else
        return false
        #endif
    }

    /// Wrap `secret` under the SE key (creating the SE key once). Returns nil (caller stores plaintext)
    /// when the Enclave is unavailable or any step fails.
    static func wrap(_ secret: Data) -> Data? {
        #if canImport(CryptoKit)
        guard available, let sePriv = loadOrCreateSEKey() else { return nil }
        do {
            let eph = P256.KeyAgreement.PrivateKey()
            let shared = try eph.sharedSecretFromKeyAgreement(with: sePriv.publicKey)
            let symKey = shared.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: Data("hop.se.wrap".utf8), sharedInfo: Data(), outputByteCount: 32)
            let sealed = try AES.GCM.seal(secret, using: symKey)
            guard let combined = sealed.combined else { return nil }
            let ephPub = eph.publicKey.x963Representation
            var out = magic
            out.append(UInt8(ephPub.count))     // ephemeral pubkey length (x9.63 P-256 = 65)
            out.append(ephPub)
            out.append(combined)                // GCM nonce+ciphertext+tag
            return out
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Reverse of `wrap`. Returns nil when `blob` is not an SE-wrapped blob (caller treats it as raw).
    static func unwrap(_ blob: Data) -> Data? {
        #if canImport(CryptoKit)
        guard blob.count > magic.count + 1, blob.prefix(magic.count) == magic,
              let sePriv = loadOrCreateSEKey(createIfMissing: false) else { return nil }
        var i = blob.index(blob.startIndex, offsetBy: magic.count)
        let ephLen = Int(blob[i]); i = blob.index(after: i)
        guard blob.distance(from: i, to: blob.endIndex) > ephLen else { return nil }
        let ephEnd = blob.index(i, offsetBy: ephLen)
        let ephPub = Data(blob[i..<ephEnd])
        let sealed = Data(blob[ephEnd...])
        do {
            let ephKey = try P256.KeyAgreement.PublicKey(x963Representation: ephPub)
            let shared = try sePriv.sharedSecretFromKeyAgreement(with: ephKey)
            let symKey = shared.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: Data("hop.se.wrap".utf8), sharedInfo: Data(), outputByteCount: 32)
            let box = try AES.GCM.SealedBox(combined: sealed)
            return try AES.GCM.open(box, using: symKey)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    #if canImport(CryptoKit)
    /// The SE-resident P-256 key agreement key, persisted (as its opaque SE representation) in the
    /// Keychain so it survives launches. Created once.
    private static func loadOrCreateSEKey(createIfMissing: Bool = true) -> SecureEnclave.P256.KeyAgreement.PrivateKey? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: seKeyService,
            kSecAttrAccount as String: seKeyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let rep = out as? Data {
            return try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: rep)
        }
        guard createIfMissing, let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey() else { return nil }
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: seKeyService,
            kSecAttrAccount as String: seKeyAccount,
            kSecValueData as String: key.dataRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(add as CFDictionary)
        add[kSecValueData as String] = key.dataRepresentation
        _ = SecItemAdd(add as CFDictionary, nil)
        return key
    }
    #endif
}
