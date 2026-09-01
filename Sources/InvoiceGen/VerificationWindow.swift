import SwiftUI
import AppKit

/// "Is this sheet real?" — paste or scan the code from a printed invoice and
/// the app recomputes the signature from its own copy of the invoice.
struct VerifyInvoiceView: View {
    @EnvironmentObject var store: AppStore
    @State private var entry = ""
    @State private var result: Verification.Result?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Verify an invoice")
                .font(.title3.weight(.semibold))
            Text("Scan the barcode on the printed invoice, or type the code beneath it. "
                 + "A handheld scanner types into this field like a keyboard.")
                .font(.callout)
                .foregroundColor(.secondary)
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

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 300)
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
            Image(systemName: icon).foregroundColor(tint).font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.08))
        .cornerRadius(8)
    }

    private func verify() {
        result = store.verify(entry)
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
        let size = NSSize(width: 520, height: 360)
        let root = VerifyInvoiceView()
            .environmentObject(store)
            .frame(minWidth: 460, idealWidth: size.width, minHeight: 300, idealHeight: size.height)
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
