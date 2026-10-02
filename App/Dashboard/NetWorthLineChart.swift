import SwiftUI
import Charts
import BudgetCore

/// Net worth by month: solid actual line (light area beneath), dashed forecast line, a
/// "Today" rule, dots on the forecast year-ends, and a hover read-out.
struct NetWorthLineChart: View {
    let actual: [NetWorthPoint]
    let forecast: [NetWorthPoint]
    let today: Date

    @State private var selectedDate: Date?

    private struct Plotted: Identifiable {
        let id: Int
        let date: Date
        let month: Int
        let pounds: Double
    }

    private func plot(_ points: [NetWorthPoint]) -> [Plotted] {
        points.map { Plotted(id: $0.id, date: MonthRange.of(year: $0.year, month: $0.month).start, month: $0.month, pounds: Double($0.valueMinorUnits) / 100) }
    }

    private var selected: Plotted? {
        guard let selectedDate else { return nil }
        return (plot(actual) + plot(forecast)).min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        let actualPlotted = plot(actual)
        let forecastPlotted = plot(forecast)
        Chart {
            ForEach(actualPlotted) { point in
                AreaMark(x: .value("Month", point.date), y: .value("Net worth", point.pounds), series: .value("Series", "Actual area"))
                    .foregroundStyle(Color.blue.opacity(0.12))
                LineMark(x: .value("Month", point.date), y: .value("Net worth", point.pounds), series: .value("Series", "Actual"))
                    .foregroundStyle(Color.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(forecastPlotted) { point in
                LineMark(x: .value("Month", point.date), y: .value("Net worth", point.pounds), series: .value("Series", "Forecast"))
                    .foregroundStyle(Color.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
            ForEach(forecastPlotted.filter { $0.month == 12 }) { point in
                PointMark(x: .value("Month", point.date), y: .value("Net worth", point.pounds))
                    .foregroundStyle(Color.blue)
                    .symbolSize(40)
            }
            RuleMark(x: .value("Today", today))
                .foregroundStyle(Color.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .annotation(position: .top, alignment: .leading, spacing: 2) {
                    Text("Today").font(.caption2).foregroundStyle(.secondary)
                }
            if let selected {
                RuleMark(x: .value("Selected", selected.date))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 0) {
                            Text(DashboardFormat.monthYear(selected.date)).font(.caption2).foregroundStyle(.secondary)
                            Text(DashboardFormat.pounds(Int(selected.pounds * 100))).font(.caption.bold())
                        }
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
                    }
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartXAxis {
            AxisMarks(values: .stride(by: .year)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.year(), centered: false)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let pounds = value.as(Double.self) { Text(DashboardFormat.axisThousands(pounds)) }
                }
            }
        }
        .frame(height: 230)
        .accessibilityLabel("Net worth by month since \(actual.first.map { String($0.year) } ?? "the start"), actual and forecast")
    }
}
