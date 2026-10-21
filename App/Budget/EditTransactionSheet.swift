// App/Budget/EditTransactionSheet.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

/// Edit transaction (spec §5): category (with "New category…") and note; date,
/// description and amount are shown read-only. Saving never learns a rule. With `transfer`,
/// also the transaction's transfer link (spec §6): each linked leg with Unlink, or Link to
/// transfer… when it has none, plus Add the other side… when the chosen category is none or a
/// (non-external) transfer category (spec 2026-10-14 §2). With `manual`, a transaction
/// added by hand also has its account, date, description and amount editable, and Delete…
/// (which warns when the transaction has documents). Documents lists its linked documents
/// (spec 2026-10-16 §2), with Unlink, Link document… and a drop target; links and unlinks are
/// staged like the rest and written by Save (a dropped file is copied into the library at
/// once, and stays there unlinked after Cancel).
///
/// Nothing is written until Save: a transfer change is held (one at a time, previewed with
/// Undo), document links are staged, and Save writes them with the fields in one transaction
/// (`TransactionEditing.save`).
/// Cancel discards everything. Delete… is its own confirmed, immediate action.
struct EditTransactionSheet: View {
    let transaction: Transaction
    let categories: [Category]
    let groups: [CategoryGroup]
    let recentIds: [Int64]
    let createCategory: CreateCategory
    /// Saves everything in one write and reloads; `.failed` keeps the sheet open with the
    /// message (nothing was saved).
    let onSave: (TransactionEditChanges) -> SaveOutcome
    let transfer: TransferLinkActions?
    /// Edit and Delete… for a transaction added by hand; nil (or an imported transaction)
    /// keeps those fields read-only.
    let manual: ManualTransactionActions?
    @Environment(\.dismiss) private var dismiss

    @State private var categoryId: Int64?
    @State private var note: String
    @State private var errorMessage: String?
    /// The transaction's linked legs when the sheet opened.
    private let counterparts: [TransferCounterpart]
    @State private var transferError: String?
    @State private var candidates: [TransferCandidate]?
    /// The transfer change Save will write, if any.
    @State private var pendingTransfer: PendingTransfer?
    /// A manual transaction's account, date, description and amount.
    @State private var draft: ManualTransactionDraft
    @State private var confirmingDelete = false
    /// The stored EUR→GBP rate, read once when the sheet appears; nil = unknown (a
    /// cross-currency preview then leaves out the amount).
    @State private var eurToGbpRate: Double?
    /// The transaction's documents (spec 2026-10-16 §2), staged until Save.
    @StateObject private var documentsModel: TransactionDocumentsModel
    @ObservedObject private var documentCounts = TransactionDocumentCounts.shared

    /// A transfer change held until Save, with what the Transfer row previews.
    private enum PendingTransfer: Equatable {
        case addOtherSide(Account)
        case unlink(TransferCounterpart)
        case link(TransferCandidate)

        var change: PendingTransferChange? {
            switch self {
            case .addOtherSide(let account): return account.id.map { .addOtherSide(accountId: $0) }
            case .unlink(let counterpart): return .unlink(linkIds: [counterpart.linkId])
            case .link(let candidate): return .link(transactionId: candidate.transactionId)
            }
        }
    }

    init(transaction: Transaction, categories: [Category], groups: [CategoryGroup], recentIds: [Int64],
         createCategory: @escaping CreateCategory, transfer: TransferLinkActions? = nil,
         manual: ManualTransactionActions? = nil,
         onSave: @escaping (TransactionEditChanges) -> SaveOutcome) {
        self.transaction = transaction
        self.categories = categories
        self.groups = groups
        self.recentIds = recentIds
        self.createCategory = createCategory
        self.transfer = transfer
        self.manual = manual
        self.onSave = onSave
        counterparts = transaction.id.flatMap { id in transfer?.counterparts(id) } ?? []
        _draft = State(initialValue: ManualTransactionDraft(transaction))
        _categoryId = State(initialValue: transaction.categoryId)
        _note = State(initialValue: transaction.note ?? "")
        _documentsModel = StateObject(wrappedValue: TransactionDocumentsModel.make(transactionId: transaction.id))
    }

