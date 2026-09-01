import Foundation

extension AppData {
    /// First-launch content, matched to the sample invoice this app was modelled on.
    /// Everything here is editable — it just saves retyping on day one.
    static func seeded() -> AppData {
        var data = AppData()

        var business = BusinessProfile()
        business.name = "Finecut Studio LLC"
        business.city = "California"
        business.country = "United States"
        business.phone = "5555550123"
        business.website = "finecut.com"
        business.logoData = SeedAssets.logoData
        business.accentHex = "#7C7C7C"
        business.templateStyle = .banner
        business.currencyCode = "USD"
        business.defaultPaymentTermDays = 30
        business.defaultFooterMessage = "It was a pleasure working with you!"
        business.defaultNotes = ""
        business.paymentMethods = AppData.seededPaymentMethods()
        data.business = business

        var customer = Customer()
        customer.name = "Harbour Coffee Roasters"
        customer.email = "accounts@example.com"
        data.customers = [customer]

        data.catalog = [
            CatalogItem(
                title: "Commercial Edit",
                details: "Long x1 Short x1 Reel x1 + VFX Graphic",
                price: 1075,
                taxable: false
            ),
            CatalogItem(title: "Additional Revision Round", details: "", price: 150, taxable: false),
            CatalogItem(title: "Color Grade", details: "Per finished minute", price: 200, taxable: false)
        ]

        var sample = Invoice()
        sample.number = "8"
        sample.customerID = customer.id
        sample.currencyCode = "USD"
        sample.notes = business.defaultNotes
        sample.paymentMethods = business.paymentMethods
        sample.footerMessage = business.defaultFooterMessage
        sample.status = .sent
        sample.issueDate = AppData.date(2026, 8, 16)
        sample.dueDate = AppData.date(2026, 9, 15)
        sample.items = [
            LineItem(
                title: "Commercial Edit",
                details: "Long x1 Short x1 Reel x1 + VFX Graphic",
                quantity: 1,
                price: 1075,
                taxable: false
            )
        ]
        data.invoices = [sample]
        data.nextInvoiceNumber = 9

        return data
    }

    /// Also used when migrating a data file that still keeps payment details
    /// in the free-text notes field.
    static func seededPaymentMethods() -> [PaymentMethod] {
        var zelle = PaymentMethod.make(.zelle)
        zelle.set("Zelle ID (email or phone)", "billing@example.com")
        zelle.set("Recipient name", "FINECUT STUDIO LLC")

        var bank = PaymentMethod.make(.bank)
        bank.title = "U.S. Bank"
        bank.bankPresetID = "usbank"
        bank.set("Bank", "US Bank Checking")
        bank.set("Account number", "000123456789")
        bank.set("Routing number (ACH)", "123456789")

        return [zelle, bank]
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return Calendar.current.date(from: components) ?? Date()
    }
}
