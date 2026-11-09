import Foundation
import PDFKit

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Reads a freelance contract and proposes a project with its payment
/// schedule, so a job that arrives as a PDF stops being typed in by hand.
///
/// The same three rules as `OnDeviceAssist`, for the same reasons:
///
/// 1. **On-device only.** `SystemLanguageModel`. A contract is the most
///    sensitive document this app will ever touch — names, rates, terms — and
///    it never leaves the Mac. `build.sh` refuses the Private Cloud Compute
///    model anywhere in Sources.
///
/// 2. **The model extracts, it never calculates.** Every number comes back as
///    text and is parsed here, in `Decimal`. A milestone whose amount or date
///    cannot be parsed is dropped rather than guessed at, and the totals are
///    summed by the app from the parsed values.
///
/// 3. **Nothing is applied unseen.** This returns a draft; the sheet shows it,
///    the user edits and confirms, and only then is anything created.
enum ContractImport {

    /// A postal address, split the way a customer record holds one.
    struct Address: Equatable {
        var line1 = ""
        var line2 = ""
        var city = ""
        var region = ""
        var postalCode = ""
        var isEmpty: Bool { self == Address() }
    }

    /// Money paid for time rather than for a deliverable: "$500 per day".
    /// It has no amount due until the days are worked, so it never becomes a
    /// milestone -- it is shown, and kept in the project's notes.
    struct Rate: Equatable, Hashable {
        var amount: Decimal
        /// "day", "hour", "week" or "month".
        var unit: String
    }

    /// What the model found, after parsing and validation.
    struct Draft: Equatable {
        /// The company that pays -- or the person, when the client is one.
        var customerName: String = ""
        /// The person at that company the bill is for. Empty for a client
        /// who is an individual.
        var customerContact: String = ""
        var customerEmail: String = ""
        var customerPhone: String = ""
        var customerAddress = Address()
        var projectTitle: String = ""
        var contractTotal: Decimal = 0
        var paymentTermDays: Int = 30
        var milestones: [Milestone] = []
        /// Lines the model produced that could not be parsed into a milestone.
        /// Shown to the user rather than silently dropped.
        var discarded: [String] = []
        /// Payments the contract gives no date for -- "payable on delivery" is
        /// common. They carry today as a placeholder and the sheet says so.
        var undated: Set<UUID> = []
        /// Day, hourly or weekly rates. Not part of the schedule or the total.
        var rates: [Rate] = []
    }

    enum Failure: LocalizedError {
        case unavailable(OnDeviceAssist.Readiness)
        case unreadablePDF
        case noText
        case nothingFound

        var errorDescription: String? {
            switch self {
            case .unavailable(let readiness):
                return readiness.explanation ?? "Not available."
            case .unreadablePDF:
                return "That file could not be opened as a PDF."
            case .noText:
                return "This PDF has no text in it — it may be a scan. "
                     + "A scanned contract would need OCR first."
            case .nothingFound:
                return "No client or payment schedule could be found in this contract."
            }
        }
    }

    /// Comfortably inside the context window, and far more than the
    /// compensation clause of a real contract needs.
    static let excerptLimit = 6000

    // MARK: - Reading the file