    /// The transaction's category when it's built in (a balance adjustment or market
    /// movement): shown read-only.
    private var builtInCategory: Category? {
        guard let id = transaction.categoryId else { return nil }
        return categories.first { $0.id == id && $0.isBuiltIn }
    }

    /// A transaction added by hand, with the actions to edit it.
    private var editsManually: Bool {
        transaction.isManual && transaction.id != nil && manual != nil
    }

    private var isChanged: Bool {
        categoryId != transaction.categoryId || Transaction.normalizedNote(note) != transaction.note
            || (editsManually && draft != ManualTransactionDraft(transaction))
            || pendingTransfer != nil
            || documentsModel.staging.hasChanges
    }

    private var canSave: Bool {
        isChanged && (!editsManually || draft.isValid) && pendingProblem == nil
    }

    /// Why the pending Add the other side… no longer applies to what's entered (Save is off
    /// until it's undone or fixed).
    private var pendingProblem: String? {
        guard case .addOtherSide(let account) = pendingTransfer else { return nil }
        if account.id == source.accountId { return "Pick a different account" }
        if !canAddOtherSide { return "Only transfers have another side — choose a transfer category" }
        return nil
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
                    LabeledContent("Amount") { MoneyText(minorUnits: transaction.amountMinorUnits, currency: transactionCurrency) }
                }
                if let builtIn = builtInCategory {
                    // Balance adjustments and market movements are the Accounts screen's.
                    LabeledContent("Category") {
                        HStack(spacing: 4) {
                            CategoryBadge(category: builtIn, size: .small)
                            Text(builtIn.name)
                        }
                        .help("Set by the Accounts screen; its category can't be changed here")
                    }
                } else {
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
                }
                LabeledContent("Note") {
                    TextField("Note", text: $note, prompt: Text("Optional"), axis: .vertical)
                        .lineLimit(1...4)
                }
                if transfer != nil, transaction.id != nil {
                    LabeledContent("Transfer") { transferContent }
                }
                if documentsModel.isAvailable {
                    LabeledContent("Documents") {
                        TransactionDocumentsSection(model: documentsModel, transactionName: transaction.rawDescription)
                    }
                    SheetFormNote("Document changes are saved with the transaction.")
                }
            }
        }
        .onChange(of: draft) { _, _ in errorMessage = nil }
        .onChange(of: pendingTransfer) { _, _ in errorMessage = nil }
        .onAppear { eurToGbpRate = transfer?.eurToGbpRate() }
        .alert("Delete this transaction?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }

    /// The delete confirmation's text: a transaction with documents says they stay in the
    /// library, unlinked.
    private var deleteMessage: String {
        let base = "“\(transaction.rawDescription)” will be removed, along with any transfer link"
        let count = documentCounts.count(transaction.id)
        guard count > 0 else { return base + ". This can't be undone." }
        let documents = count == 1 ? "its linked document" : "its \(count) linked documents"
        return base + ". It has \(count) document\(count == 1 ? "" : "s"): \(documents) will stay in the library but no longer be linked to it. This can't be undone."
    }

    /// Add the other side… applies while the chosen (possibly unsaved) category is none or a
    /// transfer category that isn't for an account you don't import (`ManualTransactions.addOtherSide`).
    private var canAddOtherSide: Bool {
        guard let id = categoryId else { return true }
        guard let category = categories.first(where: { $0.id == id }) else { return false }
        return category.type == .transfer && !category.isExternalTransfer
    }

    /// The account, day and signed amount Save will see: the entered ones for a manual transaction.
    private var source: (accountId: Int64, date: Date, amountMinorUnits: Int) {
        if editsManually {
            return (draft.accountId ?? transaction.accountId, draft.day, draft.signedAmountMinorUnits ?? transaction.amountMinorUnits)
        }
        return (transaction.accountId, transaction.date, transaction.amountMinorUnits)
    }

    /// The transaction's account's currency (its amount is stored in it); GBP when unknown.
    private var transactionCurrency: Currency {
        (transfer?.accounts ?? manual?.accounts ?? []).first { $0.id == transaction.accountId }?.currency ?? .gbp
    }

    /// The accounts the other side can be in: every account but this transaction's.
    private var otherSideAccounts: [Account] {
        let accountId = source.accountId
        return (transfer?.accounts ?? []).filter { $0.id != accountId }
    }

    @ViewBuilder
    private var transferContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(counterparts) { counterpart in
                if pendingTransfer != .unlink(counterpart) {
                    HStack {
                        Text(TransferFormat.line(counterpart))
                            .help(counterpart.origin == .auto ? "Matched automatically" : "Linked by you")
                        Spacer()
                        Button("Unlink") { pendingTransfer = .unlink(counterpart) }
                            .controlSize(.small)
                            .disabled(pendingTransfer != nil)
                            .help("Count both transactions in the budget again (on Save)")
                    }
                }
            }
            if let pendingTransfer {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preview(pendingTransfer))
                            .foregroundStyle(.secondary)
                            .italic()
                        if let pendingProblem {
                            Text(pendingProblem).font(.callout).foregroundStyle(.red)
                        }
                    }
                    Spacer()
                    Button("Undo") { self.pendingTransfer = nil }
                        .controlSize(.small)
                        .help("Keep the transfer as it is")
                }
            }
            if counterparts.isEmpty {
                HStack(spacing: 8) {
                    Button("Link to transfer…") { loadCandidates() }
                        .controlSize(.small)
                        .disabled(pendingTransfer != nil)
                        .popover(isPresented: Binding(get: { candidates != nil }, set: { if !$0 { candidates = nil } })) {
                            candidateList
                        }
                    if canAddOtherSide, !otherSideAccounts.isEmpty {
                        Menu("Add the other side…") {
                            Section("Add the other side in") {
                                ForEach(otherSideAccounts) { account in
                                    Button(account.displayName) { pendingTransfer = .addOtherSide(account) }
                                }
                            }
                        }
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(pendingTransfer != nil)
                        .help("Add this transfer's other leg by hand in another account, linked to this one (on Save)")
                    }
                }
            }
            if let transferError {
                Text(transferError).font(.callout).foregroundStyle(.red)
            }
        }
    }

    /// "↔ will add to <account> · <date> · <amount>", "Will unlink from …", "Will link to …".
    private func preview(_ pending: PendingTransfer) -> String {
        switch pending {
        case .addOtherSide(let account):
            let source = source
            let sourceCurrency = transfer?.accounts.first { $0.id == source.accountId }?.currency
            // Across currencies without a known rate, the amount is left out rather than guessed.
            guard let sourceCurrency, let rate = sourceCurrency == account.currency ? 1 : eurToGbpRate else {
                return "↔ will add to \(account.displayName) · \(source.date.formatted(date: .abbreviated, time: .omitted))"
            }
            let amount = ManualTransactions.otherSideAmount(source.amountMinorUnits, from: sourceCurrency, to: account.currency, rate: rate)
            return "↔ will add to " + TransferFormat.details(account: account.displayName, date: source.date,
                                                             amountMinorUnits: amount, currency: account.currency)
        case .unlink(let counterpart):
            return "Will unlink from " + TransferFormat.details(account: counterpart.accountName, date: counterpart.date,
                                                                amountMinorUnits: counterpart.amountMinorUnits, currency: counterpart.currency)
        case .link(let candidate):
            return "Will link to " + TransferFormat.details(account: candidate.accountName, date: candidate.date,
                                                            amountMinorUnits: candidate.amountMinorUnits, currency: candidate.currency)
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
                        // The account truncates; the day never does.
                        HStack(spacing: 0) {
                            Text("\(candidate.accountName) · ").lineLimit(1)
                            Text(candidate.date.formatted(date: .abbreviated, time: .omitted)).figureText()
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    MoneyText(minorUnits: candidate.amountMinorUnits, currency: candidate.currency)
                    Button("Link") {
                        candidates = nil
                        pendingTransfer = .link(candidate)
                    }
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

    /// Writes the fields and the pending transfer change in one go; a refusal saves nothing.
    private func save() {
        var manualFields: TransactionEditChanges.ManualFields?
        if editsManually {
            guard let fields = draft.fields else { return }
            manualFields = fields
        }
        let changes = TransactionEditChanges(categoryId: categoryId, note: note, manual: manualFields,
                                             transfer: pendingTransfer?.change, documents: documentsModel.staging.changes)
        switch onSave(changes) {
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
