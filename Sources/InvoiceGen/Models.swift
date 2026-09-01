import Foundation

// MARK: - Business profile

struct BusinessProfile: Codable, Hashable {
    var name: String = "Your Business LLC"
    var addressLine1: String = ""
    var city: String = ""
    var region: String = ""
    var postalCode: String = ""
    var country: String = "United States"
    var phone: String = ""
    var website: String = ""
    var email: String = ""
    var logoData: Data?

    var currencyCode: String = "USD"
    var accentHex: String = "#7C7C7C"
    var templateStyle: TemplateStyle = .banner

    var defaultPaymentTermDays: Int = 30
    var defaultNotes: String = ""
    var defaultFooterMessage: String = "It was a pleasure working with you!"
    var paymentMethods: [PaymentMethod] = []
    var defaultColumns: InvoiceColumns = InvoiceColumns()

    /// Verification: the passphrase is a secret and lives in the vault, never
    /// in data.json. The salt is not secret and must survive a backup restore,
    /// so it stays in the file — without it the same passphrase would derive a
    /// different key and every past code would stop verifying.
    var verificationPassphrase: String = ""
    var verificationSalt: Data = Data()
    var printVerificationCode: Bool = true
    /// The strip under the title. Quiet matches the banner and is the nicer
    /// object; ink is the one a laser scanner can actually read. There is no
    /// middle: print contrast fails everywhere between them.
    var verificationStripInk: Bool = false
    /// True: the mark stays inside the letterforms (decorative).
    /// False: it grows a strip below the word and stays a working barcode.
    var verificationMarkContained: Bool = true

    // Tolerant decoding: older data files simply lack the newer keys.
    enum CodingKeys: String, CodingKey {
        case name, addressLine1, city, region, postalCode, country, phone, website, email
        case logoData, currencyCode, accentHex, templateStyle
        case defaultPaymentTermDays, defaultNotes, defaultFooterMessage, paymentMethods
        case defaultColumns, verificationPassphrase, verificationSalt, printVerificationCode
        case verificationStripInk, verificationMarkContained
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = BusinessProfile()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? fallback.name
        addressLine1 = try c.decodeIfPresent(String.self, forKey: .addressLine1) ?? ""
        city = try c.decodeIfPresent(String.self, forKey: .city) ?? ""
        region = try c.decodeIfPresent(String.self, forKey: .region) ?? ""
        postalCode = try c.decodeIfPresent(String.self, forKey: .postalCode) ?? ""
        country = try c.decodeIfPresent(String.self, forKey: .country) ?? ""
        phone = try c.decodeIfPresent(String.self, forKey: .phone) ?? ""
        website = try c.decodeIfPresent(String.self, forKey: .website) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        logoData = try c.decodeIfPresent(Data.self, forKey: .logoData)
        currencyCode = try c.decodeIfPresent(String.self, forKey: .currencyCode) ?? "USD"
        accentHex = try c.decodeIfPresent(String.self, forKey: .accentHex) ?? fallback.accentHex
        templateStyle = try c.decodeIfPresent(TemplateStyle.self, forKey: .templateStyle) ?? .banner
        defaultPaymentTermDays = try c.decodeIfPresent(Int.self, forKey: .defaultPaymentTermDays) ?? 30
        defaultNotes = try c.decodeIfPresent(String.self, forKey: .defaultNotes) ?? ""
        defaultFooterMessage = try c.decodeIfPresent(String.self, forKey: .defaultFooterMessage)
            ?? fallback.defaultFooterMessage
        paymentMethods = try c.decodeIfPresent([PaymentMethod].self, forKey: .paymentMethods) ?? []
        defaultColumns = try c.decodeIfPresent(InvoiceColumns.self, forKey: .defaultColumns)
            ?? InvoiceColumns()
        verificationPassphrase = try c.decodeIfPresent(String.self, forKey: .verificationPassphrase) ?? ""
        verificationSalt = try c.decodeIfPresent(Data.self, forKey: .verificationSalt) ?? Data()
        printVerificationCode = try c.decodeIfPresent(Bool.self, forKey: .printVerificationCode) ?? true
        verificationStripInk = try c.decodeIfPresent(Bool.self, forKey: .verificationStripInk) ?? false
        verificationMarkContained = try c.decodeIfPresent(
            Bool.self, forKey: .verificationMarkContained) ?? true
    }

