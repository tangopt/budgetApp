// App/Budget/AddTransactionSheet.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

/// Add transaction… (spec 2026-10-14 §2): a transaction entered by hand — account, date,
/// description, Money in / Money out, amount (in the account's currency), category (with
/// "New category…") and note. Saved confirmed when categorised, else left for review.
struct AddTransactionSheet: View {
    let accounts: [Account]
    let categories: [Category]
    let groups: [CategoryGroup]
    let recentIds: [Int64]
    let createCategory: CreateCategory
    /// Saves and reloads; `.failed` keeps the sheet open with the message.
    /// Saves the transaction; one that would change a filed return asks first (`.asks`, plan
    /// Task 14) and is saved again with the answer.
    let onSave: (ManualTransactionInput, FiledYearEditCheck.Resolution?) -> CheckedSaveOutcome
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ManualTransactionDraft
    @State private var categoryId: Int64?
    @State private var note = ""
    /// Save waiting on the filed-year question.
    @State private var filedYearQuestion: FiledYearPending?
    @State private var errorMessage: String?

    /// `accountId` and `categoryId` preselect (an unknown account falls back to the first).
    init(accounts: [Account], accountId: Int64?, categoryId: Int64? = nil, categories: [Category], groups: [CategoryGroup],
         recentIds: [Int64], createCategory: @escaping CreateCategory, onSave: @escaping (ManualTransactionInput, FiledYearEditCheck.Resolution?) -> CheckedSaveOutcome) {
        self.accounts = accounts
        self.categories = categories
        self.groups = groups
        self.recentIds = recentIds
        self.createCategory = createCategory
        self.onSave = onSave
        let account = accounts.first { $0.id == accountId } ?? accounts.first
        let category = categoryId.flatMap { id in categories.first { $0.id == id && $0.isAssignable } }
        _draft = State(initialValue: ManualTransactionDraft(accountId: account?.id, category: category))
        _categoryId = State(initialValue: category?.id)
    }

    var body: some View {
        SheetScaffold(title: "Add transaction", subtitle: "A transaction your imports don't have yet. A later import of the same transaction replaces it.",
                      error: errorMessage, width: 480, onCancel: { dismiss() },
                      primary: SheetAction("Add", isEnabled: draft.isValid, action: save)) {
            SheetForm {
                ManualTransactionFields(draft: $draft, accounts: accounts)
                LabeledContent("Category") {
                    CategoryPickerButton(
                        selection: $categoryId,
                        categories: categories,
                        groups: groups,
                        suggestedId: nil,
                        recentIds: recentIds,
                        amountMinorUnits: draft.isMoneyIn ? 1 : -1,
                        placeholder: "Uncategorized",
                        createCategory: createCategory
                    )
                    .frame(maxWidth: 260)
                }
                LabeledContent("Note") {
                    TextField("Note", text: $note, prompt: Text("Optional"), axis: .vertical)
                        .lineLimit(1...4)
                }
            }
        }
        .onChange(of: draft) { _, _ in errorMessage = nil }
        .onChange(of: categoryId) { _, _ in errorMessage = nil }
        .filedYearQuestion($filedYearQuestion)
    }

    private func save() {
        guard let input = draft.input(categoryId: categoryId, note: note) else { return }
        save(input, resolution: nil)
    }

    private func save(_ input: ManualTransactionInput, resolution: FiledYearEditCheck.Resolution?) {
        switch onSave(input, resolution) {
        case .done(.saved), .done(.savedButReloadFailed): dismiss()
        case .done(.failed(let message)): errorMessage = message
        case .asks(let question):
            errorMessage = nil
            filedYearQuestion = FiledYearPending(question: question) { answer in save(input, resolution: answer) }
        }
    }
}
