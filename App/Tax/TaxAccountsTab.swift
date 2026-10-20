// App/Tax/TaxAccountsTab.swift
import SwiftUI
import Charts
import BudgetCore
import struct BudgetCore.Transaction

/// The year's rental accounts (UI polish §4.2): what to look at as a banner; the headline
/// figures in the property's currency and GBP; every line as one table in groups (income,
/// expenses with their total, the profit, the lines reported apart) — the rule beside each, the
/// share when lines differ, pound items noted under their GBP figure, the sources a chevron
/// away; the costs the return left out ("Deductible, not claimed", for information); then the
/// expenses by line and the rent by month as charts (the months' table folded away), and the
/// HMRC rate as a caption.
struct TaxAccountsTab: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let page: TaxOverview.YearPage
    let openTransaction: (Transaction) -> Void
    @State private var drillDown: RentalAccounts.Line?
    @State private var showsRentTable = false
    @Environment(\.theme) private var theme

    var body: some View {
        if let accounts = page.accounts {
            VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
                if !accounts.warnings.isEmpty {
                    InlineBanner(.warning) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(accounts.warnings, id: \.self) { Text($0.figuresUnbroken) }
                        }
                    }
                }
                Panel("Summary", subtitle: shareNote(accounts)) {
                    // The figures of the accounts, then the two reported apart (not part of the
                    // profit) in a tinted group of their own.
                    SplitRow(ratio: 0.6, spacing: 14, stackBelow: 700) {
                        FigureStrip(headline(accounts))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Reported apart").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                            FigureStrip(reportedApart(accounts))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.sectionHeaderTint))
                    }
                }
                Panel("Lines", subtitle: linesNote(accounts)) {
                    DataTable(columns: lineColumns(accounts), sections: lineSections(accounts), zebra: false)
                }
                SplitRow(ratio: 0.5, stackBelow: 720) {
                    expensesPanel(accounts)
                    rentPanel(accounts)
                }
                Text(rateCaption(accounts)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .sheet(item: $drillDown) { line in
                TaxLineSourcesSheet(viewModel: viewModel, line: line, currency: accounts.currency, openTransaction: openTransaction)
            }
        } else {
            Panel {
                EmptyState(systemImage: "house", title: "No rental accounts",
                           message: "\(page.row.person.name) owns no property in \(page.row.year.label).")
                    .inPanel()
            }
        }
    }

    // MARK: Notes

    /// Whether every line takes the same share (then it's said once, not on each line).
    private func commonShare(_ accounts: RentalAccounts.Result) -> RentalAccounts.Line? {
        let lines = accounts.allLines
        return lines.allSatisfy { $0.share == accounts.income.share } ? accounts.income : nil
    }

    private func shareNote(_ accounts: RentalAccounts.Result) -> String {
        let property = page.property?.name ?? "the property"
        if let line = commonShare(accounts) {
            return "Share of \(property): \(line.shareExplanation)"
        }
        return "Shares of \(property) by line, as the table shows"
    }

    private func linesNote(_ accounts: RentalAccounts.Result) -> String {
        let notClaimed = accounts.notClaimedLines.isEmpty ? ""
            : " Deductible costs left off the \(accounts.taxYear.label) return are listed apart, not in the totals."
        return (accounts.currency == .gbp ? "In GBP. A chevron lists a line's sources."
            : "In \(accounts.currency.rawValue.uppercased()) and in GBP at HMRC's average rate. A chevron lists a line's sources.") + notClaimed
    }

    private func rateCaption(_ accounts: RentalAccounts.Result) -> String {
        let apart = "Finance costs get relief at the basic rate; the PT tax (calendar year \(String(accounts.taxYear.startYear))) is the foreign tax credit relief input; not-deductible items are listed for information."
        guard accounts.currency != .gbp else { return apart }
        guard let rate = accounts.rate else { return "No HMRC average rate for \(accounts.taxYear.label): set or fetch it in Settings. " + apart }
        return "GBP at HMRC's average rate: \(TaxFormat.rate(rate).unbroken), \(TaxFormat.source(of: rate)). Pound items are added as they are, never converted. " + apart
    }

    // MARK: Headline

    private func headline(_ accounts: RentalAccounts.Result) -> [FigureTile] {
        let t = accounts.totals, currency = accounts.currency
        func gbp(_ amount: RentalAccounts.Amount) -> Int? { currency == .gbp ? nil : amount.gbp }
        return [
            FigureTile(title: "Rental income", value: .money(t.income.native, currency, .signed), gbp: gbp(t.income)),
            FigureTile(title: "Expenses", value: .money(t.expenses.native, currency, .cost), gbp: gbp(t.expenses),
                       caption: t.expenses.gbpNative == 0 ? nil : "incl. \(Money.format(abs(t.expenses.gbpNative), currency: .gbp)) paid in GBP"),
            FigureTile(title: "Profit before finance costs", value: .money(t.profit.native, currency, .signed), gbp: gbp(t.profit))
        ]
    }

    /// The figures reported apart from the profit: finance costs and the foreign tax.
    private func reportedApart(_ accounts: RentalAccounts.Result) -> [FigureTile] {
        let t = accounts.totals, currency = accounts.currency
        func gbp(_ amount: RentalAccounts.Amount) -> Int? { currency == .gbp ? nil : amount.gbp }
        return [
            // Reported apart: neither gain nor loss on this page (spec §1.4).
            FigureTile(title: "Finance costs", value: .money(t.financeCosts.native, currency, .neutral), gbp: gbp(t.financeCosts),
                       caption: "Basic-rate relief"),
            FigureTile(title: "Foreign tax", value: .money(t.foreignTax.native, currency, .neutral), gbp: gbp(t.foreignTax),
                       caption: "PT \(String(accounts.taxYear.startYear)) · FTCR input")
        ]
    }

    // MARK: Lines

    /// A row of the lines table: a line, or a total.
    private struct LineRow: Identifiable {
        let id: String
        let title: String
        var line: RentalAccounts.Line?
        let amount: RentalAccounts.Amount
        let role: MoneyRole
        /// A line's sources left off the return ("Deductible, not claimed").
        var isNotClaimed = false
    }

    private func lineSections(_ accounts: RentalAccounts.Result) -> [DataTableSection<LineRow>] {
        func row(_ line: RentalAccounts.Line, _ role: MoneyRole) -> LineRow {
            LineRow(id: line.expenseType.rawValue, title: line.label, line: line, amount: line.amount, role: role)
        }
        let t = accounts.totals
        return [
            // Rent reads as income; expense lines are costs, shown negative beside it.
            DataTableSection("Income", rows: [row(accounts.income, .signed)]),
            DataTableSection("Expenses", rows: accounts.expenses.map { row($0, .cost) },
                             total: LineRow(id: "expenses", title: "Total expenses", amount: t.expenses, role: .cost)),
            DataTableSection(nil, rows: [],
                             total: LineRow(id: "profit", title: "Profit before finance costs", amount: t.profit, role: .signed)),
            // Every line apart is a cost: magnitudes, neutral (spec §1.4).
            DataTableSection("Reported apart", rows: [accounts.financeCosts, accounts.foreignTax, accounts.notDeductible].map { row($0, .neutral) })
        ] + notClaimedSection(accounts)
    }

    /// The costs the return left out, by line, with their total: for information, never in the
    /// figures above.
    private func notClaimedSection(_ accounts: RentalAccounts.Result) -> [DataTableSection<LineRow>] {
        let lines = accounts.notClaimedLines
        guard !lines.isEmpty else { return [] }
        let rows = lines.map { line in
            LineRow(id: "notClaimed-" + line.expenseType.rawValue, title: line.label, line: line, amount: line.notClaimed, role: .neutral,
                    isNotClaimed: true)
        }
        return [DataTableSection("Deductible, not claimed", rows: rows,
                                 total: lines.count > 1 ? LineRow(id: "notClaimed", title: "Total not claimed", amount: accounts.notClaimedTotal,
                                                                  role: .neutral) : nil)]
    }

    private func lineColumns(_ accounts: RentalAccounts.Result) -> [DataTableColumn<LineRow>] {
        let currency = accounts.currency
        var columns: [DataTableColumn<LineRow>] = [
            DataTableColumn("Line", width: .fill(min: 140), accessibilityValue: { $0.title }) { row, kind in
                Text(row.title)
                    .fontWeight(kind == .total ? .semibold : .regular)
                    .lineLimit(1)
                    .help(row.line.map { "\($0.ruleExplanation) Share: \($0.shareExplanation)." } ?? row.title)
            },
            // A label that truncates (whole on hover) so the figures keep their room.
            DataTableColumn("Rule", width: .fill(min: 90), accessibilityValue: { row in
                row.isNotClaimed ? "Left off the \(accounts.taxYear.label) return" : row.line?.rule.displayName
            }) { row, _ in
                if row.isNotClaimed {
                    Text("Left off the return").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        .help("Deductible, but not claimed on the \(accounts.taxYear.label) return: listed for information, not in the figures.")
                } else if let line = row.line {
                    Text(line.rule.displayName).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        .help(line.ruleExplanation)
                }
            }
        ]
        if commonShare(accounts) == nil {
            columns.append(DataTableColumn("Share", alignment: .trailing, width: .min(52),
                                           accessibilityValue: { $0.line.map { PropertyFormat.percent($0.share.shareBasisPoints) } }) { row, _ in
                if let line = row.line {
                    Text(PropertyFormat.percent(line.share.shareBasisPoints)).monospacedDigit().figureText()
                        .help(line.shareExplanation)
                }
            })
        }
        columns.append(.money(currency.rawValue.uppercased(), role: { $0.role }, minWidth: 104, currency: { _ in currency }) { $0.amount.native })
        if currency != .gbp {
            columns.append(gbpColumn)
        }
        columns.append(DataTableColumn("", alignment: .trailing) { row, kind in
            if kind == .row, let line = row.line {
                if row.isNotClaimed {
                    TaxSourcesButton(count: line.notClaimedSources.count, label: "\(line.label), not claimed") { drillDown = line }
                } else if !line.sources.isEmpty || !line.notClaimedSources.isEmpty {
                    TaxSourcesButton(count: line.sources.count, label: line.label) { drillDown = line }
                }
            }
        })
        return columns
    }

    /// The GBP figure, with the part already paid in pounds (not converted) noted beneath — on
    /// the lines and Total expenses, not on the profit (where it would read as part of it).
    private var gbpColumn: DataTableColumn<LineRow> {
        DataTableColumn("GBP", alignment: .trailing, width: .min(104), accessibilityValue: { row in
            guard let gbp = row.amount.gbp else { return "no GBP figure" }
            let text = Money.format(row.role.displayed(gbp), currency: .gbp)
            guard let paid = Self.paidInGBP(row) else { return text }
            return "\(text), including \(paid) paid in GBP"
        }) { row, kind in
            VStack(alignment: .trailing, spacing: 0) {
                if let gbp = row.amount.gbp {
                    MoneyText(minorUnits: gbp, currency: .gbp,
                              font: kind == .total ? .body.monospacedDigit().weight(.semibold) : .body.monospacedDigit(), role: row.role)
                } else {
                    Text("—").foregroundStyle(.secondary).help("No HMRC rate for the year")
                }
                if let paid = Self.paidInGBP(row) {
                    Text("incl. \(paid) paid in GBP")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).figureText()
                        .help("Items paid in pounds, added as they are (never converted)")
                }
            }
        }
    }

    /// "£450.00": the part of a row paid in pounds, when there is one (none on the profit).
    private static func paidInGBP(_ row: LineRow) -> String? {
        guard row.amount.gbpNative != 0, row.id != "profit" else { return nil }
        return Money.format(abs(row.amount.gbpNative), currency: .gbp)
    }

    // MARK: Expenses by line

    private func expensesPanel(_ accounts: RentalAccounts.Result) -> some View {
        // In GBP when every line has it (pound items included); else in the property's currency.
        let inGBP = accounts.currency == .gbp || accounts.expenses.allSatisfy { $0.amount.gbp != nil }
        let items = accounts.expenses.map { line in
            BreakdownItem(line.label, minorUnits: inGBP ? (line.amount.gbp ?? 0) : line.amount.native, id: line.expenseType.rawValue)
        }
        let total = items.reduce(0) { $0 + max(0, $1.value) }
        let currency: Currency = inGBP ? .gbp : accounts.currency
        return Panel("Expenses by line", subtitle: total > 0 ? "Total \(Money.format(total, currency: currency))" : nil,
                     fillsHeight: true) {
            if total <= 0 {
                Text("No deductible expenses this year.").font(.callout).foregroundStyle(.secondary)
            } else {
                // Every row is a cost: magnitudes, neutral (spec §1.4).
                BreakdownBars(items: items, currency: currency, maxItems: max(items.count, 1),
                              selectTitle: { "Sources of \($0.label)" }) { item in
                    drillDown = accounts.expenses.first { $0.expenseType.rawValue == item.id && !$0.sources.isEmpty }
                }
            }
        }
    }

    // MARK: Rent by month

    /// A month (or the year's total) as a table row.
    private struct RentRow: Identifiable {
        let id: String
        let title: String
        let whole: Int
        let amount: Int
    }

    private func rentPanel(_ accounts: RentalAccounts.Result) -> some View {
        let months = accounts.rentMonths
        let format = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.abbreviated).year()
        return Panel("Rent by month", subtitle: months.isEmpty ? nil : "By rent period, April to March", fillsHeight: true) {
            if !months.isEmpty {
                Button { withAnimation(.snappy) { showsRentTable.toggle() } } label: {
                    Label(showsRentTable ? "Hide table" : "Show table", systemImage: showsRentTable ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        } content: {
            if months.isEmpty {
                Text("No rent in this year.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    TaxRentMonthsChart(months: months, currency: accounts.currency, personName: page.row.person.name)
                    if showsRentTable {
                        DataTable(columns: [
                            .text("Month", width: .fill(min: 90), figure: true, { $0.title }),
                            .money("Property", role: .neutral, currency: { _ in accounts.currency }) { $0.whole },
                            .money(page.row.person.name, role: .signed, currency: { _ in accounts.currency }) { $0.amount }
                        ], rows: months.map { RentRow(id: "\($0.start.timeIntervalSince1970)", title: $0.start.formatted(format),
                                                      whole: $0.whole, amount: $0.amount) },
                           total: RentRow(id: "total", title: "Total", whole: months.reduce(0) { $0 + $1.whole },
                                          amount: months.reduce(0) { $0 + $1.amount }))
                    }
                }
            }
        }
    }
}

/// A line's drill-down: its number of sources and a chevron.
struct TaxSourcesButton: View {
    let count: Int
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text("\(count)").font(.callout).monospacedDigit().figureText()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .fixedSize()
        .help("\(count) source\(count == 1 ? "" : "s") of \(label)")
        .accessibilityLabel("Sources of \(label): \(count)")
    }
}

