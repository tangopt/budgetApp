// App/DesignSystem/MoneyField.swift
import SwiftUI
import BudgetCore

/// The one money input: right-aligned monospaced digits followed by the currency code.
/// On losing focus a parseable entry is rewritten as `Money.formatInput` ("44,007.51");
/// an unparseable one is left as typed and outlined red. Empty is neither — callers
/// decide whether empty is valid. Signs are the caller's business; typing accepts
/// commas, a currency symbol and a leading minus (whatever `Money.parseMinorUnits` does).
struct MoneyField: View {
    let label: String
    @Binding var text: String
    let currency: Currency
    var width: CGFloat?

    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    init(_ label: String, text: Binding<String>, currency: Currency, width: CGFloat? = nil) {
        self.label = label
        self._text = text
        self.currency = currency
        self.width = width
    }

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var isInvalid: Bool { isEnabled && !isEmpty && Money.parseMinorUnits(text) == nil }

    static func invalidAmountMessage(_ text: String) -> String {
        "“\(text.trimmingCharacters(in: .whitespacesAndNewlines))” isn't a valid amount. Use digits with an optional decimal point, e.g. 1,234.56."
    }

    var body: some View {
        HStack {
            TextField(label, text: $text)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .focused($focused)
                .frame(width: width)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isInvalid && !focused ? Color.red : Color.clear))
                .help(isInvalid ? Self.invalidAmountMessage(text) : "")
            Text(currency.rawValue.uppercased())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
        .onChange(of: focused) { _, isFocused in
            guard !isFocused, let value = Money.parseMinorUnits(text) else { return }
            text = Money.formatInput(value)
        }
    }
}
