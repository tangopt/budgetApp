// Sources/BudgetCore/Budget/BudgetTotals.swift
import Foundation

/// The Budget grid's Totals block (spec 2026-10-15 budget-totals §1): **Total in**, **Total
/// out** and **Net** per month.
///
/// Total in is the Income categories plus transfer money arriving from outside: incoming
/// external transfers and, under an account filter, transfers into the selected accounts from
/// unselected ones. Total out is the Expenses categories, the reserves (their allowance cells as
/// shown) and transfer money leaving the same way. Transfers between the user's own accounts
/// are left out with All accounts, and under a filter when both legs are selected (they net to
/// zero within the selection) — except money to or from an account left out of net worth,
/// which always counts, like an external transfer. Adjustments are never included. Net = in + out (out negative).
///
/// Cells follow the plan cell semantics (`PlanStatus`): actual plus whatever the plan still
/// expects, with the pending part and its state; actuals only with Show forecast off.
public enum BudgetTotals {
    public typealias Cell = (value: Int, pending: Int, state: PendingState)

    /// A row of the block.
    public enum Row: String, CaseIterable, Sendable {
        case totalIn
        case totalOut
        case net

        public var title: String {
            switch self {
            case .totalIn: return "Total in"
            case .totalOut: return "Total out"
            case .net: return "Net"
            }
        }

        /// The rows shown: all three, or only Net while the section is collapsed.
        public static func visible(collapsed: Bool) -> [Row] {
            collapsed ? [.net] : allCases
        }

        /// Whether money of `category` (a transaction, or a planned occurrence as the filter
        /// sees it) belongs in this row. `countedTransfer`: for a transfer category, whether
        /// this money crosses the selection's boundary (`countsTransfer` for a transaction,
        /// `countsPlannedTransfer` for a planned occurrence).
        public func includes(_ category: Category, amount: Int, countedTransfer: Bool) -> Bool {
            switch category.type {
            case .income: return self != .totalOut
            case .expense: return self != .totalIn
            case .adjustment: return false
            case .transfer:
                guard countedTransfer, amount != 0 else { return false }
                switch self {
                case .totalIn: return amount > 0
                case .totalOut: return amount < 0
                case .net: return true
                }
            }
        }
    }

    /// Money in and out of one transfer category in a month (outgoing negative).
    public struct Flow: Equatable, Sendable {
        public var incoming: Int
        public var outgoing: Int

        public init(incoming: Int = 0, outgoing: Int = 0) {
            self.incoming = incoming
            self.outgoing = outgoing
        }

        public var net: Int { incoming + outgoing }
    }

    // MARK: Which transfers count

    /// Whether a transfer category's planned money counts for `accountIds` (nil = All
    /// accounts): an external transfer, or one tied to an account left out of net worth,
    /// always; under a filter, a transfer tied to an
    /// unselected account (a planned incoming leg is filed under its payer's own transfer
    /// category, so it is tied to the unselected payer) — `ForecastCalculator.countsInNetWorth`.
    public static func countsPlannedTransfer(_ category: Category, accountIds: Set<Int64>?) -> Bool {
        category.type == .transfer && ForecastCalculator.countsInNetWorth(category, accountIds: accountIds)
    }

    /// The accounts of each transaction's linked other legs (active links only), by transaction
    /// id. `transactions` must be every transaction (the other legs are looked up among them).
    public static func counterpartAccounts(transactions: [Transaction], links: [TransferLink]) -> [Int64: Set<Int64>] {
        let accountById = Dictionary(transactions.compactMap { t in t.id.map { ($0, t.accountId) } }, uniquingKeysWith: { first, _ in first })
        var result: [Int64: Set<Int64>] = [:]
        for link in links where !link.isDismissed {
            if let inAccount = accountById[link.inTransactionId] { result[link.outTransactionId, default: []].insert(inAccount) }
            if let outAccount = accountById[link.outTransactionId] { result[link.inTransactionId, default: []].insert(outAccount) }
        }
        return result
    }

    /// Whether a shown (budget-facing) transaction's transfer money counts for `accountIds`
    /// (nil = All accounts): an external transfer, or one filed under the transfer category of
    /// an account left out of net worth (`Category.movesMoneyOutsideNetWorth`), always; another
    /// transfer only under a filter, when its linked other leg is in an unselected account — or,
    /// unlinked, when its category is tied to an unselected account. Non-transfers: false.
    public static func countsTransfer(_ transaction: Transaction, category: Category?, accountIds: Set<Int64>?, counterpartAccounts: Set<Int64>?) -> Bool {
        guard let category, category.type == .transfer else { return false }
        if category.movesMoneyOutsideNetWorth { return true }
        guard let accountIds else { return false }
        if let counterparts = counterpartAccounts, !counterparts.isEmpty { return !counterparts.isSubset(of: accountIds) }
        guard let tied = category.transferAccountId else { return false }
        return !accountIds.contains(tied)
    }

    /// The confirmed transfers among `shown` (the cells' budget-facing transactions) whose
    /// money counts (`countsTransfer`).
    public static func countedTransfers(_ shown: [Transaction], categories: [Category], accountIds: Set<Int64>?, counterpartAccounts: [Int64: Set<Int64>]) -> [Transaction] {
        let byId = Dictionary(categories.compactMap { c in c.id.map { ($0, c) } }, uniquingKeysWith: { first, _ in first })
        return shown.filter { transaction in
            guard transaction.status == .confirmed, let categoryId = transaction.categoryId else { return false }
            return countsTransfer(transaction, category: byId[categoryId], accountIds: accountIds, counterpartAccounts: transaction.id.flatMap { counterpartAccounts[$0] })
        }
    }

