import Foundation
import Security
import CryptoKit

/// Keychain-backed secrets. The vault key never leaves the login keychain, and
/// the integrity fingerprint lives there too — a process that can write your
/// files still cannot rewrite the Keychain without your login.
enum Keychain {
    private static let service = "com.finecut.invoicegen"

    enum Item: String {
        case vaultKey = "payment-vault-key"
        case vaultFingerprint = "payment-vault-fingerprint"
    }

    static func read(_ item: Item) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    static func write(_ item: Item, _ value: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = value
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    static func delete(_ item: Item) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Where the vault key actually ended up.
    enum KeySource: Equatable {
        case keychain
        /// The login Keychain refused us — happens when the app is re-signed,
        /// since Keychain ACLs are tied to the signing identity. A 0600 key file
        /// beside the data keeps the vault working; it is weaker (anything
        /// running as you can read it) and the UI says so.
        case protectedFile
    }

    private(set) static var keySource: KeySource = .keychain

    private static var fallbackDirectory: URL {
        AppStore.defaultFileURL().deletingLastPathComponent()
    }

    private static func fallbackURL(_ item: Item) -> URL {
        fallbackDirectory.appendingPathComponent(".\(item.rawValue)")
    }

    private static func readFallback(_ item: Item) -> Data? {
        try? Data(contentsOf: fallbackURL(item))
    }

    @discardableResult
    private static func writeFallback(_ item: Item, _ value: Data) -> Bool {
        let url = fallbackURL(item)
        guard (try? value.write(to: url, options: .atomic)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    /// The symmetric key used to seal the payment vault, created on first use.
    static func vaultKey() -> SymmetricKey? {
        if let existing = read(.vaultKey), existing.count == 32 {
            keySource = .keychain
            return SymmetricKey(data: existing)
        }
        if let existing = readFallback(.vaultKey), existing.count == 32 {
            keySource = .protectedFile
            return SymmetricKey(data: existing)
        }

        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        if write(.vaultKey, raw) {
            keySource = .keychain
            return key
        }
        guard writeFallback(.vaultKey, raw) else { return nil }
        keySource = .protectedFile
        return key
    }

    /// Fingerprint storage follows wherever the key lives.
    static func readFingerprint() -> Data? {
        keySource == .keychain ? read(.vaultFingerprint) : readFallback(.vaultFingerprint)
    }

    static func writeFingerprint(_ value: Data) {
        if keySource == .keychain {
            write(.vaultFingerprint, value)
        } else {
            writeFallback(.vaultFingerprint, value)
        }
    }

    static func deleteFingerprint() {
        delete(.vaultFingerprint)
        try? FileManager.default.removeItem(at: fallbackURL(.vaultFingerprint))
    }

    static func deleteKey() {
        delete(.vaultKey)
        try? FileManager.default.removeItem(at: fallbackURL(.vaultKey))
    }
}
