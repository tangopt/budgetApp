// App/Categories/CategoryTransactionsPanel.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

/// What the Categories screen's side panel shows: one category, or a group's members.
struct CategoryPanelSubject: Equatable {
    /// Distinguishes a category from a group with the same id ("c-<id>" / "g-<id>").
    let key: String
    let title: String
    let categoryIds: Set<Int64>
}

/// The Categories screen's side panel (spec §4, groups 2026-10-15): the selected category's
/// (or group's member categories') transactions in a
/// pay-month year (the current one by default, or All years), via `TransactionsSidePanel`,
/// with Edit… per transaction (EditTransactionSheet).
struct CategoryTransactionsPanel: View {
    let subject: CategoryPanelSubject
    @ObservedObject var viewModel: CategoriesViewModel
    let onClose: () -> Void

    /// nil = All years.
    @State private var year: Int?
    @State private var editingTransaction: Transaction?
    /// Read when Edit… is clicked, for the sheet's picker.
    @State private var editingRecentIds: [Int64] = []

    init(subject: CategoryPanelSubject, viewModel: CategoriesViewModel, onClose: @escaping () -> Void) {
        self.subject = subject
        self.viewModel = viewModel
        self.onClose = onClose
        _year = State(initialValue: viewModel.payCalendar.current.year)
    }

    var body: some View {
        TransactionsSidePanel(
            title: subject.title,
            transactions: viewModel.transactions(forCategoryIds: subject.categoryIds, year: year),
            transfers: viewModel.transferCounterparts,
            conversion: viewModel.conversion,
            accessory: AnyView(yearPicker),
            onEdit: { transaction in
                editingRecentIds = viewModel.recentCategoryIds()
                editingTransaction = transaction
            },
            onClose: onClose
        )
        // Another category or group: back to the current year.
        .onChange(of: subject.key) { _, _ in year = viewModel.payCalendar.current.year }
        .sheet(item: $editingTransaction) { transaction in
            EditTransactionSheet(
                transaction: transaction,
                categories: viewModel.categories,
                groups: viewModel.groups,
                recentIds: editingRecentIds,
                createCategory: viewModel.createCategory,
                transfer: viewModel.transferActions,
                manual: viewModel.manualActions,
                onSave: { changes, resolution in
                    guard let id = transaction.id else { return .done(.failed("This transaction hasn't been saved yet.")) }
                    return viewModel.saveTransactionEdit(id: id, changes: changes, resolution: resolution)
                }
            )
        }
    }

    private var yearPicker: some View {
        Picker("Year", selection: $year) {
            ForEach(viewModel.years(forCategoryIds: subject.categoryIds), id: \.self) { year in
                Text(String(year)).tag(Int?.some(year))
            }
            Divider()
            Text("All years").tag(Int?.none)
        }
        .labelsHidden()
        .fixedSize()
    }
}
