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
        VStack(alignment: .leading, spacing: 0) {
            ScenarioChips(viewModel: viewModel, mode: .multi(selected: $viewModel.compareSelection), prompts: $chipPrompts)
            combinedControls
            content
        }
    }

    /// The Combined toggle, the save button and the note when a fifth tick was refused.
    private var combinedControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Toggle("Combined", isOn: $viewModel.showCombined)
                    .disabled(!viewModel.canCombine)
                    .help(viewModel.canCombine ? "Draw the ticked scenarios applied together" : "Tick at least two scenarios")
                Button("Save combination as a scenario…") {
                    chipPrompts.nameSheet = .saveCombination(defaultName: viewModel.combinationName)
                }
                .disabled(!(viewModel.showCombined && viewModel.canCombine))
                .help("Keep the combined line as a scenario of its own")
                if let note = viewModel.tickLimitNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.bottom, 12)
    }

    /// What two ticked scenarios both change (while Combined is on). Inside the scroll view: a
    /// notice wraps to its full height, which outside it would count towards the window's minimum
    /// height (measured at the narrowest width, a few words a line) and push the page off screen.
    @ViewBuilder
    private var overlapNotices: some View {
        if viewModel.showCombined && !viewModel.overlapNotices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(viewModel.overlapNotices.enumerated()), id: \.offset) { _, notice in
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var content: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                overlapNotices
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
                // At least the full width (its columns flex to fill it); scrolls sideways
                // only when the window is narrower than the columns' minimum widths.
                ScrollView(.horizontal) {
                    SummaryTable(rows: viewModel.summaries, horizon: viewModel.horizon.endMonth(today: viewModel.today))
                        .containerRelativeFrame(.horizontal, alignment: .leading) { length, _ in
                            max(length, SummaryTable.minimumWidth(rows: viewModel.summaries))
                        }
                        .wrapProbeScrollsHorizontally()
                }
            }
            .padding(.bottom)
        }
    }
}

/// One line per plan, coloured by the theme's chart series (`Theme.series`); the shared actual months in grey. Hovering
/// shows every line's value for that month.
struct ScenarioNetWorthChart: View {
    let actual: [NetWorthPoint]
    let lines: [ScenarioLabViewModel.PlanLine]
    let today: Date

    @State private var selectedDate: Date?
    @Environment(\.theme) private var theme

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
        let colors = [Color.gray] + lines.map { theme.series($0.colorIndex) }
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
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: line.colorIndex == 0 ? [] : line.id == "combined" ? [2, 3] : [6, 3]))
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
        // Charts lay their labels out apart from the scroll view: no clip check on them.
        .wrapProbeInChart()
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
                    if let pounds = value.as(Double.self) { Text(DashboardFormat.axisThousands(pounds)).figureText() }
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
            Text(DashboardFormat.monthYear(readout.date)).font(.caption2).foregroundStyle(.secondary).figureText()
            ForEach(Array(readout.values.enumerated()), id: \.offset) { _, value in
                HStack(spacing: 4) {
                    Circle().fill(value.colorIndex.map(theme.series) ?? .gray).frame(width: 6, height: 6)
                    Text(value.name).font(.caption2).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(DashboardFormat.pounds(value.minorUnits)).font(.caption.bold()).monospacedDigit()
                        .figureText()
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.windowFill))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(Self.actualName, color: .gray)
            ForEach(lines) { line in legendItem(line.name, color: theme.series(line.colorIndex)) }
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
    @Environment(\.theme) private var theme

    private static let columns = ["Avg monthly surplus", "Year-end net worth", "Δ vs Budget", "Income", "Expenses", "Reserves (unspent)"]

    /// The columns' minimum widths; they share out any extra width.
    private static let columnWidth: CGFloat = 120
    private static let planWidth: CGFloat = 170
    private static let columnSpacing: CGFloat = 12
    private static let horizontalPadding: CGFloat = 8

    /// The Δ column's minimum when the Combined row lists each scenario's own difference
    /// under "Together" (a name beside each figure).
    private static let contributionsWidth: CGFloat = 200

    /// The narrowest the table lays out at (every column at its minimum).
    static func minimumWidth(rows: [ScenarioLabViewModel.SummaryRow]) -> CGFloat {
        let extra = rows.contains { !$0.contributions.isEmpty } ? contributionsWidth - columnWidth : 0
        return planWidth + CGFloat(columns.count) * (columnWidth + columnSpacing) + 2 * horizontalPadding + extra
    }

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
                .figureText()
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.sectionHeaderTint)
            Grid(alignment: .trailing, horizontalSpacing: Self.columnSpacing, verticalSpacing: 0) {
                GridRow {
                    Text("Plan").font(.caption.bold()).frame(minWidth: Self.planWidth, maxWidth: .infinity, alignment: .leading).gridColumnAlignment(.leading)
                    ForEach(Self.columns, id: \.self) { column in
                        Text(column).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .frame(minWidth: Self.columnWidth, maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.vertical, 4)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(rows) { row in
                    GridRow {
                        Text(row.name).fontWeight(row.isBudget ? .semibold : .regular)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(minWidth: Self.planWidth, maxWidth: .infinity, alignment: .leading)
                        if let summary = row.years.first(where: { $0.year == year }) {
                            amount(row.averageMonthlySurplus[year])
                            amount(summary.yearEndNetWorth)
                            if row.isBudget {
                                amount(nil)
                            } else {
                                differenceCell(summary.differenceVsBudget, contributions: row.contributions[year] ?? [])
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
            .padding(.horizontal, Self.horizontalPadding)
        }
    }

    /// Δ vs Budget; the Combined row lists each scenario's own difference under "Together".
    @ViewBuilder
    private func differenceCell(_ difference: Int?, contributions: [ScenarioLabViewModel.Contribution]) -> some View {
        if contributions.isEmpty {
            amount(difference, signed: true)
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Together").font(.caption).foregroundStyle(.secondary).fixedSize()
                    amountContent(difference, signed: true)
                }
                ForEach(Array(contributions.enumerated()), id: \.offset) { _, contribution in
                    HStack(spacing: 4) {
                        Text(contribution.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        amountContent(contribution.difference, signed: true).font(.caption)
                    }
                }
            }
            .frame(minWidth: Self.contributionsWidth, maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func amount(_ minorUnits: Int?, signed: Bool = false) -> some View {
        Group {
            amountContent(minorUnits, signed: signed)
        }
        .frame(minWidth: Self.columnWidth, maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private func amountContent(_ minorUnits: Int?, signed: Bool) -> some View {
        if let minorUnits {
            if signed && minorUnits > 0 {
                Text("+" + Money.format(minorUnits, currency: .gbp)).font(.body.monospacedDigit()).foregroundStyle(theme.income)
                    .figureText()
            } else {
                MoneyText(minorUnits: minorUnits)
            }
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }
}
