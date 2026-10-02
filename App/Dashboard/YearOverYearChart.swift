import SwiftUI
import Charts
import BudgetCore

/// Net worth change per year: solid = realised, hatched = forecast, negative below the axis.
struct YearOverYearChart: View {
    let changes: [YearChange]

    @State private var selectedYear: String?

    private var selected: YearChange? {
        guard let selectedYear else { return nil }
        return changes.first { label($0) == selectedYear }
    }

    private func label(_ change: YearChange) -> String {
        change.partialFromMonth != nil ? "\(change.year)*" : String(change.year)
    }
    private func pounds(_ minorUnits: Int) -> Double { Double(minorUnits) / 100 }
    private func color(_ change: YearChange) -> Color { change.totalMinorUnits < 0 ? .red : .green }

    var body: some View {
        Chart {
            ForEach(changes) { change in
                if change.realisedMinorUnits != 0 || change.forecastMinorUnits == 0 {
                    BarMark(x: .value("Year", label(change)), y: .value("Realised", pounds(change.realisedMinorUnits)))
                        .foregroundStyle(color(change))
                        .annotation(position: change.totalMinorUnits < 0 ? .bottom : .top) {
                            if change.forecastMinorUnits == 0 { totalLabel(change) }
                        }
                }
                if change.forecastMinorUnits != 0 {
                    BarMark(x: .value("Year", label(change)), y: .value("Forecast", pounds(change.forecastMinorUnits)))
                        .foregroundStyle(HatchPattern.style(color(change)))
                        .annotation(position: change.totalMinorUnits < 0 ? .bottom : .top) { totalLabel(change) }
                }
            }
            if let selected {
                RuleMark(x: .value("Year", label(selected)))
                    .foregroundStyle(Color.secondary.opacity(0.3))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 0) {
                            Text(label(selected)).font(.caption2).foregroundStyle(.secondary)
                            Text(DashboardFormat.pounds(selected.totalMinorUnits)).font(.caption.bold())
                            Text(DashboardFormat.percent(selected.percent)).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
                    }
            }
        }
        .chartXSelection(value: $selectedYear)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let pounds = value.as(Double.self) { Text(DashboardFormat.axisThousands(pounds)) }
                }
            }
        }
        .frame(height: 200)
        .accessibilityLabel("Net worth change per year")
    }

    private func totalLabel(_ change: YearChange) -> some View {
        Text(DashboardFormat.compactPounds(change.totalMinorUnits))
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}
