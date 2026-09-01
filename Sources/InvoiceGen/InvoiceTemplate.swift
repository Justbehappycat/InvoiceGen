import Foundation

/// A reusable starting point for an invoice: the line items, terms, tax and
/// payment details you use for a recurring kind of job.
struct InvoiceTemplate: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = "New template"
    var title: String = "INVOICE"
    var items: [LineItem] = []
    var discountIsPercent: Bool = false
    var discountValue: Decimal = 0
    var taxLabel: String = "Tax"
    var taxRate: Decimal = 0
    var paymentTermDays: Int = 30
    var notes: String = ""
    var footerMessage: String = ""
    var paymentMethods: [PaymentMethod] = []
    var currencyCode: String = "USD"
    var columns: InvoiceColumns = InvoiceColumns()

    enum CodingKeys: String, CodingKey {
        case id, name, title, items, discountIsPercent, discountValue, taxLabel, taxRate
        case paymentTermDays, notes, footerMessage, paymentMethods, currencyCode, columns
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Template"
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "INVOICE"
        items = try c.decodeIfPresent([LineItem].self, forKey: .items) ?? []
        discountIsPercent = try c.decodeIfPresent(Bool.self, forKey: .discountIsPercent) ?? false
        discountValue = try c.decodeIfPresent(Decimal.self, forKey: .discountValue) ?? 0
        taxLabel = try c.decodeIfPresent(String.self, forKey: .taxLabel) ?? "Tax"
        taxRate = try c.decodeIfPresent(Decimal.self, forKey: .taxRate) ?? 0
        paymentTermDays = try c.decodeIfPresent(Int.self, forKey: .paymentTermDays) ?? 30
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        footerMessage = try c.decodeIfPresent(String.self, forKey: .footerMessage) ?? ""
        paymentMethods = try c.decodeIfPresent([PaymentMethod].self, forKey: .paymentMethods) ?? []
        currencyCode = try c.decodeIfPresent(String.self, forKey: .currencyCode) ?? "USD"
        columns = try c.decodeIfPresent(InvoiceColumns.self, forKey: .columns) ?? InvoiceColumns()
    }

    /// Snapshot an invoice as a template.
    init(from invoice: Invoice, name: String) {
        self.name = name
        title = invoice.title
        items = invoice.items.map { item in
            var copy = item
            copy.id = UUID()
            return copy
        }
        discountIsPercent = invoice.discountIsPercent
        discountValue = invoice.discountValue
        taxLabel = invoice.taxLabel
        taxRate = invoice.taxRate
        paymentTermDays = max(
            0,
            Calendar.current.dateComponents([.day], from: invoice.issueDate, to: invoice.dueDate).day ?? 30
        )
        notes = invoice.notes
        footerMessage = invoice.footerMessage
        currencyCode = invoice.currencyCode
        columns = invoice.columns
        paymentMethods = invoice.paymentMethods.map { method in
            var copy = method
            copy.id = UUID()
            return copy
        }
    }
}
