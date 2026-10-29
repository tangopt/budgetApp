// App/Dashboard/DashboardMoneyTiles.swift
import SwiftUI
import BudgetCore

// The Money section: what the Dashboard showed before the review cards. Each tile is one big figure and a small chart.

struct NetWorthTile: View {
    let content: DashboardContent
    let navigate: (AppScreen) -> Void
    @Environment(\.theme) private var theme

    private var series: NetWorthSeries { content.netWorth }

    /// The lines under the figure, in the order they are given room.
    private enum Extra {
        case change(Int), forecast(YearEndForecast), behind(BehindBalances)
    }

    private var extras: [Extra] {
        var result: [Extra] = []
        if let change = series.changeVsPreviousMonthMinorUnits { result.append(.change(change)) }
        if let yearEnd = series.yearEnds.first { result.append(.forecast(yearEnd)) }
        if let behind = series.behindBalances { result.append(.behind(behind)) }
        return result
    }

    var body: some View {
        DashTile("Net worth", linkTitle: "Accounts", onLink: { navigate(.accounts) }) { _ in
            if series == .empty {
                Text("No history yet — record a balance on the Accounts screen.").font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                ChartBeside(maximumLines: extras.count) { lines in
                    VStack(alignment: .leading, spacing: 4) {
                        // The headline is the current net worth, not the last chart point: a typed snapshot dated after the
                        // data-through month makes the two differ.
                        TileFigure(value: series.currentNetWorthMinorUnits.map(DashboardFormat.pounds) ?? "—",
                                   caption: series.asOf.map { "as of \(DashboardFormat.day($0))" })
                        ForEach(Array(extras.prefix(lines).enumerated()), id: \.offset) { _, extra in
                            switch extra {
                            case .change(let change):
                                Text("\(change >= 0 ? "↑" : "↓") \(DashboardFormat.pounds(abs(change))) vs last month")
                                    .font(.caption).foregroundStyle(change >= 0 ? theme.income : theme.expense).figureText(.shrink(minimumScale: 0.8))
                            case .forecast(let yearEnd):
                                Text("Dec \(String(yearEnd.year)) forecast \(DashboardFormat.pounds(yearEnd.valueMinorUnits))")
                                    .font(.caption).foregroundStyle(.secondary).figureText(.shrink(minimumScale: 0.8))
                            case .behind(let behind):
                                Label("\(behind.accountCount) balance\(behind.accountCount == 1 ? "" : "s") out of date", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
                                    .help("\(behind.accountCount) balance\(behind.accountCount == 1 ? " was" : "s were") last updated \(DashboardFormat.day(behind.oldestSnapshotDate)), so the forecast restarts from \(behind.accountCount == 1 ? "it" : "them"). Update balances to correct it.")
                            }
                        }
                    }
                } chart: { height in
                    if !(series.actual.isEmpty && series.forecast.isEmpty) {
                        NetWorthLineChart(actual: series.actual, forecast: series.forecast, today: content.today, height: height)
                    }
                }
            }
        }
        .help(content.showsNetWorthNote ? SharingCopy.netWorthNote : "")
    }
}

struct CurrentMonthTile: View {
    let month: CurrentMonthTracking
    let navigate: (AppScreen) -> Void
    /// Opens the Close month sheet for this pay month.
    let closeMonth: () -> Void
    @Environment(\.theme) private var theme

    private var payMonth: PayMonth { PayMonth(year: month.year, month: month.month) }
    private var pace: Double { Double(month.dayOfMonth) / Double(month.daysInMonth) }
    private var hasActuals: Bool { month.hasTransactions }

    private func fraction(_ totals: FlowTotals) -> Double {
        totals.expected > 0 ? Double(totals.actual) / Double(totals.expected) : (totals.actual > 0 ? 1 : 0)
    }

    private func figure(_ totals: FlowTotals) -> String {
        hasActuals ? "\(DashboardFormat.pounds(totals.actual)) of \(DashboardFormat.pounds(totals.expected))" : "expected \(DashboardFormat.pounds(totals.expected))"
    }

