import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var store: AppStore

    private var business: Binding<BusinessProfile> {
        Binding(get: { store.data.business }, set: { store.data.business = $0 })
    }

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    identity
                    branding
                    columns
                    verification
                    payments
                    security
                    defaults
                    storage
                }
                .padding(20)
                .frame(maxWidth: 640, alignment: .leading)
            }
            .frame(minWidth: 520, idealWidth: 560)

            DocumentPreview(
                invoice: previewInvoice,
                customer: store.data.customers.first ?? Customer(name: "Sample Customer LLC"),
                business: store.data.business
            )
            .frame(minWidth: 300, idealWidth: 520)
        }
        .navigationTitle("Settings")
    }

    private var previewInvoice: Invoice {
        store.data.invoices.first ?? {
            var invoice = Invoice()
            invoice.number = "1"
            invoice.notes = store.data.business.defaultNotes
            invoice.footerMessage = store.data.business.defaultFooterMessage
            invoice.items = [LineItem(title: "Sample service", details: "", quantity: 1, price: 500)]
            return invoice
        }()
    }

    private var identity: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Business name")
                    TextField("", text: business.name)
                }
                GridRow {
                    Text("Address")
                    TextField("Street", text: business.addressLine1)
                }
                GridRow {
                    Text("City")
                    TextField("", text: business.city)
                }
                GridRow {
                    Text("State / region")
                    TextField("", text: business.region)
                }
                GridRow {
                    Text("Postal code")
                    TextField("", text: business.postalCode)
                }
                GridRow {
                    Text("Country")
                    TextField("", text: business.country)
                }
                GridRow {
                    Text("Phone")
                    TextField("", text: business.phone)
                }
                GridRow {
                    Text("Email")
                    TextField("", text: business.email)
                }
                GridRow {
                    Text("Website")
                    TextField("", text: business.website)
                }
            }
            .padding(6)
        } label: {
            Text("Business").font(.headline)
        }
    }

    private var branding: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    Group {
                        if let data = store.data.business.logoData, let image = NSImage(data: data) {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.secondary.opacity(0.15))
                                .overlay(Text("No logo").font(.caption).foregroundColor(.secondary))
                        }
                    }
                    .frame(width: 140, height: 60)

                    VStack(alignment: .leading, spacing: 6) {
                        Button("Choose logo…") { pickLogo() }
                        Button("Remove logo") { store.data.business.logoData = nil }
                            .disabled(store.data.business.logoData == nil)
                    }
                }

                HStack(spacing: 16) {
                    ColorPicker(
                        "Accent color",
                        selection: Binding(
                            get: { Color(hex: store.data.business.accentHex) },
                            set: { store.data.business.accentHex = $0.hexString }
                        ),
                        supportsOpacity: false
                    )
                    .fixedSize()

                    Picker("Template", selection: business.templateStyle) {
                        ForEach(TemplateStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .frame(width: 200)
                }
            }
            .padding(6)
        } label: {
            Text("Branding").font(.headline)
        }
    }

    private var columns: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ColumnSettingsEditor(columns: business.defaultColumns)
                Text("New invoices start from these. Any invoice can override them from the Columns button above its items.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        } label: {
            Text("Line item columns").font(.headline)
        }
    }

    private var payments: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                PaymentMethodsEditor(methods: business.paymentMethods, showEnableToggles: false)
                Text("These appear in the invoice's “How to Pay” block. New invoices copy this list; you can then tweak it per invoice.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(6)
        } label: {
            Text("Payment methods").font(.headline)
        }
    }

    @State private var passphrase = ""
    @State private var passphraseConfirm = ""
    @State private var passphraseNote: String?
    @ObservedObject private var lock = PaymentLock.shared

    private var verification: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: store.hasVerificationPassphrase ? "barcode" : "barcode.viewfinder")
                        .foregroundColor(store.hasVerificationPassphrase ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.hasVerificationPassphrase
                             ? "Invoices carry a verification code."
                             : "No passphrase set — invoices print without a code.")
                        Text("The code is a signature over the invoice number, date, total quantity "
                             + "and total amount. Change any of them and it stops verifying. "
                             + "Same passphrase on another Mac ⇒ same codes.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle("Print the barcode on invoices", isOn: business.printVerificationCode)
                    .disabled(!store.hasVerificationPassphrase)

                Picker("The mark", selection: business.verificationMarkStyle) {
                    ForEach(VerificationMarkStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(!store.hasVerificationPassphrase)

                if store.data.business.verificationMarkStyle == .banner {
                    HStack(spacing: 10) {
                        Text("Stripe tone")
                        Slider(value: business.verificationBarTone, in: 0.02...0.40)
                            .frame(width: 200)
                        Text(String(format: "%.0f%%", store.data.business.verificationBarTone * 100))
                            .font(.callout.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    .padding(.leading, 16)
                } else if store.data.business.verificationMarkStyle == .strip {
                    Picker("Strip tone", selection: business.verificationStripInk) {
                        Text("Quiet — matches the banner").tag(false)
                        Text("Ink — readable by a scanner").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    .padding(.leading, 16)
                }

                markNote

                if lock.isUnlocked {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            Text(store.hasVerificationPassphrase ? "New passphrase" : "Passphrase")
                            SecureField("", text: $passphrase).frame(width: 220)
                        }
                        GridRow {
                            Text("Confirm")
                            SecureField("", text: $passphraseConfirm).frame(width: 220)
                        }
                    }
                    HStack(spacing: 10) {
                        Button(store.hasVerificationPassphrase ? "Change passphrase" : "Set passphrase") {
                            savePassphrase()
                        }
                        .disabled(passphrase.count < 8 || passphrase != passphraseConfirm)
                        if store.hasVerificationPassphrase {
                            Button("Copy current passphrase") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    store.data.business.verificationPassphrase, forType: .string
                                )
                                passphraseNote = "Copied to the clipboard — paste it somewhere safe."
                            }
                        }
                    }
                    Text("At least 8 characters. Changing it invalidates the codes on every invoice "
                         + "already sent, so pick one you'll keep.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Button("Unlock to set the passphrase") {
                        lock.unlock(reason: "set the invoice verification passphrase")
                    }
                }

                if let passphraseNote {
                    Text(passphraseNote).font(.caption).foregroundColor(.secondary)
                }

                Divider()
                Button("Verify an invoice…") {
                    VerifyWindowController.shared.show(store: store)
                }
            }
            .padding(6)
        } label: {
            Text("Invoice verification").font(.headline)
        }
    }

    /// Whether the bars can print straight on the banner colour is a print
    /// question, so the app measures it (print contrast signal, the barcode
    /// standards' own metric) and says what it did.
    /// Print contrast signal is the barcode standards' own metric, so the app
    /// measures it and says plainly what the chosen tone can and can't do.
    /// Says what the chosen mark can actually do, rather than implying a
    /// barcode that isn't one.
    @ViewBuilder
    private var markNote: some View {
        if store.data.business.verificationMarkStyle == .banner {
            let tone = store.data.business.verificationBarTone
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "app.badge.checkmark").foregroundColor(.green)
                Text(String(format: "Stripes at %.0f%% — print contrast %.2f, far under the "
                     + "0.70 a handheld scanner needs, and that's fine: the app reads its own "
                     + "mark by sampling where it knows the stripes are and comparing against "
                     + "the pattern these numbers should produce. Tested down to 2%%. Drop the "
                     + "PDF here to check one.", tone * 100, tone))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if store.data.business.verificationMarkStyle == .letters {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "textformat").foregroundColor(.secondary)
                Text("The code is cut into the letterforms and nothing extends past them. "
                     + "This is a brand mark, not a scannable symbol — Code 128 needs every "
                     + "column, and the gaps between letters delete some. Verification is "
                     + "unaffected: the code prints in the footer, and dropping the PDF here "
                     + "still checks the page against it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            contrastNote
        }
    }

    private var contrastNote: some View {
        let business = store.data.business
        let field = NSColor(Color(hex: business.accentHex))
        let bars = business.verificationStripInk
            ? Verification.inkColor
            : NSColor(Color(hex: business.accentHex).adjustingBrightness(0.78))
        let contrast = Verification.printContrast(bars: bars, onField: field)
        let scannable = contrast >= Verification.minimumContrast
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: scannable ? "barcode.viewfinder" : "eye")
                .foregroundColor(scannable ? .green : .secondary)
            Text(scannable
                 ? "Print contrast \(String(format: "%.2f", contrast)) — above the "
                   + "\(String(format: "%.2f", Verification.minimumContrast)) floor, so a scanner "
                   + "can read the strip off a printed sheet."
                 : "Print contrast \(String(format: "%.2f", contrast)), under the "
                   + "\(String(format: "%.2f", Verification.minimumContrast)) floor. The strip is "
                   + "decorative at this tone: verify by dropping the PDF here, or by the code "
                   + "printed in the footer. Switch to ink if you want it scannable — there is no "
                   + "tone in between that passes.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func savePassphrase() {
        store.setVerificationPassphrase(passphrase)
        passphraseNote = "Saved. New invoices will carry a code."
        passphrase = ""
        passphraseConfirm = ""
    }

    private var security: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: store.vaultStatus.isTrouble
                          ? "exclamationmark.triangle.fill" : "lock.shield.fill")
                        .foregroundColor(store.vaultStatus.isTrouble ? .orange : .green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.secretsLoaded
                             ? store.vaultStatus.message
                             : "Opening the payment vault…")
                        Text("Sealed with AES-GCM under a key in your login Keychain, at \(PaymentVault.shared.vaultURL.lastPathComponent). data.json holds no payment details.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if store.secretsUnprotected {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Payment details could not be encrypted and are stored in plain text in data.json.")
                            Text("This happens when the Keychain key isn't reachable — usually after the app was rebuilt or re-signed. Repairing makes a new key; anything already in the vault becomes unreadable and has to be re-entered.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button("Repair encryption key") { store.repairEncryptionKey() }
                        }
                    }
                }

                if store.vaultStatus.isTrouble, store.secretsLoaded {
                    HStack {
                        Button("Re-enter payment details") {
                            PaymentVault.shared.reset()
                            store.data.business.paymentMethods = []
                        }
                        Button("Trust the current file") {
                            PaymentVault.shared.acceptCurrentFile()
                        }
                        .help("Only if you know why it changed — for example you restored a backup.")
                    }
                }

                Divider()

                Text("Recent changes to payment details").font(.callout.weight(.medium))
                let log = store.vaultChangeLog.reversed().prefix(6)
                if log.isEmpty {
                    Text("No changes recorded yet.").font(.caption).foregroundColor(.secondary)
                } else {
                    ForEach(Array(log)) { entry in
                        HStack {
                            Text(entry.summary).font(.caption)
                            Spacer()
                            Text(Fmt.shortDate(entry.date)).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(6)
        } label: {
            Text("Security").font(.headline)
        }
    }

    private var defaults: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Default currency")
                    Picker("", selection: business.currencyCode) {
                        ForEach(Fmt.currencyCodes, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 110)

                    Spacer()

                    Text("Payment terms")
                    TextField("", value: business.defaultPaymentTermDays, format: .number)
                        .frame(width: 50)
                    Text("days").foregroundColor(.secondary)
                }

                Text("Default notes / terms (anything beyond payment details)").font(.callout)
                TextEditor(text: business.defaultNotes)
                    .frame(height: 150)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))

                Text("Default footer message").font(.callout)
                TextField("", text: business.defaultFooterMessage)

                Text("New invoices start from these values.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(6)
        } label: {
            Text("Invoice defaults").font(.headline)
        }
    }

    private var storage: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Next invoice number")
                    TextField("", value: Binding(
                        get: { store.data.nextInvoiceNumber },
                        set: { store.data.nextInvoiceNumber = max(1, $0) }
                    ), format: .number)
                    .frame(width: 70)
                    Spacer()
                }
                Text(store.storageURL.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Text("InvoiceGen")
                    Text(AppVersion.display)
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                HStack {
                    Button("Reveal data file") {
                        store.saveNow()
                        NSWorkspace.shared.activateFileViewerSelecting([store.storageURL])
                    }
                    Button("Back up…") { backup() }
                    Button("Restore…") { restore() }
                }
            }
            .padding(6)
        } label: {
            Text("Data").font(.headline)
        }
    }

    // MARK: - Panels

    private func pickLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .pdf, .image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            store.data.business.logoData = data
        }
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
