import Foundation
import SwiftUI

/// Coordinates wording suggestions for an invoice's line items: when to ask the
/// on-device model, what to do with its answer, and what never to do.
///
/// The rules it holds, so no view has to:
///
/// - **Suggests, never writes.** It has no access to the invoice. The row asks
///   for a suggestion and applies one only when the user presses Apply.
/// - **Asks after a pause, not per keystroke.** Edits are debounced; finishing
///   with a line (focus leaving it) asks at once.
/// - **One question at a time.** Requests run serially, so a whole-invoice
///   review can't fire twenty model calls at once.
/// - **Never answers a stale question.** If a line changes while it is being
///   analysed, the old answer is discarded on arrival and queued work for the
///   old text is dropped.
/// - **Doesn't repeat itself.** Answers are cached by input, so the same text
///   is never sent twice; a dismissed suggestion is not offered again for the
///   same text unless the user asks.
/// - **Quiet when proactive.** A suggestion nobody asked for appears only if it
///   changes something; failures and "already fine" stay silent. A request the
///   user made always gets an answer, including why not.
///
/// Numbers stay out of it entirely: the model only ever sees and returns the
/// two text fields, and `OnDeviceAssist` discards any answer that moves a digit.
@MainActor
final class WordingAssistant: ObservableObject {

    enum State: Equatable {
        case idle
        /// `manual` decides whether the row shows progress: a proactive check
        /// runs invisibly.
        case working(manual: Bool)
        case suggestion(OnDeviceAssist.Proposal)
        /// Only shown for a request the user made.
        case alreadyClear
        case failed(String)
    }

    /// The text a suggestion was made for. A suggestion is only ever shown
    /// against exactly this input.
    struct Input: Hashable {
        var title: String
        var details: String
        var heading: String

        init(title: String, details: String, heading: String) {
            self.title = title
            self.details = details
            self.heading = heading
        }

        init(_ item: LineItem, heading: String) {
            title = item.title
            details = item.details
            self.heading = heading
        }

        /// Too little to improve: the model would only be guessing.
        var isWorthAsking: Bool {
            title.trimmingCharacters(in: .whitespaces).count >= 3
        }
    }

    typealias Tidier = (_ title: String, _ details: String, _ heading: String) async throws
        -> OnDeviceAssist.Proposal

    @Published private(set) var states: [UUID: State] = [:]

    /// Seconds of quiet after an edit before a proactive check.
    var debounce: Duration = .milliseconds(1500)
    /// Model availability and the master switch; checked on every request.
    var isAvailable: () -> OnDeviceAssist.Readiness = { OnDeviceAssist.readiness }
    var isEnabled: () -> Bool = { UserDefaults.standard.object(forKey: "onDeviceAssist") as? Bool ?? true }
    var isProactive: () -> Bool = {
        UserDefaults.standard.object(forKey: "onDeviceAssistProactive") as? Bool ?? true
    }

    private let tidy: Tidier
    private var inputs: [UUID: Input] = [:]
    private var cache: [Input: OnDeviceAssist.Proposal] = [:]
    private var dismissed: Set<Input> = []
    private var timers: [UUID: Task<Void, Never>] = [:]
    private var queue: [(line: UUID, input: Input, manual: Bool, force: Bool, quietIfClear: Bool)] = []
    private var running: (line: UUID, input: Input)?
    private var worker: Task<Void, Never>?
    /// For tests: how many model calls were actually made.
    private(set) var calls = 0

    init(tidy: @escaping Tidier = { try await OnDeviceAssist.tidy(title: $0, details: $1, heading: $2) }) {
        self.tidy = tidy
    }

    func state(for line: UUID) -> State { states[line] ?? .idle }

    var canSuggest: Bool { isEnabled() && isAvailable() == .ready }

    // MARK: - Events from the editor

