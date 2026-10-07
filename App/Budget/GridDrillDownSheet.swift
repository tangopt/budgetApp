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
    }

    private func plannedSection(_ plan: DrillDownPlan) -> some View {
        PlannedOccurrencesSection(
            rows: viewModel.occurrences(category: plan.category, year: plan.year, month: plan.month),
            errorMessage: planError,
            onEdit: { row in planError = nil; editing = row },
            onRemove: { row in planError = nil; removing = row }
        )
    }

    private func transactionRow(_ transaction: Transaction) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.rawDescription)
                Text(transaction.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            MoneyText(minorUnits: transaction.amountMinorUnits)
            // `target` is a snapshot frozen when the cell was tapped, so the picker reads the
            // live category from the view model — otherwise a successful recategorize would
            // appear to snap back to the old category.
            Picker("", selection: Binding<Int64?>(
                get: { viewModel.transactions.first(where: { $0.id == transaction.id })?.categoryId ?? transaction.categoryId },
                set: { newValue in
                    guard let newValue else { return }
                    viewModel.recategorize(transaction, to: newValue)
                }
            )) {
                ForEach(viewModel.categories.filter(\.isAssignable)) { category in Text(category.name).tag(Int64?.some(category.id!)) }
            }
            .labelsHidden()
            .frame(width: 180)
        }
    }
}
