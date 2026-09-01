import SwiftUI
import AppKit

/// The left column: section switcher plus the invoice or customer list.
struct SidebarView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var focus: AppFocus

    @Binding var section: SidebarSection
    @Binding var search: String
    @Binding var statusFilter: InvoiceStatus?

    /// Only the two day-to-day sections switch here. Saved items and Settings
    /// live in the bar at the bottom: they are set-up, not daily work.
    private static let primarySections: [SidebarSection] = [.invoices, .customers]

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
            .foregroundColor(section == .items ? .accentColor : .primary)
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

    private func newInvoice() {
        let invoice = store.newInvoice()
        focus.invoiceID = invoice.id
        section = .invoices
    }

    private func openSettingsWindow() {
        SettingsWindowController.shared.show(store: store, focus: focus)
    }

    private var filteredInvoices: [Invoice] {
        let matches = store.data.invoices.filter { invoice in
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
            get: { focus.invoiceID },
            set: { newValue in
                focus.invoiceID = newValue
                // Picking an invoice means "show me that invoice", even when
                // the detail pane is currently parked on Saved items.
                if newValue != nil, section != .invoices { section = .invoices }
            }
        )) {
            ForEach(filteredInvoices) { invoice in
                InvoiceRow(invoice: invoice, customer: store.customer(id: invoice.customerID))
                    .tag(invoice.id)
                    .contextMenu {
                        Menu("Status") {
                            ForEach(InvoiceStatus.allCases) { status in
                                Button {
                                    store.setStatus(status, on: invoice.id)
                                } label: {
                                    // A checkmark on the current one, so the
                                    // menu also answers "what is it now?"
                                    Label(
                                        status.label,
                                        systemImage: invoice.status == status ? "checkmark" : ""
                                    )
                                }
                            }
                        }
                        if invoice.status != .paid {
                            Button("Mark as Paid") { store.setStatus(.paid, on: invoice.id) }
                        }
                        Divider()
                        Button("Duplicate") {
                            let copy = store.duplicate(invoice)
                            focus.invoiceID = copy.id
                        }
                        Button("Delete", role: .destructive) {
                            if focus.invoiceID == invoice.id { focus.invoiceID = nil }
                            store.deleteInvoice(id: invoice.id)
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { invoiceFilterBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { summaryBar }
        .searchable(text: $search, placement: .sidebar, prompt: "Search invoices")
    }

    private var invoiceFilterBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Menu {
                    Button("All") { statusFilter = nil }
                    ForEach(InvoiceStatus.allCases) { status in
                        Button(status.label) { statusFilter = status }
                    }
                } label: {
                    Label(statusFilter?.label ?? "All", systemImage: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                if store.data.templates.isEmpty {
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
            Divider()
        }
        .background(.bar)
    }

    private var summaryBar: some View {
        let outstanding = store.data.invoices
            .filter { $0.status != .paid }
            .reduce(Decimal(0)) { $0 + $1.amountDue }
        let overdue = store.data.invoices.filter(\.isOverdue).count
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Outstanding")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(Fmt.currency(outstanding, code: store.data.business.currencyCode))
                    .font(.callout.weight(.semibold))
            }
            Spacer()
            if overdue > 0 {
                Text("\(overdue) overdue")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var filteredCustomers: [Customer] {
        guard !search.isEmpty else { return store.data.customers }
        return store.data.customers.filter {
            $0.displayName.localizedCaseInsensitiveContains(search)
                || $0.email.localizedCaseInsensitiveContains(search)
        }
    }

    private var customerList: some View {
        List(selection: Binding(get: { focus.customerID }, set: { focus.customerID = $0 })) {
                ForEach(filteredCustomers) { customer in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(customer.displayName).font(.body)
                        if !customer.email.isEmpty {
                            Text(customer.email).font(.caption).foregroundColor(.secondary)
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
                Divider()
            }
            .background(.bar)
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search customers")
    }
}
