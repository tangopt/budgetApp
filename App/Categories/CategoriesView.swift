// App/Categories/CategoriesView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

/// The Categories screen (spec §4): Expenses / Income / Transfers sections, each with its
/// collapsible groups and Ungrouped, then the read-only Reserves. Categories multi-select
/// and drag onto a group (or Ungrouped) to move; right-click to move, rename, exclude from
/// the auto-forecast or delete. Selecting one category opens its transactions panel.
struct CategoriesView: View {
    @ObservedObject var viewModel: CategoriesViewModel

    @State private var search = ""
    @State private var selection: Set<Int64> = []
    /// Collapsed group rows, keyed "<type>-<group id>" or "<type>-ungrouped".
    @State private var collapsed: Set<String> = []
    /// The drop target under the pointer (same keys), highlighted.
    @State private var dropTarget: String?

    @State private var renamingGroupId: Int64?
    @State private var groupNameDraft = ""
    /// The group whose inline name field has focus (keyed by id, so moving from one
    /// group's field to another's never reads as "clicked away" from the new one).
    @FocusState private var focusedGroupId: Int64?
    @State private var deletingGroup: CategoryGroup?

    @State private var newCategoryDraft: NewCategoryDraft?
    @State private var renamingCategory: Category?
    @State private var deletingCategory: Category?

