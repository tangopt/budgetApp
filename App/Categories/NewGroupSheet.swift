// App/Categories/NewGroupSheet.swift
import SwiftUI
import BudgetCore

/// What the New group sheet opens with: the categories selected on the Categories screen,
/// which it offers to move into the new group, and the starting type (the selection's section).
struct NewGroupDraft: Identifiable {
    let id = UUID()
    let selectedCategoryIds: [Int64]
    var type: CategoryType = .expense
}

/// The Categories screen's "+ Group" sheet (spec 2026-10-15): a required, unique name, its
/// type (Expenses / Income / Transfers: the section it shows in while empty) and,
/// when categories are selected, "Move the N selected categories into it" (unticked by
/// default). A refused name (`CategoryGroups.create`) shows inline and keeps the sheet open.
struct NewGroupSheet: View {
    let draft: NewGroupDraft
    /// Creates the group, moving `categoryIds` into it (through the filed-year check on `gate`),
    /// then calls back with it or a readable error.
    let create: CreateGroup
    let onCreated: (CategoryGroup) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type: CategoryType
    @State private var movesSelection = false
    @State private var errorMessage: String?
    /// Saves through the filed-year check (moving a property's categories); its question shows here.
    @StateObject private var gate = FiledYearGate()

    typealias CreateGroup = (_ name: String, _ type: CategoryType, _ categoryIds: [Int64], _ gate: FiledYearGate,
                             _ done: @escaping (Result<CategoryGroup, Error>) -> Void) -> Void

    init(draft: NewGroupDraft, create: @escaping CreateGroup,
         onCreated: @escaping (CategoryGroup) -> Void) {
        self.draft = draft
        self.create = create
        self.onCreated = onCreated
        _type = State(initialValue: draft.type)
    }

    private var selectedCount: Int { draft.selectedCategoryIds.count }

    var body: some View {
        SheetScaffold(title: "New group", error: errorMessage, onCancel: { dismiss() },
                      primary: SheetAction("Create group", isEnabled: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: save)) {
            SheetForm {
                LabeledContent("Name") {
                    TextField("Name", text: $name)
                        .onChange(of: name) { _, _ in errorMessage = nil }
                }
                LabeledContent("Type") {
                    Picker("Type", selection: $type) {
                        Text("Expenses").tag(CategoryType.expense)
                        Text("Income").tag(CategoryType.income)
                        Text("Transfers").tag(CategoryType.transfer)
                    }
                    .pickerStyle(.segmented).prominentTint()
                    .labelsHidden()
                    .fixedSize()
                }
                if selectedCount > 0 {
                    GridRow {
                        Text(verbatim: "")
                        Toggle(selectedCount == 1 ? "Move the selected category into it" : "Move the \(selectedCount) selected categories into it",
                               isOn: $movesSelection)
                            .toggleStyle(.checkbox)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .filedYearGate(gate)
    }

    private func save() {
        create(name, type, movesSelection ? draft.selectedCategoryIds : [], gate) { result in
            switch result {
            case .success(let group):
                onCreated(group)
                dismiss()
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }
}