    static func text(fromPDF url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else { throw Failure.unreadablePDF }
        var text = ""
        for index in 0..<document.pageCount {
            if let page = document.page(at: index), let pageText = page.string {
                text += pageText + "\n"
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A scanned contract is all images: PDFKit returns nothing, and the
        // model would otherwise be handed an empty string and invent a client.
        guard trimmed.count > 40 else { throw Failure.noText }
        return trimmed
    }

    /// Words that mark the part of a contract worth reading. A 20-page
    /// agreement is mostly boilerplate; the money lives in a few paragraphs.
    private static let signals = [
        "payment", "compensation", "fee", "invoice", "rate", "deliverable",
        "schedule", "due", "episode", "milestone", "revision", "net ", "$"
    ]

    /// The whole contract when it is short, otherwise the paragraphs that
    /// actually mention money, in document order.
    static func relevantExcerpt(_ text: String, limit: Int = excerptLimit) -> String {
        guard text.count > limit else { return text }

        let paragraphs = text.components(separatedBy: "\n")
        var kept: [String] = []
        var length = 0
        // The opening always goes in: the parties are named at the top.
        for paragraph in paragraphs.prefix(12) {
            kept.append(paragraph)
            length += paragraph.count + 1
        }
        for paragraph in paragraphs.dropFirst(12) {
            let lowered = paragraph.lowercased()
            guard signals.contains(where: lowered.contains) else { continue }
            guard length + paragraph.count + 1 <= limit else { break }
            kept.append(paragraph)
            length += paragraph.count + 1
        }
        return kept.joined(separator: "\n")
    }

    // MARK: - Parsing (pure, and the only place numbers are made)

    /// "$1,200.00" / "1200" / "1,200" -> 1200. Nil for anything else, which
    /// is what keeps an unparsable amount out of an invoice.
    static func parseAmount(_ raw: String) -> Decimal? {
        let cleaned = raw
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "USD", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              cleaned.allSatisfy({ $0.isNumber || $0 == "." }),
              cleaned.filter({ $0 == "." }).count <= 1,
              let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")),
              value > 0
        else { return nil }
        return value
    }

    /// "2026-10-30" -> that day at noon, matching how the app makes dates
    /// elsewhere. Nil for anything that is not a real calendar date.
    static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              year >= 2000, year <= 2100, (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        guard let date = Calendar.current.date(from: components) else { return nil }
        // Rejects 31 February, which the component check alone lets through.
        let round = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard round.year == year, round.month == month, round.day == day else { return nil }
        return date
    }

    /// The model's answer as plain text, with no availability attached, so the
    /// parsing below and its tests build and run on any macOS this app
    /// supports -- not just one new enough to have the framework.
    struct Fields {
        var clientName = ""
        var clientContact = ""
        var clientEmail = ""
        var projectTitle = ""
        var paymentTermDays = 30
        var milestones: [Line] = []
        var rates: [RateLine] = []
    }

    struct RateLine {
        var amount = ""
        var unit = ""
    }

    struct Line {
        var deliverable = ""
        var amount = ""
        var dueDate = ""
    }

    // MARK: - Checking against the contract (pure)

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    /// A phone number in a line: 10 to 15 digits, so a date or a postcode
    /// can't pass for one.
    static func phoneNumber(in line: String) -> String? {
        guard var found = firstMatch(#"(?<!\d)\+?\(?\d[\d ().-]{8,}\d(?!\d)"#, in: line) else { return nil }
        // "(818-555-0142)" keeps its digits, not half of its bracket.
        if found.hasPrefix("("), !found.contains(")") { found.removeFirst() }
        return (10...15).contains(found.filter(\.isNumber).count) ? found : nil
    }

    static func emailAddress(in line: String) -> String? {
        firstMatch(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+"#, in: line)
    }

    private static let stateAndZip = #"\b([A-Za-z]{2})\s*,?\s*(\d{5}(?:-\d{4})?)\s*$"#

    /// "4 Main St, Suite 2, Burbank, CA 91502" -> its parts. Only a US state
    /// and zip can be split with confidence; anything else stays whole on the
    /// first line, for the user to see and sort out, rather than being guessed
    /// into the wrong boxes.
    static func parseAddress(_ raw: String) -> Address {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let label = text.range(of: #"^(billing\s+)?address\s*[:：]\s*"#,
                                  options: [.regularExpression, .caseInsensitive]) {
            text = String(text[label.upperBound...])
        }
        guard let match = text.range(of: stateAndZip, options: .regularExpression) else {
            return Address(line1: text)
        }
        let tail = String(text[match]).filter { !$0.isWhitespace && $0 != "," }
        var address = Address()
        address.region = String(tail.prefix(2)).uppercased()
        address.postalCode = String(tail.dropFirst(2))

        var parts = text[..<match.lowerBound].split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return address }
        if parts.count == 1 {
            address.line1 = parts[0]
            return address
        }
        address.city = parts.removeLast()
        address.line1 = parts.removeFirst()
        address.line2 = parts.joined(separator: ", ")
        return address
    }

    /// The address in a party's lines: a labelled one, or an unlabelled line
    /// that starts with a street number and ends in a zip. A street on one line
    /// and "City, ST zip" on the next are read together.
    static func address(in lines: [String]) -> Address {
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        func endsInZip(_ line: String) -> Bool {
            line.range(of: stateAndZip, options: .regularExpression) != nil
        }
        for (index, line) in trimmed.enumerated() {
            let labelled = line.range(of: #"^(billing\s+)?address\s*[:：]"#,
                                      options: [.regularExpression, .caseInsensitive]) != nil
            guard labelled || (line.first?.isNumber == true && endsInZip(line)) else { continue }
            if !endsInZip(line), index + 1 < trimmed.count, endsInZip(trimmed[index + 1]) {
                return parseAddress(line + ", " + trimmed[index + 1])
            }
            let parsed = parseAddress(line)
            if !parsed.isEmpty { return parsed }
        }
        return Address()
    }

    /// The lines that belong to one party: from where its name first appears
    /// to where the other party or the first clause begins. A contract names
    /// both sides' details in the same shape, and a signed one often has the
    /// contractor's own number written in, so "a phone number somewhere in the
    /// document" is not good enough to put on a client's record.
    static func partyBlock(of name: String, in text: String) -> [String] {
        guard !name.isEmpty else { return [] }
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.range(of: name, options: .caseInsensitive) != nil })
        else { return [] }

        func endsBlock(_ line: String) -> Bool {
            let lowered = line.trimmingCharacters(in: .whitespaces).lowercased()
            if lowered == "and" { return true }
            if lowered.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil { return true }
            return ["crew member", "contractor", "independent contractor", "freelancer",
                    "consultant", "vendor", "artist"].contains { lowered.hasPrefix($0) }
        }

        // On its own line, only what follows the name and comes before any
        // "and": "between Acme (555...) and Sam (555...)" is two parties.
        var first = lines[start]
        if let name = first.range(of: name, options: .caseInsensitive) {
            first = String(first[name.upperBound...])
        }
        if let and = first.range(of: " and ", options: .caseInsensitive) {
            first = String(first[..<and.lowerBound])
        }
        var block = [first]
        for line in lines[(start + 1)...].prefix(8) {
            if endsBlock(line) { break }
            block.append(line)
        }
        return block
    }

    /// "$275.00 per day", for the sheet and the project's notes.
    static func describe(_ rate: Rate, currency: String) -> String {
        Fmt.currency(rate.amount, code: currency) + " per " + rate.unit
    }

    /// Where a contract's own sentence gives the party's address: "Acme LLC,
    /// a California corporation having its principal place of business at
    /// 4 Main St, Burbank, CA 91502 (the Company)". Only what follows this
    /// party's name and comes before the next party, so the contractor's
    /// address in the same sentence is never taken for the client's.
    static func statedAddress(of name: String, in text: String) -> Address {
        guard !name.isEmpty else { return Address() }
        let flat = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        var searchFrom = flat.startIndex
        while let found = flat.range(of: name, options: .caseInsensitive, range: searchFrom..<flat.endIndex) {
            searchFrom = found.upperBound
            var window = String(flat[found.upperBound...].prefix(240))
            for stop in [" and ", ";", "(", "“", "\""] {
                if let cut = window.range(of: stop, options: .caseInsensitive) {
                    window = String(window[..<cut.lowerBound])
                }
            }
            let pattern = #"(?i)(?:business|office|offices|located|address|residing|resides|headquartered|headquarters)[^\d;]{0,25}?\s(?:at|of|is|:)\s+(\d[^;]{3,120}?\b[A-Za-z]{2},?\s+\d{5}(?:-\d{4})?)\b"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: window, range: NSRange(window.startIndex..., in: window)),
                  let range = Range(match.range(at: 1), in: window)
            else { continue }
            let address = parseAddress(String(window[range]))
            if !address.isEmpty { return address }
        }
        return Address()
    }

    /// A contact is a person. An address, a phone number or an email that the
    /// model put in the field is not one, and is left out rather than printed
    /// on an invoice as somebody's name.
    static func looksLikeName(_ text: String) -> Bool {
        !text.contains(where: \.isNumber) && !text.contains("@")
            && text.split(separator: " ").count <= 6
    }

    private static func normalizedUnit(_ raw: String) -> String? {
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "day", "days", "daily", "d": return "day"
        case "hour", "hours", "hr", "hrs", "hourly", "h": return "hour"
        case "week", "weeks", "wk", "weekly": return "week"
        case "month", "months", "mo", "monthly": return "month"
        default: return nil
        }
    }