    /// The user changed a line. Anything shown for the old text goes, and a
    /// proactive check is scheduled for when typing stops.
    func edited(_ item: LineItem, heading: String) {
        let input = Input(item, heading: heading)
        guard inputs[item.id] != input else { return }
        inputs[item.id] = input
        dropStale(line: item.id, keeping: input)
        // Whatever was showing belonged to the old text -- a suggestion, a
        // failure, or progress on a check whose answer will now be discarded.
        states[item.id] = nil

        timers[item.id]?.cancel()
        guard canSuggest, isProactive(), input.isWorthAsking else { return }
        timers[item.id] = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.enqueue(line: item.id, input: input, manual: false, force: false)
        }
    }

    /// Focus left the line: the user is done with it, so don't wait out the
    /// pause -- but only if there is an edit still waiting to be checked.
    func finishedEditing(_ item: LineItem, heading: String) {
        guard let timer = timers[item.id] else { return }
        timer.cancel()
        timers[item.id] = nil
        let input = Input(item, heading: heading)
        guard canSuggest, isProactive(), input.isWorthAsking, inputs[item.id] == input else { return }
        enqueue(line: item.id, input: input, manual: false, force: false)
    }

    /// The user asked: from the line's menu, or by reviewing the whole list.
    func request(_ item: LineItem, heading: String, force: Bool = false, quietIfClear: Bool = false) {
        let input = Input(item, heading: heading)
        inputs[item.id] = input
        timers[item.id]?.cancel()
        timers[item.id] = nil
        guard isEnabled() else {
            states[item.id] = .failed("Turn on the on-device assist in Settings to tidy wording.")
            return
        }
        let readiness = isAvailable()
        guard readiness == .ready else {
            states[item.id] = .failed(readiness.explanation ?? "The on-device model isn't available.")
            return
        }
        guard !input.title.trimmingCharacters(in: .whitespaces).isEmpty else {
            states[item.id] = .failed("Type a name for this line first.")
            return
        }
        dismissed.remove(input)
        enqueue(line: item.id, input: input, manual: true, force: force, quietIfClear: quietIfClear)
    }

    /// Reviews every line, one after another. Lines that already read well
    /// stay quiet: "already clear" is an answer to a question about one line,
    /// and under every line of a review it would just be noise.
    func reviewAll(_ items: [LineItem], heading: String) {
        for item in items where !item.title.trimmingCharacters(in: .whitespaces).isEmpty {
            request(item, heading: heading, quietIfClear: true)
        }
    }

    /// Hands the suggestion to the caller to write, and clears it. Returns nil
    /// if the line has changed since -- a suggestion is never applied to text
    /// it wasn't made for.
    func apply(_ item: LineItem, heading: String) -> OnDeviceAssist.Proposal? {
        guard case .suggestion(let proposal) = state(for: item.id),
              inputs[item.id] == Input(item, heading: heading) else { return nil }
        states[item.id] = nil
        // The applied text is the new input; it needs no checking.
        let applied = Input(title: proposal.title, details: proposal.details, heading: heading)
        inputs[item.id] = applied
        cache[applied] = proposal
        return proposal
    }

    func dismiss(_ line: UUID) {
        if let input = inputs[line] { dismissed.insert(input) }
        states[line] = nil
    }

    func forget(_ line: UUID) {
        timers[line]?.cancel()
        timers[line] = nil
        queue.removeAll { $0.line == line }
        inputs[line] = nil
        states[line] = nil
    }

    // MARK: - The queue

    private func enqueue(line: UUID, input: Input, manual: Bool, force: Bool, quietIfClear: Bool = false) {
        if !force, let cached = cache[input] {
            show(cached, for: line, input: input, manual: manual, quietIfClear: quietIfClear)
            return
        }
        if !manual, dismissed.contains(input) { return }
        // Already asking this exact question: a manual request just makes the
        // pending one visible instead of asking twice.
        if let running, running.line == line, running.input == input, !force {
            if manual { states[line] = .working(manual: true) }
            return
        }
        queue.removeAll { $0.line == line }
        queue.append((line, input, manual, force, quietIfClear))
        if manual { states[line] = .working(manual: true) }
        pump()
    }

    private func pump() {
        guard running == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        running = (next.line, next.input)
        if !next.manual { states[next.line] = .working(manual: false) }
        calls += 1
        worker = Task { [weak self, tidy] in
            let result: Result<OnDeviceAssist.Proposal, Error>
            do { result = .success(try await tidy(next.input.title, next.input.details, next.input.heading)) }
            catch { result = .failure(error) }
            self?.finish(next.line, next.input, manual: next.manual, quietIfClear: next.quietIfClear, result)
        }
    }

    private func finish(_ line: UUID, _ input: Input, manual: Bool, quietIfClear: Bool,
                        _ result: Result<OnDeviceAssist.Proposal, Error>) {
        running = nil
        defer { pump() }
        // The line changed while the model was thinking: this answer is for
        // text that no longer exists.
        guard inputs[line] == input else { return }
        switch result {
        case .success(let proposal):
            cache[input] = proposal
            show(proposal, for: line, input: input, manual: manual, quietIfClear: quietIfClear)
        case .failure(let error):
            states[line] = manual ? .failed(error.localizedDescription) : nil
        }
    }

    private func show(_ proposal: OnDeviceAssist.Proposal, for line: UUID, input: Input, manual: Bool,
                      quietIfClear: Bool = false) {
        let changes = proposal.title != input.title || proposal.details != input.details
        if changes, manual || !dismissed.contains(input) {
            states[line] = .suggestion(proposal)
            if manual { announce("Wording suggestion ready") }
        } else {
            states[line] = manual && !quietIfClear ? .alreadyClear : nil
        }
    }

    /// Queued work for this line's old text goes; a running request for it is
    /// left to finish and discarded on arrival (the model call itself can't be
    /// interrupted mid-generation, so cancelling would only lose the slot).
    private func dropStale(line: UUID, keeping input: Input) {
        queue.removeAll { $0.line == line && $0.input != input }
    }

    private func announce(_ message: String) {
        if #available(macOS 14.0, *) {
            AccessibilityNotification.Announcement(message).post()
        }
    }
}
