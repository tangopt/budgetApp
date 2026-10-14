// App/Budget/EditTransactionSheet.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

/// Edit transaction (spec §5): category (with "New category…") and note; date,
/// description and amount are shown read-only. Saving never learns a rule. With `transfer`,
/// also the transaction's transfer link (spec §6): each linked leg with Unlink, or Link to
/// transfer… when it has none, plus Add the other side… when it's uncategorised or in a
/// (non-external) transfer category (spec 2026-10-14 §2). With `manual`, a transaction
/// added by hand also has its account, date, description and amount editable, and Delete….
struct EditTransactionSheet: View {
    let transaction: Transaction
    let categories: [Category]
    let groups: [CategoryGroup]
    let recentIds: [Int64]
    let createCategory: CreateCategory
    /// Saves and reloads; `.failed` keeps the sheet open with the message.
    let onSave: (_ categoryId: Int64?, _ note: String?) -> SaveOutcome
    let transfer: TransferLinkActions?
    /// Edit and Delete… for a transaction added by hand; nil (or an imported transaction)
    /// keeps those fields read-only.
    let manual: ManualTransactionActions?
    @Environment(\.dismiss) private var dismiss

    @State private var categoryId: Int64?
    @State private var note: String
    @State private var errorMessage: String?
    /// The transaction's linked legs, refreshed after Unlink / Link.
    @State private var counterparts: [TransferCounterpart]
    @State private var transferError: String?
    @State private var candidates: [TransferCandidate]?
    /// A manual transaction's account, date, description and amount.
    @State private var draft: ManualTransactionDraft
    @State private var confirmingDelete = false

    init(transaction: Transaction, categories: [Category], groups: [CategoryGroup], recentIds: [Int64],
         createCategory: @escaping CreateCategory, transfer: TransferLinkActions? = nil,
         manual: ManualTransactionActions? = nil,
         onSave: @escaping (Int64?, String?) -> SaveOutcome) {
        self.transaction = transaction
        self.categories = categories
        self.groups = groups
        self.recentIds = recentIds
        self.createCategory = createCategory
        self.transfer = transfer
        self.manual = manual
        self.onSave = onSave
        _draft = State(initialValue: ManualTransactionDraft(transaction))
        _categoryId = State(initialValue: transaction.categoryId)
        _note = State(initialValue: transaction.note ?? "")
        _counterparts = State(initialValue: transaction.id.flatMap { id in transfer?.counterparts(id) } ?? [])
    }

    /// A transaction added by hand, with the actions to edit it.
    private var editsManually: Bool {
        transaction.isManual && transaction.id != nil && manual != nil
    }

    private var isChanged: Bool {
        categoryId != transaction.categoryId || Transaction.normalizedNote(note) != transaction.note
            || (editsManually && draft != ManualTransactionDraft(transaction))
    }

    private var canSave: Bool {
        isChanged && (!editsManually || draft.isValid)
    }

    /// The sign the category picker filters by: the entered direction for a manual transaction.
    private var pickerAmount: Int {
        editsManually ? (draft.isMoneyIn ? 1 : -1) : transaction.amountMinorUnits
    }

