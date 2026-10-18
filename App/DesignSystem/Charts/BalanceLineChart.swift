// App/DesignSystem/Charts/BalanceLineChart.swift
import SwiftUI
import Charts
import BudgetCore

/// One point of a balance over time.
struct BalancePoint: Identifiable, Equatable {
    let date: Date
    let minorUnits: Int
    /// A projected value (drawn dashed, without the area).
    var isForecast = false
    var id: Date { date }
}

/// A balance over time (spec §4.1; the Dashboard's net worth line): the area at 0.12 under a
/// 2 pt line in `theme.series(series)`, forecast points dashed; a dashed "Today" rule; hover
/// for a readout. With `showsAxes` off it's the Accounts sparkline. `includesZero` off fits
/// the scale to the values (a loan that moves a few percent a year), the area filling down
/// to the bottom of the plot.
struct BalanceLineChart: View {
    let points: [BalancePoint]
    let currency: Currency
    var title = "Balance"
    var series = 0
    var showsAxes = true
    var includesZero = true
    var today: Date? = nil
    var height: CGFloat = 200
    @Environment(\.theme) private var theme
    @State private var selectedDate: Date?

    private static let utc = TimeZone(identifier: "UTC")!

    private var actual: [BalancePoint] { points.filter { !$0.isForecast } }

    /// The forecast continues from the last actual point.
    private var forecast: [BalancePoint] {
        let projected = points.filter(\.isForecast)
        guard !projected.isEmpty else { return [] }
        return (actual.last.map { [$0] } ?? []) + projected
    }

    private var selected: BalancePoint? {
        guard let selectedDate else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    /// The value scale: from zero, or around the values with a margin of a tenth of their
    /// range on each side.
    private var domain: ClosedRange<Double> {
        let values = points.map { Double($0.minorUnits) / 100 }
        let low = values.min() ?? 0, high = values.max() ?? 0
        if includesZero { return Swift.min(0, low)...Swift.max(0, high) }
        let margin = Swift.max((high - low) / 10, Swift.max(abs(high), 1) / 100)
        return (low - margin)...(high + margin)
    }

    var body: some View {
        let color = theme.series(series)
        let domain = domain
        Chart {
            ForEach(actual) { point in
                AreaMark(x: .value("Date", point.date), yStart: .value(title, domain.lowerBound),
                         yEnd: .value(title, Double(point.minorUnits) / 100), series: .value("Series", "Area"))
                    .foregroundStyle(color.opacity(0.12))
                LineMark(x: .value("Date", point.date), y: .value(title, Double(point.minorUnits) / 100), series: .value("Series", "Actual"))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(forecast) { point in
                LineMark(x: .value("Date", point.date), y: .value(title, Double(point.minorUnits) / 100), series: .value("Series", "Forecast"))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
            if let today, showsAxes {
                RuleMark(x: .value("Today", today))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("Today").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            if let selected {
                RuleMark(x: .value("Selected", selected.date))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(DocumentFormat.day(selected.date)).font(.caption2).foregroundStyle(.secondary)
                            MoneyText(minorUnits: selected.minorUnits, currency: currency, font: .caption.bold().monospacedDigit(), role: .neutral)
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.windowFill))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    }
            }
        }
        .chartYScale(domain: domain)
        // Room after the last point for the last month's label.
        .chartXScale(range: .plotDimension(endPadding: showsAxes ? 18 : 0))
        .chartXAxis {
            if showsAxes {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: Date.FormatStyle(timeZone: Self.utc).month(.abbreviated).year(.twoDigits))
                }
            }
        }
        .chartYAxis {
            if showsAxes {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) { Text(MoneyAxis.compact(amount, currency: currency)) }
                    }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        // The points are UTC days: label them in UTC, so a month end never takes the next
        // month's label.
        .environment(\.calendar, MonthRange.calendar)
        .environment(\.timeZone, Self.utc)
        .frame(height: height)
        .accessibilityLabel(title)
    }
}
