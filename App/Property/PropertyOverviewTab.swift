// App/Property/PropertyOverviewTab.swift
import SwiftUI
import BudgetCore

/// The Overview tab (spec 2026-10-16 §1, UI polish §4.2): the property at a glance. The
/// checks as one line (all clear, or what to look at, with Open Checks); the period's key
/// figures; cash flow by month beside the loan since it started; the tenancy in force beside
/// what's coming up.
struct PropertyOverviewTab: View {
    @ObservedObject var viewModel: PropertyViewModel

    var body: some View {
        let snapshot = viewModel.snapshot
        VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
            if let checks = snapshot.checks, let period = viewModel.period {
                checksBanner(checks, period: period)
            }
            if let summary = snapshot.summary {
                Panel("Key figures · \(summary.period.label)") {
                    PanelLink(title: "Money", action: { viewModel.tab = .money })
                } content: {
                    FigureStrip(figures(summary))
                }
                SplitRow(ratio: 0.6) {
                    Panel("Cash flow by month", subtitle: "Rent received above the line, costs below, net cash flow as the line",
                          fillsHeight: true) {
                        PropertyMonthlyChart(summary: summary, height: 210)
                    }
                    PropertyLoanPanel(points: snapshot.loanHistory, currency: summary.currency,
                                      isLinked: snapshot.propertyAccounts.contains { $0.role == .mortgage })
                }
            } else if viewModel.period == nil {
                InlineBanner(.info, "Pick a range that ends after it starts.")
            }
            TwoUpRow {
                tenancyPanel
            } second: {
                comingUpPanel
            }
        }
    }

    // MARK: Checks

    private func checksBanner(_ checks: PropertyCheckReport, period: PropertyPeriod) -> some View {
        let issues = PropertyCheckSummary.issues(checks, currency: viewModel.currency)
        let allClear = "Nothing to look at in \(period.label): every month has its receipt, every receipt its credit."
        let heading = "\(issues.count) thing\(issues.count == 1 ? "" : "s") to look at in \(period.label): "
        return InlineBanner(issues.isEmpty ? .success : .warning, action: {
            Button("Open Checks ›") { viewModel.tab = .checks }
                .buttonStyle(.link)
        }) {
            if issues.isEmpty {
                Text(allClear)
            } else {
                Text("\(Text(heading).fontWeight(.semibold))\(issues.joined(separator: " · "))")
            }
        }
        .lineLimit(1)
        // The line may be cut short: the whole of it on hover.
        .help(issues.isEmpty ? allClear : heading + issues.joined(separator: "; "))
    }

    // MARK: Key figures

    private func figures(_ summary: PropertySummary) -> [FigureTile] {
        let t = summary.totals, currency = summary.currency
        func gbp(_ amount: PropertyAmount) -> Int? { currency == .gbp ? nil : amount.gbp }
        return [
            FigureTile(title: "Rent received", value: .money(t.rentReceived.native, currency, .signed), gbp: gbp(t.rentReceived),
                       caption: "\(Money.format(t.rentPerReceipts.native, currency: currency)) on receipts"),
            FigureTile(title: "Costs", value: .money(t.costs.native, currency, .cost), gbp: gbp(t.costs)),
            FigureTile(title: "Net cash flow", value: .money(t.netCashFlow.native, currency, .signed), gbp: gbp(t.netCashFlow)),
            FigureTile(title: "Gross / net yield",
                       value: .text("\(PropertyFormat.yield(summary.grossYield)) / \(PropertyFormat.yield(summary.netYield))"),
                       caption: summary.purchasePrice == nil ? "Set a price in Profile" : "Annualised on the price"),
            FigureTile(title: "Outstanding loan", value: .money(summary.outstandingLoan.native, currency, .neutral),
                       gbp: gbp(summary.outstandingLoan)),
            FigureTile(title: "Deposit held", value: .money(summary.depositHeld.native, currency, .neutral), gbp: gbp(summary.depositHeld),
                       pill: viewModel.snapshot.checks?.deposit.map { PropertyCheckSummary.depositPill($0, currency: currency) })
        ]
    }

    // MARK: Tenancy

    private var tenancyPanel: some View {
        Group {
            if let tenancy = viewModel.currentTenancy {
                let running = viewModel.isRunning(tenancy)
                Panel(tenancy.referenceLabel, subtitle: running ? "The tenancy running today" : "The latest tenancy", fillsHeight: true) {
                    PanelLink(title: "Tenancies", action: { viewModel.tab = .tenancies })
                } content: {
                    PropertyFacts {
                        PropertyFact("Tenant") { Text(tenancy.tenantName ?? "—") }
                        PropertyFact("Runs") {
                            HStack(spacing: 6) {
                                Text(PropertyFormat.period(tenancy.startDate, tenancy.endDate))
                                StatusPill(running ? "Running" : "Ended", tone: running ? .positive : .neutral)
                            }
                        }
                        if let rent = viewModel.rentInForce(tenancy) {
                            PropertyFact("Rent") {
                                HStack(spacing: 4) {
                                    MoneyText(minorUnits: rent.monthlyAmountMinorUnits, currency: viewModel.currency, role: .neutral)
                                    Text("a month").foregroundStyle(.secondary)
                                }
                            }
                        }
                        PropertyFact("Held") { Text(PropertyFormat.held(tenancy)) }
                        PropertyFact("Receipts") { receiptsLine(tenancy) }
                    }
                }
            } else {
                Panel("Tenancy", fillsHeight: true) {
                    PanelLink(title: "Tenancies", action: { viewModel.tab = .tenancies })
                } content: {
                    Text("No tenancy yet: import the portal's receipts export on Tenancies, or add one by hand.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func receiptsLine(_ tenancy: Tenancy) -> some View {
        let rows = viewModel.snapshot.receipts[tenancy.id ?? -1] ?? []
        let issued = rows.filter { $0.receipt.status == .issued }.count, paid = rows.filter(\.isPaid).count
        return HStack(spacing: 6) {
            Text("\(issued) issued").monospacedDigit()
            if issued > 0 {
                if paid == issued {
                    StatusPill("All paid", tone: .positive, systemImage: "checkmark")
                } else {
                    StatusPill("\(issued - paid) not matched", tone: .warning)
                }
            }
        }
    }

    // MARK: Coming up

    private var comingUpPanel: some View {
        let upcoming = Array(viewModel.snapshot.obligations.prefix(6))
        return Panel("Coming up", fillsHeight: true) {
            PanelLink(title: "Calendar", action: { viewModel.tab = .calendar })
        } content: {
            if upcoming.isEmpty {
                Text("Nothing in the next twelve months.").font(.callout).foregroundStyle(.secondary)
            } else {
                DataTable(columns: PropertyObligationColumns.columns, rows: upcoming, showsHeader: false)
            }
        }
    }
}

/// Rent received and costs by month (bars), net cash flow (line), in the property's currency.
struct PropertyMonthlyChart: View {
    let summary: PropertySummary
    var height: CGFloat = 220

    var body: some View {
        MonthlyFlowChart(months: summary.months.map { month in
                             FlowMonth(start: month.start, inflowMinorUnits: month.figures.rentReceived.native,
                                         outflowMinorUnits: month.figures.costs.native, netMinorUnits: month.figures.netCashFlow.native)
                         },
                         currency: summary.currency, inflowLabel: "Rent received", outflowLabel: "Costs", netLabel: "Net cash flow",
                         today: AppClock.now, height: height)
    }
}

/// What the mortgage owes over time (`PropertyViewModel.Snapshot.loanHistory`): today's
/// figure and how much has been repaid since the first month shown, over the line.
struct PropertyLoanPanel: View {
    let points: [PropertyViewModel.LoanPoint]
    let currency: Currency
    /// Whether a mortgage account is linked (with too little history, the panel says so).
    var isLinked = false

    var body: some View {
        Panel("Outstanding loan", subtitle: subtitle, fillsHeight: true) {
            if let first = points.first, let last = points.last, points.count >= 2 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        MoneyText(minorUnits: last.owedMinorUnits, currency: currency,
                                  font: .title3.monospacedDigit().weight(.semibold), role: .neutral)
                        Text("owed today").font(.callout).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if first.owedMinorUnits > last.owedMinorUnits {
                            Text("\(Money.format(first.owedMinorUnits - last.owedMinorUnits, currency: currency)) repaid")
                                .font(.callout).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    BalanceLineChart(points: points.map { BalancePoint(date: $0.date, minorUnits: $0.owedMinorUnits) },
                                     currency: currency, title: "Outstanding loan", includesZero: false, height: 160)
                }
            } else if isLinked {
                Text("The mortgage account has too little history yet to draw the loan: it needs balances on two days or more.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Link the mortgage account in Profile to follow the loan.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String? {
        guard let first = points.first, points.count >= 2 else { return nil }
        let utc = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.abbreviated).year()
        return "Month ends since \(first.date.formatted(utc))"
    }
}