    /// How a contract might write this amount: "275", "$2,100", "62.50".
    private static func spellings(of amount: Decimal) -> [String] {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        let whole = amount == amount.rounded(0)
        formatter.minimumFractionDigits = whole ? 0 : 2
        formatter.maximumFractionDigits = whole ? 0 : 2
        var all: [String] = []
        for grouped in [false, true] {
            formatter.usesGroupingSeparator = grouped
            if let text = formatter.string(from: NSDecimalNumber(decimal: amount)) { all.append(text) }
        }
        return Array(Set(all))
    }

    /// The unit each mention of this amount is charged by -- nil where it is
    /// a fixed sum. "$275 per day", "$75/hr", "a day rate of $500" are rates;
    /// "$2,100 flat fee" is not.
    static func rateUnits(of amount: Decimal, in text: String) -> [String?] {
        let flat = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        let lowered = flat.lowercased() as NSString
        var units: [String?] = []
        for spelling in spellings(of: amount) {
            let escaped = NSRegularExpression.escapedPattern(for: spelling)
            guard let regex = try? NSRegularExpression(
                pattern: #"(?<![\d.,])\$?\s?"# + escaped + #"(?:\.00)?(?![\d]|[.,]\d)"#) else { continue }
            for match in regex.matches(in: lowered as String, range: NSRange(location: 0, length: lowered.length)) {
                let afterStart = match.range.location + match.range.length
                let after = lowered.substring(with: NSRange(location: afterStart,
                                                            length: min(24, lowered.length - afterStart)))
                let beforeStart = max(0, match.range.location - 30)
                let before = lowered.substring(with: NSRange(location: beforeStart,
                                                             length: match.range.location - beforeStart))
                var unit: String?
                if let r = after.range(of: #"^\s*(?:usd\s*)?(?:/\s*|per\s+|an?\s+|each\s+)(days?|hours?|hrs?|weeks?|wk|months?|mo)\b"#,
                                       options: .regularExpression) {
                    let word = after[r].split(whereSeparator: { " /".contains($0) }).last.map(String.init) ?? ""
                    unit = normalizedUnit(word)
                } else if let r = after.range(of: #"^\s*(daily|hourly|weekly|monthly)\b"#, options: .regularExpression) {
                    unit = normalizedUnit(after[r].trimmingCharacters(in: .whitespaces))
                } else if let r = before.range(of: #"\b(day|daily|hourly|hour|weekly|week|monthly)\s+rate\b[^$\d]{0,14}$"#,
                                               options: .regularExpression) {
                    unit = normalizedUnit(String(before[r].split(separator: " ").first ?? ""))
                }
                units.append(unit)
            }
        }
        return units
    }

    /// Fixed fees the contract writes down beside a rate, such as "$500 per
    /// day + $3,000 flat fee (assembly edit)". Found by the app, so a model
    /// that read only the rate cannot lose the fee. The note in brackets, when
    /// there is one, names it.
    static func flatFees(in text: String) -> [(amount: Decimal, deliverable: String)] {
        let flat = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        let pattern = #"(?i)\$?\s?(\d[\d,]*(?:\.\d{2})?)\s*(?:usd\s*)?(?:flat(?:\s+(?:fee|rate))?|lump[- ]sum)(?:\s+(?:fee|payment))?\s*(?:\(([^)]{1,80})\)|for\s+(?:the\s+)?([^.;,()$]{3,60}))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var found: [(Decimal, String)] = []
        for match in regex.matches(in: flat, range: NSRange(flat.startIndex..., in: flat)) {
            guard let r = Range(match.range(at: 1), in: flat), let amount = parseAmount(String(flat[r])) else { continue }
            var name = "Flat fee"
            for group in [2, 3] {
                if let g = Range(match.range(at: group), in: flat) {
                    name = flat[g].trimmingCharacters(in: .whitespaces)
                }
            }
            if !found.contains(where: { $0.0 == amount }) { found.append((amount, name)) }
        }
        return found
    }

    /// Whether `value` is written within two lines of one of these names. A
    /// signed contract carries the contractor's own email too, so the model's
    /// answer being somewhere in the document doesn't make it the client's.
    static func mentioned(_ value: String, near names: [String], in text: String) -> Bool {
        guard !value.isEmpty else { return false }
        let lines = text.components(separatedBy: .newlines)
        let names = names.filter { !$0.isEmpty }
        for (index, line) in lines.enumerated()
        where line.range(of: value, options: .caseInsensitive) != nil {
            let nearby = lines[max(0, index - 2)...min(lines.count - 1, index + 2)]
            if nearby.contains(where: { near in
                names.contains { near.range(of: $0, options: .caseInsensitive) != nil }
            }) { return true }
        }
        return false
    }

    /// The ways a contract might write this date.
    private static func spellings(of date: Date) -> [String] {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let y = parts.year, let m = parts.month, let d = parts.day else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let long = formatter.monthSymbols[m - 1], short = formatter.shortMonthSymbols[m - 1]
        var all = [String(format: "%04d-%02d-%02d", y, m, d)]
        for (a, b) in [(m, d), (d, m)] {
            all += [String(format: "%02d/%02d/%04d", a, b, y), "\(a)/\(b)/\(y)",
                    String(format: "%02d/%02d/%02d", a, b, y % 100)]
        }
        for month in [long, short] {
            all += ["\(month) \(d)", "\(month). \(d)", "\(d) \(month)"]
        }
        return all
    }

    /// Whether the contract states this date beside this payment. The start
    /// date of an agreement is a real date in the document, and a model asked
    /// for due dates will happily use it, so appearing somewhere isn't enough:
    /// it has to be within a line of the deliverable or the amount.
    static func statesDate(_ date: Date, deliverable: String, amount: Decimal, in text: String) -> Bool {
        let whole = NSDecimalNumber(decimal: amount).intValue
        var marks = [deliverable.lowercased(), "$\(whole)"]
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let grouped = formatter.string(from: NSNumber(value: whole)) { marks.append("$" + grouped) }
        let lines = text.lowercased().components(separatedBy: .newlines)
        let dates = spellings(of: date).map { $0.lowercased() }
        for (index, line) in lines.enumerated() where marks.contains(where: line.contains) {
            let nearby = lines[max(0, index - 1)...min(lines.count - 1, index + 1)]
            if nearby.contains(where: { near in dates.contains(where: near.contains) }) { return true }
        }
        return false
    }

    /// Turns the model's text fields into a validated draft. Pure, so the
    /// self-test can exercise every rejection without a model. `source` is the
    /// contract's own text, which contact details and dates are checked against.
    static func draft(from extracted: Fields, source: String? = nil) -> Draft {
        var draft = Draft()
        draft.customerName = extracted.clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.customerContact = extracted.clientContact.trimmingCharacters(in: .whitespacesAndNewlines)
        if !looksLikeName(draft.customerContact) { draft.customerContact = "" }
        // A client who is a person comes back either way round: as the
        // client, or as a contact with no company. Either way they are the
        // client, and naming them twice would print them twice on the bill.
        if draft.customerName.isEmpty {
            draft.customerName = draft.customerContact
            draft.customerContact = ""
        } else if draft.customerContact.caseInsensitiveCompare(draft.customerName) == .orderedSame {
            draft.customerContact = ""
        }

        // Read from the client's own block, by the app: a number the model
        // never handles can't be the wrong party's, or land in the wrong field.
        // The model's email is the fallback, and only if it is one, and is in
        // the contract.
        let lines = source.map { partyBlock(of: draft.customerName, in: $0)
            + partyBlock(of: draft.customerContact, in: $0) } ?? []
        draft.customerPhone = lines.lazy.compactMap(phoneNumber(in:)).first ?? ""
        draft.customerAddress = address(in: lines)
        if draft.customerAddress.isEmpty, let source {
            draft.customerAddress = statedAddress(of: draft.customerName, in: source)
        }
        let answered = emailAddress(in: extracted.clientEmail) ?? ""
        let nearClient = source.map {
            mentioned(answered, near: [draft.customerName, draft.customerContact], in: $0)
        } ?? true
        draft.customerEmail = lines.lazy.compactMap(emailAddress(in:)).first
            ?? (nearClient ? answered : "")

        draft.projectTitle = extracted.projectTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.paymentTermDays = (1...365).contains(extracted.paymentTermDays)
            ? extracted.paymentTermDays : 30

        // Rates first: they are checked against the contract, and a payment
        // the model listed that the contract charges by the day is one too.
        func addRate(_ rate: Rate) {
            if !draft.rates.contains(rate) { draft.rates.append(rate) }
        }
        for line in extracted.rates {
            guard let amount = parseAmount(line.amount) else { continue }
            if let source {
                guard let unit = rateUnits(of: amount, in: source).compactMap({ $0 }).first else { continue }
                addRate(Rate(amount: amount, unit: unit))
            } else if let unit = normalizedUnit(line.unit) {
                addRate(Rate(amount: amount, unit: unit))
            }
        }

        for line in extracted.milestones {
            let deliverable = line.deliverable.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let amount = parseAmount(line.amount), !deliverable.isEmpty else {
                draft.discarded.append(
                    "\(line.deliverable.isEmpty ? "—" : line.deliverable) · "
                    + "\(line.amount.isEmpty ? "no amount" : line.amount) · "
                    + "\(line.dueDate.isEmpty ? "no date" : line.dueDate)")
                continue
            }
            // Every mention of it in the contract is "per day": it is a rate,
            // whatever the model called it.
            if let source {
                let units = rateUnits(of: amount, in: source)
                if !units.isEmpty, units.allSatisfy({ $0 != nil }), let unit = units.first ?? nil {
                    addRate(Rate(amount: amount, unit: unit))
                    continue
                }
            }
            // A real payment with no real date is still a real payment: it is
            // kept and flagged, not dropped and not given a date from elsewhere.
            var milestone = Milestone(deliverable: deliverable, amount: amount, dueDate: placeholderDate())
            if let date = parseDate(line.dueDate),
               source.map({ statesDate(date, deliverable: deliverable, amount: amount, in: $0) }) ?? true {
                milestone.dueDate = date
            } else {
                draft.undated.insert(milestone.id)
            }
            draft.milestones.append(milestone)
        }
        // A flat fee written beside a rate is a payment the model can miss
        // while reading the rate. Only alongside a rate, so an ordinary
        // schedule is the model's alone.
        if let source, !draft.rates.isEmpty {
            for fee in flatFees(in: source)
            where !draft.milestones.contains(where: { $0.amount == fee.amount })
                && !draft.rates.contains(where: { $0.amount == fee.amount }) {
                let milestone = Milestone(deliverable: fee.deliverable, amount: fee.amount,
                                          dueDate: placeholderDate())
                draft.undated.insert(milestone.id)
                draft.milestones.append(milestone)
            }
        }
        // Dated ones in date order, then the undated in the contract's order.
        let order = Dictionary(uniqueKeysWithValues: draft.milestones.enumerated().map { ($1.id, $0) })
        draft.milestones.sort { a, b in
            let aOpen = draft.undated.contains(a.id), bOpen = draft.undated.contains(b.id)
            if aOpen != bOpen { return bOpen }
            if !aOpen, a.dueDate != b.dueDate { return a.dueDate < b.dueDate }
            return order[a.id, default: 0] < order[b.id, default: 0]
        }
        // Summed here, from parsed Decimals. The model is never asked for it.
        draft.contractTotal = draft.milestones.reduce(0) { $0 + $1.amount }
        return draft
    }

    /// Today at noon, matching `parseDate`.
    private static func placeholderDate() -> Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
    }

