// App/DesignSystem/Charts/WaterfallChart.swift
import SwiftUI
import Charts
import BudgetCore

/// One bar of a waterfall: a starting or total level, or a change from the previous level.
/// Steps are told apart by their place in the chart, so two may share a name.
struct WaterfallStep: Equatable {
    enum Kind: Equatable {
        /// A level drawn from zero: the start.
        case start
        /// A change (signed) from the running level.
        case change
        /// The running level drawn from zero: a subtotal or the end.
        case total
    }

    /// The bar's name under the axis (short: "Higher 40%").
    let label: String
    let kind: Kind
    /// The level (`start`), or the change (`change`); ignored for `total`.
    var minorUnits: Int = 0
    /// A longer description for the hover readout and VoiceOver ("Higher rate 40% on £12,000.00").
    var detail: String? = nil
    /// Whether the bar's figure is shown without its sign: a level below zero that is an
    /// amount in its own right (a repayment: "£998", not "-£998").
    var showsMagnitude = false
}

/// How a figure builds up (spec §4.1; the Self Assessment liability: tax by band, less the
/// reliefs and the tax already paid, to the balancing payment): levels from zero in the
/// chart accent (`theme.chartAccent`), changes floating from the running level with dashed connectors between them,
/// increases and decreases in the money colours, each bar labelled with its whole-unit figure;
/// hover for the exact amount and the running total. A legend names the three colours.
struct WaterfallChart: View {
    let steps: [WaterfallStep]
    let currency: Currency
    /// Whether a rise is bad news (tax owed): rises then take the expense colour, falls the income one.
    var risesAreCosts = false
    var riseLabel = "Increase"
    var fallLabel = "Decrease"
    var totalLabel = "Total"
    var height: CGFloat = 240
    /// What VoiceOver calls the chart: the panel's title ("How the tax builds up").
    var accessibilityTitle = "Waterfall"
    @Environment(\.theme) private var theme
    @State private var selectedX: Double?

    struct Bar: Identifiable, Equatable {
        /// The step's place in the chart: its identity.
        let index: Int
        let step: WaterfallStep
        /// The bar's ends, in minor units.
        let low: Int
        let high: Int
        /// The figure shown on it: the level (start, total) or the change.
        let value: Int
        /// The running level after the bar.
        let level: Int
        let isRise: Bool
        var id: Int { index }
        var isLevel: Bool { step.kind != .change }
        /// The figure as shown: without its sign for a step that shows its magnitude.
        var shownValue: Int { step.showsMagnitude ? abs(value) : value }
    }

    /// The bars with their ends: a level from zero, a change from the running level.
    static func bars(_ steps: [WaterfallStep]) -> [Bar] {
        var level = 0
        return steps.enumerated().map { index, step in
            switch step.kind {
            case .start, .total:
                if step.kind == .start { level = step.minorUnits }
                return Bar(index: index, step: step, low: min(0, level), high: max(0, level), value: level, level: level, isRise: level >= 0)
            case .change:
                let from = level
                level += step.minorUnits
                return Bar(index: index, step: step, low: min(from, level), high: max(from, level), value: step.minorUnits, level: level,
                           isRise: step.minorUnits >= 0)
            }
        }
    }

    private var bars: [Bar] { Self.bars(steps) }

    private func color(_ bar: Bar) -> Color {
        if bar.isLevel { return theme.chartAccent }
        return bar.isRise == !risesAreCosts ? theme.income : theme.expense
    }

