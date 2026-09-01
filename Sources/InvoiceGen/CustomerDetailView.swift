import SwiftUI

struct CustomerDetailView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var focus: AppFocus
    @Binding var customer: Customer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("Business name")
                            TextField("Acme LLC", text: $customer.name)
                        }
                        GridRow {
                            Text("Contact name")
                            TextField("Jane Doe", text: $customer.contactName)
                        }
                        GridRow {
                            Text("Email")
                            TextField("billing@acme.com", text: $customer.email)
                        }
                        GridRow {
                            Text("Phone")
                            TextField("", text: $customer.phone)
                        }
                    }
                    .padding(6)
                } label: {
                    Text("Contact").font(.headline)
                }

                GroupBox {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("Address")
                            TextField("Street", text: $customer.addressLine1)
                        }
                        GridRow {
                            Text("")
                            TextField("Suite / unit", text: $customer.addressLine2)
                        }
                        GridRow {
                            Text("City")
                            TextField("", text: $customer.city)
                        }
                        GridRow {
                            Text("State / region")
                            TextField("", text: $customer.region)
                        }
                        GridRow {
                            Text("Postal code")
                            TextField("", text: $customer.postalCode)
                        }
                        GridRow {
                            Text("Country")
                            TextField("", text: $customer.country)
                        }
                    }
                    .padding(6)
                } label: {
                    Text("Address").font(.headline)
                }

                GroupBox {
                    TextEditor(text: $customer.notes)
                        .frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                        .padding(6)
                } label: {
                    Text("Internal notes").font(.headline)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        let invoices = store.invoices(for: customer.id)
                        if invoices.isEmpty {
                            Text("No invoices yet.").foregroundColor(.secondary)
                        } else {
                            ForEach(invoices) { invoice in
                                HStack {
                                    Text("#\(invoice.number)").frame(width: 60, alignment: .leading)
                                    Text(Fmt.shortDate(invoice.issueDate)).foregroundColor(.secondary)
                                    Spacer()
                                    StatusChip(status: invoice.status, overdue: invoice.isOverdue)
                                    Text(Fmt.currency(invoice.total, code: invoice.currencyCode))
                                        .frame(width: 100, alignment: .trailing)
                                    Button("Open") {
                                        focus.invoiceID = invoice.id
                                        focus.requestedSection = .invoices
                                    }
                                    .buttonStyle(.borderless)
                                }
                                Divider()
                            }
                            HStack {
                                Text("Total billed").font(.callout.weight(.semibold))
                                Spacer()
                                Text(Fmt.currency(
                                    invoices.reduce(Decimal(0)) { $0 + $1.total },
                                    code: store.data.business.currencyCode
                                ))
                                .font(.callout.weight(.semibold))
                            }
                        }
                    }
                    .padding(6)
                } label: {
                    Text("History").font(.headline)
                }

                HStack {
                    Button {
                        let invoice = store.newInvoice(customerID: customer.id)
                        focus.invoiceID = invoice.id
                        focus.requestedSection = .invoices
                    } label: {
                        Label("New invoice for this customer", systemImage: "plus")
                    }
                    Spacer()
                    Button(role: .destructive) {
                        let id = customer.id
                        focus.customerID = nil
                        store.deleteCustomer(id: id)
                    } label: {
                        Label("Delete customer", systemImage: "trash")
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(customer.displayName)
        .onAppear { focus.customerID = customer.id }
        .onDisappear { store.sortCustomers() }
    }
}
