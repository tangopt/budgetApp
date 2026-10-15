// App/Categories/NewGroupSheet.swift
import SwiftUI
import BudgetCore

/// What the New group sheet opens with: the categories selected on the Categories screen,
/// which it offers to move into the new group.
struct NewGroupDraft: Identifiable {
    let id = UUID()
    let selectedCategoryIds: [Int64]
}

/// The Categories screen's "+ Group" sheet (spec 2026-10-15): a required, unique name and,
/// when categories are selected, "Move the N selected categories into it" (unticked by
/// default). A refused name (`CategoryGroups.create`) shows inline and keeps the sheet open.
struct NewGroupSheet: View {
    let draft: NewGroupDraft
    /// Creates the group, moving `categoryIds` into it, or throws a readable error.
    let create: (_ name: String, _ categoryIds: [Int64]) throws -> CategoryGroup
    let onCreated: (CategoryGroup) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var movesSelection = false
    @State private var errorMessage: String?

    private var selectedCount: Int { draft.selectedCategoryIds.count }

    var body: some View {
        SheetScaffold(title: "New group", error: errorMessage, onCancel: { dismiss() },
                      primary: SheetAction("Create group", isEnabled: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: save)) {
            SheetForm {
                LabeledContent("Name") {
                    TextField("Name", text: $name)
                        .onChange(of: name) { _, _ in errorMessage = nil }
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
    }

    private func save() {
        do {
            let group = try create(name, movesSelection ? draft.selectedCategoryIds : [])
            onCreated(group)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
