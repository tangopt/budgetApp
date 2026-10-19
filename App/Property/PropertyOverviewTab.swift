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
                    Panel("Cash flow by month", subtitle: "Rent above the line, costs below, net as the line; click a month for its transactions",
                          fillsHeight: true) {
                        PropertyMonthlyChart(summary: summary, height: 210, viewModel: viewModel)
                    }
                    PropertyLoanPanel(viewModel: viewModel, currency: summary.currency)
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
                                Text(PropertyFormat.period(tenancy.startDate, tenancy.endDate)).figureText()
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
            Text("\(issued) issued").monospacedDigit().figureText()
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
/// With a view model, clicking a month opens its transactions beside the page (and closes
/// them when it's the open one); the open month is highlighted.
struct PropertyMonthlyChart: View {
    let summary: PropertySummary
    var height: CGFloat = 220
    var viewModel: PropertyViewModel? = nil

    var body: some View {
        MonthlyFlowChart(months: summary.months.map { month in
                             FlowMonth(start: month.start, inflowMinorUnits: month.figures.rentReceived.native,
                                         outflowMinorUnits: month.figures.costs.native, netMinorUnits: month.figures.netCashFlow.native)
                         },
                         currency: summary.currency, inflowLabel: "Rent received", outflowLabel: "Costs", netLabel: "Net cash flow",
                         today: AppClock.now, height: height, openMonth: viewModel?.openMonthStart,
                         onSelectMonth: viewModel.map { model in { model.toggleMonth($0) } })
    }
}

/// What the mortgage owes over time (`PropertyViewModel.Snapshot.loanHistory`), and, zoomed
/// out (Next 5 years, To the end), what it will owe (`MortgageProjection`, dashed) to the
/// final instalment and its balloon, with the projection's assumptions as a caption.
struct PropertyLoanPanel: View {
    @ObservedObject var viewModel: PropertyViewModel
    let currency: Currency

    private var points: [PropertyViewModel.LoanPoint] { viewModel.snapshot.loanHistory }
    private var projection: MortgageProjection.Result? {
        guard let result = viewModel.snapshot.loanProjection, !result.payments.isEmpty, result.end != .neverRepaid else { return nil }
        return result
    }
    private var isLinked: Bool { viewModel.snapshot.propertyAccounts.contains { $0.role == .mortgage } }
    private var range: PropertyViewModel.LoanRange { projection == nil ? .soFar : viewModel.loanRange }

