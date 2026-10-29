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

    /// What the model found, after parsing and validation.
    struct Draft: Equatable {
        var customerName: String = ""
        var customerEmail: String = ""
        var projectTitle: String = ""
        var contractTotal: Decimal = 0
        var paymentTermDays: Int = 30
        var milestones: [Milestone] = []
        /// Lines the model produced that could not be parsed into a milestone.
        /// Shown to the user rather than silently dropped.
        var discarded: [String] = []
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
        var clientEmail = ""
        var projectTitle = ""
        var paymentTermDays = 30
        var milestones: [Line] = []
    }

    struct Line {
        var deliverable = ""
        var amount = ""
        var dueDate = ""
    }

    /// Turns the model's text fields into a validated draft. Pure, so the
    /// self-test can exercise every rejection without a model.
    static func draft(from extracted: Fields) -> Draft {
        var draft = Draft()
        draft.customerName = extracted.clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.customerEmail = extracted.clientEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.projectTitle = extracted.projectTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.paymentTermDays = (1...365).contains(extracted.paymentTermDays)
            ? extracted.paymentTermDays : 30

        for line in extracted.milestones {
            let deliverable = line.deliverable.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let amount = parseAmount(line.amount),
                  let date = parseDate(line.dueDate),
                  !deliverable.isEmpty else {
                draft.discarded.append(
                    "\(line.deliverable.isEmpty ? "—" : line.deliverable) · "
                    + "\(line.amount.isEmpty ? "no amount" : line.amount) · "
                    + "\(line.dueDate.isEmpty ? "no date" : line.dueDate)")
                continue
            }
            draft.milestones.append(Milestone(deliverable: deliverable, amount: amount, dueDate: date))
        }
        draft.milestones.sort { $0.dueDate < $1.dueDate }
        // Summed here, from parsed Decimals. The model is never asked for it.
        draft.contractTotal = draft.milestones.reduce(0) { $0 + $1.amount }
        return draft
    }

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
            - Dates: YYYY-MM-DD. If a payment has no date, leave it empty.
            - One milestone per scheduled payment. "Episodes 2-3 — $300" is one \
            milestone, not two.
            - The client is whoever pays, not the contractor being paid.
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
            clientEmail: answer.clientEmail,
            projectTitle: answer.projectTitle,
            paymentTermDays: answer.paymentTermDays,
            milestones: answer.milestones.map {
                Line(deliverable: $0.deliverable, amount: $0.amount, dueDate: $0.dueDate)
            }))
        guard !draft.customerName.isEmpty || !draft.milestones.isEmpty else {
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
    @Guide(description: "The client company or person who pays. Empty if unclear.")
    var clientName: String

    @Guide(description: "The client's billing email. Empty if absent.")
    var clientEmail: String

    @Guide(description: "The production or project title. Empty if unnamed.")
    var projectTitle: String

    @Guide(description: "Days to pay an invoice, e.g. 30 for net 30. Use 30 if unstated.")
    var paymentTermDays: Int

    @Guide(description: "Every scheduled payment in the contract", .count(0...24))
    var milestones: [RawMilestone]
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
