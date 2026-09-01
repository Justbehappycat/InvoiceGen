import SwiftUI
import AppKit

/// "Is this sheet real?" — paste or scan the code from a printed invoice and
/// the app recomputes the signature from its own copy of the invoice.
struct VerifyInvoiceView: View {
    @EnvironmentObject var store: AppStore
    @State private var entry = ""
    @State private var result: Verification.Result?
    @State private var pdfReport: PDFVerificationReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Verify an invoice")
                .font(.title3.weight(.semibold))
            Text("Scan the barcode on the printed invoice, or type the code beneath it. "
                 + "A handheld scanner types into this field like a keyboard.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("IG1-11-4A7C9E2B", text: $entry)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(verify)
                Button("Verify", action: verify)
                    .keyboardShortcut(.defaultAction)
                    .disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let result {
                resultPanel(result)
            }

            Divider()

            HStack(spacing: 10) {
                Button("Choose PDF…") { choosePDF() }
                Text("Checks the file itself: reads the bars, then re-reads the numbers "
                     + "printed on the page and recomputes the signature from those.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let pdfReport {
                pdfPanel(pdfReport)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 420)
        .onChange(of: entry) { _ in result = nil }
    }

    @ViewBuilder
    private func resultPanel(_ result: Verification.Result) -> some View {
        switch result {
        case .valid(let id, let number):
            panel(
                icon: "checkmark.seal.fill", tint: .green,
                title: "Invoice #\(number) is genuine",
                detail: detailLine(id)
            )
        case .mismatch(let number):
            panel(
                icon: "exclamationmark.triangle.fill", tint: .orange,
                title: "Code does not match invoice #\(number)",
                detail: "The number, date, quantity or total on the printed sheet differs from "
                    + "the invoice held here — or the code was produced with a different passphrase."
            )
        case .unknownInvoice(let number):
            panel(
                icon: "questionmark.circle.fill", tint: .orange,
                title: "No invoice #\(number) on this Mac",
                detail: "The code is well-formed, but this copy of InvoiceGen has no invoice with that number."
            )
        case .malformed:
            panel(
                icon: "xmark.octagon.fill", tint: .red,
                title: "That isn't a verification code",
                detail: "Codes look like IG1-11-4A7C9E2B — the prefix, the invoice number, "
                    + "and eight hex digits."
            )
        case .noPassphrase:
            panel(
                icon: "key.slash", tint: .orange,
                title: "No verification passphrase set",
                detail: "Set one in Settings ▸ Security before codes can be produced or checked."
            )
        }
    }

    private func detailLine(_ id: UUID) -> String {
        guard let invoice = store.invoice(id: id) else { return "" }
        let customer = store.customer(id: invoice.customerID)?.displayName ?? "no customer"
        return "\(customer) · \(Fmt.longDate(invoice.issueDate)) · "
            + "\(Fmt.quantity(Verification.totalQuantity(of: invoice))) items · "
            + "\(Fmt.currency(invoice.total, code: invoice.currencyCode)) total"
    }

    private func panel(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.08))
        .clipShape(.rect(cornerRadius: 8))
    }

    private func verify() {
        pdfReport = nil
        result = store.verify(entry)
    }

    private func choosePDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an invoice PDF to verify"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        result = nil
        pdfReport = PDFVerifier.verify(url: url, store: store)
    }

    @ViewBuilder
    private func pdfPanel(_ report: PDFVerificationReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch report.verdict {
            case .genuine:
                panel(icon: "checkmark.seal.fill", tint: .green,
                      title: "\(report.fileName) is genuine",
                      detail: "The numbers printed on the page reproduce the code the page carries"
                        + (report.recordFound ? ", and they match the invoice held here." : "."))
            case .tampered:
                panel(icon: "exclamationmark.triangle.fill", tint: .red,
                      title: "\(report.fileName) does not match its own code",
                      detail: "The invoice number, date, item count or total on this page has been "
                        + "changed since it was signed — or it was signed with a different passphrase.")
            case .differsFromRecord:
                panel(icon: "exclamationmark.circle.fill", tint: .orange,
                      title: "Page is internally consistent, but differs from our copy",
                      detail: report.differencesFromRecord.joined(separator: "; ")
                        + ". The PDF is intact, so the invoice was probably edited here after it was sent.")
            case .noCode:
                panel(icon: "barcode.viewfinder", tint: .orange,
                      title: "No verification code on that PDF",
                      detail: "Neither a barcode nor a printed code was found — it may pre-date "
                        + "verification, or have been produced with the code switched off.")
            case .unreadable:
                panel(icon: "questionmark.circle.fill", tint: .orange,
                      title: "Couldn't check \(report.fileName)",
                      detail: report.notes.joined(separator: " "))
            }

            // What the page says, in the app's own words, so a mismatch is
            // legible rather than a verdict you have to take on faith.
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                if let code = report.scannedCode ?? report.printedCode {
                    GridRow { Text("Code").gridColumnAlignment(.trailing); Text(code).monospaced() }
                }
                if let number = report.number {
                    GridRow { Text("Number").gridColumnAlignment(.trailing); Text(number) }
                }
                if let date = report.date {
                    GridRow { Text("Date").gridColumnAlignment(.trailing); Text(Fmt.longDate(date)) }
                }
                if let quantity = report.quantity {
                    GridRow { Text("Items").gridColumnAlignment(.trailing); Text(Fmt.quantity(quantity)) }
                }
                if let agreement = report.stripeAgreement {
                    GridRow {
                        Text("Mark").gridColumnAlignment(.trailing)
                        Text(String(format: "read off the page, %.0f%% match", agreement * 100))
                    }
                }
                if let total = report.total {
                    GridRow {
                        Text("Total").gridColumnAlignment(.trailing)
                        Text(Fmt.currency(total, code: store.data.business.currencyCode))
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ForEach(report.notes, id: \.self) { note in
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Owned directly, for the same reason the Settings window is.
@MainActor
final class VerifyWindowController: NSObject, NSWindowDelegate {
    static let shared = VerifyWindowController()
    private var window: NSWindow?

    func show(store: AppStore) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let size = NSSize(width: 560, height: 560)
        let root = VerifyInvoiceView()
            .environmentObject(store)
            .frame(minWidth: 460, idealWidth: size.width, minHeight: 420, idealHeight: size.height)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Verify Invoice"
        let hosting = NSHostingController(rootView: root)
        hosting.view.frame = NSRect(origin: .zero, size: size)
        window.contentViewController = hosting
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
