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
    /// The hatched forecast part takes the sign of the year's total...
    private func color(_ change: YearChange) -> Color { change.totalMinorUnits < 0 ? .red : .green }
    /// ...while the solid realised part takes its own sign (they can differ: a small loss so
    /// far that the forecast turns into a gain, or the reverse).
    private func realisedColor(_ change: YearChange) -> Color { change.realisedMinorUnits < 0 ? .red : .green }

    var body: some View {
        Chart {
            ForEach(changes) { change in
                if change.realisedMinorUnits != 0 || change.forecastMinorUnits == 0 {
                    BarMark(x: .value("Year", label(change)), y: .value("Realised", pounds(change.realisedMinorUnits)))
                        .foregroundStyle(realisedColor(change))
                        .annotation(position: change.totalMinorUnits < 0 ? .bottom : .top) {
                            if change.forecastMinorUnits == 0 { totalLabel(change) }
                        }
                }
                if change.forecastMinorUnits != 0 {
                    // A floating segment from where the realised part ends to the year's total,
                    // so opposite-sign parts (realised -£887, forecast +£15.6k) end at the
                    // total instead of stacking away from it.
                    BarMark(
                        x: .value("Year", label(change)),
                        yStart: .value("From", pounds(change.realisedMinorUnits)),
                        yEnd: .value("To", pounds(change.totalMinorUnits))
                    )
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
