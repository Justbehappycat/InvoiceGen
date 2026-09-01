import Foundation
import CryptoKit

/// Payment details are the one part of an invoice worth attacking: change a
/// routing number and the money goes elsewhere. So they never touch data.json.
/// They live in `vault.dat`, sealed with AES-GCM under a key held in the login
/// Keychain, and a fingerprint of the plaintext is kept in the Keychain too.
///
/// - Editing the ciphertext breaks the GCM tag → detected.
/// - Swapping in an older, genuine vault file → fingerprint mismatch → detected.
/// - Deleting the vault → detected (fingerprint exists, contents don't).
///
/// In every one of those cases the app refuses to put payment details on an
/// invoice and says so, rather than quietly printing someone else's account.
struct VaultContents: Codable, Equatable {
    var businessMethods: [PaymentMethod] = []
    var invoiceMethods: [String: [PaymentMethod]] = [:]
    var templateMethods: [String: [PaymentMethod]] = [:]
    var changeLog: [VaultChange] = []
    /// The verification passphrase: a secret, so it sits beside the payment
    /// details rather than in data.json.
    var verificationPassphrase: String = ""

    var isEmpty: Bool {
        businessMethods.isEmpty && invoiceMethods.isEmpty && templateMethods.isEmpty
            && verificationPassphrase.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case businessMethods, invoiceMethods, templateMethods, changeLog, verificationPassphrase
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        businessMethods = try c.decodeIfPresent([PaymentMethod].self, forKey: .businessMethods) ?? []
        invoiceMethods = try c.decodeIfPresent([String: [PaymentMethod]].self, forKey: .invoiceMethods) ?? [:]
        templateMethods = try c.decodeIfPresent([String: [PaymentMethod]].self, forKey: .templateMethods) ?? [:]
        changeLog = try c.decodeIfPresent([VaultChange].self, forKey: .changeLog) ?? []
        verificationPassphrase = try c.decodeIfPresent(String.self, forKey: .verificationPassphrase) ?? ""
    }
}

struct VaultChange: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var date: Date = Date()
    var summary: String = ""
}

enum VaultStatus: Equatable {
    /// Decrypted and verified.
    case verified
    /// No vault yet — nothing has been saved.
    case empty
    /// Ciphertext or fingerprint did not check out.
    case tampered(String)
    /// The Keychain key is unavailable (denied, or a different login).
    case keyUnavailable

    var isTrouble: Bool {
        switch self {
        case .verified, .empty: return false
        case .tampered, .keyUnavailable: return true
        }
    }

    var message: String {
        switch self {
        case .verified: return "Payment details are encrypted and verified."
        case .empty: return "No payment details saved yet."
        case .tampered(let detail): return detail
        case .keyUnavailable:
            return "The encryption key in your Keychain isn't available, so payment details can't be read."
        }
    }
}

final class PaymentVault {
    static let shared = PaymentVault()

    private(set) var status: VaultStatus = .empty
    private var lastSaved: VaultContents?

    private var fileURL: URL {
        AppStore.defaultFileURL().deletingLastPathComponent().appendingPathComponent("vault.dat")
    }

    // MARK: - Load

    func load() -> VaultContents {
        guard let key = Keychain.vaultKey() else {
            status = .keyUnavailable
            return VaultContents()
        }

        let storedFingerprint = Keychain.readFingerprint()
        guard let sealed = try? Data(contentsOf: fileURL) else {
            if storedFingerprint != nil {
                status = .tampered("The encrypted payment file is missing, but this Mac has a record of it.")
            } else {
                status = .empty
            }
            return VaultContents()
        }

        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let plaintext = try? AES.GCM.open(box, using: key) else {
            status = .tampered("The encrypted payment file failed its integrity check — it was modified or corrupted.")
            return VaultContents()
        }

        let fingerprint = Data(SHA256.hash(data: plaintext))
        if let storedFingerprint, storedFingerprint != fingerprint {
            status = .tampered("The payment file doesn't match this Mac's record — an older or substituted copy was put in its place.")
            return VaultContents()
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let contents = try? decoder.decode(VaultContents.self, from: plaintext) else {
            status = .tampered("The payment file could not be read.")
            return VaultContents()
        }

        if storedFingerprint == nil { Keychain.writeFingerprint(fingerprint) }
        status = .verified
        lastSaved = contents
        return contents
    }

    // MARK: - Save

    @discardableResult
    func save(_ contents: VaultContents) -> Bool {
        guard let key = Keychain.vaultKey() else {
            status = .keyUnavailable
            return false
        }
        // Never overwrite a vault we could not verify: that would destroy the
        // evidence and hand the attacker a clean slate.
        if status.isTrouble, case .keyUnavailable = status {} else if status.isTrouble {
            return false
        }

        var contents = contents
        contents.changeLog = updatedChangeLog(for: contents)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let plaintext = try? encoder.encode(contents),
              let sealed = try? AES.GCM.seal(plaintext, using: key).combined else { return false }

        do {
            try sealed.write(to: fileURL, options: [.atomic, .completeFileProtection])
            var attributes = [FileAttributeKey: Any]()
            attributes[.posixPermissions] = 0o600
            try? FileManager.default.setAttributes(attributes, ofItemAtPath: fileURL.path)
        } catch {
            return false
        }

        Keychain.writeFingerprint(Data(SHA256.hash(data: plaintext)))
        lastSaved = contents
        status = .verified
        return true
    }

    /// Appends an audit entry when the payment details actually changed, so an
    /// unexpected edit is visible in Settings after the fact.
    private func updatedChangeLog(for contents: VaultContents) -> [VaultChange] {
        var log = lastSaved?.changeLog ?? contents.changeLog
        let previous = lastSaved
        let changed = previous == nil
            || previous!.businessMethods != contents.businessMethods
            || previous!.invoiceMethods != contents.invoiceMethods
            || previous!.templateMethods != contents.templateMethods
        guard changed else { return log }

        let summary = previous == nil
            ? "Payment details first stored"
            : describeChange(from: previous!, to: contents)

        // Collapse a burst of edits into the entry already at the top.
        if let last = log.last, last.summary == summary, Date().timeIntervalSince(last.date) < 120 {
            log[log.count - 1].date = Date()
        } else {
            log.append(VaultChange(summary: summary))
        }
        if log.count > 50 { log.removeFirst(log.count - 50) }
        return log
    }

    private func describeChange(from old: VaultContents, to new: VaultContents) -> String {
        if old.businessMethods != new.businessMethods {
            let oldNames = old.businessMethods.map(\.displayTitle)
            let newNames = new.businessMethods.map(\.displayTitle)
            if oldNames != newNames {
                return "Default payment methods changed: \(newNames.joined(separator: ", "))"
            }
            return "Default payment details edited"
        }
        if old.invoiceMethods != new.invoiceMethods { return "Payment details on an invoice edited" }
        return "Payment templates edited"
    }

    // MARK: - Recovery

    /// Accepts the on-disk vault as the new truth. Only ever called from an
    /// explicit user action after a tamper warning.
    func acceptCurrentFile() {
        Keychain.deleteFingerprint()
        status = .empty
        lastSaved = nil
    }

    /// Throws the vault away and starts over — used when the warning is real.
    func reset() {
        try? FileManager.default.removeItem(at: fileURL)
        Keychain.deleteFingerprint()
        status = .empty
        lastSaved = nil
    }

    var vaultURL: URL { fileURL }

    /// The audit trail as of the last load or save — no decryption needed.
    var currentChangeLog: [VaultChange] { lastSaved?.changeLog ?? [] }
}
