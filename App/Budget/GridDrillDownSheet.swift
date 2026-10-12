// App/Budget/GridDrillDownSheet.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

/// The category and calendar month a month cell's drill-down lists planned occurrences for.
struct DrillDownPlan {
    let category: Category
    let year: Int
    let month: Int
}

enum GridDrillDownTarget: Identifiable {
    /// `plan` is nil for a Year Total cell (its drill-down lists transactions only).
    case transactions(title: String, transactions: [Transaction], plan: DrillDownPlan?)
    /// A reserve's month cell: planned occurrences only (reserves hold no transactions).
    case planned(title: String, plan: DrillDownPlan)

    var id: String {
        switch self {
        case .transactions(let title, let transactions, _):
            return "txn-\(title)-\(transactions.map { String($0.id ?? -1) }.joined(separator: ","))"
        case .planned(let title, let plan):
            return "plan-\(title)-\(plan.category.id ?? -1)"
        }
    }
}

struct GridDrillDownSheet: View {
    let target: GridDrillDownTarget
    @ObservedObject var viewModel: BudgetGridViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var editing: PlannedRow?
    @State private var removing: PlannedRow?
    /// A failed Remove… (an Edit… failure shows in its own sheet).
    @State private var planError: String?
    @State private var editingTransaction: Transaction?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }
            switch target {
            case .transactions(let title, let transactions, let plan):
                Text(title).font(.headline)
                List {
                    Section("Transactions") {
                        if transactions.isEmpty {
                            Text("No transactions in this cell.").foregroundStyle(.secondary)
                        }
                        ForEach(transactions) { transaction in
                            transactionRow(transaction)
                        }
                    }
                    if let plan { plannedSection(plan) }
                }
            case .planned(let title, let plan):
                Text(title).font(.headline)
                List { plannedSection(plan) }
            }
        }
        .padding()
        .frame(width: 560, height: 480)
        .plannedOccurrenceEditing(editing: $editing, removing: $removing, planError: $planError,
                                  categories: viewModel.categories, actions: viewModel.planEditActions)
        .sheet(item: $editingTransaction) { transaction in
            EditTransactionSheet(
                transaction: transaction,
                categories: viewModel.categories,
                groups: viewModel.categoryGroups,
                recentIds: [],
                createCategory: viewModel.createCategory,
                onSave: { categoryId, note in
                    guard let id = transaction.id else { return .failed("This transaction hasn't been saved yet.") }
                    return viewModel.editTransaction(id: id, categoryId: categoryId, note: note)
                }
            )
        }
    }

    private func plannedSection(_ plan: DrillDownPlan) -> some View {
        PlannedOccurrencesSection(
            rows: viewModel.occurrences(category: plan.category, year: plan.year, month: plan.month),
            errorMessage: planError,
            onEdit: { row in planError = nil; editing = row },
            onRemove: { row in planError = nil; removing = row }
        )
    }

    /// `target` is a snapshot frozen when the cell was tapped, so each row reads the live
    /// transaction from the view model — otherwise a saved edit would appear to snap back.
    private func transactionRow(_ snapshot: Transaction) -> some View {
        let transaction = viewModel.transactions.first(where: { $0.id == snapshot.id }) ?? snapshot
        let categoryName = transaction.categoryId.flatMap { id in viewModel.categories.first { $0.id == id }?.name } ?? "Uncategorized"
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.rawDescription)
                Text(transaction.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let note = transaction.note {
                NoteIcon(filled: true).help(note)
            }
            Spacer()
            MoneyText(minorUnits: transaction.amountMinorUnits)
            Text(categoryName)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
            Button("Edit…") { editingTransaction = transaction }
        }
    }
}
