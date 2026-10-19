// App/DesignSystem/MoneyText.swift
import SwiftUI
import BudgetCore

/// What an amount is, which decides how it reads (UI polish spec §1.4, the money rule):
///
/// - `.signed` — a change to the user's money given with its sign (a transaction, a net
///   figure, a profit, cash flow): positive in the income colour, negative in the expense
///   colour, zero neutral. The default.
/// - `.cost` — a cost given as a positive magnitude. In a money table, a figure strip or a
///   total, beside figures of other kinds, it shows **negative, in the expense colour**
///   ("−€120.00"; a refund, negative, reads as a gain). Costs never show in the income green.
/// - `.neutral` — a figure that is neither a gain nor a loss, as given in the neutral colour:
///   balances, prices, deposits, loan outstanding, amounts on a document (a rent receipt, a
///   statement line), values to copy into a form (Self Assessment boxes, P60 figures) — and
///   **the parts of a breakdown in which every row is a cost** (costs by category, a line's
///   sources, the bills coming up), where red on every row would say nothing.
enum MoneyRole {
    case signed
    case cost
    case neutral

    /// The amount as shown: a cost negated, anything else as given.
    func displayed(_ minorUnits: Int) -> Int {
        self == .cost ? -minorUnits : minorUnits
    }
}

/// Renders a minor-units amount via `Money.format`, colored by sign in the theme's income
/// (positive) and expense (negative) colours, which adapt to light/dark mode. This is
/// the one place money color/formatting logic lives — every other view should use this
/// instead of formatting `Money.format` output directly. `role` says what the amount is
/// (`MoneyRole`): signed by default; a cost shows negative; a neutral figure isn't coloured.
struct MoneyText: View {
    let minorUnits: Int
    var currency: Currency = .gbp
    var font: Font = .system(.body, design: .default).monospacedDigit()
    var role: MoneyRole = .signed
    /// When set, colors by this value's sign instead of `minorUnits`'s — for cases where
    /// the displayed number is a positive magnitude (e.g. "amount owed") but the color
    /// should reflect the underlying signed value (negative = bad).
    var colorOverride: Int? = nil
    /// When set, the text fills the width it's given and aligns within it — e.g.
    /// `.trailing` for table columns, so figures right-align and decimal points line up.
    /// Nil (the default) keeps the text at its natural size, which inline call sites
    /// (Net Worth, Import, Forecast, lists with a `Spacer`) rely on. Either way it's one line.
    var alignment: Alignment? = nil
    /// When set, overrides the sign-based income/expense/neutral color entirely — for callers
    /// that need a fixed color regardless of the value's sign (e.g. marking a figure as a
    /// pending amount, not a real change in either direction).
    var tint: Color? = nil
    /// Whole units, the pence dropped (towards zero): "£41,760" — a Self Assessment box, which
    /// the return takes in whole pounds and whose copy is the same figure.
    var wholeUnits = false
    /// How far the amount may shrink in a fixed-width cell (`alignment`) before it would truncate.
    var minimumScale: CGFloat = MoneyText.minimumScale
    @Environment(\.theme) private var theme

    /// How far an amount in a fixed-width cell (`alignment`) shrinks by default.
    static let minimumScale: CGFloat = 0.7

    /// `Money.format`, or its whole units when `wholeUnits` ("£41,760", "-£123").
    static func format(_ minorUnits: Int, currency: Currency, wholeUnits: Bool) -> String {
        guard wholeUnits else { return Money.format(minorUnits, currency: currency) }
        // `Money.format` always ends in the two-digit fraction: drop it from the truncated figure.
        return String(Money.format(minorUnits - minorUnits % 100, currency: currency).dropLast(3))
    }

    var body: some View {
        let shown = role.displayed(minorUnits)
        let colorSource = colorOverride ?? shown
        let color = tint ?? (role == .neutral ? theme.neutralMoney : theme.money(colorSource))
        // Never wraps: an amount reads as one figure. In a fixed-width cell (`alignment`) it
        // shrinks a little rather than wrap or truncate; at its natural size it keeps its full
        // width, so neighbouring text truncates instead.
        let formatted = Self.format(shown, currency: currency, wholeUnits: wholeUnits)
        let text = Text(formatted)
            .font(font)
            .foregroundStyle(color)
            .contentTransition(.numericText())
            .lineLimit(1)
        if let alignment {
            text
                .minimumScaleFactor(minimumScale)
                .wrapProbe("MoneyText", text: formatted, minimumScale: minimumScale)
                .frame(maxWidth: .infinity, alignment: alignment)
        } else {
            text.fixedSize(horizontal: true, vertical: false)
                .wrapProbe("MoneyText", text: formatted)
        }
    }
}
