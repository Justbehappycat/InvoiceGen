import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model, used to tidy up text the user has already typed.
///
/// Three rules hold everywhere in this file, and they are the reason the
/// feature is allowed to exist in an app that promises nothing leaves the Mac:
///
/// 1. **On-device only.** `SystemLanguageModel` runs on this machine. The same
///    framework also offers `PrivateCloudComputeLanguageModel`, which sends the
///    prompt to Apple's servers — that would quietly break the promise the rest
///    of the app is built on, so it is never used here. `build.sh` refuses to
///    build if the name appears anywhere in Sources.
///
/// 2. **The model never does arithmetic.** It rewrites wording and nothing
///    else. Quantities, prices and totals stay exactly as typed, computed in
///    `Decimal` as they always were. `changesNumbers` enforces this by rejecting
///    any result whose numbers differ at all from the input's — a cheap,
///    deterministic guard that does not depend on the model behaving.
///
/// 3. **Nothing is applied unseen.** `tidy` returns a proposal; the caller
///    shows it and the user decides. Undo covers it either way.
enum OnDeviceAssist {

    /// Why the feature is or isn't offered. Every "no" simply hides the button.
    enum Readiness: Equatable {
        case ready
        /// Built for macOS 13, so the framework may not exist at all.
        case unsupportedOS
        case deviceNotEligible
        case appleIntelligenceOff
        case modelNotReady

        var explanation: String? {
            switch self {
            case .ready: return nil
            case .unsupportedOS:
                return "Tidying up wording needs macOS 26 or later."
            case .deviceNotEligible:
                return "This Mac doesn't support Apple Intelligence."
            case .appleIntelligenceOff:
                return "Turn on Apple Intelligence in System Settings to tidy up wording."
            case .modelNotReady:
                return "The on-device model is still downloading. Try again shortly."
            }
        }
    }

    static var readiness: Readiness {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return .unsupportedOS }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
            case .modelNotReady: return .modelNotReady
            @unknown default: return .modelNotReady
            }
        }
        #else
        return .unsupportedOS
        #endif
    }

    static var isReady: Bool { readiness == .ready }

    /// What the user is asked to approve.
    struct Proposal: Equatable, Identifiable {
        let id = UUID()
        var title: String
        var details: String

        static func == (a: Proposal, b: Proposal) -> Bool {
            a.title == b.title && a.details == b.details
        }

        func changes(from item: LineItem) -> Bool {
            title != item.title || details != item.details
        }
    }

    enum Failure: LocalizedError, Equatable {
        case unavailable(Readiness)
        case changedNumbers
        case empty

        var errorDescription: String? {
            switch self {
            case .unavailable(let readiness):
                return readiness.explanation ?? "Not available."
            case .changedNumbers:
                // Rule 2. We throw rather than show it: a suggestion that moves
                // a figure is the one kind of mistake that could be approved
                // without being noticed.
                return "The suggestion changed a number, so it was discarded."
            case .empty:
                return "Nothing to tidy up."
            }
        }
    }

    /// Longer than any line anyone types, short enough to stay well inside the
    /// context window so a long paste can't fail the request.
    static let inputLimit = 600

    // MARK: - The guard

    /// Every run of digits in a string, e.g. "2 x EP10" -> ["2", "10"].
    static func digitRuns(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// True when `result`'s numbers differ from `source`'s in either direction.
    ///
    /// Symmetric on purpose. Inventing a price is the obvious danger, but
    /// losing one is just as bad on an invoice: the model's first instinct on
    /// "ep1 edit" was "Episode Edit", which quietly drops which episode was
    /// billed. Spelling a numeral out as a word trips this too, which is what
    /// we want — "Two rounds" is not the same cell as "2 rounds".
    static func changesNumbers(source: String, result: String) -> Bool {
        Set(digitRuns(in: source)) != Set(digitRuns(in: result))
    }

    // MARK: - The call

    /// Rewrites the item's wording. Throws rather than returning anything the
    /// guard rejects; the caller shows what comes back and applies nothing.
    static func tidy(title: String, details: String, heading: String) async throws -> Proposal {
        let readiness = self.readiness
        guard readiness == .ready else { throw Failure.unavailable(readiness) }

        let source = (title + "\n" + details).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { throw Failure.empty }

        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { throw Failure.unavailable(.unsupportedOS) }

        let session = LanguageModelSession(model: SystemLanguageModel.default) {
            """
            You rewrite one line on a freelance video and post-production \
            invoice so a client reads it clearly.

            - Expand trade shorthand: "ep" to "Episode", "rev" to "Revision", \
            "vo" to "Voiceover", "gfx" to "Graphics".
            - Write the name in Title Case.
            - Every number in the input must appear in your output, unchanged \
            and as digits. "ep1" becomes "Episode 1", never "Episode". Never \
            spell a number out as a word, never drop one, never add one.
            - Keep every item and quantity listed. "Long x1 Short x1" keeps both.
            - Do not add prices, dates, or work that is not described.
            - If the description is empty, leave it empty. Do not invent one.
            - If the wording is already clear, return it unchanged.
            - Keep it short: this prints in a table column, not a paragraph.
            """
        }

        let clipped = String(source.prefix(inputLimit))
        let response = try await session.respond(
            to: """
            Column heading: \(heading)

            Name: \(title)
            Description: \(details)

            Rewrite the name and description.
            """,
            generating: TidiedLine.self,
            options: GenerationOptions(temperature: 0.2)
        )

        let proposal = Proposal(
            title: response.content.name.trimmingCharacters(in: .whitespacesAndNewlines),
            details: response.content.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        guard !proposal.title.isEmpty else { throw Failure.empty }
        guard !changesNumbers(source: clipped, result: proposal.title + " " + proposal.details)
        else { throw Failure.changedNumbers }

        return proposal
        #else
        throw Failure.unavailable(.unsupportedOS)
        #endif
    }
}

#if canImport(FoundationModels)
/// The shape the model fills in. Guided generation constrains decoding to this
/// schema, so the result arrives as a typed value — there is no free text to
/// parse and no way to get a malformed answer back.
@available(macOS 26.0, *)
@Generable(description: "One tidied line on an invoice")
struct TidiedLine {
    @Guide(description: "The item name, in title case, at most 8 words")
    var name: String

    @Guide(description: "The description, one short sentence. Empty if there is nothing to add.")
    var summary: String
}
#endif
