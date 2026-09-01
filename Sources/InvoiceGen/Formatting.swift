import Foundation
import SwiftUI
import AppKit

enum Fmt {
    static func currency(_ value: Decimal, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
    }

    static func quantity(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 4
        formatter.minimumFractionDigits = 0
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
    }

    static func longDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter.string(from: date)
    }

    static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func fileDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static let currencyCodes = ["USD", "CAD", "EUR", "GBP", "AUD", "JPY", "CNY", "CHF", "SGD", "HKD", "MXN", "INR"]
}

extension Color {
    init(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let intValue = UInt32(value, radix: 16) else {
            self = Color.gray
            return
        }
        self.init(
            .sRGB,
            red: Double((intValue >> 16) & 0xFF) / 255,
            green: Double((intValue >> 8) & 0xFF) / 255,
            blue: Double(intValue & 0xFF) / 255,
            opacity: 1
        )
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Multiplies brightness — used for the darker "amount due" block in the header.
    func adjustingBrightness(_ factor: Double) -> Color {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let adjusted = NSColor(hue: h, saturation: s, brightness: min(max(b * factor, 0), 1), alpha: a)
        return Color(nsColor: adjusted)
    }
}
