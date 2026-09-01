import SwiftUI

/// Reusable products / services so recurring line items can be dropped into
/// any invoice without retyping them.
struct CatalogView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var focus: AppFocus

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Library").font(.title2.weight(.semibold))
                        Text("Reusable line items and whole-invoice templates.")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        store.newCatalogItem()
                    } label: {
                        Label("New item", systemImage: "plus")
                    }
                }

                if !store.data.templates.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Invoice templates").font(.headline)
                        ForEach($store.data.templates) { $template in
                            GroupBox {
                                HStack(spacing: 10) {
                                    TextField("Template name", text: $template.name)
                                    Text("\(template.items.count) item\(template.items.count == 1 ? "" : "s")")
                                        .foregroundColor(.secondary)
                                    Text("Net \(template.paymentTermDays)")
                                        .foregroundColor(.secondary)
                                    Button {
                                        let invoice = store.newInvoice(from: template)
                                        focus.invoiceID = invoice.id
                                        focus.requestedSection = .invoices
                                    } label: {
                                        Label("New invoice", systemImage: "plus")
                                    }
                                    Button(role: .destructive) {
                                        store.data.templates.removeAll { $0.id == template.id }
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(6)
                            }
                        }
                    }
                    .padding(.bottom, 6)

                    Text("Saved items").font(.headline)
                }

                if store.data.catalog.isEmpty {
                    Text("Nothing saved yet. Create an item here, or use “Save to items library” on any invoice line.")
                        .foregroundColor(.secondary)
                        .padding(.vertical, 30)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach($store.data.catalog) { $item in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 10) {
                                    TextField("Item name", text: $item.title)
                                    TextField("0", value: $item.price, format: .number)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 100)
                                    Text(store.data.business.currencyCode)
                                        .foregroundColor(.secondary)
                                    Button(role: .destructive) {
                                        store.data.catalog.removeAll { $0.id == item.id }
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                                TextField("Description (optional)", text: $item.details, axis: .vertical)
                                    .lineLimit(1...4)
                                    .font(.callout)
                                Toggle("Taxable", isOn: $item.taxable)
                                    .toggleStyle(.checkbox)
                                    .font(.callout)
                            }
                            .padding(6)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Items")
    }
}
