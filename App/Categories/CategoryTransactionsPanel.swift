// App/Categories/CategoryTransactionsPanel.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

/// The Categories screen's side panel (spec §4): the selected category's transactions in a
/// pay-month year (the current one by default, or All years), via `TransactionsSidePanel`,
/// with Edit… per transaction (EditTransactionSheet).
struct CategoryTransactionsPanel: View {
    let category: Category
    @ObservedObject var viewModel: CategoriesViewModel
    let onClose: () -> Void

    /// nil = All years.
    @State private var year: Int?
    @State private var editingTransaction: Transaction?
    /// Read when Edit… is clicked, for the sheet's picker.
    @State private var editingRecentIds: [Int64] = []

    init(category: Category, viewModel: CategoriesViewModel, onClose: @escaping () -> Void) {
        self.category = category
        self.viewModel = viewModel
        self.onClose = onClose
        _year = State(initialValue: viewModel.payCalendar.current.year)
    }

    var body: some View {
        let id = category.id ?? -1
        TransactionsSidePanel(
            title: category.name,
            transactions: viewModel.transactions(forCategoryId: id, year: year),
            transfers: viewModel.transferCounterparts,
            accessory: AnyView(yearPicker(id)),
            onEdit: { transaction in
                editingRecentIds = viewModel.recentCategoryIds()
                editingTransaction = transaction
            },
            onClose: onClose
        )
        // Another category: back to the current year.
        .onChange(of: category.id) { _, _ in year = viewModel.payCalendar.current.year }
        .sheet(item: $editingTransaction) { transaction in
            EditTransactionSheet(
                transaction: transaction,
                categories: viewModel.categories,
                groups: viewModel.groups,
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
    }

    private func yearPicker(_ id: Int64) -> some View {
        Picker("Year", selection: $year) {
            ForEach(viewModel.years(forCategoryId: id), id: \.self) { year in
                Text(String(year)).tag(Int?.some(year))
            }
            Divider()
            Text("All years").tag(Int?.none)
        }
        .labelsHidden()
        .fixedSize()
    }
}