    /// An invented crew deal memo in the shape that is hard to read: the
    /// client's address inside a sentence, a day rate and a flat fee on one
    /// line, and the contractor's own details filled in at the end. Used by
    /// the self-test; every name and number in it is made up.
    static let dealMemoSample = """
    Northlight Post LLC
    CREW DEAL MEMO
    Contractor Name:
    TERMS AND CONDITIONS: This Deal Memo shall confirm the agreement between
    the above-named freelance contractor ("Contractor") and Northlight Post LLC, a California corporation having its
    principal place of business at 200 Example Blvd, Suite 5, Glendale, CA 91203 ("Production Company"), in
    connection with the Film presently entitled
    Harbour Lights
    Contractor will commence performance of services as of Dec 1-12, 2026
    for the position of Assistant Editor.
    Exact dates on set for this position will be communicated by production.
    COMPENSATION: Company shall pay to Contractor the following compensation:
    Rate:
    $350 per day + 1800 flat fee (selects reel)
    Overtime: calculated as (day rate / 12) x 1.5 applies to any time worked beyond twelve (12) hours.
    This rate is all-inclusive.
    PAYMENT: fees shall be paid to the Contractor within Fifteen (15) days after completion of production and
    receipt of the Contractor's invoice.
    AGREED TO AND ACCEPTED:
    CONTRACTOR PRINT CONTRACTOR SIGN DATE
    ADDRESS:
    123 Example St, Burbank, CA 91502
    PHONE:
    657-555-0199
    EMAIL:
    crew@example.com
    """

