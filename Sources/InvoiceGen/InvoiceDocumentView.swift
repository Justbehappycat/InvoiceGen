import SwiftUI
import AppKit

/// One printable sheet of an invoice. Laid out at US Letter width (612pt) so it
/// renders straight into a PDF context at 1:1 scale.
struct InvoiceDocumentView: View {
    let invoice: Invoice
    let customer: Customer?
    let business: BusinessProfile
    var page: InvoicePageSpec
    var padToPageHeight: Bool = true
    /// Test hook: prints this code instead of the one the invoice signs to,
    /// which is how `--selftest-pdf` forges "edited page, original barcode".
    var verificationCodeOverride: String?

    init(
        invoice: Invoice,
        customer: Customer?,
        business: BusinessProfile,
        page: InvoicePageSpec? = nil,
        padToPageHeight: Bool = true
    ) {
        self.invoice = invoice
        self.customer = customer
        self.business = business
        self.page = page ?? .whole(itemCount: invoice.items.count)
        self.padToPageHeight = padToPageHeight
    }

    static let pageWidth: CGFloat = 612
    static let pageHeight: CGFloat = 792

    private var accent: Color { Color(hex: business.accentHex) }
    private var accentDark: Color { accent.adjustingBrightness(0.78) }
    private var currency: String { invoice.currencyCode }

    /// The signature printed on the sheet, when a passphrase is set and the
    /// business hasn't switched it off. Derived from the business profile the
    /// view already holds, so pagination measures the real thing.
    private var displayTitle: String {
        invoice.title.isEmpty ? "INVOICE" : invoice.title
    }

    private var verificationCode: String? {
        if let verificationCodeOverride { return verificationCodeOverride }
        guard business.printVerificationCode,
              let key = Verification.cachedKey(
                  passphrase: business.verificationPassphrase,
                  salt: business.verificationSalt
              )
        else { return nil }
        return Verification.code(for: invoice, key: key)
    }

    private var pageItems: ArraySlice<LineItem> {
        let lower = min(max(0, page.start), invoice.items.count)
        let upper = min(max(lower, page.end), invoice.items.count)
        return invoice.items[lower..<upper]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if page.isFirst {
                header
            }
            VStack(alignment: .leading, spacing: 0) {
                if page.isFirst {
                    partiesAndMeta
                        .padding(.top, 28)
                } else {
                    continuationHeader
                        .padding(.top, 28)
                }

                // A trailing totals-only sheet has no rows to head.
                if !pageItems.isEmpty {
                    itemsTable
                        .padding(.top, 24)
                }

                if page.isLast {
                    totals
                        .padding(.top, 18)
                    if !invoice.enabledPaymentMethods.isEmpty {
                        paymentSection.padding(.top, 24)
                    }
                    if !invoice.notes.isEmpty {
                        notes.padding(.top, 18)
                    }
                    if !invoice.footerMessage.isEmpty {
                        Text(invoice.footerMessage)
                            .font(.system(size: 10.5))
                            .foregroundColor(Color(white: 0.42))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)
                    }
                }
            }
            .padding(.horizontal, 44)