    var addressLines: [String] {
        var lines: [String] = []
        if !addressLine1.isEmpty { lines.append(addressLine1) }
        let cityLine = [city, region, postalCode].filter { !$0.isEmpty }.joined(separator: " ")
        if !cityLine.isEmpty { lines.append(cityLine) }
        if !country.isEmpty { lines.append(country) }
        return lines
    }
}

enum TemplateStyle: String, Codable, CaseIterable, Identifiable {
    case banner
    case minimal

    var id: String { rawValue }
    var label: String {
        switch self {
        case .banner: return "Banner"
        case .minimal: return "Minimal"
        }
    }
}

// MARK: - Customer

struct Customer: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var contactName: String = ""
    var email: String = ""
    var phone: String = ""
    var addressLine1: String = ""
    var addressLine2: String = ""
    var city: String = ""
    var region: String = ""
    var postalCode: String = ""
    var country: String = ""
    var notes: String = ""
    var createdAt: Date = Date()

    var displayName: String { name.isEmpty ? "Untitled customer" : name }

    var addressLines: [String] {
        var lines: [String] = []
        if !addressLine1.isEmpty { lines.append(addressLine1) }
        if !addressLine2.isEmpty { lines.append(addressLine2) }
        let cityLine = [city, region, postalCode].filter { !$0.isEmpty }.joined(separator: " ")
        if !cityLine.isEmpty { lines.append(cityLine) }
        if !country.isEmpty { lines.append(country) }
        return lines
    }
}

// MARK: - Line items

struct LineItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String = ""
    var details: String = ""
    var quantity: Decimal = 1
    var price: Decimal = 0
    var taxable: Bool = true

    var amount: Decimal { quantity * price }
}

/// Reusable product / service saved in the catalog.
struct CatalogItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String = ""
    var details: String = ""
    var price: Decimal = 0
    var taxable: Bool = true

    var asLineItem: LineItem {
        LineItem(title: title, details: details, quantity: 1, price: price, taxable: taxable)
    }
}

// MARK: - Invoice

enum InvoiceStatus: String, Codable, CaseIterable, Identifiable {
    case draft
    case sent
    case paid

    var id: String { rawValue }
    var label: String {
        switch self {
        case .draft: return "Draft"
        case .sent: return "Sent"
        case .paid: return "Paid"
        }
    }
}

