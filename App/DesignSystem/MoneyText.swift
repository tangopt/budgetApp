// App/DesignSystem/MoneyText.swift
import SwiftUI
import BudgetCore

/// Renders a minor-units amount via `Money.format`, colored by sign in the theme's income
/// (positive) and expense (negative) colours, which adapt to light/dark mode. This is
/// the one place money color/formatting logic lives — every other view should use this
/// instead of formatting `Money.format` output directly.
struct MoneyText: View {
    let minorUnits: Int
    var currency: Currency = .gbp
    var font: Font = .system(.body, design: .default).monospacedDigit()
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
    @Environment(\.theme) private var theme

    var body: some View {
        let colorSource = colorOverride ?? minorUnits
        let color = tint ?? theme.money(colorSource)
        // Never wraps: an amount reads as one figure. In a fixed-width cell (`alignment`) it
        // shrinks a little rather than wrap or truncate; at its natural size it keeps its full
        // width, so neighbouring text truncates instead.
        let text = Text(Money.format(minorUnits, currency: currency))
            .font(font)
            .foregroundStyle(color)
            .contentTransition(.numericText())
            .lineLimit(1)
        if let alignment {
            text
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: alignment)
        } else {
            text.fixedSize(horizontal: true, vertical: false)
        }
    }
}
