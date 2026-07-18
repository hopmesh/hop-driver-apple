import Foundation
import Security
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum HopKeychainError: Error, Equatable {
    case itemNotFound
    case status(operation: String, code: OSStatus)
    case invalidItem
    case invalidLength(Int)
    case unwrapFailed
    case randomFailure(OSStatus)
    case verificationFailed
}

public enum HopKeychain {
    static let service = "sh.hop.identity"
    static let identityAccount = "device-seed.v2"
    static let dbKeyAccount = "db-key.v2"

    public enum Origin: String {
        case loaded = "keychain-loaded"
        case created = "keychain-created"
    }

    public struct Resolved {
        public let bytes: Data
        public let origin: Origin
    }

    enum ItemRead {
        case missing
        case value(Data)
        case failure(OSStatus)
    }

    struct Operations {
        var read: (String) -> ItemRead
        var add: (String, Data) -> OSStatus
        var random: (Int) throws -> Data
        var isWrapped: (Data) -> Bool
        var wrap: (Data) throws -> Data
        var unwrap: (Data) throws -> Data
    }

    /// Only an explicit `errSecItemNotFound` creates. Every other read, decode, unwrap, or length error
    /// propagates so startup cannot silently replace the user's identity.
    public static func secret(account: String) throws -> Resolved {
        try resolve(account: account, operations: productionOperations)
    }

    static func resolve(account: String, operations: Operations) throws -> Resolved {
        switch operations.read(account) {
        case .value(let stored):
            return Resolved(bytes: try decode(stored, operations: operations), origin: .loaded)
        case .failure(let status):
            throw HopKeychainError.status(operation: "SecItemCopyMatching", code: status)
        case .missing:
            let fresh = try operations.random(32)
            guard fresh.count == 32 else { throw HopKeychainError.invalidLength(fresh.count) }
            let stored = try operations.wrap(fresh)
            let status = operations.add(account, stored)
            if status == errSecDuplicateItem {
                guard case .value(let raced) = operations.read(account) else {
                    throw HopKeychainError.status(operation: "SecItemAdd duplicate reload", code: status)
                }
                return Resolved(bytes: try decode(raced, operations: operations), origin: .loaded)
            }
            guard status == errSecSuccess else {
                throw HopKeychainError.status(operation: "SecItemAdd", code: status)
            }
            guard case .value(let committed) = operations.read(account),
                  try decode(committed, operations: operations) == fresh else {
                throw HopKeychainError.verificationFailed
            }
            return Resolved(bytes: fresh, origin: .created)
        }
    }

    private static func decode(_ stored: Data, operations: Operations) throws -> Data {
        let secret = operations.isWrapped(stored) ? try operations.unwrap(stored) : stored
        guard secret.count == 32 else { throw HopKeychainError.invalidLength(secret.count) }
        return secret
    }

    private static var productionOperations: Operations {
        Operations(
            read: readItem,
            add: addItem,
            random: randomBytes,
            isWrapped: SecureEnclaveWrap.isWrapped,
            wrap: { secret in try SecureEnclaveWrap.wrap(secret) ?? secret },
            unwrap: SecureEnclaveWrap.unwrap,
        )
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func readItem(account: String) -> ItemRead {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var output: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &output)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { return .failure(status) }
        guard let data = output as? Data else { return .failure(errSecDecode) }
        return .value(data)
    }

    private static func addItem(account: String, data: Data) -> OSStatus {
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrSynchronizable as String] = false
        return SecItemAdd(query as CFDictionary, nil)
    }

    static func randomBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw HopKeychainError.randomFailure(status) }
        return data
    }
}

enum SecureEnclaveWrap {
    private static let magic = Data("HOPSE1".utf8)
    private static let keyAccount = "se-wrap-key.v2"

    static var available: Bool {
        #if canImport(CryptoKit)
        return SecureEnclave.isAvailable
        #else
        return false
        #endif
    }

    static func isWrapped(_ blob: Data) -> Bool {
        blob.count > magic.count + 1 && blob.prefix(magic.count) == magic
    }

