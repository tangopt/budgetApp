// App/Budget/BudgetCellPanel.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

/// The period a "Not assigned to an account" cell's panel lists (budget-totals spec §2): a
/// calendar month, or the whole year (`month` nil).
struct UnassignedPeriod {
    let year: Int
    let month: Int?
}

/// The Budget grid's side panel for the selected cell: the shared `GridCellPanel` (its
/// transactions, then the planned occurrences' Edit…/Remove…) plus each transaction's Edit…
/// (EditTransactionSheet) and Add transaction…; or, for a "Not assigned to an account" cell,
/// `UnassignedItemsPanel`.
struct BudgetCellPanel: View {
    let target: GridCellTarget
    @ObservedObject var viewModel: BudgetGridViewModel
    let onClose: () -> Void

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
        if let period = target.unassigned {
            UnassignedItemsPanel(title: target.title, period: period, viewModel: viewModel, onClose: onClose)
        } else {
            cellPanel
        }
    }

    private var cellPanel: some View {
        GridCellPanel(
            target: target,
            model: viewModel,
            onAdd: viewModel.accounts.isEmpty ? nil : {
                editingRecentIds = viewModel.recentCategoryIds()
                isAdding = true
            },
            onEditTransaction: { transaction in
                editingRecentIds = viewModel.recentCategoryIds()
                editingTransaction = transaction
            },
            onClose: onClose
        )
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
}

extension BudgetGridViewModel: GridCellPanelModel {
    var panelShowsPlan: Bool { showForecast }
    var panelPlanIsScenario: Bool { false }
    var panelAllowsPlanEditing: Bool { true }
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
    /// After Assign all to ▾: how many items were left out (transfers into that account).
    @State private var assignNote: String?

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
        .onChange(of: title) { _, _ in planError = nil; assignNote = nil }
        .plannedOccurrenceEditing(editing: $editing, removing: $removing, planError: $planError,
                                  categories: viewModel.categories, actions: viewModel.planEditActions, accountOptions: viewModel.planAccountOptions)
    }

    /// The count and total, and Assign all to ▾.
    private func header(_ rows: [PlannedRow]) -> some View {
        HStack {
            Text(rows.count == 1 ? "1 planned item" : "\(rows.count) planned items")
                .figureText()
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
            if let assignNote {
                Text(assignNote).foregroundStyle(.secondary).font(.callout)
            }
            if rows.isEmpty {
                Text("Every planned item here has an account.").foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(PayMonthFormat.longDay(row.occurrence.date)).figureText()
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

    /// The accounts by display name; picking one assigns every series behind `rows` to it. A
    /// single row's menu leaves out the account a transfer pays into; Assign all skips those
    /// rows and says how many.
    private func assignMenu(_ title: String, rows: [PlannedRow]) -> some View {
        Menu(title) {
            ForEach(viewModel.accounts) { account in
                if let id = account.id, rows.count != 1 || viewModel.canAssign(rows[0], to: id) {
                    Button(account.displayName) {
                        planError = nil
                        let skipped = rows.filter { !viewModel.canAssign($0, to: id) }.count
                        assignNote = skipped == 0 ? nil
                            : "\(skipped == 1 ? "1 transfer" : "\(skipped) transfers") into \(account.displayName) not assigned: an item can't pay into its own account."
                        if case .failed(let message) = viewModel.assignAccount(rows, to: id) { planError = message; assignNote = nil }
                    }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(viewModel.accounts.isEmpty)
    }
}
