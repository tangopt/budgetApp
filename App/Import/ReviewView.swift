// App/Import/ReviewView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

struct ReviewView: View {
    @ObservedObject var viewModel: ImportViewModel
    let categories: [Category]
    let onCommitted: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            if viewModel.duplicateCount > 0 {
                Text("\(viewModel.duplicateCount) duplicate transaction(s) skipped")
                    .foregroundStyle(.secondary)
            }
            Table(viewModel.stagedRows) {
                TableColumn("Date") { row in Text(row.staged.parsed.date.formatted(date: .abbreviated, time: .omitted)) }
                TableColumn("Description") { row in Text(row.staged.parsed.rawDescription) }
                TableColumn("Amount") { row in Text(Money.format(row.staged.parsed.amountMinorUnits, currency: .gbp)) }
                TableColumn("Category") { row in
                    categoryPicker(for: row)
                }
                TableColumn("Source") { row in Text(row.staged.source.rawValue) }
            }
            Button("Confirm all \(viewModel.stagedRows.count) transactions") {
                try? viewModel.commit()
                onCommitted()
            }
            .disabled(viewModel.stagedRows.isEmpty)
        }
        .padding()
    }

    private func categoryPicker(for row: ReviewRow) -> some View {
        let binding = Binding<Int64?>(
            get: { row.chosenCategoryId },
            set: { newValue in
                if let index = viewModel.stagedRows.firstIndex(where: { $0.id == row.id }) {
                    viewModel.stagedRows[index].chosenCategoryId = newValue
                }
            }
        )
        return Picker("", selection: binding) {
            Text("Uncategorized").tag(Int64?.none)
            ForEach(categories) { category in Text(category.name).tag(Int64?.some(category.id!)) }
        }
        .labelsHidden()
    }
}
