import Foundation
import CommonCrypto
import CryptoKit
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// A short signature printed on the invoice — as a Code 128 barcode and as
/// human-readable text — that proves the sheet in someone's hand matches the
/// invoice in the app.
///
/// The signature covers exactly the fields you asked for: invoice number, date,
/// total quantity, total amount. Change any of them and the code stops
/// verifying. The key comes from your passphrase, so nobody can forge a code
/// without it, and anyone with the passphrase can verify an invoice on another
/// Mac.
enum Verification {
    static let prefix = "IG1"

    // MARK: - Key

    /// PBKDF2-HMAC-SHA256. The iteration count is deliberately slow: the
    /// passphrase is the only secret, so guessing it must be expensive.
    static let iterations: UInt32 = 200_000

    static func deriveKey(passphrase: String, salt: Data) -> SymmetricKey? {
        let passwordBytes = Array(passphrase.utf8).map { Int8(bitPattern: $0) }
        guard !passwordBytes.isEmpty, !salt.isEmpty else { return nil }
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBuffer -> Int32 in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes, passwordBytes.count,
                saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                iterations,
                &derived, derived.count
            )
        }
        guard status == kCCSuccess else { return nil }
        return SymmetricKey(data: Data(derived))
    }

    /// Deriving costs 200k PBKDF2 rounds, and the printed sheet re-renders on
    /// every keystroke — so both the key and the rendered bars are memoised.
    private static let cacheLock = NSLock()
    private static var keyCache: [String: SymmetricKey] = [:]
    private static var imageCache: [String: NSImage] = [:]

    static func cachedKey(passphrase: String, salt: Data) -> SymmetricKey? {
        guard !passphrase.isEmpty, !salt.isEmpty else { return nil }
        let id = "\(passphrase.hashValue)-\(salt.base64EncodedString())"
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = keyCache[id] { return cached }
        guard let key = deriveKey(passphrase: passphrase, salt: salt) else { return nil }
        if keyCache.count > 8 { keyCache.removeAll() }
        keyCache[id] = key
        return key
    }

    static func cachedBarcode(for code: String, scale: CGFloat = 12) -> NSImage? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = imageCache[code] { return cached }
        guard let image = barcodeImage(for: code, scale: scale) else { return nil }
        if imageCache.count > 40 { imageCache.removeAll() }
        imageCache[code] = image
        return image
    }

    static func newSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    // MARK: - Payload

    /// The exact bytes that get signed. Locale-independent on purpose: the same
    /// invoice must produce the same code on any Mac, in any region.
    static func payload(for invoice: Invoice) -> String {
        [
            prefix,
            invoice.number,
            isoDate(invoice.issueDate),
            decimalString(totalQuantity(of: invoice)),
            decimalString(invoice.total),
        ].joined(separator: "|")
    }

    static func totalQuantity(of invoice: Invoice) -> Decimal {
        invoice.items.reduce(Decimal(0)) { $0 + $1.quantity }
    }

    private static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func isoDate(_ date: Date) -> String { isoFormatter.string(from: date) }

    /// Two decimal places, always, with a dot — never a comma, never a group
    /// separator, whatever the Mac's region is set to.
    static func decimalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value.rounded(2))
            .description(withLocale: Locale(identifier: "en_US_POSIX"))
            .appendingTwoDecimalsIfNeeded()
    }

    // MARK: - Code

    /// `IG1-11-4A7C9E2B` — prefix, invoice number, eight hex digits of HMAC.
    static func code(for invoice: Invoice, key: SymmetricKey) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(payload(for: invoice).utf8), using: key)
        let signature = Data(mac).prefix(4).map { String(format: "%02X", $0) }.joined()
        return "\(prefix)-\(invoice.number)-\(signature)"
    }

    enum Result: Equatable {
        case valid(invoiceID: UUID, number: String)
        /// The code is well-formed but doesn't match the invoice we hold.
        case mismatch(number: String)
        case unknownInvoice(number: String)
        case malformed
        case noPassphrase

        var isValid: Bool { if case .valid = self { return true } else { return false } }
    }

    /// Checks a scanned or typed code against the invoices in `data`.
    static func verify(_ scanned: String, in data: AppData, key: SymmetricKey?) -> Result {
        guard let key else { return .noPassphrase }
        let trimmed = scanned.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        // Invoice numbers may themselves contain dashes, so only the first and
        // last components are fixed.
        guard parts.count >= 3, parts[0] == prefix else { return .malformed }
        let signature = String(parts[parts.count - 1])
        let number = parts[1..<(parts.count - 1)].joined(separator: "-")
        guard signature.count == 8, signature.allSatisfy(\.isHexDigit) else { return .malformed }

        guard let invoice = data.invoices.first(where: { $0.number.uppercased() == number }) else {
            return .unknownInvoice(number: number)
        }
        let expected = code(for: invoice, key: key).split(separator: "-").last.map(String.init) ?? ""
        // Constant-time-ish compare; the signature is public anyway, but the
        // habit costs nothing.
        let match = expected.count == signature.count
            && zip(expected.utf8, signature.utf8).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
        return match ? .valid(invoiceID: invoice.id, number: invoice.number) : .mismatch(number: number)
    }

    // MARK: - Barcode

    /// Code 128 via CoreImage — the system encoder, so the symbology, check
    /// digit and quiet zone are correct by construction rather than by my
    /// transcription of a pattern table.
    static func barcodeImage(for code: String, scale: CGFloat = 12) -> NSImage? {
        let filter = CIFilter.code128BarcodeGenerator()
        filter.message = Data(code.utf8)
        filter.quietSpace = 6
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

private extension String {
    /// NSDecimalNumber prints "400" for 400 and "400.5" for 400.5; the signed
    /// payload needs "400.00" and "400.50" so the same invoice always hashes
    /// the same way.
    func appendingTwoDecimalsIfNeeded() -> String {
        guard let dot = firstIndex(of: ".") else { return self + ".00" }
        let decimals = distance(from: index(after: dot), to: endIndex)
        if decimals == 1 { return self + "0" }
        if decimals == 0 { return self + "00" }
        return self
    }
}
