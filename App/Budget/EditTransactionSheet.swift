// App/Budget/EditTransactionSheet.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

/// Edit transaction (spec §5): category (with "New category…") and note; date,
/// description and amount are shown read-only. Saving never learns a rule. With `transfer`,
/// also the transaction's transfer link (spec §6): each linked leg with Unlink, or Link to
/// transfer… when it has none.
struct EditTransactionSheet: View {
    let transaction: Transaction
    let categories: [Category]
    let groups: [CategoryGroup]
    let recentIds: [Int64]
    let createCategory: CreateCategory
    /// Saves and reloads; `.failed` keeps the sheet open with the message.
    let onSave: (_ categoryId: Int64?, _ note: String?) -> SaveOutcome
    let transfer: TransferLinkActions?
    @Environment(\.dismiss) private var dismiss

    @State private var categoryId: Int64?
    @State private var note: String
    @State private var errorMessage: String?
    /// The transaction's linked legs, refreshed after Unlink / Link.
    @State private var counterparts: [TransferCounterpart]
    @State private var transferError: String?
    @State private var candidates: [TransferCandidate]?

    init(transaction: Transaction, categories: [Category], groups: [CategoryGroup], recentIds: [Int64],
         createCategory: @escaping CreateCategory, transfer: TransferLinkActions? = nil,
         onSave: @escaping (Int64?, String?) -> SaveOutcome) {
        self.transaction = transaction
        self.categories = categories
        self.groups = groups
        self.recentIds = recentIds
        self.createCategory = createCategory
        self.transfer = transfer
        self.onSave = onSave
        _categoryId = State(initialValue: transaction.categoryId)
        _note = State(initialValue: transaction.note ?? "")
        _counterparts = State(initialValue: transaction.id.flatMap { id in transfer?.counterparts(id) } ?? [])
    }

    private var isChanged: Bool {
        categoryId != transaction.categoryId || Transaction.normalizedNote(note) != transaction.note
    }

    var body: some View {
        SheetScaffold(title: "Edit transaction", error: errorMessage, width: 460, onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: isChanged, action: save)) {
            SheetForm {
                LabeledContent("Date", value: transaction.date.formatted(date: .abbreviated, time: .omitted))
                LabeledContent("Description") {
                    Text(transaction.rawDescription)
                        .textSelection(.enabled)
                }
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
                Button("Link to transfer…") { loadCandidates() }
                    .controlSize(.small)
                    .popover(isPresented: Binding(get: { candidates != nil }, set: { if !$0 { candidates = nil } })) {
                        candidateList
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
        switch onSave(categoryId, note) {
        case .saved, .savedButReloadFailed: dismiss()
        case .failed(let message): errorMessage = message
        }
    }
}
