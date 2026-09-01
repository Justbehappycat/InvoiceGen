import SwiftUI
import AppKit

/// Which slice of an invoice a rendered sheet contains.
struct InvoicePageSpec: Hashable, Identifiable {
    var start: Int
    var end: Int
    var isFirst: Bool
    var isLast: Bool

    var id: String { "\(start)-\(end)-\(isFirst)-\(isLast)" }

    static func whole(itemCount: Int) -> InvoicePageSpec {
        InvoicePageSpec(start: 0, end: itemCount, isFirst: true, isLast: true)
    }
}

/// Splits an invoice into US Letter sheets by actually measuring the laid-out
/// page, so line items are never cut in half by a page break.
enum InvoicePaginator {

    @MainActor
    static func pages(invoice: Invoice, customer: Customer?, business: BusinessProfile) -> [InvoicePageSpec] {
        let count = invoice.items.count
        guard count > 0 else { return [.whole(itemCount: 0)] }

        // Fast path: the whole invoice on one sheet.
        let whole = InvoicePageSpec.whole(itemCount: count)
        if measuredHeight(invoice: invoice, customer: customer, business: business, page: whole)
            <= InvoiceDocumentView.pageHeight + 0.5 {
            return [whole]
        }

        // Pack items by how much room the rows alone need. Measuring each
        // candidate page as if it were the last would strand a page's worth of
        // space whenever the totals block is what pushed it over.
        var pages: [InvoicePageSpec] = []
        var start = 0

        while start < count {
            let isFirst = pages.isEmpty
            var fitting = start
            var end = start + 1

            while end <= count {
                let isLast = end == count
                let candidate = InvoicePageSpec(start: start, end: end, isFirst: isFirst, isLast: isLast)
                if fits(invoice: invoice, customer: customer, business: business, page: candidate) {
                    fitting = end
                    end += 1
                    continue
                }
                // The rows themselves may still fit — the totals block is what
                // overflowed. Keep the row on this page and let the totals move
                // to a sheet of their own.
                if isLast {
                    let rowsOnly = InvoicePageSpec(start: start, end: end, isFirst: isFirst, isLast: false)
                    if fits(invoice: invoice, customer: customer, business: business, page: rowsOnly) {
                        fitting = end
                    }
                }
                break
            }

            // A single item taller than a page still has to go somewhere.
            if fitting == start { fitting = start + 1 }

            let isLast = fitting == count
                && fits(
                    invoice: invoice, customer: customer, business: business,
                    page: InvoicePageSpec(start: start, end: fitting, isFirst: isFirst, isLast: true)
                )
            pages.append(InvoicePageSpec(start: start, end: fitting, isFirst: isFirst, isLast: isLast))
            start = fitting
        }

        // Totals, payment details and notes did not fit under the final rows.
        if pages.last?.isLast != true {
            pages.append(InvoicePageSpec(start: count, end: count, isFirst: false, isLast: true))
        }
        return pages
    }

    @MainActor
    private static func fits(
        invoice: Invoice, customer: Customer?, business: BusinessProfile, page: InvoicePageSpec
    ) -> Bool {
        measuredHeight(invoice: invoice, customer: customer, business: business, page: page)
            <= InvoiceDocumentView.pageHeight + 0.5
    }

    /// Laying out a page costs a few milliseconds, and pagination needs several
    /// of them, so results are memoised — otherwise every keystroke would pay
    /// the full bill again.
    private struct MeasureKey: Hashable {
        let invoice: Invoice
        let customer: Customer?
        let business: BusinessProfile
        let page: InvoicePageSpec
    }

    @MainActor private static var cache: [MeasureKey: CGFloat] = [:]

    @MainActor
    static func clearCache() { cache.removeAll(keepingCapacity: true) }

    @MainActor
    static func measuredHeight(
        invoice: Invoice,
        customer: Customer?,
        business: BusinessProfile,
        page: InvoicePageSpec
    ) -> CGFloat {
        let key = MeasureKey(invoice: invoice, customer: customer, business: business, page: page)
        if let cached = cache[key] { return cached }
        let height = layoutHeight(invoice: invoice, customer: customer, business: business, page: page)
        if cache.count > 500 { cache.removeAll(keepingCapacity: true) }
        cache[key] = height
        return height
    }

    @MainActor
    private static func layoutHeight(
        invoice: Invoice,
        customer: Customer?,
        business: BusinessProfile,
        page: InvoicePageSpec
    ) -> CGFloat {
        let view = InvoiceDocumentView(
            invoice: invoice, customer: customer, business: business, page: page, padToPageHeight: false
        )
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: InvoiceDocumentView.pageWidth, height: 10)
        return host.fittingSize.height
    }
}
