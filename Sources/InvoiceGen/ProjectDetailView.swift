import SwiftUI

/// One job, end to end: who it is for, what it is worth, what it still owes.
///
/// The schedule is the point. A contract says "$150 on 30 Oct, $300 on 6 Nov",
/// and until now that lived in a PDF while the invoices were made by hand one
/// at a time. Here the schedule is the record, and each line turns into a
/// draft invoice that stays linked to the milestone that produced it.
struct ProjectDetailView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var focus: AppFocus
    @Binding var project: Project

    @State private var confirmBillAll = false

    private var totals: AppStore.ProjectTotals { store.totals(forProject: project.id) }
    private var currency: String { store.data.business.currencyCode }
    private var unbilled: [Milestone] {
        project.milestones.filter { store.needsInvoicing($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                identity
                money
                schedule
                invoices
                notes
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .safeAreaInset(edge: .top, spacing: 0) { actionBar }
    }

    // MARK: - Bar

    private var actionBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(project.displayName).font(.headline).lineLimit(1)
                if project.isArchived {
                    Text("Archived")
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if !unbilled.isEmpty {
                    Button {
                        confirmBillAll = true
                    } label: {
                        Label("Invoice \(unbilled.count) unbilled", systemImage: "doc.badge.plus")
                    }
                    .controlSize(.small)
                }
                Menu {
                    Button(project.isArchived ? "Unarchive" : "Archive") {
                        store.setArchived(!project.isArchived, onProject: project.id)
                    }
                    Button("Delete project", role: .destructive) {
                        let id = project.id
                        focus.projectID = nil
                        store.deleteProject(id: id)
                    }
                } label: {
                    Label("Project actions", systemImage: "ellipsis.circle")
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            BarDivider()
        }
        .liquidGlassBar()
        .confirmationDialog(
            "Create \(unbilled.count) draft invoice\(unbilled.count == 1 ? "" : "s")?",
            isPresented: $confirmBillAll, titleVisibility: .visible
        ) {
            Button("Create Drafts") {
                let made = store.createInvoicesForUnbilled(inProject: project.id)
                if let first = made.first {
                    focus.invoiceID = first.id
                    focus.requestedSection = .invoices
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They are created as drafts, oldest due date first. Nothing is sent, "
                 + "and ⌘Z undoes the whole batch in one step.")
        }
    }

    // MARK: - Sections

    private var identity: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Project name", text: $project.name)

                HStack {
                    Picker("Client", selection: $project.customerID) {
                        Text("No client").tag(UUID?.none)
                        ForEach(store.data.customers) { customer in
                            Text(customer.displayName).tag(UUID?.some(customer.id))
                        }
                    }
                    // The visible "Client" is a separate text node, so the
                    // pop-up itself was announced with no name at all.
                    .accessibilityLabel("Client")
                    Button {
                        let new = store.newCustomer(name: "New customer")
                        project.customerID = new.id
                        focus.customerID = new.id
                        focus.requestedSection = .customers
                    } label: {
                        Label("New client", systemImage: "person.badge.plus")
                    }
                    .labelStyle(.iconOnly)
                    .help("Create a new client and edit their details")
                }

                HStack {
                    Text("Contract total")
                    DecimalField(placeholder: "0", value: $project.contractTotal,
                                 alignment: .trailing)
                        .frame(width: 120)
                    Text(currency).foregroundStyle(.secondary)
                    Spacer()
                }
                Text("What the whole job is worth. Leave it at zero for open-ended work — "
                     + "the schedule and the invoices still add up either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        } label: {
            Text("The job").font(.headline)
        }
    }

    private var money: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 0) {
                    if project.hasContractTotal {
                        figure("Contracted", project.contractTotal, tint: .secondary)
                    }
                    figure("Invoiced", totals.invoiced, tint: .secondary)
                    // Measured status shades, not raw .green/.orange: those
                    // were about 2:1 against the window background.
                    figure("Paid", totals.paid, tint: totals.paid > 0 ? StatusTone.paid.text : .secondary)
                    figure("Outstanding", totals.outstanding,
                           tint: totals.outstanding > 0 ? StatusTone.overdue.text : .secondary)
                }

                if let left = totals.remainingToBill(contractTotal: project.contractTotal) {
                    Text(remainingSentence(left))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if project.hasContractTotal, project.scheduledTotal != project.contractTotal,
                   !project.milestones.isEmpty {
                    // Worth saying out loud: a schedule that doesn't add up to
                    // the contract is usually a typo, occasionally deliberate.
                    Label(
                        "The schedule adds up to \(Fmt.currency(project.scheduledTotal, code: currency)), "
                        + "not \(Fmt.currency(project.contractTotal, code: currency)).",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
        } label: {
            Text("Money").font(.headline)
        }
    }

    private func remainingSentence(_ left: Decimal) -> String {
        if left > 0 {
            return "\(Fmt.currency(left, code: currency)) of the contract is still to invoice."
        }
        if left < 0 {
            return "Invoiced \(Fmt.currency(-left, code: currency)) beyond the contract — "
                 + "extra rounds and overages, or the contract total needs updating."
        }
        return "The whole contract has been invoiced."
    }

    private func figure(_ label: String, _ value: Decimal, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(Fmt.currency(value, code: currency))
                .font(.title3.weight(.medium))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var schedule: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if project.milestones.isEmpty {
                    Text("No payment schedule yet. Add the dates the contract pays on, "
                         + "and each one becomes a draft invoice when you want it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 0) {
                        Text("Deliverable").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Due").frame(width: 110, alignment: .leading)
                        Text("Amount").frame(width: 90, alignment: .trailing)
                        Spacer().frame(width: 140)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    ForEach($project.milestones) { $milestone in
                        MilestoneRow(
                            milestone: $milestone,
                            currency: currency,
                            invoice: store.billedInvoice(for: milestone),
                            onInvoice: {
                                if let made = store.createInvoice(
                                    forMilestone: milestone.id, inProject: project.id) {
                                    focus.invoiceID = made.id
                                    focus.requestedSection = .invoices
                                }
                            },
                            onOpen: {
                                if let id = milestone.invoiceID {
                                    focus.invoiceID = id
                                    focus.requestedSection = .invoices
                                }
                            },
                            onRemove: {
                                project.milestones.removeAll { $0.id == milestone.id }
                            }
                        )
                        Divider()
                    }
                }

                Button {
                    project.milestones.append(nextMilestone())
                } label: {
                    Label("Add payment", systemImage: "plus")
                }
            }
            .padding(6)
        } label: {
            Text("Payment schedule").font(.headline)
        }
    }

    /// A new row guesses forward from the last one — contracts pay on a
    /// rhythm, so a fortnight on at the same amount is usually right.
    private func nextMilestone() -> Milestone {
        guard let last = project.milestones.max(by: { $0.dueDate < $1.dueDate }) else {
            return Milestone(deliverable: "", amount: 0, dueDate: Date())
        }
        let next = Calendar.current.date(byAdding: .day, value: 14, to: last.dueDate) ?? last.dueDate
        return Milestone(deliverable: "", amount: last.amount, dueDate: next)
    }

    private var invoices: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                let list = store.invoices(inProject: project.id)
                if list.isEmpty {
                    Text("Nothing invoiced against this job yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(list) { invoice in
                        Button {
                            focus.invoiceID = invoice.id
                            focus.requestedSection = .invoices
                        } label: {
                            HStack(spacing: 8) {
                                Text("#\(invoice.number)").font(.body.weight(.medium))
                                Text(Fmt.shortDate(invoice.dueDate))
                                    .font(.caption)
                                    .foregroundStyle(invoice.isOverdue ? StatusTone.overdue.text : .secondary)
                                Spacer()
                                Text(Fmt.currency(invoice.total, code: invoice.currencyCode))
                                StatusChip(status: invoice.status, overdue: invoice.isOverdue)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            .padding(6)
        } label: {
            Text("Invoices").font(.headline)
        }
    }

    private var notes: some View {
        GroupBox {
            TextField("Anything worth remembering about this job", text: $project.notes,
                      axis: .vertical)
                .lineLimit(2...8)
                .padding(6)
        } label: {
            Text("Notes").font(.headline)
        }
    }
}

/// One line of the schedule. Once it has produced an invoice it stops being
/// editable money and becomes a link: the invoice is the record from then on.
private struct MilestoneRow: View {
    @Binding var milestone: Milestone
    let currency: String
    let invoice: Invoice?
    let onInvoice: () -> Void
    let onOpen: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            TextField("Deliverable, e.g. Episode 1", text: $milestone.deliverable)
                .frame(maxWidth: .infinity, alignment: .leading)

            DatePicker("Due date", selection: $milestone.dueDate, displayedComponents: .date)
                .labelsHidden()
                .frame(width: 110, alignment: .leading)

            DecimalField(placeholder: "0", value: $milestone.amount, alignment: .trailing)
                .frame(width: 86)
                .padding(.leading, 4)
                .disabled(invoice != nil)

            HStack(spacing: 4) {
                if let invoice {
                    Button {
                        onOpen()
                    } label: {
                        Label("Invoice #\(invoice.number)", systemImage: "arrow.up.forward.square")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Open the invoice this payment produced")
                } else {
                    Button(action: onInvoice) {
                        Label("Invoice", systemImage: "doc.badge.plus").font(.caption)
                    }
                    .controlSize(.small)
                    .disabled(milestone.amount <= 0)
                    .help(milestone.amount <= 0
                          ? "Set an amount first"
                          : "Create a draft invoice for this payment")
                }
                Spacer(minLength: 0)
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(invoice != nil)
                .opacity(invoice != nil ? 0.25 : 1)
                .accessibilityLabel("Remove payment")
                .help(invoice != nil
                      ? "This payment has been invoiced. Delete the invoice to unlink it."
                      : "Remove this payment from the schedule")
            }
            .frame(width: 140)
        }
        .padding(.vertical, 3)
    }
}
