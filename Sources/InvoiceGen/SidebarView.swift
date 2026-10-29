import SwiftUI
import AppKit

/// Which pile of invoices the sidebar is showing.
enum InvoiceScope: String, CaseIterable, Identifiable {
    case active, archive, trash

    var id: String { rawValue }
    var label: String {
        switch self {
        case .active: return "Invoices"
        case .archive: return "Archive"
        case .trash: return "Trash"
        }
    }
    var systemImage: String {
        switch self {
        case .active: return "line.3.horizontal.decrease.circle"
        case .archive: return "archivebox"
        case .trash: return "trash"
        }
    }
}

/// The left column: section switcher plus the invoice or customer list.
struct SidebarView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var focus: AppFocus

    @Binding var section: SidebarSection
    @Binding var search: String
    @Binding var statusFilter: InvoiceStatus?

    /// Which pile of invoices the list is showing. Kept in preferences so the
    /// app doesn't reopen in the trash.
    @AppStorage("invoiceScope") private var scope: InvoiceScope = .active
    @State private var isImportingContract = false

    /// Only the two day-to-day sections switch here. Saved items and Settings
    /// live in the bar at the bottom: they are set-up, not daily work.
    private static let primarySections: [SidebarSection] = [.invoices, .projects, .customers]

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(Self.primarySections) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.vertical, 8)

            Divider()

            switch section {
            case .customers: customerList
            case .projects: projectList
            default: invoiceList
            }

            Divider()
            utilityBar
        }
    }

    private var utilityBar: some View {
        HStack(spacing: 6) {
            Button {
                section = section == .items ? .invoices : .items
            } label: {
                Label(
                    section == .items ? "Back to invoices" : "Saved items",
                    systemImage: section == .items ? "chevron.left" : "shippingbox"
                )
            }
            .buttonStyle(.borderless)
            .foregroundStyle(section == .items ? Color.accentColor : Color.primary)
            .help("Reusable services, prices and invoice templates")

            Spacer()

            Button {
                openSettingsWindow()
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Business profile, branding, payment methods (⌘,)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func count(of scope: InvoiceScope) -> Int {
        switch scope {
        case .active: return store.activeInvoices.count
        case .archive: return store.archivedInvoices.count
        case .trash: return store.trashedInvoices.count
        }
    }

    private func newInvoice() {
        scope = .active
        let invoice = store.newInvoice()
        focus.invoiceID = invoice.id
        section = .invoices
    }

    private func openSettingsWindow() {
        SettingsWindowController.shared.show(store: store, focus: focus)
    }

    private var scopedInvoices: [Invoice] {
        switch scope {
        case .active: return store.activeInvoices
        case .archive: return store.archivedInvoices
        case .trash: return store.trashedInvoices
        }
    }

    /// The archive is filed by year, newest first — that's how you look for
    /// something from two Marches ago.
    private var archiveYears: [(year: Int, invoices: [Invoice])] {
        Dictionary(grouping: filteredInvoices, by: \.year)
            .map { (year: $0.key, invoices: $0.value.sorted { $0.issueDate > $1.issueDate }) }
            .sorted { $0.year > $1.year }
    }

    private var filteredInvoices: [Invoice] {
        let matches = scopedInvoices.filter { invoice in
            if let statusFilter, invoice.status != statusFilter { return false }
            guard !search.isEmpty else { return true }
            let customerName = store.customer(id: invoice.customerID)?.displayName ?? ""
            return invoice.number.localizedCaseInsensitiveContains(search)
                || customerName.localizedCaseInsensitiveContains(search)
                || invoice.items.contains { $0.title.localizedCaseInsensitiveContains(search) }
        }
        // What still needs doing floats up; settled invoices sink but stay
        // visible and searchable. Overdue leads, then unpaid by soonest due,
        // then paid by most recent.
        return matches.sorted { a, b in
            if a.sortRank != b.sortRank { return a.sortRank < b.sortRank }
            if a.status == .paid { return a.issueDate > b.issueDate }
            if a.dueDate != b.dueDate { return a.dueDate < b.dueDate }
            return a.createdAt > b.createdAt
        }
    }

    private var invoiceList: some View {
        List(selection: Binding(
            get: { focus.selectedInvoiceIDs },
            set: { (newValue: Set<UUID>) in
                focus.select(newValue)
                // Picking an invoice means "show me that invoice", even when
                // the detail pane is currently parked on Saved items.
                if !newValue.isEmpty, section != .invoices { section = .invoices }
            }
        )) {
            if scope == .archive {
                ForEach(archiveYears, id: \.year) { group in
                    Section("\(String(group.year))  ·  \(group.invoices.count)") {
                        ForEach(group.invoices) { invoice in
                            row(for: invoice)
                        }
                    }
                }
            } else {
                ForEach(filteredInvoices) { invoice in
                    row(for: invoice)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { invoiceFilterBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { summaryBar }
        .searchable(text: $search, placement: .sidebar, prompt: searchPrompt)
    }

    private var searchPrompt: String {
        switch scope {
        case .active: return "Search invoices"
        case .archive: return "Search the archive"
        case .trash: return "Search the trash"
        }
    }

    /// Right-clicking inside a multi-selection acts on all of it; right-clicking
    /// outside one acts on just that row. That is the Finder rule, and getting
    /// it wrong means silently editing one invoice when eight were selected.
    private func targets(for invoice: Invoice) -> Set<UUID> {
        focus.selectedInvoiceIDs.count > 1 && focus.selectedInvoiceIDs.contains(invoice.id)
            ? focus.selectedInvoiceIDs
            : [invoice.id]
    }

    private func row(for invoice: Invoice) -> some View {
        InvoiceRow(invoice: invoice, customer: store.customer(id: invoice.customerID))
            .tag(invoice.id)
            .contextMenu {
                let ids = targets(for: invoice)
                let many = ids.count > 1
                let suffix = many ? " (\(ids.count))" : ""

                Menu("Status") {
                    ForEach(InvoiceStatus.allCases) { status in
                        Button {
                            store.setStatus(status, on: ids)
                        } label: {
                            // A checkmark on the current one, so the menu also
                            // answers "what is it now?" -- but only when a
                            // single invoice is in play and that question has
                            // one answer.
                            Label(
                                status.label,
                                systemImage: !many && invoice.status == status ? "checkmark" : ""
                            )
                        }
                    }
                }
                if many || invoice.status != .paid {
                    Button("Mark as Paid" + suffix) { store.setStatus(.paid, on: ids) }
                }
                Divider()
                if invoice.isTrashed {
                    Button("Put Back" + suffix) { store.restoreFromTrash(ids: ids) }
                    Button("Delete Permanently" + suffix, role: .destructive) {
                        focus.select(focus.selectedInvoiceIDs.subtracting(ids))
                        store.permanentlyDelete(ids: ids)
                    }
                } else {
                    Button("Duplicate" + suffix) {
                        let copies = store.duplicate(ids: ids)
                        focus.select(Set(copies.map(\.id)))
                    }
                    let allArchived = store.invoices(with: ids).allSatisfy(\.isArchived)
                    Button((allArchived ? "Move to Invoices" : "Archive") + suffix) {
                        store.setArchived(!allArchived, on: ids)
                    }
                    Button("Move to Trash" + suffix, role: .destructive) {
                        focus.select(focus.selectedInvoiceIDs.subtracting(ids))
                        store.deleteInvoices(ids: ids)
                    }
                }
            }
    }

    private var invoiceFilterBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Menu {
                    Section("Show") {
                        ForEach(InvoiceScope.allCases) { item in
                            Button {
                                scope = item
                            } label: {
                                Label(
                                    "\(item.label) (\(count(of: item)))",
                                    systemImage: scope == item ? "checkmark" : item.systemImage
                                )
                            }
                        }
                    }
                    if scope != .trash {
                        Section("Status") {
                            Button("All") { statusFilter = nil }
                            ForEach(InvoiceStatus.allCases) { status in
                                Button(status.label) { statusFilter = status }
                            }
                        }
                    }
                } label: {
                    Label(scope == .active ? (statusFilter?.label ?? "All") : scope.label,
                          systemImage: scope.systemImage)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                if scope == .trash, !store.trashedInvoices.isEmpty {
                    Button("Empty Trash", role: .destructive) {
                        if let id = focus.invoiceID,
                           store.invoice(id: id)?.isTrashed == true { focus.invoiceID = nil }
                        store.emptyTrash()
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }

                if scope == .trash {
                    EmptyView()
                } else if store.data.templates.isEmpty {
                    Button {
                        newInvoice()
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                } else {
                    Menu {
                        Button("Blank invoice") { newInvoice() }
                        Divider()
                        Section("From template") {
                            ForEach(store.data.templates) { template in
                                Button(template.name) {
                                    let invoice = store.newInvoice(from: template)
                                    focus.invoiceID = invoice.id
                                    section = .invoices
                                }
                            }
                        }
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            BarDivider()
        }
        .liquidGlassBar()
    }

    private var summaryBar: some View {
        // Archived and trashed invoices are not outstanding work.
        let outstanding = store.activeInvoices
            .filter { $0.status != .paid }
            .reduce(Decimal(0)) { $0 + $1.amountDue }
        let overdue = store.activeInvoices.filter(\.isOverdue).count
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Outstanding")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(Fmt.currency(outstanding, code: store.data.business.currencyCode))
                    .font(.callout.weight(.semibold))
            }
            Spacer()
            if overdue > 0 {
                Text("\(overdue) overdue")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .liquidGlassBar()
        .overlay(alignment: .top) { BarDivider() }
    }

    private var filteredCustomers: [Customer] {
        guard !search.isEmpty else { return store.data.customers }
        return store.data.customers.filter {
            $0.displayName.localizedCaseInsensitiveContains(search)
                || $0.email.localizedCaseInsensitiveContains(search)
        }
    }

    private var filteredProjects: [Project] {
        // Archived jobs sink to the bottom rather than vanish: the work still
        // happened, and last year's series is exactly what you go looking for.
        let all = store.data.projects.sorted { a, b in
            if a.isArchived != b.isArchived { return !a.isArchived }
            return a.createdAt > b.createdAt
        }
        guard !search.isEmpty else { return all }
        return all.filter {
            $0.displayName.localizedCaseInsensitiveContains(search)
                || (store.customer(id: $0.customerID)?.displayName
                    .localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    private var projectList: some View {
        List(selection: Binding(get: { focus.projectID }, set: { focus.projectID = $0 })) {
            ForEach(filteredProjects) { project in
                let totals = store.totals(forProject: project.id)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(project.displayName).font(.body)
                        if project.isArchived {
                            Image(systemName: "archivebox")
                                .imageScale(.small)
                                .help("Archived")
                                .accessibilityLabel("Archived")
                        }
                    }
                    if let customer = store.customer(id: project.customerID) {
                        Text(customer.displayName).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(projectSummary(project, totals: totals))
                        .font(.caption)
                        .foregroundStyle(totals.outstanding > 0 ? .orange : .secondary)
                }
                .padding(.vertical, 2)
                .tag(project.id)
                .contextMenu {
                    Button(project.isArchived ? "Unarchive" : "Archive") {
                        store.setArchived(!project.isArchived, onProject: project.id)
                    }
                    Button("Delete", role: .destructive) {
                        if focus.projectID == project.id { focus.projectID = nil }
                        store.deleteProject(id: project.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    // With the on-device model available, "New" offers a
                    // contract as a starting point; without it, it is the
                    // plain button it always was.
                    if OnDeviceAssist.isReady {
                        Menu {
                            Button("Empty Project") {
                                let project = store.newProject()
                                focus.projectID = project.id
                            }
                            Button("From a Contract…") { isImportingContract = true }
                        } label: {
                            Label("New", systemImage: "plus")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    } else {
                        Button {
                            let project = store.newProject()
                            focus.projectID = project.id
                        } label: {
                            Label("New", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                BarDivider()
            }
            .liquidGlassBar()
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search projects")
        .sheet(isPresented: $isImportingContract) {
            ContractImportView()
                .environmentObject(store)
                .environmentObject(focus)
        }
    }

    /// One line of money, which is the thing you open a job to find out.
    private func projectSummary(_ project: Project, totals: AppStore.ProjectTotals) -> String {
        let code = store.data.business.currencyCode
        if totals.outstanding > 0 {
            return "\(Fmt.currency(totals.outstanding, code: code)) outstanding"
        }
        if totals.invoiced > 0 {
            return "\(Fmt.currency(totals.invoiced, code: code)) invoiced · paid up"
        }
        if project.hasContractTotal {
            return "\(Fmt.currency(project.contractTotal, code: code)) contracted · nothing invoiced"
        }
        return "Nothing invoiced yet"
    }

    private var customerList: some View {
        List(selection: Binding(get: { focus.customerID }, set: { focus.customerID = $0 })) {
                ForEach(filteredCustomers) { customer in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(customer.displayName).font(.body)
                        if !customer.email.isEmpty {
                            Text(customer.email).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(customer.id)
                    .contextMenu {
                        Button("New Invoice for \(customer.displayName)") {
                            let invoice = store.newInvoice(customerID: customer.id)
                            focus.invoiceID = invoice.id
                            section = .invoices
                        }
                        Button("Delete", role: .destructive) {
                            if focus.customerID == customer.id { focus.customerID = nil }
                            store.deleteCustomer(id: customer.id)
                        }
                    }
                }
            }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        let customer = store.newCustomer()
                        focus.customerID = customer.id
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                BarDivider()
            }
            .liquidGlassBar()
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search customers")
    }
}
