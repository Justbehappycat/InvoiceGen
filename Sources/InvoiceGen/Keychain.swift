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
        case publishToken = "publish-token"
    }

    /// The bearer token for the publishing endpoint. Not part of the payment
    /// vault: it protects a web endpoint, not the payment details, and mixing
    /// the two would mean a vault problem took publishing down with it.
    static func publishToken() -> String? {
        guard let data = read(.publishToken), let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    @discardableResult
    static func setPublishToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { delete(.publishToken); return true }
        delete(.publishToken)          // replace, don't merge
        return write(.publishToken, Data(trimmed.utf8))
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

        // Deliberately add-if-absent for the key: an update would overwrite
        // whatever is already there, and the thing already there may be the
        // only copy of the key that opens an existing vault. Replacing a key
        // is `deleteKey()` followed by a write, which only the explicit repair
        // path does.
        if item == .vaultKey, read(.vaultKey) != nil { return false }

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

    /// The key that seals the payment vault. Read only — this never mints one.
    ///
    /// It used to: if the Keychain read failed, it generated a fresh key and
    /// stored it. That is the most destructive thing this file could do. A
    /// read can fail for reasons that have nothing to do with the key being
    /// absent — most often a rebuilt binary whose signature no longer matches
    /// the item's ACL — and minting a replacement in that moment orphans a
    /// vault that was perfectly fine, permanently. Returning nil instead
    /// yields "key unavailable", which is recoverable: nothing is destroyed
    /// and the next run under the right identity opens the vault again.
    static func vaultKey() -> SymmetricKey? {
        if let existing = read(.vaultKey), existing.count == 32 {
            keySource = .keychain
            return SymmetricKey(data: existing)
        }
        if let existing = readFallback(.vaultKey), existing.count == 32 {
            keySource = .protectedFile
            return SymmetricKey(data: existing)
        }
        return nil
    }

    /// Whether this Mac already holds a vault key at all — the question
    /// `vaultKey()` used to answer by creating one.
    static func hasVaultKey() -> Bool { vaultKey() != nil }

    /// Creates the key, and only for a Mac that doesn't have one. Callers must
    /// establish that there is no vault to orphan before asking.
    static func createVaultKey() -> SymmetricKey? {
        if let existing = vaultKey() { return existing }
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
