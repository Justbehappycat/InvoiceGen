import SwiftUI
import AppKit

/// `--selftest-ui`: the interface's regression suite.
///
/// Two kinds of check. Pure ones need no window: badge contrast measured
/// against this Mac's real selection colours, and the preview's zoom maths.
/// Window ones host the real ContentView offscreen in each major
/// configuration and inspect it through the accessibility tree -- the same
/// tree VoiceOver reads -- rather than by pixels, because pixels from an
/// offscreen window lie about materials and selection, while the tree's
/// names, help text and frames don't.
///
/// It runs in UI-check mode on an in-memory fixture: the Keychain is never
/// touched, nothing is saved, and the user's window-state preferences are
/// put back afterwards.
///
/// `--selftest-ui <dir>` also writes a PNG of each configuration to <dir>,
/// for looking at layout by eye.
enum UIRegression {
    private static var failures = 0
    private static var snapshotDirectory: String?

    private static func check(_ label: String, _ ok: Bool, _ detail: String = "") {
        print("  \(ok ? "ok  " : "FAIL") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
        if !ok { failures += 1 }
    }

    @MainActor
    static func run(snapshotDirectory: String?) -> Int32 {
        Self.snapshotDirectory = snapshotDirectory
        print("status badge contrast (WCAG AA, 4.5:1):")
        badgeContrast()
        print("preview zoom:")
        zoomMaths()

        let restore = UIShot.preservingWindowState()
        defer { restore() }
        installFixture()

        for config in configurations {
            print("\(config):")
            let (window, _) = UIShot.host(config)
            if let dir = snapshotDirectory {
                let name = config.name.replacingOccurrences(of: " ", with: "-")
                UIShot.writePNG(of: window, to: "\(dir)/\(name).png")
            }
            audit(window, config)
            window.orderOut(nil)
        }

        print(failures == 0 ? "all UI checks passed" : "\(failures) UI checks FAILED")
        return failures == 0 ? 0 : 1
    }

    // MARK: - Configurations

    static let configurations: [UIShot.Configuration] = [
        .init(name: "laptop", width: 1340, height: 900),
        .init(name: "wide", width: 1680, height: 1050),
        .init(name: "minimum", width: 1120, height: 800),
        .init(name: "dark", width: 1340, height: 900, dark: true),
        .init(name: "no preview", width: 1340, height: 900, preview: false),
        .init(name: "narrow no preview", width: 900, height: 800, preview: false),
        .init(name: "wide no preview", width: 1920, height: 1080, preview: false),
        .init(name: "fit page", width: 1340, height: 900, zoom: .fitPage),
        .init(name: "bulk", width: 1340, height: 900, selection: .multiple),
        .init(name: "trashed", width: 1340, height: 900, selection: .trashed),
        .init(name: "projects", width: 1340, height: 900, section: .projects),
    ]

    // MARK: - Fixture

    /// Every status, an overdue invoice, a trashed one, a long address and a
    /// project -- the states the layout has to survive. Lives only in memory.
    @MainActor
    private static func installFixture() {
        let store = AppStore.shared
        var data = AppData.seeded()
        var customer = Customer()
        customer.name = "Lantern Road Media"
        customer.contactName = "Dana Whitfield"
        customer.email = "accounts@example.com"
        customer.addressLine1 = "Building C, 1180 Mission Street, Suite 400 (Loading dock entrance on 8th)"
        customer.city = "San Francisco"; customer.region = "CA"; customer.postalCode = "94103"
        data.customers = [customer]

        func invoice(_ number: String, _ status: InvoiceStatus, dueIn days: Int, trashed: Bool = false) -> Invoice {
            var i = Invoice()
            i.number = number
            i.customerID = customer.id
            i.status = status
            i.issueDate = Calendar.current.date(byAdding: .day, value: days - 30, to: Date())!
            i.dueDate = Calendar.current.date(byAdding: .day, value: days, to: Date())!
            i.items = [LineItem(title: "Episode \(number)", details: "Long x1, Short x1, Reel x1 + VFX graphic package",
                                quantity: 1, price: 150, taxable: false)]
            if status == .paid { i.amountPaid = i.total }
            if trashed { i.deletedAt = Date() }
            return i
        }
        var project = Project()
        project.name = "Night Shift — S1"
        project.customerID = customer.id
        project.contractTotal = 1200
        var first = invoice("12", .sent, dueIn: -5)      // overdue
        first.projectID = project.id
        first.items += [
            LineItem(title: "Colour grade", details: "Per finished minute", quantity: 12, price: 200, taxable: false),
            LineItem(title: "Additional revision round",
                     details: "Round three of notes from the client, covering the opening titles, a recut of the "
                            + "interview section, music swaps in acts two and three, and a new end card.\n"
                            + "Agreed by email on 14 October.",
                     quantity: 1, price: 150, taxable: false),
            LineItem(title: "Hard drive", details: "4TB SSD, delivered with masters", quantity: 1, price: 289, taxable: true),
            LineItem(title: "gfx pkg", details: "lower thirds + endcard", quantity: 1, price: 400, taxable: false),
        ]
        data.projects = [project]
        data.invoices = [first, invoice("13", .draft, dueIn: 20), invoice("14", .paid, dueIn: 10),
                         invoice("15", .sent, dueIn: 15, trashed: true)]
        store.data = data
    }

    // MARK: - Pure checks

    /// Re-measures the badge palette against the selection colours this Mac is
    /// actually using -- so an unusual accent colour fails here, not in use.
    private static func badgeContrast() {
        for (look, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let app = NSAppearance(named: look)!
            func rgb(_ c: NSColor) -> [Double] {
                var out = [0.0, 0.0, 0.0]
                app.performAsCurrentDrawingAppearance {
                    let s = c.usingColorSpace(.sRGB)!
                    out = [Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent)]
                }
                return out
            }
            let rows: [(String, [Double])] = [
                ("unselected", rgb(.controlBackgroundColor)),
                ("selected, unfocused or inactive", rgb(.unemphasizedSelectedContentBackgroundColor)),
            ]
            for tone in StatusTone.allCases {
                let t = name == "dark" ? tone.darkText : tone.lightText
                let text = [Double(t.r), Double(t.g), Double(t.b)].map { $0 / 255 }
                let hue = rgb(tone.hue)
                let worst = rows.map { _, row in
                    contrast(text, mix(row, hue, StatusTone.fillOpacity))
                }.min()!
                check("\(name) \(tone) badge on plain and unfocused rows: \(fmt(worst))", worst >= 4.5)
            }
            let accent = rgb(.selectedContentBackgroundColor)
            let onAccent = contrast([1, 1, 1], accent)
            check("\(name) badges on the focused selection (white on accent): \(fmt(onAccent))", onAccent >= 4.5)
        }
    }

