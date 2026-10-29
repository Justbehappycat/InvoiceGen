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
    var verificationMarkStyle: VerificationMarkStyle = .banner
    /// How much darker than the banner the bars print, 0…1. The app reads its
    /// own mark by local contrast, so this can go as low as taste allows —
    /// it does not have to clear the scanner standards' 0.70.
    /// How dark the verification stripes print, as a fraction of the banner.
    /// Four percent, not ten: the app reads its own mark at 100% all the way
    /// down to 2%, so a tone that bands visibly across the header buys no
    /// verification strength. The slider still goes to 40% for anyone who
    /// wants a scanner to manage it.
    var verificationBarTone: Double = 0.04
    /// Whether the one-time correction below has already run for this file.
    var markStyleMigrated: Bool = true
    /// False only in a file written before the tone default changed.
    var barToneMigrated: Bool = true
    /// Where published invoices are served from, e.g. https://invoice.finecut.com
    /// The token that goes with it lives in the Keychain, never in data.json.
    var publishBaseURL: String = ""

    // Tolerant decoding: older data files simply lack the newer keys.
    enum CodingKeys: String, CodingKey {
        case name, addressLine1, city, region, postalCode, country, phone, website, email
        case logoData, currencyCode, accentHex, templateStyle
        case defaultPaymentTermDays, defaultNotes, defaultFooterMessage, paymentMethods
        case defaultColumns, verificationPassphrase, verificationSalt, printVerificationCode
        case verificationStripInk, verificationMarkContained
        case verificationMarkStyle, verificationBarTone, markStyleMigrated, barToneMigrated
        case publishBaseURL
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
        // A file that predates the style enum carries no preference at all, so
        // it gets the current default. Only a file that *explicitly* chose the
        // contained mark keeps it — mapping a missing key to `true` and then
        // to `.letters` silently pinned every existing file to the old style.
        let containedChoice = try c.decodeIfPresent(Bool.self, forKey: .verificationMarkContained)
        verificationMarkContained = containedChoice ?? true
        verificationMarkStyle = try c.decodeIfPresent(
            VerificationMarkStyle.self, forKey: .verificationMarkStyle)
            ?? containedChoice.map { $0 ? .letters : .strip }
            ?? .banner
        verificationBarTone = try c.decodeIfPresent(Double.self, forKey: .verificationBarTone) ?? 0.04
        markStyleMigrated = try c.decodeIfPresent(Bool.self, forKey: .markStyleMigrated) ?? false
        barToneMigrated = try c.decodeIfPresent(Bool.self, forKey: .barToneMigrated) ?? false
        publishBaseURL = try c.decodeIfPresent(String.self, forKey: .publishBaseURL) ?? ""
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

/// Where the verification code lives on the sheet.
enum VerificationMarkStyle: String, Codable, CaseIterable, Identifiable {
    /// Cut into the letterforms; nothing extends past the word.
    case letters
    /// The word, growing a strip of the same columns below it.
    case strip
    /// Stripes across the banner, the title sitting over them — the bars run
    /// the banner's full height, so a reading taken above or below the title
    /// crosses every column.
    case banner

    var id: String { rawValue }
    var label: String {
        switch self {
        case .letters: return "Inside the letters"
        case .strip: return "Word with a strip below"
        case .banner: return "Stripes across the banner"
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
    /// When this customer was last edited, used to settle iCloud merges.
    /// Optional because Swift's synthesized decoder ignores default values
    /// for missing keys -- a non-optional here would fail to decode every
    /// customer already written to disk. Nil means "as old as createdAt".
    var updatedAt: Date?

    var changedAt: Date { updatedAt ?? createdAt }

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

/// A job: one production, one contract, one set of deadlines.
///
/// Film and post work is billed per production, not per invoice. A podcast
/// series is one agreement with a payment schedule running down it, and the
/// question that matters mid-job is "what have I invoiced against this, and
/// what is still owed" — which no single invoice can answer.
struct Project: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var customerID: UUID?
    /// What the contract is worth in total. Zero means it was never stated —
    /// plenty of jobs are open-ended, so this stays optional in spirit.
    var contractTotal: Decimal = 0
    var milestones: [Milestone] = []
    var notes: String = ""
    var createdAt: Date = Date()
    /// Finished and filed away, the way an archived invoice is.
    var archivedAt: Date?

    var isArchived: Bool { archivedAt != nil }
    var displayName: String { name.isEmpty ? "Untitled project" : name }
    var hasContractTotal: Bool { contractTotal > 0 }

    /// The schedule's own total, which is not always the contract's: a job can
    /// be scheduled in part, or carry a milestone added later.
    var scheduledTotal: Decimal {
        milestones.reduce(0) { $0 + $1.amount }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, customerID, contractTotal, milestones, notes, createdAt, archivedAt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        customerID = try c.decodeIfPresent(UUID.self, forKey: .customerID)
        contractTotal = try c.decodeIfPresent(Decimal.self, forKey: .contractTotal) ?? 0
        milestones = try c.decodeIfPresent([Milestone].self, forKey: .milestones) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
    }
}

/// One scheduled payment: a deliverable, what it pays, and when it is due.
///
/// `invoiceID` is the link back to the invoice this milestone produced, so the
/// schedule can show what has been billed without guessing. It stays nil until
/// the invoice is made, and goes back to nil if that invoice is destroyed.
struct Milestone: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var deliverable: String = ""
    var amount: Decimal = 0
    var dueDate: Date = Date()
    var invoiceID: UUID?

    var isInvoiced: Bool { invoiceID != nil }
    var displayName: String { deliverable.isEmpty ? "Untitled milestone" : deliverable }

    enum CodingKeys: String, CodingKey {
        case id, deliverable, amount, dueDate, invoiceID
    }

    init() {}

    init(deliverable: String, amount: Decimal, dueDate: Date) {
        self.deliverable = deliverable
        self.amount = amount
        self.dueDate = dueDate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        deliverable = try c.decodeIfPresent(String.self, forKey: .deliverable) ?? ""
        amount = try c.decodeIfPresent(Decimal.self, forKey: .amount) ?? 0
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate) ?? Date()
        invoiceID = try c.decodeIfPresent(UUID.self, forKey: .invoiceID)
    }
}

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
    /// The job this invoice belongs to, if any.
    var projectID: UUID?
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

    /// Set aside: finished business, kept for the record but out of the way.
    /// Archived invoices don't appear in the working list and don't count
    /// toward the outstanding totals.
    var archivedAt: Date?
    /// In the trash. Nothing is destroyed until the trash is emptied, so a
    /// mis-click costs nothing even after the undo history is gone.
    var deletedAt: Date?

    /// The id this invoice is published under, if it is. Kept so re-publishing
    /// reuses the same link and a client's bookmark keeps working.
    var publishedID: String?
    var publishedAt: Date?

    var enabledPaymentMethods: [PaymentMethod] {
        paymentMethods.filter { $0.isEnabled && !($0.displayTitle.isEmpty && $0.filledFields.isEmpty) }
    }

    enum CodingKeys: String, CodingKey {
        case id, number, poNumber, title, customerID, projectID, issueDate, dueDate, items
        case discountIsPercent, discountValue, taxLabel, taxRate, amountPaid
        case notes, footerMessage, currencyCode, status, createdAt, paymentMethods, columns
        case archivedAt, deletedAt, publishedID, publishedAt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        number = try c.decodeIfPresent(String.self, forKey: .number) ?? "1"
        poNumber = try c.decodeIfPresent(String.self, forKey: .poNumber) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "INVOICE"
        customerID = try c.decodeIfPresent(UUID.self, forKey: .customerID)
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
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
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        publishedID = try c.decodeIfPresent(String.self, forKey: .publishedID)
        publishedAt = try c.decodeIfPresent(Date.self, forKey: .publishedAt)
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

    var isArchived: Bool { archivedAt != nil }
    var isTrashed: Bool { deletedAt != nil }
    /// The year an archived invoice is filed under.
    var year: Int { Calendar.current.component(.year, from: issueDate) }

    /// Sidebar ordering: overdue first, then everything still owed, then paid.
    var sortRank: Int {
        if status == .paid { return 2 }
        return isOverdue ? 0 : 1
    }

    var isOverdue: Bool {
        status != .paid && !isArchived && !isTrashed
            && amountDue > 0 && dueDate < Calendar.current.startOfDay(for: Date())
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
    var projects: [Project] = []
    var templates: [InvoiceTemplate] = []
    var nextInvoiceNumber: Int = 1

    enum CodingKeys: String, CodingKey {
        case business, customers, invoices, catalog, projects, templates, nextInvoiceNumber
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        business = try c.decodeIfPresent(BusinessProfile.self, forKey: .business) ?? BusinessProfile()
        customers = try c.decodeIfPresent([Customer].self, forKey: .customers) ?? []
        invoices = try c.decodeIfPresent([Invoice].self, forKey: .invoices) ?? []
        catalog = try c.decodeIfPresent([CatalogItem].self, forKey: .catalog) ?? []
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        templates = try c.decodeIfPresent([InvoiceTemplate].self, forKey: .templates) ?? []
        nextInvoiceNumber = try c.decodeIfPresent(Int.self, forKey: .nextInvoiceNumber) ?? 1
    }
}
