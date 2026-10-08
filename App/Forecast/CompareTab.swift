// App/Forecast/CompareTab.swift
import SwiftUI
import Charts
import BudgetCore

/// The Compare chips (Budget always on, scenarios toggled), then net worth lines for the
/// Budget and each ticked scenario and the summary table.
struct CompareTab: View {
    @ObservedObject var viewModel: ScenarioLabViewModel
    @Binding var chipPrompts: ScenarioChipPrompts

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScenarioChips(viewModel: viewModel, mode: .multi(selected: $viewModel.compareSelection), prompts: $chipPrompts)
            content
        }
    }

    private var content: some View {
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
                ScrollView(.horizontal) {
                    SummaryTable(rows: viewModel.summaries, horizon: viewModel.horizon.endMonth(today: viewModel.today))
                }
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
            }
        }
        .chartForegroundStyleScale(domain: ids, range: colors)
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            // The read-out sits just inside the plot's top edge, following the hovered month but
            // clamped to the plot's width; below the "Today" label at the rule's top, so they never meet.
            GeometryReader { geometry in
                if let readout, let frame = proxy.plotFrame.map({ geometry[$0] }), let x = proxy.position(forX: readout.date) {
                    let width: CGFloat = 190
                    let left = max(frame.minX, min(max(frame.minX + x - width / 2, frame.minX), frame.maxX - width))
                    readoutBox(readout)
                        .frame(width: width)
                        .offset(x: left, y: frame.minY + 18)
                        .allowsHitTesting(false)
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
        .frame(height: 300)
        .accessibilityLabel("Net worth by month: actual, then the forecast of the budget and each compared scenario")
            legend
        }
    }

    private func readoutBox(_ readout: (date: Date, values: [(name: String, colorIndex: Int?, minorUnits: Int)])) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(DashboardFormat.monthYear(readout.date)).font(.caption2).foregroundStyle(.secondary)
            ForEach(Array(readout.values.enumerated()), id: \.offset) { _, value in
                HStack(spacing: 4) {
                    Circle().fill(value.colorIndex.map(PlanPalette.color) ?? .gray).frame(width: 6, height: 6)
                    Text(value.name).font(.caption2).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(DashboardFormat.pounds(value.minorUnits)).font(.caption.bold()).monospacedDigit()
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
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

/// One block per year; rows = plans: year-end net worth, the difference vs the Budget,
/// income, expenses and the reserves' unspent part (`ScenarioComparison.yearSummaries`).
struct SummaryTable: View {
    let rows: [ScenarioLabViewModel.SummaryRow]
    /// The horizon's last month: its year's block is labelled "to <month>".
    let horizon: (year: Int, month: Int)

    private static let columns = ["Year-end net worth", "Δ vs Budget", "Income", "Expenses", "Reserves (unspent)"]

    private static let columnWidth: CGFloat = 120
    private static let planWidth: CGFloat = 170

    private var years: [Int] { rows.first?.years.map(\.year) ?? [] }

    private func yearLabel(_ year: Int) -> String {
        guard year == horizon.year, horizon.month != 12 else { return "\(year) (year end)" }
        return "\(year) (to \(PayMonthFormat.monthName(PayMonth(year: year, month: horizon.month))))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(years, id: \.self) { year in
                yearBlock(year)
            }
        }
    }

    private func yearBlock(_ year: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(yearLabel(year))
                .font(.subheadline.bold())
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08))
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 0) {
                GridRow {
                    Text("Plan").font(.caption.bold()).frame(width: Self.planWidth, alignment: .leading).gridColumnAlignment(.leading)
                    ForEach(Self.columns, id: \.self) { column in
                        Text(column).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .frame(width: Self.columnWidth, alignment: .trailing)
                    }
                }
                .padding(.vertical, 4)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(rows) { row in
                    GridRow {
                        Text(row.name).fontWeight(row.isBudget ? .semibold : .regular)
                            .lineLimit(1)
                            .frame(width: Self.planWidth, alignment: .leading)
                        if let summary = row.years.first(where: { $0.year == year }) {
                            amount(summary.yearEndNetWorth)
                            if row.isBudget {
                                amount(nil)
                            } else {
                                amount(summary.differenceVsBudget, signed: true)
                            }
                            amount(summary.income)
                            amount(-summary.expenses)
                            amount(summary.reserves == 0 ? nil : -summary.reserves)
                        } else {
                            ForEach(0..<Self.columns.count, id: \.self) { _ in amount(nil) }
                        }
                    }
                    .padding(.vertical, 4)
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    @ViewBuilder
    private func amount(_ minorUnits: Int?, signed: Bool = false) -> some View {
        Group {
            amountContent(minorUnits, signed: signed)
        }
        .frame(width: Self.columnWidth, alignment: .trailing)
    }

    @ViewBuilder
    private func amountContent(_ minorUnits: Int?, signed: Bool) -> some View {
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
}
