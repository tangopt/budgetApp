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

    var body: some View {
        TransactionsSidePanel(
            title: target.title,
            transactions: viewModel.transactions(forCategoryIds: target.categoryIds, from: target.start, to: target.end),
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
                // Planned items have no account: none under an account filter (spec §7).
                if let plan = target.plan, !viewModel.isAccountFiltered { plannedSection(plan) }
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
                                  categories: viewModel.categories, actions: viewModel.planEditActions)
        .sheet(item: $editingTransaction) { transaction in
            EditTransactionSheet(
                transaction: transaction,
                categories: viewModel.categories,
                groups: viewModel.categoryGroups,
                recentIds: editingRecentIds,
                createCategory: viewModel.createCategory,
                transfer: viewModel.transferActions,
                manual: viewModel.manualActions,
                onSave: { categoryId, note in
                    guard let id = transaction.id else { return .failed("This transaction hasn't been saved yet.") }
                    return viewModel.editTransaction(id: id, categoryId: categoryId, note: note)
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
        let rows = plan.categories
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