    private static func zoomMaths() {
        let page = CGSize(width: 612, height: 792)
        let canvas = CGSize(width: 660, height: 600)
        let width = PreviewZoom.fitWidth.scale(in: canvas, page: page)
        let fit = PreviewZoom.fitPage.scale(in: canvas, page: page)
        check("fit width fills the width", abs(width - (660 - 48) / 612) < 0.001)
        check("fit page fits the height when that is tighter", abs(fit - (600 - 48) / 792) < 0.001)
        check("fit page never exceeds fit width", fit <= width)
        check("a fixed zoom is honoured", PreviewZoom.fixed(1.25).scale(in: canvas, page: page) == 1.25)
        check("zoom is clamped at 300%", PreviewZoom.fixed(9).scale(in: canvas, page: page) == 3)
        check("+ steps from 81% to 100%", PreviewZoom.fitWidth.zoomed(in: true, from: 0.81) == .fixed(1.0))
        check("− steps from 100% to 75%", PreviewZoom.fixed(1).zoomed(in: false, from: 1.0) == .fixed(0.75))
        check("− bottoms out at 25%", PreviewZoom.fixed(0.25).zoomed(in: false, from: 0.25) == .fixed(0.25))
        for zoom in [PreviewZoom.fitWidth, .fitPage, .fixed(1.5)] {
            check("\(zoom) survives being stored", PreviewZoom(storage: zoom.storage) == zoom)
        }
        check("a corrupt stored zoom falls back to fit width", PreviewZoom(storage: "banana") == .fitWidth)
    }

    // MARK: - Window audit

    /// What VoiceOver can reach in one window.
    struct Node {
        let role: String
        let name: String
        let help: String
        let identifier: String
        let frame: NSRect
        let value: String
        let subrole: String
    }

