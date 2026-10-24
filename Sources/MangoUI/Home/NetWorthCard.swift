import SwiftUI
import Charts
import BudgetCore

/// Net worth (iPhone spec §3.2): the figure and its change since last month, a sparkline of the last year with the
/// confirmed forecast dashed to the end of the year, and the year-end forecast. Every value is the dashboard's
/// (`DashboardCalculator.netWorthSeries`).
struct NetWorthCard: View {
    let netWorth: NetWorthSeries
    @Environment(\.phoneTheme) private var theme

    /// Months of history the sparkline shows.
    static let historyMonths = 12

    var body: some View {
        Card(title: "Net worth") {
            if let current = netWorth.currentNetWorthMinorUnits {
                MoneyText(minorUnits: current, currency: .gbp, role: .balance, fit: .shrink())
                    .font(.largeTitle.weight(.semibold))
                if let change = netWorth.changeVsPreviousMonthMinorUnits {
                    FigureRow(label: "Since last month") {
                        MoneyText(minorUnits: change, currency: .gbp, role: .income)
                    }
                }
                sparkline
                if let yearEnd = netWorth.yearEnds.first {
                    FigureRow(label: "Forecast for the end of \(String(yearEnd.year))") {
                        MoneyText(minorUnits: yearEnd.valueMinorUnits, currency: .gbp, role: .balance)
                    }
                }
            } else {
                Text("No balances yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private struct Point: Identifiable {
        let series: String
        let date: Date
        let value: Double
        var id: String { "\(series)-\(date.timeIntervalSince1970)" }
    }

    /// The last `historyMonths` of actuals, then the forecast through the first year-end it gives.
    private var points: [Point] {
        func date(_ point: NetWorthPoint) -> Date {
            MonthRange.calendar.date(from: DateComponents(year: point.year, month: point.month, day: 1))!
        }
        let actual = netWorth.actual.suffix(Self.historyMonths).map {
            Point(series: "Actual", date: date($0), value: Double($0.valueMinorUnits) / 100)
        }
        let lastYear = netWorth.yearEnds.first?.year ?? Int.max
        let forecast = netWorth.forecast.filter { $0.year <= lastYear }.map {
            Point(series: "Forecast", date: date($0), value: Double($0.valueMinorUnits) / 100)
        }
        return actual + forecast
    }

    @ViewBuilder
    private var sparkline: some View {
        let points = points
        if points.count > 1 {
            Chart(points) { point in
                LineMark(x: .value("Month", point.date), y: .value("Net worth", point.value),
                         series: .value("Series", point.series))
                    .foregroundStyle(theme.accent)
                    .lineStyle(point.series == "Forecast"
                               ? StrokeStyle(lineWidth: 2, dash: [4, 3]) : StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 64)
            .accessibilityLabel("Net worth over the last year, with the forecast dashed")
            .accessibilityValue(HomeCopy.sparklineValue(netWorth))
        }
    }
}