    /// The scale with room above the tallest bar (and below the lowest) for the figures.
    private var domain: ClosedRange<Double> {
        let lows = bars.map(\.low), highs = bars.map(\.high)
        let top = Double(max(0, highs.max() ?? 0)) / 100, bottom = Double(min(0, lows.min() ?? 0)) / 100
        let span = max(top - bottom, 1)
        return (bottom < 0 ? bottom - span * 0.14 : 0)...(top + span * 0.14)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                // Each bar's slot, for its two-line axis label (the y labels take ~56 pt).
                chart(slot: max(40, (proxy.size.width - 56) / CGFloat(max(1, bars.count))))
            }
            .frame(height: height)
            legend
        }
    }

    /// Half a bar's width, in steps (the x axis counts steps: bar `i` is centred on `i`).
    private static let halfBar = 0.28

    /// The step under the pointer, from the chart's x position.
    private var selectedIndex: Int? {
        guard let selectedX, !bars.isEmpty else { return nil }
        return min(max(Int(selectedX.rounded()), 0), bars.count - 1)
    }

    private func chart(slot: CGFloat) -> some View {
        let bars = bars
        let selected = selectedIndex
        return Chart {
            // Dashed connectors from each bar's end to the next bar's edge, at the level between them.
            ForEach(Array(bars.indices.dropLast()), id: \.self) { index in
                RuleMark(xStart: .value("From", Double(index) + Self.halfBar), xEnd: .value("To", Double(index + 1) - Self.halfBar),
                         y: .value("Level", Double(bars[index].level) / 100))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(Color.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1))
            ForEach(bars) { bar in
                RectangleMark(xStart: .value("Start", Double(bar.index) - Self.halfBar), xEnd: .value("End", Double(bar.index) + Self.halfBar),
                              yStart: .value("From", Double(bar.low) / 100), yEnd: .value("To", Double(bar.high) / 100))
                    .cornerRadius(3)
                    .foregroundStyle(color(bar))
                    .opacity(selected == nil || selected == bar.index ? 1 : 0.45)
                    .annotation(position: bar.isLevel && bar.value < 0 ? .bottom : .top, spacing: 3) {
                        Text(label(bar))
                            .font(.caption2.monospacedDigit().weight(bar.isLevel ? .semibold : .regular))
                            .foregroundStyle(bar.isLevel ? Color.primary : Color.secondary)
                            .fixedSize()
                    }
            }
            if let selected {
                RuleMark(x: .value("Step", Double(selected)))
                    .foregroundStyle(Color.clear)
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        readout(bars[selected])
                    }
            }
        }
        .chartXScale(domain: -0.5...(Double(bars.count) - 0.5))
        .chartYScale(domain: domain)
        .chartXAxis {
            // Marks at each slot's left edge, labels centred in the slot (under the bar).
            AxisMarks(values: bars.indices.map { Double($0) - 0.5 }) { value in
                AxisValueLabel(centered: true, collisionResolution: .disabled) {
                    if let x = value.as(Double.self), bars.indices.contains(Int((x + 0.5).rounded())) {
                        Text(bars[Int((x + 0.5).rounded())].step.label)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(width: slot - 6)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = value.as(Double.self) { Text(MoneyAxis.compact(amount, currency: currency)) }
                }
            }
        }
        .chartXSelection(value: $selectedX)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(bars.map { "\($0.step.label) \(Money.format($0.shownValue, currency: currency))" }.joined(separator: ", "))
    }

    /// The figure on a bar in whole units: a change signed, a level as it is.
    private func label(_ bar: Bar) -> String {
        let text = MoneyAxis.whole(minorUnits: bar.shownValue, currency: currency)
        return !bar.isLevel && bar.value > 0 ? "+" + text : text
    }

    private func readout(_ bar: Bar) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(bar.step.label).font(.caption2.weight(.semibold))
            if let detail = bar.step.detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Circle().fill(color(bar)).frame(width: 6, height: 6)
                Text((!bar.isLevel && bar.value > 0 ? "+" : "") + Money.format(bar.shownValue, currency: currency))
                    .font(.caption2.monospacedDigit())
            }
            if !bar.isLevel {
                Text("Running total \(Money.format(bar.level, currency: currency))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .fixedSize()
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.windowFill))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
    }

    private var legend: some View {
        HStack(spacing: 14) {
            swatch(risesAreCosts ? theme.expense : theme.income, riseLabel)
            swatch(risesAreCosts ? theme.income : theme.expense, fallLabel)
            swatch(theme.chartAccent, totalLabel)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func swatch(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(title).lineLimit(1)
        }
        .fixedSize()
    }
}

extension MoneyAxis {
    /// Whole units, rounded, grouped: "£7,049", "-£308".
    static func whole(minorUnits: Int, currency: Currency) -> String {
        let units = (abs(minorUnits) + 50) / 100
        let text = Money.format(units * 100, currency: currency).dropLast(3)
        return (minorUnits < 0 && units > 0 ? "-" : "") + text
    }
}
