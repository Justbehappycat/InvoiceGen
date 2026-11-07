import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

enum PDFExporter {

    static func suggestedFileName(for invoice: Invoice) -> String {
        let number = invoice.number.isEmpty ? "draft" : invoice.number
        return "Invoice_\(number)_\(Fmt.fileDate(invoice.dueDate)).pdf"
    }

    /// Renders the invoice as vector PDF data, one US Letter sheet per page.
    @MainActor
    static func makePDFData(
        invoice: Invoice, customer: Customer?, business: BusinessProfile,
        verificationCodeOverride: String? = nil
    ) -> Data? {
        let specs = InvoicePaginator.pages(invoice: invoice, customer: customer, business: business)

        let output = NSMutableData()
        var mediaBox = CGRect(
            x: 0, y: 0, width: InvoiceDocumentView.pageWidth, height: InvoiceDocumentView.pageHeight
        )
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        for spec in specs {
            var view = InvoiceDocumentView(
                invoice: invoice, customer: customer, business: business, page: spec
            )
            view.verificationCodeOverride = verificationCodeOverride
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(width: InvoiceDocumentView.pageWidth, height: nil)

            renderer.render { size, draw in
                // A page that somehow overflows grows rather than losing content.
                let height = max(size.height, InvoiceDocumentView.pageHeight)
                var box = CGRect(x: 0, y: 0, width: InvoiceDocumentView.pageWidth, height: height)
                let info = [kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)]
                ctx.beginPDFPage(info as CFDictionary)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(box)
                draw(ctx)
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
        return output as Data
    }

    /// `afterSaving` runs only once the file is really on disk, and before
    /// Finder is brought forward, which would otherwise cover anything it shows.
    @MainActor
    static func exportWithPanel(invoice: Invoice, customer: Customer?, business: BusinessProfile,
                                afterSaving: () -> Void = {}) {
        guard let data = makePDFData(invoice: invoice, customer: customer, business: business) else {
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedFileName(for: invoice)
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).runModal()
                return
            }
            afterSaving()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Exporting is usually the moment a draft goes out, so offer to record it.
    /// Asked, never assumed: a PDF saved to check the layout hasn't been sent.
    /// An invoice already sent or paid isn't asked about.
    @MainActor
    static func offerToMarkSent(_ id: UUID, in store: AppStore) {
        guard store.invoice(id: id)?.status == .draft else { return }
        let alert = NSAlert()
        alert.messageText = "Mark this invoice as sent?"
        alert.informativeText = "The PDF is saved. You can change the status later."
        alert.addButton(withTitle: "Mark as Sent")
        alert.addButton(withTitle: "Not Yet")
        if alert.runModal() == .alertFirstButtonReturn {
            store.setStatus(.sent, on: id)
        }
    }

    @MainActor
    static func printInvoice(invoice: Invoice, customer: Customer?, business: BusinessProfile) {
        guard let data = makePDFData(invoice: invoice, customer: customer, business: business),
              let document = PDFDocument(data: data) else {
            NSSound.beep()
            return
        }
        let info = NSPrintInfo.shared
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        let operation = document.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: false)
        operation?.run()
    }
}
