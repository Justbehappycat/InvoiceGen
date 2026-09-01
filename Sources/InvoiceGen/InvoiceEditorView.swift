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
    @State private var templateName = ""

    private var customer: Customer? { store.customer(id: invoice.customerID) }
    private var business: BusinessProfile { store.data.business }

    var body: some View {
        VStack(spacing: 0) {
            stateBanner
            actionBar
            Divider()
            HSplitView {
                form
                    .frame(minWidth: 520, idealWidth: 560)
                if showPreview {
                    DocumentPreview(invoice: invoice, customer: customer, business: business)
                        .frame(minWidth: 300, idealWidth: 520)
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
            Text(text).font(.callout)
            Spacer()
            Button(action, action: perform).controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tint.opacity(0.10))
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

            Button {
                showPreview.toggle()
            } label: {
                Label(
                    "Preview",
                    systemImage: showPreview
                        ? "rectangle.righthalf.inset.filled"
                        : "rectangle.righthalf.inset"
                )
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help("Show or hide the live preview (⇧⌘P)")

            Button {
                PDFExporter.printInvoice(invoice: invoice, customer: customer, business: business)
            } label: {
                Label("Print", systemImage: "printer")
            }

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
        .background(Color(nsColor: .windowBackgroundColor))
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
            VStack(alignment: .leading, spacing: 22) {
                customerSection
                detailsSection
                itemsSection
                totalsSection
                paymentsSection
                notesSection
                dangerSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
    }

    private var customerSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Bill to", selection: Binding(
                        get: { invoice.customerID },
                        set: { invoice.customerID = $0 }
                    )) {
                        Text("No customer").tag(UUID?.none)
                        ForEach(store.data.customers) { customer in
                            Text(customer.displayName).tag(UUID?.some(customer.id))
                        }
                    }
                    Button {
                        let new = store.newCustomer(name: "New customer")
                        invoice.customerID = new.id
                        focus.customerID = new.id
                        focus.requestedSection = .customers
                    } label: {
                        Label("New customer", systemImage: "person.badge.plus")
                    }
                    .labelStyle(.iconOnly)
                    .help("Create a new customer and edit their details")
                }

                if let customer {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(customer.addressLines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption).foregroundStyle(.secondary)
                        }
                        if !customer.email.isEmpty {
                            Text(customer.email).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(6)
        } label: {
            sectionTitle("Customer")
        }
    }

    private var detailsSection: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Invoice number")
                    TextField("", text: $invoice.number).frame(width: 120)
                    Text("P.O./S.O.")
                    TextField("", text: $invoice.poNumber).frame(width: 120)
                }
                GridRow {
                    Text("Invoice date")
                    HStack(spacing: 6) {
                        DatePicker("", selection: $invoice.issueDate, displayedComponents: .date)
                            .labelsHidden()
                        Button("Today") { setIssueDateToToday() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(Calendar.current.isDateInToday(invoice.issueDate))
                            .help("Set the invoice date to today, keeping the same payment term")
                    }
                    Text("Payment due")
                    DatePicker("", selection: $invoice.dueDate, displayedComponents: .date)
                        .labelsHidden()
                }
                GridRow {
                    Text("Title")
                    TextField("INVOICE", text: $invoice.title).frame(width: 120)
                    Text("Currency")
                    Picker("", selection: $invoice.currencyCode) {
                        ForEach(Fmt.currencyCodes, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                GridRow {
                    Text("Terms")
                    HStack(spacing: 6) {
                        ForEach([7, 14, 30, 60], id: \.self) { days in
                            Button("\(days)d") {
                                invoice.dueDate = Calendar.current.date(
                                    byAdding: .day, value: days, to: invoice.issueDate
                                ) ?? invoice.dueDate
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .gridCellColumns(3)
                }
            }
            .padding(6)
        } label: {
            sectionTitle("Details")
        }
    }

    private var itemsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    columnHeader(invoice.columns.itemHeading, printed: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    columnHeader(invoice.columns.unitHeading, printed: invoice.columns.showUnit)
                        .frame(width: 60, alignment: .trailing)
                    columnHeader(invoice.columns.priceHeading, printed: invoice.columns.showPrice)
                        .frame(width: 90, alignment: .trailing)
                    columnHeader(invoice.columns.amountHeading, printed: invoice.columns.showAmount)
                        .frame(width: 90, alignment: .trailing)
                    Spacer().frame(width: 54)
                }
                .font(.caption)

                ForEach($invoice.items) { $item in
                    LineItemRow(
                        item: $item,
                        currencyCode: invoice.currencyCode,
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
                        .fixedSize()
                    }
                    Spacer()
                }
            }
            .padding(6)
        } label: {
            HStack {
                sectionTitle("Items")
                Spacer()
                Button {
                    isEditingColumns = true
                } label: {
                    Label("Columns", systemImage: "tablecells")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
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
        }
    }

    /// The editor always keeps every input — hiding a column changes what
    /// prints, not what you can type — so a hidden one is marked, not removed.
    private func columnHeader(_ title: String, printed: Bool) -> some View {
        HStack(spacing: 3) {
            if !printed {
                Image(systemName: "eye.slash")
            }
            Text(title)
        }
        .foregroundStyle(printed ? .secondary : Color.secondary.opacity(0.5))
        .help(printed ? "" : "Filled in here, left off the printed invoice")
    }

    private var totalsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Discount").frame(width: 90, alignment: .leading)
                    DecimalField(placeholder: "0", value: $invoice.discountValue)
                        .frame(width: 90)
                    Picker("", selection: $invoice.discountIsPercent) {
                        Text(invoice.currencyCode).tag(false)
                        Text("%").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 110)
                    Spacer()
                    Text("-" + Fmt.currency(invoice.discountAmount, code: invoice.currencyCode))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text("Tax").frame(width: 90, alignment: .leading)
                    TextField("Tax", text: $invoice.taxLabel).frame(width: 90)
                    DecimalField(placeholder: "0", value: $invoice.taxRate).frame(width: 70)
                    Text("%").foregroundStyle(.secondary)
                    Spacer()
                    Text(Fmt.currency(invoice.taxAmount, code: invoice.currencyCode))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text("Amount paid").frame(width: 90, alignment: .leading)
                    DecimalField(placeholder: "0", value: $invoice.amountPaid).frame(width: 90)
                    Button("Mark fully paid") {
                        invoice.amountPaid = invoice.total
                        invoice.status = .paid
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                }

                Divider()

                HStack {
                    Text("Total").font(.callout)
                    Spacer()
                    Text(Fmt.currency(invoice.total, code: invoice.currencyCode))
                        .font(.callout)
                }
                HStack {
                    Text("Amount due").font(.title3.weight(.semibold))
                    Spacer()
                    Text(Fmt.currency(invoice.amountDue, code: invoice.currencyCode))
                        .font(.title3.weight(.semibold))
                }
            }
            .padding(6)
        } label: {
            sectionTitle("Totals")
        }
    }

    private var paymentsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Shown on the invoice under “How to Pay”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Use defaults") {
                        invoice.paymentMethods = business.paymentMethods.map { method in
                            var copy = method
                            copy.id = UUID()
                            return copy
                        }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(business.paymentMethods.isEmpty || !paymentLock.isUnlocked)
                }
                PaymentMethodsEditor(methods: $invoice.paymentMethods)
            }
            .padding(6)
        } label: {
            sectionTitle("Payment")
        }
    }

    private var notesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Notes / Terms").font(.callout)
                    Spacer()
                    Button("Use default") { invoice.notes = business.defaultNotes }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                TextEditor(text: $invoice.notes)
                    .font(.body)
                    .frame(height: 130)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))

                Text("Footer message").font(.callout)
                TextField("It was a pleasure working with you!", text: $invoice.footerMessage)
            }
            .padding(6)
        } label: {
            sectionTitle("Notes")
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
    /// An invoice always keeps at least one line.
    var canDelete: Bool = true
    let onDelete: () -> Void
    let onSaveToCatalog: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Item name", text: $item.title)
                TextField("Description (optional)", text: $item.details, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.caption)
                Toggle("Taxable", isOn: $item.taxable)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            DecimalField(placeholder: "1", value: $item.quantity, alignment: .trailing)
                .frame(width: 56)
                .padding(.leading, 4)
            DecimalField(placeholder: "0", value: $item.price, alignment: .trailing)
                .frame(width: 86)
                .padding(.leading, 4)
            Text(Fmt.currency(item.amount, code: currencyCode))
                .frame(width: 90, alignment: .trailing)
                .padding(.top, 3)

            Menu {
                Button("Save to items library", action: onSaveToCatalog)
                Button("Remove line", role: .destructive, action: onDelete)
                    .disabled(!canDelete)
            } label: {
                Label("Line actions", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 50)
        }
        .padding(.vertical, 4)
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
