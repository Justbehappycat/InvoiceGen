import SwiftUI
import AppKit
import PDFKit
import Vision

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

/// Self-tests mutate a store and save it. Pointed at the real data directory
/// they also touch the real vault — which is how a headless run under a
/// different code signature came to overwrite the Keychain key and orphan a
/// perfectly good vault. So every diagnostic that writes gets its own throwaway
/// data directory unless the caller has deliberately named one.
private func isolateDataDirectoryForDiagnostics() {
    guard ProcessInfo.processInfo.environment["INVOICEGEN_DATA"] == nil else { return }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("invoicegen-selftest-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("INVOICEGEN_DATA", directory.appendingPathComponent("data.json").path, 1)
    print("(self-test sandbox: \(directory.path))")
}

@main
struct InvoiceGenApp: App {
    @StateObject private var store = AppStore.shared
    @StateObject private var focus = AppFocus()
    @StateObject private var updates = UpdateController.shared

    init() {
        // Headless render used for checking PDF output: InvoiceGen --render-sample out.pdf
        let args = CommandLine.arguments
        // For checking the live app in both themes without flipping the whole
        // Mac's appearance: InvoiceGen --appearance dark|light. Offscreen
        // renders can't stand in for this -- the sidebar selection and the bar
        // materials only draw correctly in a real window.
        if let index = args.firstIndex(of: "--appearance"), index + 1 < args.count {
            _ = NSApplication.shared
            NSApp.appearance = NSAppearance(named: args[index + 1] == "dark" ? .darkAqua : .aqua)
        }
        if let index = args.firstIndex(of: "--render-ui"), index + 1 < args.count {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            let width = args.count > index + 2 ? Double(args[index + 2]) ?? 1320 : 1320
            let height = args.count > index + 3 ? Double(args[index + 3]) ?? 860 : 860
            let screen = args.count > index + 4 ? args[index + 4] : "invoices"
            // Optional 5th argument forces an appearance, so both themes can
            // actually be looked at rather than assumed from semantic colours.
            if args.count > index + 5 {
                NSApp.appearance = NSAppearance(named: args[index + 5] == "dark" ? .darkAqua : .aqua)
            }
            MainActor.assumeIsolated {
                // The vault opens on a background queue, so without this the
                // capture races it and the shot shows "No payment methods yet"
                // on an invoice that has them -- a screenshot that lies about
                // the app's state. Every other data path already waits.
                waitForSecrets(AppStore.shared)
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
            print("verification passphrase set: \(store.hasVerificationPassphrase)")
            print("verification mark style: \(store.data.business.verificationMarkStyle.rawValue)"
                + ", printed: \(store.data.business.printVerificationCode)")
            if let invoice = store.data.invoices.first {
                print("code for #\(invoice.number): \(store.verificationCode(for: invoice) ?? "none")")
            }
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
        // Renders a sheet from invented data — no customer, business or payment
        // details of yours — so layout changes can be shown and reviewed safely.
        if let index = args.firstIndex(of: "--render-mock"), index + 1 < args.count {
            _ = NSApplication.shared
            var business = BusinessProfile()
            business.name = "Northwind Studio LLC"
            business.addressLine1 = "1200 Alder Street"
            business.city = "Portland"
            business.region = "OR"
            business.postalCode = "97205"
            business.country = "United States"
            business.phone = "(555) 010-4477"
            business.email = "billing@example.com"
            business.website = "example.com"
            business.verificationSalt = Data(repeating: 0x2A, count: 16)
            business.verificationPassphrase = "sample passphrase"
            business.verificationStripInk = args.contains("ink")
            business.verificationMarkStyle = args.contains("strip") ? .strip : .banner
            business.verificationStripInk = args.contains("ink")
            if let index = args.firstIndex(of: "tone"), index + 1 < args.count,
               let tone = Double(args[index + 1]) {
                business.verificationBarTone = tone
            }

            var customer = Customer()
            customer.name = "Harbour Coffee Roasters"
            customer.contactName = "Attn: Accounts Payable"
            customer.addressLine1 = "418 Pike Street"
            customer.city = "Seattle"
            customer.region = "WA"
            customer.postalCode = "98101"
            customer.email = "ap@example.com"

            var invoice = Invoice()
            invoice.number = "11"
            invoice.poNumber = "HCR-2291"
            invoice.items = [
                LineItem(title: "Brand film — 90 second cut",
                         details: "Two rounds of revisions, colour grade, mix", quantity: 1, price: 4200),
                LineItem(title: "Social cutdowns", details: "6 × 15s vertical, captioned",
                         quantity: 6, price: 180),
                LineItem(title: "Studio day rate", details: "Crew of three, lighting package",
                         quantity: 2, price: 1400),
            ]
            invoice.amountPaid = 2000
            invoice.notes = "Payment due within 30 days of the invoice date."
            invoice.footerMessage = "It was a pleasure working with you!"
            var zelle = PaymentMethod.make(.zelle)
            zelle.set("Zelle ID (email or phone)", "payments@example.com")
            var bank = PaymentMethod.make(.bank)
            bank.title = "Placeholder Bank"
            bank.set("Account number", "•••• •••• 4412")
            invoice.paymentMethods = [zelle, bank]

            if let data = MainActor.assumeIsolated({
                PDFExporter.makePDFData(invoice: invoice, customer: customer, business: business)
            }) {
                try? data.write(to: URL(fileURLWithPath: args[index + 1]))
                MainActor.assumeIsolated {
                    if let key = Verification.cachedKey(passphrase: business.verificationPassphrase,
                                                        salt: business.verificationSalt) {
                        print("mock code:", Verification.code(for: invoice, key: key))
                    }
                }
                exit(0)
            }
            exit(1)
        }
        if args.contains("--selftest-mark") {
            setvbuf(stdout, nil, _IONBF, 0)
            _ = NSApplication.shared
            MainActor.assumeIsolated {
                let salt = Data(repeating: 0x2A, count: 16)
                guard let key = Verification.cachedKey(passphrase: "sample passphrase", salt: salt)
                else { print("no key — FAILED"); exit(1) }

                var business = BusinessProfile()
                business.name = "Northwind Studio LLC"
                business.verificationSalt = salt
                business.verificationPassphrase = "sample passphrase"
                var customer = Customer(); customer.name = "Harbour Coffee Roasters"
                var invoice = Invoice()
                invoice.number = "11"
                invoice.items = [LineItem(title: "Edit", details: "", quantity: 3, price: 500)]
                let code = Verification.code(for: invoice, key: key)

                let accent = NSColor(Color(hex: business.accentHex))
                let quiet = NSColor(Color(hex: business.accentHex).adjustingBrightness(0.78))
                print(String(format: "contrast · quiet strip: %.2f   ink strip: %.2f   (floor %.2f)",
                             Verification.printContrast(bars: quiet, onField: accent),
                             Verification.printContrast(bars: Verification.inkColor, onField: accent),
                             Verification.minimumContrast))

                @MainActor func render(_ name: String, contained: Bool, ink: Bool) -> URL? {
                    var profile = business
                    profile.verificationMarkStyle = contained ? .letters : .strip
                    profile.verificationStripInk = ink
                    guard let data = PDFExporter.makePDFData(
                        invoice: invoice, customer: customer, business: profile) else { return nil }
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("ig-mark-\(name).pdf")
                    try? data.write(to: url)
                    return url
                }

                // How light can the bars go before our own reader loses them?
                print("— banner stripes, read by the app itself")
                for tone in [0.30, 0.15, 0.08, 0.04, 0.02] {
                    var profile = business
                    profile.verificationMarkStyle = .banner
                    profile.verificationBarTone = tone
                    guard let data = PDFExporter.makePDFData(
                        invoice: invoice, customer: customer, business: profile) else { continue }
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("ig-tone.pdf")
                    try? data.write(to: url)
                    let report = PDFVerifier.verify(url: url, key: key, invoices: [invoice])
                    let field = NSColor(Color(hex: profile.accentHex))
                    let bars = Verification.barColor(onField: field, tone: tone)
                    let pcs = Verification.printContrast(bars: bars, onField: field)
                    print(String(format: "  tone %.2f  PCS %.2f  scanner: %@  our reader: %@  verdict: %@",
                                 tone, pcs,
                                 report.scannedCode == nil ? "no " : "yes",
                                 report.stripeAgreement.map { String(format: "%.0f%%", $0 * 100) } ?? "—",
                                 "\(report.verdict)"))
                    try? FileManager.default.removeItem(at: url)
                }

                // (label, contained, ink strip, must the bars decode?)
                let cases: [(String, Bool, Bool, Bool)] = [
                    ("contained", true,  false, false),   // the word alone — decorative by design
                    ("strip-ink", false, true,  true),    // a working symbol
                    ("strip-quiet", false, false, false), // present, but under the contrast floor
                ]
                for (name, contained, ink, mustScan) in cases {
                    guard let url = render(name, contained: contained, ink: ink) else {
                        print("render FAILED"); exit(1)
                    }
                    let report = PDFVerifier.verify(url: url, key: key, invoices: [invoice])
                    let decoded = report.scannedCode
                    let label = name.padding(toLength: 11, withPad: " ", startingAt: 0)
                    let payload = Verification.barcodePayload(for: code)
                    print("\(label) · bars decode:", decoded ?? "no",
                          mustScan ? (decoded == payload ? "ok" : "FAILED — this one must scan")
                                   : "(not required)")
                    print("\(label) · footer code read:", report.printedCode ?? "none",
                          report.printedCode == code ? "ok" : "FAILED")
                    print("\(label) · verdict:", "\(report.verdict)",
                          report.verdict == .genuine ? "ok" : "FAILED")
                    try? FileManager.default.removeItem(at: url)
                }
                print("Every style verifies: when the bars can't be read the PDF check falls "
                      + "back to the code printed in the footer.")
            }
            exit(0)
        }
        if args.contains("--selftest-pdf") {
            setvbuf(stdout, nil, _IONBF, 0)
            _ = NSApplication.shared
            MainActor.assumeIsolated {
                let salt = Data(repeating: 0x2A, count: 16)
                guard let key = Verification.cachedKey(passphrase: "sample passphrase", salt: salt)
                else { print("no key — FAILED"); exit(1) }

                var business = BusinessProfile()
                business.name = "Northwind Studio LLC"
                business.verificationSalt = salt
                business.verificationPassphrase = "sample passphrase"
                // Scannable settings, so this test exercises the bars as well
                // as the text; the shipping default is a tint no scanner reads.
                business.verificationMarkStyle = .banner
                business.verificationBarTone = 0.45
                var customer = Customer(); customer.name = "Harbour Coffee Roasters"

                var invoice = Invoice()
                invoice.number = "11"
                invoice.items = [
                    LineItem(title: "Brand film", details: "", quantity: 1, price: 4200),
                    LineItem(title: "Cutdowns", details: "", quantity: 6, price: 180),
                ]
                let genuineCode = Verification.code(for: invoice, key: key)
                let dir = FileManager.default.temporaryDirectory

                @MainActor func write(_ invoice: Invoice, override: String?, to name: String) -> URL? {
                    guard let data = PDFExporter.makePDFData(
                        invoice: invoice, customer: customer, business: business,
                        verificationCodeOverride: override
                    ) else { return nil }
                    let url = dir.appendingPathComponent(name)
                    try? data.write(to: url)
                    return url
                }

                // 1. An untouched invoice.
                guard let clean = write(invoice, override: nil, to: "ig-clean.pdf") else {
                    print("render FAILED"); exit(1)
                }
                var report = PDFVerifier.verify(url: clean, key: key, invoices: [invoice])
                print("clean PDF:")
                let genuinePayload = Verification.barcodePayload(for: genuineCode)
                print("  bars decoded:", report.scannedCode ?? "none",
                      report.scannedCode == genuinePayload ? "ok" : "FAILED")
                print("  read off the page: number=\(report.number ?? "-") "
                      + "date=\(report.date.map(Verification.isoDate) ?? "-") "
                      + "items=\(report.quantity.map { "\($0)" } ?? "-") "
                      + "total=\(report.total.map { "\($0)" } ?? "-")")
                print("  verdict:", "\(report.verdict)",
                      report.verdict == .genuine ? "ok" : "FAILED")

                // 2. The attack: page edited, original barcode left in place.
                var edited = invoice
                edited.items[0].price = 9200          // someone raises the total
                guard let forged = write(edited, override: genuineCode, to: "ig-forged.pdf") else {
                    print("render FAILED"); exit(1)
                }
                report = PDFVerifier.verify(url: forged, key: key, invoices: [invoice])
                print("edited PDF, original barcode:")
                print("  page total read as:", report.total.map { "\($0)" } ?? "-")
                print("  self-consistent:", report.pageIsSelfConsistent.map { "\($0)" } ?? "-")
                print("  verdict:", "\(report.verdict)",
                      report.verdict == .tampered ? "caught" : "MISSED — FAILED")

                // 3. Intact sheet, but our own copy has moved on since sending.
                var changedRecord = invoice
                changedRecord.items[0].price = 4500
                report = PDFVerifier.verify(url: clean, key: key, invoices: [changedRecord])
                print("intact PDF vs an invoice edited after sending:")
                print("  verdict:", "\(report.verdict)",
                      report.verdict == .differsFromRecord ? "flagged" : "FAILED")
                print("  difference:", report.differencesFromRecord.first ?? "none")

                // 4. A PDF with no code at all.
                business.printVerificationCode = false
                guard let plain = write(invoice, override: nil, to: "ig-plain.pdf") else { exit(1) }
                report = PDFVerifier.verify(url: plain, key: key, invoices: [invoice])
                print("PDF without a code:", "\(report.verdict)",
                      report.verdict == .noCode ? "reported" : "FAILED")

                for name in ["ig-clean.pdf", "ig-forged.pdf", "ig-plain.pdf"] {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
                }
            }
            exit(0)
        }
        if args.contains("--selftest-verify") {
            setvbuf(stdout, nil, _IONBF, 0)
            _ = NSApplication.shared
            MainActor.assumeIsolated {
                let salt = Verification.newSalt()
                guard let key = Verification.deriveKey(passphrase: "correct horse battery", salt: salt),
                      let other = Verification.deriveKey(passphrase: "wrong horse battery", salt: salt)
                else { print("key derivation FAILED"); exit(1) }

                var invoice = Invoice()
                invoice.number = "11"
                invoice.issueDate = Date()
                invoice.items = [
                    LineItem(title: "Edit", details: "", quantity: 2, price: 150),
                    LineItem(title: "Grade", details: "", quantity: 1, price: 100),
                ]
                var data = AppData()
                data.invoices = [invoice]

                let code = Verification.code(for: invoice, key: key)
                print("payload:", Verification.payload(for: invoice))
                print("code:", code)
                print("verifies:", Verification.verify(code, in: data, key: key).isValid ? "yes" : "NO — FAILED")

                // Every signed field must actually change the code.
                for (label, mutate) in [
                    ("total amount", { (i: inout Invoice) in i.items[0].price += 1 }),
                    ("quantity", { (i: inout Invoice) in i.items[0].quantity += 1 }),
                    ("date", { (i: inout Invoice) in i.issueDate = i.issueDate.addingTimeInterval(86400) }),
                    ("number", { (i: inout Invoice) in i.number = "12" }),
                ] {
                    var tampered = invoice
                    mutate(&tampered)
                    var tamperedData = AppData()
                    tamperedData.invoices = [tampered]
                    let result = Verification.verify(code, in: tamperedData, key: key)
                    print("  changed \(label) ->", result.isValid ? "STILL VALID — FAILED" : "rejected")
                }

                print("wrong passphrase:",
                      Verification.verify(code, in: data, key: other).isValid ? "ACCEPTED — FAILED" : "rejected")
                print("garbage input:",
                      Verification.verify("hello", in: data, key: key) == .malformed ? "malformed" : "FAILED")
                print("no passphrase:",
                      Verification.verify(code, in: data, key: nil) == .noPassphrase ? "reported" : "FAILED")

                // Same passphrase + same salt on another Mac ⇒ same code.
                let elsewhere = Verification.deriveKey(passphrase: "correct horse battery", salt: salt)!
                print("reproducible elsewhere:",
                      Verification.code(for: invoice, key: elsewhere) == code ? "yes" : "NO — FAILED")

                // The bars actually encode the code, and scan back.
                if let image = Verification.cachedBarcode(for: code),
                   let tiff = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff), let cg = bitmap.cgImage {
                    let request = VNDetectBarcodesRequest()
                    try? VNImageRequestHandler(cgImage: cg).perform([request])
                    let decoded = (request.results ?? []).compactMap { $0.payloadStringValue }
                    let payload = Verification.barcodePayload(for: code)
                    print("barcode round-trip:", decoded.first == payload
                          ? "scans back to \(payload), the code's numeric payload"
                          : "FAILED \(decoded), expected \(payload)")
                } else {
                    print("barcode round-trip: FAILED to render")
                }
            }
            exit(0)
        }
        if args.contains("--selftest-archive") {
            isolateDataDirectoryForDiagnostics()
            setvbuf(stdout, nil, _IONBF, 0)
            _ = NSApplication.shared
            MainActor.assumeIsolated {
                let store = AppStore.shared
                waitForSecrets(store)
                let liveBefore = store.activeInvoices.count

                let invoice = store.newInvoice()
                store.commitHistory()

                store.setArchived(true, on: invoice.id)
                print("archived leaves the working list:",
                      store.activeInvoices.count == liveBefore
                        && store.archivedInvoices.contains { $0.id == invoice.id } ? "yes" : "FAILED")
                let archived = store.invoice(id: invoice.id)
                print("archived is never overdue:", archived?.isOverdue == false ? "yes" : "FAILED")

                store.setArchived(false, on: invoice.id)
                print("un-archiving puts it back:",
                      store.activeInvoices.count == liveBefore + 1 ? "yes" : "FAILED")

                // Deleting is a move, not a destruction.
                let total = store.data.invoices.count
                _ = total
                store.deleteInvoice(id: invoice.id)
                print("delete moves to the trash:",
                      store.data.invoices.count == total
                        && store.trashedInvoices.contains { $0.id == invoice.id }
                        && store.activeInvoices.count == liveBefore ? "yes" : "FAILED")
                print("trashed invoice leaves customer history:",
                      !store.invoices(for: invoice.customerID ?? UUID())
                          .contains { $0.id == invoice.id } ? "yes" : "FAILED")

                store.restoreFromTrash(id: invoice.id)
                print("put back:", store.activeInvoices.contains { $0.id == invoice.id }
                      ? "yes" : "FAILED")

                store.deleteInvoice(id: invoice.id)
                store.undo()
                print("undo un-deletes:", store.invoice(id: invoice.id)?.isTrashed == false
                      ? "yes" : "FAILED")

                // Measure across the emptying itself: an undo earlier in this
                // test can move the total, so counting from a number captured
                // before it proves nothing.
                if store.invoice(id: invoice.id) == nil {
                    print("emptying the trash: SKIPPED — undo removed the test invoice")
                } else {
                    store.deleteInvoice(id: invoice.id)
                    let trashedNow = store.trashedInvoices.count
                    let countBefore = store.data.invoices.count
                    store.emptyTrash()
                    print("emptying the trash really removes it:",
                          store.invoice(id: invoice.id) == nil
                            && store.data.invoices.count == countBefore - trashedNow
                            ? "yes (\(trashedNow) removed)" : "FAILED")
                }

                // The archive files by year, newest first.
                var years: [Invoice] = []
                for year in [2024, 2026, 2025] {
                    var one = Invoice()
                    one.issueDate = Calendar.current.date(
                        from: DateComponents(year: year, month: 6, day: 1)) ?? Date()
                    one.archivedAt = Date()
                    years.append(one)
                }
                let grouped = Dictionary(grouping: years, by: \.year)
                    .map(\.key).sorted(by: >)
                print("archive years, newest first:", grouped,
                      grouped == [2026, 2025, 2024] ? "ok" : "FAILED")

                store.data.nextInvoiceNumber -= 1
                store.saveNow()
            }
            exit(0)
        }
        if args.contains("--selftest-list") {
            isolateDataDirectoryForDiagnostics()
            setvbuf(stdout, nil, _IONBF, 0)
            _ = NSApplication.shared
            MainActor.assumeIsolated {
                let store = AppStore.shared
                waitForSecrets(store)

                // Ordering: overdue (0) before unpaid (1) before paid (2).
                var overdue = Invoice(); overdue.number = "A"
                overdue.dueDate = Date().addingTimeInterval(-10 * 86400)
                overdue.items = [LineItem(title: "x", details: "", quantity: 1, price: 100)]
                var unpaid = Invoice(); unpaid.number = "B"
                unpaid.dueDate = Date().addingTimeInterval(10 * 86400)
                unpaid.items = overdue.items
                var paid = Invoice(); paid.number = "C"; paid.status = .paid
                paid.items = overdue.items; paid.amountPaid = 100
                let ranked = [paid, unpaid, overdue]
                    .sorted { $0.sortRank < $1.sortRank }
                    .map { $0.number }
                print("sort order:", ranked, ranked == ["A", "B", "C"] ? "ok" : "FAILED")
                print("paid sinks below overdue:", paid.sortRank > overdue.sortRank ? "yes" : "NO — FAILED")

                // setStatus(.paid) settles the invoice, and undo restores both.
                let created = store.newInvoice()
                store.commitHistory()
                guard let index = store.data.invoices.firstIndex(where: { $0.id == created.id })
                else { print("FAILED to create"); exit(1) }
                store.data.invoices[index].items = [
                    LineItem(title: "Work", details: "", quantity: 2, price: 250)
                ]
                store.commitHistory()
                let total = store.data.invoices[index].total
                store.setStatus(.paid, on: created.id)
                let after = store.data.invoices[index]
                print("mark paid -> status:", after.status.label,
                      "amountPaid:", "\(after.amountPaid)", "of total", "\(total)",
                      after.status == .paid && after.amountPaid == total ? "ok" : "FAILED")
                print("amount due is zero:", after.amountDue == 0 ? "yes" : "NO — FAILED")
                store.undo()
                let undone = store.data.invoices.first { $0.id == created.id }
                print("undo restores:", undone?.status.label ?? "gone",
                      "amountPaid \(undone?.amountPaid ?? -1)",
                      undone?.status == .draft && undone?.amountPaid == 0 ? "ok" : "FAILED")

                // "Today" keeps the payment term.
                let calendar = Calendar.current
                var invoice = Invoice()
                invoice.issueDate = calendar.date(byAdding: .day, value: -9, to: Date())!
                invoice.dueDate = calendar.date(byAdding: .day, value: 30, to: invoice.issueDate)!
                let today = calendar.startOfDay(for: Date())
                let term = calendar.dateComponents([.day], from: invoice.issueDate, to: invoice.dueDate).day!
                invoice.issueDate = today
                invoice.dueDate = calendar.date(byAdding: .day, value: term, to: today)!
                let newTerm = calendar.dateComponents([.day], from: invoice.issueDate, to: invoice.dueDate).day!
                print("today keeps the term:", newTerm == 30 ? "yes (30 days)" : "NO — FAILED (\(newTerm))")

                store.deleteInvoice(id: created.id)
                store.data.nextInvoiceNumber -= 1
                store.saveNow()
            }
            exit(0)
        }
        if args.contains("--selftest-customer-sync") {
            setvbuf(stdout, nil, _IONBF, 0)
            var failures = 0
            func check(_ label: String, _ condition: Bool) {
                print("  \(condition ? "ok  " : "FAIL") \(label)")
                if !condition { failures += 1 }
            }

            // merge() is pure, so this touches no iCloud folder and no data file.
            let early = Date(timeIntervalSince1970: 1_000_000)
            let late = Date(timeIntervalSince1970: 2_000_000)
            let later = Date(timeIntervalSince1970: 3_000_000)

            func make(_ name: String, id: UUID, created: Date, updated: Date?) -> Customer {
                var c = Customer()
                c.id = id
                c.name = name
                c.createdAt = created
                c.updatedAt = updated
                return c
            }

            let idA = UUID(), idB = UUID(), idC = UUID()

            print("union:")
            let onlyLocal = make("Local Only", id: idA, created: early, updated: nil)
            let onlyRemote = make("Remote Only", id: idB, created: early, updated: nil)
            var merged = CustomerSync.merge(local: [onlyLocal], remote: [onlyRemote], deleted: [:])
            check("keeps a customer only this Mac has", merged.contains { $0.id == idA })
            check("picks up a customer only the other Mac has", merged.contains { $0.id == idB })

            print("conflict — newer wins:")
            let mine = make("Old Name", id: idC, created: early, updated: late)
            let theirs = make("New Name", id: idC, created: early, updated: later)
            merged = CustomerSync.merge(local: [mine], remote: [theirs], deleted: [:])
            check("remote newer replaces local", merged.first { $0.id == idC }?.name == "New Name")
            merged = CustomerSync.merge(local: [theirs], remote: [mine], deleted: [:])
            check("local newer survives remote", merged.first { $0.id == idC }?.name == "New Name")
            check("no duplicate rows", merged.filter { $0.id == idC }.count == 1)

            print("missing updatedAt falls back to createdAt:")
            let oldNoStamp = make("Older", id: idC, created: early, updated: nil)
            let newNoStamp = make("Newer", id: idC, created: later, updated: nil)
            merged = CustomerSync.merge(local: [oldNoStamp], remote: [newNoStamp], deleted: [:])
            check("later createdAt wins", merged.first { $0.id == idC }?.name == "Newer")

            print("tombstones:")
            let doomed = make("Deleted Elsewhere", id: idA, created: early, updated: early)
            merged = CustomerSync.merge(local: [doomed], remote: [],
                                        deleted: [idA.uuidString: late])
            check("a delete on the other Mac removes it here", merged.isEmpty)

            let revived = make("Edited After Delete", id: idA, created: early, updated: later)
            merged = CustomerSync.merge(local: [revived], remote: [],
                                        deleted: [idA.uuidString: late])
            check("an edit made after the delete brings it back", merged.count == 1)

            merged = CustomerSync.merge(local: [onlyLocal], remote: [],
                                        deleted: [UUID().uuidString: late])
            check("an unrelated tombstone removes nothing", merged.count == 1)

            print("ordering:")
            let z = make("Zebra", id: UUID(), created: early, updated: nil)
            let a = make("Apple", id: UUID(), created: early, updated: nil)
            merged = CustomerSync.merge(local: [z], remote: [a], deleted: [:])
            check("result is sorted by name", merged.map(\.name) == ["Apple", "Zebra"])

            print(failures == 0 ? "customer sync self-test: all passed"
                                : "customer sync self-test: \(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }

        if args.contains("--selftest-bulk") {
            setvbuf(stdout, nil, _IONBF, 0)
            // Mutating test: never let it near the real data file.
            isolateDataDirectoryForDiagnostics()
            _ = NSApplication.shared
            var failures = 0
            func check(_ label: String, _ condition: Bool) {
                print("  \(condition ? "ok  " : "FAIL") \(label)")
                if !condition { failures += 1 }
            }

            MainActor.assumeIsolated {
                let store = AppStore.shared
                store.data.invoices = []
                var made: [Invoice] = []
                for n in 1...5 {
                    var invoice = Invoice()
                    invoice.number = String(n)
                    invoice.items = [LineItem(title: "Work", details: "", quantity: 1, price: 100)]
                    made.append(invoice)
                }
                store.data.invoices = made
                let all = Set(made.map(\.id))
                let three = Set(made.prefix(3).map(\.id))
                store.commitHistory()

                print("bulk status:")
                store.setStatus(.paid, on: three)
                check("marks exactly the selection paid",
                      store.data.invoices.filter { $0.status == .paid }.count == 3)
                check("paid also settles the amount",
                      store.invoices(with: three).allSatisfy { $0.amountPaid == $0.total })

                print("undo is one step for the whole batch:")
                store.undo()
                check("one undo restores all three",
                      store.data.invoices.allSatisfy { $0.status != .paid })

                print("bulk archive / trash:")
                store.setArchived(true, on: three)
                check("archives three", store.archivedInvoices.count == 3)
                store.setArchived(false, on: three)
                check("un-archives three", store.archivedInvoices.isEmpty)

                store.deleteInvoices(ids: three)
                check("trashes three", store.trashedInvoices.count == 3)
                check("leaves the rest active", store.activeInvoices.count == 2)
                store.restoreFromTrash(ids: three)
                check("restores three", store.trashedInvoices.isEmpty)

                print("bulk duplicate:")
                let copies = store.duplicate(ids: three)
                check("makes one copy each", copies.count == 3)
                check("copies are drafts", copies.allSatisfy { $0.status == .draft })
                check("originals remain", store.data.invoices.count == 8)

                print("bulk permanent delete:")
                store.permanentlyDelete(ids: Set(copies.map(\.id)))
                check("removes exactly the copies", store.data.invoices.count == 5)

                print("empty selection is a no-op:")
                let before = store.data.invoices
                store.setStatus(.paid, on: [])
                store.deleteInvoices(ids: [])
                check("nothing changed", store.data.invoices == before)
                _ = all
            }

            print(failures == 0 ? "bulk self-test: all passed" : "bulk self-test: \(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }

        if args.contains("--selftest-update") {
            setvbuf(stdout, nil, _IONBF, 0)
            var failures = 0
            func check(_ label: String, _ condition: Bool) {
                print("  \(condition ? "ok  " : "FAIL") \(label)")
                if !condition { failures += 1 }
            }

            print("version comparison:")
            check("0.15.0 > 0.14.0", Updater.isNewer("0.15.0", than: "0.14.0"))
            check("0.9.3 < 0.14.0", !Updater.isNewer("0.9.3", than: "0.14.0"))
            check("1.0 == 1.0.0", !Updater.isNewer("1.0", than: "1.0.0"))
            check("0.14.1 > 0.14.0", Updater.isNewer("0.14.1", than: "0.14.0"))
            check("equal is not newer", !Updater.isNewer("0.14.0", than: "0.14.0"))

            print("signing identity:")
            let requirement = Updater.expectedRequirement()
            check("derived from the running bundle", requirement != nil)
            if let requirement {
                print("    \(requirement)")
                check("pins a team OU", requirement.contains("subject.OU"))
                check("pins the Developer ID leaf OID",
                      requirement.contains("1.2.840.113635.100.6.1.13"))
            }

            print("signature check:")
            let own = Bundle.main.bundleURL
            do {
                try Updater.verifySignature(of: own)
                check("accepts this very bundle", true)
            } catch {
                check("accepts this very bundle — \(error.localizedDescription)", false)
            }

            // The one that matters: a modified copy must be refused.
            let work = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("invoicegen-tamper-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let copy = work.appendingPathComponent("InvoiceGen.app")
            do {
                try FileManager.default.copyItem(at: own, to: copy)
                try Updater.verifySignature(of: copy)   // an untouched copy is still fine
                check("accepts an untouched copy", true)

                // Flip a byte in the Info.plist and it must stop verifying.
                let plist = copy.appendingPathComponent("Contents/Info.plist")
                var text = try String(contentsOf: plist, encoding: .utf8)
                text = text.replacingOccurrences(of: "<string>InvoiceGen</string>",
                                                 with: "<string>EvilGen</string>")
                try text.write(to: plist, atomically: true, encoding: .utf8)

                var rejected = false
                do { try Updater.verifySignature(of: copy) } catch { rejected = true }
                check("REJECTS a tampered copy", rejected)
            } catch {
                check("tamper test could not run: \(error.localizedDescription)", false)
            }

            print(failures == 0 ? "update self-test: all passed" : "update self-test: \(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }

        if args.contains("--selftest-publish") {
            setvbuf(stdout, nil, _IONBF, 0)
            _ = NSApplication.shared
            MainActor.assumeIsolated {
                var business = BusinessProfile()
                business.name = "Northwind Studio LLC"
                business.accentHex = "#7C7C7C"
                business.publishBaseURL = "https://invoice.finecut.com"

                var invoice = Invoice()
                invoice.number = "17"
                invoice.items = [LineItem(title: "Edit", details: "", quantity: 2, price: 200)]
                var customer = Customer(); customer.name = "Harbour Coffee Roasters"

                // A payment method with values that must never reach the page.
                var bank = PaymentMethod.make(.bank)
                bank.set("Account number", "000123456789")
                bank.set("Routing number (ACH)", "123456789")
                invoice.paymentMethods = [bank]

                let target = PublishService.Target(
                    url: URL(string: "https://invoice.finecut.com")!, token: "token-1234567890")

                let meta = PublishService.metadata(for: invoice, customer: customer, business: business)
                let json = String(data: try! JSONSerialization.data(withJSONObject: meta), encoding: .utf8)!
                print("metadata:", meta.keys.sorted().joined(separator: ", "))
                let leaks = ["000123456789", "123456789"].filter { json.contains($0) }
                print("payment details stay out of the page metadata:",
                      leaks.isEmpty ? "yes" : "NO — FAILED \(leaks)")
                print("summary is present:",
                      meta["number"] == "17" && meta["amountDue"] == "$400.00"
                        && meta["status"] == "Draft" ? "yes" : "FAILED")

                let id = PublishService.makeID()
                print("id is unguessable and url-safe:",
                      id.count == 12 && id.allSatisfy(\.isHexDigit) ? "yes (\(id))" : "FAILED \(id)")
                print("ids differ each time:",
                      Set((0..<200).map { _ in PublishService.makeID() }).count == 200 ? "yes" : "FAILED")

                let put = PublishService.publishRequest(
                    id: id, target: target, metadata: meta, pdf: Data("%PDF".utf8))
                print("publish:", put.httpMethod ?? "-", put.url?.path ?? "-",
                      put.url?.path == "/publish/\(id)" ? "ok" : "FAILED")
                print("token is sent as a bearer:",
                      put.value(forHTTPHeaderField: "Authorization") == "Bearer token-1234567890"
                        ? "ok" : "FAILED")
                print("body is the PDF:", put.httpBody == Data("%PDF".utf8) ? "ok" : "FAILED")

                let delete = PublishService.unpublishRequest(id: id, target: target)
                print("unpublish:", delete.httpMethod ?? "-", delete.url?.path ?? "-",
                      delete.httpMethod == "DELETE" ? "ok" : "FAILED")

                print("public link:", PublishService.publicURL(for: id, target: target).absoluteString)

                // Without an address or a token, nothing can be sent.
                var unset = business
                unset.publishBaseURL = ""
                print("refuses to publish when unconfigured:",
                      PublishService.target(for: unset) == nil ? "yes" : "NO — FAILED")
                var insecure = business
                insecure.publishBaseURL = "http://invoice.finecut.com"
                print("refuses a plain-http address:",
                      PublishService.target(for: insecure) == nil ? "yes" : "NO — FAILED")
            }
            exit(0)
        }
        if args.contains("--selftest-fields") {
            setvbuf(stdout, nil, _IONBF, 0)
            // Deleting the last digit must reach zero, not restore the old
            // number — the failure this test exists for.
            var value: Decimal = 500
            for typed in ["50", "5", ""] {
                if let next = DecimalField.value(for: typed) { value = next }
            }
            print("500 → 50 → 5 → empty gives:", "\(value)", value == 0 ? "ok" : "FAILED")

            let cases: [(String, Decimal?)] = [
                ("", 0), ("0", 0), ("12", 12), ("12.5", 12.5), ("1,250", 1250),
                // Half-typed "1." on the way to "1.5" means 1 — the totals stay
                // live and the field keeps the dot, because the text is the
                // state and only a *different* value rewrites it.
                (" 7 ", 7), ("1.", 1), ("-", nil), ("abc", nil), ("12abc", nil), ("1.2.3", nil),
            ]
            for (text, expected) in cases {
                let actual = DecimalField.value(for: text)
                let match = actual == expected
                // %s with a Swift String crashes; pad in Swift instead.
                let shown = "\"\(text)\"".padding(toLength: 9, withPad: " ", startingAt: 0)
                let got = (actual.map { "\($0)" } ?? "leave").padding(toLength: 7, withPad: " ", startingAt: 0)
                print("  " + shown + "→ " + got
                      + (match ? "ok" : "FAILED (expected \(expected.map { "\($0)" } ?? "leave"))"))
            }

            print("integer empty falls to its floor:",
                  IntegerField.value(for: "", minimum: 1) == 1 ? "ok" : "FAILED")
            print("integer clamps below the floor:",
                  IntegerField.value(for: "0", minimum: 1) == 1 ? "ok" : "FAILED")
            print("integer takes a number:",
                  IntegerField.value(for: "42", minimum: 0) == 42 ? "ok" : "FAILED")
            exit(0)
        }
        if args.contains("--selftest-assist") {
            setvbuf(stdout, nil, _IONBF, 0)
            var failed = false
            func check(_ name: String, _ passed: Bool) {
                print("  " + name.padding(toLength: 52, withPad: " ", startingAt: 0)
                      + (passed ? "ok" : "FAILED"))
                if !passed { failed = true }
            }

            // The guard that keeps rule 2 — the model may reword, never
            // re-price. These run with no model and must hold regardless.
            check("digits pulled out of \"2 x EP10\"",
                  OnDeviceAssist.digitRuns(in: "2 x EP10") == ["2", "10"])
            check("prose has no digits",
                  OnDeviceAssist.digitRuns(in: "Episode one edit").isEmpty)

            let guardCases: [(String, String, Bool)] = [
                ("ep1 edit", "Episode 1 Edit", false),
                ("ep1 edit", "Episode 1 Edit, 2 revisions", true),   // invented "2"
                ("edit", "Edit — $400", true),                       // invented a price
                // Both of these were real first drafts from the model.
                ("ep1 edit", "Episode Edit", true),                  // dropped the episode
                ("2 rounds at ep1", "Two rounds, Episode 1", true),  // spelled "2" out
                ("ep1 ep2", "Episode 1", true),                      // lost one of two
                ("Long x1 Short x1", "Long x1 Short x1", false),
                ("", "", false),
            ]
            for (source, result, expected) in guardCases {
                let actual = OnDeviceAssist.changesNumbers(source: source, result: result)
                let label = "\"\(result)\" from \"\(source)\""
                check(label.padding(toLength: min(label.count, 44), withPad: " ", startingAt: 0)
                      + " moves a number: \(actual)", actual == expected)
            }

            // Readiness must answer on any Mac, including one with no Apple
            // Intelligence, without throwing or blocking.
            let readiness = OnDeviceAssist.readiness
            print("  readiness: \(readiness)")
            check("readiness explains itself when unavailable",
                  readiness == .ready || readiness.explanation != nil)

            // A real round trip, only where the model exists. Non-deterministic
            // wording, so this asserts the contract, not the prose.
            if readiness == .ready {
                // Pump the run loop rather than block on it: the model's work
                // needs the main thread to keep turning, so waiting on a
                // semaphore here deadlocks until the timeout.
                nonisolated(unsafe) var live: Result<OnDeviceAssist.Proposal, Error>?
                Task {
                    do {
                        live = .success(try await OnDeviceAssist.tidy(
                            title: "ep1 edit + colour pass",
                            details: "long x1 short x1",
                            heading: "Item"))
                    } catch { live = .failure(error) }
                }
                let deadline = Date().addingTimeInterval(90)
                while live == nil, Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
                if live == nil {
                    check("on-device tidy answers within 90s", false)
                } else if case .success(let proposal) = live {
                    print("  model returned: \"\(proposal.title)\" / \"\(proposal.details)\"")
                    check("tidy returns a name", !proposal.title.isEmpty)
                    check("tidy moved no numbers",
                          !OnDeviceAssist.changesNumbers(
                            source: "ep1 edit + colour pass long x1 short x1",
                            result: proposal.title + " " + proposal.details))
                } else if case .failure(let error) = live {
                    // A rejected suggestion is the guard working, not a failure.
                    let rejected = (error as? OnDeviceAssist.Failure) == .changedNumbers
                    print("  model call failed: \(error.localizedDescription)")
                    check("failure was the guard, not a crash", rejected)
                }
            } else {
                print("  (no on-device model here — skipping the live call)")
            }

            exit(failed ? 1 : 0)
        }
        if args.contains("--selftest-project") {
            setvbuf(stdout, nil, _IONBF, 0)
            // Mutating test: never let it near the real data file.
            isolateDataDirectoryForDiagnostics()
            _ = NSApplication.shared
            var failures = 0
            func check(_ label: String, _ condition: Bool) {
                print("  \(condition ? "ok  " : "FAIL") \(label)")
                if !condition { failures += 1 }
            }

            MainActor.assumeIsolated {
                let store = AppStore.shared
                store.data.invoices = []
                store.data.projects = []

                let customer = store.newCustomer(name: "Lantern Road Media")
                var project = store.newProject(customerID: customer.id)
                project.name = "Night Shift — S1"
                project.contractTotal = 1200
                // The shape of a real podcast contract: staggered episode
                // payments, a fortnight apart.
                func day(_ offset: Int) -> Date {
                    Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
                }
                project.milestones = [
                    Milestone(deliverable: "Episode 1", amount: 150, dueDate: day(1)),
                    Milestone(deliverable: "Episodes 2-3", amount: 300, dueDate: day(8)),
                    Milestone(deliverable: "Episodes 4-5", amount: 300, dueDate: day(22)),
                    Milestone(deliverable: "Episodes 6-8", amount: 450, dueDate: day(36)),
                ]
                store.data.projects[0] = project
                let projectID = project.id
                store.commitHistory()

                print("the schedule:")
                check("adds up to the contract",
                      store.data.projects[0].scheduledTotal == 1200)

                print("one milestone becomes one draft invoice:")
                let first = store.data.projects[0].milestones[0]
                guard let made = store.createInvoice(forMilestone: first.id, inProject: projectID)
                else {
                    print("  FAIL could not create the invoice"); exit(1)
                }
                let live = store.invoice(id: made.id)
                check("belongs to the project", live?.projectID == projectID)
                check("bills the client from the project", live?.customerID == customer.id)
                check("due on the milestone's date",
                      live.map { Calendar.current.isDate($0.dueDate, inSameDayAs: first.dueDate) } == true)
                check("carries the deliverable", live?.items.first?.title == "Episode 1")
                check("totals the milestone amount", live?.total == 150)
                check("starts as a draft", live?.status == .draft)
                check("milestone now points at it",
                      store.data.projects[0].milestones[0].invoiceID == made.id)

                print("a milestone cannot be billed twice:")
                check("second attempt refuses",
                      store.createInvoice(forMilestone: first.id, inProject: projectID) == nil)
                check("still exactly one invoice", store.invoices(inProject: projectID).count == 1)

                print("totals:")
                var totals = store.totals(forProject: projectID)
                check("invoiced 150", totals.invoiced == 150)
                check("paid nothing yet", totals.paid == 0)
                check("outstanding 150", totals.outstanding == 150)
                check("1050 of the contract left to bill",
                      totals.remainingToBill(contractTotal: 1200) == 1050)
                check("no contract total means no claim about what is left",
                      totals.remainingToBill(contractTotal: 0) == nil)

                store.setStatus(.paid, on: made.id)
                totals = store.totals(forProject: projectID)
                check("paying settles the outstanding", totals.outstanding == 0)
                check("paid 150", totals.paid == 150)

                print("billing the rest is one undo step:")
                let rest = store.createInvoicesForUnbilled(inProject: projectID)
                check("made the three remaining", rest.count == 3)
                check("oldest due date first",
                      rest.map(\.dueDate) == rest.map(\.dueDate).sorted())
                check("every milestone is now billed",
                      store.data.projects[0].milestones.allSatisfy { $0.isInvoiced })
                totals = store.totals(forProject: projectID)
                check("invoiced the whole contract", totals.invoiced == 1200)
                store.undo()
                check("one undo takes all three back",
                      store.invoices(inProject: projectID).count == 1)
                check("and unbills their milestones",
                      store.data.projects[0].milestones.filter { $0.isInvoiced }.count == 1)

                print("trashed invoices stop counting, archived ones don't:")
                _ = store.createInvoicesForUnbilled(inProject: projectID)
                let second = store.invoices(inProject: projectID)
                    .first { $0.id != made.id }!
                store.setArchived(true, on: second.id)
                check("archived still counts as billed",
                      store.totals(forProject: projectID).invoiced == 1200)
                store.deleteInvoice(id: second.id)
                check("trashed drops out of the total",
                      store.totals(forProject: projectID).invoiced == 1200 - second.total)
                check("and out of the project's list",
                      !store.invoices(inProject: projectID).contains { $0.id == second.id })

                print("a trashed invoice releases its milestone:")
                // Found by looking at the screen: the schedule said "Invoice
                // #12" while the money said "$0.00 invoiced", because the
                // invoice had been trashed. Both halves must agree.
                let third = store.invoices(inProject: projectID).first { $0.id != made.id }!
                let itsMilestone = store.data.projects[0].milestones
                    .first { $0.invoiceID == third.id }!
                check("counts as billed while the invoice lives",
                      !store.needsInvoicing(itsMilestone))
                store.deleteInvoice(id: third.id)
                let afterTrash = store.data.projects[0].milestones
                    .first { $0.id == itsMilestone.id }!
                check("stops counting as billed once trashed",
                      store.needsInvoicing(afterTrash))
                check("and the schedule offers no stale link",
                      store.billedInvoice(for: afterTrash) == nil)
                check("so it can be billed again",
                      store.createInvoice(forMilestone: afterTrash.id,
                                          inProject: projectID) != nil)
                store.undo()

                print("destroying an invoice unbills its milestone:")
                store.permanentlyDelete(id: second.id)
                check("milestone is free again",
                      store.data.projects[0].milestones.contains {
                          $0.invoiceID == nil
                      })
                check("no milestone points at a missing invoice",
                      store.data.projects[0].milestones.allSatisfy { milestone in
                          milestone.invoiceID.map { store.invoice(id: $0) != nil } ?? true
                      })

                print("deleting the job keeps the bills:")
                let before = store.invoices(inProject: projectID).count
                store.deleteProject(id: projectID)
                check("project is gone", store.project(id: projectID) == nil)
                check("its invoices survive",
                      store.data.invoices.filter { !$0.isTrashed }.count >= before)
                check("they just belong to nothing",
                      store.data.invoices.allSatisfy { $0.projectID == nil })

                print("round trip through the data file:")
                var sample = AppData()
                var keep = Project()
                keep.name = "Kept"
                keep.contractTotal = 500
                keep.milestones = [Milestone(deliverable: "Cut 1", amount: 500, dueDate: Date())]
                sample.projects = [keep]
                var attached = Invoice()
                attached.projectID = keep.id
                sample.invoices = [attached]
                // Same date strategy the store writes with. A plain
                // JSONEncoder round-trips happily on timestamps the real file
                // would reject, so testing without this proves less than it
                // looks — the app stores dates as ISO 8601.
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                guard let encoded = try? encoder.encode(sample),
                      let decoded = try? decoder.decode(AppData.self, from: encoded) else {
                    print("  FAIL could not round-trip"); exit(1)
                }
                check("projects survive", decoded.projects.first?.name == "Kept")
                check("milestones survive",
                      decoded.projects.first?.milestones.first?.amount == 500)
                check("the invoice keeps its project",
                      decoded.invoices.first?.projectID == keep.id)

                // The reason Invoice and Project decode by hand: a file written
                // before projects existed has no such keys at all.
                let old = Data(#"{"invoices":[{"number":"7"}],"nextInvoiceNumber":8}"#.utf8)
                let migrated = try? decoder.decode(AppData.self, from: old)
                check("a file from before projects still opens", migrated != nil)
                check("and simply has none", migrated?.projects.isEmpty == true)
                check("its invoices belong to no project",
                      migrated?.invoices.first?.projectID == nil)
            }

            print(failures == 0 ? "all project checks passed" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
        if args.contains("--selftest-contract") {
            setvbuf(stdout, nil, _IONBF, 0)
            isolateDataDirectoryForDiagnostics()
            _ = NSApplication.shared
            var failures = 0
            func check(_ label: String, _ condition: Bool) {
                print("  \(condition ? "ok  " : "FAIL") \(label)")
                if !condition { failures += 1 }
            }

            print("amounts are parsed here, never by the model:")
            check("1200", ContractImport.parseAmount("1200") == 1200)
            check("$1,200.00", ContractImport.parseAmount("$1,200.00") == 1200)
            check("150.50", ContractImport.parseAmount("150.50") == Decimal(string: "150.50"))
            check("refuses words", ContractImport.parseAmount("three hundred") == nil)
            check("refuses empty", ContractImport.parseAmount("") == nil)
            check("refuses zero", ContractImport.parseAmount("0") == nil)
            check("refuses two decimal points", ContractImport.parseAmount("1.2.3") == nil)

            print("dates:")
            check("2026-10-30", ContractImport.parseDate("2026-10-30") != nil)
            check("refuses 31 February", ContractImport.parseDate("2026-02-31") == nil)
            check("refuses month 13", ContractImport.parseDate("2026-13-01") == nil)
            check("refuses prose", ContractImport.parseDate("end of October") == nil)
            check("refuses empty", ContractImport.parseDate("") == nil)

            print("a draft keeps what parses and shows what didn't:")
            let fields = ContractImport.Fields(
                clientName: " Lantern Road Media ",
                clientEmail: "dana@lanternroad.example",
                projectTitle: "Night Shift",
                paymentTermDays: 15,
                milestones: [
                    .init(deliverable: "Episodes 2-3", amount: "300", dueDate: "2026-11-06"),
                    .init(deliverable: "Episode 1", amount: "150", dueDate: "2026-10-30"),
                    .init(deliverable: "Bonus", amount: "TBD", dueDate: "2026-12-01"),
                    .init(deliverable: "Wrap", amount: "200", dueDate: ""),
                ])
            let draft = ContractImport.draft(from: fields)
            check("trims the client", draft.customerName == "Lantern Road Media")
            check("keeps the two good payments", draft.milestones.count == 2)
            check("sorted by due date", draft.milestones.first?.deliverable == "Episode 1")
            check("lists the two it refused", draft.discarded.count == 2)
            check("total summed from parsed values", draft.contractTotal == 450)
            check("keeps the payment terms", draft.paymentTermDays == 15)
            let silly = ContractImport.draft(from: .init(paymentTermDays: 9000))
            check("absurd terms fall back to 30", silly.paymentTermDays == 30)

            print("long contracts are trimmed to the parts about money:")
            let boiler = String(repeating: "Boilerplate clause about confidentiality.\n", count: 400)
            let long = "Agreement between Lantern Road Media and the Contractor.\n" + boiler
                + "Compensation: Episode 1, $150, due 2026-10-30.\n" + boiler
            let excerpt = ContractImport.relevantExcerpt(long, limit: 2000)
            check("fits the limit", excerpt.count <= 2000)
            check("keeps the opening", excerpt.contains("Lantern Road Media"))
            check("keeps the compensation clause", excerpt.contains("Episode 1, $150"))
            check("a short contract passes through whole",
                  ContractImport.relevantExcerpt("short", limit: 2000) == "short")

            MainActor.assumeIsolated {
                let store = AppStore.shared
                store.data.projects = []
                store.data.customers = []
                store.commitHistory()

                print("importing creates the job in one undo step:")
                let project = store.importProject(from: draft)
                check("project made", store.project(id: project.id) != nil)
                check("named from the contract", project.name == "Night Shift")
                check("carries the schedule", project.milestones.count == 2)
                check("client created", store.data.customers.count == 1)
                check("project bills that client",
                      project.customerID == store.data.customers.first?.id)
                store.undo()
                check("one undo removes the project", store.data.projects.isEmpty)
                check("and the client it made", store.data.customers.isEmpty)

                print("a returning client is reused, not duplicated:")
                let regular = store.newCustomer(name: "Lantern Road Media")
                store.commitHistory()
                let second = store.importProject(from: draft)
                check("still one client", store.data.customers.count == 1)
                check("pointing at the existing one", second.customerID == regular.id)
            }

            print("reading a real PDF:")
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ig-contract-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let pdfURL = dir.appendingPathComponent("contract.pdf")
            let contractText = """
            INDEPENDENT CONTRACTOR AGREEMENT — POST PRODUCTION

            Client: Lantern Road Media LLC
            Billing contact: dana@lanternroad.example

            Contractor shall edit the podcast series "Night Shift" (8 episodes).

            COMPENSATION
            Episode 1 ............ $150, payable 2026-10-30
            Episodes 2-3 ......... $300, payable 2026-11-06
            Episodes 4-5 ......... $300, payable 2026-11-20
            Episodes 6-8 ......... $450, payable 2026-12-04

            Payment by Zelle within 15 days of invoice.
            """
            // An NSTextView's PDF carries real, selectable text -- the same
            // kind PDFKit reads out of a contract someone emailed.
            MainActor.assumeIsolated {
                let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
                view.string = contractText
                view.font = .systemFont(ofSize: 12)
                try? view.dataWithPDF(inside: view.bounds).write(to: pdfURL)
            }
            let extracted = try? ContractImport.text(fromPDF: pdfURL)
            check("PDFKit gets the text back", extracted?.contains("Lantern Road Media") == true)

            let emptyURL = dir.appendingPathComponent("scan.pdf")
            MainActor.assumeIsolated {
                let blank = NSView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
                try? blank.dataWithPDF(inside: blank.bounds).write(to: emptyURL)
            }
            var refusedScan = false
            do { _ = try ContractImport.text(fromPDF: emptyURL) }
            catch ContractImport.Failure.noText { refusedScan = true }
            catch {}
            check("a PDF with no text is refused, not guessed at", refusedScan)

            if OnDeviceAssist.isReady, let extracted {
                print("on-device extraction (live):")
                nonisolated(unsafe) var live: Result<ContractImport.Draft, Error>?
                Task {
                    do { live = .success(try await ContractImport.extract(from: extracted)) }
                    catch { live = .failure(error) }
                }
                let deadline = Date().addingTimeInterval(120)
                while live == nil, Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
                switch live {
                case .success(let found):
                    print("    client: \(found.customerName)   project: \(found.projectTitle)")
                    for m in found.milestones {
                        print("    \(Fmt.shortDate(m.dueDate))  \(m.deliverable)  \(m.amount)")
                    }
                    check("found the client", found.customerName.contains("Lantern Road"))
                    check("found all four payments", found.milestones.count == 4)
                    check("totals 1200, summed by the app", found.contractTotal == 1200)
                case .failure(let error):
                    check("extraction answered (\(error.localizedDescription))", false)
                case nil:
                    check("extraction answered within 120s", false)
                }
            } else {
                print("  (no on-device model here — skipping the live extraction)")
            }
            try? FileManager.default.removeItem(at: dir)

            print(failures == 0 ? "all contract checks passed" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
        if args.contains("--selftest-uicheck") {
            setvbuf(stdout, nil, _IONBF, 0)
            var failures = 0
            func check(_ label: String, _ ok: Bool) {
                print("  \(ok ? "ok  " : "FAIL") \(label)"); if !ok { failures += 1 }
            }
            let real = URL(fileURLWithPath: "/Users/someone/Library/Application Support/InvoiceGen/data.json")
            print("when UI-check mode may switch the vault off:")
            check("not without the flag",
                  !AppStore.uiCheckAllowed(environment: ["INVOICEGEN_DATA": "/tmp/f.json"], realData: real))
            check("not with the flag but no fixture",
                  !AppStore.uiCheckAllowed(environment: ["INVOICEGEN_UI_CHECK": "1"], realData: real))
            check("not with any value but 1",
                  !AppStore.uiCheckAllowed(environment: ["INVOICEGEN_UI_CHECK": "yes",
                                                         "INVOICEGEN_DATA": "/tmp/f.json"], realData: real))
            check("never on the real data file",
                  !AppStore.uiCheckAllowed(environment: ["INVOICEGEN_UI_CHECK": "1",
                                                         "INVOICEGEN_DATA": real.path], realData: real))
            check("not on the real file reached through a dot-dot path",
                  !AppStore.uiCheckAllowed(environment: ["INVOICEGEN_UI_CHECK": "1",
                      "INVOICEGEN_DATA": "/Users/someone/Library/Application Support/InvoiceGen/../InvoiceGen/data.json"],
                      realData: real))
            check("yes on a fixture with the flag",
                  AppStore.uiCheckAllowed(environment: ["INVOICEGEN_UI_CHECK": "1",
                                                        "INVOICEGEN_DATA": "/tmp/fixture.json"], realData: real))

            if AppStore.isUICheck {
                print("this process is a UI check, so the guards must hold:")
                _ = NSApplication.shared
                MainActor.assumeIsolated {
                    let store = AppStore.shared
                    check("vault never opened", store.vaultStatus == .notOpened)
                    check("not reported as trouble", !store.vaultStatus.isTrouble)
                    check("Keychain returns nothing for the vault key", Keychain.vaultKey() == nil)
                    check("Keychain returns nothing for the publish token", Keychain.publishToken() == nil)
                    let before = (try? FileManager.default.attributesOfItem(
                        atPath: store.storageURL.path)[.modificationDate]) as? Date
                    store.data.business.name += " (edited)"
                    store.saveNow()
                    let after = (try? FileManager.default.attributesOfItem(
                        atPath: store.storageURL.path)[.modificationDate]) as? Date
                    check("saving writes nothing", before == after)
                }
            } else {
                print("  (not a UI-check process: the live guards are exercised with "
                      + "INVOICEGEN_UI_CHECK=1 and a fixture)")
            }
            print(failures == 0 ? "all ui-check checks passed" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
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
            isolateDataDirectoryForDiagnostics()
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
                .task {
                    // Off the launch path: neither a slow network nor an
                    // iCloud file that has to be pulled down may hold up the
                    // window appearing.
                    store.syncCustomers()
                    store.startWatchingCustomerSync()
                    try? await Task.sleep(for: .seconds(4))
                    UpdateController.shared.checkInBackgroundIfDue()
                }
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

            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    UpdateController.shared.checkManually()
                }
                .disabled(updates.isBusy)
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

            CommandGroup(after: .toolbar) {
                Button("Verify Invoice…") {
                    VerifyWindowController.shared.show(store: store)
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
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
    /// The one invoice the detail pane is editing. Nil when nothing -- or more
    /// than one thing -- is selected.
    @Published var invoiceID: UUID? {
        didSet {
            // Everything that already said `focus.invoiceID = x` means "select
            // exactly this one", so keep the set in step rather than making
            // every call site learn about multi-selection.
            if let invoiceID {
                if selectedInvoiceIDs != [invoiceID] { selectedInvoiceIDs = [invoiceID] }
            } else if selectedInvoiceIDs.count <= 1 {
                // Only clear on the way out of a single selection: going nil
                // because two things are selected must not wipe the set.
                if !selectedInvoiceIDs.isEmpty { selectedInvoiceIDs = [] }
            }
        }
    }

    /// Everything selected in the sidebar. One entry is the ordinary case;
    /// more than one puts the detail pane into bulk mode.
    @Published var selectedInvoiceIDs: Set<UUID> = []

    @Published var customerID: UUID?
    @Published var projectID: UUID?
    @Published var requestedSection: SidebarSection?

    var isMultiSelecting: Bool { selectedInvoiceIDs.count > 1 }

    /// Selects exactly these, routing through the single/multi distinction.
    func select(_ ids: Set<UUID>) {
        selectedInvoiceIDs = ids
        invoiceID = ids.count == 1 ? ids.first : nil
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case invoices
    case projects
    case customers
    case items
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .invoices: return "Invoices"
        case .projects: return "Projects"
        case .customers: return "Customers"
        case .items: return "Items"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .invoices: return "doc.text"
        case .projects: return "folder"
        case .customers: return "person.2"
        case .items: return "shippingbox"
        case .settings: return "gearshape"
        }
    }
}