/// The rent by month: the person's share at the foot of each bar in the income colour, the
/// rest of the property's rent above it, lighter; hover for the month's figures.
struct TaxRentMonthsChart: View {
    let months: [RentalAccounts.RentMonth]
    let currency: Currency
    let personName: String
    var height: CGFloat = 200
    @Environment(\.theme) private var theme
    @State private var selectedDate: Date?

    private static let utc = TimeZone(identifier: "UTC")!

    private var othersLabel: String { "Rest of the property" }

    /// Whether the person owns all of it (then there's no rest of the property to show).
    private var ownsAll: Bool { months.allSatisfy { $0.whole == $0.amount } }

    private var selected: RentalAccounts.RentMonth? {
        guard let selectedDate else { return nil }
        return months.min { abs($0.start.timeIntervalSince(selectedDate)) < abs($1.start.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            chart
            HStack(spacing: 14) {
                legend(personName, theme.income, months.reduce(0) { $0 + $1.amount })
                if !ownsAll {
                    legend(othersLabel, theme.income.opacity(0.3), months.reduce(0) { $0 + $1.whole - $1.amount })
                }
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(months, id: \.start) { month in
                BarMark(x: .value("Month", month.start, unit: .month), y: .value("Amount", Double(month.amount) / 100))
                    .foregroundStyle(by: .value("Part", personName))
                BarMark(x: .value("Month", month.start, unit: .month), y: .value("Amount", Double(month.whole - month.amount) / 100))
                    .foregroundStyle(by: .value("Part", othersLabel))
            }
            if let selected {
                RuleMark(x: .value("Selected", selected.start, unit: .month))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        readout(selected)
                    }
            }
        }
        // Charts lay their labels out apart from the scroll view: no clip check on them.
        .wrapProbeInChart()
        .chartForegroundStyleScale([personName: theme.income, othersLabel: theme.income.opacity(0.3)])
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: Date.FormatStyle(timeZone: Self.utc).month(.abbreviated), centered: true)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = value.as(Double.self) { Text(MoneyAxis.compact(amount, currency: currency)).figureText() }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        .environment(\.calendar, MonthRange.calendar)
        .environment(\.timeZone, Self.utc)
        .frame(height: height)
        .accessibilityLabel("Rent by month: \(personName)'s share and the rest of the property's")
    }

