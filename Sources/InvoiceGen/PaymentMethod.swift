import SwiftUI

/// A way for a customer to pay: shown on the invoice as a badge, a title and a
/// short list of label/value fields, instead of a free-text notes blob.
struct PaymentMethod: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var kind: PaymentKind = .bank
    var title: String = ""
    var fields: [PaymentField] = []
    /// Optional real logo. Falls back to the drawn badge when nil.
    var iconData: Data?
    var isEnabled: Bool = true
    /// Picks the badge monogram/tint for bank and wire methods.
    var bankPresetID: String?

    var bankPreset: BankPreset? {
        guard let bankPresetID else { return nil }
        return BankPreset.all.first { $0.id == bankPresetID }
    }

    /// Switches kind, dropping the old kind's empty fields so a Bank method
    /// turned into a Zelle one doesn't keep an account and routing number.
    mutating func changeKind(to newKind: PaymentKind) {
        guard newKind != kind else { return }
        let oldLabels = Set(kind.defaultFields.map { $0.label })
        let newLabels = Set(newKind.defaultFields.map { $0.label })

        kind = newKind
        // Details that belonged to the old kind go with it, filled in or not: a
        // Zelle method has no business carrying a routing number. Fields the
        // user added by hand are kept. ⌘Z undoes a misclick.
        fields.removeAll { oldLabels.contains($0.label) && !newLabels.contains($0.label) }
        for index in fields.indices where !newLabels.contains(fields[index].label) {
            fields[index].isRequired = false
        }
        ensureRequiredFields()
        fields.sort { lhs, rhs in
            let order = newKind.defaultFields.map { $0.label }
            let l = order.firstIndex(of: lhs.label) ?? order.count
            let r = order.firstIndex(of: rhs.label) ?? order.count
            return l < r
        }
        if newKind != .bank && newKind != .wire { bankPresetID = nil }
    }

    /// Field labels were sharpened after the first release ("Handle" became
    /// "Cashtag" and so on). Rename rather than leave a stale row beside a new
    /// empty one.
    mutating func normalizeLabels() {
        var renames: [String: String] = [
            "Zelle ID": "Zelle ID (email or phone)",
            "Routing number": "Routing number (ACH)",
            "Pay at": "Payment link",
            "Details": "Instructions"
        ]
        switch kind {
        case .zelle: renames["Name"] = "Recipient name"
        case .paypal: renames["Handle"] = "PayPal email"
        case .venmo: renames["Handle"] = "Venmo handle"
        case .cashApp: renames["Handle"] = "Cashtag"
        case .wire: renames["Account number"] = "Account number / IBAN"
        case .crypto: renames["Address"] = "Wallet address"
        default: break
        }

        let valid = Set(kind.defaultFields.map { $0.label })
        for index in fields.indices {
            guard let newLabel = renames[fields[index].label], valid.contains(newLabel) else { continue }
            // Don't collide with a row that already carries the new label.
            if fields.contains(where: { $0.label == newLabel }) { continue }
            fields[index].label = newLabel
        }
        ensureRequiredFields()
        fields.removeAll { $0.value.isEmpty && !$0.isRequired && !valid.contains($0.label) && $0.label.isEmpty }
    }

    /// Adds back any required field that an older file or a kind change dropped.
    mutating func ensureRequiredFields() {
        for required in kind.defaultFields where required.isRequired {
            if let index = fields.firstIndex(where: {
                $0.label.caseInsensitiveCompare(required.label) == .orderedSame
            }) {
                fields[index].isRequired = true
            } else {
                fields.append(required)
            }
        }
    }

    var displayTitle: String { title.isEmpty ? kind.label : title }

    var filledFields: [PaymentField] { fields.filter { !$0.value.isEmpty } }

    /// Fills a field by label, adding it when the kind doesn't define it.
    mutating func set(_ label: String, _ value: String) {
        if let index = fields.firstIndex(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }) {
            fields[index].value = value
        } else {
            fields.append(PaymentField(label, value))
        }
    }

    static func make(_ kind: PaymentKind) -> PaymentMethod {
        PaymentMethod(kind: kind, title: kind.label, fields: kind.defaultFields)
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, fields, iconData, isEnabled, bankPresetID
    }

    init(
        id: UUID = UUID(),
        kind: PaymentKind = .bank,
        title: String = "",
        fields: [PaymentField] = [],
        iconData: Data? = nil,
        isEnabled: Bool = true,
        bankPresetID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.fields = fields
        self.iconData = iconData
        self.isEnabled = isEnabled
        self.bankPresetID = bankPresetID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(PaymentKind.self, forKey: .kind) ?? .bank
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        fields = try c.decodeIfPresent([PaymentField].self, forKey: .fields) ?? []
        iconData = try c.decodeIfPresent(Data.self, forKey: .iconData)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        bankPresetID = try c.decodeIfPresent(String.self, forKey: .bankPresetID)
        normalizeLabels()
    }
}

