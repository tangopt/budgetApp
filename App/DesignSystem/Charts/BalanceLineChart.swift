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
    /// An estimated past value (drawn lighter and finely dashed, over a fainter area): a
    /// loan's history before its first statement.
    var isEstimated = false
    var id: Date { date }
}

/// A labelled point on a balance chart (the loan's final instalment).
struct BalanceMarker: Identifiable, Equatable {
    let date: Date
    let minorUnits: Int
    let label: String
    var id: Date { date }
}

/// A balance over time (spec §4.1; the Dashboard's net worth line): the area at 0.12 under a
/// 2 pt line in `theme.series(series)`, forecast points dashed, estimated past points lighter
/// and finely dashed over a fainter area; a dashed "Today" rule; hover for a readout. With `showsAxes` off it's the Accounts sparkline. `includesZero` off fits
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
    /// The dates the chart shows, when not the points' own extent (a window around today; the
    /// caller keeps the points inside it).
    var xDomain: ClosedRange<Date>? = nil
    /// Points labelled on the chart.
    var markers: [BalanceMarker] = []
    var height: CGFloat = 200
    /// Taller than `height` when its container offers more (a panel stretched to its row).
    var growsVertically = false
    @Environment(\.theme) private var theme
    @State private var selectedDate: Date?

    private static let utc = TimeZone(identifier: "UTC")!

    private var actual: [BalancePoint] { points.filter { !$0.isForecast && !$0.isEstimated } }

    /// The estimate runs on to the first actual point.
    private var estimated: [BalancePoint] {
        let past = points.filter(\.isEstimated)
        guard !past.isEmpty else { return [] }
        return past + (actual.first.map { [$0] } ?? [])
    }

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

    /// Over about four years, the axis counts years ("2030") rather than months ("Mar 26").
    private var spansYears: Bool {
        if let xDomain { return xDomain.upperBound.timeIntervalSince(xDomain.lowerBound) > 4 * 365 * 86_400 }
        guard let first = points.first?.date, let last = points.last?.date else { return false }
        return last.timeIntervalSince(first) > 4 * 365 * 86_400
    }

    var body: some View {
        let color = theme.series(series)
        let domain = domain
        let spansYears = spansYears
        Chart {
            ForEach(estimated) { point in
                AreaMark(x: .value("Date", point.date), yStart: .value(title, domain.lowerBound),
                         yEnd: .value(title, Double(point.minorUnits) / 100), series: .value("Series", "Estimated area"))
                    .foregroundStyle(color.opacity(0.06))
                LineMark(x: .value("Date", point.date), y: .value(title, Double(point.minorUnits) / 100), series: .value("Series", "Estimated"))
                    .foregroundStyle(color.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
            }
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
            ForEach(markers) { marker in
                PointMark(x: .value("Date", marker.date), y: .value(title, Double(marker.minorUnits) / 100))
                    .foregroundStyle(color)
                    .symbolSize(30)
                    .annotation(position: .bottom, alignment: .trailing, spacing: 2,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text(marker.label).font(.caption2).foregroundStyle(.secondary).figureText()
                    }
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
                            Text(DocumentFormat.day(selected.date) + (selected.isEstimated ? " · estimated" : ""))
                                .font(.caption2).foregroundStyle(.secondary).figureText()
                            MoneyText(minorUnits: selected.minorUnits, currency: currency, font: .caption.bold().monospacedDigit(), role: .neutral)
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.windowFill))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    }
            }
        }
        // Charts lay their labels out apart from the scroll view: no clip check on them.
        .wrapProbeInChart()
        .chartYScale(domain: domain)
        // Room after the last point for the last month's label.
        .modifier(XScale(domain: xDomain, endPadding: showsAxes ? 18 : 0))
        .chartXAxis {
            if showsAxes {
                if spansYears {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: Date.FormatStyle(timeZone: Self.utc).year(), collisionResolution: .greedy)
                    }
                } else {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: Date.FormatStyle(timeZone: Self.utc).month(.abbreviated).year(.twoDigits), collisionResolution: .greedy)
                    }
                }
            }
        }
        .chartYAxis {
            if showsAxes {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) { Text(MoneyAxis.compact(amount, currency: currency)).figureText() }
                    }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        // The points are UTC days: label them in UTC, so a month end never takes the next
        // month's label.
        .environment(\.calendar, MonthRange.calendar)
        .environment(\.timeZone, Self.utc)
        .frame(minHeight: height, idealHeight: height, maxHeight: growsVertically ? .infinity : height)
        .accessibilityLabel(title)
    }
}

/// The date scale: the points' extent, or the given window.
private struct XScale: ViewModifier {
    let domain: ClosedRange<Date>?
    let endPadding: CGFloat

    func body(content: Content) -> some View {
        if let domain {
            content.chartXScale(domain: domain, range: .plotDimension(endPadding: endPadding))
        } else {
            content.chartXScale(range: .plotDimension(endPadding: endPadding))
        }
    }
}