    /// The one selected (non-reserve) category, whose panel is open.
    private var panelCategory: Category? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return viewModel.categories.first { $0.id == id && !$0.isReserved }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = viewModel.errorMessage {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error).foregroundStyle(.red)
                    Spacer()
                    Button("Dismiss") { viewModel.errorMessage = nil }
                        .buttonStyle(.borderless)
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            HStack(spacing: 0) {
                list
                    .frame(maxWidth: .infinity)
                if let category = panelCategory {
                    Divider()
                    CategoryTransactionsPanel(category: category, viewModel: viewModel, onClose: { selection = [] })
                        .frame(width: 320)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: panelCategory == nil)
        }
        .searchable(text: $search, prompt: "Search categories and groups")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { addGroup() } label: { Label("Group", systemImage: "folder.badge.plus") }
                    .help("New group")
                Button { newCategoryDraft = NewCategoryDraft(type: .expense, groupId: nil) } label: { Label("Category", systemImage: "plus") }
                    .help("New category")
            }
        }
        .onAppear { viewModel.load() }
        .onChange(of: viewModel.categories) { _, categories in
            // A deleted category leaves the selection.
            let ids = Set(categories.compactMap(\.id))
            selection = selection.filter(ids.contains)
        }
        .onChange(of: focusedGroupId) { old, new in
            // Clicking away from the field being edited saves it.
            if let old, old != new, renamingGroupId == old { commitGroupRename(keepEditingOnFailure: false) }
        }
        .newCategorySheet(draft: $newCategoryDraft, groups: viewModel.groups, create: viewModel.createCategory) { category in
            if let id = category.id { selection = [id] }
        }
        .sheet(item: $renamingCategory) { category in
            ScenarioNameSheet(title: "Rename category", message: nil, actionLabel: "Rename", initialName: category.name) { name in
                guard let id = category.id else { return .failed("This category no longer exists.") }
                return viewModel.renameCategory(id: id, to: name)
            }
        }
        .confirmationDialog(
            "Delete the group “\(deletingGroup?.name ?? "")”?",
            isPresented: Binding(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } }),
            titleVisibility: .visible,
            presenting: deletingGroup
        ) { group in
            Button("Delete group", role: .destructive) {
                if let id = group.id { viewModel.deleteGroup(id: id) }
            }
        } message: { _ in
            Text("Its categories become ungrouped. No category is deleted.")
        }
        .confirmationDialog(
            "Delete the category “\(deletingCategory?.name ?? "")”?",
            isPresented: Binding(get: { deletingCategory != nil }, set: { if !$0 { deletingCategory = nil } }),
            titleVisibility: .visible,
            presenting: deletingCategory
        ) { category in
            Button("Delete category", role: .destructive) {
                if let id = category.id { viewModel.deleteCategory(id: id) }
            }
        } message: { _ in
            Text("Rules that file into it are deleted too.")
        }
    }

    // MARK: List

    private var list: some View {
        let searching = !search.trimmingCharacters(in: .whitespaces).isEmpty
        let reserves = viewModel.reserves(search: search)
        return List(selection: $selection) {
            ForEach(viewModel.sections(search: search)) { section in
                Section(section.title) {
                    ForEach(section.groups) { block in
                        let key = block.id
                        DisclosureGroup(isExpanded: expanded(key, forced: searching)) {
                            ForEach(block.categories) { categoryRow($0) }
                        } label: {
                            groupLabel(block.group, count: block.categories.count, type: section.type, key: key)
                        }
                    }
                    if !searching || !section.ungrouped.isEmpty {
                        let key = "\(section.type.rawValue)-ungrouped"
                        DisclosureGroup(isExpanded: expanded(key, forced: searching)) {
                            ForEach(section.ungrouped) { categoryRow($0) }
                        } label: {
                            dropRow(key: key, groupId: nil) {
                                countedName("Ungrouped", count: section.ungrouped.count)
                                Spacer()
                            }
                        }
                    }
                }
            }
            if !reserves.isEmpty {
                Section {
                    ForEach(reserves) { reserve in
                        HStack {
                            CategoryBadge(type: reserve.type, size: .medium, systemImage: "tray")
                            Text(reserve.name)
                            Spacer()
                        }
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Reserves")
                } footer: {
                    Text("Reserves are managed on the Budget grid.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            categoryMenu(Array(ids))
        }
    }

    private func expanded(_ key: String, forced: Bool) -> Binding<Bool> {
        Binding(
            get: { forced || !collapsed.contains(key) },
            set: { isExpanded in
                if isExpanded { collapsed.remove(key) } else { collapsed.insert(key) }
            }
        )
    }

    private func countedName(_ name: String, count: Int) -> some View {
        let suffix = Text(" · \(count)").foregroundStyle(.secondary)
        return Text("\(Text(name).fontWeight(.semibold))\(suffix)")
            .lineLimit(1)
    }

    /// A group row: name · count (or the inline rename field) and its ⋯ menu; a drop target.
    private func groupLabel(_ group: CategoryGroup, count: Int, type: CategoryType, key: String) -> some View {
        dropRow(key: key, groupId: group.id) {
            if renamingGroupId == group.id {
                TextField("Group name", text: $groupNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedGroupId, equals: group.id)
                    .onSubmit { commitGroupRename(keepEditingOnFailure: true) }
                    .onExitCommand { renamingGroupId = nil }
                    .frame(maxWidth: 240)
            } else {
                countedName(group.name, count: count)
            }
            Spacer()
            Menu {
                Button("Rename") { startGroupRename(group) }
                Button("Add category here") { newCategoryDraft = NewCategoryDraft(type: type, groupId: group.id) }
                Divider()
                Button("Delete…", role: .destructive) { deletingGroup = group }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Group actions")
        }
    }

    /// A group or Ungrouped row that dragged categories can be dropped on.
    private func dropRow<Content: View>(key: String, groupId: Int64?, @ViewBuilder content: () -> Content) -> some View {
        HStack { content() }
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(dropTarget == key ? 0.2 : 0))
            )
            .dropDestination(for: String.self) { items, _ in
                let ids = items.flatMap(CategoryDrag.ids(from:))
                guard !ids.isEmpty else { return false }
                viewModel.move(ids: ids, toGroupId: groupId)
                return true
            } isTargeted: { targeted in
                if targeted { dropTarget = key } else if dropTarget == key { dropTarget = nil }
            }
    }

    private func categoryRow(_ category: Category) -> some View {
        let id = category.id ?? -1
        return HStack {
            CategoryBadge(type: category.type, size: .medium, systemImage: category.type.symbolName)
            Text(category.name).lineLimit(1)
            if category.excludeFromAutoForecast {
                Image(systemName: "wand.and.sparkles.inverse")
                    .foregroundStyle(.secondary)
                    .help("Excluded from auto-forecast")
            }
            if category.type == .transfer && category.isExternalTransfer {
                Image(systemName: "arrow.up.forward.square")
                    .foregroundStyle(.secondary)
                    .help("Money goes to an account you don't import — never matched as a transfer")
            }
            Spacer()
            if let average = viewModel.averages[id] {
                MoneyText(minorUnits: average)
                    .help("Average per month over the last 12 pay months")
            } else {
                Text("—").foregroundStyle(.secondary)
                    .help("No transactions in the last 12 pay months")
            }
        }
        .tag(id)
        .draggable(CategoryDrag.payload(selection.contains(id) ? Array(selection) : [id])) {
            let count = selection.contains(id) ? selection.count : 1
            Label(count == 1 ? category.name : "\(count) categories", systemImage: "tag")
                .padding(6)
        }
    }

    /// Right-click on one or several categories (reserves aren't selectable, so never here).
    @ViewBuilder
    private func categoryMenu(_ ids: [Int64]) -> some View {
        let chosen = viewModel.categories.filter { c in c.id.map(ids.contains) == true && !c.isReserved }
        if !chosen.isEmpty {
            Menu("Move to group") {
                Button("Ungrouped") { viewModel.move(ids: chosen.compactMap(\.id), toGroupId: nil) }
                Divider()
                ForEach(viewModel.groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { group in
                    Button(group.name) { viewModel.move(ids: chosen.compactMap(\.id), toGroupId: group.id) }
                }
            }
            if chosen.count == 1, let category = chosen.first, let id = category.id {
                Button("Rename…") { renamingCategory = category }
                if category.type == .expense {
                    Toggle("Exclude from auto-forecast", isOn: Binding(
                        get: { category.excludeFromAutoForecast },
                        set: { viewModel.setExcludedFromAutoForecast(id: id, excluded: $0) }
                    ))
                }
                if category.type == .transfer {
                    Toggle("Money goes to an account you don't import — never match", isOn: Binding(
                        get: { category.isExternalTransfer },
                        set: { viewModel.setExternalTransfer(id: id, external: $0) }
                    ))
                }
                Divider()
                Button("Delete…", role: .destructive) { deletingCategory = category }
            }
        }
    }

    // MARK: Groups

    private func addGroup() {
        guard let group = viewModel.createGroup() else { return }
        search = ""
        collapsed.remove("\(CategoryType.expense.rawValue)-\(group.id ?? -1)")
        startGroupRename(group)
    }

    private func startGroupRename(_ group: CategoryGroup) {
        // Another group's field is open: save its draft first (as clicking away would).
        if let current = renamingGroupId, current != group.id { commitGroupRename(keepEditingOnFailure: false) }
        groupNameDraft = group.name
        renamingGroupId = group.id
        // The field appears on the next pass; focus it then.
        let id = group.id
        DispatchQueue.main.async { focusedGroupId = id }
    }

    /// Saves the inline name; an unchanged name just ends editing. A refused one shows the
    /// banner message and, on Return, keeps the field open; clicking away abandons it.
    private func commitGroupRename(keepEditingOnFailure: Bool) {
        guard let id = renamingGroupId else { return }
        if viewModel.groups.first(where: { $0.id == id })?.name == groupNameDraft {
            renamingGroupId = nil
            return
        }
        if viewModel.renameGroup(id: id, to: groupNameDraft) || !keepEditingOnFailure {
            renamingGroupId = nil
        } else {
            DispatchQueue.main.async { focusedGroupId = id }
        }
    }
}

/// Dragged category ids travel as a tagged string, so stray dropped text is ignored.
enum CategoryDrag {
    private static let prefix = "budget-category-ids:"

    static func payload(_ ids: [Int64]) -> String {
        prefix + ids.sorted().map(String.init).joined(separator: ",")
    }

    static func ids(from payload: String) -> [Int64] {
        guard payload.hasPrefix(prefix) else { return [] }
        return payload.dropFirst(prefix.count).split(separator: ",").compactMap { Int64($0) }
    }
}

extension CategoryType {
    /// The Categories screen's row icon.
    var symbolName: String {
        switch self {
        case .expense: return "arrow.up.right"
        case .income: return "arrow.down.left"
        case .transfer: return "arrow.left.arrow.right"
        }
    }
}
