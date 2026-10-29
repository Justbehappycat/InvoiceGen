import SwiftUI
import AppKit

struct InvoiceEditorView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var focus: AppFocus
    @Binding var invoice: Invoice

    /// Kept in preferences rather than view state: it should survive switching
    /// invoices and relaunching, and hiding it skips the preview's layout work
    /// entirely — worth having when you just want to type.
    @AppStorage("showInvoicePreview") private var showPreview = true
    @ObservedObject private var paymentLock = PaymentLock.shared
    @State private var isNamingTemplate = false
    @State private var isEditingColumns = false
    @State private var isPublishing = false
    @State private var publishError: String?
    @State private var justCopiedLink = false
    @State private var templateName = ""
    /// Payment details change once and then sit there, so the section opens
    /// collapsed. The choice sticks across invoices and relaunches.
    @AppStorage("showPaymentDetail") private var showPaymentDetail = false

    private var customer: Customer? { store.customer(id: invoice.customerID) }
    private var business: BusinessProfile { store.data.business }

    var body: some View {
        VStack(spacing: 0) {
            stateBanner
            actionBar
            Divider()
            HSplitView {
                // Both panes state a real minimum and keep their own scroll
                // view, so dragging the divider runs out of room instead of
                // crushing either side. No layout priority: giving the form
                // one lets it swallow the preview whole.
                form
                    .frame(minWidth: 520, idealWidth: 580)
                if showPreview {
                    DocumentPreview(invoice: invoice, customer: customer, business: business)
                        .frame(minWidth: 360, idealWidth: 520)
                }
            }
        }
        .navigationTitle("Invoice #\(invoice.number)")
        .navigationSubtitle(customer?.displayName ?? "No customer")
        .onAppear { focus.invoiceID = invoice.id }
        .alert("Save as template", isPresented: $isNamingTemplate) {
            TextField("Template name", text: $templateName)
            Button("Cancel", role: .cancel) { templateName = "" }
            Button("Save") {
                let name = templateName.trimmingCharacters(in: .whitespaces)
                store.saveAsTemplate(invoice, name: name.isEmpty ? "Template" : name)
                templateName = ""
            }
        } message: {
            Text("Items, terms, tax and payment details are saved. Customer and dates are not.")
        }
    }

    // MARK: - Action bar
    //
    // Deliberately part of the pane rather than the window toolbar: toolbar
    // items float over the split view and collapse into an overflow menu when
    // the window is narrow.

    /// An archived or trashed invoice can still be opened; it says so, and
    /// offers the one action that matters.
    @ViewBuilder
    private var stateBanner: some View {
        if invoice.isTrashed {
            stateStrip(icon: "trash", tint: .red,
                       text: "In the trash — deleted \(Fmt.shortDate(invoice.deletedAt ?? Date()))",
                       action: "Put Back") { store.restoreFromTrash(id: invoice.id) }
        } else if invoice.isArchived {
            stateStrip(icon: "archivebox", tint: .secondary,
                       text: "Archived \(Fmt.shortDate(invoice.archivedAt ?? Date()))",
                       action: "Move to Invoices") { store.setArchived(false, on: invoice.id) }
        }
    }

    private func stateStrip(icon: String, tint: Color, text: String,
                            action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text).font(.callout).foregroundStyle(.primary)
            Spacer()
            Button(action, action: perform).controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // A tint this faint reads on white but disappears on a dark window, so
        // the strip carries its own hairline rather than relying on the wash
        // alone to separate it from the bar below.
        .background(tint.opacity(0.14))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $invoice.status) {
                ForEach(InvoiceStatus.allCases) { status in
                    Text(status.label).tag(status)
                }
            }
            .labelsHidden()
            .fixedSize()

            if invoice.isOverdue {
                StatusChip(status: invoice.status, overdue: true)
            }

            Spacer()

            Menu {
                Button("Duplicate invoice") {
                    let copy = store.duplicate(invoice)
                    focus.invoiceID = copy.id
                }
                Button("Save as template…") { isNamingTemplate = true }
                if !store.data.templates.isEmpty {
                    Divider()
                    Section("Apply template") {
                        ForEach(store.data.templates) { template in
                            Button(template.name) { apply(template) }
                        }
                    }
                }
            } label: {
                Label("Reuse", systemImage: "plus.square.on.square")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Duplicate this invoice, save it as a template, or apply one")

            // A toggle, not a button: it reads as pressed while the preview is
            // showing, so its state is visible without looking at the pane.
            Toggle(isOn: $showPreview) {
                Label("Preview", systemImage: "sidebar.right")
            }
            .toggleStyle(.button)
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help(showPreview ? "Hide the live preview (⇧⌘P)" : "Show the live preview (⇧⌘P)")

            shareMenu

            Button {
                PDFExporter.printInvoice(invoice: invoice, customer: customer, business: business)
            } label: {
                Label("Print", systemImage: "printer")
            }
            .labelStyle(.iconOnly)
            .help("Print this invoice (⌘P)")

            Button {
                PDFExporter.exportWithPanel(invoice: invoice, customer: customer, business: business)
            } label: {
                Label("Export PDF", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .liquidGlassBar()
    }

    /// Publishing puts the invoice behind a link a client can open. Always
    /// explicit, and reversible from the same menu.
    @ViewBuilder
    private var shareMenu: some View {
        Menu {
            if let link = publishedLink {
                Button(justCopiedLink ? "Copied" : "Copy link") { copy(link) }
                Button("Open in browser") { NSWorkspace.shared.open(link) }
                Divider()
                Button("Update the published copy") { publish() }
                Button("Unpublish", role: .destructive) { unpublish() }
            } else if store.publishingIsConfigured {
                Button("Publish link…") { publish() }
            } else {
                Text("Set the publishing address and token in Settings first")
            }
        } label: {
            Label(isPublishing ? "Publishing…" : (publishedLink == nil ? "Share" : "Shared"),
                  systemImage: publishedLink == nil ? "link" : "link.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isPublishing)
        .help(publishedLink?.absoluteString ?? "Publish this invoice as a link for the client")
        .alert("Couldn't publish", isPresented: Binding(
            get: { publishError != nil }, set: { if !$0 { publishError = nil } }
        )) {
            Button("OK", role: .cancel) { publishError = nil }
        } message: {
            Text(publishError ?? "")
        }
    }

    private var publishedLink: URL? {
        guard let id = invoice.publishedID,
              let target = PublishService.target(for: store.data.business) else { return nil }
        return PublishService.publicURL(for: id, target: target)
    }

    private func copy(_ link: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
        justCopiedLink = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            justCopiedLink = false
        }
    }

    private func publish() {
        isPublishing = true
        Task { @MainActor in
            defer { isPublishing = false }
            do {
                let result = try await PublishService.publish(
                    invoice: invoice, customer: customer, business: store.data.business
                )
                invoice.publishedID = result.id
                invoice.publishedAt = Date()
                store.commitHistory()
                copy(result.url)
            } catch {
                publishError = error.localizedDescription
            }
        }
    }

    private func unpublish() {
        guard let id = invoice.publishedID else { return }
        isPublishing = true
        Task { @MainActor in
            defer { isPublishing = false }
            do {
                try await PublishService.unpublish(id: id, business: store.data.business)
                invoice.publishedID = nil
                invoice.publishedAt = nil
                store.commitHistory()
            } catch {
                publishError = error.localizedDescription
            }
        }
    }

    /// Moving the invoice date drags the due date with it, so a 30-day invoice
    /// stays a 30-day invoice instead of silently becoming a 12-day one.
    private func setIssueDateToToday() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let term = calendar.dateComponents([.day], from: invoice.issueDate, to: invoice.dueDate).day
        invoice.issueDate = today
        if let term, term > 0 {
            invoice.dueDate = calendar.date(byAdding: .day, value: term, to: today) ?? today
        }
        store.commitHistory()
    }

    private func apply(_ template: InvoiceTemplate) {
        invoice.title = template.title
        invoice.items = template.items.map { item in
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
        if !template.paymentMethods.isEmpty {
            invoice.paymentMethods = template.paymentMethods.map { method in
                var copy = method
                copy.id = UUID()
                return copy
            }
        }
        invoice.dueDate = Calendar.current.date(
            byAdding: .day, value: template.paymentTermDays, to: invoice.issueDate
        ) ?? invoice.dueDate
    }

    // MARK: - Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                customerSection
                SectionRule()
                detailsSection
                SectionRule()
                itemsSection
                SectionRule()
                totalsSection
                SectionRule()
                paymentsSection
                SectionRule()
                notesSection
                dangerSection
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var customerSection: some View {
        VStack(alignment: .leading, spacing: Metrics.rowGap) {
            SectionHeader("Customer")

            FormRow(label: "Bill to") {
                // fixedSize: a menu picker given a wider frame centres itself in
                // it, which is what pushed the selector away from its label.
                Picker("", selection: Binding(
                    get: { invoice.customerID },
                    set: { invoice.customerID = $0 }
                )) {
                    Text("No customer").tag(UUID?.none)
                    ForEach(store.data.customers) { customer in
                        Text(customer.displayName).tag(UUID?.some(customer.id))
                    }
                }
                .labelsHidden()
                .fixedSize()

                Button {
                    let new = store.newCustomer(name: "New customer")
                    invoice.customerID = new.id
                    focus.customerID = new.id
                    focus.requestedSection = .customers
                } label: {
                    Label("New customer", systemImage: "person.badge.plus")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Create a new customer and edit their details")
            }

            // Two lines at most, starting in the same column as the selector:
            // who, then where. Four stacked caption lines made the customer
            // the tallest thing in the editor.
            if let customer, !contactLines(for: customer).isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(contactLines(for: customer), id: \.self) { line in
                        Text(line).lineLimit(1).truncationMode(.tail)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, Metrics.labelWidth + 10)
                .textSelection(.enabled)
            }

            // Only worth showing once there is a job to file this under.
            if !store.data.projects.isEmpty {
                FormRow(label: "Project") {
                    Picker("", selection: $invoice.projectID) {
                        Text("None").tag(UUID?.none)
                        ForEach(store.data.projects.filter { !$0.isArchived }) { project in
                            Text(project.displayName).tag(UUID?.some(project.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()

                    if let id = invoice.projectID, store.project(id: id) != nil {
                        Button {
                            focus.projectID = id
                            focus.requestedSection = .projects
                        } label: {
                            Label("Open project", systemImage: "arrow.up.forward.square")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Open the job this invoice belongs to")
                    }
                }
            }
        }
    }

    /// "Dana Whitfield · accounts@example.com" then the address on one line.
    private func contactLines(for customer: Customer) -> [String] {
        let who = [customer.contactName, customer.email]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        let address = customer.addressLines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        return [who, address].filter { !$0.isEmpty }
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: Metrics.rowGap) {
            SectionHeader("Details")

            // Pairs side by side: number with P.O., issue date with due date,
            // title with currency. The term buttons sit directly under the due
            // date they set, and "Today" under the date it sets, so neither
            // needs a row and a label of its own. Below ~500pt the pairs stack.
            ViewThatFits(in: .horizontal) {
                Grid(alignment: .leadingFirstTextBaseline,
                     horizontalSpacing: 10, verticalSpacing: Metrics.rowGap) {
                    GridRow {
                        detailLabel("Invoice number"); invoiceNumberField
                        pairLabel("P.O./S.O.");        poField
                    }
                    GridRow {
                        detailLabel("Invoice date");   issueDatePicker
                        pairLabel("Payment due");      dueDateField
                    }
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        todayButton
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        termsButtons
                    }
                    .padding(.top, -4)
                    GridRow {
                        detailLabel("Title");          titleField
                        pairLabel("Currency");         currencyField
                    }
                }
                .fixedSize()

                Grid(alignment: .leadingFirstTextBaseline,
                     horizontalSpacing: 10, verticalSpacing: Metrics.rowGap) {
                    GridRow { detailLabel("Invoice number"); invoiceNumberField }
                    GridRow { detailLabel("P.O./S.O.");      poField }
                    GridRow {
                        detailLabel("Invoice date")
                        HStack(spacing: 6) { issueDatePicker; todayButton }
                    }
                    GridRow { detailLabel("Payment due");    dueDateField }
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        termsButtons
                    }
                    .padding(.top, -4)
                    GridRow { detailLabel("Title");          titleField }
                    GridRow { detailLabel("Currency");       currencyField }
                }
            }
        }
    }

    /// The second label in a pair: sized to its text, with a little extra
    /// lead so the two pairs read as two pairs rather than one long row.
    private func pairLabel(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
            .gridColumnAlignment(.leading)
    }

    private func detailLabel(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(width: Metrics.labelWidth, alignment: .leading)
            .gridColumnAlignment(.leading)
    }

    private var invoiceNumberField: some View {
        TextField("", text: $invoice.number)
            .monospacedDigit()
            .frame(width: Metrics.fieldWidth)
    }

    private var poField: some View {
        TextField("", text: $invoice.poNumber).frame(width: Metrics.fieldWidth)
    }

    private var issueDatePicker: some View {
        DatePicker("", selection: $invoice.issueDate, displayedComponents: .date)
            .labelsHidden()
            .fixedSize()
    }

    private var todayButton: some View {
        // fixedSize stops the grid squeezing this to "Tod...".
        Button("Today") { setIssueDateToToday() }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .disabled(Calendar.current.isDateInToday(invoice.issueDate))
            .help("Set the invoice date to today, keeping the same payment term")
    }

    private var dueDateField: some View {
        DatePicker("", selection: $invoice.dueDate, displayedComponents: .date)
            .labelsHidden()
            .fixedSize()
    }

    private var titleField: some View {
        TextField("INVOICE", text: $invoice.title).frame(width: Metrics.fieldWidth)
    }

    private var currencyField: some View {
        Picker("", selection: $invoice.currencyCode) {
            ForEach(Fmt.currencyCodes, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    /// The quick terms as one segmented control rather than four buttons: it
    /// is narrower, which is what lets Details stay two columns in a laptop
    /// pane, and it shows which term the dates currently describe -- "30d"
    /// stays lit on a Net 30 invoice -- so the link to the due date is visible
    /// rather than implied. A custom due date lights nothing.
    private var termsButtons: some View {
        Picker("Payment term", selection: termBinding) {
            ForEach([7, 14, 30, 60], id: \.self) { days in
                Text("\(days)d").tag(Int?.some(days))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Set the due date this many days after the invoice date")
    }

    private var termBinding: Binding<Int?> {
        Binding(
            get: {
                let calendar = Calendar.current
                let days = calendar.dateComponents(
                    [.day],
                    from: calendar.startOfDay(for: invoice.issueDate),
                    to: calendar.startOfDay(for: invoice.dueDate)
                ).day
                return [7, 14, 30, 60].contains(days ?? -1) ? days : nil
            },
            set: { days in
                // Exactly what the buttons did: issue date plus the term.
                guard let days else { return }
                invoice.dueDate = Calendar.current.date(
                    byAdding: .day, value: days, to: invoice.issueDate
                ) ?? invoice.dueDate
            }
        )
    }

    private var itemsSection: some View {
        VStack(alignment: .leading, spacing: Metrics.rowGap) {
            SectionHeader(title: "Items") {
                Button {
                    isEditingColumns = true
                } label: {
                    Label("Columns", systemImage: "tablecells")
                }
                .buttonStyle(.borderless)
                .help("Rename the columns, or keep one off the printed invoice")
                .popover(isPresented: $isEditingColumns, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        ColumnSettingsEditor(columns: $invoice.columns)
                        HStack {
                            Button("Use business defaults") {
                                invoice.columns = store.data.business.defaultColumns
                            }
                            Spacer()
                            Button("Save as defaults") {
                                store.data.business.defaultColumns = invoice.columns
                            }
                        }
                        .controlSize(.small)
                    }
                    .padding(16)
                    .frame(width: 420)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    columnHeader(invoice.columns.itemHeading, printed: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    columnHeader(invoice.columns.unitHeading, printed: invoice.columns.showUnit)
                        .frame(width: Metrics.quantityColumn, alignment: .trailing)
                    columnHeader(invoice.columns.priceHeading, printed: invoice.columns.showPrice)
                        .frame(width: Metrics.priceColumn, alignment: .trailing)
                    columnHeader(invoice.columns.amountHeading, printed: invoice.columns.showAmount)
                        .frame(width: Metrics.amountColumn, alignment: .trailing)
                    Spacer().frame(width: Metrics.actionColumn)
                }
                .font(.caption)

                ForEach($invoice.items) { $item in
                    LineItemRow(
                        item: $item,
                        currencyCode: invoice.currencyCode,
                        itemHeading: invoice.columns.itemHeading,
                        canDelete: invoice.items.count > 1,
                        onDelete: { invoice.items.removeAll { $0.id == item.id } },
                        onSaveToCatalog: {
                            store.data.catalog.append(
                                CatalogItem(
                                    title: item.title,
                                    details: item.details,
                                    price: item.price,
                                    taxable: item.taxable
                                )
                            )
                        }
                    )
                    Divider()
                }

                HStack {
                    Button {
                        invoice.items.append(LineItem())
                    } label: {
                        Label("Add item", systemImage: "plus")
                    }
                    .controlSize(.small)

                    if !store.data.catalog.isEmpty {
                        Menu {
                            ForEach(store.data.catalog) { catalogItem in
                                Button(catalogItem.title.isEmpty ? "Untitled" : catalogItem.title) {
                                    invoice.items.append(catalogItem.asLineItem)
                                }
                            }
                        } label: {
                            Label("Add saved item", systemImage: "shippingbox")
                        }
                        .controlSize(.small)
                        .fixedSize()
                    }
                    Spacer()
                }
            }
        }
    }

    /// The editor always keeps every input — hiding a column changes what
    /// prints, not what you can type — so a hidden one is marked, not removed.
    private func columnHeader(_ title: String, printed: Bool) -> some View {
        HStack(spacing: 3) {
            if !printed {
                Image(systemName: "eye.slash")
                    .accessibilityLabel("Not printed")
            }
            Text(title)
        }
        .foregroundStyle(.secondary)
        .help(printed ? "" : "Filled in here, left off the printed invoice")
    }

    private var totalsSection: some View {
        VStack(alignment: .leading, spacing: Metrics.rowGap) {
            SectionHeader("Totals")

            // Every row here -- the editable ones and the sums -- is the same
            // shape: label column, controls, then the amount hard against the
            // right edge. That is what makes one column of figures instead of
            // two that nearly line up.
            totalsRow("Discount", amount: -invoice.discountAmount) {
                DecimalField(placeholder: "0", value: $invoice.discountValue, alignment: .trailing)
                    .frame(width: 80)
                Picker("", selection: $invoice.discountIsPercent) {
                    Text(invoice.currencyCode).tag(false)
                    Text("%").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            totalsRow("Tax", amount: invoice.taxAmount) {
                TextField("Tax", text: $invoice.taxLabel).frame(width: 80)
                DecimalField(placeholder: "0", value: $invoice.taxRate, alignment: .trailing)
                    .frame(width: 56)
                Text("%").foregroundStyle(.secondary)
            }

            totalsRow("Amount paid", amount: invoice.amountPaid) {
                DecimalField(placeholder: "0", value: $invoice.amountPaid, alignment: .trailing)
                    .frame(width: 80)
                Button("Mark fully paid") {
                    invoice.amountPaid = invoice.total
                    invoice.status = .paid
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .disabled(invoice.amountPaid == invoice.total)
            }

            VStack(alignment: .leading, spacing: 6) {
                Divider().padding(.vertical, 6)
                summaryRow("Subtotal", invoice.subtotal, tint: .secondary)
                summaryRow("Total", invoice.total, tint: .primary)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Amount due")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer(minLength: 8)
                    Money(amount: invoice.amountDue, code: invoice.currencyCode,
                          font: .system(size: 16), weight: .semibold)
                        .frame(width: Metrics.amountWidth, alignment: .trailing)
                }
                .padding(.top, 2)
            }
            .padding(.leading, Metrics.labelWidth + 10)
        }
    }

    private func totalsRow<Controls: View>(
        _ label: String,
        amount: Decimal,
        @ViewBuilder controls: () -> Controls
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .frame(width: Metrics.labelWidth, alignment: .leading)
                .foregroundStyle(.secondary)
            controls()
            Spacer(minLength: 8)
            Money(amount: amount, code: invoice.currencyCode, tint: .secondary)
                .frame(width: Metrics.amountWidth, alignment: .trailing)
        }
    }

    private func summaryRow(_ label: String, _ value: Decimal,
                            tint: HierarchicalShapeStyle) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).foregroundStyle(tint)
            Spacer(minLength: 8)
            Money(amount: value, code: invoice.currencyCode, tint: tint)
                .frame(width: Metrics.amountWidth, alignment: .trailing)
        }
    }

    private var paymentsSection: some View {
        VStack(alignment: .leading, spacing: Metrics.rowGap) {
            SectionHeader(title: "Payment") {
                HStack(spacing: 8) {
                    Button("Use defaults") {
                        invoice.paymentMethods = business.paymentMethods.map { method in
                            var copy = method
                            copy.id = UUID()
                            return copy
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(business.paymentMethods.isEmpty || !paymentLock.isUnlocked)

                    Button(showPaymentDetail ? "Hide" : "Show") {
                        showPaymentDetail.toggle()
                    }
                    .buttonStyle(.borderless)
                }
            }

            if showPaymentDetail {
                Text("Shown on the invoice under “How to Pay”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PaymentMethodsEditor(methods: $invoice.paymentMethods)
            } else {
                paymentSummary
            }
        }
    }

    /// Collapsed, this is a status line, not a second editor. The values it
    /// shows come from `PaymentLock.mask` exactly as the expanded editor's do,
    /// so collapsing can never reveal something unlocking would not.
    private var paymentSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if invoice.enabledPaymentMethods.isEmpty {
                Text("No payment methods on this invoice.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(invoice.enabledPaymentMethods) { method in
                    HStack(spacing: 8) {
                        PaymentBadge(method: method, size: 16)
                        Text(method.displayTitle)
                        if let field = method.filledFields.first {
                            Text(PaymentLock.mask(field.value))
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: paymentLock.isUnlocked ? "lock.open" : "lock")
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(paymentLock.isUnlocked
                     ? "Unlocked — values can be edited."
                     : "Masked and read-only until you authenticate.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: Metrics.rowGap) {
            SectionHeader(title: "Notes") {
                Button("Use default") { invoice.notes = business.defaultNotes }
                    .buttonStyle(.borderless)
            }

            // Starts at three lines and grows with what is typed, rather than
            // reserving 130pt of empty box on an invoice that has no terms.
            TextField("Notes and terms", text: $invoice.notes, axis: .vertical)
                .lineLimit(3...14)

            FormRow(label: "Footer") {
                TextField("It was a pleasure working with you!",
                          text: $invoice.footerMessage)
            }
            .font(.callout)
        }
    }

    private var dangerSection: some View {
        HStack {
            Spacer()
            Button(role: .destructive) {
                let id = invoice.id
                focus.invoiceID = nil
                store.deleteInvoice(id: id)
            } label: {
                Label("Delete invoice", systemImage: "trash")
            }
        }
    }
}

struct LineItemRow: View {
    @Binding var item: LineItem
    let currencyCode: String
    /// Passed to the on-device model so "Hours" and "Items" read differently.
    var itemHeading: String = "Item"
    /// An invoice always keeps at least one line.
    var canDelete: Bool = true
    let onDelete: () -> Void
    let onSaveToCatalog: () -> Void

    @AppStorage("onDeviceAssist") private var assistEnabled = true
    @State private var proposal: OnDeviceAssist.Proposal?
    @State private var isTidying = false
    @State private var assistError: String?

    var body: some View {
        // Two lines. The figures share a line with the name, and the
        // description gets the full width beneath them -- under quantity,
        // price and amount too -- instead of being squeezed into the name's
        // column and wrapping after four words. Taxable rides at the end of
        // that line rather than taking a third.
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                TextField("Item name", text: $item.title)
                    .frame(maxWidth: .infinity)
                DecimalField(placeholder: "1", value: $item.quantity, alignment: .trailing)
                    .frame(width: Metrics.quantityColumn - 4)
                    .padding(.leading, 4)
                DecimalField(placeholder: "0", value: $item.price, alignment: .trailing)
                    .frame(width: Metrics.priceColumn - 4)
                    .padding(.leading, 4)
                Money(amount: item.amount, code: currencyCode)
                    .frame(width: Metrics.amountColumn, alignment: .trailing)
                actions
                    .frame(width: Metrics.actionColumn)
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TextField("Description (optional)", text: $item.details, axis: .vertical)
                    .lineLimit(1...6)
                    .font(.callout)
                Toggle("Taxable", isOn: $item.taxable)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .fixedSize()
            }
            .padding(.trailing, Metrics.actionColumn)
        }
        .padding(.vertical, 6)
        .sheet(item: $proposal) { proposal in
            TidyReview(item: item, proposal: proposal) { accepted in
                if accepted {
                    item.title = proposal.title
                    item.details = proposal.details
                }
                self.proposal = nil
            }
        }
        .alert("Couldn't tidy this line",
               isPresented: Binding(get: { assistError != nil },
                                    set: { if !$0 { assistError = nil } })) {
            Button("OK", role: .cancel) { assistError = nil }
        } message: {
            Text(assistError ?? "")
        }
    }

    private var actions: some View {
        Menu {
            if assistEnabled, OnDeviceAssist.isReady {
                Button("Tidy up wording", action: tidy)
                    .disabled(isTidying || item.title.isEmpty)
            }
            Button("Save to items library", action: onSaveToCatalog)
            Button("Remove line", role: .destructive, action: onDelete)
                .disabled(!canDelete)
        } label: {
            if isTidying {
                ProgressView().controlSize(.small)
            } else {
                Label("Line actions", systemImage: "ellipsis.circle")
            }
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    /// The model only ever proposes. Applying is the sheet's job, and undo
    /// covers it like any other edit.
    private func tidy() {
        isTidying = true
        Task {
            defer { isTidying = false }
            do {
                let suggested = try await OnDeviceAssist.tidy(
                    title: item.title, details: item.details, heading: itemHeading
                )
                if suggested.changes(from: item) {
                    proposal = suggested
                } else {
                    assistError = "This line already reads clearly."
                }
            } catch {
                assistError = error.localizedDescription
            }
        }
    }
}

/// Shows what the model suggests beside what is already there. The user
/// approves the change; nothing is written before that.
private struct TidyReview: View {
    let item: LineItem
    let proposal: OnDeviceAssist.Proposal
    let finish: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tidy up wording").font(.headline)
            Text("Suggested by the model on this Mac. Nothing was sent anywhere, "
                 + "and the quantity, price and total are untouched.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            comparison("Name", before: item.title, after: proposal.title)
            if !item.details.isEmpty || !proposal.details.isEmpty {
                comparison("Description", before: item.details, after: proposal.details)
            }

            HStack {
                Spacer()
                Button("Keep mine") { finish(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Use this") { finish(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    @ViewBuilder
    private func comparison(_ label: String, before: String, after: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(before.isEmpty ? "—" : before)
                .strikethrough(before != after)
                .foregroundStyle(before == after ? .primary : .secondary)
            if before != after {
                Text(after.isEmpty ? "—" : after)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Live preview

struct DocumentPreview: View {
    let invoice: Invoice
    let customer: Customer?
    let business: BusinessProfile

    @State private var availableWidth: CGFloat = 300
    @State private var specs: [InvoicePageSpec] = []

    private struct PaginationKey: Equatable {
        let invoice: Invoice
        let customer: Customer?
        let business: BusinessProfile
    }

    var body: some View {
        // Width comes from a background reader rather than a GeometryReader
        // wrapper, so the ScrollView keeps its toolbar safe-area inset.
        let scale = min(1.0, max(0.28, (availableWidth - 48) / InvoiceDocumentView.pageWidth))
        let specs = self.specs.isEmpty ? [.whole(itemCount: invoice.items.count)] : self.specs

        ScrollView {
            VStack(spacing: 20) {
                ForEach(Array(specs.enumerated()), id: \.element.id) { index, spec in
                    VStack(spacing: 4) {
                        InvoiceDocumentView(
                            invoice: invoice, customer: customer, business: business, page: spec
                        )
                        .frame(
                            width: InvoiceDocumentView.pageWidth,
                            height: InvoiceDocumentView.pageHeight
                        )
                        // Scale about the center so the shrunken page stays
                        // centred inside the smaller frame below it.
                        .scaleEffect(scale)
                        .frame(
                            width: InvoiceDocumentView.pageWidth * scale,
                            height: InvoiceDocumentView.pageHeight * scale
                        )
                        // The shadow goes on a plain rectangle behind the page,
                        // never on the page itself: shadowing the live view
                        // makes AppKit rasterise and blur the whole invoice on
                        // every redraw (~360ms a page), which is what made
                        // activating the window feel slow.
                        .background(
                            Rectangle()
                                .fill(Color.white)
                                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                        )

                        if specs.count > 1 {
                            Text("Page \(index + 1) of \(specs.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .background(
            GeometryReader { geo in
                Color(nsColor: .underPageBackgroundColor)
                    .preference(key: PreviewWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(PreviewWidthKey.self) { width in
            if width > 0, abs(width - availableWidth) > 0.5 { availableWidth = width }
        }
        // Repaginate off the body path, and only once typing settles.
        .task(id: PaginationKey(invoice: invoice, customer: customer, business: business)) {
            if !self.specs.isEmpty {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
            }
            self.specs = InvoicePaginator.pages(
                invoice: invoice, customer: customer, business: business
            )
        }
    }
}

private struct PreviewWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