    // MARK: - The call

    static func extract(from contractText: String) async throws -> Draft {
        let readiness = OnDeviceAssist.readiness
        guard readiness == .ready else { throw Failure.unavailable(readiness) }

        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { throw Failure.unavailable(.unsupportedOS) }

        let session = LanguageModelSession(model: SystemLanguageModel.default) {
            """
            You read freelance contracts for video and post-production work and \
            pull out the billing facts.

            - Copy values exactly as they appear. Never calculate a total, never \
            add a payment that is not written down, and never invent a date.
            - Amounts: digits only, no currency symbol and no thousands \
            separator. "$1,200.00" becomes "1200.00".
            - Dates: YYYY-MM-DD. If a payment has no date of its own, such as \
            "payable on delivery", leave it empty. The date of the agreement \
            and the start date of the work are not due dates.
            - The email must be the client's own email address, not a phone \
            number and not the contractor's. Empty if there is none.
            - One milestone per scheduled payment. "Episodes 2-3 — $300" is one \
            milestone, not two.
            - The client is whoever pays, not the contractor being paid: the \
            company, or the person when an individual hires the contractor.
            - The contact is the named person at the client company the work or \
            the invoices go to, such as a producer or accounts payable. Empty \
            if nobody is named or the client is that person.
            - The contact is a person's name only: never an address, a phone \
            number or a company.
            - A rate paid for time, such as "$500 per day" or "$75/hr", is not \
            a scheduled payment: put it in rates, never in milestones. A flat \
            fee is a milestone, even with no date. "$500/day + $3,000 flat fee \
            (assembly)" is one rate of 500 per day and one milestone of 3000.
            - Leave a field empty rather than guessing at it.
            """
        }

        let response = try await session.respond(
            to: """
            Contract:

            \(relevantExcerpt(contractText))
            """,
            generating: RawContract.self,
            options: GenerationOptions(temperature: 0.1)
        )

        let answer = response.content
        let draft = draft(from: Fields(
            clientName: answer.clientName,
            clientContact: answer.clientContact,
            clientEmail: answer.clientEmail,
            projectTitle: answer.projectTitle,
            paymentTermDays: answer.paymentTermDays,
            milestones: answer.milestones.map {
                Line(deliverable: $0.deliverable, amount: $0.amount, dueDate: $0.dueDate)
            },
            rates: answer.rates.map { RateLine(amount: $0.amount, unit: $0.unit) }),
            source: contractText)
        guard !draft.customerName.isEmpty || !draft.milestones.isEmpty || !draft.rates.isEmpty else {
            throw Failure.nothingFound
        }
        return draft
        #else
        throw Failure.unavailable(.unsupportedOS)
        #endif
    }
}

