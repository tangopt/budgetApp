import SwiftUI
import Charts
import BudgetCore

/// Home's charts on the iPad: the same figures as the cards, drawn larger, with a value readout that follows the pointer
/// (hover with a trackpad or mouse) or a finger (touch and drag). The readout line keeps its height, so the card never
/// jumps as the readout appears.
struct NetWorthInteractiveChart: View {
    let netWorth: NetWorthSeries
    @Environment(\.phoneTheme) private var theme
    @State private var selected: Date?

    struct Point: Identifiable {
        let series: String
        let date: Date
        let value: Int
        var id: String { "\(series)-\(date.timeIntervalSince1970)" }
    }

    var points: [Point] {
        func date(_ point: NetWorthPoint) -> Date {
            MonthRange.calendar.date(from: DateComponents(year: point.year, month: point.month, day: 1))!
        }
        let actual = netWorth.actual.suffix(NetWorthCard.historyMonths).map { Point(series: "Actual", date: date($0), value: $0.valueMinorUnits) }
        let lastYear = netWorth.yearEnds.first?.year ?? Int.max
        let forecast = netWorth.forecast.filter { $0.year <= lastYear }.map { Point(series: "Forecast", date: date($0), value: $0.valueMinorUnits) }
        return actual + forecast
    }

    /// The point nearest `date`.
    static func nearest(_ date: Date, in points: [Point]) -> Point? {
        points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    private static let month = Date.FormatStyle(timeZone: MonthRange.calendar.timeZone).month(.abbreviated).year()

    var body: some View {
        let points = points
        let picked = selected.flatMap { Self.nearest($0, in: points) }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let picked {
                    Text(picked.date.formatted(Self.month)).mangoFont(.subheadline).foregroundStyle(.secondary)
                    MoneyText(minorUnits: picked.value, currency: .gbp, role: .balance, font: .headline)
                    if picked.series == "Forecast" { Text("forecast").mangoFont(.footnote).foregroundStyle(.secondary) }
                } else {
                    Text("Hover or touch a point for its value").mangoFont(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 28)
            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("Month", point.date), y: .value("Net worth", Double(point.value) / 100),
                             series: .value("Series", point.series))
                        .foregroundStyle(theme.accent)
                        .lineStyle(point.series == "Forecast" ? StrokeStyle(lineWidth: 2.5, dash: [5, 4]) : StrokeStyle(lineWidth: 2.5))
                        .interpolationMethod(.monotone)
                }
                if let picked {
                    RuleMark(x: .value("Month", picked.date)).foregroundStyle(Color.secondary.opacity(0.5))
                    PointMark(x: .value("Month", picked.date), y: .value("Net worth", Double(picked.value) / 100))
                        .foregroundStyle(theme.accent)
                }
            }
            .chartXSelection(value: $selected)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis {
                AxisMarks(position: .trailing) { _ in AxisGridLine(); AxisValueLabel().font(.caption2) }
            }
            .frame(height: 200)
            .accessibilityLabel("Net worth over the last year, with the forecast dashed")
            .accessibilityValue(HomeCopy.sparklineValue(netWorth))
        }
    }
}

/// This pay month as bars: spent, still expected and planned, with the same readout.
struct PayMonthInteractiveChart: View {
    let summary: HomeSummary
    @Environment(\.phoneTheme) private var theme
    @State private var selected: String?

    private var bars: [(name: String, value: Int)] {
        [("Spent", summary.month.expenses.actual), ("Still expected", summary.leftToSpendMinorUnits),
         ("Planned", summary.plannedSpendingMinorUnits)]
    }

    var body: some View {
        let picked = selected.flatMap { name in bars.first { $0.name == name } }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let picked {
                    Text(picked.name).mangoFont(.subheadline).foregroundStyle(.secondary)
                    MoneyText(minorUnits: picked.value, currency: .gbp, role: .neutral, font: .headline)
                } else {
                    Text("Hover or touch a bar for its value").mangoFont(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 28)
            Chart(bars, id: \.name) { bar in
                BarMark(x: .value("Part", bar.name), y: .value("Amount", Double(bar.value) / 100))
                    .foregroundStyle(bar.name == "Spent" ? theme.expense : (bar.name == "Planned" ? Color.secondary.opacity(0.5) : theme.expense.opacity(0.4)))
                    .opacity(picked == nil || picked?.name == bar.name ? 1 : 0.5)
            }
            .chartXSelection(value: $selected)
            .chartYAxis { AxisMarks(position: .trailing) { _ in AxisGridLine(); AxisValueLabel().font(.caption2) } }
            .frame(height: 160)
            .accessibilityLabel("Spent, still expected and planned spending this pay month")
            .accessibilityValue(HomeCopy.payMonthBarValue(summary))
        }
    }
}
