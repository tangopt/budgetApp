// App/DesignSystem/NewCategorySheet.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

/// Creates a category from its name, type and optional group, throwing a readable error
/// (`Categories.create`). Each owning view model supplies one and refreshes its own list.
typealias CreateCategory = (_ name: String, _ type: CategoryType, _ groupId: Int64?) throws -> Category

/// What the New category sheet opens with (spec §4).
struct NewCategoryDraft: Identifiable {
    let id = UUID()
    let name: String
    let type: CategoryType
    /// Preselected group (the Categories screen's "Add category here").
    var groupId: Int64? = nil

    /// The type follows the amount's sign: money in → income, otherwise expense.
    init(name: String, amountMinorUnits: Int?) {
        self.name = name
        self.type = (amountMinorUnits ?? 0) > 0 ? .income : .expense
    }

    init(name: String = "", type: CategoryType, groupId: Int64?) {
        self.name = name
        self.type = type
        self.groupId = groupId
    }
}

/// The category picker's "New category…" sheet: name, type and optional group. Saving
/// creates the category and hands it back to whatever opened the picker.
struct NewCategorySheet: View {
    let draft: NewCategoryDraft
    let groups: [CategoryGroup]
    let create: CreateCategory
    let onCreated: (Category) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var type: CategoryType
    @State private var groupId: Int64?
    @State private var errorMessage: String?

    init(draft: NewCategoryDraft, groups: [CategoryGroup], create: @escaping CreateCategory, onCreated: @escaping (Category) -> Void) {
        self.draft = draft
        self.groups = groups
        self.create = create
        self.onCreated = onCreated
        _name = State(initialValue: draft.name)
        _type = State(initialValue: draft.type)
        _groupId = State(initialValue: draft.groupId)
    }

    private var sortedGroups: [CategoryGroup] {
        groups.filter { $0.id != nil }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Text("New category").font(.headline)
            TextField("Name", text: $name)
            Picker("Type", selection: $type) {
                Text("Expense").tag(CategoryType.expense)
                Text("Income").tag(CategoryType.income)
                Text("Transfer").tag(CategoryType.transfer)
            }
            .pickerStyle(.segmented)
            Picker("Group", selection: $groupId) {
                Text("None").tag(Int64?.none)
                ForEach(sortedGroups) { group in Text(group.name).tag(Int64?.some(group.id!)) }
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onChange(of: name) { _, _ in errorMessage = nil }
        .padding()
        .frame(width: 360)
    }

    private func save() {
        do {
            let category = try create(name, type, groupId)
            onCreated(category)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension View {
    /// Presents the New category sheet while `draft` is set; `onCreated` gets the new
    /// category after a successful save.
    func newCategorySheet(draft: Binding<NewCategoryDraft?>, groups: [CategoryGroup], create: CreateCategory?,
                          onCreated: @escaping (Category) -> Void) -> some View {
        sheet(item: draft) { draft in
            if let create {
                NewCategorySheet(draft: draft, groups: groups, create: create, onCreated: onCreated)
            }
        }
    }
}