            Spacer(minLength: 16)
            businessFooter
        }
        .frame(width: Self.pageWidth, alignment: .topLeading)
        .frame(minHeight: padToPageHeight ? Self.pageHeight : 0, alignment: .top)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        switch business.templateStyle {
        case .banner:
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    if let verificationCode {
                        // The title *is* the mark: solid at the top, combing
                        // open into the code at its foot.
                        // Ink letters, not white: the mark ramps from the
                        // strip's tone into the letters, and a white title
                        // would force that ramp to cross the banner colour
                        // itself — muddy in the middle, no continuity.
                        VerificationMark(
                            title: displayTitle,
                            code: verificationCode,
                            ink: Color(nsColor: Verification.inkColor),
                            field: accent,
                            stripTone: business.verificationStripInk
                                ? Color(nsColor: Verification.inkColor)
                                : accentDark
                        )
                        .padding(.leading, 44)
                        .padding(.bottom, 18)
                    } else {
                        Text(displayTitle)
                            .font(.system(size: 30, weight: .regular))
                            .foregroundColor(.white)
                            .padding(.leading, 44)
                            .padding(.bottom, 22)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 118)
                .background(accent)

                VStack(alignment: .trailing, spacing: 4) {
                    Spacer()
                    Text("Amount Due (\(currency))")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.92))
                    Text(Fmt.currency(invoice.amountDue, code: currency))
                        .font(.system(size: 26, weight: .regular))
                        .foregroundColor(.white)
                        .padding(.bottom, 16)
                }
                .padding(.trailing, 30)
                .frame(width: 212, alignment: .trailing)
                .frame(height: 118)
                .background(accentDark)
            }
        case .minimal:
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let logo = logoImage {
                            Image(nsImage: logo)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 150, maxHeight: 52, alignment: .leading)
                        }
                        Text(business.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.black)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(invoice.title.isEmpty ? "INVOICE" : invoice.title)
                            .font(.system(size: 26, weight: .light))
                            .foregroundColor(accent)
                        Text("Amount Due (\(currency)): \(Fmt.currency(invoice.amountDue, code: currency))")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.black)
                    }
                }
                Rectangle().fill(accent).frame(height: 3)
                if let verificationCode {
                    VerificationMark(
                        title: displayTitle,
                        code: verificationCode,
                        ink: Color(nsColor: Verification.inkColor),
                        field: .white,
                        stripTone: business.verificationStripInk
                            ? Color(nsColor: Verification.inkColor)
                            : Color(white: 0.45),
                        fontSize: 26
                    )
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 44)
            .padding(.top, 40)
        }
    }

    /// The readable form of the code, for reading down a phone line, plus the
    /// signed item count — the one signed field the printed sheet doesn't
    /// otherwise state, which is what makes a PDF checkable on its own.
    private var verificationFooterLine: some View {
        Group {
            if let verificationCode {
                Text("Verification \(verificationCode) · "
                     + "\(Fmt.quantity(Verification.totalQuantity(of: invoice))) items")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Color(white: 0.45))
            }
        }
    }

    private var continuationHeader: some View {
        HStack {
            Text("\(displayTitle) #\(invoice.number) — continued")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.black)
            Spacer()
            Text(customer?.displayName ?? "")
                .font(.system(size: 11))
                .foregroundColor(Color(white: 0.35))
        }
    }

    // MARK: - Bill to + meta

    private var partiesAndMeta: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("BILL TO")
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.55))
                Text(customer?.displayName ?? "—")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.black)
                if let customer {
                    if !customer.contactName.isEmpty {
                        Text(customer.contactName).font(.system(size: 11)).foregroundColor(.black)
                    }
                    ForEach(Array(customer.addressLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11)).foregroundColor(.black)
                    }
                    if !customer.email.isEmpty {
                        Text(customer.email).font(.system(size: 11)).foregroundColor(.black).padding(.top, 4)
                    }
                    if !customer.phone.isEmpty {
                        Text(customer.phone).font(.system(size: 11)).foregroundColor(.black)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 6) {
                metaRow("Invoice Number:", invoice.number)
                if !invoice.poNumber.isEmpty {
                    metaRow("P.O./S.O. Number:", invoice.poNumber)
                }
                metaRow("Invoice Date:", Fmt.longDate(invoice.issueDate))
                metaRow("Payment Due:", Fmt.longDate(invoice.dueDate))
                metaRow(
                    "Amount Due (\(currency)):",
                    Fmt.currency(invoice.amountDue, code: currency),
                    valueBold: true
                )
            }
            .frame(width: 250, alignment: .trailing)
        }
    }

    private func metaRow(_ label: String, _ value: String, valueBold: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(value)
                .font(.system(size: 10.5, weight: valueBold ? .semibold : .regular))
                .foregroundColor(.black)
                .frame(width: 118, alignment: .leading)
        }
    }

    // MARK: - Items

    private var columns: InvoiceColumns { invoice.columns }

    private var itemsTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(columns.itemHeading).frame(maxWidth: .infinity, alignment: .leading)
                if columns.showUnit {
                    Text(columns.unitHeading).frame(width: 80, alignment: .trailing)
                }
                if columns.showPrice {
                    Text(columns.priceHeading).frame(width: 90, alignment: .trailing)
                }
                if columns.showAmount {
                    Text(columns.amountHeading).frame(width: 90, alignment: .trailing)
                }
            }
            .font(.system(size: 9.5))
            .foregroundColor(Color(white: 0.55))
            .padding(.bottom, 8)

            Rectangle().fill(Color(white: 0.88)).frame(height: 1)

            ForEach(Array(pageItems.enumerated()), id: \.element.id) { offset, item in
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.black)
                        if !item.details.isEmpty && columns.showDescription {
                            Text(item.details)
                                .font(.system(size: 10.5))
                                .foregroundColor(Color(white: 0.25))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if columns.showUnit {
                        Text(Fmt.quantity(item.quantity))
                            .frame(width: 80, alignment: .trailing)
                    }
                    if columns.showPrice {
                        Text(Fmt.currency(item.price, code: currency))
                            .frame(width: 90, alignment: .trailing)
                    }
                    if columns.showAmount {
                        Text(Fmt.currency(item.amount, code: currency))
                            .frame(width: 90, alignment: .trailing)
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.black)
                .padding(.vertical, 11)
                .padding(.horizontal, 6)
                .background((page.start + offset).isMultiple(of: 2) ? Color(white: 0.965) : Color.white)
            }

            Rectangle().fill(Color(white: 0.88)).frame(height: 1)
        }
    }

    // MARK: - Totals

    private var totals: some View {
        HStack {
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                if invoice.discountAmount > 0 || invoice.taxAmount > 0 {
                    totalRow("Subtotal:", Fmt.currency(invoice.subtotal, code: currency))
                }
                if invoice.discountAmount > 0 {
                    totalRow(
                        invoice.discountIsPercent
                            ? "Discount (\(Fmt.quantity(invoice.discountValue))%):"
                            : "Discount:",
                        "-" + Fmt.currency(invoice.discountAmount, code: currency)
                    )
                }
                if invoice.taxAmount > 0 {
                    totalRow(
                        "\(invoice.taxLabel) (\(Fmt.quantity(invoice.taxRate))%):",
                        Fmt.currency(invoice.taxAmount, code: currency)
                    )
                }
                totalRow("Total:", Fmt.currency(invoice.total, code: currency), bold: true)

                Rectangle().fill(Color(white: 0.82)).frame(width: 300, height: 1)

                if invoice.amountPaid > 0 {
                    totalRow("Amount Paid:", "-" + Fmt.currency(invoice.amountPaid, code: currency))
                }
                totalRow(
                    "Amount Due (\(currency)):",
                    Fmt.currency(invoice.amountDue, code: currency),
                    bold: true
                )
            }
        }
    }

    private func totalRow(_ label: String, _ value: String, bold: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 11, weight: bold ? .semibold : .regular))
            Text(value)
                .font(.system(size: 11, weight: bold ? .semibold : .regular))
                .frame(width: 110, alignment: .trailing)
        }
        .foregroundColor(.black)
    }

    // MARK: - Payment methods

    private var paymentSection: some View {
        let methods = invoice.enabledPaymentMethods
        let columns = methods.count > 1 ? 2 : 1
        let rows = stride(from: 0, to: methods.count, by: columns).map { start in
            Array(methods[start..<min(start + columns, methods.count)])
        }

        return VStack(alignment: .leading, spacing: 8) {
            Text("HOW TO PAY")
                .font(.system(size: 9.5))
                .foregroundColor(Color(white: 0.55))

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 22) {
                        ForEach(row) { method in
                            methodBlock(method)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if row.count < columns {
                            Spacer().frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private func methodBlock(_ method: PaymentMethod) -> some View {
        HStack(alignment: .top, spacing: 7) {
            PaymentBadge(method: method, size: 17)
            VStack(alignment: .leading, spacing: 1) {
                Text(method.displayTitle)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.black)
                ForEach(method.filledFields) { field in
                    HStack(spacing: 4) {
                        if !field.label.isEmpty {
                            Text("\(field.label):")
                                .font(.system(size: 9.5))
                                .foregroundColor(Color(white: 0.45))
                        }
                        Text(field.value)
                            .font(.system(size: 9.5))
                            .foregroundColor(Color(white: 0.15))
                    }
                }
            }
        }
    }

    // MARK: - Notes

    private var notes: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Notes / Terms")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.black)
            Text(invoice.notes)
                .font(.system(size: 10.5))
                .foregroundColor(Color(white: 0.2))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var logoImage: NSImage? {
        guard let data = business.logoData else { return nil }
        return NSImage(data: data)
    }

    private var businessFooter: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(white: 0.88)).frame(height: 1)
            HStack(alignment: .top, spacing: 18) {
                if let logo = logoImage, business.templateStyle == .banner {
                    Image(nsImage: logo)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 132, height: 60, alignment: .leading)
                } else {
                    Spacer().frame(width: 132)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(business.name)
                        .font(.system(size: 11, weight: .semibold))
                    ForEach(Array(business.addressLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11))
                    }
                    verificationFooterLine.padding(.top, 3)
                }
                .foregroundColor(.black)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("Contact Information")
                        .font(.system(size: 11, weight: .semibold))
                    if !business.phone.isEmpty { Text(business.phone).font(.system(size: 11)) }
                    if !business.email.isEmpty { Text(business.email).font(.system(size: 11)) }
                    if !business.website.isEmpty { Text(business.website).font(.system(size: 11)) }
                }
                .foregroundColor(.black)
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 16)
        }
    }
}
