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
    private static var columnCache: [String: [Bool]] = [:]

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

    static func cachedBarcode(for code: String, ink: NSColor = inkColor, scale: CGFloat = 12) -> NSImage? {
        let id = "\(code)|\(ink.description)|\(scale)"
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = imageCache[id] { return cached }
        guard let image = barcodeImage(for: code, ink: ink, scale: scale) else { return nil }
        if imageCache.count > 40 { imageCache.removeAll() }
        imageCache[id] = image
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

    /// Local time zone, deliberately: the signature has to cover the date the
    /// invoice *prints*, and that's the sender's calendar day. Formatting an
    /// evening timestamp in UTC would sign the following day and every PDF
    /// check would come back a false mismatch.
    private static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
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
        code(number: invoice.number, date: invoice.issueDate,
             quantity: totalQuantity(of: invoice), total: invoice.total, key: key)
    }

    /// The same signature, from loose fields — this is what lets a PDF be
    /// checked against its own printed numbers rather than against our copy.
    static func code(number: String, date: Date, quantity: Decimal,
                     total: Decimal, key: SymmetricKey) -> String {
        let payload = [prefix, number, isoDate(date),
                       decimalString(quantity), decimalString(total)].joined(separator: "|")
        let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
        let signature = Data(mac).prefix(4).map { String(format: "%02X", $0) }.joined()
        return "\(prefix)-\(number)-\(signature)"
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
    ///
    /// The bars are drawn in `ink` with the spaces left *transparent*, so the
    /// invoice's own field shows through as the light half of the symbol and
    /// the code reads as part of the design rather than a sticker on top of it.
    static func barcodeImage(for code: String, ink: NSColor = inkColor, scale: CGFloat = 12) -> NSImage? {
        let generator = CIFilter.code128BarcodeGenerator()
        generator.message = Data(code.utf8)
        generator.quietSpace = 8
        guard let generated = generator.outputImage else { return nil }

        // Bars → opaque, spaces → transparent.
        let invert = CIFilter.colorInvert()
        invert.inputImage = generated
        let toAlpha = CIFilter.maskToAlpha()
        toAlpha.inputImage = invert.outputImage
        guard let alpha = toAlpha.outputImage else { return nil }

        let rgb = ink.usingColorSpace(.sRGB) ?? .black
        let flat = CIImage(color: CIColor(red: rgb.redComponent,
                                          green: rgb.greenComponent,
                                          blue: rgb.blueComponent)).cropped(to: alpha.extent)
        let blend = CIFilter.blendWithAlphaMask()
        blend.inputImage = flat
        blend.backgroundImage = CIImage.empty().cropped(to: alpha.extent)
        blend.maskImage = alpha
        guard let output = blend.outputImage else { return nil }

        let rep = NSCIImageRep(ciImage: output.transformed(by: CGAffineTransform(scaleX: scale, y: scale)))
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    /// The symbol as one bool per module column, true = bar. Used by the
    /// drawn mark, which needs the pattern itself rather than an image of it.
    static func moduleColumns(for code: String) -> [Bool] {
        cacheLock.lock()
        if let cached = columnCache[code] { cacheLock.unlock(); return cached }
        cacheLock.unlock()

        let generator = CIFilter.code128BarcodeGenerator()
        generator.message = Data(code.utf8)
        generator.quietSpace = 8
        guard let image = generator.outputImage,
              let cg = CIContext().createCGImage(image, from: image.extent)
        else { return [] }
        let rep = NSBitmapImageRep(cgImage: cg)
        let row = rep.pixelsHigh / 2
        let columns = (0..<rep.pixelsWide).map { x in
            (rep.colorAt(x: x, y: row)?.brightnessComponent ?? 1) < 0.5
        }
        cacheLock.lock()
        if columnCache.count > 40 { columnCache.removeAll() }
        columnCache[code] = columns
        cacheLock.unlock()
        return columns
    }

    // MARK: - Print contrast
    //
    // Whether bars can sit straight on a coloured field is a print question,
    // not a "does Vision decode my anti-aliased PNG" question — Vision will
    // happily read black bars on a near-black field that no laser scanner
    // could. So the guard uses print contrast signal (PCS), the measure the
    // barcode standards actually use: (light − dark) / light, on reflectance.

    /// Near-black, a touch softer than pure ink so it sits in a greyscale design.
    static let inkColor = NSColor(calibratedWhite: 0.06, alpha: 1)
    private static let inkReflectance: Double = 0.06

    /// ISO 15416 grade C and better starts around 0.70; anything under that is
    /// a barcode that scans on a good day and fails in a warehouse.
    static let minimumContrast: Double = 0.70
    /// What a lightened band aims for — comfortably inside grade A.
    private static let targetContrast: Double = 0.85

    /// Perceived reflectance of a colour, 0…1 (luma — the eye's, and a
    /// scanner's, weighting of the channels).
    static func reflectance(of color: NSColor) -> Double {
        let rgb = color.usingColorSpace(.sRGB) ?? .white
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
    }

    static func printContrast(onField color: NSColor) -> Double {
        printContrast(bars: inkColor, onField: color)
    }

    /// PCS for an arbitrary pair — the strip is not always drawn in ink.
    static func printContrast(bars: NSColor, onField color: NSColor) -> Double {
        let light = reflectance(of: color)
        let dark = reflectance(of: bars)
        guard light > 0, light > dark else { return 0 }
        return (light - dark) / light
    }

    /// Nil when the field is light enough to take bars directly. Otherwise the
    /// colour of the band to lay behind them — the same hue, lifted toward
    /// paper until the contrast is safe, so it still reads as the design.
    static func guardBand(forField color: NSColor) -> NSColor? {
        guard printContrast(onField: color) < minimumContrast else { return nil }
        let needed = inkReflectance / (1 - targetContrast)          // reflectance to reach the target
        let field = color.usingColorSpace(.sRGB) ?? .white
        let current = reflectance(of: field)
        guard current < needed else { return nil }
        // Blend toward white by the fraction that lifts reflectance to `needed`.
        let t = min(1.0, max(0.0, (needed - current) / max(0.0001, 1 - current)))
        return NSColor(
            srgbRed: field.redComponent + (1 - field.redComponent) * t,
            green: field.greenComponent + (1 - field.greenComponent) * t,
            blue: field.blueComponent + (1 - field.blueComponent) * t,
            alpha: 1
        )
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