struct PaymentField: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var label: String = ""
    var value: String = ""
    /// A field the method cannot do without. The value may be left blank, but
    /// the row itself cannot be deleted or relabelled.
    var isRequired: Bool = false

    init(id: UUID = UUID(), _ label: String = "", _ value: String = "", required: Bool = false) {
        self.id = id
        self.label = label
        self.value = value
        self.isRequired = required
    }

    enum CodingKeys: String, CodingKey { case id, label, value, isRequired }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        isRequired = try c.decodeIfPresent(Bool.self, forKey: .isRequired) ?? false
    }
}

enum PaymentKind: String, Codable, CaseIterable, Identifiable {
    case zelle
    case bank
    case wire
    case paypal
    case venmo
    case cashApp
    case check
    case card
    case crypto
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .zelle: return "Zelle"
        case .bank: return "Bank Transfer"
        case .wire: return "Wire Transfer"
        case .paypal: return "PayPal"
        case .venmo: return "Venmo"
        case .cashApp: return "Cash App"
        case .check: return "Check"
        case .card: return "Card"
        case .crypto: return "Crypto"
        case .other: return "Other"
        }
    }

    /// Brand-ish tint for the badge. Not official artwork — a customer can drop
    /// a real logo onto any method in Settings.
    var tintHex: String {
        switch self {
        case .zelle: return "#6D1ED4"
        case .bank: return "#2F6FEB"
        case .wire: return "#1F4FA8"
        case .paypal: return "#003087"
        case .venmo: return "#008CFF"
        case .cashApp: return "#00C244"
        case .check: return "#4B5563"
        case .card: return "#111827"
        case .crypto: return "#F7931A"
        case .other: return "#6B7280"
        }
    }

    /// Badge artwork: an SF Symbol, or a letter when no symbol reads right.
    var symbolName: String? {
        switch self {
        case .zelle, .paypal, .venmo: return nil
        case .bank: return "building.columns.fill"
        case .wire: return "arrow.left.arrow.right"
        case .cashApp: return "dollarsign"
        case .check: return "doc.text.fill"
        case .card: return "creditcard.fill"
        case .crypto: return "bitcoinsign"
        case .other: return "banknote.fill"
        }
    }

    var letter: String {
        switch self {
        case .zelle: return "Z"
        case .paypal: return "P"
        case .venmo: return "V"
        default: return String(label.prefix(1))
        }
    }

    var defaultFields: [PaymentField] {
        switch self {
        case .zelle:
            // Zelle moves money by email/phone — no account or routing number.
            return [
                PaymentField("Zelle ID (email or phone)", "", required: true),
                PaymentField("Recipient name", "", required: true)
            ]
        case .bank:
            return [
                PaymentField("Bank", "", required: true),
                PaymentField("Account holder", ""),
                PaymentField("Account number", "", required: true),
                PaymentField("Routing number (ACH)", "", required: true),
                PaymentField("Account type", "")
            ]
        case .wire:
            return [
                PaymentField("Bank", "", required: true),
                PaymentField("Beneficiary", ""),
                PaymentField("Account number / IBAN", "", required: true),
                PaymentField("SWIFT/BIC", "", required: true),
                PaymentField("Wire routing (ABA)", ""),
                PaymentField("Bank address", "")
            ]
        case .paypal:
            return [
                PaymentField("PayPal email", "", required: true),
                PaymentField("PayPal.me link", "")
            ]
        case .venmo:
            return [
                PaymentField("Venmo handle", "", required: true),
                PaymentField("Last 4 of phone", "")
            ]
        case .cashApp:
            return [PaymentField("Cashtag", "", required: true)]
        case .check:
            return [
                PaymentField("Payable to", "", required: true),
                PaymentField("Mail to", ""),
                PaymentField("Memo", "")
            ]
        case .card:
            return [
                PaymentField("Payment link", "", required: true),
                PaymentField("Cards accepted", "")
            ]
        case .crypto:
            return [
                PaymentField("Network", "", required: true),
                PaymentField("Wallet address", "", required: true)
            ]
        case .other:
            return [PaymentField("Instructions", "", required: true)]
        }
    }

    /// Placeholder shown in the editor so the expected format is obvious.
    func hint(for label: String) -> String {
        switch label {
        case "Zelle ID (email or phone)": return "you@example.com or 555-123-4567"
        case "Cashtag": return "$yourcashtag"
        case "Venmo handle": return "@your-handle"
        case "PayPal email": return "you@example.com"
        case "PayPal.me link": return "paypal.me/yourname"
        case "Payment link": return "https://…"
        case "Account type": return "Checking / Savings"
        case "Network": return "Bitcoin, Ethereum, USDC…"
        default: return "Optional to fill"
        }
    }
}

