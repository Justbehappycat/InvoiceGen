import SwiftUI

/// What the line-item table is called and which of its columns print.
///
/// An hourly studio bills "Hours × Rate", a reseller sells "Products", and a
/// flat-fee job wants neither quantity nor unit price on the page — only a
/// description and an amount. The item column itself is never hidden: a table
/// with no rows to name is not an invoice.
struct InvoiceColumns: Codable, Hashable {
    var itemTitle: String = "Items"
    var unitTitle: String = "Quantity"
    var priceTitle: String = "Price"
    var amountTitle: String = "Amount"

    var showDescription: Bool = true
    var showUnit: Bool = true
    var showPrice: Bool = true
    var showAmount: Bool = true

    static let itemPresets = ["Items", "Products", "Services"]
    static let unitPresets = ["Quantity", "Hours", "Days", "Units"]
    static let pricePresets = ["Price", "Rate"]
    static let amountPresets = ["Amount", "Total"]

    enum CodingKeys: String, CodingKey {
        case itemTitle, unitTitle, priceTitle, amountTitle
        case showDescription, showUnit, showPrice, showAmount
    }

    init() {}

    /// Older data files have no columns key at all, and a file written by a
    /// build that only knew some of these keys must still land on "visible".
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = InvoiceColumns()
        itemTitle = try c.decodeIfPresent(String.self, forKey: .itemTitle) ?? fallback.itemTitle
        unitTitle = try c.decodeIfPresent(String.self, forKey: .unitTitle) ?? fallback.unitTitle
        priceTitle = try c.decodeIfPresent(String.self, forKey: .priceTitle) ?? fallback.priceTitle
        amountTitle = try c.decodeIfPresent(String.self, forKey: .amountTitle) ?? fallback.amountTitle
        showDescription = try c.decodeIfPresent(Bool.self, forKey: .showDescription) ?? true
        showUnit = try c.decodeIfPresent(Bool.self, forKey: .showUnit) ?? true
        showPrice = try c.decodeIfPresent(Bool.self, forKey: .showPrice) ?? true
        showAmount = try c.decodeIfPresent(Bool.self, forKey: .showAmount) ?? true
    }

    /// A blank title would leave a nameless column on the printed page.
    func heading(_ title: String, fallback: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return (trimmed.isEmpty ? fallback : trimmed).uppercased()
    }

    var itemHeading: String { heading(itemTitle, fallback: "Items") }
    var unitHeading: String { heading(unitTitle, fallback: "Quantity") }
    var priceHeading: String { heading(priceTitle, fallback: "Price") }
    var amountHeading: String { heading(amountTitle, fallback: "Amount") }
}

/// Shared by the per-invoice popover and the business defaults in Settings.
struct ColumnSettingsEditor: View {
    @Binding var columns: InvoiceColumns

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Item column").gridColumnAlignment(.trailing)
                    titleField($columns.itemTitle, presets: InvoiceColumns.itemPresets, fallback: "Items")
                    Text("always shown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Quantity").gridColumnAlignment(.trailing)
                    titleField($columns.unitTitle, presets: InvoiceColumns.unitPresets, fallback: "Quantity")
                    Toggle("Print", isOn: $columns.showUnit)
                }
                GridRow {
                    Text("Price").gridColumnAlignment(.trailing)
                    titleField($columns.priceTitle, presets: InvoiceColumns.pricePresets, fallback: "Price")
                    Toggle("Print", isOn: $columns.showPrice)
                }
                GridRow {
                    Text("Amount").gridColumnAlignment(.trailing)
                    titleField($columns.amountTitle, presets: InvoiceColumns.amountPresets, fallback: "Amount")
                    Toggle("Print", isOn: $columns.showAmount)
                }
                GridRow {
                    Text("Descriptions").gridColumnAlignment(.trailing)
                    Toggle("Print the description under each item", isOn: $columns.showDescription)
                        .gridCellColumns(2)
                }
            }

            Text("Hidden columns are still yours to fill in — they just don't print. "
                 + "Totals always use quantity × price.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func titleField(
        _ text: Binding<String>, presets: [String], fallback: String
    ) -> some View {
        HStack(spacing: 4) {
            TextField(fallback, text: text)
                .frame(width: 150)
            Menu {
                ForEach(presets, id: \.self) { preset in
                    Button(preset) { text.wrappedValue = preset }
                }
            } label: {
                EmptyView()
            }
            .menuStyle(.borderlessButton)
            .frame(width: 14)
            .help("Common names for this column")
        }
    }
}
