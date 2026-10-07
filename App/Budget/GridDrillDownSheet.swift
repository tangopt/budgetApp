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

    var id: String {
        switch self {
        case .transactions(let title, let transactions, _):
            return "txn-\(title)-\(transactions.map { String($0.id ?? -1) }.joined(separator: ","))"
        }
    }
}

struct GridDrillDownSheet: View {
    let target: GridDrillDownTarget
    @ObservedObject var viewModel: BudgetGridViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var editing: BudgetGridViewModel.PlannedRow?
    @State private var removing: BudgetGridViewModel.PlannedRow?
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
                    if let plan {
                        PlannedOccurrencesSection(
                            rows: viewModel.occurrences(category: plan.category, year: plan.year, month: plan.month),
                            errorMessage: planError,
                            onEdit: { row in planError = nil; editing = row },
                            onRemove: { row in planError = nil; removing = row }
                        )
                    }
                }
            }
        }
        .padding()
        .frame(width: 560, height: 480)
        .sheet(item: $editing) { row in
            EditOccurrenceSheet(row: row, categories: viewModel.categories) { change, scope in
                switch scope {
                case .onlyThis: return viewModel.editOccurrence(row.occurrence, change: change)
                case .thisAndFollowing: return viewModel.editFollowing(row.occurrence, change: change)
                }
            }
        }
        .confirmationDialog("Remove this planned occurrence?", isPresented: Binding(
            get: { removing != nil },
            set: { if !$0 { removing = nil } }
        ), presenting: removing) { row in
            Button("Only this occurrence", role: .destructive) { remove(row, .onlyThis) }
            Button("This and all following", role: .destructive) { remove(row, .thisAndFollowing) }
            Button("Cancel", role: .cancel) { removing = nil }
        }
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

    private func remove(_ row: BudgetGridViewModel.PlannedRow, _ scope: PlanEditScope) {
        let change = OccurrenceChange(remove: true)
        let outcome: SaveOutcome
        switch scope {
        case .onlyThis: outcome = viewModel.editOccurrence(row.occurrence, change: change)
        case .thisAndFollowing: outcome = viewModel.editFollowing(row.occurrence, change: change)
        }
        removing = nil
        if case .failed(let message) = outcome { planError = message }
    }
}
