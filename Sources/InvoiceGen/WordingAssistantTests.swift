import Foundation

/// `--selftest-wording`: the suggestion coordinator's rules, checked with a
/// stand-in for the model so every timing question has an exact answer.
enum WordingAssistantTests {
    private static var failures = 0

    private static func check(_ label: String, _ ok: Bool, _ detail: String = "") {
        print("  \(ok ? "ok  " : "FAIL") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
        if !ok { failures += 1 }
    }

    /// A model that answers "Tidy: <title>", records what it was asked, and
    /// tracks how many questions were in flight at once.
    @MainActor
    final class FakeModel {
        var asked: [String] = []
        var inFlight = 0
        var maxInFlight = 0
        var delay: Duration = .milliseconds(30)
        var reply: (String, String) throws -> OnDeviceAssist.Proposal = { title, details in
            OnDeviceAssist.Proposal(title: "Tidy: " + title, details: details)
        }

        func tidy(_ title: String, _ details: String) async throws -> OnDeviceAssist.Proposal {
            asked.append(title)
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            defer { inFlight -= 1 }
            try? await Task.sleep(for: delay)
            return try reply(title, details)
        }
    }

    @MainActor
    private static func make(_ model: FakeModel, proactive: Bool = true,
                             readiness: OnDeviceAssist.Readiness = .ready) -> WordingAssistant {
        let assistant = WordingAssistant { title, details, _ in try await model.tidy(title, details) }
        assistant.isEnabled = { true }
        assistant.isProactive = { proactive }
        assistant.isAvailable = { readiness }
        assistant.debounce = .milliseconds(150)
        return assistant
    }

    @MainActor
    private static func settle(_ seconds: Double = 0.5) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private static func line(_ title: String, _ details: String = "", id: UUID = UUID()) -> LineItem {
        var item = LineItem()
        item.id = id
        item.title = title
        item.details = details
        return item
    }

    @MainActor
    static func run() -> Int32 {
        print("asks after a pause, not per keystroke:")
        do {
            let model = FakeModel(); let w = make(model); let id = UUID()
            for typed in ["ep1", "ep1 e", "ep1 ed", "ep1 edit"] { w.edited(line(typed, id: id), heading: "Item") }
            settle()
            check("four keystrokes, one question", model.asked.count == 1, "\(model.asked)")
            check("and it was about the final text", model.asked.last == "ep1 edit")
            check("the suggestion appears", w.state(for: id) == .suggestion(.init(title: "Tidy: ep1 edit", details: "")))
            let short = UUID(); w.edited(line("ab", id: short), heading: "Item"); settle()
            check("two characters isn't worth asking about", model.asked.count == 1)
        }

        print("finishing a line asks at once:")
        do {
            let model = FakeModel(); let w = make(model); w.debounce = .seconds(30)
            let item = line("ep2 edit")
            w.edited(item, heading: "Item")
            settle(0.1)
            check("not yet: the pause hasn't passed", model.asked.isEmpty)
            w.finishedEditing(item, heading: "Item")
            settle(0.3)
            check("leaving the line asks without waiting", model.asked == ["ep2 edit"])
        }

        print("never answers a stale question:")
        do {
            let model = FakeModel(); model.delay = .milliseconds(400)
            let w = make(model, proactive: false); let id = UUID()
            w.request(line("ep3 edit", id: id), heading: "Item")
            settle(0.1)
            check("shows progress for a request the user made", w.state(for: id) == .working(manual: true))
            w.edited(line("ep3 edit + grade", id: id), heading: "Item")
            settle(0.6)
            check("the answer for the old text is discarded", w.state(for: id) == .idle)
            check("and the edit didn't trigger another (proactive off)", model.asked.count == 1)
        }

        print("doesn't ask the same question twice:")
        do {
            let model = FakeModel(); let w = make(model, proactive: false); let item = line("ep4 edit")
            w.request(item, heading: "Item"); settle(0.2)
            w.dismiss(item.id)
            w.request(item, heading: "Item"); settle(0.2)
            check("the same text is answered from memory", model.asked.count == 1)
            check("and still shown", w.state(for: item.id) == .suggestion(.init(title: "Tidy: ep4 edit", details: "")))
            w.request(item, heading: "Item", force: true); settle(0.2)
            check("Regenerate asks again", model.asked.count == 2)
            w.request(item, heading: "Item"); w.request(item, heading: "Item"); w.request(item, heading: "Item")
            settle(0.2)
            check("repeated presses while answered don't queue more", model.asked.count == 2)
        }

        print("a dismissed suggestion isn't offered again:")
        do {
            let model = FakeModel(); let w = make(model); let id = UUID()
            w.edited(line("ep5 edit", id: id), heading: "Item"); settle()
            w.dismiss(id)
            w.edited(line("ep5 edit!", id: id), heading: "Item")
            w.edited(line("ep5 edit", id: id), heading: "Item"); settle()
            check("typing back to the same text stays quiet", w.state(for: id) == .idle)
            w.request(line("ep5 edit", id: id), heading: "Item"); settle(0.2)
            check("but asking for it shows it", w.state(for: id) == .suggestion(.init(title: "Tidy: ep5 edit", details: "")))
        }

        print("only says something worth saying:")
        do {
            let model = FakeModel(); model.reply = { t, d in .init(title: t, details: d) }
            let w = make(model); let id = UUID()
            w.edited(line("Commercial Edit", id: id), heading: "Item"); settle()
            check("proactive: already clear, so nothing shown", w.state(for: id) == .idle)
            let asked = UUID()
            w.request(line("Colour Grade", id: asked), heading: "Item"); settle(0.2)
            check("asked: says it already reads clearly", w.state(for: asked) == .alreadyClear)

            model.reply = { _, _ in throw OnDeviceAssist.Failure.changedNumbers }
            let quiet = UUID(), loud = UUID()
            w.edited(line("ep6 edit", id: quiet), heading: "Item"); settle()
            check("proactive failure stays silent", w.state(for: quiet) == .idle)
            w.request(line("ep7 edit", id: loud), heading: "Item"); settle(0.2)
            check("asked failure says why", {
                if case .failed(let why) = w.state(for: loud) { return why.contains("number") } else { return false }
            }())
        }

        print("one question at a time:")
        do {
            let model = FakeModel(); model.delay = .milliseconds(120)
            let w = make(model, proactive: false)
            let items = [line("ep8 edit"), line("ep9 edit"), line("ep10 edit"), line("")]
            w.reviewAll(items, heading: "Item")
            settle(1.0)
            check("every named line reviewed", model.asked.count == 3, "\(model.asked)")
            check("never more than one in flight", model.maxInFlight == 1, "max \(model.maxInFlight)")
            check("every line got its own suggestion",
                  items.prefix(3).allSatisfy { if case .suggestion = w.state(for: $0.id) { return true }; return false })

            model.reply = { t, d in .init(title: t, details: d) }
            let clean = line("Colour Grade")
            w.reviewAll([clean], heading: "Item"); settle(0.3)
            check("a review stays quiet about lines that already read well", w.state(for: clean.id) == .idle)
        }

        print("applies only on acceptance, and only to the text it was for:")
        do {
            let model = FakeModel(); let w = make(model, proactive: false); let id = UUID()
            let original = line("ep11 edit", id: id)
            w.request(original, heading: "Item"); settle(0.2)
            check("a suggestion alone changes nothing", original.title == "ep11 edit")
            let changed = line("ep11 edit, recut", id: id)
            check("not applied to text that has changed since", w.apply(changed, heading: "Item") == nil)
            w.request(original, heading: "Item"); settle(0.2)
            let accepted = w.apply(original, heading: "Item")
            check("Apply hands the suggestion over", accepted?.title == "Tidy: ep11 edit")
            check("and clears it", w.state(for: id) == .idle)
            var written = original
            written.title = accepted?.title ?? ""
            w.edited(written, heading: "Item"); settle()
            check("the applied text isn't sent back to be checked", model.asked.count == 1)
        }

        print("unavailable or switched off:")
        do {
            let model = FakeModel(); let w = make(model, readiness: .appleIntelligenceOff); let id = UUID()
            w.edited(line("ep12 edit", id: id), heading: "Item"); settle()
            check("proactive does nothing", model.asked.isEmpty && w.state(for: id) == .idle)
            w.request(line("ep12 edit", id: id), heading: "Item")
            check("asking explains why", {
                if case .failed(let why) = w.state(for: id) { return why.contains("Apple Intelligence") } else { return false }
            }())
            let off = FakeModel(); let w2 = make(off, proactive: false); let id2 = UUID()
            w2.edited(line("ep13 edit", id: id2), heading: "Item"); settle()
            check("proactive switched off: edits ask nothing", off.asked.isEmpty)
            w2.request(line("ep13 edit", id: id2), heading: "Item"); settle(0.2)
            check("but asking still works", off.asked == ["ep13 edit"])
        }

        print(failures == 0 ? "all wording checks passed" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}