    private func legend(_ title: String, _ color: Color, _ minorUnits: Int) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(title).foregroundStyle(.secondary)
            MoneyText(minorUnits: minorUnits, currency: currency, font: .callout.monospacedDigit(), role: .neutral)
        }
        .font(.callout)
        .figureText()
        .accessibilityElement(children: .combine)
    }

    private func readout(_ month: RentalAccounts.RentMonth) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(month.start.formatted(Date.FormatStyle(timeZone: Self.utc).month(.wide).year())).font(.caption2).foregroundStyle(.secondary)
                .figureText()
            // Each series under its own name and colour, then the whole property's rent.
            readoutLine(personName, month.amount, theme.income)
            if !ownsAll {
                readoutLine(othersLabel, month.whole - month.amount, theme.income.opacity(0.3))
                readoutLine("Whole property", month.whole, .clear)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.windowFill))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
    }

    private func readoutLine(_ label: String, _ minorUnits: Int, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption2)
            Spacer(minLength: 8)
            MoneyText(minorUnits: minorUnits, currency: currency, font: .caption.bold().monospacedDigit(), role: .neutral)
        }
        .frame(minWidth: 150)
    }
}

extension RentalAccounts.Line: @retroactive Identifiable {
    public var id: TaxExpenseType { expenseType }
}

