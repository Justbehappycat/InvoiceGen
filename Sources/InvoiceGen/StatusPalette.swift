import SwiftUI
import AppKit

/// The colours that carry an invoice's status, chosen by measurement rather
/// than by eye.
///
/// The badges used to be the raw system hue for the text over 18% of the same
/// hue. Measured against the real selection colours, every badge failed WCAG
/// AA (4.5:1) except in dark mode on an unselected row: "Paid" was 1.92:1 on a
/// plain white row and "Sent" 1.41:1 on a focused selection -- the hue against
/// itself. The text shades below are each hue walked toward black (light) or
/// white (dark) until it clears 4.6:1 on an unselected row *and* on an
/// unfocused selection. On a focused selection the row is the accent colour,
/// so text goes white; white on the accent clears AA unaided, and the capsule
/// becomes an outline because any tint behind the text would only lower it.
///
/// `--selftest-ui` re-measures all of this against whatever selection colours
/// this Mac is using, so a palette change or an unusual accent colour shows up
/// as a failing check rather than as a badge nobody can read.
enum StatusTone: CaseIterable {
    case draft, sent, paid, overdue

    init(status: InvoiceStatus, overdue: Bool) {
        if overdue { self = .overdue; return }
        switch status {
        case .draft: self = .draft
        case .sent: self = .sent
        case .paid: self = .paid
        }
    }

    /// The system hue the badge is tinted with.
    var hue: NSColor {
        switch self {
        case .draft: return .systemGray
        case .sent: return .systemBlue
        case .paid: return .systemGreen
        case .overdue: return .systemOrange
        }
    }

    /// Text on light surfaces: the hue darkened until it passes.
    var lightText: (r: Int, g: Int, b: Int) {
        switch self {
        case .draft: return (0x57, 0x57, 0x5A)
        case .sent: return (0x00, 0x56, 0xA1)
        case .paid: return (0x1B, 0x65, 0x2D)
        case .overdue: return (0x85, 0x49, 0x15)
        }
    }

    /// Text on dark surfaces: the hue lightened until it passes.
    var darkText: (r: Int, g: Int, b: Int) {
        switch self {
        case .draft: return (0xC8, 0xC8, 0xCB)
        case .sent: return (0x85, 0xCA, 0xFF)
        case .paid: return (0x7F, 0xE2, 0x97)
        case .overdue: return (0xFF, 0xBF, 0x85)
        }
    }

    /// How much of the hue tints the capsule behind the text. The search that
    /// produced the shades above assumed exactly this.
    static let fillOpacity: Double = 0.16

    var text: Color {
        let light = lightText, dark = darkText
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
                           blue: CGFloat(c.b) / 255, alpha: 1)
        })
    }

    var fill: Color { Color(nsColor: hue).opacity(Self.fillOpacity) }
}

/// Text in a status colour that stays readable when its row is selected.
private struct StatusForeground: ViewModifier {
    let tone: StatusTone

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.modifier(ProminenceAwareForeground(tone: tone))
        } else {
            content.foregroundStyle(tone.text)
        }
    }
}

@available(macOS 14.0, *)
private struct ProminenceAwareForeground: ViewModifier {
    let tone: StatusTone
    /// `.increased` inside a focused, selected row -- the accent background.
    @Environment(\.backgroundProminence) private var prominence

    func body(content: Content) -> some View {
        if prominence == .increased {
            content.foregroundStyle(.white)
        } else {
            content.foregroundStyle(tone.text)
        }
    }
}

extension View {
    /// Colours text by status, switching to white on a focused selection.
    func statusForeground(_ tone: StatusTone) -> some View {
        modifier(StatusForeground(tone: tone))
    }
}
