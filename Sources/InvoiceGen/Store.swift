import Foundation
import SwiftUI
import CryptoKit

/// Everything lives in a single JSON file on disk. No network, no accounts.
final class AppStore: ObservableObject {
    @Published var data: AppData {
        didSet {
            recordHistory(previous: oldValue)
            scheduleSave()
        }
    }

    /// Undo state. Edits made in a burst (typing, dragging a stepper) collapse
    /// into one step, so ⌘Z undoes a change rather than a character.
    /// Surfaced in the UI so a failed integrity check can't pass unnoticed.
    @Published private(set) var vaultStatus: VaultStatus = .empty
    /// Audit trail of payment-detail changes, refreshed on load and on save.
    @Published private(set) var vaultChangeLog: [VaultChange] = []
    /// True when payment details could not be encrypted and are still sitting in
    /// data.json. Surfaced in Settings — never left silent.
    @Published private(set) var secretsUnprotected = false

    /// False until the encrypted vault has been opened. The first Keychain read
    /// in a freshly signed build costs seconds while macOS evaluates the new
    /// signature against the key's ACL, so it happens off the launch path — the
    /// window comes up on data.json alone and payment details arrive after.
    @Published private(set) var secretsLoaded = false

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var undoStack: [AppData] = []
    private var redoStack: [AppData] = []
    private var pendingBaseline: AppData?
    private var historyWorkItem: DispatchWorkItem?
    private var isApplyingHistory = false
    private var isSeeded = false
    private var needsSaveAfterSecrets = false
    private let historyLimit = 60

    private let fileURL: URL
    private var saveWorkItem: DispatchWorkItem?

    static let shared = AppStore()

    init(fileURL: URL? = nil) {
        let url = fileURL ?? AppStore.defaultFileURL()
        self.fileURL = url
        if let existing = AppStore.load(from: url) {
            let migrated = AppStore.migrate(existing)
            self.data = migrated
            self.needsSaveAfterSecrets = migrated != existing
        } else {
            self.data = AppData.seeded()
            self.isSeeded = true
            self.needsSaveAfterSecrets = true
        }
        openVault()
    }

