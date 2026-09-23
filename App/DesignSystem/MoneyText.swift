// App/DesignSystem/MoneyText.swift
import SwiftUI
import BudgetCore

/// Renders a minor-units amount via `Money.format`, colored green for positive and red
/// for negative using semantic colors (adapts automatically to light/dark mode). This is
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
    /// (Net Worth, Import, Forecast, lists with a `Spacer`) rely on.
    var alignment: Alignment? = nil

    var body: some View {
        let colorSource = colorOverride ?? minorUnits
        let text = Text(Money.format(minorUnits, currency: currency))
            .font(font)
            .foregroundStyle(colorSource < 0 ? Color.red : (colorSource > 0 ? Color.green : Color.primary))
            .contentTransition(.numericText())
        if let alignment {
            text.frame(maxWidth: .infinity, alignment: alignment)
        } else {
            text
        }
    }
}
