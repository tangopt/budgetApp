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

    var body: some View {
        Text(Money.format(minorUnits, currency: currency))
            .font(font)
            .foregroundStyle(minorUnits < 0 ? Color.red : (minorUnits > 0 ? Color.green : Color.primary))
            .contentTransition(.numericText())
    }
}
