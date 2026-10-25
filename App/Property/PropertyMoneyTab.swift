// App/Property/PropertyMoneyTab.swift
import SwiftUI
import Charts
import BudgetCore
import struct BudgetCore.Transaction

/// The Money tab (spec 2026-10-16 §1, UI polish §4.2): the period's headline figures; every
/// figure as a table in groups (Rent, Income, Costs, Mortgage, Cash flow, Balances) in the
/// property's currency and GBP, each that has transactions with a chevron that lists them;
/// beside it, costs by category (a chevron each) and the mortgage's interest and capital by
/// month; then cash flow by month and, folded away, the monthly figures as a table.
struct PropertyMoneyTab: View {
    @ObservedObject var viewModel: PropertyViewModel
    let openTransaction: (Transaction) -> Void

    @State private var showsMonthlyTable = false
    @FocusState private var isFocused: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
            if let summary = viewModel.snapshot.summary {
                Panel("Summary · \(summary.period.label)", subtitle: rateNote(summary)) {
                    FigureStrip(headline(summary))
                }
                // Side by side only where costs by category gets the width its bars and figures need.
                SplitRow(ratio: 0.57, stackBelow: 1000) {
                    Panel("Figures", subtitle: "Select a figure to list its transactions", fillsHeight: true) {
                        DataTable(columns: figureColumns(summary.currency), sections: figureSections(summary), zebra: false,
                                  onSelect: { figure in
                                      if let kind = figure.drillDown { select(id: figure.id, figure.title, kind) }
                                  },
                                  selectedId: viewModel.openFigureId)
                    }
                    VStack(spacing: ScreenMetrics.spacing) {
                        costsPanel(summary)
                        mortgagePanel(summary)
                    }
                }
                Panel("Cash flow by month", subtitle: "Rent received above the line, costs below, net cash flow as the line; click a month for its transactions") {
                    PropertyMonthlyChart(summary: summary, height: 220, viewModel: viewModel)
                }
                monthlyPanel(summary)
            } else if viewModel.period == nil {
                InlineBanner(.info, "Pick a range that ends after it starts.")
            }
        }
        // Up and Down move the selection through the figures, then the cost categories.
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSelection(-1) }
        .onKeyPress(.downArrow) { moveSelection(1) }
    }

    private static let categoryPrefix = "category."

    /// Opens a figure's transactions in the side panel, or closes the panel when it's the open one.
    private func select(id: String, _ title: String, _ kind: PropertyDrillDown) {
        isFocused = true
        viewModel.toggleSidePanel(.figure(id: id, title: title, drillDown: kind))
    }

    /// The rows that open, in the order they are drawn: the figures, then the cost categories.
    private func openableRows(_ summary: PropertySummary) -> [(id: String, title: String, kind: PropertyDrillDown)] {
        let figures = figureSections(summary).flatMap { section in section.rows + (section.total.map { [$0] } ?? []) }
            .compactMap { figure in figure.drillDown.map { (id: figure.id, title: figure.title, kind: $0) } }
        let categories = summary.costsByCategory.map {
            (id: Self.categoryPrefix + String($0.categoryId), title: $0.name, kind: PropertyDrillDown.costs(categoryId: $0.categoryId))
        }
        return figures + categories
    }

    private func moveSelection(_ steps: Int) -> KeyPress.Result {
        guard let summary = viewModel.snapshot.summary else { return .ignored }
        let rows = openableRows(summary)
        guard let id = PropertyMoneySelection.step(ids: rows.map(\.id), from: viewModel.openFigureId, by: steps),
              let row = rows.first(where: { $0.id == id }) else { return .ignored }
        viewModel.sidePanel = .figure(id: row.id, title: row.title, drillDown: row.kind)
        return .handled
    }

    private func rateNote(_ summary: PropertySummary) -> String? {
        summary.currency == .gbp ? nil : "GBP at \(String(format: "%.4f", summary.eurToGbpRate)) per euro (the rate in Settings)"
    }

    // MARK: Headline

    private func headline(_ summary: PropertySummary) -> [FigureTile] {
        let t = summary.totals, currency = summary.currency
        func gbp(_ amount: PropertyAmount) -> Int? { currency == .gbp ? nil : amount.gbp }
        return [
            FigureTile(title: "Income", value: .money(t.income.native, currency, .signed), gbp: gbp(t.income)),
            FigureTile(title: "Costs", value: .money(t.costs.native, currency, .cost), gbp: gbp(t.costs)),
            FigureTile(title: "Capital repaid", value: .money(t.mortgageCapital.native, currency, .cost), gbp: gbp(t.mortgageCapital)),
            FigureTile(title: "Net cash flow", value: .money(t.netCashFlow.native, currency, .signed), gbp: gbp(t.netCashFlow)),
            FigureTile(title: "Gross yield", value: .text(PropertyFormat.yield(summary.grossYield)),
                       caption: summary.purchasePrice == nil ? "Set a price in Profile" : "Rent on receipts, annualised"),
            FigureTile(title: "Net yield", value: .text(PropertyFormat.yield(summary.netYield)),
                       caption: summary.purchasePrice == nil ? nil : "Income − costs, annualised")
        ]
    }

    // MARK: Figures

    /// A row of the figures table.
    private struct Figure: Identifiable {
        let id: String
        let title: String
        /// What it is, in the row's tooltip.
        var detail: String?
        let amount: PropertyAmount
        let role: MoneyRole
        var drillDown: PropertyDrillDown?
    }

    private func figureColumns(_ currency: Currency) -> [DataTableColumn<Figure>] {
        var columns: [DataTableColumn<Figure>] = [
            DataTableColumn("", width: .fill(min: 180), accessibilityValue: { $0.title }) { figure, kind in
                Text(figure.title)
                    .fontWeight(kind == .total ? .semibold : .regular)
                    .lineLimit(1)
                    .help(figure.detail ?? figure.title)
            },
            .money(currency.rawValue.uppercased(), role: { $0.role }, currency: { _ in currency }) { $0.amount.native }
        ]
        if currency != .gbp {
            columns.append(.money("GBP", role: { $0.role }, currency: { _ in .gbp }) { $0.amount.gbp })
        }
        return columns
    }

    private func figureSections(_ summary: PropertySummary) -> [DataTableSection<Figure>] {
        let t = summary.totals
        return [
            DataTableSection("Rent", rows: [
                Figure(id: "perReceipts", title: "Rent per receipts", detail: "The receipts' rent, spread over their rent periods",
                       amount: t.rentPerReceipts, role: .neutral),
                Figure(id: "credits", title: "Rent credits", detail: "Credits in the rent categories on the current account",
                       amount: t.rentCredits, role: .signed, drillDown: .rentCredits),
                Figure(id: "recharges", title: "Recharges and other", detail: "The part of those credits that isn't rent",
                       amount: t.recharges, role: .signed, drillDown: .rentCredits),
                Figure(id: "received", title: "Rent received", detail: "Rent credits − recharges and other",
                       amount: t.rentReceived, role: .signed, drillDown: .rentCredits)
            ]),
            DataTableSection("Income", rows: [
                Figure(id: "income", title: "Income", detail: "Every transaction in the property's income categories",
                       amount: t.income, role: .signed, drillDown: .income)
            ]),
            DataTableSection("Costs", rows: [
                Figure(id: "costs", title: "Costs",
                       detail: "Every transaction in the property's expense categories, mortgage interest included",
                       amount: t.costs, role: .cost, drillDown: .costs(categoryId: nil)),
                Figure(id: "utilities", title: "Utilities paid", detail: "Costs in the utility categories (electricity, gas, water)",
                       amount: t.utilities, role: .cost),
                Figure(id: "utilityRecharges", title: "Utilities recharged",
                       detail: "Recharge statements paid by the tenant: the statement-linked parts of credits",
                       amount: t.utilityRecharges, role: .signed),
                Figure(id: "netUtilities", title: "Net utilities",
                       detail: "Utilities paid − recharged, never below zero: what they cost the landlord", amount: t.netUtilities, role: .cost)
            ]),
            DataTableSection("Mortgage", rows: [
                Figure(id: "interest", title: "Mortgage interest", detail: "Interest, fees and taxes charged on the mortgage accounts",
                       amount: t.mortgageInterest, role: .cost, drillDown: .mortgageInterest),
                Figure(id: "capital", title: "Mortgage capital repaid", detail: "Instalments less interest",
                       amount: t.mortgageCapital, role: .cost, drillDown: .mortgage),
                Figure(id: "outside", title: "Interest outside the property's categories",
                       detail: "Mortgage interest filed under a category that isn't one of the property's",
                       amount: t.interestOutsideCosts, role: .cost, drillDown: .mortgageInterestOutsideCosts)
            ]),
            DataTableSection("Cash flow", rows: [], total: Figure(id: "net", title: "Net cash flow",
                                                                  detail: "Income − costs − capital repaid (and any interest filed elsewhere)",
                                                                  amount: t.netCashFlow, role: .signed)),
            DataTableSection("Balances at the end", rows: [
                Figure(id: "loan", title: "Outstanding loan", amount: summary.outstandingLoan, role: .neutral),
                Figure(id: "deposit", title: "Deposit held", amount: summary.depositHeld, role: .neutral)
            ])
        ]
    }

    // MARK: Costs by category

    private func costsPanel(_ summary: PropertySummary) -> some View {
        // Categories whose refunds cancel their costs stay (a row without a bar), so their
        // transactions can still be opened.
        let categories = summary.costsByCategory
        return Panel("Costs by category", subtitle: categories.isEmpty ? nil
                     : "\(categories.count) categor\(categories.count == 1 ? "y" : "ies") · \(Money.format(summary.totals.costs.native, currency: summary.currency))") {
            if categories.isEmpty {
                Text("No costs in this period: link the property's category groups in Profile.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Every row is a cost: magnitudes, neutral (spec §1.4).
                BreakdownBars(items: categories.map { BreakdownItem($0.name, minorUnits: $0.amount.native, id: Self.categoryPrefix + String($0.categoryId)) },
                              currency: summary.currency, maxItems: max(categories.count, 1), keepsNonPositive: true,
                              selectedId: viewModel.openFigureId,
                              selectTitle: { "Transactions: \($0.label)" }) { item in
                    if let category = categories.first(where: { Self.categoryPrefix + String($0.categoryId) == item.id }) {
                        select(id: item.id, category.name, .costs(categoryId: category.categoryId))
                    }
                }
            }
        }
    }

    // MARK: Mortgage

    private func mortgagePanel(_ summary: PropertySummary) -> some View {
        let t = summary.totals, currency = summary.currency
        let paid = t.mortgageInterest.native + t.mortgageCapital.native
        return Panel("Mortgage", subtitle: paid > 0 ? "\(Money.format(paid, currency: currency)) paid: interest and capital by month" : nil,
                     fillsHeight: true) {
            if paid > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 18) {
                        MortgagePart(title: "Interest", minorUnits: t.mortgageInterest.native, of: paid, currency: currency, color: theme.expense)
                        MortgagePart(title: "Capital repaid", minorUnits: t.mortgageCapital.native, of: paid, currency: currency,
                                     color: theme.transfer)
                        Spacer(minLength: 0)
                    }
                    MortgageMonthsChart(months: summary.months, currency: currency)
                }
            } else {
                Text("No mortgage payments in this period: link the mortgage account in Profile.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Monthly figures

    /// A month (or the period's total) as a table row.
    private struct MonthLine: Identifiable {
        let id: String
        let title: String
        let figures: PropertyFigures
    }

    private func monthColumn(_ title: String, _ role: MoneyRole, _ currency: Currency,
                             _ value: @escaping (PropertyFigures) -> PropertyAmount) -> DataTableColumn<MonthLine> {
        .money(title, role: role, currency: { _ in currency }) { value($0.figures).native }
    }

    private func monthlyPanel(_ summary: PropertySummary) -> some View {
        let format = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.abbreviated).year()
        let currency = summary.currency
        return Panel("Monthly figures", subtitle: "Month by month, in \(currency.rawValue.uppercased())") {
            Button { withAnimation(.snappy) { showsMonthlyTable.toggle() } } label: {
                Label(showsMonthlyTable ? "Hide table" : "Show table", systemImage: showsMonthlyTable ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        } content: {
            if showsMonthlyTable {
                DataTable(columns: [
                    .text("Month", width: .fill(min: 90), figure: true, { $0.title }),
                    monthColumn("Rent per receipts", .neutral, currency) { $0.rentPerReceipts },
                    monthColumn("Rent received", .signed, currency) { $0.rentReceived },
                    monthColumn("Recharges", .signed, currency) { $0.recharges },
                    monthColumn("Costs", .cost, currency) { $0.costs },
                    monthColumn("Interest", .cost, currency) { $0.mortgageInterest },
                    monthColumn("Capital", .cost, currency) { $0.mortgageCapital },
                    monthColumn("Net cash flow", .signed, currency) { $0.netCashFlow }
                ], rows: summary.months.map { MonthLine(id: "\($0.start.timeIntervalSince1970)", title: $0.start.formatted(format), figures: $0.figures) },
                   total: MonthLine(id: "total", title: "Total", figures: summary.totals))
            }
        }
    }
}

/// A part of the mortgage payments: its colour (the chart's), name, amount and share.
private struct MortgagePart: View {
    let title: String
    let minorUnits: Int
    let of: Int
    let currency: Currency
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(title)
            MoneyText(minorUnits: minorUnits, currency: currency, role: .neutral)
            Text(of > 0 ? "\(Int((Double(minorUnits) / Double(of) * 100).rounded()))%" : "")
                .monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
        .figureText()
        .accessibilityElement(children: .combine)
    }
}

/// The mortgage's interest and capital repaid by month, stacked: interest in the expense
/// colour (a cost), capital in the transfer colour (it moves money into the loan).
private struct MortgageMonthsChart: View {
    let months: [PropertyMonthFigures]
    let currency: Currency
    @Environment(\.theme) private var theme

    private static let utc = TimeZone(identifier: "UTC")!

    var body: some View {
        Chart {
            ForEach(months, id: \.start) { month in
                BarMark(x: .value("Month", month.start, unit: .month), y: .value("Amount", Double(month.figures.mortgageInterest.native) / 100))
                    .foregroundStyle(by: .value("Part", "Interest"))
                BarMark(x: .value("Month", month.start, unit: .month), y: .value("Amount", Double(month.figures.mortgageCapital.native) / 100))
                    .foregroundStyle(by: .value("Part", "Capital repaid"))
            }
        }
        // Charts lay their labels out apart from the scroll view: no clip check on them.
        .wrapProbeInChart()
        .chartForegroundStyleScale(["Interest": theme.expense, "Capital repaid": theme.transfer])
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: Date.FormatStyle(timeZone: Self.utc).month(.abbreviated), centered: true)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = value.as(Double.self) { Text(MoneyAxis.compact(amount, currency: currency)).figureText() }
                }
            }
        }
        .environment(\.calendar, MonthRange.calendar)
        .environment(\.timeZone, Self.utc)
        // Takes some of what the panel has beside the figures, not all of it.
        .frame(minHeight: 120, idealHeight: 150, maxHeight: 200)
        .accessibilityLabel("Mortgage interest and capital repaid by month")
    }
}
