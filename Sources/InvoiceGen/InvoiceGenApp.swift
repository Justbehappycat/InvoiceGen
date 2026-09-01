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
            business.verificationMarkStyle = .banner
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
                    profile.verificationMarkContained = contained
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
                    print("\(label) · bars decode:", decoded ?? "no",
                          mustScan ? (decoded == code ? "ok" : "FAILED — this one must scan")
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
                print("  bars decoded:", report.scannedCode ?? "none",
                      report.scannedCode == genuineCode ? "ok" : "FAILED")
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
                    print("barcode round-trip:", decoded.first == code ? "scans back to the code" : "FAILED \(decoded)")
                } else {
                    print("barcode round-trip: FAILED to render")
                }
            }
            exit(0)
        }
        if args.contains("--selftest-list") {
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
