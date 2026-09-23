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

    var body: some View {
        let colorSource = colorOverride ?? minorUnits
        Text(Money.format(minorUnits, currency: currency))
            .font(font)
            .foregroundStyle(colorSource < 0 ? Color.red : (colorSource > 0 ? Color.green : Color.primary))
            .contentTransition(.numericText())
    }
}