    /// `counted` (`countedTransfers`) summed per category per pay month, incoming and
    /// outgoing apart: category id → year → month → flow.
    public static func transferActuals(_ counted: [Transaction], calendar: PayCalendar) -> [Int64: [Int: [Int: Flow]]] {
        var result: [Int64: [Int: [Int: Flow]]] = [:]
        for transaction in counted {
            guard let categoryId = transaction.categoryId else { continue }
            let month = calendar.month(containing: transaction.date)
            var flow = result[categoryId]?[month.year]?[month.month] ?? Flow()
            if transaction.amountMinorUnits > 0 { flow.incoming += transaction.amountMinorUnits } else { flow.outgoing += transaction.amountMinorUnits }
            result[categoryId, default: [:]][month.year, default: [:]][month.month] = flow
        }
        return result
    }

    // MARK: The plan's transfers

    /// The confirmed plan's transfer money in `period` for the Totals block, as the filter's
    /// accounts see it (`PlannedItemAccounts.legs`; nil filter = All accounts): `byCategory`
    /// holds each counting transfer category's (`countsPlannedTransfer`) occurrences split by
    /// direction; `incomingElsewhere` the incoming legs into a selected account filed under a
    /// category that doesn't count (a payer with no transfer category of its own) — money
    /// arriving from outside the selection (`ForecastCalculator.netWorthTotals`).
    public static func plannedTransfers(period: PayPeriod, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException],
                                        filter: PlanAccountFilter?) -> (byCategory: [Int64: Flow], incomingElsewhere: Int) {
        let counting = Set(categories.filter { countsPlannedTransfer($0, accountIds: filter?.accountIds) }.compactMap(\.id))
        let plan = ForecastCalculator.confirmedEntries(entries: entries, groups: groups)
        let occurrences = PlannedOccurrences.occurrences(entries: plan, exceptions: exceptions, in: period)
        let legs: [(occurrence: PlannedOccurrence, isIncoming: Bool)] = filter.map { filter in
            filter.itemAccounts.legs(occurrences, entries: plan, accountIds: filter.accountIds).map { ($0.occurrence, $0.isIncomingTransfer) }
        } ?? occurrences.map { ($0, false) }
        var byCategory: [Int64: Flow] = [:]
        var elsewhere = 0
        for leg in legs {
            let amount = leg.occurrence.amountMinorUnits
            if counting.contains(leg.occurrence.categoryId) {
                if amount > 0 { byCategory[leg.occurrence.categoryId, default: Flow()].incoming += amount } else { byCategory[leg.occurrence.categoryId, default: Flow()].outgoing += amount }
            } else if leg.isIncoming {
                elsewhere += amount
            }
        }
        return (byCategory, elsewhere)
    }

    // MARK: A month

    /// One month's Total in and Total out.
    /// - `actuals`: each category's pay-month actual as the cells show it (the filter's accounts).
    /// - `transferActuals`: the counted transfers' flows per category (`transferActuals`).
    /// - `planned`: the calendar month's planned totals per category for the filter's accounts
    ///   (income and expenses).
    /// - `plannedTransfers` / `plannedIncomingElsewhere`: `plannedTransfers(…)`'s parts.
    /// - `reserves`: the Total reserved cell (counted out).
    /// Income categories count in whole, expense categories out whole (refunds reduce them),
    /// as their cells show. A transfer category's two directions are plan cells of their own
    /// (`PlanStatus.cell`: counted incoming actuals against the planned incoming money, and
    /// likewise outgoing), so money sent doesn't hide money still expected in. The incoming
    /// money planned elsewhere is in only (all of it pending while the month is open). Reserves
    /// (as categories) and adjustments are skipped. Show forecast off: actuals only.
    public static func month(categories: [Category], actuals: [Int64: Int], transferActuals: [Int64: Flow], planned: [Int64: Int],
                             plannedTransfers: [Int64: Flow] = [:], plannedIncomingElsewhere: Int = 0, reserves: Cell,
                             monthClass: MonthClass, includeForecast: Bool, accountIds: Set<Int64>?) -> (totalIn: Cell, totalOut: Cell) {
        var ins: [Cell] = []
        var outs: [Cell] = [reserves]
        for category in categories where !category.isReserved {
            guard let id = category.id else { continue }
            switch category.type {
            case .income, .expense:
                let actual = actuals[id] ?? 0
                let cell: Cell = includeForecast ? PlanStatus.cell(actual: actual, planned: planned[id] ?? 0, categoryType: category.type, monthClass: monthClass) : (actual, 0, .none)
                if category.type == .income { ins.append(cell) } else { outs.append(cell) }
            case .transfer:
                let flow = transferActuals[id] ?? Flow()
                let plan = includeForecast && countsPlannedTransfer(category, accountIds: accountIds) ? plannedTransfers[id] ?? Flow() : Flow()
                ins.append(PlanStatus.cell(actual: flow.incoming, planned: plan.incoming, categoryType: .transfer, monthClass: monthClass))
                outs.append(PlanStatus.cell(actual: flow.outgoing, planned: plan.outgoing, categoryType: .transfer, monthClass: monthClass))
            case .adjustment:
                continue
            }
        }
        if includeForecast, plannedIncomingElsewhere != 0 {
            ins.append(PlanStatus.cell(actual: 0, planned: plannedIncomingElsewhere, categoryType: .transfer, monthClass: monthClass))
        }
        return (PlanStatus.combine(ins), PlanStatus.combine(outs))
    }

    /// A row's cell from the month's Total in and Total out (Net: the two combined).
    public static func cell(_ row: Row, totalIn: Cell, totalOut: Cell) -> Cell {
        switch row {
        case .totalIn: return totalIn
        case .totalOut: return totalOut
        case .net: return PlanStatus.combine([totalIn, totalOut])
        }
    }
}
