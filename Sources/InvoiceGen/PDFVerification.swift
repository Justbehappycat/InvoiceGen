import Foundation
import PDFKit
import AppKit
import Vision
import CryptoKit

/// Checks a PDF on its own terms.
///
/// The point of reading the page rather than trusting the app's copy: if
/// somebody edits the total on the printed sheet and leaves the barcode alone,
/// a check that only compares the code against our own records still says
/// "genuine". So the signature is recomputed from the numbers the page itself
/// shows — number, date, item count, total — and compared with the code the
/// page carries. Those have to agree, and only then is the app's copy
/// consulted as a second opinion.
struct PDFVerificationReport {
    var fileName: String = ""
    var scannedCode: String?          // decoded from the bars
    var printedCode: String?          // read from the footer line
    var number: String?
    var date: Date?
    var quantity: Decimal?
    var total: Decimal?

    /// The page's own numbers reproduce the code the page carries.
    var pageIsSelfConsistent: Bool?
    /// The app read its own mark off the page: how much of the pattern
    /// matched what the page's own numbers should have produced. A high score
    /// is proof; a low one proves nothing — the sheet may simply carry the
    /// mark in a different style, or none — so it can confirm but never
    /// accuse.
    var stripeAgreement: Double?
    /// Differences against the invoice of the same number held in the app.
    var differencesFromRecord: [String] = []
    var recordFound = false
    var notes: [String] = []

    var verdict: Verdict {
        guard scannedCode != nil || printedCode != nil else { return .noCode }
        guard let pageIsSelfConsistent else { return .unreadable }
        if !pageIsSelfConsistent { return .tampered }
        return differencesFromRecord.isEmpty ? .genuine : .differsFromRecord
    }

    enum Verdict {
        case genuine
        /// The code doesn't match what the page says — the page was altered
        /// after it was signed, or signed with a different passphrase.
        case tampered
        case differsFromRecord
        case noCode
        case unreadable
    }
}

enum PDFVerifier {
    /// How much of the sampled pattern must agree before the reading counts as
    /// confirmation. Rendered pages are exact, so a genuine mark scores 100%;
    /// anything appreciably below that is a different mark or no mark at all.
    static let stripeMatchThreshold = 0.95


    @MainActor
    static func verify(url: URL, store: AppStore) -> PDFVerificationReport {
        verify(url: url, key: store.verificationKey, invoices: store.data.invoices,
               currencyCode: store.data.business.currencyCode)
    }

    static func verify(url: URL, key: SymmetricKey?, invoices: [Invoice],
                       currencyCode: String = "USD") -> PDFVerificationReport {
        var report = PDFVerificationReport()
        report.fileName = url.lastPathComponent

        guard let document = PDFDocument(url: url) else {
            report.notes.append("That file could not be opened as a PDF.")
            return report
        }

        let text = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")

        report.scannedCode = scanBarcode(in: document)
        report.printedCode = printedCode(in: text)
        report.number = value(after: "Invoice Number:", in: text)
        report.date = printedDate(in: text)
        report.quantity = printedQuantity(in: text)
        report.total = printedTotal(in: text)

        if report.scannedCode == nil {
            report.notes.append("No barcode could be read from the page"
                + (report.printedCode != nil ? " — using the printed code instead." : "."))
        } else if let scanned = report.scannedCode, let printed = report.printedCode,
                  scanned != printed {
            report.notes.append("The barcode says \(scanned) but the printed code says \(printed).")
        }

        guard let code = report.scannedCode ?? report.printedCode else { return report }
        if let agreement = readOwnMark(document: document, expecting: code),
           agreement >= Self.stripeMatchThreshold {
            report.stripeAgreement = agreement
            report.notes.append(String(
                format: "The app read the mark on the page directly: %.0f%% of the pattern "
                    + "matches what these numbers should produce.", agreement * 100))
        }
        guard let key else {
            report.notes.append("No verification passphrase is set on this Mac, so the "
                + "signature can't be recomputed.")
            return report
        }

        // Rebuild the invoice the *page* describes, and sign that.
        if let number = report.number, let date = report.date,
           let quantity = report.quantity, let total = report.total {
            let expected = Verification.code(
                number: number, date: date, quantity: quantity, total: total, key: key
            )
            report.pageIsSelfConsistent = (expected == code)
        } else {
            var missing: [String] = []
            if report.number == nil { missing.append("invoice number") }
            if report.date == nil { missing.append("invoice date") }
            if report.quantity == nil { missing.append("item count") }
            if report.total == nil { missing.append("total") }
            report.notes.append("Couldn't read the \(missing.joined(separator: ", ")) from the page, "
                + "so its numbers can't be checked against the code.")
        }

        // Second opinion: the copy we hold.
        if let number = report.number,
           let record = invoices.first(where: { $0.number == number }) {
            report.recordFound = true
            if let total = report.total, total != record.total {
                report.differencesFromRecord.append(
                    "total on the page is \(Fmt.currency(total, code: record.currencyCode)), "
                    + "our copy says \(Fmt.currency(record.total, code: record.currencyCode))")
            }
            if let quantity = report.quantity,
               quantity != Verification.totalQuantity(of: record) {
                report.differencesFromRecord.append(
                    "page shows \(Fmt.quantity(quantity)) items, our copy has "
                    + "\(Fmt.quantity(Verification.totalQuantity(of: record)))")
            }
            if let date = report.date,
               Verification.isoDate(date) != Verification.isoDate(record.issueDate) {
                report.differencesFromRecord.append(
                    "page is dated \(Fmt.longDate(date)), our copy \(Fmt.longDate(record.issueDate))")
            }
        }
        return report
    }

