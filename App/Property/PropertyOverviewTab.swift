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
                        PropertyMonthlyChart(summary: summary, height: 210, growsVertically: true, viewModel: viewModel)
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
    /// Taller than `height` when the panel is stretched to its row (Overview, beside the loan).
    var growsVertically = false
    var viewModel: PropertyViewModel? = nil

    var body: some View {
        MonthlyFlowChart(months: summary.months.map { month in
                             FlowMonth(start: month.start, inflowMinorUnits: month.figures.rentReceived.native,
                                         outflowMinorUnits: month.figures.costs.native, netMinorUnits: month.figures.netCashFlow.native)
                         },
                         currency: summary.currency, inflowLabel: "Rent received", outflowLabel: "Costs", netLabel: "Net cash flow",
                         today: AppClock.now, height: height, growsVertically: growsVertically, openMonth: viewModel?.openMonthStart,
                         onSelectMonth: viewModel.map { model in { model.toggleMonth($0) } })
    }
}

/// What the mortgage owes over time (`PropertyViewModel.Snapshot.loanHistory`) — from the
/// first instalment when the amount borrowed is known, the part before the first statement
/// estimated from the loan's terms (`MortgageHistory`, lighter and finely dashed) — and,
/// zoomed out, what it will owe (`MortgageProjection`, dashed): ±5 years shows the five years
/// before today and the five after (the window alone, its scale fitted to it); To the end, the
/// whole loan to the final instalment and its balloon. At the bottom, in one slot of constant height: for
/// So far, how much is repaid (a bar and the figures) and what the estimate rests on; for the
/// projections, the projection's assumptions. The slot is as tall as the taller of the two,
/// so the tile never changes height between ranges.
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

    /// The estimate before the first real point: only when it ends where the plotted history
    /// starts (its anchor is no earlier than the first point, give or take a month), so the
    /// two never leave a stretch of real history out.
    private var estimate: MortgageHistory.Estimate? {
        guard let estimate = viewModel.snapshot.loanEstimate, let first = points.first,
              let lastEstimated = estimate.points.last?.date, lastEstimated < first.date,
              first.date.timeIntervalSince(lastEstimated) <= 45 * 86_400 else { return nil }
        return estimate
    }
    private var estimatedPoints: [BalancePoint] {
        guard let estimate, let first = points.first else { return [] }
        return estimate.points.filter { $0.date < first.date }
            .map { BalancePoint(date: $0.date, minorUnits: $0.owedMinorUnits, isEstimated: true) }
    }
    /// Where the chart starts: the amount borrowed, or the first record.
    private var startDate: Date? { estimatedPoints.first?.date ?? points.first?.date }

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
                        headlineEnd(repaid: viewModel.snapshot.loanProgress?.repaidMinorUnits
                                        ?? (estimatedPoints.first?.minorUnits ?? first.owedMinorUnits) - last.owedMinorUnits)
                    }
                    BalanceLineChart(points: chartPoints, currency: currency, title: "Outstanding loan",
                                     includesZero: range == .toTheEnd, today: range == .soFar ? nil : last.date,
                                     xDomain: window, markers: markers, height: 160, growsVertically: true)
                        // Room above the plot for the "Today" label (in every range, so the
                        // tile keeps its height).
                        .padding(.top, 8)
                    footer
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
        .help("How far the chart reaches: the loan so far; five years back and five years projected on from today; or the whole loan to its final instalment")
        .accessibilityLabel("Loan chart range")
        .accessibilityHint("So far, five years before and after today, or to the final instalment")
    }

    /// So far: what's been repaid; zoomed out: when the loan ends.
    @ViewBuilder
    private func headlineEnd(repaid: Int) -> some View {
        if range != .soFar, let date = projection?.finalDate {
            HStack(spacing: 4) {
                Text("ends").foregroundStyle(.secondary).lineLimit(1)
                DateText(date: date, font: .callout).foregroundStyle(.secondary)
            }
            .font(.callout)
            .fixedSize()
        } else if repaid > 0 {
            Text("\(Money.format(repaid, currency: currency)) repaid")
                .font(.callout).monospacedDigit().foregroundStyle(.secondary).figureText()
        }
    }

    // MARK: Footer

    /// One slot for both: the assumptions (projections) and the progress (So far), each laid
    /// out in every range and shown in its own, so the slot's height never changes.
    private var footer: some View {
        ZStack(alignment: .topLeading) {
            if let caption = assumptions {
                Text(caption.figuresUnbroken)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(range == .soFar ? 0 : 1)
                    .accessibilityHidden(range == .soFar)
            }
            progressFooter
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(range == .soFar ? 1 : 0)
                .accessibilityHidden(range != .soFar)
        }
    }

    /// The share of the amount borrowed repaid, as a bar and its figures; then what the
    /// estimate before the first statement rests on.
    private var progressFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progress = viewModel.snapshot.loanProgress {
                ProgressBar(fraction: progress.fraction, accessibilityLabel: "Loan repaid")
                ViewThatFits(in: .horizontal) {
                    progressLine(progress, showsInstalment: true, showsAmounts: true)
                    progressLine(progress, showsInstalment: false, showsAmounts: true)
                    progressLine(progress, showsInstalment: false, showsAmounts: false)
                }
            } else {
                Text("Enter the amount borrowed in Mortgage terms to follow the loan from its start.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = estimateNote {
                Text(note.figuresUnbroken)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "44% repaid · €X of €Y · instalment 175 of 300".
    private func progressLine(_ progress: MortgageHistory.Progress, showsInstalment: Bool, showsAmounts: Bool) -> some View {
        HStack(spacing: 4) {
            Text("\(progress.percent)% repaid").fontWeight(.semibold).figureText()
            if showsAmounts {
                Text("·").foregroundStyle(.secondary)
                MoneyText(minorUnits: progress.repaidMinorUnits, currency: currency, font: .caption.monospacedDigit(), role: .neutral)
                Text("of").foregroundStyle(.secondary)
                MoneyText(minorUnits: progress.borrowedMinorUnits, currency: currency, font: .caption.monospacedDigit(), role: .neutral)
            }
            if showsInstalment, let number = progress.instalmentNumber, let total = progress.totalInstalments {
                Text("·").foregroundStyle(.secondary)
                Text("instalment \(number) of \(total)").foregroundStyle(.secondary).figureText()
            }
        }
        .font(.caption)
        .fixedSize()
    }

    /// "Before 30 Sep 2023: estimated from the loan's terms and Euribor history, adjusted by
    /// €327.07 to meet the first statement" (the demo loan); with a large gap, the amount
    /// borrowed that would meet it, to check.
    private var estimateNote: String? {
        guard let estimate, let first = points.first else { return nil }
        var text = "Before \(MortgageTerms.dayText(first.date).unbroken): estimated from the loan's terms and Euribor history"
        let gap = Money.format(abs(estimate.gapMinorUnits), currency: currency).unbroken
        if estimate.isAdjusted {
            text += ", adjusted by \(gap) to meet the first statement"
        } else if estimate.isLargeGap {
            text += "; it misses the first statement by \(gap): check the amount borrowed"
            if let suggested = estimate.suggestedPrincipalMinorUnits {
                text += " (\(Money.format(suggested, currency: currency).unbroken) would meet it)"
            }
        }
        return text
    }

    // MARK: Chart

    /// ±5 years: today − 5 years … today + 5 years (nil in the other ranges: the points' extent).
    private var window: ClosedRange<Date>? {
        guard range == .fiveYears, let today = points.last?.date else { return nil }
        let calendar = MonthRange.calendar
        return calendar.date(byAdding: .year, value: -5, to: today)!...calendar.date(byAdding: .year, value: 5, to: today)!
    }

    /// The estimate, the history, then the projection as far as the range reaches (±5 years:
    /// only what falls in the window, the line meeting its left edge).
    private var chartPoints: [BalancePoint] {
        var history = estimatedPoints + points.map { BalancePoint(date: $0.date, minorUnits: $0.owedMinorUnits) }
        guard range != .soFar, let projection else { return history }
        if let window { history = Self.clipped(history, from: window.lowerBound) }
        let limit = window?.upperBound ?? Date.distantFuture
        // The history's month ends, then what's owed after each projected instalment, on its
        // payment day (so the final instalment's drop to nothing shows).
        return history + projection.payments.filter { $0.date <= limit }
            .map { BalancePoint(date: $0.date, minorUnits: $0.owedMinorUnits, isForecast: true) }
    }

    /// The points from `start` on, led by one on `start` itself (interpolated between the
    /// points either side, styled as the earlier one) so the line reaches the window's edge.
    static func clipped(_ history: [BalancePoint], from start: Date) -> [BalancePoint] {
        guard let index = history.firstIndex(where: { $0.date >= start }) else { return [] }
        let kept = Array(history[index...])
        guard index > 0, kept[0].date > start else { return kept }
        let before = history[index - 1], after = kept[0]
        let fraction = start.timeIntervalSince(before.date) / after.date.timeIntervalSince(before.date)
        let owed = Double(before.minorUnits) + Double(after.minorUnits - before.minorUnits) * fraction
        return [BalancePoint(date: start, minorUnits: Int(owed.rounded()), isEstimated: before.isEstimated)] + kept
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

    /// The same in every range (so the title block keeps its height).
    private var subtitle: String? {
        guard let start = startDate, points.count >= 2 else { return nil }
        let utc = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.abbreviated).year()
        var since = "Since \(start.formatted(utc))"
        if estimate != nil, let first = points.first { since += " (estimated before \(first.date.formatted(utc)))" }
        return projection == nil ? since : since + ", then the projection (dashed)"
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