    var body: some View {
        DashTile(title: PayMonthFormat.monthName(payMonth), linkTitle: "Budget", onLink: { navigate(.budgetGrid) }, accessory: {
            // A closed month (salary imported or closed by hand) is already final.
            if month.monthClass != .actual {
                Button(action: closeMonth) { Image(systemName: "calendar.badge.checkmark") }
                    .buttonStyle(.borderless)
                    .help("Close \(PayMonthFormat.name(payMonth)): end it on a chosen day; spending after it counts in \(PayMonthFormat.monthName(payMonth.next)).")
                    .accessibilityLabel("Close month")
            }
        }, content: { size in
            // In order of priority as the tile grows: income, expenses, then the note.
            var room = TileBudget(height: Double(size.height), reserved: TileBudget.figure)
            let showsIncome = room.take(TileBudget.meterLine)
            let showsExpenses = showsIncome && room.take(TileBudget.meterLine)
            let showsNote = showsExpenses && room.take(TileBudget.textLine)
            TileFigure(value: DashboardFormat.pounds(month.net.projected),
                       caption: "projected net · day \(month.dayOfMonth) of \(month.daysInMonth)",
                       tint: month.net.projected < 0 ? theme.expense : .primary)
                .help(month.reservedProjected > 0 ? "Includes \(DashboardFormat.pounds(month.reservedProjected)) reserved for unplanned spending (the Budget grid's reserves)." : "")
            if showsIncome {
                MeterLine(label: "Income", figure: figure(month.income), fraction: hasActuals ? fraction(month.income) : 0, pace: hasActuals ? pace : nil, tint: theme.income)
            }
            if showsExpenses {
                MeterLine(label: "Expenses", figure: figure(month.expenses), fraction: hasActuals ? fraction(month.expenses) : 0, pace: hasActuals ? pace : nil,
                          tint: month.expenses.actual > month.expenses.expected ? theme.expense : theme.series(1))
            }
            if showsNote && month.unreviewedCount > 0 {
                Text("\(month.unreviewedCount) unreviewed (\(DashboardFormat.pounds(month.unreviewedOutflowMinorUnits).unbroken) out) not included")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else if showsNote && !hasActuals {
                Text("No transactions imported yet").font(.caption).foregroundStyle(.orange).lineLimit(1)
            }
        })
    }
}

struct YearTile: View {
    @ObservedObject var viewModel: DashboardViewModel
    let content: DashboardContent
    let navigate: (AppScreen) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        // Summed once per body evaluation (twelve additions).
        let totals = DashboardCalculator.yearTotals(viewModel.flows)
        let isFuture = viewModel.flows.contains { $0.monthClass != .actual }
        let net = totals.incomeProjected - totals.expenseProjected
        DashTile(title: "Year at a glance", linkTitle: isFuture ? "Forecast" : "Budget", onLink: { navigate(isFuture ? .forecast : .budgetGrid) }, accessory: {
            HStack(spacing: 2) {
                Button { viewModel.selectYear(viewModel.selectedYear - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(viewModel.selectedYear <= content.yearRange.lowerBound)
                    .help("Show the previous year")
                    .accessibilityLabel("Previous year")
                Text(String(viewModel.selectedYear)).font(.subheadline.weight(.medium)).figureText().frame(minWidth: 40)
                Button { viewModel.selectYear(viewModel.selectedYear + 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(viewModel.selectedYear >= content.yearRange.upperBound)
                    .help("Show the next year")
                    .accessibilityLabel("Next year")
            }
            .buttonStyle(.borderless)
        }, content: { size in
            // The footnote needs a line of its own under the chart; a tile too short for it goes without.
            let showsFootnote = size.height >= 184
            ChartBeside(maximumLines: 2, footer: showsFootnote ? 20 : 0) { lines in
                VStack(alignment: .leading, spacing: 4) {
                    TileFigure(value: DashboardFormat.pounds(net), caption: isFuture ? "net saved, projected" : "net saved",
                               tint: net < 0 ? theme.expense : .primary)
                    if lines >= 1 {
                        Text("In \(DashboardFormat.pounds(totals.incomeProjected))").font(.caption).foregroundStyle(theme.income).figureText(.shrink(minimumScale: 0.8))
                    }
                    if lines >= 2 {
                        Text("Out \(DashboardFormat.pounds(totals.expenseProjected))").font(.caption).foregroundStyle(theme.series(1)).figureText(.shrink(minimumScale: 0.8))
                    }
                }
            } chart: { height in
                YearAtAGlanceChart(flows: viewModel.flows, height: height)
            }
            if showsFootnote {
                Text(footnote(isFuture: isFuture)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        })
    }

    /// Built as Strings (the year via `String(_:)`, so it reads "2026", not "2,026").
    private func footnote(isFuture: Bool) -> String {
        let unreviewed = viewModel.unreviewed
        if unreviewed.count > 0 {
            return "\(unreviewed.count) unreviewed in \(String(viewModel.selectedYear)) \(unreviewed.count == 1 ? "isn't" : "aren't") included"
        }
        return isFuture ? "Solid = actual · hatched = forecast or still expected" : "Completed year, as the Budget grid"
    }
}

struct YearChangeTile: View {
    let changes: [YearChange]
    let thisYear: Int
    let navigate: (AppScreen) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        DashTile("Net worth change a year", linkTitle: "Accounts", onLink: { navigate(.accounts) }) { _ in
            if let latest = changes.first(where: { $0.year == thisYear }) ?? changes.last {
                ChartBeside { _ in
                    TileFigure(value: DashboardFormat.pounds(latest.totalMinorUnits),
                               caption: "\(String(latest.year))\(latest.forecastMinorUnits != 0 ? " incl. forecast" : "") · \(DashboardFormat.percent(latest.percent))",
                               tint: latest.totalMinorUnits < 0 ? theme.yoyBad : .primary)
                } chart: { height in
                    YearOverYearChart(changes: changes, height: height)
                }
            } else {
                Text("Needs at least a year of balance history.").font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

struct TopCategoriesTile: View {
    let categories: [CategorySpend]
    let hasActuals: Bool
    let navigate: (AppScreen) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let total = categories.reduce(0) { $0 + (hasActuals ? $1.actual : $1.expected) }
        DashTile("Top categories", linkTitle: "Budget", onLink: { navigate(.budgetGrid) }) { size in
            // Two categories at the default height; more as the tile gets taller.
            var room = TileBudget(height: Double(size.height), reserved: TileBudget.figure)
            let visible = Array(categories.prefix(room.count(upTo: 8, cost: TileBudget.meterLine)))
            if categories.isEmpty {
                Text("Nothing planned or spent yet this month.").font(.callout).foregroundStyle(.secondary).lineLimit(2)
            } else {
                TileFigure(value: DashboardFormat.pounds(total), caption: hasActuals ? "spent in the top \(categories.count) this month" : "expected in the top \(categories.count) this month")
                ForEach(visible) { category in
                    MeterLine(label: category.name, figure: figure(category),
                              fraction: category.expected > 0 ? Double(category.actual) / Double(category.expected) : (category.actual > 0 ? 1 : 0),
                              tint: category.isOver || category.isUnplanned ? theme.expense : theme.series(1),
                              figureTint: category.isOver ? theme.expense : (category.isUnplanned ? .orange : .primary))
                }
            }
        }
    }

    // Amounts never wrap; the name truncates instead.
    private func figure(_ category: CategorySpend) -> String {
        if category.isCoveredByReserve && category.expected == 0 && category.actual > 0 { return "\(DashboardFormat.pounds(category.actual)) reserved" }
        if category.isUnplanned { return "\(DashboardFormat.pounds(category.actual)) unplanned" }
        return hasActuals ? "\(DashboardFormat.pounds(category.actual)) of \(DashboardFormat.pounds(category.expected))" : "expected \(DashboardFormat.pounds(category.expected))"
    }
}

struct UpcomingBillsTile: View {
    let bills: [UpcomingBill]
    let navigate: (AppScreen) -> Void

    var body: some View {
        DashTile("Bills · next 30 days", linkTitle: "Budget", onLink: { navigate(.budgetGrid) }) { size in
            var room = TileBudget(height: Double(size.height), reserved: TileBudget.figure)
            let shown = room.count(upTo: 8, cost: TileBudget.listRow)
            if bills.isEmpty {
                Text("None in the next 30 days.").font(.callout).foregroundStyle(.secondary)
            } else {
                TileFigure(value: DashboardFormat.pounds(bills.reduce(0) { $0 + abs($1.amountMinorUnits) }),
                           caption: "\(bills.count) bill\(bills.count == 1 ? "" : "s") due")
                // Offset identity: `UpcomingBill.id` collides for two identical bills (same category, date and amount).
                let visible = Array(bills.prefix(shown).enumerated())
                ForEach(visible, id: \.offset) { _, bill in
                    HStack(spacing: 6) {
                        Text(DashboardFormat.day(bill.date)).foregroundStyle(.secondary).figureText()
                        Text(bill.categoryName).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(DashboardFormat.pounds(abs(bill.amountMinorUnits))).monospacedDigit().figureText()
                    }
                    .font(.caption)
                }
            }
        }
    }
}

struct AccountsTile: View {
    let accounts: [AccountSummary]
    let navigate: (AppScreen) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let sorted = accounts.sorted { abs($0.gbpBalanceMinorUnits) > abs($1.gbpBalanceMinorUnits) }
        DashTile("Accounts", linkTitle: "Accounts", onLink: { navigate(.accounts) }) { size in
            var room = TileBudget(height: Double(size.height), reserved: TileBudget.figure)
            let shown = room.count(upTo: 8, cost: TileBudget.meterLine)
            let visible = Array(sorted.prefix(shown))
            let largest = max(1, visible.map { abs($0.gbpBalanceMinorUnits) }.max() ?? 1)
            if accounts.isEmpty {
                Text("No accounts yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                TileFigure(value: String(accounts.count), caption: shown > 0 && accounts.count > shown ? "accounts · the \(shown) largest" : "account\(accounts.count == 1 ? "" : "s")")
                ForEach(visible) { account in
                    let owed = account.kind == .credit && account.gbpBalanceMinorUnits < 0
                    MeterLine(label: account.name, figure: owed ? "\(DashboardFormat.pounds(abs(account.gbpBalanceMinorUnits))) owed" : DashboardFormat.pounds(account.gbpBalanceMinorUnits),
                              fraction: Double(abs(account.gbpBalanceMinorUnits)) / Double(largest), tint: owed ? theme.expense : theme.series(0),
                              figureTint: owed ? theme.expense : .primary)
                }
            }
        }
    }
}
