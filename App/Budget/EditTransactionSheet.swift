// App/Budget/EditTransactionSheet.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

/// Edit transaction (spec §5): category (with "New category…") and note; date,
/// description and amount are shown read-only. Saving never learns a rule.
struct EditTransactionSheet: View {
    let transaction: Transaction
    let categories: [Category]
    let groups: [CategoryGroup]
    let recentIds: [Int64]
    let createCategory: CreateCategory
    /// Saves and reloads; `.failed` keeps the sheet open with the message.
    let onSave: (_ categoryId: Int64?, _ note: String?) -> SaveOutcome
    @Environment(\.dismiss) private var dismiss

    @State private var categoryId: Int64?
    @State private var note: String
    @State private var errorMessage: String?

    init(transaction: Transaction, categories: [Category], groups: [CategoryGroup], recentIds: [Int64],
         createCategory: @escaping CreateCategory, onSave: @escaping (Int64?, String?) -> SaveOutcome) {
        self.transaction = transaction
        self.categories = categories
        self.groups = groups
        self.recentIds = recentIds
        self.createCategory = createCategory
        self.onSave = onSave
        _categoryId = State(initialValue: transaction.categoryId)
        _note = State(initialValue: transaction.note ?? "")
    }

    private var isChanged: Bool {
        categoryId != transaction.categoryId || Transaction.normalizedNote(note) != transaction.note
    }

    var body: some View {
        Form {
            Text("Edit transaction").font(.headline)
            LabeledContent("Date", value: transaction.date.formatted(date: .abbreviated, time: .omitted))
            LabeledContent("Description", value: transaction.rawDescription)
            LabeledContent("Amount") { MoneyText(minorUnits: transaction.amountMinorUnits) }
            LabeledContent("Category") {
                CategoryPickerButton(
                    selection: $categoryId,
                    categories: categories,
                    groups: groups,
                    suggestedId: nil,
                    recentIds: recentIds,
                    amountMinorUnits: transaction.amountMinorUnits,
                    createCategory: createCategory
                )
                .frame(width: 220)
            }
            TextField("Note", text: $note, axis: .vertical)
                .lineLimit(1...4)
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .disabled(!isChanged)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onChange(of: categoryId) { _, _ in errorMessage = nil }
        .padding()
        .frame(width: 440)
    }

    private func save() {
        switch onSave(categoryId, note) {
        case .saved, .savedButReloadFailed: dismiss()
        case .failed(let message): errorMessage = message
        }
    }
}