/// A line's sources (UI polish §4.2): the line's figures — the whole property's, the share and
/// the person's — then each transaction, receipt or manual item as a table row: its day, what
/// it is with how the rule attributed it, the whole amount and the part attributed to the
/// year, the share where it differs from the line's, its documents, and Show for a
/// transaction; a total when the sources share a currency. A deductible line's sources can be
/// marked "not claimed" for the year (after a confirmation): they move to their own table
/// below, "Deductible, not claimed", with the person's figure, and can be claimed again.
struct TaxLineSourcesSheet: View {
    @ObservedObject var viewModel: TaxYearsViewModel
    let line: RentalAccounts.Line
    let currency: Currency
    let openTransaction: (Transaction) -> Void
    @Environment(\.dismiss) private var dismiss
    /// The sources' documents, read when the sheet opens and when its sources change.
    @State private var documents: [Int64: EvidenceDocument] = [:]
    /// A not-claimed mark (or its removal) waiting for its confirmation.
    @State private var pendingMark: PendingMark?
    @State private var error: String?

    /// A source as a table row (or the total).
    private struct SourceRow: Identifiable {
        let id: Int
        var source: RentalAccounts.Source?
    }

    private struct PendingMark: Identifiable {
        let source: RentalAccounts.Source
        let notClaimed: Bool
        var id: String { "\(source.reference)-\(notClaimed)" }
    }

