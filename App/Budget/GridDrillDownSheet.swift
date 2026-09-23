// App/Budget/GridDrillDownSheet.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

enum GridDrillDownTarget: Identifiable {
    case transactions(title: String, transactions: [Transaction])

    var id: String {
        switch self {
        case .transactions(let title, let transactions):
            return "txn-\(title)-\(transactions.map { String($0.id ?? -1) }.joined(separator: ","))"
        }
    }
}

struct GridDrillDownSheet: View {
    let target: GridDrillDownTarget
    let categories: [Category]
    var errorMessage: String? = nil
    /// The view model's current transactions. `target` is a snapshot frozen when the cell
    /// was tapped, so each row's picker reads its category from here instead — otherwise
    /// a successful recategorize would appear to snap back to the old category.
    var liveTransactions: [Transaction] = []
    let onRecategorize: (Transaction, Int64) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }
            switch target {
            case .transactions(let title, let transactions):
                Text(title).font(.headline)
                if transactions.isEmpty {
                    Text("No transactions in this cell.").foregroundStyle(.secondary)
                } else {
                    List(transactions) { transaction in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(transaction.rawDescription)
                                Text(transaction.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            MoneyText(minorUnits: transaction.amountMinorUnits)
                            Picker("", selection: Binding<Int64?>(
                                get: { liveTransactions.first(where: { $0.id == transaction.id })?.categoryId ?? transaction.categoryId },
                                set: { newValue in
                                    guard let newValue else { return }
                                    onRecategorize(transaction, newValue)
                                }
                            )) {
                                ForEach(categories) { category in Text(category.name).tag(Int64?.some(category.id!)) }
                            }
                            .labelsHidden()
                            .frame(width: 180)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(width: 420, height: 360)
    }
}