struct Invoice: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var number: String = "1"
    var poNumber: String = ""
    var title: String = "INVOICE"
    var customerID: UUID?
    var issueDate: Date = Date()
    var dueDate: Date = Date().addingTimeInterval(30 * 86400)
    var items: [LineItem] = []

    var discountIsPercent: Bool = false
    var discountValue: Decimal = 0

    var taxLabel: String = "Tax"
    var taxRate: Decimal = 0

    var amountPaid: Decimal = 0

    var notes: String = ""
    var footerMessage: String = ""
    var currencyCode: String = "USD"
    var status: InvoiceStatus = .draft
    var createdAt: Date = Date()
    var paymentMethods: [PaymentMethod] = []
    var columns: InvoiceColumns = InvoiceColumns()

    var enabledPaymentMethods: [PaymentMethod] {
        paymentMethods.filter { $0.isEnabled && !($0.displayTitle.isEmpty && $0.filledFields.isEmpty) }
    }

    enum CodingKeys: String, CodingKey {
        case id, number, poNumber, title, customerID, issueDate, dueDate, items
        case discountIsPercent, discountValue, taxLabel, taxRate, amountPaid
        case notes, footerMessage, currencyCode, status, createdAt, paymentMethods, columns
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        number = try c.decodeIfPresent(String.self, forKey: .number) ?? "1"
        poNumber = try c.decodeIfPresent(String.self, forKey: .poNumber) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "INVOICE"
        customerID = try c.decodeIfPresent(UUID.self, forKey: .customerID)
        issueDate = try c.decodeIfPresent(Date.self, forKey: .issueDate) ?? Date()
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate) ?? Date()
        items = try c.decodeIfPresent([LineItem].self, forKey: .items) ?? []
        discountIsPercent = try c.decodeIfPresent(Bool.self, forKey: .discountIsPercent) ?? false
        discountValue = try c.decodeIfPresent(Decimal.self, forKey: .discountValue) ?? 0
        taxLabel = try c.decodeIfPresent(String.self, forKey: .taxLabel) ?? "Tax"
        taxRate = try c.decodeIfPresent(Decimal.self, forKey: .taxRate) ?? 0
        amountPaid = try c.decodeIfPresent(Decimal.self, forKey: .amountPaid) ?? 0
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        footerMessage = try c.decodeIfPresent(String.self, forKey: .footerMessage) ?? ""
        currencyCode = try c.decodeIfPresent(String.self, forKey: .currencyCode) ?? "USD"
        status = try c.decodeIfPresent(InvoiceStatus.self, forKey: .status) ?? .draft
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        paymentMethods = try c.decodeIfPresent([PaymentMethod].self, forKey: .paymentMethods) ?? []
        columns = try c.decodeIfPresent(InvoiceColumns.self, forKey: .columns) ?? InvoiceColumns()
    }

    // MARK: Totals

    var subtotal: Decimal { items.reduce(0) { $0 + $1.amount } }

    var discountAmount: Decimal {
        guard discountValue > 0 else { return 0 }
        if discountIsPercent {
            return (subtotal * discountValue / 100).rounded(2)
        }
        return min(discountValue, subtotal)
    }

    var taxableBase: Decimal {
        let taxableSum = items.filter { $0.taxable }.reduce(Decimal(0)) { $0 + $1.amount }
        guard subtotal > 0, discountAmount > 0 else { return taxableSum }
        // Spread the discount proportionally across the taxable portion.
        return (taxableSum - discountAmount * taxableSum / subtotal).rounded(2)
    }

    var taxAmount: Decimal {
        guard taxRate > 0 else { return 0 }
        return (taxableBase * taxRate / 100).rounded(2)
    }

    var total: Decimal { (subtotal - discountAmount + taxAmount).rounded(2) }

    var amountDue: Decimal { (total - amountPaid).rounded(2) }

    /// Sidebar ordering: overdue first, then everything still owed, then paid.
    var sortRank: Int {
        if status == .paid { return 2 }
        return isOverdue ? 0 : 1
    }

    var isOverdue: Bool {
        status != .paid && amountDue > 0 && dueDate < Calendar.current.startOfDay(for: Date())
    }
}

extension Decimal {
    func rounded(_ scale: Int) -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, .plain)
        return result
    }
}

// MARK: - Persisted document

struct AppData: Codable, Equatable {
    var business: BusinessProfile = BusinessProfile()
    var customers: [Customer] = []
    var invoices: [Invoice] = []
    var catalog: [CatalogItem] = []
    var templates: [InvoiceTemplate] = []
    var nextInvoiceNumber: Int = 1

    enum CodingKeys: String, CodingKey {
        case business, customers, invoices, catalog, templates, nextInvoiceNumber
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        business = try c.decodeIfPresent(BusinessProfile.self, forKey: .business) ?? BusinessProfile()
        customers = try c.decodeIfPresent([Customer].self, forKey: .customers) ?? []
        invoices = try c.decodeIfPresent([Invoice].self, forKey: .invoices) ?? []
        catalog = try c.decodeIfPresent([CatalogItem].self, forKey: .catalog) ?? []
        templates = try c.decodeIfPresent([InvoiceTemplate].self, forKey: .templates) ?? []
        nextInvoiceNumber = try c.decodeIfPresent(Int.self, forKey: .nextInvoiceNumber) ?? 1
    }
}