/// The little square that identifies a payment method.
struct PaymentBadge: View {
    let method: PaymentMethod
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let data = method.iconData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(Color(hex: method.bankPreset?.tintHex ?? method.kind.tintHex))
                    .frame(width: size, height: size)
                    .overlay(glyph)
            }
        }
    }

    @ViewBuilder
    private var glyph: some View {
        if let preset = method.bankPreset {
            Text(preset.monogram)
                .font(.system(size: size * (preset.monogram.count > 2 ? 0.34 : 0.46),
                              weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.horizontal, 1)
        } else if let symbol = method.kind.symbolName {
            Image(systemName: symbol)
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(.white)
        } else {
            Text(method.kind.letter)
                .font(.system(size: size * 0.62, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}


/// Monogram badges for the banks most US clients pay from. These are drawn
/// marks, not the banks' official logos — pick "Choose logo image…" on a method
/// if you want the real artwork.
struct BankPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let monogram: String
    let tintHex: String

    static let all: [BankPreset] = [
        BankPreset(id: "chase", name: "Chase", monogram: "C", tintHex: "#117ACA"),
        BankPreset(id: "bofa", name: "Bank of America", monogram: "BA", tintHex: "#C4122E"),
        BankPreset(id: "wells", name: "Wells Fargo", monogram: "WF", tintHex: "#D71E28"),
        BankPreset(id: "citi", name: "Citibank", monogram: "citi", tintHex: "#003B70"),
        BankPreset(id: "usbank", name: "U.S. Bank", monogram: "US", tintHex: "#0C2074"),
        BankPreset(id: "pnc", name: "PNC Bank", monogram: "PNC", tintHex: "#F58025"),
        BankPreset(id: "capitalone", name: "Capital One", monogram: "C1", tintHex: "#D03027"),
        BankPreset(id: "td", name: "TD Bank", monogram: "TD", tintHex: "#54B848"),
        BankPreset(id: "truist", name: "Truist", monogram: "T", tintHex: "#52247F"),
        BankPreset(id: "schwab", name: "Charles Schwab", monogram: "S", tintHex: "#00A0DF"),
        BankPreset(id: "ally", name: "Ally Bank", monogram: "A", tintHex: "#6B2C91"),
        BankPreset(id: "amex", name: "American Express", monogram: "AX", tintHex: "#016FD0"),
        BankPreset(id: "discover", name: "Discover", monogram: "D", tintHex: "#F76B1C"),
        BankPreset(id: "navyfed", name: "Navy Federal", monogram: "NF", tintHex: "#003A63"),
        BankPreset(id: "fifththird", name: "Fifth Third", monogram: "53", tintHex: "#00573F"),
        BankPreset(id: "regions", name: "Regions Bank", monogram: "R", tintHex: "#00954C"),
        BankPreset(id: "citizens", name: "Citizens Bank", monogram: "CB", tintHex: "#00573F"),
        BankPreset(id: "hsbc", name: "HSBC", monogram: "H", tintHex: "#DB0011"),
        BankPreset(id: "mercury", name: "Mercury", monogram: "M", tintHex: "#5266EB"),
        BankPreset(id: "chime", name: "Chime", monogram: "CH", tintHex: "#1EC677")
    ]
}
