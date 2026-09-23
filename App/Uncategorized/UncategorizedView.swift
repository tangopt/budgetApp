// App/Uncategorized/UncategorizedView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

struct UncategorizedView: View {
    @ObservedObject var viewModel: UncategorizedViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            Group {
                if viewModel.transactions.isEmpty {
                    VStack(spacing: 8) {
                        Text("Nothing uncategorized").font(.headline)
                        Text("Every committed transaction has a category. If you expected something here, check Import.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(viewModel.transactions) { transaction in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(transaction.rawDescription)
                                Text(transaction.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            MoneyText(minorUnits: transaction.amountMinorUnits)
                            categoryPicker(for: transaction).frame(width: 200)
                        }
                    }
                }
            }
        }
        .padding()
    }

    private func categoryPicker(for transaction: Transaction) -> some View {
        Picker("", selection: Binding<Int64?>(
            get: { transaction.categoryId },
            set: { newValue in
                guard let newValue else { return }
                viewModel.assignCategory(transaction, to: newValue)
            }
        )) {
            Text("Uncategorized").tag(Int64?.none)
            ForEach(viewModel.categories) { category in Text(category.name).tag(Int64?.some(category.id!)) }
        }
        .labelsHidden()
    }
}
