// App/Budget/BudgetCellPanel.swift
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

/// The period a "Not assigned to an account" cell's panel lists (budget-totals spec §2): a
/// calendar month, or the whole year (`month` nil).
struct UnassignedPeriod {
    let year: Int
    let month: Int?
}

/// What a clicked Budget cell's side panel shows (spec §2): the transactions of
/// `categoryIds` in `start...end` (read live from the view model, so an edit shows at once),
/// then the planned occurrences of `plan` when set.
struct BudgetCellTarget {
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
    /// A "Not assigned to an account" cell: the unassigned planned items to assign instead.
    var unassigned: UnassignedPeriod? = nil
}

/// The Budget grid's side panel for the selected cell: `TransactionsSidePanel` plus the
/// planned occurrences' Edit…/Remove… and each transaction's Edit… (EditTransactionSheet).
struct BudgetCellPanel: View {
    let target: BudgetCellTarget
    @ObservedObject var viewModel: BudgetGridViewModel
    let onClose: () -> Void

    @State private var editing: PlannedRow?
    @State private var removing: PlannedRow?
    /// A failed Remove… (an Edit… failure shows in its own sheet).
    @State private var planError: String?
    @State private var editingTransaction: Transaction?
    /// Read when Edit… is clicked, for the sheet's picker.
    @State private var editingRecentIds: [Int64] = []
    /// Add transaction… is open.
    @State private var isAdding = false

    /// Add transaction…'s account: the one ticked in the account filter when exactly one is,
    /// else the first account.
    private var addAccountId: Int64? {
        viewModel.accountFilter.count == 1 ? viewModel.accountFilter.first : viewModel.accounts.first?.id
    }

    /// Add transaction…'s category: the cell's, when it's a single category's.
    private var addCategoryId: Int64? {
        target.categoryIds.count == 1 ? target.categoryIds.first : nil
    }

    /// The transactions listed: a Totals row's, else the cell's categories'.
    private var transactions: [Transaction] {
        if let row = target.totals { return viewModel.totalsTransactions(row, from: target.start, to: target.end) }
        return viewModel.transactions(forCategoryIds: target.categoryIds, from: target.start, to: target.end)
    }

    var body: some View {
        if let period = target.unassigned {
            UnassignedItemsPanel(title: target.title, period: period, viewModel: viewModel, onClose: onClose)
        } else {
            cellPanel
        }
    }

    private var cellPanel: some View {
        TransactionsSidePanel(
            title: target.title,
            transactions: transactions,
            categoryById: viewModel.categoryById,
            showCategory: target.showCategory,
            accountNameById: viewModel.accountNameById,
            transfers: viewModel.transferCounterparts,
            showsTransactions: target.showsTransactions,
            onAdd: target.showsTransactions && !viewModel.accounts.isEmpty ? {
                editingRecentIds = viewModel.recentCategoryIds()
                isAdding = true
            } : nil,
            plannedSection: {
                // The filter's accounts' items only, each naming its account (spec 2026-10-15 §3);
                // none with Show forecast off (actuals only).
                if let plan = target.plan, viewModel.showForecast { plannedSection(plan) }
            },
            onEdit: { transaction in
                editingRecentIds = viewModel.recentCategoryIds()
                editingTransaction = transaction
            },
            onClose: onClose
        )
        // Another cell's panel: a stale Remove… error doesn't carry over.
        .onChange(of: target.title) { _, _ in planError = nil }
        .plannedOccurrenceEditing(editing: $editing, removing: $removing, planError: $planError,
                                  categories: viewModel.categories, actions: viewModel.planEditActions, accountOptions: viewModel.planAccountOptions)
        .sheet(item: $editingTransaction) { transaction in
            EditTransactionSheet(
                transaction: transaction,
                categories: viewModel.categories,
                groups: viewModel.categoryGroups,
                recentIds: editingRecentIds,
                createCategory: viewModel.createCategory,
                transfer: viewModel.transferActions,
                manual: viewModel.manualActions,
                onSave: { changes in
                    guard let id = transaction.id else { return .failed("This transaction hasn't been saved yet.") }
                    return viewModel.saveTransactionEdit(id: id, changes: changes)
                }
            )
        }
        .sheet(isPresented: $isAdding) {
            AddTransactionSheet(
                accounts: viewModel.accounts,
                accountId: addAccountId,
                categoryId: addCategoryId,
                categories: viewModel.categories,
                groups: viewModel.categoryGroups,
                recentIds: editingRecentIds,
                createCategory: viewModel.createCategory,
                onSave: viewModel.addTransaction
            )
        }
    }

