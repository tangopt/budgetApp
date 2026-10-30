import SwiftUI
import BudgetCore

/// What the read-only transaction sheet shows (iPhone spec §3.5, read parts only): amount, description, account,
/// date, category and note.
public struct TransactionDetailPresentation {
    public let description: String
    public let account: String
    public let date: Date
    /// "Uncategorised" when it has none.
    public let category: String
    /// Nil when there's no note (or only spaces).
    public let note: String?
    public let amount: (minorUnits: Int, role: MoneyRole)
    public let currency: Currency
    public let isUncategorised: Bool

    public init(_ row: TransactionSearch.Row) {
        let shown = TransactionRowPresentation(row)
        description = row.description
        account = row.accountName
        date = row.date
        category = row.categoryName.isEmpty ? "Uncategorised" : row.categoryName
        let trimmed = row.transaction.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        note = trimmed.isEmpty ? nil : trimmed
        amount = shown.amount
        currency = shown.currency
        isUncategorised = shown.isUncategorised
    }
}

/// What the transaction sheet is editing: the category and the note, as drafts. Nothing is written until Save; Cancel
/// drops them (design review I1, D7).
public struct TransactionDraft: Equatable, Sendable {
    public var categoryId: Int64?
    public var note: String

    public init(row: TransactionSearch.Row) {
        categoryId = row.transaction.categoryId
        note = row.transaction.note ?? ""
    }

    /// Whether Save would change anything (a note of spaces is no note).
    public func differs(from row: TransactionSearch.Row) -> Bool {
        func clean(_ text: String?) -> String { (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        return categoryId != row.transaction.categoryId || clean(note) != clean(row.transaction.note)
    }
}

/// The one transaction sheet (design review I1, D7): the amount large, the description, then account, date, category and
/// note. Where the user may edit it (`QuickEditModel.canEdit`) an Edit button turns the same sheet into a form in place
/// (Cancel / Save in the nav bar; nothing is written until Save, and a refusal shows in the form and keeps the draft);
/// otherwise there is no edit control at all. Large detent; Done closes it.
public struct TransactionDetailSheet: View {
    @State private var row: TransactionSearch.Row
    @Environment(\.dismiss) private var dismiss
    @Environment(\.phoneTheme) private var theme
    @Environment(\.quickEdit) private var quickEdit
    @State private var canEdit = false
    @State private var editing: Bool
    @State private var draft: TransactionDraft
    @State private var saving = false

    /// `startsEditing`: opens as the form (the snapshot route).
    public init(row: TransactionSearch.Row, startsEditing: Bool = false) {
        _row = State(initialValue: row)
        _editing = State(initialValue: startsEditing)
        _draft = State(initialValue: TransactionDraft(row: row))
    }

    public var body: some View {
        NavigationStack {
            Group {
                if editing, let quickEdit {
                    TransactionEditForm(row: row, model: quickEdit, categoryId: $draft.categoryId, note: $draft.note)
                } else {
                    TransactionDetailContent(row: row)
                }
            }
            .background(theme.background)
            .mangoNavigationTitle(editing ? "Edit transaction" : "Transaction")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                if editing {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { cancel() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }
                            .disabled(saving)
                            .accessibilityIdentifier("save-transaction")
                    }
                } else {
                    if canEdit {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Edit") { draft = TransactionDraft(row: row); editing = true }
                                .accessibilityIdentifier("edit-transaction")
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .demoBannerSlot()
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(editing && draft.differs(from: row))
        .task(id: row.id) { canEdit = await quickEdit?.canEdit(transactionId: row.id) ?? false }
        .onDisappear { quickEdit?.refusal = nil }
    }

    private func cancel() {
        draft = TransactionDraft(row: row)
        quickEdit?.refusal = nil
        editing = false
    }

    private func save() {
        guard let quickEdit else { return }
        saving = true
        Task {
            let saved = await quickEdit.save(transactionId: row.id, categoryId: draft.categoryId, note: draft.note)
            saving = false
            guard saved else { return }
            // Back to the read view with what was saved.
            if let fresh = await quickEdit.row(transactionId: row.id) { row = fresh }
            editing = false
        }
    }
}

/// The sheet's scrolling body (also what the snapshot route renders).
struct TransactionDetailContent: View {
    let row: TransactionSearch.Row

    var body: some View {
        let shown = TransactionDetailPresentation(row)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    MoneyText(minorUnits: shown.amount.minorUnits, currency: shown.currency, role: shown.amount.role,
                              fit: .shrink(), font: .largeTitle.weight(.semibold))
                    Text(shown.description)
                        .mangoFont(.title3, weight: .semibold)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Card {
                    DetailField(label: "Account") {
                        Text(shown.account.isEmpty ? "—" : shown.account)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    DetailField(label: "Date") {
                        DateText(shown.date)
                    }
                    Divider()
                    DetailField(label: "Category") {
                        HStack(spacing: 8) {
                            if let category = row.category {
                                CategoryBadge(category: category)
                            } else {
                                UncategorisedBadge()
                            }
                            Text(shown.category)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let note = shown.note {
                        Divider()
                        DetailField(label: "Note") {
                            Text(note)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

/// A label over its value, at least 44 pt tall.
private struct DetailField<Value: View>: View {
    let label: String
    let value: Value

    init(label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .mangoFont(.subheadline)
                .foregroundStyle(.secondary)
            value
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
