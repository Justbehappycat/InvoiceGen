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
        case addedMaterial
        case droppedMaterial
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
            case .addedMaterial:
                return "The suggestion added more than the line says, so it was discarded."
            case .droppedMaterial:
                return "The suggestion left out part of what you wrote, so it was discarded."
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
    ///
    /// Counted, not just collected: as a set, {1, 2} survives "Episode 2 ...
    /// 2 clips" becoming "Episode 2 ... two clips", because the episode's 2
    /// masks the one that vanished. Every occurrence has to come through.
    static func changesNumbers(source: String, result: String) -> Bool {
        digitRuns(in: source).sorted() != digitRuns(in: result).sorted()
    }

    /// Every suggestion goes through this before anyone sees it. Pure, so the
    /// self-test can hold each rule down without a model.
    ///
    /// - A description that was empty stays empty -- in code, not on the
    ///   prompt's word, because that is exactly where a model invents work.
    /// - A description may grow by rewording, not by new material: anything
    ///   past three times the original (or 60 characters more) is discarded.
    /// - No number may move, in either direction.
    /// - Nothing the user wrote may go missing: a tidier line that drops
    ///   "Podcast package" reads worse than the original, not better.
    /// Joining words a rewrite may fairly swap for "and" or a comma.
    private static let connectives: Set<String> = [
        "and", "with", "plus", "also", "each", "from", "into", "including", "includes", "the", "for",
    ]

    /// The words of `source` (four letters or more) that `result` no longer
    /// has. A word counts as kept when the result has one starting with the
    /// same three letters, so expanding shorthand ("intvw" -> "interview")
    /// and fixing a typo ("socail" -> "social") both pass, while a dropped
    /// "Podcast package" does not.
    static func droppedWords(source: String, result: String) -> [String] {
        func words(_ text: String) -> [String] {
            text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        }
        let kept = Set(words(result).filter { $0.count >= 3 }.map { String($0.prefix(3)) })
        return words(source).filter { word in
            word.count >= 4 && !connectives.contains(word) && !kept.contains(String(word.prefix(3)))
        }
    }

    static func vet(_ raw: Proposal, title: String, details: String) throws -> Proposal {
        func clean(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.caseInsensitiveCompare("(empty)") == .orderedSame ? "" : t
        }
        let sourceDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        var proposal = Proposal(title: clean(raw.title), details: clean(raw.details))
        if sourceDetails.isEmpty { proposal.details = "" }

        guard !proposal.title.isEmpty else { throw Failure.empty }
        let allowed = max(sourceDetails.count * 3, sourceDetails.count + 60)
        guard proposal.details.count <= allowed else { throw Failure.addedMaterial }
        guard !changesNumbers(source: title + "\n" + details,
                              result: proposal.title + " " + proposal.details)
        else { throw Failure.changedNumbers }
        guard droppedWords(source: title + " " + details,
                           result: proposal.title + " " + proposal.details).isEmpty
        else { throw Failure.droppedMaterial }
        return proposal
    }

    // MARK: - The prompt

    /// Tuned against real shorthand on the on-device model. Asking a model
    /// this size to "rewrite more" makes it invent -- a voiceover and
    /// graphics appeared on a bare "podcast edit" -- and drift into "we will
    /// ...". Worked examples fix both: it copies their shape. None of them
    /// is a line a user is likely to type verbatim, so it learns the style
    /// without parroting the content ("full-length" once leaked from an
    /// example into an unrelated reel).
    static let instructions = """
        You edit invoice lines for a freelance video and post-production \
        studio. The freelancer types shorthand; you return the line as the \
        client should read it.

        How to rewrite:
        - Correct spelling and typos, and expand every abbreviation.
        - Write the description as a clean invoice phrase: noun phrases \
        joined with "and" or commas, or "including ...". Not a story: never \
        "we", "I", "will" or "have completed".
        - Keep every item, every detail and every number the freelancer \
        wrote. Numbers stay as digits, next to what they count: "clips 2" \
        becomes "2 clips".
        - If a field already reads well, return it unchanged. Fix only \
        what is wrong; never shorten a description by leaving words out.
        - Add nothing. No services, steps, deliverables or qualities that \
        are not in the input. If the description is empty, return it empty.
        - The name is a short Title Case heading.

        Examples:
        Name: ep 7 | Description: vertical cuts 3, trailer x1
        -> Name: Episode 7 | Description: 3 vertical cuts and 1 trailer

        Name: ep1 edit + colour pass | Description: long x1 short x1
        -> Name: Episode 1 Edit and Colour Pass | Description: 1 long cut and 1 short cut

        Name: rev rd 3 | Description: client notes, recut intvw, swap music
        -> Name: Revision Round 3 | Description: Client notes, including an interview recut and a music swap

        Name: podcast edit | Description: (empty)
        -> Name: Podcast Edit | Description: (empty)

        Name: ep 4 | Description: Promo bundle — 1 trailer + 3 teasers
        -> Name: Episode 4 | Description: Promo bundle: 1 trailer and 3 teasers

        Name: gfx pkg | Description: lower thirds + endcard
        -> Name: Graphics Package | Description: Lower thirds and an end card
        """

    // MARK: - The call

    /// Rewrites the item's wording. Throws rather than returning anything the
    /// guard rejects; the caller shows what comes back and applies nothing.
    static func tidy(title: String, details: String, heading: String) async throws -> Proposal {
        let readiness = self.readiness
        guard readiness == .ready else { throw Failure.unavailable(readiness) }

        guard !(title + details).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw Failure.empty }

        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { throw Failure.unavailable(.unsupportedOS) }

        let prompt = "Column heading: \(heading)\n"
            + "Name: \(title) | Description: \(details.isEmpty ? "(empty)" : details)"
        let sourceTitle = String(title.prefix(inputLimit))
        let sourceDetails = String(details.prefix(inputLimit))

        // Greedy first, so the same line gets the same suggestion every time.
        // If the guard turns that down for adding or dropping material -- the
        // small model's habit, not a verdict on the line -- one more try with
        // a little sampling, in a fresh session so the rejected answer isn't
        // in its context. A number that moved is never retried.
        func ask(_ options: GenerationOptions) async throws -> Proposal {
            let session = LanguageModelSession(model: SystemLanguageModel.default) { instructions }
            let response = try await session.respond(to: prompt, generating: TidiedLine.self, options: options)
            return try vet(Proposal(title: response.content.name, details: response.content.summary),
                           title: sourceTitle, details: sourceDetails)
        }
        do {
            return try await ask(GenerationOptions(sampling: .greedy))
        } catch Failure.addedMaterial, Failure.droppedMaterial {
            return try await ask(GenerationOptions(temperature: 0.5))
        }
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
    @Guide(description: "The item name in Title Case, concise, at most 8 words")
    var name: String

    @Guide(description: "The whole description, every part of it kept, as a clear invoice phrase using only the facts given. Empty when the input description is empty.")
    var summary: String
}
#endif
