import SwiftUI
import Charts
import BudgetCore

/// Twelve months of income and expenses side by side (each a solid "actual" part plus a
/// hatched "still expected" part) with the net as a line. Solid = actual, hatched = forecast.
struct YearAtAGlanceChart: View {
    let flows: [MonthlyFlow]
    var height: CGFloat = 220

    @State private var selectedMonth: String?
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var selected: MonthlyFlow? {
        guard let selectedMonth else { return nil }
        return flows.first { name($0) == selectedMonth }
    }

    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private func name(_ flow: MonthlyFlow) -> String { Self.monthNames[flow.month - 1] }
    private func pounds(_ minorUnits: Int) -> Double { Double(minorUnits) / 100 }

    var body: some View {
        Chart {
            ForEach(flows) { flow in
                BarMark(x: .value("Month", name(flow)), y: .value("Income", pounds(flow.incomeActual)))
                    .position(by: .value("Type", "Income"))
                    .foregroundStyle(theme.income)
                if flow.incomeRemaining > 0 {
                    BarMark(x: .value("Month", name(flow)), y: .value("Income", pounds(flow.incomeRemaining)))
                        .position(by: .value("Type", "Income"))
                        .foregroundStyle(HatchPattern.style(theme.income, colorScheme: colorScheme))
                }
                BarMark(x: .value("Month", name(flow)), y: .value("Expenses", pounds(flow.expenseActual)))
                    .position(by: .value("Type", "Expenses"))
                    .foregroundStyle(theme.series(1))
                let otherRemaining = flow.expenseRemaining - flow.reservedRemaining
                if otherRemaining > 0 {
                    BarMark(x: .value("Month", name(flow)), y: .value("Expenses", pounds(otherRemaining)))
                        .position(by: .value("Type", "Expenses"))
                        .foregroundStyle(HatchPattern.style(theme.series(1), colorScheme: colorScheme))
                }
                if flow.reservedRemaining > 0 {
                    BarMark(x: .value("Month", name(flow)), y: .value("Expenses", pounds(flow.reservedRemaining)))
                        .position(by: .value("Type", "Expenses"))
                        .foregroundStyle(HatchPattern.style(theme.reserved, colorScheme: colorScheme))
                }
            }
            ForEach(flows) { flow in
                LineMark(x: .value("Month", name(flow)), y: .value("Net", pounds(flow.net)), series: .value("Series", "Net"))
                    .foregroundStyle(theme.series(0))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                PointMark(x: .value("Month", name(flow)), y: .value("Net", pounds(flow.net)))
                    .foregroundStyle(theme.series(0))
                    .symbolSize(flow.monthClass == .forecast ? 24 : 40)
            }
            if let selected {
                RuleMark(x: .value("Month", name(selected)))
                    .foregroundStyle(Color.secondary.opacity(0.3))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        detail(selected)
                    }
            }
        }
        // Charts lay their labels out apart from the scroll view: no clip check on them.
        .wrapProbeInChart()
        .chartXSelection(value: $selectedMonth)
        // Room above the plot for the bar labels / hover read-out, so they stay inside the chart, clear of the tile header.
        .chartPlotStyle { $0.padding(.top, 16) }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let pounds = value.as(Double.self) { Text(DashboardFormat.axisThousands(pounds)).figureText() }
                }
            }
        }
        .frame(height: height)
        .accessibilityLabel("Monthly income, expenses (with reserves) and net for the selected year, actual and forecast")
    }

    /// Hover card: each figure's actual part and what's still expected, so a forecast or
    /// current month shows both halves of its bars.
    private func detail(_ flow: MonthlyFlow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name(flow)).font(.caption2).foregroundStyle(.secondary).figureText()
            line("Income", total: flow.incomeTotal, actual: flow.incomeActual, remaining: flow.incomeRemaining)
            line("Expenses", total: flow.expenseTotal, actual: flow.expenseActual, remaining: flow.expenseRemaining)
            if flow.reservedRemaining > 0 {
                Text("of which reserved \(DashboardFormat.pounds(flow.reservedRemaining))").font(.caption2).foregroundStyle(.secondary).figureText()
            }
            Text("Net \(DashboardFormat.pounds(flow.net))").font(.caption.bold()).figureText()
        }
        .fixedSize()
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.windowFill))
    }

    @ViewBuilder
    private func line(_ title: String, total: Int, actual: Int, remaining: Int) -> some View {
        Text("\(title) \(DashboardFormat.pounds(total))").font(.caption).figureText()
        if remaining > 0 && actual > 0 {
            Text("actual \(DashboardFormat.pounds(actual)) · expected \(DashboardFormat.pounds(remaining))").font(.caption2).foregroundStyle(.secondary).figureText()
        } else if remaining > 0 {
            Text("expected").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