    /// The line as the year now computes it (a mark moves sources while the sheet is open).
    private var current: RentalAccounts.Line { viewModel.accounts?.line(line.expenseType) ?? line }

    /// The person on show, whose share the line is.
    private var personName: String? { viewModel.page?.row.person.name }

    private var yearLabel: String { viewModel.accounts?.taxYear.label ?? "the year" }

    private var rows: [SourceRow] { current.sources.indices.map { SourceRow(id: $0, source: current.sources[$0]) } }

    private var notClaimedRows: [SourceRow] {
        current.notClaimedSources.indices.map { SourceRow(id: $0, source: current.notClaimedSources[$0]) }
    }

    /// The sources' one currency, when they share one (then they have a total).
    private func sharedCurrency(_ sources: [RentalAccounts.Source]) -> Currency? {
        let currencies = Set(sources.map(\.currency))
        return currencies.count == 1 ? currencies.first : nil
    }

    var body: some View {
        SheetScaffold(title: current.label, subtitle: current.ruleExplanation, error: error, width: SheetMetrics.tableWidth,
                      cancelTitle: "Done", onCancel: { dismiss() }) {
            FigureStrip(figures)
            if current.sources.isEmpty {
                SheetEmptyState(systemImage: "list.bullet.rectangle", title: "No sources",
                                message: current.notClaimedSources.isEmpty ? "Nothing feeds this line this year."
                                    : "Nothing feeds this line this year: its sources were left off the return.", minHeight: 130)
            } else {
                let sources = current.sources
                let table = DataTable(columns: columns(sources, notClaimed: false), rows: rows,
                                      total: sharedCurrency(sources) == nil ? nil : SourceRow(id: -1, source: nil))
                if sources.count > 9 {
                    ScrollView { table }.frame(height: current.notClaimedSources.isEmpty ? 380 : 280).sheetListFrame()
                } else {
                    table
                }
            }
            if !current.notClaimedSources.isEmpty {
                notClaimedTable
            }
        }
        .onAppear(perform: loadDocuments)
        // A mark moves a source between the two tables: the documents follow the references.
        .onChange(of: current.sources.map(\.reference) + current.notClaimedSources.map(\.reference)) { _, _ in loadDocuments() }
        .confirmationDialog(confirmationTitle, isPresented: Binding(get: { pendingMark != nil }, set: { if !$0 { pendingMark = nil } }),
                            titleVisibility: .visible, presenting: pendingMark) { pending in
            Button(pending.notClaimed ? "Mark not claimed" : "Claim it again") {
                error = viewModel.setNotClaimed(pending.source.reference, notClaimed: pending.notClaimed)
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.notClaimed
                 ? "It leaves \(yearLabel)'s \(current.label.lowercased()) and every figure built on it, and is listed apart as deductible, not claimed — as when the return was filed without it."
                 : "It goes back on \(yearLabel)'s \(current.label.lowercased()) and the figures built on it.")
        }
    }

