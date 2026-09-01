import SwiftUI
import AppKit
import PDFKit

/// Headless flags render straight after launch, when the vault is still
/// opening in the background — they have to wait for it or they would print an
/// invoice with no payment details on it.
@MainActor
private func waitForSecrets(_ store: AppStore, timeout: TimeInterval = 20) {
    let deadline = Date().addingTimeInterval(timeout)
    while !store.secretsLoaded, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}

@main
struct InvoiceGenApp: App {
    @StateObject private var store = AppStore.shared
    @StateObject private var focus = AppFocus()

    init() {
        // Headless render used for checking PDF output: InvoiceGen --render-sample out.pdf
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--render-ui"), index + 1 < args.count {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            let width = args.count > index + 2 ? Double(args[index + 2]) ?? 1320 : 1320
            let height = args.count > index + 3 ? Double(args[index + 3]) ?? 860 : 860
            let screen = args.count > index + 4 ? args[index + 4] : "invoices"
            MainActor.assumeIsolated {
                UIShot.capture(path: args[index + 1], width: width, height: height, screen: screen)
            }
            exit(0)
        }
        if let index = args.firstIndex(of: "--show-settings") {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            MainActor.assumeIsolated {
                let store = AppStore.shared
                SettingsWindowController.shared.show(store: store, focus: AppFocus())
                RunLoop.current.run(until: Date().addingTimeInterval(2.0))
                let windows = NSApp.windows
                print("windows: \(windows.count)")
                for window in windows {
                    print("  title=\(window.title) visible=\(window.isVisible) frame=\(window.frame)")
                }
                if index + 1 < args.count, let content = windows.first(where: { $0.title == "Settings" })?.contentView,
                   let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: args[index + 1]))
                    print("captured")
                }
            }
            exit(0)
        }
        if args.contains("--profile") {
            setvbuf(stdout, nil, _IONBF, 0)
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            MainActor.assumeIsolated {
                func line(_ label: String, _ milliseconds: Double, _ suffix: String = "") {
                    let padded = label.padding(toLength: 38, withPad: " ", startingAt: 0)
                    print(padded + String(format: "%7.1f ms", milliseconds) + suffix)
                }
                func ms(_ label: String, repeats: Int = 1, _ work: () -> Void) {
                    let t0 = Date()
                    for _ in 0..<repeats { work() }
                    let total = Date().timeIntervalSince(t0) * 1000
                    line(label, total / Double(repeats), repeats > 1 ? " (avg of \(repeats))" : "")
                }

                for attempt in 1...4 {
                    let t0 = Date()
                    _ = Keychain.vaultKey()
                    line("keychain: fetch vault key #\(attempt)", Date().timeIntervalSince(t0) * 1000)
                }
                ms("vault: load + verify", repeats: 10) { _ = PaymentVault.shared.load() }

                let store = AppStore.shared
                ms("store: saveNow (vault + json)", repeats: 10) { store.saveNow() }

                if let data = store.data.business.logoData {
                    ms("logo: NSImage(data:) decode", repeats: 20) { _ = NSImage(data: data) }
                    if let image = NSImage(data: data) {
                        print("logo: size".padding(toLength: 38, withPad: " ", startingAt: 0)
                              + String(format: "%.0f x %.0f pt", image.size.width, image.size.height))
                        ms("logo: draw at 132x60", repeats: 20) {
                            let rep = NSBitmapImageRep(
                                bitmapDataPlanes: nil, pixelsWide: 264, pixelsHigh: 120,
                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                            )!
                            NSGraphicsContext.saveGraphicsState()
                            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                            image.draw(in: NSRect(x: 0, y: 0, width: 132, height: 60))
                            NSGraphicsContext.restoreGraphicsState()
                        }
                    }
                }

                guard let invoice = store.data.invoices.first else { exit(0) }
                let customer = store.customer(id: invoice.customerID)

                ms("paginate: cold cache") {
                    InvoicePaginator.clearCache()
                    _ = InvoicePaginator.pages(invoice: invoice, customer: customer, business: store.data.business)
                }
                ms("paginate: warm cache", repeats: 20) {
                    _ = InvoicePaginator.pages(invoice: invoice, customer: customer, business: store.data.business)
                }

                ms("render: one document page", repeats: 5) {
                    let view = InvoiceDocumentView(
                        invoice: invoice, customer: customer, business: store.data.business
                    )
                    let host = NSHostingView(rootView: view)
                    host.frame = CGRect(x: 0, y: 0, width: 612, height: 792)
                    host.layoutSubtreeIfNeeded()
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                    }
                }

                // Which part of the preview costs what: the same page drawn
                // four ways, each measured as a full redraw.
                do {
                    @MainActor func measureView(_ label: String, _ view: some View,
                                                width: CGFloat, height: CGFloat) {
                        let host = NSHostingView(rootView: AnyView(view))
                        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
                        let w = NSWindow(contentRect: host.frame, styleMask: [.titled],
                                         backing: .buffered, defer: false)
                        w.contentView = host
                        w.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
                        w.orderFrontRegardless()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                        ms(label, repeats: 5) {
                            host.setNeedsDisplay(host.bounds)
                            host.layoutSubtreeIfNeeded()
                            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                                host.cacheDisplay(in: host.bounds, to: rep)
                            }
                        }
                        w.orderOut(nil)
                    }

                    let scale: CGFloat = 0.75
                    let w = InvoiceDocumentView.pageWidth * scale
                    let h = InvoiceDocumentView.pageHeight * scale
                    let page = InvoiceDocumentView(
                        invoice: invoice, customer: customer, business: store.data.business
                    )
                    .frame(width: InvoiceDocumentView.pageWidth, height: InvoiceDocumentView.pageHeight)

                    measureView("page: scaled + shadow (current)",
                                page.scaleEffect(scale).frame(width: w, height: h)
                                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3),
                                width: w + 40, height: h + 40)
                    measureView("page: scaled, no shadow",
                                page.scaleEffect(scale).frame(width: w, height: h),
                                width: w + 40, height: h + 40)
                    measureView("page: unscaled, no shadow", page,
                                width: InvoiceDocumentView.pageWidth + 40,
                                height: InvoiceDocumentView.pageHeight + 40)

                    measureView("page: shadow on a backing rect (fix)",
                                page.scaleEffect(scale).frame(width: w, height: h)
                                    .background(Rectangle().fill(Color.white)
                                        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)),
                                width: w + 40, height: h + 40)

                }

                // Baseline: what cacheDisplay alone costs for a window this
                // size, so the numbers below are the app's own work.
                do {
                    let plain = NSHostingView(rootView: Color.blue.frame(width: 1440, height: 900))
                    plain.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
                    let w = NSWindow(contentRect: plain.frame, styleMask: [.titled], backing: .buffered, defer: false)
                    w.contentView = plain
                    w.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
                    w.orderFrontRegardless()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                    ms("baseline: plain window redraw", repeats: 5) {
                        plain.setNeedsDisplay(plain.bounds)
                        plain.layoutSubtreeIfNeeded()
                        if let rep = plain.bitmapImageRepForCachingDisplay(in: plain.bounds) {
                            plain.cacheDisplay(in: plain.bounds, to: rep)
                        }
                    }
                    w.orderOut(nil)
                }

                // The whole window, laid out and drawn the way an activation
                // redraw has to do it.
                let focus = AppFocus()
                focus.invoiceID = invoice.id
                let root = ContentView(initialSection: .invoices)
                    .environmentObject(store)
                    .environmentObject(focus)
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
                )
                let host = NSHostingView(rootView: root)
                host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
                window.contentView = host
                window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
                window.orderFrontRegardless()
                RunLoop.current.run(until: Date().addingTimeInterval(2.0))

                func redraw(_ label: String) {
                    ms(label, repeats: 5) {
                        host.setNeedsDisplay(host.bounds)
                        host.layoutSubtreeIfNeeded()
                        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                            host.cacheDisplay(in: host.bounds, to: rep)
                        }
                    }
                }
                redraw("window: redraw, preview shown")

                UserDefaults.standard.set(false, forKey: "showInvoicePreview")
                RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                redraw("window: redraw, preview hidden")
                UserDefaults.standard.set(true, forKey: "showInvoicePreview")
                RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                window.orderOut(nil)
            }
            exit(0)
        }
        if args.contains("--selftest-lazy-vault") {
            setvbuf(stdout, nil, _IONBF, 0)
            _ = NSApplication.shared
            MainActor.assumeIsolated {
                let vaultURL = PaymentVault.shared.vaultURL
                let before = try? Data(contentsOf: vaultURL)

                let t0 = Date()
                let store = AppStore.shared
                let initMS = Date().timeIntervalSince(t0) * 1000
                print(String(format: "store init: %.1f ms", initMS),
                      initMS < 100 ? "(vault is off the launch path)" : "— FAILED, still blocking")
                print("secrets loaded at init:", store.secretsLoaded ? "yes — FAILED" : "no, as expected")

                // Quitting before the vault opens must not touch it.
                store.saveNow()
                let afterEarlySave = try? Data(contentsOf: vaultURL)
                print("early save leaves vault untouched:",
                      before == afterEarlySave ? "yes" : "NO — FAILED")

                let deadline = Date().addingTimeInterval(20)
                while !store.secretsLoaded, Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
                print(String(format: "vault opened after: %.0f ms", Date().timeIntervalSince(t0) * 1000))
                print("status:", store.vaultStatus.message)
                print("business payment methods:", store.data.business.paymentMethods.count)
                print("undo stack stayed empty:", store.canUndo ? "NO — FAILED" : "yes")

                store.saveNow()
                if let raw = try? String(contentsOf: store.storageURL, encoding: .utf8) {
                    let leaked = store.data.business.paymentMethods
                        .flatMap { $0.fields.map { $0.value } }
                        .filter { $0.count > 3 && raw.contains($0) }
                    print("data.json still holds no payment values:",
                          leaked.isEmpty ? "yes" : "NO — FAILED \(leaked)")
                }
            }
            exit(0)
        }
        if args.contains("--diagnose-vault") {
            let hasKey = Keychain.vaultKey() != nil
            print("key available: \(hasKey), source: \(Keychain.keySource)")
            let vault = PaymentVault.shared
            let contents = vault.load()
            print("vault status: \(vault.status), business methods: \(contents.businessMethods.count)")
            print("vault file exists: \(FileManager.default.fileExists(atPath: vault.vaultURL.path))")
            let store = AppStore.shared
            MainActor.assumeIsolated { waitForSecrets(store) }
            print("store vaultStatus: \(store.vaultStatus), secretsUnprotected: \(store.secretsUnprotected)")
            print("in-memory business methods: \(store.data.business.paymentMethods.count)")
            store.saveNow()
            print("after saveNow -> vault file: \(FileManager.default.fileExists(atPath: vault.vaultURL.path)), status: \(store.vaultStatus), unprotected: \(store.secretsUnprotected)")
            exit(0)
        }
        if args.contains("--selftest-vault") {
            let vault = PaymentVault.shared
            vault.reset()

            var contents = VaultContents()
            var method = PaymentMethod.make(.bank)
            method.set("Account number", "111122223333")
            contents.businessMethods = [method]
            print("save:", vault.save(contents) ? "ok" : "FAILED")

            // 1. Clean re-open.
            let reopened = vault.load()
            print("reopen:", vault.status == .verified
                  && reopened.businessMethods.first?.fields.contains { $0.value == "111122223333" } == true
                  ? "verified + values intact" : "FAILED")

            // 2. Ciphertext edited under us.
            let good = try! Data(contentsOf: vault.vaultURL)
            var flipped = good
            flipped[flipped.count / 2] ^= 0x01
            try! flipped.write(to: vault.vaultURL)
            _ = vault.load()
            print("bit-flip detected:", vault.status.isTrouble ? "yes" : "NO — FAILED")
            print("  ->", vault.status.message)

            // 3. Rollback to an older but genuine vault.
            try! good.write(to: vault.vaultURL)
            _ = vault.load()
            let afterRestore = vault.status
            var newer = contents
            newer.businessMethods[0].set("Account number", "999988887777")
            vault.acceptCurrentFile()
            _ = vault.load()
            _ = vault.save(newer)
            let newestBytes = try! Data(contentsOf: vault.vaultURL)
            try! good.write(to: vault.vaultURL)   // attacker swaps in the old file
            _ = vault.load()
            print("rollback detected:", vault.status.isTrouble ? "yes" : "NO — FAILED")
            print("  ->", vault.status.message, "(restore-in-place was:", afterRestore, ")")

            // 4. Vault deleted entirely.
            try! newestBytes.write(to: vault.vaultURL)
            vault.acceptCurrentFile()
            _ = vault.load()
            try! FileManager.default.removeItem(at: vault.vaultURL)
            _ = vault.load()
            print("deletion detected:", vault.status.isTrouble ? "yes" : "NO — FAILED")
            print("  ->", vault.status.message)

            vault.reset()
            exit(0)
        }
        if args.contains("--selftest-columns") {
            _ = NSApplication.shared
            let store = AppStore.shared
            MainActor.assumeIsolated {
                waitForSecrets(store)
                guard var invoice = store.data.invoices.first else { exit(1) }
                let customer = store.customer(id: invoice.customerID)

                @MainActor func text(_ invoice: Invoice) -> String {
                    guard let data = PDFExporter.makePDFData(
                            invoice: invoice, customer: customer, business: store.data.business),
                          let doc = PDFDocument(data: data) else { return "" }
                    return (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
                }

                let before = text(invoice)
                print("default headings present:",
                      ["ITEMS", "QUANTITY", "PRICE", "AMOUNT"].allSatisfy { before.contains($0) }
                      ? "yes" : "NO — FAILED")

                invoice.columns.itemTitle = "Services"
                invoice.columns.unitTitle = "Hours"
                invoice.columns.priceTitle = "Rate"
                invoice.columns.showPrice = false
                invoice.columns.showDescription = false
                let after = text(invoice)
                let renamed = after.contains("SERVICES") && after.contains("HOURS")
                let priceGone = !after.contains("RATE") && !after.contains("PRICE")
                let details = invoice.items.compactMap { $0.details.isEmpty ? nil : $0.details }
                let detailsGone = details.allSatisfy { !after.contains($0) }
                print("renamed headings:", renamed ? "yes" : "NO — FAILED")
                print("hidden price column absent:", priceGone ? "yes" : "NO — FAILED")
                print("hidden descriptions absent:", detailsGone ? "yes (\(details.count) checked)" : "NO — FAILED")
                print("amount still printed:", after.contains("AMOUNT") ? "yes" : "NO — FAILED")

                if let index = args.firstIndex(of: "--selftest-columns"), index + 1 < args.count,
                   let data = PDFExporter.makePDFData(
                       invoice: invoice, customer: customer, business: store.data.business) {
                    try? data.write(to: URL(fileURLWithPath: args[index + 1]))
                    print("wrote", args[index + 1])
                }

                // A file written before this feature existed must still load.
                let legacy = """
                {"id":"\(UUID().uuidString)","number":"7","items":[]}
                """
                if let decoded = try? JSONDecoder().decode(Invoice.self, from: Data(legacy.utf8)) {
                    print("legacy invoice decodes:", decoded.columns == InvoiceColumns()
                          ? "yes, columns default to visible" : "NO — FAILED")
                } else {
                    print("legacy invoice decodes: NO — FAILED")
                }

                let blank = InvoiceColumns()
                var empty = blank
                empty.unitTitle = "   "
                print("blank title falls back:", empty.unitHeading == "QUANTITY" ? "yes" : "NO — FAILED")
                _ = blank
            }
            exit(0)
        }
        if args.contains("--selftest-payment") {
            var method = PaymentMethod.make(.bank)
            method.set("Bank", "US Bank")
            method.set("Account number", "1234")
            method.set("Routing number (ACH)", "5678")
            method.changeKind(to: .zelle)
            print("bank -> zelle: \(method.fields.map { "\($0.label)=\($0.value)" })")

            var venmo = PaymentMethod.make(.venmo)
            venmo.set("Venmo handle", "@finecut")
            venmo.set("Studio ref", "custom")
            venmo.changeKind(to: .paypal)
            print("venmo -> paypal (custom field kept): \(venmo.fields.map { "\($0.label)=\($0.value)" })")

            for kind in PaymentKind.allCases {
                let labels = kind.defaultFields.map { $0.label }
                let leaked = labels.filter { $0.lowercased().contains("routing") || $0.lowercased().contains("account") }
                if kind != .bank && kind != .wire && !leaked.isEmpty {
                    print("LEAK \(kind.rawValue): \(leaked)")
                }
            }
            print("PAYMENT FIELDS OK")
            exit(0)
        }
        if args.contains("--selftest-undo") {
            let store = AppStore.shared
            let before = store.data.invoices.count
            let created = store.newInvoice()
            store.commitHistory()
            store.data.invoices[0].number = "TEST-A"
            store.commitHistory()
            store.undo()
            let afterUndo = store.data.invoices.first?.number
            store.undo()
            let afterSecondUndo = store.data.invoices.count
            store.redo()
            let afterRedo = store.data.invoices.count
            print("created #\(created.number); undo(rename) -> \(afterUndo ?? "nil"); "
                + "undo(create) -> \(afterSecondUndo) invoices (was \(before)); redo -> \(afterRedo)")
            print(afterUndo == created.number && afterSecondUndo == before && afterRedo == before + 1
                ? "UNDO OK" : "UNDO FAILED")
            exit(0)
        }
        if args.contains("--measure-pages") {
            _ = NSApplication.shared
            let store = AppStore.shared
            MainActor.assumeIsolated {
                waitForSecrets(store)
                guard let invoice = store.data.invoices.first else { exit(1) }
                let customer = store.customer(id: invoice.customerID)
                for end in 1...invoice.items.count {
                    for isLast in [false, true] where !(isLast && end != invoice.items.count) || isLast {
                        let spec = InvoicePageSpec(start: 0, end: end, isFirst: true, isLast: isLast)
                        let height = InvoicePaginator.measuredHeight(
                            invoice: invoice, customer: customer, business: store.data.business, page: spec
                        )
                        print("items 0..<\(end) isLast=\(isLast) height=\(height)")
                    }
                }
                let t0 = Date()
                for _ in 0..<10 {
                    _ = InvoicePaginator.pages(
                        invoice: invoice, customer: customer, business: store.data.business
                    )
                }
                print("pages() x10 (warm cache): \(Int(Date().timeIntervalSince(t0) * 1000))ms")
                let pages = InvoicePaginator.pages(
                    invoice: invoice, customer: customer, business: store.data.business
                )
                print("pages: \(pages.map { "\($0.start)..<\($0.end) last=\($0.isLast)" })")
            }
            exit(0)
        }
        if let index = args.firstIndex(of: "--render-sample"), index + 1 < args.count {
            _ = NSApplication.shared
            let store = AppStore.shared
            MainActor.assumeIsolated { waitForSecrets(store) }
            store.saveNow()
            if let invoice = store.data.invoices.first,
               let data = MainActor.assumeIsolated({
                   PDFExporter.makePDFData(
                       invoice: invoice,
                       customer: store.customer(id: invoice.customerID),
                       business: store.data.business
                   )
               }) {
                try? data.write(to: URL(fileURLWithPath: args[index + 1]))
                exit(0)
            }
            exit(1)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(focus)
                .frame(minWidth: 1120, minHeight: 640)
                .onDisappear { store.saveNow() }
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { store.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!store.canUndo)
                Button("Redo") { store.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!store.canRedo)
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    SettingsWindowController.shared.show(store: store, focus: focus)
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(replacing: .newItem) {
                Button("New Invoice") {
                    let invoice = store.newInvoice()
                    focus.invoiceID = invoice.id
                    focus.requestedSection = .invoices
                } .keyboardShortcut("n")

                Button("New Customer") {
                    let customer = store.newCustomer()
                    focus.customerID = customer.id
                    focus.requestedSection = .customers
                } .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            CommandGroup(after: .saveItem) {
                Button("Export PDF…") { exportFocused() }
                    .keyboardShortcut("e")
                    .disabled(focus.invoiceID == nil)
                Button("Print Invoice…") { printFocused() }
                    .keyboardShortcut("p")
                    .disabled(focus.invoiceID == nil)
                Divider()
                Button("Back Up Data…") { backup() }
                Button("Restore From Backup…") { restore() }
                Button("Reveal Data File in Finder") {
                    store.saveNow()
                    NSWorkspace.shared.activateFileViewerSelecting([store.storageURL])
                }
            }
        }

    }

    private func exportFocused() {
        guard let id = focus.invoiceID, let invoice = store.invoice(id: id) else { return }
        PDFExporter.exportWithPanel(
            invoice: invoice,
            customer: store.customer(id: invoice.customerID),
            business: store.data.business
        )
    }

    private func printFocused() {
        guard let id = focus.invoiceID, let invoice = store.invoice(id: id) else { return }
        PDFExporter.printInvoice(
            invoice: invoice,
            customer: store.customer(id: invoice.customerID),
            business: store.data.business
        )
    }

    private func backup() {
        BackupPrompt.run(store: store)
    }

    private func restore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            try? store.importBackup(from: url)
        }
    }
}

/// Tracks what the window is currently showing so menu commands can act on it.
final class AppFocus: ObservableObject {
    @Published var invoiceID: UUID?
    @Published var customerID: UUID?
    @Published var requestedSection: SidebarSection?
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case invoices
    case customers
    case items
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .invoices: return "Invoices"
        case .customers: return "Customers"
        case .items: return "Items"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .invoices: return "doc.text"
        case .customers: return "person.2"
        case .items: return "shippingbox"
        case .settings: return "gearshape"
        }
    }
}