    /// Every member's occurrences in the month, by date; aggregates name each one's category.
    private func plannedSection(_ plan: CellPlan) -> some View {
        let rows = plan.totals.map { viewModel.totalsOccurrences($0, year: plan.year, month: plan.month) }
            ?? plan.categories
                .flatMap { viewModel.occurrences(category: $0, year: plan.year, month: plan.month) }
                .sorted { $0.occurrence.date < $1.occurrence.date }
        return PlannedOccurrencesSection(
            rows: rows,
            compact: true,
            categoryNameById: plan.categories.count > 1 ? viewModel.categoryNameById : nil,
            errorMessage: planError,
            onEdit: { row in planError = nil; editing = row },
            onRemove: { row in planError = nil; removing = row }
        )
    }
}

/// A "Not assigned to an account" cell's panel (budget-totals spec §2): the period's planned
/// occurrences with no effective account (date, category, amount), each with Edit… and
/// Assign to ▾, and Assign all to ▾ in the header. Assigning sets the series' account
/// (`BudgetGridViewModel.assignAccount`); the list re-reads after the reload.
struct UnassignedItemsPanel: View {
    let title: String
    let period: UnassignedPeriod
    @ObservedObject var viewModel: BudgetGridViewModel
    let onClose: () -> Void

    @State private var editing: PlannedRow?
    @State private var removing: PlannedRow?
    @State private var planError: String?

    var body: some View {
        let rows = viewModel.unassignedRows(year: period.year, month: period.month)
        TransactionsSidePanel(
            title: title,
            transactions: [],
            showsTransactions: false,
            accessory: AnyView(header(rows)),
            plannedSection: { section(rows) },
            onEdit: { _ in },
            onClose: onClose
        )
        .onChange(of: title) { _, _ in planError = nil }
        .plannedOccurrenceEditing(editing: $editing, removing: $removing, planError: $planError,
                                  categories: viewModel.categories, actions: viewModel.planEditActions, accountOptions: viewModel.planAccountOptions)
    }

    /// The count and total, and Assign all to ▾.
    private func header(_ rows: [PlannedRow]) -> some View {
        HStack {
            Text(rows.count == 1 ? "1 planned item" : "\(rows.count) planned items")
            Spacer()
            MoneyText(minorUnits: rows.reduce(0) { $0 + $1.occurrence.amountMinorUnits })
            assignMenu("Assign all to", rows: rows)
                .disabled(rows.isEmpty)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func section(_ rows: [PlannedRow]) -> some View {
        Section("Not assigned to an account") {
            if let planError {
                Text(planError).foregroundStyle(.red).font(.callout)
            }
            if rows.isEmpty {
                Text("Every planned item here has an account.").foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(PayMonthFormat.longDay(row.occurrence.date))
                        Spacer()
                        MoneyText(minorUnits: row.occurrence.amountMinorUnits)
                    }
                    Text([PlanFormat.frequency(row.entry.frequency, interval: row.entry.interval), viewModel.categoryNameById[row.occurrence.categoryId] ?? ""]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack {
                        Spacer()
                        if !row.isConfirmed {
                            Button("Edit…") { planError = nil; editing = row }
                        }
                        assignMenu("Assign to", rows: [row])
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// The accounts by display name; picking one assigns every series behind `rows` to it.
    private func assignMenu(_ title: String, rows: [PlannedRow]) -> some View {
        Menu(title) {
            ForEach(viewModel.accounts) { account in
                if let id = account.id {
                    Button(account.displayName) {
                        planError = nil
                        if case .failed(let message) = viewModel.assignAccount(rows, to: id) { planError = message }
                    }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(viewModel.accounts.isEmpty)
    }
}