    /// Our own reader. A scanner needs contrast because it knows nothing about
    /// the page; we know where the mark is and what it should say, so we can
    /// sample it and compare. That is what lets the bars be a few percent off
    /// the banner colour instead of near-black.
    private static func readOwnMark(document: PDFDocument, expecting code: String) -> Double? {
        guard let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 4
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        if let context = NSGraphicsContext.current?.cgContext {
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cg = bitmap.cgImage else { return nil }

        let expected = Verification.moduleColumns(for: code)
        guard !expected.isEmpty else { return nil }
        let geometry = StripeReader.Geometry(
            x: Verification.BannerStripes.x,
            width: Verification.BannerStripes.width,
            sampleRows: Verification.BannerStripes.sampleRows
        )
        guard let reading = StripeReader.read(
            image: cg, pageWidth: bounds.width, pageHeight: bounds.height,
            geometry: geometry, moduleCount: expected.count
        ) else { return nil }
        return StripeReader.agreement(reading.pattern, expected)
    }

    // MARK: - Reading the page

    private static func scanBarcode(in document: PDFDocument) -> String? {
        for index in 0..<min(document.pageCount, 4) {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale: CGFloat = 3                       // ~216 dpi: plenty for Code 128
            let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            if let context = NSGraphicsContext.current?.cgContext {
                context.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: context)
            }
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let cg = bitmap.cgImage else { continue }
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.code128]
            try? VNImageRequestHandler(cgImage: cg).perform([request])
            let payloads = (request.results ?? []).compactMap { $0.payloadStringValue }
            if let hit = payloads.first(where: { $0.hasPrefix(Verification.prefix + "-") }) {
                return hit
            }
        }
        return nil
    }

    private static func printedCode(in text: String) -> String? {
        firstMatch("Verification\\s+(\(Verification.prefix)-[A-Za-z0-9-]+)", in: text)
    }

    private static func value(after label: String, in text: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        return firstMatch("\(escaped)\\s*([^\\s]+)", in: text)
    }

    private static func printedDate(in text: String) -> Date? {
        guard let raw = firstMatch("Invoice Date:\\s*([A-Za-z]+\\s+\\d{1,2},\\s*\\d{4})", in: text)
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter.date(from: raw.replacingOccurrences(of: "\\s+", with: " ",
                                                             options: .regularExpression))
    }

    /// From the footer line the sheet prints for exactly this purpose.
    private static func printedQuantity(in text: String) -> Decimal? {
        guard let raw = firstMatch("·\\s*([0-9][0-9,.]*)\\s+items", in: text) else { return nil }
        return Decimal(string: raw.replacingOccurrences(of: ",", with: ""))
    }

    /// "Total:" — not "Subtotal:", and not "Amount Due", which is a different
    /// number the signature doesn't cover.
    private static func printedTotal(in text: String) -> Decimal? {
        guard let raw = firstMatch("(?:^|[^a-zA-Z])Total:\\s*[^0-9\\-]*(-?[0-9][0-9,]*\\.[0-9]{2})",
                                   in: text)
        else { return nil }
        return Decimal(string: raw.replacingOccurrences(of: ",", with: ""))
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
