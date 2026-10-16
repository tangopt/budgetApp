// App/DesignSystem/GridCellPanel.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

/// The categories and calendar month a month cell's panel lists planned occurrences for (one
/// category, or a group's or section's members).
struct CellPlan {
    let categories: [Category]
    let year: Int
    let month: Int
    /// A Totals row's month: the occurrences that row includes (`totalsOccurrences`) instead.
    var totals: BudgetTotals.Row? = nil
}

/// What a clicked grid cell's side panel shows (Budget grid spec §2, and the Forecast grid):
/// the transactions of `categoryIds` in `start...end` (read live from the view model, so an
/// edit shows at once), then the planned occurrences of `plan` when set.
struct GridCellTarget {
    let title: String
    let categoryIds: Set<Int64>
    let start: Date
    let end: Date
    /// Group and section rows: each transaction names its category.
    var showCategory = false
    /// False for a reserve (planned items only).
    var showsTransactions = true
    /// nil for a Year Total (transactions only).
    var plan: CellPlan?
    /// A Totals row: the transactions it sums (`totalsTransactions`) instead of `categoryIds`'.
    var totals: BudgetTotals.Row? = nil
    /// A "Not assigned to an account" cell (Budget grid): the unassigned planned items to assign instead.
    var unassigned: UnassignedPeriod? = nil
}

/// What a grid's view model gives its cell panel (`GridCellPanel`): the Budget grid's
/// (`BudgetGridViewModel`, the budget's plan) and the Forecast grid's (`ScenarioLabViewModel`,
/// the selected plan, with the same actuals).
@MainActor
protocol GridCellPanelModel: ObservableObject {
    var categories: [Category] { get }
    var categoryById: [Int64: Category] { get }
    var categoryNameById: [Int64: String] { get }
    var accountNameById: [Int64: String] { get }
    var transferCounterparts: [Int64: [TransferCounterpart]] { get }
    /// Non-GBP accounts at the stored rate: rows in each account's currency, the total in GBP.
    var conversion: CurrencyConversion { get }
    var planEditActions: PlanEditActions { get }
    var planAccountOptions: PlanAccountOptions { get }
    /// Whether month panels list the plan (the Budget grid: Show forecast).
    var panelShowsPlan: Bool { get }
    /// A scenario's occurrences, labelled "Open" / "Closed month" (`PlannedOccurrencesSection.inScenario`).
    var panelPlanIsScenario: Bool { get }
    /// Whether planned occurrences offer Edit… / Remove… (not for a read-only plan).
    var panelAllowsPlanEditing: Bool { get }
    /// The confirmed, budget-facing transactions of any of `categoryIds` in `start...end`.
    func transactions(forCategoryIds categoryIds: Set<Int64>, from startDate: Date, to endDate: Date) -> [Transaction]
    /// The transactions in `start...end` a Totals row sums.
    func totalsTransactions(_ row: BudgetTotals.Row, from startDate: Date, to endDate: Date) -> [Transaction]
    /// The plan's occurrences filed under `category` in the calendar month.
    func occurrences(category: Category, year: Int, month: Int) -> [PlannedRow]
    /// The plan's occurrences in the calendar month a Totals row includes (reserves left out).
    func totalsOccurrences(_ row: BudgetTotals.Row, year: Int, month: Int) -> [PlannedRow]
    /// What's left of the reserves' allowances in the month, for a Totals panel (0 for Total in).
    func totalsReserved(_ row: BudgetTotals.Row, year: Int, month: Int) -> Int
}

/// A grid's side panel for the selected cell: `TransactionsSidePanel` with the cell's
/// transactions (Edit transaction and Add transaction… when given), then its planned
/// occurrences with Edit… / Remove… (`plannedOccurrenceEditing`), and for a Totals row the
/// reserves' remaining allowances as one line. Escape or ✕ closes it.
struct GridCellPanel<Model: GridCellPanelModel>: View {
    let target: GridCellTarget
    @ObservedObject var model: Model
    /// Add transaction… in the header (cells that list transactions only).
    var onAdd: (() -> Void)? = nil
    /// Each transaction's Edit transaction button; nil lists them read-only.
    var onEditTransaction: ((Transaction) -> Void)? = nil
    let onClose: () -> Void

    @State private var editing: PlannedRow?
    @State private var removing: PlannedRow?
    /// A failed Remove… (an Edit… failure shows in its own sheet).
    @State private var planError: String?

    /// The transactions listed: a Totals row's, else the cell's categories'.
    private var transactions: [Transaction] {
        if let row = target.totals { return model.totalsTransactions(row, from: target.start, to: target.end) }
        return model.transactions(forCategoryIds: target.categoryIds, from: target.start, to: target.end)
    }

    var body: some View {
        TransactionsSidePanel(
            title: target.title,
            transactions: transactions,
            categoryById: model.categoryById,
            showCategory: target.showCategory,
            accountNameById: model.accountNameById,
            transfers: model.transferCounterparts,
            conversion: model.conversion,
            showsTransactions: target.showsTransactions,
            onAdd: target.showsTransactions ? onAdd : nil,
            plannedSection: {
                if let plan = target.plan, model.panelShowsPlan {
                    plannedSection(plan)
                    if let row = plan.totals { reservedLine(row, plan: plan) }
                }
            },
            onEdit: onEditTransaction,
            onClose: onClose
        )
        // Another cell's panel: a stale Remove… error doesn't carry over.
        .onChange(of: target.title) { _, _ in planError = nil }
        .plannedOccurrenceEditing(editing: $editing, removing: $removing, planError: $planError,
                                  categories: model.categories, actions: model.planEditActions, accountOptions: model.planAccountOptions)
    }

    /// A Totals panel's reserves as one line: what's left of their allowances, as the Total
    /// reserved cell shows it (nothing when none is left).
    @ViewBuilder
    private func reservedLine(_ row: BudgetTotals.Row, plan: CellPlan) -> some View {
        let remaining = model.totalsReserved(row, year: plan.year, month: plan.month)
        if remaining != 0 {
            Section("Reserved") {
                HStack {
                    Text("Remaining allowances")
                    Spacer()
                    MoneyText(minorUnits: remaining)
                }
            }
        }
    }

    /// Every member's occurrences in the month, by date; aggregates name each one's category.
    private func plannedSection(_ plan: CellPlan) -> some View {
        let rows = plan.totals.map { model.totalsOccurrences($0, year: plan.year, month: plan.month) }
            ?? plan.categories
                .flatMap { model.occurrences(category: $0, year: plan.year, month: plan.month) }
                .sorted { $0.occurrence.date < $1.occurrence.date }
        return PlannedOccurrencesSection(
            rows: rows,
            inScenario: model.panelPlanIsScenario,
            compact: true,
            categoryNameById: plan.categories.count > 1 ? model.categoryNameById : nil,
            allowsEditing: model.panelAllowsPlanEditing,
            errorMessage: planError,
            onEdit: { row in planError = nil; editing = row },
            onRemove: { row in planError = nil; removing = row }
        )
    }
}
