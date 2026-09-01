import SwiftUI

/// A number field where clearing it means zero.
///
/// SwiftUI's `TextField(value:format:)` parses on every keystroke and, when the
/// parse fails, puts the old value back. An empty string is a failed parse — so
/// deleting the last digit of "500" silently restores 500, and the only way to
/// reach zero is to select-all and type over it. Here the text is the state and
/// the number follows it: empty parses as zero, and a half-typed "1." simply
/// leaves the value alone until it means something.
struct DecimalField: View {
    let placeholder: String
    @Binding var value: Decimal
    var alignment: TextAlignment = .leading

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .multilineTextAlignment(alignment)
            .focused($isFocused)
            .onAppear { text = Self.string(from: value) }
            .onChange(of: value) { newValue in
                // Only rewrite the text when the value moved somewhere the
                // text doesn't already say — otherwise typing fights itself.
                if Self.decimal(from: text) != newValue {
                    text = Self.string(from: newValue)
                }
            }
            .onChange(of: text) { newText in
                if let next = Self.value(for: newText), next != value { value = next }
            }
            .onChange(of: isFocused) { focused in
                // Tidy up once, on the way out — never mid-edit.
                if !focused { text = Self.string(from: value) }
            }
    }

    /// What the typed text means, or nil to leave the value untouched.
    /// Empty is zero — that is the whole point. An unparseable fragment
    /// ("1.", "-", "abc") means "not yet", so the value keeps its last meaning
    /// and the text keeps what was typed.
    static func value(for text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return 0 }
        return decimal(from: trimmed)
    }

    static func string(from value: Decimal) -> String {
        value == 0 ? "0" : Fmt.quantity(value)
    }

    static func decimal(from text: String) -> Decimal? {
        let cleaned = text
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return 0 }
        // Decimal(string:) accepts "12abc" as 12; require the whole string to
        // be a number so junk doesn't quietly become a value.
        guard cleaned.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }),
              cleaned.filter({ $0 == "." }).count <= 1,
              cleaned != "-", cleaned != ".", cleaned != "-."
        else { return nil }
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }
}

/// The same, for whole numbers — payment terms, the next invoice number.
struct IntegerField: View {
    let placeholder: String
    @Binding var value: Int
    var minimum: Int = 0
    var alignment: TextAlignment = .leading

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    /// Empty means the floor, not "put the old number back".
    static func value(for digits: String, minimum: Int) -> Int? {
        if digits.isEmpty { return minimum }
        guard let parsed = Int(digits) else { return nil }
        return max(minimum, parsed)
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .multilineTextAlignment(alignment)
            .focused($isFocused)
            .onAppear { text = String(value) }
            .onChange(of: value) { newValue in
                if Int(text) != newValue { text = String(newValue) }
            }
            .onChange(of: text) { newText in
                let digits = newText.filter(\.isNumber)
                if digits != newText { text = digits; return }
                if let next = Self.value(for: digits, minimum: minimum), next != value {
                    value = next
                }
            }
            .onChange(of: isFocused) { focused in
                if !focused { text = String(value) }
            }
    }
}
