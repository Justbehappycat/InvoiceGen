import SwiftUI

/// The editor's shared measurements and small shared views.
///
/// The invoice editor used to be seven `GroupBox`es stacked on top of each
/// other, which gave every section the same visual weight and filled the pane
/// with grey. A document editor on this platform reads better as one sheet:
/// quiet headings, a shared label column so every field lines up down the
/// page, and hairlines only where a boundary actually means something.
enum Metrics {
    /// Horizontal margin of the form. Narrow enough that a 520pt pane still
    /// has room for the fields, wide enough not to feel cramped.
    static let gutter: CGFloat = 18
    /// Between one section and the next.
    static let sectionGap: CGFloat = 20
    /// Between rows inside a section. Ten rather than eight: at eight the
    /// totals and the line-item description read as one dense block.
    static let rowGap: CGFloat = 10
    /// Every label in the editor is this wide, so the fields beside them form
    /// one column from Customer all the way down to Totals.
    static let labelWidth: CGFloat = 96
    /// The ordinary single-value field. 104, not 128: two of these plus a date
    /// have to sit side by side in a 520pt pane, or Details falls back to one
    /// tall column at ordinary laptop widths.
    static let fieldWidth: CGFloat = 104
    /// How far a short field may grow when the pane has room. Past this an
    /// invoice number box is just a long empty bar.
    static let fieldMaxWidth: CGFloat = 220

    /// The editor column's widest, gutters included, when it has the window
    /// to itself. Past this, rows are too long to read across.
    static let editorMaxWidth: CGFloat = 960

    // Line-item columns, shared by the header and every row so they cannot
    // drift apart.
    static let quantityColumn: CGFloat = 60
    static let priceColumn: CGFloat = 92
    static let amountColumn: CGFloat = 92
    static let actionColumn: CGFloat = 40
    /// Where money lines up on the right.
    static let amountWidth: CGFloat = 104

    // Three corner radii for the whole app, so a text box, a panel and a
    // glass surface each have one answer instead of five. These replaced a
    // scatter of 5, 6, 8, 16 and 20 that had no rule behind it.
    /// Text boxes and other small inset surfaces.
    static let corner: CGFloat = 6
    /// Panels, popovers and cards.
    static let cornerPanel: CGFloat = 10
    /// Glass surfaces, which read as thicker and want a larger curve.
    static let cornerGlass: CGFloat = 16
}

/// A quiet section heading. Secondary and small on purpose: the content is
/// what matters, and seven loud headings down a page is noise.
struct SectionHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
            Spacer(minLength: 8)
            accessory()
                .controlSize(.small)
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// A form row: fixed label column, content beside it. Using this everywhere is
/// what makes the fields line up without each section inventing its own width.
struct FormRow<Content: View>: View {
    let label: String
    var labelWidth: CGFloat = Metrics.labelWidth
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .frame(width: labelWidth, alignment: .leading)
                .foregroundStyle(.secondary)
            content()
            Spacer(minLength: 0)
        }
    }
}

/// Money, always with tabular figures so columns of it line up and a changing
/// total doesn't shuffle the digits beside it.
struct Money: View {
    let amount: Decimal
    let code: String
    var font: Font = .body
    var weight: Font.Weight = .regular
    var tint: HierarchicalShapeStyle = .primary

    var body: some View {
        Text(Fmt.currency(amount, code: code))
            .font(font.weight(weight))
            .monospacedDigit()
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}

/// The hairline between sections. One line, inset to the content margin, and
/// nothing else — no card, no fill, no shadow.
struct SectionRule: View {
    var body: some View {
        Divider().opacity(0.6)
    }
}
