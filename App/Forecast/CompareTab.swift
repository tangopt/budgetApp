// App/Forecast/CompareTab.swift
import SwiftUI
import Charts
import BudgetCore

/// Net worth lines for the Budget and each compared scenario, then the summary table.
struct CompareTab: View {
    @ObservedObject var viewModel: ScenarioLabViewModel

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text("Net worth").font(.headline)
                    if viewModel.isComputingComparison {
                        ProgressView().controlSize(.small)
                        Text("Updating…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if viewModel.isComputingComparison && viewModel.actualLine.isEmpty && viewModel.lines.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                } else if viewModel.actualLine.isEmpty && viewModel.lines.allSatisfy({ $0.forecast.isEmpty }) {
                    Text("No net worth data yet: add accounts and balances on the Accounts screen.")
                        .foregroundStyle(.secondary)
                } else {
                    ScenarioNetWorthChart(actual: viewModel.actualLine, lines: viewModel.lines, today: viewModel.today)
                }
                Text("Summary").font(.headline)
                SummaryTable(rows: viewModel.summaries, horizon: viewModel.horizon.endMonth(today: viewModel.today))
            }
            .padding(.bottom)
        }
    }
}

/// One line per plan, coloured by `PlanPalette`; the shared actual months in grey. Hovering
/// shows every line's value for that month.
struct ScenarioNetWorthChart: View {
    let actual: [NetWorthPoint]
    let lines: [ScenarioLabViewModel.PlanLine]
    let today: Date

    @State private var selectedDate: Date?

    private struct Plotted: Identifiable {
        let id: String
        let series: String
        let date: Date
        let pounds: Double
    }

    /// Series are keyed by `PlanLine.id` (names can repeat a reserved word or each other's
    /// spelling); names are only labels, in the legend and the hover read-out.
    private static let actualId = "actual"
    private static let actualName = "Actual"

    private func plot(_ points: [NetWorthPoint], series: String) -> [Plotted] {
        points.map { Plotted(id: "\(series)-\($0.id)", series: series, date: MonthRange.of(year: $0.year, month: $0.month).start, pounds: Double($0.valueMinorUnits) / 100) }
    }

    /// The hovered month's value on each line (actual months show the actual value).
    private var readout: (date: Date, values: [(name: String, colorIndex: Int?, minorUnits: Int)])? {
        guard let selectedDate else { return nil }
        let (year, month) = MonthRange.components(of: selectedDate)
        let index = MonthRange.index(year: year, month: month)
        var values: [(name: String, colorIndex: Int?, minorUnits: Int)] = []
        if let point = actual.first(where: { $0.id == index }) {
            values.append((Self.actualName, nil, point.valueMinorUnits))
        }
        for line in lines {
            if let point = line.forecast.first(where: { $0.id == index }) {
                values.append((line.name, line.colorIndex, point.valueMinorUnits))
            }
        }
        guard !values.isEmpty else { return nil }
        return (MonthRange.of(year: year, month: month).start, values)
    }