    /// Controls whose only visible content is an icon. Each must have a
    /// tooltip as well as a name, or a sighted mouse user has nothing to go on.
    static let iconOnly: Set<String> = [
        "New Invoice", "New customer", "Line actions", "Reuse", "Preview", "Share", "Shared", "Print",
        "Fit page", "Fit width", "Zoom out", "Zoom in", "Columns",
    ]

    @MainActor
    private static func audit(_ window: NSWindow, _ config: UIShot.Configuration) {
        let nodes = readAccessibilityTree()
        // The window's own buttons and the date fields' stepper arrows are
        // AppKit parts that VoiceOver announces by role; they aren't ours to name.
        let windowWidgets: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton",
                                          "AXFullScreenButton", "AXIncrementArrow", "AXDecrementArrow",
                                          "AXIncrementPage", "AXDecrementPage"]
        let controls = nodes.filter { !windowWidgets.contains($0.subrole) }.filter {
            ["AXButton", "AXMenuButton", "AXCheckBox", "AXPopUpButton", "AXRadioButton",
             "AXTextField", "AXDateField", "AXComboBox", "AXSlider"].contains($0.role)
        }
        check("accessibility tree reached (\(controls.count) controls)", controls.count > 10)

        // Text fields are named by their own content or placeholder; the rest
        // need a name of their own.
        let unnamed = controls.filter {
            $0.name.isEmpty && !["AXTextField", "AXDateField", "AXComboBox"].contains($0.role)
                && $0.identifier.isEmpty
        }
        check("every control has a VoiceOver name", unnamed.isEmpty,
              unnamed.prefix(8).map { "\($0.role)/\($0.subrole) at \(Int($0.frame.minX)),\(Int($0.frame.minY))" }
                .joined(separator: "; "))

        let iconControls = controls.filter { node in iconOnly.contains { node.name.hasPrefix($0) } }
        let silent = iconControls.filter { $0.help.isEmpty }
        check("icon-only controls have tooltips (\(iconControls.count) found)", silent.isEmpty,
              silent.map(\.name).joined(separator: ", "))

        let showsEditor = config.section == .invoices && config.selection != .multiple
        if showsEditor {
            check("Export PDF is in the toolbar with its label",
                  controls.contains { $0.name == "Export PDF" })

            if let number = nodes.first(where: { $0.role == "AXStaticText" && $0.name == "Invoice number" }),
               let po = nodes.first(where: { $0.role == "AXStaticText" && $0.name == "P.O./S.O." }) {
                check("Details is two columns (P.O. beside invoice number)",
                      abs(number.frame.midY - po.frame.midY) < 4 && po.frame.minX > number.frame.maxX)
            } else {
                check("Details labels found", false)
            }

            func pane(_ id: String) -> Node? {
                nodes.filter { $0.identifier == id }.max { $0.frame.width < $1.frame.width }
            }
            if let editor = pane("invoice-editor") {
                check("editor keeps its 520pt minimum (\(Int(editor.frame.width)))", editor.frame.width >= 519)
            } else {
                check("editor pane found", false)
            }
            let preview = pane("invoice-preview")
            if config.preview {
                if let preview {
                    check("preview keeps its 360pt minimum (\(Int(preview.frame.width)))",
                          preview.frame.width >= 359)
                    check("zoom control present",
                          controls.contains { $0.name == "Fit page" } && controls.contains { $0.name == "Zoom in" })
                } else {
                    check("preview pane found", false)
                }
            } else {
                check("preview hidden when turned off", preview == nil)
                // The column caps and centres once the pane is wider than the cap.
                if let editor = pane("invoice-editor"),
                   let left = nodes.first(where: { $0.role == "AXStaticText" && $0.name == "Invoice number" }),
                   let right = controls.first(where: { $0.name == "Columns" }) {
                    let width = right.frame.maxX - left.frame.minX
                    let limit = Metrics.editorMaxWidth - 2 * Metrics.gutter
                    check("content no wider than the cap (\(Int(width)) ≤ \(Int(limit)))", width <= limit + 1)
                    if editor.frame.width > Metrics.editorMaxWidth + 40 {
                        let leftMargin = left.frame.minX - editor.frame.minX
                        let rightMargin = editor.frame.maxX - right.frame.maxX
                        check("content centred (margins \(Int(leftMargin)) / \(Int(rightMargin)))",
                              abs(leftMargin - rightMargin) < 24)
                    }
                    // Every item field stays inside the column, so quantity,
                    // price and amount sit with the item they belong to.
                    let itemFields = controls.filter {
                        $0.role == "AXTextField" && $0.frame.minY > right.frame.maxY
                            && $0.frame.minX >= left.frame.minX - 2
                    }
                    let spill = itemFields.filter { $0.frame.maxX > right.frame.maxX + 2 }
                    check("item fields stay within the column (\(itemFields.count) checked)", spill.isEmpty,
                          spill.prefix(3).map { "\(Int($0.frame.minX))–\(Int($0.frame.maxX))" }.joined(separator: ", "))
                }
            }
        }