    /// Nil means the platform has no Secure Enclave. A present Enclave failing to wrap is an error.
    static func wrap(_ secret: Data) throws -> Data? {
        #if canImport(CryptoKit)
        guard available else { return nil }
        do {
            let secureKey = try loadOrCreateKey()
            let ephemeral = P256.KeyAgreement.PrivateKey()
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: secureKey.publicKey)
            let symmetric = shared.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: Data("hop.se.wrap".utf8),
                sharedInfo: Data(),
                outputByteCount: 32
            )
            let sealed = try AES.GCM.seal(secret, using: symmetric)
            guard let combined = sealed.combined else { throw HopKeychainError.unwrapFailed }
            let publicKey = ephemeral.publicKey.x963Representation
            guard publicKey.count <= Int(UInt8.max) else { throw HopKeychainError.invalidItem }
            var output = magic
            output.append(UInt8(publicKey.count))
            output.append(publicKey)
            output.append(combined)
            return output
        } catch let error as HopKeychainError {
            throw error
        } catch {
            throw HopKeychainError.unwrapFailed
        }
        #else
        return nil
        #endif
    }

    static func unwrap(_ blob: Data) throws -> Data {
        #if canImport(CryptoKit)
        guard isWrapped(blob) else { throw HopKeychainError.invalidItem }
        do {
            let secureKey = try loadKey()
            var index = blob.index(blob.startIndex, offsetBy: magic.count)
            let publicLength = Int(blob[index])
            index = blob.index(after: index)
            guard blob.distance(from: index, to: blob.endIndex) > publicLength else {
                throw HopKeychainError.invalidItem
            }
            let publicEnd = blob.index(index, offsetBy: publicLength)
            let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: Data(blob[index..<publicEnd]))
            let shared = try secureKey.sharedSecretFromKeyAgreement(with: ephemeral)
            let symmetric = shared.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: Data("hop.se.wrap".utf8),
                sharedInfo: Data(),
                outputByteCount: 32
            )
            let box = try AES.GCM.SealedBox(combined: Data(blob[publicEnd...]))
            return try AES.GCM.open(box, using: symmetric)
        } catch let error as HopKeychainError {
            throw error
        } catch {
            throw HopKeychainError.unwrapFailed
        }
        #else
        throw HopKeychainError.unwrapFailed
        #endif
    }

    #if canImport(CryptoKit)
    private static func keyQuery(returnData: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: HopKeychain.service,
            kSecAttrAccount as String: keyAccount,
        ]
        if returnData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }

    private static func loadKey() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        var output: CFTypeRef?
        let status = SecItemCopyMatching(keyQuery(returnData: true) as CFDictionary, &output)
        if status == errSecItemNotFound { throw HopKeychainError.itemNotFound }
        guard status == errSecSuccess else {
            throw HopKeychainError.status(operation: "SecItemCopyMatching SE key", code: status)
        }
        guard let representation = output as? Data else { throw HopKeychainError.invalidItem }
        do {
            return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: representation)
        } catch {
            throw HopKeychainError.unwrapFailed
        }
    }

    private static func loadOrCreateKey() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        do {
            return try loadKey()
        } catch HopKeychainError.itemNotFound {
            let key: SecureEnclave.P256.KeyAgreement.PrivateKey
            do { key = try SecureEnclave.P256.KeyAgreement.PrivateKey() }
            catch { throw HopKeychainError.unwrapFailed }
            var add = keyQuery(returnData: false)
            add[kSecValueData as String] = key.dataRepresentation
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrSynchronizable as String] = false
            let status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecDuplicateItem { return try loadKey() }
            guard status == errSecSuccess else {
                throw HopKeychainError.status(operation: "SecItemAdd SE key", code: status)
            }
            let committed = try loadKey()
            guard committed.dataRepresentation == key.dataRepresentation else {
                throw HopKeychainError.verificationFailed
            }
            return committed
        }
    }
    #endif
}