#if canImport(FoundationModels)
/// The shape the model fills in. Every number is a `String`: guided generation
/// would happily give us a `Decimal`, but then the model would be doing the
/// parsing, and a misread "1,200" becoming 1.2 is exactly the kind of error
/// that reaches a client as an invoice.
@available(macOS 26.0, *)
@Generable(description: "Billing facts from a freelance contract")
struct RawContract {
    @Guide(description: "The client company that pays, or the person's full name if the client is an individual. Empty if unclear.")
    var clientName: String

    @Guide(description: "The named person at the client company invoices go to. Empty if none is named or the client is an individual.")
    var clientContact: String

    @Guide(description: "The client's own billing email address, containing @. Empty if absent.")
    var clientEmail: String

    @Guide(description: "The production or project title. Empty if unnamed.")
    var projectTitle: String

    @Guide(description: "Days to pay an invoice, e.g. 30 for net 30. Use 30 if unstated.")
    var paymentTermDays: Int

    @Guide(description: "Every scheduled payment in the contract, including flat fees. Not day or hourly rates.", .count(0...24))
    var milestones: [RawMilestone]

    @Guide(description: "Rates paid for time worked, such as a day rate or an hourly rate", .count(0...6))
    var rates: [RawRate]
}

@available(macOS 26.0, *)
@Generable(description: "A rate paid for time worked")
struct RawRate {
    @Guide(description: "Amount per unit, digits only, no symbol or separators")
    var amount: String

    @Guide(description: "day, hour, week or month")
    var unit: String
}

@available(macOS 26.0, *)
@Generable(description: "One scheduled payment")
struct RawMilestone {
    @Guide(description: "What is delivered, e.g. 'Episode 1' or 'Final cut'")
    var deliverable: String

    @Guide(description: "Amount, digits only, no symbol or separators")
    var amount: String

    @Guide(description: "Due date as YYYY-MM-DD, empty if the contract gives none")
    var dueDate: String
}
#endif
