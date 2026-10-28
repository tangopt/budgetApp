import SwiftUI
import BudgetCore
import struct BudgetCore.Category

/// Edit a transaction's category and note (step 7b). The choices are drafts: nothing is written until Save, Cancel
/// leaves the transaction as it was, and a refusal (a filed year, Edit lost) shows in the sheet and keeps the draft.
public struct TransactionEditSheet: View {
    let row: TransactionSearch.Row
    @ObservedObject var model: QuickEditModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.phoneTheme) private var theme
    @State private var categoryId: Int64?
    @State private var note: String
    @State private var saving = false

    public init(row: TransactionSearch.Row, model: QuickEditModel) {
        self.row = row
        self.model = model
        _categoryId = State(initialValue: row.transaction.categoryId)
        _note = State(initialValue: row.transaction.note ?? "")
    }

    public var body: some View {
        NavigationStack {
            TransactionEditForm(row: row, model: model, categoryId: $categoryId, note: $note)
                .navigationTitle("Edit transaction")
                .navigationBarTitleDisplayModeInline()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }
                            .disabled(saving)
                    }
                }
        }
        .presentationDetents([.large])
        .onDisappear { model.refusal = nil }
    }

    private func save() {
        saving = true
        Task {
            let saved = await model.save(transactionId: row.id, categoryId: categoryId, note: note)
            saving = false
            if saved { dismiss() }
        }
    }
}

/// The sheet's body (also what the snapshot route renders).
struct TransactionEditForm: View {
    let row: TransactionSearch.Row
    @ObservedObject var model: QuickEditModel
    @Binding var categoryId: Int64?
    @Binding var note: String
    @Environment(\.phoneTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let shown = TransactionDetailPresentation(row)
        let sections = CategoryPickerSections.build(categories: model.lists.categories, groups: model.lists.groups, suggestedId: nil, recentIds: [],
                                                    amountMinorUnits: nil, query: "", showAll: true)
        Form {
            if let refusal = model.refusal {
                Section { PadRefusalBanner(message: refusal) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    MoneyText(minorUnits: shown.amount.minorUnits, currency: shown.currency, role: shown.amount.role,
                              fit: .shrink(), font: .title.weight(.semibold))
                    Text(shown.description)
                        .mangoFont(.headline)
                        .lineLimit(3)
                        .truncationMode(.middle)
                    (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 6))) {
                        Text(shown.account.isEmpty ? "—" : shown.account)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        DateText(shown.date, font: .subheadline)
                    }
                    .mangoFont(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section("Category") {
                Picker("Category", selection: $categoryId) {
                    ForEach(sections) { section in
                        Section(section.title ?? "") {
                            ForEach(section.entries) { entry in
                                if case .pick(let id) = entry.action {
                                    Text(entry.title).tag(id)
                                }
                            }
                        }
                    }
                }
                .pushesPickerList()
                .accessibilityIdentifier("category-picker")
            }
            Section("Note") {
                TextField("Note", text: $note, prompt: Text("Optional"), axis: .vertical)
                    .lineLimit(1...5)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("note-field")
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.background)
    }
}

/// Presents the transaction a Month row opened (`QuickEditModel.monthDetail`), where editing is on.
struct MonthDetailSheet: ViewModifier {
    let model: QuickEditModel?

    func body(content: Content) -> some View {
        if let model {
            content.modifier(Host(model: model))
        } else {
            content
        }
    }

    private struct Host: ViewModifier {
        @ObservedObject var model: QuickEditModel

        func body(content: Content) -> some View {
            content.sheet(item: $model.monthDetail) { row in TransactionDetailSheet(row: row) }
        }
    }
}

extension View {
    /// A picker that pushes its list (iOS); the platform's own on the Mac, where MangoUI also builds for tests.
    func pushesPickerList() -> some View {
        #if os(iOS)
        pickerStyle(.navigationLink)
        #else
        self
        #endif
    }
}