    var body: some View {
        SheetScaffold(title: "Edit transaction", subtitle: transaction.isManual ? "Added by hand" : nil,
                      error: errorMessage, width: editsManually ? 480 : 460, onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: canSave, action: save),
                      destructive: editsManually ? SheetAction("Delete…") { confirmingDelete = true } : nil) {
            SheetForm {
                if editsManually, let manual {
                    ManualTransactionFields(draft: $draft, accounts: manual.accounts)
                } else {
                    LabeledContent("Date", value: transaction.date.formatted(date: .abbreviated, time: .omitted))
                    LabeledContent("Description") {
                        Text(transaction.rawDescription)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Amount") { MoneyText(minorUnits: transaction.amountMinorUnits) }
                }
                LabeledContent("Category") {
                    CategoryPickerButton(
                        selection: $categoryId,
                        categories: categories,
                        groups: groups,
                        suggestedId: nil,
                        recentIds: recentIds,
                        amountMinorUnits: pickerAmount,
                        createCategory: createCategory
                    )
                    .frame(maxWidth: 260)
                    .onChange(of: categoryId) { _, _ in errorMessage = nil }
                }
                LabeledContent("Note") {
                    TextField("Note", text: $note, prompt: Text("Optional"), axis: .vertical)
                        .lineLimit(1...4)
                }
                if transfer != nil, transaction.id != nil {
                    LabeledContent("Transfer") { transferContent }
                }
            }
        }
        .onChange(of: draft) { _, _ in errorMessage = nil }
        .alert("Delete this transaction?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(transaction.rawDescription)” will be removed, along with any transfer link. This can't be undone.")
        }
    }

    /// Add the other side… applies to a transaction that's uncategorised or in a transfer
    /// category that isn't for an account you don't import (`ManualTransactions.addOtherSide`).
    private var canAddOtherSide: Bool {
        guard let id = transaction.categoryId else { return true }
        guard let category = categories.first(where: { $0.id == id }) else { return false }
        return category.type == .transfer && !category.isExternalTransfer
    }

    /// The accounts the other side can be in: every account but this transaction's.
    private var otherSideAccounts: [Account] {
        (transfer?.accounts ?? []).filter { $0.id != transaction.accountId }
    }

    @ViewBuilder
    private var transferContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(counterparts) { counterpart in
                HStack {
                    Text(TransferFormat.line(counterpart))
                        .help(counterpart.origin == .auto ? "Matched automatically" : "Linked by you")
                    Spacer()
                    Button("Unlink") { unlink(counterpart) }
                        .controlSize(.small)
                        .help("Count both transactions in the budget again")
                }
            }
            if counterparts.isEmpty {
                HStack(spacing: 8) {
                    Button("Link to transfer…") { loadCandidates() }
                        .controlSize(.small)
                        .popover(isPresented: Binding(get: { candidates != nil }, set: { if !$0 { candidates = nil } })) {
                            candidateList
                        }
                    if canAddOtherSide, !otherSideAccounts.isEmpty {
                        Menu("Add the other side…") {
                            Section("Add the other side in") {
                                ForEach(otherSideAccounts) { account in
                                    Button(account.displayName) { addOtherSide(in: account) }
                                }
                            }
                        }
                        .controlSize(.small)
                        .fixedSize()
                        .help("Add this transfer's other leg by hand in another account, linked to this one")
                    }
                }
            }
            if let transferError {
                Text(transferError).font(.callout).foregroundStyle(.red)
            }
        }
    }

    /// The candidates (opposite sign, another account, ±7 days and ±3% — or the same pay
    /// month for spreadsheet history), each with Link.
    private var candidateList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Link to transfer").font(.headline)
            if candidates?.isEmpty ?? true {
                Text("No matching transaction in your other accounts.")
                    .foregroundStyle(.secondary)
            }
            ForEach(candidates ?? []) { candidate in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.rawDescription).lineLimit(1)
                        Text("\(candidate.accountName) · \(candidate.date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    MoneyText(minorUnits: candidate.amountMinorUnits, currency: candidate.currency)
                    Button("Link") { link(candidate) }
                        .controlSize(.small)
                }
            }
        }
        .popoverPadding()
        .frame(width: 420)
    }

    private func loadCandidates() {
        guard let transfer, let id = transaction.id else { return }
        transferError = nil
        do {
            candidates = try transfer.candidates(id)
        } catch {
            transferError = "Couldn't look for transfers: \(error.localizedDescription)"
        }
    }

    private func addOtherSide(in account: Account) {
        guard let transfer, let id = transaction.id, let accountId = account.id else { return }
        candidates = nil
        apply(transfer.addOtherSide(id, accountId))
    }

    private func unlink(_ counterpart: TransferCounterpart) {
        guard let transfer else { return }
        apply(transfer.unlink(counterpart.linkId))
    }

    private func link(_ candidate: TransferCandidate) {
        guard let transfer, let id = transaction.id else { return }
        candidates = nil
        apply(transfer.link(id, candidate.transactionId))
    }

    private func apply(_ outcome: SaveOutcome) {
        guard let transfer, let id = transaction.id else { return }
        switch outcome {
        case .saved, .savedButReloadFailed:
            transferError = nil
            counterparts = transfer.counterparts(id)
        case .failed(let message):
            transferError = message
        }
    }

    private func save() {
        let outcome: SaveOutcome
        if editsManually, let manual, let id = transaction.id {
            guard let input = draft.input(categoryId: categoryId, note: note) else { return }
            outcome = manual.update(id, input)
        } else {
            outcome = onSave(categoryId, note)
        }
        switch outcome {
        case .saved, .savedButReloadFailed: dismiss()
        case .failed(let message): errorMessage = message
        }
    }
}

private extension EditTransactionSheet {
    func delete() {
        guard let manual, let id = transaction.id else { return }
        switch manual.delete(id) {
        case .saved, .savedButReloadFailed: dismiss()
        case .failed(let message): errorMessage = message
        }
    }
}