        // The primary action is reachable whatever is showing.
        check("New Invoice is in the toolbar", controls.contains { $0.name == "New Invoice" })

        if config.name == "laptop" {
            // Key within this process only -- never activating the app, which
            // would take the screen from whoever is using it.
            window.makeKey()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            focusSurvivesPreviewToggle()
            suggestionsAreInlineAndNeedAcceptance()
        }

        if config.selection == .trashed {
            check("trashed invoice offers Put Back", controls.contains { $0.name == "Put Back" })
        }
        if config.section == .projects {
            check("projects list reachable", nodes.contains { $0.name.contains("Night Shift") })
        }
    }

    /// Reads the window the way VoiceOver does: through the accessibility
    /// API, as a client. SwiftUI builds its tree only for a client that asks,
    /// so walking NSAccessibility in process sees an empty host view.
    ///
    /// On the main thread, deliberately. A process querying itself is answered
    /// on the calling thread, so asking from a background thread drives AppKit
    /// off the main thread -- it warns about the layout engine and corrupts
    /// later reads. It works here because launching has finished first.
    @MainActor
    private static func readAccessibilityTree() -> [Node] {
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 5)
        // Tells SwiftUI an assistive client is here, so it builds the tree.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        var nodes: [Node] = []
        if let windows = copy(app, kAXWindowsAttribute) as? [AXUIElement] {
            // The newest window is the configuration under test.
            for window in windows where nodes.isEmpty || copy(window, kAXMainAttribute) as? Bool == true {
                var found: [Node] = []
                walk(window, depth: 0, into: &found)
                if found.count > nodes.count { nodes = found }
            }
        }
        return nodes
    }

    /// Puts the caret in the invoice-number field, presses the toolbar's
    /// Preview toggle twice, and checks the caret never left the field.
    @MainActor
    private static func focusSurvivesPreviewToggle() {
        let app = AXUIElementCreateApplication(getpid())
        guard let window = (copy(app, kAXWindowsAttribute) as? [AXUIElement])?.first,
              let number = find(in: window, { role, _, value in role == "AXTextField" && value == "12" }),
              let toggle = find(in: window, { role, name, _ in role == "AXCheckBox" && name == "Preview" })
        else { check("focus test could find its field and the Preview toggle", false); return }

        AXUIElementSetAttributeValue(number, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        func focusedIsNumber() -> Bool {
            guard let focused = copy(app, kAXFocusedUIElementAttribute) else { return false }
            let f = focused as! AXUIElement
            return (copy(f, kAXRoleAttribute) as? String) == "AXTextField"
                && (copy(f, kAXValueAttribute) as? String) == "12"
        }
        let before = focusedIsNumber()
        check("caret placed in the invoice number", before)
        guard before else { return }
        for _ in 0..<2 {
            AXUIElementPerformAction(toggle, kAXPressAction as CFString)
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        }
        check("hiding and showing the preview keeps the caret in place", focusedIsNumber())
    }

    /// End to end, with the real on-device model: Review wording puts a
    /// suggestion under the line -- no sheet, no dialog -- names its buttons,
    /// changes nothing until Apply, and Apply writes it.
    @MainActor
    private static func suggestionsAreInlineAndNeedAcceptance() {
        guard OnDeviceAssist.isReady,
              UserDefaults.standard.object(forKey: "onDeviceAssist") as? Bool ?? true else {
            print("  (no on-device model here — skipping the live suggestion check)")
            return
        }
        let app = AXUIElementCreateApplication(getpid())
        guard let window = (copy(app, kAXWindowsAttribute) as? [AXUIElement])?.first,
              let review = find(in: window, { role, name, _ in role == "AXButton" && name == "Review wording" })
        else { check("Review wording is in the Items header", false); return }
        check("Review wording is in the Items header", true)

        let invoiceID = AppStore.shared.data.invoices[0].id
        func itemTitles() -> [String] { AppStore.shared.invoice(id: invoiceID)?.items.map(\.title) ?? [] }
        func itemFigures() -> [String] {
            AppStore.shared.invoice(id: invoiceID)?.items.map { "\($0.quantity)×\($0.price)" } ?? []
        }
        let before = itemTitles()
        let figuresBefore = itemFigures()

        AXUIElementPerformAction(review, kAXPressAction as CFString)
        var apply: AXUIElement?
        let deadline = Date().addingTimeInterval(60)
        while apply == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            apply = find(in: window, { role, name, _ in role == "AXButton" && name == "Apply suggestion" })
        }
        guard let apply else { check("a suggestion arrived within 60s", false); return }
        check("a suggestion arrived inline", true)
        if let dir = snapshotDirectory, let window = NSApp.windows.first(where: { $0.isVisible }) {
            UIShot.writePNG(of: window, to: "\(dir)/suggestion.png")
        }

        let windows = (copy(app, kAXWindowsAttribute) as? [AXUIElement])?.count ?? 0
        let sheet = find(in: window, { role, _, _ in role == "AXSheet" })
        check("no sheet or dialog was opened", windows == 1 && sheet == nil)
        check("Regenerate and Dismiss are named for VoiceOver",
              find(in: window, { r, n, _ in r == "AXButton" && n == "Regenerate suggestion" }) != nil
                  && find(in: window, { r, n, _ in r == "AXButton" && n == "Dismiss suggestion" }) != nil)
        check("nothing in the invoice changed before Apply", itemTitles() == before, "\(itemTitles())")

        AXUIElementPerformAction(apply, kAXPressAction as CFString)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let after = itemTitles()
        let changed = zip(before, after).filter { $0 != $1 }
        check("Apply rewrote exactly one line", changed.count == 1, "\(changed)")
        check("and left every quantity and price alone", itemFigures() == figuresBefore,
              "\(figuresBefore) → \(itemFigures())")
    }

    private static func find(in element: AXUIElement, depth: Int = 0,
                             _ match: (String, String, String) -> Bool) -> AXUIElement? {
        guard depth < 60 else { return nil }
        let role = copy(element, kAXRoleAttribute) as? String ?? ""
        var name = copy(element, kAXDescriptionAttribute) as? String ?? ""
        if name.isEmpty { name = copy(element, kAXTitleAttribute) as? String ?? "" }
        let value = copy(element, kAXValueAttribute).map { "\($0)" } ?? ""
        if match(role, name, value) { return element }
        for child in copy(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let hit = find(in: child, depth: depth + 1, match) { return hit }
        }
        return nil
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private static func walk(_ element: AXUIElement, depth: Int, into nodes: inout [Node]) {
        guard depth < 60 else { return }
        func text(_ attribute: String) -> String { copy(element, attribute) as? String ?? "" }
        var frame = NSRect.zero
        if let p = copy(element, kAXPositionAttribute), let z = copy(element, kAXSizeAttribute) {
            var point = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(p as! AXValue, .cgPoint, &point)
            AXValueGetValue(z as! AXValue, .cgSize, &size)
            frame = NSRect(origin: point, size: size)
        }
        // VoiceOver speaks the description for an icon button and the title
        // for a text one; either counts as a name.
        let role = text(kAXRoleAttribute)
        let value = copy(element, kAXValueAttribute).map { "\($0)" } ?? ""
        var name = text(kAXDescriptionAttribute)
        if name.isEmpty { name = text(kAXTitleAttribute) }
        // Static text has no title; its words are its value.
        if name.isEmpty, role == kAXStaticTextRole as String { name = value }
        nodes.append(Node(role: role, name: name, help: text(kAXHelpAttribute),
                          identifier: text("AXIdentifier"), frame: frame, value: value,
                          subrole: text(kAXSubroleAttribute)))
        guard let children = copy(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for child in children { walk(child, depth: depth + 1, into: &nodes) }
    }

    // MARK: - Colour maths

    private static func mix(_ under: [Double], _ over: [Double], _ alpha: Double) -> [Double] {
        zip(under, over).map { $0 * (1 - alpha) + $1 * alpha }
    }

    private static func contrast(_ a: [Double], _ b: [Double]) -> Double {
        func lum(_ c: [Double]) -> Double {
            let l = c.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2]
        }
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.2f:1", v) }
}
