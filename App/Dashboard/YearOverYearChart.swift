import SwiftUI
import Charts
import BudgetCore

/// Net worth change per year: solid = realised, hatched = forecast, negative below the axis.
struct YearOverYearChart: View {
    let changes: [YearChange]

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
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let pounds = value.as(Double.self) { Text("£\(Int(pounds / 1000))k") }
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
