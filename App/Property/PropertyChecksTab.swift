// App/Property/PropertyChecksTab.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Transaction

/// The Checks tab (spec 2026-10-16 §1 "Checks", UI polish §4.2): the period's checks at a
/// glance — each with a tick when all is well or what's off — beside the deposit against the
/// tenancy's terms; then, for each check that found something, a table of what to look at
/// with its action.
struct PropertyChecksTab: View {
    @ObservedObject var viewModel: PropertyViewModel
    let openTransaction: (Transaction) -> Void
    let openMissingEvidence: (Int64, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
            if let checks = viewModel.snapshot.checks, let period = viewModel.period {
                SplitRow(ratio: 0.55) {
                    summaryPanel(checks, period: period)
                    depositPanel(checks.deposit)
                }
                if !checks.monthsWithoutReceipt.isEmpty { monthsPanel(checks.monthsWithoutReceipt) }
                if !checks.receiptsWithoutCredit.isEmpty { receiptsPanel(checks.receiptsWithoutCredit) }
                if !checks.creditsWithoutReceipt.isEmpty { creditsPanel(checks.creditsWithoutReceipt) }
                if !checks.missingRecurringCosts.isEmpty { recurringPanel(checks.missingRecurringCosts) }
                if !checks.notExpectedRecurringCosts.isEmpty { notExpectedPanel(checks.notExpectedRecurringCosts) }
            } else if viewModel.period == nil {
                InlineBanner(.info, "Pick a range that ends after it starts.")
            }
        }
    }

    // MARK: Summary

    private func summaryPanel(_ checks: PropertyCheckReport, period: PropertyPeriod) -> some View {
        let count = checks.issueCount
        let currency = viewModel.currency
        return Panel(count == 0 ? "Nothing to look at" : "\(count) thing\(count == 1 ? "" : "s") to look at",
                     subtitle: "\(period.label), up to today", fillsHeight: true) {
            if let property = viewModel.property, let id = property.id {
                PanelLink(title: "Missing evidence for \(property.name)") { openMissingEvidence(id, property.name) }
            }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                checkLine(checks.monthsWithoutReceipt.count, ok: "Every month the tenancy ran has a receipt",
                          one: "1 month without a receipt", many: { "\($0) months without a receipt" })
                checkLine(checks.receiptsWithoutCredit.count, ok: "Every receipt has its credit",
                          one: "1 receipt without a matched credit", many: { "\($0) receipts without a matched credit" })
                checkLine(checks.creditsWithoutReceipt.count, ok: "Every rent credit has its receipt",
                          one: "1 rent credit without a receipt", many: { "\($0) rent credits without a receipt" })
                if let deposit = checks.deposit {
                    if deposit.matches {
                        CheckLine(state: .ok, text: "The deposit account matches the terms")
                    } else {
                        CheckLine(state: .issue, text: "The deposit account is \(PropertyCheckSummary.depositOff(deposit, currency: currency))")
                    }
                } else {
                    CheckLine(state: .notChecked, text: "Deposit not checked: no deposit account linked")
                }
                checkLine(checks.missingRecurringCosts.count, ok: "No recurring cost is overdue",
                          one: "1 recurring cost overdue", many: { "\($0) recurring costs overdue" })
                if !viewModel.snapshot.hasEvidenceRules {
                    Divider()
                    HStack(spacing: 8) {
                        Text("Ask for a PDF per receipt and a contract per tenancy in Missing evidence.")
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 8)
                        Button("Add evidence rules") { viewModel.seedEvidenceRules() }
                            .controlSize(.small)
                            .help("Ask for one PDF per rent receipt and one contract per tenancy in Missing evidence")
                    }
                }
            }
        }
    }

    private func checkLine(_ count: Int, ok: String, one: String, many: (Int) -> String) -> CheckLine {
        CheckLine(state: count == 0 ? .ok : .issue, text: count == 0 ? ok : (count == 1 ? one : many(count)))
    }

    // MARK: Deposit

    private struct DepositLine: Identifiable {
        let id: String
        let title: String
        let amount: Int
        var role: MoneyRole = .neutral
        var matches = false
    }

    private func depositPanel(_ deposit: PropertyCheckReport.DepositCheck?) -> some View {
        let currency = viewModel.currency
        return Panel("Deposit", subtitle: deposit.map { "Held on \(DocumentFormat.day($0.date))" }, fillsHeight: true) {
            if let deposit { PropertyCheckSummary.depositPill(deposit, currency: currency) }
        } content: {
            if let deposit {
                let lines = [
                    DepositLine(id: "held", title: "In the deposit account", amount: deposit.heldMinorUnits),
                    DepositLine(id: "deposit", title: "Deposit months × rent", amount: deposit.expectedDepositMinorUnits,
                                matches: deposit.matchedInterpretation == .depositOnly),
                    DepositLine(id: "advance", title: "With advance rent", amount: deposit.expectedWithAdvanceMinorUnits,
                                matches: deposit.matchedInterpretation == .depositAndAdvanceRent)
                ]
                DataTable(columns: [
                    .text("", width: .fill(min: 140), { $0.title }),
                    .status("") { $0.matches ? StatusPill("Matches", tone: .positive, systemImage: "checkmark") : nil },
                    .money("Amount", role: { $0.role }, currency: { _ in currency }) { $0.amount }
                ], rows: lines, total: deposit.matches ? nil
                    : DepositLine(id: "difference", title: deposit.differenceMinorUnits < 0 ? "Short by" : "Over by",
                                  amount: abs(deposit.differenceMinorUnits)),
                  zebra: false, showsHeader: false)
            } else {
                Text("Link a deposit account in Profile (and set the tenancy's deposit months) to check it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Findings

    private struct MonthRow: Identifiable {
        let item: PropertyCheckReport.MissingReceiptMonth
        var id: String { "\(item.tenancyId)/\(item.month.start.timeIntervalSince1970)" }
    }

    private func monthsPanel(_ months: [PropertyCheckReport.MissingReceiptMonth]) -> some View {
        let format = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.wide).year()
        return Panel("Months without a receipt", subtitle: "Months a tenancy ran with no issued receipt covering them") {
            StatusPill("\(months.count)", tone: .warning)
        } content: {
            DataTable(columns: [
                .text("Month", width: .min(140), figure: true, { $0.item.month.start.formatted(format) }),
                .text("Tenancy", { tenancyName($0.item.tenancyId) })
            ], rows: months.map(MonthRow.init))
        }
    }

    private func receiptsPanel(_ receipts: [RentReceipt]) -> some View {
        let currency = viewModel.currency
        return Panel("Receipts without a matched credit", subtitle: "Issued receipts the linked credits don't fully pay") {
            HStack(spacing: 8) {
                StatusPill("\(receipts.count)", tone: .warning)
                Button("Match credits") { viewModel.matchCredits() }
                    .controlSize(.small)
                    .help("Link rent credits on the current account to the receipts they paid")
            }
        } content: {
            DataTable(columns: [
                .text("No.", width: .fit, figure: true, { $0.receiptNumber }),
                PropertyReceiptColumns.period { ($0.periodStart, $0.periodEnd) },
                .money("Received", role: .neutral, currency: { _ in currency }) { $0.amountReceivedMinorUnits }
            ], rows: receipts)
        }
    }

    private func creditsPanel(_ credits: [Transaction]) -> some View {
        Panel("Rent credits without a receipt", subtitle: "Credits in the rent categories not linked to any receipt") {
            StatusPill("\(credits.count)", tone: .warning)
        } content: {
            DataTable(columns: [
                .date("Date") { $0.date },
                .text("Description", { $0.rawDescription }),
                .money("Amount", currency: { _ in viewModel.currency }) { $0.amountMinorUnits },
                .actions { credit in
                    [DataTableAction("Show the transaction", systemImage: "arrow.right.circle", inline: true) { openTransaction(credit) }]
                }
            ], rows: credits)
        }
    }

    private struct RecurringRow: Identifiable {
        let item: PropertyCheckReport.MissingRecurringCost
        var id: String { item.pattern.key }
    }

    private func recurringPanel(_ items: [PropertyCheckReport.MissingRecurringCost]) -> some View {
        Panel("Recurring costs overdue", subtitle: "Costs that repeat in the history whose next one hasn't come") {
            StatusPill("\(items.count)", tone: .warning)
        } content: {
            DataTable(columns: [
                .text("Cost", { $0.item.pattern.title }),
                .date("Expected around") { $0.item.expectedDate },
                // Every row is a cost: as magnitudes (spec §1.4).
                .money("Last amount", role: .neutral, currency: { $0.item.pattern.currency }) { $0.item.pattern.lastAmountMinorUnits },
                .actions { row in
                    [DataTableAction("Not expected any more", systemImage: "bell.slash", inline: true) {
                        viewModel.stopExpecting(row.item.pattern)
                    }]
                }
            ], rows: items.map(RecurringRow.init))
        }
    }

    private struct NotExpectedRow: Identifiable {
        let item: PropertyCheckReport.NotExpectedRecurringCost
        var id: String { item.pattern.key }
    }

    /// Series cleared with "Not expected any more", to undo the decision.
    private func notExpectedPanel(_ items: [PropertyCheckReport.NotExpectedRecurringCost]) -> some View {
        Panel("Not expected any more", subtitle: "Recurring costs you cleared; a new payment brings one back") {
            StatusPill("\(items.count)", tone: .neutral)
        } content: {
            DataTable(columns: [
                .text("Cost", { $0.item.pattern.title }),
                .date("Last paid") { $0.item.pattern.lastDate },
                .money("Last amount", role: .neutral, currency: { $0.item.pattern.currency }) { $0.item.pattern.lastAmountMinorUnits },
                .actions { row in
                    [DataTableAction("Expect again", systemImage: "arrow.uturn.backward", inline: true) { viewModel.expectAgain(row.item) }]
                }
            ], rows: items.map(NotExpectedRow.init))
        }
    }

    private func tenancyName(_ id: Int64) -> String {
        viewModel.snapshot.tenancies.first { $0.id == id }?.referenceLabel ?? ""
    }
}

/// One check's state as a line: a tick in the income colour when all is well, a mark in the
/// to-do colour when something's off, a dash when it couldn't be checked.
struct CheckLine: View {
    enum State {
        case ok, issue, notChecked
    }

    let state: State
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(state == .notChecked ? Color.secondary : Color.primary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch state {
        case .ok: return "checkmark.circle.fill"
        case .issue: return "exclamationmark.circle.fill"
        case .notChecked: return "minus.circle"
        }
    }

    private var color: Color {
        switch state {
        case .ok: return theme.income
        case .issue: return theme.pending
        case .notChecked: return .secondary
        }
    }
}

/// The checks put shortly, for Overview's line and the deposit's pill.
enum PropertyCheckSummary {
    /// What's off, one phrase per check ("1 rent credit without a receipt").
    static func issues(_ checks: PropertyCheckReport, currency: Currency) -> [String] {
        func count(_ n: Int, _ one: String, _ many: String) -> String? { n == 0 ? nil : (n == 1 ? "1 \(one)" : "\(n) \(many)") }
        return [
            count(checks.monthsWithoutReceipt.count, "month without a receipt", "months without a receipt"),
            count(checks.receiptsWithoutCredit.count, "receipt without its credit", "receipts without their credit"),
            count(checks.creditsWithoutReceipt.count, "rent credit without a receipt", "rent credits without a receipt"),
            checks.deposit.flatMap { $0.matches ? nil : "deposit account \(depositOff($0, currency: currency))" },
            count(checks.missingRecurringCosts.count, "recurring cost overdue", "recurring costs overdue")
        ].compactMap { $0 }
    }

    /// How far the deposit account is off, as a magnitude with its direction and what it was
    /// compared with (the nearer reading of the terms): "€100.00 short of the deposit and
    /// advance rent", "€20.00 over the deposit".
    static func depositOff(_ deposit: PropertyCheckReport.DepositCheck, currency: Currency) -> String {
        let difference = deposit.differenceMinorUnits
        let amount = Money.format(abs(difference), currency: currency)
        return "\(amount) \(difference < 0 ? "short of" : "over") \(depositComparison(deposit))"
    }

    /// What the deposit account was compared with: the reading `differenceMinorUnits` uses.
    private static func depositComparison(_ deposit: PropertyCheckReport.DepositCheck) -> String {
        let withAdvance = deposit.expectedWithAdvanceMinorUnits != deposit.expectedDepositMinorUnits
            && deposit.differenceMinorUnits == deposit.heldMinorUnits - deposit.expectedWithAdvanceMinorUnits
        return withAdvance ? "the deposit and advance rent" : "the deposit"
    }

    /// The deposit account against the terms: matches (which reading) or how far off ("€100.00
    /// short", the comparison in its tooltip).
    static func depositPill(_ deposit: PropertyCheckReport.DepositCheck, currency: Currency) -> StatusPill {
        switch deposit.matchedInterpretation {
        case .depositAndAdvanceRent: return StatusPill("Matches with advance rent", tone: .positive, systemImage: "checkmark")
        case .depositOnly: return StatusPill("Matches the deposit", tone: .positive, systemImage: "checkmark")
        case nil:
            let difference = deposit.differenceMinorUnits
            return StatusPill("\(Money.format(abs(difference), currency: currency)) \(difference < 0 ? "short" : "over")", tone: .warning,
                              systemImage: "exclamationmark.triangle.fill",
                              help: "The deposit account is \(depositOff(deposit, currency: currency))")
        }
    }
}
