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
    private var historyTask: Task<Void, Never>?
    private var isApplyingHistory = false
    private var isSeeded = false
    private var needsSaveAfterSecrets = false
    private let historyLimit = 60

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

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

        // One-time correction of a bad default. When the mark-style setting
        // was introduced, a file that predated it was mapped through the old
        // "contained" flag, whose default was true — so every existing file
        // was silently pinned to the in-letter mark rather than taking the
        // current default. This puts those files right, once, and records that
        // it ran so a later deliberate choice of the in-letter mark sticks.
        if !data.business.markStyleMigrated {
            if data.business.verificationMarkStyle == .letters {
                data.business.verificationMarkStyle = .banner
            }
            data.business.markStyleMigrated = true
        }

        // The banner tone shipped at 10%, which bands visibly across a grey
        // header while buying nothing: the app's own reader matches 100% at
        // every tone from 30% down to 2%, so 4% verifies exactly as well and
        // stops the stripes dominating the page. A tone already moved off the
        // old default was chosen deliberately, so it is left alone.
        if !data.business.barToneMigrated {
            if data.business.verificationBarTone == 0.10 {
                data.business.verificationBarTone = 0.04
            }
            data.business.barToneMigrated = true
        }
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

        // A cancellable Task *is* the debounce: reassigning cancels the last
        // one, and the sleep throws on cancellation, so the burst collapses
        // into a single step without a work item to juggle.
        historyTask?.cancel()
        historyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.commitHistory()
        }
    }

    /// Ends the current burst of edits so the next change starts a new step.
    func commitHistory() {
        historyTask?.cancel()
        historyTask = nil
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
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
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

        pushCustomersIfChanged()
    }

    /// Customers last handed to iCloud, so an invoice edit does not cause a
    /// pointless write of an unchanged customer list.
    private var lastPushedCustomers: [Customer]?

    /// saveNow runs in a handful of non-isolated contexts, and iCloud touches
    /// @AppStorage and @Published, so the hop to the main actor happens here
    /// rather than forcing isolation up through every caller of saveNow.
    private func pushCustomersIfChanged() {
        Task { @MainActor [weak self] in
            guard let self, CustomerSync.shared.isEnabled, CustomerSync.isAvailable else { return }
            guard self.data.customers != self.lastPushedCustomers else { return }
            self.lastPushedCustomers = self.data.customers
            self.syncCustomers()
            // syncCustomers may have merged in remote edits; record what we
            // actually ended up with so the next save compares against that.
            self.lastPushedCustomers = self.data.customers
        }
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

    /// Whether an address *and* a token are both present.
    var publishingIsConfigured: Bool { PublishService.target(for: data.business) != nil }

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
        unlinkMilestones(fromInvoices: [id])
        commitHistory()
    }

    func emptyTrash() {
        commitHistory()
        let gone = Set(data.invoices.filter { $0.isTrashed }.map(\.id))
        data.invoices.removeAll { $0.isTrashed }
        unlinkMilestones(fromInvoices: gone)
        commitHistory()
    }

    // MARK: - Projects
    //
    // A project is the job; invoices are what it bills. Everything here keeps
    // the two in step, because a schedule that lies about what has been
    // invoiced is worse than no schedule at all.

    /// Invoiced / paid against a job. Trashed invoices are excluded — they are
    /// not bills any more — while archived ones still count, because the work
    /// happened and was billed.
    struct ProjectTotals: Equatable {
        var invoiced: Decimal = 0
        var paid: Decimal = 0
        var outstanding: Decimal { (invoiced - paid).rounded(2) }
        var invoiceCount: Int = 0

        /// What is left of the contract to bill. Nil when no contract total was
        /// given, rather than a misleading zero.
        func remainingToBill(contractTotal: Decimal) -> Decimal? {
            guard contractTotal > 0 else { return nil }
            return (contractTotal - invoiced).rounded(2)
        }
    }

    /// The invoice a milestone was billed with, but only while that invoice is
    /// alive. A trashed invoice is not a bill any more — the totals already
    /// leave it out — so the schedule must stop calling the milestone done and
    /// offer to bill it again. Otherwise the two halves of this screen
    /// contradict each other: "Invoice #12" beside "$0.00 invoiced".
    func billedInvoice(for milestone: Milestone) -> Invoice? {
        guard let id = milestone.invoiceID,
              let invoice = invoice(id: id),
              !invoice.isTrashed
        else { return nil }
        return invoice
    }

    func needsInvoicing(_ milestone: Milestone) -> Bool {
        billedInvoice(for: milestone) == nil
    }

    func project(id: UUID?) -> Project? {
        guard let id else { return nil }
        return data.projects.first { $0.id == id }
    }

    func binding(projectID: UUID) -> Binding<Project>? {
        guard data.projects.contains(where: { $0.id == projectID }) else { return nil }
        return Binding(
            get: { [weak self] in
                self?.data.projects.first { $0.id == projectID } ?? Project()
            },
            set: { [weak self] newValue in
                guard let self,
                      let idx = self.data.projects.firstIndex(where: { $0.id == projectID })
                else { return }
                self.data.projects[idx] = newValue
            }
        )
    }

    /// Live invoices for a job, newest first. Trashed ones are left out.
    func invoices(inProject projectID: UUID) -> [Invoice] {
        data.invoices.filter { $0.projectID == projectID && !$0.isTrashed }
    }

    func totals(forProject projectID: UUID) -> ProjectTotals {
        var totals = ProjectTotals()
        for invoice in invoices(inProject: projectID) {
            totals.invoiced += invoice.total
            totals.paid += invoice.amountPaid
            totals.invoiceCount += 1
        }
        totals.invoiced = totals.invoiced.rounded(2)
        totals.paid = totals.paid.rounded(2)
        return totals
    }

    @discardableResult
    func newProject(customerID: UUID? = nil) -> Project {
        commitHistory()
        var project = Project()
        project.customerID = customerID
        data.projects.insert(project, at: 0)
        commitHistory()
        return project
    }

    /// Removes the job but never its invoices: they are real bills that were
    /// really sent. They just stop belonging to anything.
    func deleteProject(id: UUID) {
        commitHistory()
        data.projects.removeAll { $0.id == id }
        for index in data.invoices.indices where data.invoices[index].projectID == id {
            data.invoices[index].projectID = nil
        }
        commitHistory()
    }

    func setArchived(_ archived: Bool, onProject id: UUID) {
        guard let index = data.projects.firstIndex(where: { $0.id == id }) else { return }
        commitHistory()
        data.projects[index].archivedAt = archived ? Date() : nil
        commitHistory()
    }

    /// Turns one scheduled payment into a draft invoice and links the two.
    ///
    /// A draft, deliberately: the schedule says when something is *due*, not
    /// that it is ready to send. Returns nil if the milestone has already been
    /// invoiced, so pressing the button twice cannot bill a client twice.
    @discardableResult
    func createInvoice(forMilestone milestoneID: UUID, inProject projectID: UUID) -> Invoice? {
        commitHistory()
        let made = makeInvoice(forMilestone: milestoneID, inProject: projectID)
        commitHistory()
        return made
    }

    /// The mutation with no history of its own, so a batch can run it many
    /// times inside a single step.
    @discardableResult
    private func makeInvoice(forMilestone milestoneID: UUID, inProject projectID: UUID) -> Invoice? {
        guard let projectIndex = data.projects.firstIndex(where: { $0.id == projectID }),
              let milestoneIndex = data.projects[projectIndex].milestones
                  .firstIndex(where: { $0.id == milestoneID }),
              needsInvoicing(data.projects[projectIndex].milestones[milestoneIndex])
        else { return nil }

        let project = data.projects[projectIndex]
        let milestone = project.milestones[milestoneIndex]

        var invoice = newInvoice(customerID: project.customerID)
        invoice.projectID = projectID
        invoice.dueDate = milestone.dueDate
        invoice.items = [LineItem(
            title: milestone.deliverable,
            details: "",
            quantity: 1,
            price: milestone.amount,
            taxable: false
        )]
        // newInvoice already inserted a copy; replace it with the filled one.
        if let index = data.invoices.firstIndex(where: { $0.id == invoice.id }) {
            data.invoices[index] = invoice
        }
        data.projects[projectIndex].milestones[milestoneIndex].invoiceID = invoice.id
        return invoice
    }

    /// Bills every milestone that has not been billed yet, oldest due date
    /// first so the invoice numbers run in the order the money is owed. One
    /// history step for the batch, like the other bulk edits.
    @discardableResult
    func createInvoicesForUnbilled(inProject projectID: UUID) -> [Invoice] {
        guard let projectIndex = data.projects.firstIndex(where: { $0.id == projectID })
        else { return [] }
        let pending = data.projects[projectIndex].milestones
            .filter { needsInvoicing($0) }
            .sorted { $0.dueDate < $1.dueDate }
        guard !pending.isEmpty else { return [] }

        commitHistory()
        var made: [Invoice] = []
        for milestone in pending {
            if let invoice = makeInvoice(forMilestone: milestone.id, inProject: projectID) {
                made.append(invoice)
            }
        }
        commitHistory()
        return made
    }

    /// Creates the job a contract describes: the client if they are new, the
    /// project, and its schedule. One history step, so a misread contract is
    /// one ⌘Z away from never having happened.
    ///
    /// An existing client with the same name is reused rather than duplicated
    /// -- importing the second contract from a regular client should not leave
    /// two of them in the list.
    @discardableResult
    func importProject(from draft: ContractImport.Draft) -> Project {
        commitHistory()

        var customerID: UUID?
        let wanted = draft.customerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !wanted.isEmpty {
            if let existing = data.customers.first(where: {
                $0.name.caseInsensitiveCompare(wanted) == .orderedSame
            }) {
                customerID = existing.id
            } else {
                var customer = Customer()
                customer.name = wanted
                customer.email = draft.customerEmail
                customer.updatedAt = Date()
                data.customers.append(customer)
                customerID = customer.id
            }
        }

        var project = Project()
        project.name = draft.projectTitle
        project.customerID = customerID
        project.contractTotal = draft.contractTotal
        project.milestones = draft.milestones
        data.projects.insert(project, at: 0)

        commitHistory()
        return project
    }

    /// Called when invoices are destroyed for good: a milestone must never
    /// point at an invoice that is gone, or the schedule shows work as billed
    /// that has no bill behind it.
    private func unlinkMilestones(fromInvoices ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for p in data.projects.indices {
            for m in data.projects[p].milestones.indices
            where data.projects[p].milestones[m].invoiceID.map(ids.contains) == true {
                data.projects[p].milestones[m].invoiceID = nil
            }
        }
    }

    // MARK: - Bulk edits
    //
    // Each of these wraps the whole batch in ONE history step. Looping the
    // single-invoice calls would work, but it would also push one undo step
    // per invoice -- so undoing a 20-invoice change would take 20 presses of
    // ⌘Z, which is not what anyone means by "undo that".

    func setStatus(_ status: InvoiceStatus, on ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        commitHistory()
        for index in data.invoices.indices where ids.contains(data.invoices[index].id) {
            data.invoices[index].status = status
            // Same rule as the single-invoice path: paid means paid in full.
            if status == .paid {
                data.invoices[index].amountPaid = data.invoices[index].total
            }
        }
        commitHistory()
    }

    func setArchived(_ archived: Bool, on ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        commitHistory()
        let now = Date()
        for index in data.invoices.indices where ids.contains(data.invoices[index].id) {
            data.invoices[index].archivedAt = archived ? now : nil
        }
        commitHistory()
    }

    func deleteInvoices(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        commitHistory()
        let now = Date()
        for index in data.invoices.indices where ids.contains(data.invoices[index].id) {
            data.invoices[index].deletedAt = now
        }
        commitHistory()
    }

    func restoreFromTrash(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        commitHistory()
        for index in data.invoices.indices where ids.contains(data.invoices[index].id) {
            data.invoices[index].deletedAt = nil
        }
        commitHistory()
    }

    func permanentlyDelete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        commitHistory()
        data.invoices.removeAll { ids.contains($0.id) }
        unlinkMilestones(fromInvoices: ids)
        commitHistory()
    }

    @discardableResult
    func duplicate(ids: Set<UUID>) -> [Invoice] {
        guard !ids.isEmpty else { return [] }
        commitHistory()
        // Oldest first, so the copies end up in the same order as the originals.
        let originals = data.invoices.filter { ids.contains($0.id) }.reversed()
        var copies: [Invoice] = []
        for invoice in originals {
            copies.append(duplicate(invoice))
        }
        commitHistory()
        return copies
    }

    /// Every invoice in `ids`, in the order they appear in the data.
    func invoices(with ids: Set<UUID>) -> [Invoice] {
        data.invoices.filter { ids.contains($0.id) }
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

    @MainActor
    func deleteCustomer(id: UUID) {
        data.customers.removeAll { $0.id == id }
        for index in data.invoices.indices where data.invoices[index].customerID == id {
            data.invoices[index].customerID = nil
        }
        // A tombstone, not just an absence: "missing here, present there" is
        // otherwise indistinguishable from "new there", and the next merge
        // would bring the customer straight back.
        CustomerSync.shared.recordDeletion(of: id)
    }

    // MARK: - Customer sync

    /// Merges the iCloud copy into ours and writes the union back. Safe to
    /// call often: it is a no-op unless syncing is on and iCloud Drive exists.
    @MainActor
    func syncCustomers() {
        guard let merged = CustomerSync.shared.sync(local: data.customers) else { return }
        guard merged != data.customers else { return }
        // Not an edit the user made, so it must not land on the undo stack as
        // one -- and it must not be clobbered by a stale in-flight save.
        commitHistory()
        data.customers = merged
        commitHistory()
    }

    /// Picks up edits made on another Mac while this one was open.
    @MainActor
    func startWatchingCustomerSync() {
        CustomerSync.shared.startWatching { [weak self] in
            self?.syncCustomers()
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
                guard self.data.customers[idx] != newValue else { return }
                var stamped = newValue
                stamped.updatedAt = Date()   // so iCloud can tell which copy is newer
                self.data.customers[idx] = stamped
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
