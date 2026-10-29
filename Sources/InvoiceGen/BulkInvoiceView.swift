import SwiftUI

/// The detail pane when more than one invoice is selected.
///
/// Everything here acts on the whole selection in a single undo step, so ⌘Z
/// puts back the batch rather than unwinding it one invoice at a time.
struct BulkInvoiceView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var focus: AppFocus

    @State private var confirmingTrash = false
    @State private var confirmingDelete = false

    private var selected: [Invoice] { store.invoices(with: focus.selectedInvoiceIDs) }
    private var ids: Set<UUID> { focus.selectedInvoiceIDs }

    private var total: Decimal { selected.reduce(0) { $0 + $1.total } }
    private var outstanding: Decimal {
        selected.filter { $0.status != .paid }.reduce(0) { $0 + $1.total }
    }
    private var currency: String {
        selected.first?.currencyCode ?? store.data.business.currencyCode
    }
    /// The trash needs a different verb set, and a selection can't span scopes
    /// because the sidebar only lists one scope at a time.
    private var isTrash: Bool { selected.allSatisfy(\.isTrashed) && !selected.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                actions
                summary
                list
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .confirmationDialog(
            "Move \(selected.count) invoices to the trash?",
            isPresented: $confirmingTrash, titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                store.deleteInvoices(ids: ids)
                focus.select([])
            }
        } message: {
            Text("They stay in the trash until you empty it, so this is reversible.")
        }
        .confirmationDialog(
            "Permanently delete \(selected.count) invoices?",
            isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                store.permanentlyDelete(ids: ids)
                focus.select([])
            }
        } message: {
            Text("This cannot be undone once the undo history is gone.")
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(selected.count) invoices selected")
                .font(.title2.weight(.semibold))
            Text("Changes apply to all of them, and ⌘Z undoes the whole batch.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        LiquidGlassGroup(spacing: 12) {
            HStack(spacing: 10) {
                if isTrash {
                    Button {
                        store.restoreFromTrash(ids: ids)
                    } label: { Label("Put Back", systemImage: "arrow.uturn.backward") }
                        .liquidGlassButton(prominent: true)

                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: { Label("Delete Permanently", systemImage: "trash.slash") }
                        .liquidGlassButton()
                } else {
                    Menu {
                        ForEach(InvoiceStatus.allCases) { status in
                            Button(status.label) { store.setStatus(status, on: ids) }
                        }
                    } label: {
                        Label("Set Status", systemImage: "tag")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Button {
                        store.setStatus(.paid, on: ids)
                    } label: { Label("Mark as Paid", systemImage: "checkmark.circle") }
                        .liquidGlassButton(prominent: true)

                    let allArchived = selected.allSatisfy(\.isArchived)
                    Button {
                        store.setArchived(!allArchived, on: ids)
                    } label: {
                        Label(allArchived ? "Move to Invoices" : "Archive",
                              systemImage: allArchived ? "tray.and.arrow.up" : "archivebox")
                    }
                    .liquidGlassButton()

                    Button {
                        let copies = store.duplicate(ids: ids)
                        focus.select(Set(copies.map(\.id)))
                    } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        .liquidGlassButton()

                    Button(role: .destructive) {
                        confirmingTrash = true
                    } label: { Label("Move to Trash", systemImage: "trash") }
                        .liquidGlassButton()
                }
            }
            .padding(12)
            .liquidGlass(in: RoundedRectangle(cornerRadius: Metrics.cornerGlass, style: .continuous))
        }
    }

    private var summary: some View {
        HStack(spacing: 28) {
            figure("Total", Fmt.currency(total, code: currency))
            figure("Outstanding", Fmt.currency(outstanding, code: currency))
            figure("Paid", "\(selected.filter { $0.status == .paid }.count) of \(selected.count)")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.medium)).monospacedDigit()
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(selected, id: \.id) { invoice in
                HStack(spacing: 12) {
                    Text("#\(invoice.number)")
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                        .frame(width: 52, alignment: .leading)
                    Text(store.customer(id: invoice.customerID)?.name ?? "No customer")
                        .lineLimit(1)
                    Spacer()
                    Text(invoice.status.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(Fmt.currency(invoice.total, code: invoice.currencyCode))
                        .monospacedDigit()
                        .frame(minWidth: 90, alignment: .trailing)
                }
                .padding(.vertical, 7)
                if invoice.id != selected.last?.id { Divider() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