    var body: some View {
        let ids = [Self.actualId] + lines.map(\.id)
        let colors = [Color.gray] + lines.map { PlanPalette.color($0.colorIndex) }
        let readout = readout
        VStack(alignment: .leading, spacing: 8) {
        Chart {
            ForEach(plot(actual, series: Self.actualId)) { point in
                LineMark(x: .value("Month", point.date), y: .value("Net worth", point.pounds), series: .value("Plan", point.series))
                    .foregroundStyle(by: .value("Plan", point.series))
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(lines) { line in
                ForEach(plot(line.forecast, series: line.id)) { point in
                    LineMark(x: .value("Month", point.date), y: .value("Net worth", point.pounds), series: .value("Plan", point.series))
                        .foregroundStyle(by: .value("Plan", point.series))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: line.colorIndex == 0 ? [] : [6, 3]))
                }
            }
            RuleMark(x: .value("Today", today))
                .foregroundStyle(Color.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .annotation(position: .top, alignment: .leading, spacing: 2) {
                    Text("Today").font(.caption2).foregroundStyle(.secondary)
                }
            if let readout {
                RuleMark(x: .value("Selected", readout.date))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(DashboardFormat.monthYear(readout.date)).font(.caption2).foregroundStyle(.secondary)
                            ForEach(Array(readout.values.enumerated()), id: \.offset) { _, value in
                                HStack(spacing: 4) {
                                    Circle().fill(value.colorIndex.map(PlanPalette.color) ?? .gray).frame(width: 6, height: 6)
                                    Text(value.name).font(.caption2)
                                    Spacer(minLength: 8)
                                    Text(DashboardFormat.pounds(value.minorUnits)).font(.caption.bold()).monospacedDigit()
                                }
                            }
                        }
                        .padding(6)
                        .frame(minWidth: 160)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    }
            }
        }
        .chartForegroundStyleScale(domain: ids, range: colors)
        .chartLegend(.hidden)
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
        .frame(height: 300)
        .accessibilityLabel("Net worth by month: actual, then the forecast of the budget and each compared scenario")
            legend
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(Self.actualName, color: .gray)
            ForEach(lines) { line in legendItem(line.name, color: PlanPalette.color(line.colorIndex)) }
        }
        .font(.caption)
    }

    private func legendItem(_ name: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name).lineLimit(1)
        }
    }
}

/// Rows = plans; per year: year-end net worth, the difference vs the Budget, income,
/// expenses and the reserves' unspent part (`ScenarioComparison.yearSummaries`).
struct SummaryTable: View {
    let rows: [ScenarioLabViewModel.SummaryRow]
    /// The horizon's last month: its year's column group is labelled "to <month>".
    let horizon: (year: Int, month: Int)

    private static let columns = ["Net worth", "Δ vs Budget", "Income", "Expenses", "Reserves (unspent)"]
    private static let columnWidth: CGFloat = 112

    private var years: [Int] { rows.first?.years.map(\.year) ?? [] }

    private func yearLabel(_ year: Int) -> String {
        guard year == horizon.year, horizon.month != 12 else { return "\(year) (year end)" }
        return "\(year) (to \(PayMonthFormat.monthName(PayMonth(year: year, month: horizon.month))))"
    }

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .trailing, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    Text("").frame(width: 160)
                    ForEach(years, id: \.self) { year in
                        Text(yearLabel(year))
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.08))
                            .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .leading)
                            .gridCellColumns(Self.columns.count)
                    }
                }
                GridRow {
                    Text("Plan").font(.caption.bold()).frame(width: 160, alignment: .leading)
                    ForEach(years, id: \.self) { year in
                        ForEach(Array(Self.columns.enumerated()), id: \.offset) { index, column in
                            Text(column)
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(width: Self.columnWidth, alignment: .trailing)
                                .padding(.vertical, 4)
                                .overlay(index == 0 ? Rectangle().frame(width: 1).foregroundStyle(.separator) : nil, alignment: .leading)
                        }
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(rows) { row in
                    GridRow {
                        Text(row.name).fontWeight(row.isBudget ? .semibold : .regular)
                            .lineLimit(1)
                            .frame(width: 160, alignment: .leading)
                        ForEach(row.years, id: \.year) { summary in
                            amount(summary.yearEndNetWorth, leadingRule: true)
                            if row.isBudget {
                                Text("—").foregroundStyle(.secondary).frame(width: Self.columnWidth, alignment: .trailing)
                            } else {
                                amount(summary.differenceVsBudget, signed: true)
                            }
                            amount(summary.income)
                            amount(-summary.expenses)
                            amount(summary.reserves == 0 ? nil : -summary.reserves)
                        }
                    }
                    .padding(.vertical, 4)
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
            }
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private func amount(_ minorUnits: Int?, signed: Bool = false, leadingRule: Bool = false) -> some View {
        Group {
            if let minorUnits {
                if signed && minorUnits > 0 {
                    Text("+" + Money.format(minorUnits, currency: .gbp)).font(.body.monospacedDigit()).foregroundStyle(.green)
                } else {
                    MoneyText(minorUnits: minorUnits)
                }
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.columnWidth, alignment: .trailing)
        .overlay(leadingRule ? Rectangle().frame(width: 1).foregroundStyle(.separator) : nil, alignment: .leading)
    }
}
