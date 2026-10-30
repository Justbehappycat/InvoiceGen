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
    /// One per invoice: the editor is rebuilt per invoice (`.id`), so cached
    /// answers and pending checks never leak from one invoice into the next.
    @StateObject private var wording = WordingAssistant()

    private var customer: Customer? { store.customer(id: invoice.customerID) }
    private var business: BusinessProfile { store.data.business }

    var body: some View {
        VStack(spacing: 0) {
            stateBanner
            HSplitView {
                // Both panes state a real minimum and keep their own scroll
                // view, so dragging the divider runs out of room instead of
                // crushing either side. No layout priority: giving the form
                // one lets it swallow the preview whole.
                form
                    .environmentObject(wording)
                    .frame(minWidth: 520, idealWidth: 580)
                if showPreview {
                    DocumentPreview(invoice: invoice, customer: customer, business: business)
                        .frame(minWidth: 360, idealWidth: 520)
                }
            }
        }
        .navigationTitle("Invoice #\(invoice.number)")
        .navigationSubtitle(customer?.displayName ?? "No customer")
        .toolbar { invoiceToolbar }
        .alert("Couldn't publish", isPresented: Binding(
            get: { publishError != nil }, set: { if !$0 { publishError = nil } }
        )) {
            Button("OK", role: .cancel) { publishError = nil }
        } message: {
            Text(publishError ?? "")
        }
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

    /// The window toolbar, grouped the way Mail groups its own: related
    /// actions share one glass capsule, a lone action gets a circle of its
    /// own, and the one that finishes the job -- Export PDF -- is tinted.
    /// The system draws every shape, so the rounding is the platform's and
    /// matches every other Mac app, rather than five hand-made bezels that
    /// each disagreed slightly.
    ///
    /// This used to be a bar inside the pane, to stop items collapsing into
    /// an overflow menu in a narrow window. The overflow menu is what every
    /// Mac app does there, and the in-pane bar cost a row of height and a
    /// second, competing set of shapes.
    @ToolbarContentBuilder
    private var invoiceToolbar: some ToolbarContent {
        // Beside the title: what state this invoice is in.
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 6) {
                Picker("Status", selection: $invoice.status) {
                    ForEach(InvoiceStatus.allCases) { status in
                        Text(status.label).tag(status)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("Draft, Sent or Paid")
                if invoice.isOverdue {
                    StatusChip(status: invoice.status, overdue: true)
                }
            }
        }

        ToolbarItem(placement: .primaryAction) { reuseMenu }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) {
            // A toggle, not a button: it reads as pressed while the preview
            // is showing, so its state is visible without looking at the pane.
            Toggle(isOn: $showPreview) {
                Label("Preview", systemImage: "sidebar.right")
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help(showPreview ? "Hide the live preview (⇧⌘P)" : "Show the live preview (⇧⌘P)")
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        // Sending it somewhere: one capsule, like Mail's reply group.
        ToolbarItemGroup(placement: .primaryAction) {
            shareMenu
            Button {
                PDFExporter.printInvoice(invoice: invoice, customer: customer, business: business)
            } label: {
                Label("Print", systemImage: "printer")
            }
            .help("Print this invoice (⌘P)")
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                PDFExporter.exportWithPanel(invoice: invoice, customer: customer, business: business)
            } label: {
                Label("Export PDF", systemImage: "square.and.arrow.down")
                    // The one toolbar action that finishes the job keeps its
                    // words; the secondary ones stay icons, as in Mail.
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .help("Export this invoice as a PDF (⌘E)")
        }
    }

    private var reuseMenu: some View {
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
        .help("Duplicate this invoice, save it as a template, or apply one")
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
        .disabled(isPublishing)
        .help(publishedLink?.absoluteString ?? "Publish this invoice as a link for the client")
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
            // Editor-only, the form would otherwise run the full width of the
            // window: item fields a metre long and Totals labels a screen away
            // from their figures. So the column stops at a readable width and
            // centres in what's left -- no card, just space either side. With
            // the preview showing, the pane is already narrow and keeps its
            // width. A modifier value, not a different view, so toggling the
            // preview never rebuilds the form and focus and edits survive it.
            .frame(maxWidth: showPreview ? .infinity : Metrics.editorMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("invoice-editor")
    }

    private var customerSection: some View {
        VStack(alignment: .leading, spacing: Metrics.rowGap) {
            SectionHeader("Customer")

            FormRow(label: "Bill to") {
                // fixedSize: a menu picker given a wider frame centres itself in
                // it, which is what pushed the selector away from its label.
                Picker("Bill to", selection: Binding(
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
                    // Wraps rather than truncates: a cut-off address is one you
                    // can't check against the invoice.
                    ForEach(contactLines(for: customer), id: \.self) { line in
                        Text(line).fixedSize(horizontal: false, vertical: true)
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
                    Picker("Project", selection: $invoice.projectID) {
                        Text("None").tag(UUID?.none)
                        ForEach(store.data.projects.filter { !$0.isArchived }) { project in
                            Text(project.displayName).tag(UUID?.some(project.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()

                    if let id = invoice.projectID, let project = store.project(id: id) {
                        Button {
                            focus.projectID = id
                            focus.requestedSection = .projects
                        } label: {
                            Label("Open project", systemImage: "arrow.up.forward.square")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Open “\(project.displayName)”")
                        .accessibilityLabel("Open project \(project.displayName)")
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
                .fixedSize(horizontal: false, vertical: true)

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
            .frame(minWidth: Metrics.fieldWidth, maxWidth: Metrics.fieldMaxWidth)
    }

    private var poField: some View {
        TextField("", text: $invoice.poNumber).frame(minWidth: Metrics.fieldWidth, maxWidth: Metrics.fieldMaxWidth)
    }

    private var issueDatePicker: some View {
        DatePicker("Invoice date", selection: $invoice.issueDate, displayedComponents: .date)
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
        DatePicker("Payment due", selection: $invoice.dueDate, displayedComponents: .date)
            .labelsHidden()
            .fixedSize()
    }

    private var titleField: some View {
        TextField("INVOICE", text: $invoice.title).frame(minWidth: Metrics.fieldWidth, maxWidth: Metrics.fieldMaxWidth)
    }

    private var currencyField: some View {
        Picker("Currency", selection: $invoice.currencyCode) {
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
        VStack(alignment: .leading, spacing: 3) {
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
            .accessibilityValue(termDescription)

            // Nothing lit used to be the only sign of a custom date, which is
            // easy to read as "not set". Say it, with the number of days; and
            // a due date before the invoice date is almost always a slip, so
            // it says that instead, in orange.
            if termBinding.wrappedValue == nil {
                Text(termDescription)
                    .font(.caption)
                    .foregroundStyle(termDays.map { $0 < 0 } == true ? StatusTone.overdue.text : .secondary)
                    .fixedSize()
            }
        }
    }

    /// Whole days from the invoice date to the due date.
    private var termDays: Int? {
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: invoice.issueDate),
            to: calendar.startOfDay(for: invoice.dueDate)
        ).day
    }

    private var termDescription: String {
        guard let days = termDays else { return "Custom due date" }
        if days < 0 { return "Due before the invoice date" }
        if days == 0 { return "Custom · due on receipt" }
        if [7, 14, 30, 60].contains(days) { return "Net \(days)" }
        return "Custom · \(days) days"
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
                // The whole-list review, kept beside the list it reviews and
                // as quiet as the Columns control next to it. Absent, not
                // disabled, when the model can't run.
                if wording.canSuggest {
                    Button {
                        wording.reviewAll(invoice.items, heading: invoice.columns.itemHeading)
                    } label: {
                        Label("Review wording", systemImage: "text.badge.checkmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Check every line's wording with the model on this Mac. "
                          + "Suggestions appear under each line; nothing changes until you apply one.")
                }
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
                Picker("Discount type", selection: $invoice.discountIsPercent) {
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

    @EnvironmentObject private var wording: WordingAssistant
    @FocusState private var editing: Field?
    private enum Field { case title, details }

    var body: some View {
        // Two lines. The figures share a line with the name, and the
        // description gets the full width beneath them -- under quantity,
        // price and amount too -- instead of being squeezed into the name's
        // column and wrapping after four words. Taxable rides at the end of
        // that line rather than taking a third.
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                TextField("Item name", text: $item.title)
                    .focused($editing, equals: .title)
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
                    .focused($editing, equals: .details)
                    .lineLimit(1...6)
                    .font(.callout)
                Toggle("Taxable", isOn: $item.taxable)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .fixedSize()
            }
            .padding(.trailing, Metrics.actionColumn)

            suggestionLine
        }
        .padding(.vertical, 6)
        .onChange(of: item.title) { _ in wording.edited(item, heading: itemHeading) }
        .onChange(of: item.details) { _ in wording.edited(item, heading: itemHeading) }
        // Leaving the line is "finished editing": check now rather than wait
        // out the pause.
        .onChange(of: editing) { field in
            if field == nil { wording.finishedEditing(item, heading: itemHeading) }
        }
        .onDisappear { wording.forget(item.id) }
    }

    /// The suggestion lives under the line it is for -- no sheet, no alert, and
    /// it never takes focus, so typing carries on undisturbed. A check nobody
    /// asked for shows nothing until it has something worth showing.
    @ViewBuilder
    private var suggestionLine: some View {
        switch wording.state(for: item.id) {
        case .idle, .working(manual: false):
            EmptyView()
        case .working(manual: true):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Checking the wording…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .alreadyClear:
            note("This line already reads clearly.")
        case .failed(let reason):
            note(reason)
        case .suggestion(let proposal):
            WordingSuggestion(
                proposal: proposal,
                apply: {
                    // The one place a suggestion becomes data, and only here.
                    if let accepted = wording.apply(item, heading: itemHeading) {
                        item.title = accepted.title
                        item.details = accepted.details
                    }
                },
                regenerate: { wording.request(item, heading: itemHeading, force: true) },
                dismiss: { wording.dismiss(item.id) }
            )
        }
    }

    private func note(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("OK") { wording.dismiss(item.id) }
                .buttonStyle(.borderless)
                .font(.caption)
                .accessibilityLabel("Dismiss message")
        }
    }

    private var actions: some View {
        Menu {
            if wording.isEnabled() {
                Button("Tidy up wording") { wording.request(item, heading: itemHeading) }
                    .disabled(item.title.isEmpty || !wording.canSuggest)
            }
            Button("Save to items library", action: onSaveToCatalog)
            Button("Remove line", role: .destructive, action: onDelete)
                .disabled(!canDelete)
        } label: {
            Label("Line actions", systemImage: "ellipsis.circle")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Tidy up, save to the library, or remove this line")
    }
}

/// One suggestion, inline: what it would read, and the three answers.
/// Plain text and borderless buttons -- it should read as a note in the
/// margin, not as a feature announcing itself.
private struct WordingSuggestion: View {
    let proposal: OnDeviceAssist.Proposal
    let apply: () -> Void
    let regenerate: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // foregroundColor, not foregroundStyle: concatenated Text needs
            // the Text-returning form, and that one is macOS 14+.
            (Text("Suggested: ").foregroundColor(.secondary)
             + Text(proposal.title).fontWeight(.medium)
             + Text(proposal.details.isEmpty ? "" : " — " + proposal.details).foregroundColor(.secondary))
                .font(.callout)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button("Apply", action: apply)
                .accessibilityLabel("Apply suggestion")
            Button("Regenerate", action: regenerate)
                .accessibilityLabel("Regenerate suggestion")
            Button("Dismiss", action: dismiss)
                .accessibilityLabel("Dismiss suggestion")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.trailing, Metrics.actionColumn)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Wording suggestion: \(proposal.title)")
        .help("Suggested by the model on this Mac. Nothing changes unless you press Apply.")
    }
}

// MARK: - Live preview

/// How the live preview sizes the page.
enum PreviewZoom: Equatable {
    case fitWidth
    case fitPage
    case fixed(Double)

    /// The steps − and + move through, like Preview's.
    static let steps: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    static let range: ClosedRange<Double> = 0.25...3.0
    /// Room around the page inside the canvas.
    static let margin: CGFloat = 48

    /// The page's scale for this zoom in a canvas of this size. Pure, so the
    /// regression suite can pin every mode down without a window.
    func scale(in canvas: CGSize, page: CGSize) -> CGFloat {
        let widthFit = (canvas.width - Self.margin) / page.width
        let heightFit = (canvas.height - Self.margin) / page.height
        let raw: CGFloat
        switch self {
        case .fitWidth: raw = widthFit
        case .fitPage: raw = min(widthFit, heightFit)
        case .fixed(let value): raw = CGFloat(value)
        }
        return min(CGFloat(Self.range.upperBound), max(0.2, raw))
    }

    func zoomed(in larger: Bool, from current: CGFloat) -> PreviewZoom {
        let c = Double(current)
        let next = larger
            ? Self.steps.first { $0 > c + 0.001 } ?? Self.range.upperBound
            : Self.steps.last { $0 < c - 0.001 } ?? Self.range.lowerBound
        return .fixed(min(Self.range.upperBound, max(Self.range.lowerBound, next)))
    }

    /// Stored as text so the choice survives relaunches.
    var storage: String {
        switch self {
        case .fitWidth: return "fitWidth"
        case .fitPage: return "fitPage"
        case .fixed(let value): return String(format: "%.2f", value)
        }
    }

    init(storage: String) {
        switch storage {
        case "fitPage": self = .fitPage
        case "fitWidth": self = .fitWidth
        default:
            if let value = Double(storage), PreviewZoom.range.contains(value) {
                self = .fixed(value)
            } else {
                self = .fitWidth
            }
        }
    }
}

struct DocumentPreview: View {
    let invoice: Invoice
    let customer: Customer?
    let business: BusinessProfile

    @State private var canvas = CGSize(width: 300, height: 600)
    @State private var specs: [InvoicePageSpec] = []
    @AppStorage("previewZoom") private var zoomStorage = PreviewZoom.fitWidth.storage

    private var zoom: PreviewZoom {
        get { PreviewZoom(storage: zoomStorage) }
        nonmutating set { zoomStorage = newValue.storage }
    }

    private static let page = CGSize(width: InvoiceDocumentView.pageWidth,
                                     height: InvoiceDocumentView.pageHeight)

    private struct PaginationKey: Equatable {
        let invoice: Invoice
        let customer: Customer?
        let business: BusinessProfile
    }

    var body: some View {
        // Size comes from a background reader rather than a GeometryReader
        // wrapper, so the ScrollView keeps its toolbar safe-area inset.
        let scale = zoom.scale(in: canvas, page: Self.page)
        let specs = self.specs.isEmpty ? [.whole(itemCount: invoice.items.count)] : self.specs

        ScrollView([.vertical, .horizontal]) {
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
            .padding(.top, 24)
            // Room under the last page for the zoom control, so it never
            // sits permanently over the totals.
            .padding(.bottom, 64)
            .padding(.horizontal, 24)
            .frame(minWidth: canvas.width, alignment: .top)
        }
        .scrollIndicators(.automatic)
        .background(
            GeometryReader { geo in
                Color(nsColor: .underPageBackgroundColor)
                    .preference(key: PreviewSizeKey.self, value: geo.size)
            }
        )
        .onPreferenceChange(PreviewSizeKey.self) { size in
            if size.width > 0,
               abs(size.width - canvas.width) > 0.5 || abs(size.height - canvas.height) > 0.5 {
                canvas = size
            }
        }
        .overlay(alignment: .bottomTrailing) {
            zoomControl(current: scale)
                .padding(12)
        }
        .accessibilityIdentifier("invoice-preview")
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

    /// A small floating capsule, like Preview's: two fit modes, then zoom.
    /// It overlays the canvas instead of taking a row from it.
    private func zoomControl(current scale: CGFloat) -> some View {
        HStack(spacing: 2) {
            zoomButton("Fit page", icon: "rectangle.portrait",
                       help: "Fit the whole page in the preview",
                       selected: zoom == .fitPage) { zoom = .fitPage }
            zoomButton("Fit width", icon: "arrow.left.and.right",
                       help: "Fit the page to the preview's width",
                       selected: zoom == .fitWidth) { zoom = .fitWidth }

            Divider().frame(height: 14).padding(.horizontal, 3)

            zoomButton("Zoom out", icon: "minus", help: "Zoom out (⌘−)", selected: false) {
                zoom = zoom.zoomed(in: false, from: scale)
            }
            .keyboardShortcut("-", modifiers: .command)

            Button {
                zoom = .fixed(1.0)
            } label: {
                Text("\(Int((scale * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 38)
            }
            .buttonStyle(.borderless)
            .help("Actual size (⌘0)")
            .accessibilityLabel("Zoom level")
            .accessibilityValue("\(Int((scale * 100).rounded())) percent")
            .accessibilityHint("Sets the preview to actual size")
            .keyboardShortcut("0", modifiers: .command)

            zoomButton("Zoom in", icon: "plus", help: "Zoom in (⌘+)", selected: false) {
                zoom = zoom.zoomed(in: true, from: scale)
            }
            .keyboardShortcut("=", modifiers: .command)
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .liquidGlass(in: Capsule())
    }

    private func zoomButton(_ label: String, icon: String, help: String, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .labelStyle(.iconOnly)
                .frame(width: 22, height: 18)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PreviewSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        value = CGSize(width: max(value.width, next.width), height: max(value.height, next.height))
    }
}