    var body: some View {
        Panel("Outstanding loan", subtitle: subtitle, fillsHeight: true) {
            if let first = points.first, let last = points.last, points.count >= 2 {
                VStack(alignment: .leading, spacing: 8) {
                    if projection != nil { rangePicker }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        MoneyText(minorUnits: last.owedMinorUnits, currency: currency,
                                  font: .title3.monospacedDigit().weight(.semibold), role: .neutral)
                        // The label gives way before the figures beside it.
                        Text("owed today").font(.callout).foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1)
                        Spacer(minLength: 8)
                        headlineEnd(first: first, last: last)
                    }
                    BalanceLineChart(points: chartPoints, currency: currency, title: "Outstanding loan",
                                     includesZero: range == .toTheEnd, today: range == .soFar ? nil : last.date,
                                     markers: markers, height: 160)
                        // Room above the plot for the "Today" label.
                        .padding(.top, range == .soFar ? 0 : 8)
                    if range != .soFar, let caption = assumptions {
                        Text(caption.figuresUnbroken)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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

    /// How far the chart reaches (a row of its own, so the panel's title never squeezes).
    private var rangePicker: some View {
        Picker("Range", selection: $viewModel.loanRange) {
            ForEach(PropertyViewModel.LoanRange.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .prominentTint()
        .fixedSize()
        .help("How far the chart reaches: the loan so far, or projected five years on, or to its final instalment")
        .accessibilityLabel("Loan chart range")
    }

    /// So far: what's been repaid; zoomed out: when the loan ends.
    @ViewBuilder
    private func headlineEnd(first: PropertyViewModel.LoanPoint, last: PropertyViewModel.LoanPoint) -> some View {
        if range != .soFar, let date = projection?.finalDate {
            HStack(spacing: 4) {
                Text("ends").foregroundStyle(.secondary).lineLimit(1)
                DateText(date: date, font: .callout).foregroundStyle(.secondary)
            }
            .font(.callout)
            .fixedSize()
        } else if first.owedMinorUnits > last.owedMinorUnits {
            Text("\(Money.format(first.owedMinorUnits - last.owedMinorUnits, currency: currency)) repaid")
                .font(.callout).monospacedDigit().foregroundStyle(.secondary).figureText()
        }
    }

    /// The history, then the projection as far as the range reaches.
    private var chartPoints: [BalancePoint] {
        let history = points.map { BalancePoint(date: $0.date, minorUnits: $0.owedMinorUnits) }
        guard range != .soFar, let projection, let today = points.last?.date else { return history }
        let limit = range == .fiveYears ? MonthRange.calendar.date(byAdding: .year, value: 5, to: today)! : Date.distantFuture
        // The history's month ends, then what's owed after each projected instalment, on its
        // payment day (so the final instalment's drop to nothing shows).
        return history + projection.payments.filter { $0.date <= limit }
            .map { BalancePoint(date: $0.date, minorUnits: $0.owedMinorUnits, isForecast: true) }
    }

    /// The final instalment (the balloon), marked where the chart reaches it.
    private var markers: [BalanceMarker] {
        guard range == .toTheEnd, let projection, let date = projection.finalDate, let paid = projection.finalPaymentMinorUnits,
              let before = projection.payments.dropLast().last?.owedMinorUnits else { return [] }
        let balloon = viewModel.snapshot.loanBasis?.input.balloonMinorUnits ?? 0
        let label = balloon > 0 ? "Final \(MoneyAxis.compact(minorUnits: paid, currency: currency)) with the balloon"
            : "Final \(MoneyAxis.compact(minorUnits: paid, currency: currency))"
        return [BalanceMarker(date: date, minorUnits: before, label: label)]
    }

    private var subtitle: String? {
        guard let first = points.first, points.count >= 2 else { return nil }
        let utc = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.abbreviated).year()
        switch range {
        case .soFar: return "Month ends since \(first.date.formatted(utc))"
        case .fiveYears: return "Since \(first.date.formatted(utc)), projected five years on (dashed)"
        case .toTheEnd: return "Since \(first.date.formatted(utc)), projected to the final instalment (dashed)"
        }
    }

    /// The projection's assumptions: the rate held, how it's revised, the instalment, the end.
    private var assumptions: String? {
        guard let basis = viewModel.snapshot.loanBasis, let projection else { return nil }
        let input = basis.input
        let instalment = Money.format(projection.payments.first?.paidMinorUnits ?? input.instalmentMinorUnits, currency: currency).unbroken
        var text: String
        switch basis.rateSource {
        case let .rules(current):
            text = "Projection: \(current.explanation) from \(MortgageTerms.dayText(current.start).unbroken)"
            if let held = basis.heldFrom, let fixing = held.fixing {
                text += "; from \(MortgageTerms.dayText(held.start).unbroken) the latest fixing (\(fixing.dateText.unbroken)) is held, "
                    + "\(MortgageRate.percent(held.ratePercent).unbroken) to the end (not a market forecast)"
            }
            text += "; revised \(MortgageTerms.scheduleText(input.revisionMonths)); \(instalment) a month"
        case let .derived(day):
            let rate = MortgageRate.percent(input.annualRatePercent).unbroken
            text = "Projection: \(rate) (from the interest charged on \(DocumentFormat.day(day))) held constant to the end, revised "
                + "\(MortgageTerms.scheduleText(input.revisionMonths)); \(instalment) a month"
        }
        if let date = projection.finalDate, let paid = projection.finalPaymentMinorUnits {
            let final = Money.format(paid, currency: currency)
            text += input.finalInstalmentDate != nil
                ? (input.balloonMinorUnits > 0
                    ? ", the final instalment of \(final) on \(DocumentFormat.day(date)) repaying the \(Money.format(input.balloonMinorUnits, currency: currency)) balloon."
                    : ", the final instalment of \(final) on \(DocumentFormat.day(date)).")
                : " until repaid on \(DocumentFormat.day(date)) (no final instalment in Profile)."
        } else {
            text += "."
        }
        return text
    }
}