    private var confirmationTitle: String {
        guard let pending = pendingMark else { return "" }
        return pending.notClaimed ? "Leave “\(pending.source.description)” off the \(yearLabel) return?"
            : "Claim “\(pending.source.description)” in \(yearLabel) again?"
    }

    private func loadDocuments() {
        let ids = Array(Set((current.sources + current.notClaimedSources).flatMap(\.documentIds)))
        documents = Dictionary(uniqueKeysWithValues: viewModel.documents(ids).compactMap { d in d.id.map { ($0, d) } })
    }

    /// The sources left off the return, with the person's figure.
    private var notClaimedTable: some View {
        let sources = current.notClaimedSources
        let gbp = currency == .gbp ? "" : current.notClaimed.gbp.map { " (\(Money.format($0, currency: .gbp)))" } ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Deductible, not claimed in \(yearLabel)").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                Text("\(personName.map { "\($0)'s share" } ?? "Share") \(Money.format(current.notClaimed.native, currency: currency))\(gbp)")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary).figureText()
            }
            Text("Left off the return: not in the line or the totals above.")
                .font(.caption).foregroundStyle(.secondary)
            DataTable(columns: columns(sources, notClaimed: true), rows: notClaimedRows,
                      total: sources.count > 1 && sharedCurrency(sources) != nil ? SourceRow(id: -1, source: nil) : nil)
        }
    }

    private var figures: [FigureTile] {
        let person = personName ?? "Share"
        let line = current
        // A line's figures read as what they are: values for a form (spec §1.4).
        var tiles = [
            FigureTile(title: "Whole property", value: .money(line.whole.native, currency, .neutral),
                       gbp: currency == .gbp ? nil : line.whole.gbp),
            FigureTile(title: "Share", value: .text(PropertyFormat.percent(line.share.shareBasisPoints)),
                       caption: shareOrigin),
            FigureTile(title: personName == nil ? "The person's share" : "\(person)'s share", value: .money(line.amount.native, currency, .neutral),
                       gbp: currency == .gbp ? nil : line.amount.gbp),
            FigureTile(title: "Sources", value: .text("\(line.sources.count)"),
                       caption: line.rule.displayName)
        ]
        if !line.notClaimedSources.isEmpty {
            tiles.append(FigureTile(title: "Not claimed", value: .money(line.notClaimed.native, currency, .neutral),
                                    gbp: currency == .gbp ? nil : line.notClaimed.gbp, caption: "\(person)'s share, left off the return"))
        }
        return tiles
    }

    private var shareOrigin: String {
        switch current.share.origin {
        case .ownership: return "Ownership, by days owned"
        case .splitForType: return "Split for this type"
        case .splitForAllTypes: return "Split for the year"
        }
    }

    private func columns(_ sources: [RentalAccounts.Source], notClaimed: Bool) -> [DataTableColumn<SourceRow>] {
        let line = current
        let sourcesCurrency = sharedCurrency(sources)
        var columns: [DataTableColumn<SourceRow>] = [
            DataTableColumn("Date", accessibilityValue: { $0.source?.date.map(DocumentFormat.day) }) { row, kind in
                if kind == .row { DateText(date: row.source?.date) }
            },
            // The total row is read as "Total" already (DataTable): nothing more here.
            DataTableColumn("Source", width: .fill(min: 240), accessibilityValue: { row in
                row.source.map { "\($0.description), \($0.explanation)" }
            }) { row, kind in
                if let source = row.source {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(source.description).lineLimit(1)
                        Text(source.explanation).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .help("\(source.description)\n\(source.explanation)")
                } else {
                    Text("Total").fontWeight(.semibold)
                }
            },
            // The parts of one line: magnitudes, not coloured (MoneyRole.neutral).
            .money("Amount", role: .neutral, currency: { $0.source?.currency ?? sourcesCurrency ?? currency }) { row in
                row.source?.amountMinorUnits ?? sources.reduce(0) { $0 + $1.amountMinorUnits }
            },
            .money("Attributed", role: .neutral, currency: { $0.source?.currency ?? sourcesCurrency ?? currency }) { row in
                row.source?.attributedMinorUnits ?? sources.reduce(0) { $0 + $1.attributedMinorUnits }
            }
        ]
        if sources.contains(where: { $0.shareBasisPoints != line.share.shareBasisPoints }) {
            columns.append(DataTableColumn("Share", alignment: .trailing, width: .min(52),
                                           accessibilityValue: { $0.source.map { PropertyFormat.percent($0.shareBasisPoints) } }) { row, _ in
                if let source = row.source {
                    Text(PropertyFormat.percent(source.shareBasisPoints)).monospacedDigit().figureText()
                        .foregroundStyle(source.shareBasisPoints == line.share.shareBasisPoints ? .secondary : .primary)
                }
            })
        }
        // Not described: the paperclip is a button (or a menu) VoiceOver has to reach.
        columns.append(DataTableColumn("", alignment: .center, width: .fixed(44)) { row, _ in
            if let source = row.source {
                SourceDocumentsButton(documents: source.documentIds.compactMap { documents[$0] }) { viewModel.open($0) }
            }
        })
        let claimable = TaxNotClaimedSources.isClaimable(line.expenseType)
        columns.append(.actions { row in
            guard let source = row.source else { return [] }
            var actions: [DataTableAction] = []
            if let id = source.transactionId {
                actions.append(DataTableAction("Show \(source.description) in Search", systemImage: "arrow.right.circle", inline: true) {
                    guard let info = viewModel.transaction(id) else { return }
                    dismiss()
                    openTransaction(info.transaction)
                })
            }
            // A cost of a deductible line (not a rent receipt, not a recharge netted against it).
            if notClaimed {
                actions.append(DataTableAction("Claim in \(yearLabel) again…", systemImage: "arrow.uturn.backward") {
                    pendingMark = PendingMark(source: source, notClaimed: false)
                })
            } else if claimable, source.amountMinorUnits > 0, !Self.isRentReceipt(source.reference) {
                actions.append(DataTableAction("Mark not claimed in \(yearLabel)…", systemImage: "minus.circle") {
                    pendingMark = PendingMark(source: source, notClaimed: true)
                })
            }
            return actions
        })
        return columns
    }

    private static func isRentReceipt(_ reference: RentalAccounts.SourceReference) -> Bool {
        if case .rentReceipt = reference { return true }
        return false
    }
}

/// A source's documents: a paperclip that opens the one document, or a menu of them.
private struct SourceDocumentsButton: View {
    let documents: [EvidenceDocument]
    let open: (EvidenceDocument) -> Void

    var body: some View {
        if documents.count == 1, let document = documents.first {
            Button { open(document) } label: { Image(systemName: "paperclip") }
                .buttonStyle(.borderless)
                .help("Open \(document.displayName)")
                .accessibilityLabel("Open \(document.displayName)")
        } else if documents.count > 1 {
            Menu {
                ForEach(documents) { document in
                    Button(document.displayName) { open(document) }
                }
            } label: {
                HStack(spacing: 1) {
                    Image(systemName: "paperclip")
                    Text("\(documents.count)").monospacedDigit().figureText()
                }
                .font(.caption)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("\(documents.count) documents")
            .accessibilityLabel("Open one of \(documents.count) documents")
        }
    }
}