    /// Opens the vault away from the main thread, then folds what it holds into
    /// the data already on screen.
    private func openVault() {
        let wasSeeded = isSeeded
        DispatchQueue.global(qos: .userInitiated).async {
            let contents = PaymentVault.shared.load()
            let status = PaymentVault.shared.status
            let log = PaymentVault.shared.currentChangeLog
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isApplyingHistory = true   // arriving secrets are not an edit
                // Anything already in memory came from a migrated file or from
                // the user editing in the moments before the vault opened —
                // either way it wins, and the next save seals it.
                let hasLocalSecrets = !self.data.business.paymentMethods.isEmpty
                    || self.data.invoices.contains { !$0.paymentMethods.isEmpty }
                    || self.data.templates.contains { !$0.paymentMethods.isEmpty }
                var movedOutOfPlaintext = false
                if !hasLocalSecrets {
                    let merged: AppData
                    (merged, movedOutOfPlaintext) = AppStore.attachSecrets(
                        to: self.data, vault: contents, status: status
                    )
                    // A fresh install starts from the seeded defaults; a
                    // reinstall over an existing vault keeps what it holds.
                    if !wasSeeded || status == .verified { self.data = merged }
                }
                self.isApplyingHistory = false
                self.vaultStatus = status
                self.vaultChangeLog = log
                self.secretsLoaded = true
                if self.needsSaveAfterSecrets || movedOutOfPlaintext { self.saveNow() }
                self.needsSaveAfterSecrets = false
            }
        }
    }

    /// Payment details live in the encrypted vault, never in data.json. Returns
    /// whether plaintext secrets had to be moved out of an older file.
    private static func attachSecrets(
        to data: AppData, vault: VaultContents, status: VaultStatus
    ) -> (AppData, Bool) {
        var data = data

        // Legacy files carry payment methods in the clear; adopt them once.
        let plaintextPresent = !data.business.paymentMethods.isEmpty
            || data.invoices.contains { !$0.paymentMethods.isEmpty }
            || data.templates.contains { !$0.paymentMethods.isEmpty }

        if status.isTrouble {
            // Withhold details that can only have come from a vault we cannot
            // verify. Anything still present in data.json is the user's own
            // copy — keep it, or a failed check would destroy their data.
            if !plaintextPresent {
                data.business.paymentMethods = []
                for index in data.invoices.indices { data.invoices[index].paymentMethods = [] }
                for index in data.templates.indices { data.templates[index].paymentMethods = [] }
            }
            return (data, false)
        }

        if !vault.isEmpty {
            data.business.verificationPassphrase = vault.verificationPassphrase
            data.business.paymentMethods = vault.businessMethods
            for index in data.invoices.indices {
                if let methods = vault.invoiceMethods[data.invoices[index].id.uuidString] {
                    data.invoices[index].paymentMethods = methods
                } else if !plaintextPresent {
                    data.invoices[index].paymentMethods = []
                }
            }
            for index in data.templates.indices {
                if let methods = vault.templateMethods[data.templates[index].id.uuidString] {
                    data.templates[index].paymentMethods = methods
                }
            }
        }
        return (data, vault.isEmpty && plaintextPresent)
    }

    // MARK: - Storage

    static func defaultFileURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["INVOICEGEN_DATA"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("InvoiceGen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("data.json")
    }

    var storageURL: URL { fileURL }

    /// Payment details used to live in the free-text notes field. Where a file
    /// still carries that exact block, turn it into structured methods.
    private static func migrate(_ data: AppData) -> AppData {
        var data = data
        let legacyNotes = """
        Methods of Payment:
        1. Zelle
        Zelle ID: billing@example.com
        Name: FINECUT STUDIO LLC

        2. Bank Details:
        Account number: 000123456789
        Routing number: 123456789
        US Bank Checking
        """
        let isLegacy = { (notes: String) in
            notes.trimmingCharacters(in: .whitespacesAndNewlines)
                == legacyNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if data.business.paymentMethods.isEmpty, isLegacy(data.business.defaultNotes) {
            data.business.paymentMethods = AppData.seededPaymentMethods()
            data.business.defaultNotes = ""
        }
        for index in data.invoices.indices where data.invoices[index].paymentMethods.isEmpty {
            if isLegacy(data.invoices[index].notes) {
                data.invoices[index].paymentMethods = AppData.seededPaymentMethods()
                data.invoices[index].notes = ""
            } else if !data.business.paymentMethods.isEmpty {
                data.invoices[index].paymentMethods = data.business.paymentMethods
            }
        }
        return data
    }

    private static func load(from url: URL) -> AppData? {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AppData.self, from: raw)
    }

    // MARK: - Undo / redo

    private func recordHistory(previous: AppData) {
        guard !isApplyingHistory, previous != data else { return }
        if pendingBaseline == nil { pendingBaseline = previous }

        historyWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.commitHistory() }
        historyWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// Ends the current burst of edits so the next change starts a new step.
    func commitHistory() {
        historyWorkItem?.cancel()
        historyWorkItem = nil
        guard let baseline = pendingBaseline else { return }
        pendingBaseline = nil
        guard baseline != data else { return }

        undoStack.append(baseline)
        if undoStack.count > historyLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        refreshHistoryFlags()
    }

    func undo() {
        commitHistory()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(data)
        apply(previous)
    }

    func redo() {
        commitHistory()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(data)
        apply(next)
    }

    private func apply(_ snapshot: AppData) {
        isApplyingHistory = true
        data = snapshot
        isApplyingHistory = false
        pendingBaseline = nil
        refreshHistoryFlags()
        saveNow()
    }

    private func refreshHistoryFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    func saveNow() {
        // Until the vault has been opened there is nothing of its own to write,
        // and touching it here would race the background open.
        guard secretsLoaded else {
            writeDiskCopy(scrubbedForDisk())
            return
        }

        // Secrets to the encrypted vault, everything else to data.json.
        let secrets = secretsFromCurrentData()
        let vaultSaved = secrets.isEmpty ? true : PaymentVault.shared.save(secrets)
        vaultStatus = PaymentVault.shared.status
        vaultChangeLog = PaymentVault.shared.currentChangeLog
        secretsUnprotected = !vaultSaved && !secrets.isEmpty

        // If the vault could not be written, keeping the details in data.json is
        // the lesser evil: dropping them would lose the user's data outright.
        // The UI says so loudly rather than pretending they are encrypted.
        writeDiskCopy(vaultSaved ? scrubbedForDisk() : data)
    }

    private func writeDiskCopy(_ snapshot: AppData) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let raw = try? encoder.encode(snapshot) else { return }
        try? raw.write(to: fileURL, options: .atomic)
    }

    /// Payment details are sitting in data.json unencrypted because the vault
    /// key is unavailable.
    func repairEncryptionKey() {
        Keychain.deleteKey()
        Keychain.deleteFingerprint()
        PaymentVault.shared.reset()
        vaultStatus = PaymentVault.shared.status
        saveNow()
    }

    private func secretsFromCurrentData() -> VaultContents {
        var contents = VaultContents()
        contents.businessMethods = data.business.paymentMethods
        contents.verificationPassphrase = data.business.verificationPassphrase
        for invoice in data.invoices where !invoice.paymentMethods.isEmpty {
            contents.invoiceMethods[invoice.id.uuidString] = invoice.paymentMethods
        }
        for template in data.templates where !template.paymentMethods.isEmpty {
            contents.templateMethods[template.id.uuidString] = template.paymentMethods
        }
        return contents
    }

    /// The copy that goes to data.json: identical, minus every payment detail.
    func scrubbedForDisk() -> AppData {
        var copy = data
        copy.business.paymentMethods = []
        copy.business.verificationPassphrase = ""   // the salt stays; the secret doesn't
        for index in copy.invoices.indices { copy.invoices[index].paymentMethods = [] }
        for index in copy.templates.indices { copy.templates[index].paymentMethods = [] }
        return copy
    }

    // MARK: - Invoices

    @discardableResult
    func newInvoice(customerID: UUID? = nil) -> Invoice {
        var invoice = Invoice()
        invoice.number = String(data.nextInvoiceNumber)
        invoice.customerID = customerID
        invoice.currencyCode = data.business.currencyCode
        invoice.notes = data.business.defaultNotes
        invoice.footerMessage = data.business.defaultFooterMessage
        invoice.columns = data.business.defaultColumns
        invoice.paymentMethods = data.business.paymentMethods.map { method in
            var copy = method
            copy.id = UUID()
            return copy
        }
        invoice.issueDate = Date()
        invoice.dueDate = Calendar.current.date(
            byAdding: .day, value: data.business.defaultPaymentTermDays, to: Date()
        ) ?? Date()
        invoice.items = [LineItem()]
        data.nextInvoiceNumber += 1
        data.invoices.insert(invoice, at: 0)
        return invoice
    }

    @discardableResult
    func newInvoice(from template: InvoiceTemplate, customerID: UUID? = nil) -> Invoice {
        var invoice = newInvoice(customerID: customerID)
        invoice.title = template.title
        invoice.items = template.items.isEmpty
            ? [LineItem()]
            : template.items.map { item in
                var copy = item
                copy.id = UUID()
                return copy
            }
        invoice.discountIsPercent = template.discountIsPercent
        invoice.discountValue = template.discountValue
        invoice.taxLabel = template.taxLabel
        invoice.taxRate = template.taxRate
        invoice.notes = template.notes
        invoice.footerMessage = template.footerMessage
        invoice.currencyCode = template.currencyCode
        invoice.columns = template.columns
        invoice.dueDate = Calendar.current.date(
            byAdding: .day, value: template.paymentTermDays, to: invoice.issueDate
        ) ?? invoice.dueDate
        if !template.paymentMethods.isEmpty {
            invoice.paymentMethods = template.paymentMethods.map { method in
                var copy = method
                copy.id = UUID()
                return copy
            }
        }
        if let index = data.invoices.firstIndex(where: { $0.id == invoice.id }) {
            data.invoices[index] = invoice
        }
        return invoice
    }

    @discardableResult
    func saveAsTemplate(_ invoice: Invoice, name: String) -> InvoiceTemplate {
        let template = InvoiceTemplate(from: invoice, name: name)
        data.templates.append(template)
        return template
    }

    func binding(templateID: UUID) -> Binding<InvoiceTemplate>? {
        guard data.templates.contains(where: { $0.id == templateID }) else { return nil }
        return Binding(
            get: { [weak self] in
                self?.data.templates.first { $0.id == templateID } ?? InvoiceTemplate()
            },
            set: { [weak self] newValue in
                guard let self,
                      let idx = self.data.templates.firstIndex(where: { $0.id == templateID }) else { return }
                self.data.templates[idx] = newValue
            }
        )
    }

    @discardableResult
    func duplicate(_ invoice: Invoice) -> Invoice {
        var copy = invoice
        copy.id = UUID()
        copy.number = String(data.nextInvoiceNumber)
        copy.status = .draft
        copy.amountPaid = 0
        copy.createdAt = Date()
        copy.issueDate = Date()
        copy.dueDate = Calendar.current.date(
            byAdding: .day, value: data.business.defaultPaymentTermDays, to: Date()
        ) ?? Date()
        copy.items = copy.items.map { item in
            var new = item
            new.id = UUID()
            return new
        }
        data.nextInvoiceNumber += 1
        data.invoices.insert(copy, at: 0)
        return copy
    }

    /// Marking an invoice paid settles it in full — the whole point of the
    /// gesture. ⌘Z puts back both the status and the amount.
    func setStatus(_ status: InvoiceStatus, on id: UUID) {
        guard let index = data.invoices.firstIndex(where: { $0.id == id }) else { return }
        commitHistory()
        data.invoices[index].status = status
        if status == .paid {
            data.invoices[index].amountPaid = data.invoices[index].total
        }
        commitHistory()
    }

    // MARK: - Verification

    /// Derived once per passphrase change — PBKDF2 at 200k iterations is slow
    /// by design, and the printed sheet re-derives nothing.
    private var cachedVerificationKey: (passphrase: String, salt: Data, key: SymmetricKey)?

    var hasVerificationPassphrase: Bool { !data.business.verificationPassphrase.isEmpty }

    var verificationKey: SymmetricKey? {
        let passphrase = data.business.verificationPassphrase
        let salt = data.business.verificationSalt
        guard !passphrase.isEmpty, !salt.isEmpty else { return nil }
        if let cached = cachedVerificationKey,
           cached.passphrase == passphrase, cached.salt == salt {
            return cached.key
        }
        guard let key = Verification.deriveKey(passphrase: passphrase, salt: salt) else { return nil }
        cachedVerificationKey = (passphrase, salt, key)
        return key
    }

    /// The salt is generated once and then never changes: rotating it would
    /// invalidate the code on every invoice already sent.
    func setVerificationPassphrase(_ passphrase: String) {
        commitHistory()
        if data.business.verificationSalt.isEmpty {
            data.business.verificationSalt = Verification.newSalt()
        }
        data.business.verificationPassphrase = passphrase
        cachedVerificationKey = nil
        commitHistory()
        saveNow()
    }

    func verificationCode(for invoice: Invoice) -> String? {
        guard let key = verificationKey else { return nil }
        return Verification.code(for: invoice, key: key)
    }

    func verify(_ scanned: String) -> Verification.Result {
        Verification.verify(scanned, in: data, key: verificationKey)
    }

    // MARK: - Archive and trash

    /// Everything that is live work: not archived, not in the trash.
    var activeInvoices: [Invoice] {
        data.invoices.filter { !$0.isArchived && !$0.isTrashed }
    }

    var archivedInvoices: [Invoice] {
        data.invoices.filter { $0.isArchived && !$0.isTrashed }
    }

    var trashedInvoices: [Invoice] {
        data.invoices.filter { $0.isTrashed }
    }

    func setArchived(_ archived: Bool, on id: UUID) {
        guard let index = data.invoices.firstIndex(where: { $0.id == id }) else { return }
        commitHistory()
        data.invoices[index].archivedAt = archived ? Date() : nil
        commitHistory()
    }

    /// Deleting is a move to the trash, never a destruction. `emptyTrash` and
    /// `permanentlyDelete` are the only things that actually remove an invoice.
    func deleteInvoice(id: UUID) {
        guard let index = data.invoices.firstIndex(where: { $0.id == id }) else { return }
        commitHistory()
        data.invoices[index].deletedAt = Date()
        commitHistory()
    }

    func restoreFromTrash(id: UUID) {
        guard let index = data.invoices.firstIndex(where: { $0.id == id }) else { return }
        commitHistory()
        data.invoices[index].deletedAt = nil
        commitHistory()
    }

    func permanentlyDelete(id: UUID) {
        commitHistory()
        data.invoices.removeAll { $0.id == id }
        commitHistory()
    }

    func emptyTrash() {
        commitHistory()
        data.invoices.removeAll { $0.isTrashed }
        commitHistory()
    }

    func invoice(id: UUID) -> Invoice? {
        data.invoices.first { $0.id == id }
    }

    func binding(invoiceID: UUID) -> Binding<Invoice>? {
        guard let index = data.invoices.firstIndex(where: { $0.id == invoiceID }) else { return nil }
        return Binding(
            get: { [weak self] in
                guard let self else { return Invoice() }
                guard self.data.invoices.indices.contains(index),
                      self.data.invoices[index].id == invoiceID else {
                    return self.data.invoices.first { $0.id == invoiceID } ?? Invoice()
                }
                return self.data.invoices[index]
            },
            set: { [weak self] newValue in
                guard let self,
                      let idx = self.data.invoices.firstIndex(where: { $0.id == invoiceID }) else { return }
                self.data.invoices[idx] = newValue
            }
        )
    }

    // MARK: - Customers

    @discardableResult
    func newCustomer(name: String = "") -> Customer {
        let customer = Customer(name: name)
        data.customers.append(customer)
        sortCustomers()
        return customer
    }

    func deleteCustomer(id: UUID) {
        data.customers.removeAll { $0.id == id }
        for index in data.invoices.indices where data.invoices[index].customerID == id {
            data.invoices[index].customerID = nil
        }
    }

    func customer(id: UUID?) -> Customer? {
        guard let id else { return nil }
        return data.customers.first { $0.id == id }
    }

    func binding(customerID: UUID) -> Binding<Customer>? {
        guard data.customers.contains(where: { $0.id == customerID }) else { return nil }
        return Binding(
            get: { [weak self] in
                self?.data.customers.first { $0.id == customerID } ?? Customer()
            },
            set: { [weak self] newValue in
                guard let self,
                      let idx = self.data.customers.firstIndex(where: { $0.id == customerID }) else { return }
                self.data.customers[idx] = newValue
            }
        )
    }

    func sortCustomers() {
        data.customers.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func invoices(for customerID: UUID) -> [Invoice] {
        data.invoices.filter { $0.customerID == customerID && !$0.isTrashed }
    }

    // MARK: - Catalog

    @discardableResult
    func newCatalogItem() -> CatalogItem {
        let item = CatalogItem(title: "New item")
        data.catalog.append(item)
        return item
    }

    func binding(catalogItemID: UUID) -> Binding<CatalogItem>? {
        guard data.catalog.contains(where: { $0.id == catalogItemID }) else { return nil }
        return Binding(
            get: { [weak self] in
                self?.data.catalog.first { $0.id == catalogItemID } ?? CatalogItem()
            },
            set: { [weak self] newValue in
                guard let self,
                      let idx = self.data.catalog.firstIndex(where: { $0.id == catalogItemID }) else { return }
                self.data.catalog[idx] = newValue
            }
        )
    }

    // MARK: - Backup

    /// Backups leave payment details out by default: a backup file is the
    /// easiest thing in the world to email to the wrong person.
    func exportBackup(to url: URL, includePaymentDetails: Bool = false) throws {
        saveNow()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(includePaymentDetails ? data : scrubbedForDisk())
            .write(to: url, options: .atomic)
    }

    func importBackup(from url: URL) throws {
        let raw = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(AppData.self, from: raw)
        // A restore is an explicit user action, long after launch: the vault is
        // already open and the Keychain read is warm.
        let contents = PaymentVault.shared.load()
        let (withSecrets, _) = AppStore.attachSecrets(
            to: restored, vault: contents, status: PaymentVault.shared.status
        )
        data = withSecrets
        vaultStatus = PaymentVault.shared.status
        secretsLoaded = true
        saveNow()
    }
}
