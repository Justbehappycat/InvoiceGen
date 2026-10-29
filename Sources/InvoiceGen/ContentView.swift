import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var focus: AppFocus

    @State private var section: SidebarSection
    @State private var search = ""
    @State private var statusFilter: InvoiceStatus?
    @State private var showVaultAlert = false

    init(initialSection: SidebarSection = .invoices) {
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(section: $section, search: $search, statusFilter: $statusFilter)
                .navigationSplitViewColumnWidth(min: 216, ideal: 240, max: 400)
        } detail: {
            detail
                .frame(minWidth: 680)
        }
        .navigationSplitViewStyle(.balanced)
        .alert("Payment details couldn't be verified", isPresented: $showVaultAlert) {
            Button("Open Settings") {
                SettingsWindowController.shared.show(store: store, focus: focus)
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text(store.vaultStatus.message
                 + "\n\nThey have been left off your invoices until you sort it out in Settings ▸ Security.")
        }
        .task {
            if store.vaultStatus.isTrouble { showVaultAlert = true }
            // Marks a UI-check copy on the Dock, where it can't be mistaken
            // for the real app and costs the layout nothing.
            if AppStore.isUICheck { NSApp.dockTile.badgeLabel = "UI" }
        }
        .onChange(of: focus.requestedSection) { newValue in
            if let newValue {
                section = newValue
                focus.requestedSection = nil
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .invoices:
            if focus.isMultiSelecting {
                BulkInvoiceView()
            } else if let id = focus.invoiceID, let binding = store.binding(invoiceID: id) {
                InvoiceEditorView(invoice: binding)
                    .id(id)
            } else {
                EmptyStateView(
                    systemImage: "doc.text",
                    title: "No invoice selected",
                    message: "Pick an invoice on the left, or press ⌘N to start a new one."
                )
            }
        case .projects:
            if let id = focus.projectID, let binding = store.binding(projectID: id) {
                ProjectDetailView(project: binding)
                    .id(id)
            } else {
                EmptyStateView(
                    systemImage: "folder",
                    title: "No project selected",
                    message: "A project holds one job: its payment schedule, its invoices, "
                           + "and what is still owed on it."
                )
            }
        case .customers:
            if let id = focus.customerID, let binding = store.binding(customerID: id) {
                CustomerDetailView(customer: binding)
                    .id(id)
            } else {
                EmptyStateView(
                    systemImage: "person.2",
                    title: "No customer selected",
                    message: "Customers you save here are remembered and reusable on every invoice."
                )
            }
        case .items:
            CatalogView()
        case .settings:
            SettingsView()
        }
    }
}

struct InvoiceRow: View {
    let invoice: Invoice
    let customer: Customer?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("#\(invoice.number)").font(.body.weight(.semibold))
                    Text(customer?.displayName ?? "No customer")
                        .font(.body)
                        .foregroundStyle(customer == nil ? .secondary : .primary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(invoice.isTrashed
                         ? "Deleted \(Fmt.shortDate(invoice.deletedAt ?? Date()))"
                         : "Due \(Fmt.shortDate(invoice.dueDate))")
                    if invoice.isArchived, !invoice.isTrashed {
                        Image(systemName: "archivebox")
                            .imageScale(.small)
                            .help("Archived")
                            .accessibilityLabel("Archived")
                    }
                }
                .font(.caption)
                .foregroundStyle(invoice.isOverdue ? .orange : .secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.currency(invoice.total, code: invoice.currencyCode))
                    .font(.callout.weight(.medium))
                StatusChip(status: invoice.status, overdue: invoice.isOverdue)
            }
        }
        .padding(.vertical, 3)
        // Set-aside work reads as set aside.
        .opacity(invoice.isTrashed ? 0.55 : 1)
    }
}

struct StatusChip: View {
    let status: InvoiceStatus
    var overdue: Bool = false

    private var color: Color {
        if overdue { return .orange }
        switch status {
        case .draft: return .gray
        case .sent: return .blue
        case .paid: return .green
        }
    }

    var body: some View {
        Text(overdue ? "Overdue" : status.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
    }
}
