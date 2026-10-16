// App/Categories/CategoriesView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

/// A selectable row of the Categories screen: a category, or a group row in one type
/// section (a mixed group shows in each section it has members in, so the type keeps the
/// rows distinct). Categories and groups never share an id space.
enum CategoryRowID: Hashable {
    case category(Int64)
    case group(Int64, CategoryType)

    var categoryId: Int64? {
        if case .category(let id) = self { return id }
        return nil
    }

    var groupId: Int64? {
        if case .group(let id, _) = self { return id }
        return nil
    }
}

/// The Categories screen (spec §4; groups 2026-10-15): Expenses / Income / Transfers
/// sections, each with its collapsible groups and Ungrouped, the read-only built-in
/// Adjustments, then the read-only Reserves. Categories multi-select and drag onto a group
/// (or Ungrouped) to move; a group selects on its own (clicking its chevron only
/// expands/collapses). Groups and categories share the right-click menu and keys: Rename…
/// (Return), Delete… (⌫/⌦); categories also move, change the icon (also by clicking its
/// badge), exclude from the auto-forecast and set a transfer category's linked account
/// (shown "↔ <account>" on its row); groups also Add category here…. Selecting one
/// category or group opens its transactions panel. The toolbar expands or collapses every
/// group; ⌥-click a chevron to toggle its whole section (expansion is remembered).
struct CategoriesView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var viewModel: CategoriesViewModel

    @State private var search = ""
    @State private var selection: Set<CategoryRowID> = []
    /// Collapsed group rows (`CategoryOutline`, keyed "<type>-<group id>" or
    /// "<type>-ungrouped"), remembered across launches.
    @AppStorage("categories.collapsedGroups") private var collapsedStore = ""
    /// The drop target under the pointer (same keys), highlighted.
    @State private var dropTarget: String?
    /// The group row under the pointer (same keys), whose ⋯ menu shows.
    @State private var hoveredGroupKey: String?
    /// A new group's row to scroll to; cleared once it has appeared (or after the retry).
    @State private var scrollTarget: CategoryRowID?
    /// Whether the scroll to `scrollTarget` has been retried after the groups changed.
    @State private var scrollRetried = false
    /// Bumped to scroll to `scrollTarget` (the list's ScrollViewReader watches it).
    @State private var scrollRequest = 0

    @State private var newGroupDraft: NewGroupDraft?
    @State private var newCategoryDraft: NewCategoryDraft?
    @State private var renaming: RenameTarget?
    @State private var deleting: DeleteTarget?
    /// The category whose badge shows the icon picker.
    @State private var iconPickerCategoryId: Int64?

    /// What Rename… renames.
    private enum RenameTarget: Identifiable {
        case category(Category)
        case group(CategoryGroup)

        var id: String {
            switch self {
            case .category(let category): return "c-\(category.id ?? -1)"
            case .group(let group): return "g-\(group.id ?? -1)"
            }
        }
    }

    /// What Delete… deletes, once confirmed.
    private enum DeleteTarget {
        case categories([Category])
        case group(CategoryGroup, memberCount: Int)
    }

    /// The selected categories' ids.
    private var selectedCategoryIds: [Int64] { selection.compactMap(\.categoryId) }

    /// The one selected (non-reserve) category or group, whose panel is open.
    private var panelSubject: CategoryPanelSubject? {
        guard selection.count == 1, let row = selection.first else { return nil }
        switch row {
        case .category(let id):
            guard let category = viewModel.categories.first(where: { $0.id == id && !$0.isReserved }) else { return nil }
            return CategoryPanelSubject(key: "c-\(id)", title: category.name, categoryIds: [id])
        case .group(let id, _):
            guard let group = viewModel.groups.first(where: { $0.id == id }) else { return nil }
            return CategoryPanelSubject(key: "g-\(id)", title: group.name,
                                        categoryIds: Set(viewModel.members(ofGroupId: id).compactMap(\.id)))
        }
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
                if let subject = panelSubject {
                    Divider()
                    CategoryTransactionsPanel(subject: subject, viewModel: viewModel, onClose: { selection = [] })
                        .frame(width: 320)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: panelSubject == nil)
        }
        .searchable(text: $search, prompt: "Search categories and groups")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { updateOutline { $0.expandAll() } } label: { Label("Expand all", systemImage: "rectangle.expand.vertical") }
                    .buttonStyle(.borderless)
                    .help("Expand all groups")
                    .disabled(isSearching)
                Button { updateOutline { $0.collapseAll(allRowKeys) } } label: { Label("Collapse all", systemImage: "rectangle.compress.vertical") }
                    .buttonStyle(.borderless)
                    .help("Collapse all groups")
                    .disabled(isSearching)
                Button {
                    newGroupDraft = NewGroupDraft(selectedCategoryIds: movableIds(selectedCategoryIds), type: newGroupType)
                } label: { Label("Group", systemImage: "folder.badge.plus") }
                    .help("New group")
                Button { newCategoryDraft = NewCategoryDraft(type: .expense, groupId: nil) } label: { Label("Category", systemImage: "plus") }
                    .help("New category")
            }
        }
        .onAppear { viewModel.load() }
        .onChange(of: viewModel.categories) { _, _ in reconcileSelection() }
        .onChange(of: viewModel.groups) { _, _ in
            reconcileSelection()
            // The new group's row may not have been listed yet: scroll to it once more.
            if scrollTarget != nil && !scrollRetried {
                scrollRetried = true
                scrollRequest += 1
            }
        }
        .onChange(of: selection) { old, new in
            // A group selects on its own: picking one clears the categories, and vice versa.
            guard new.count > 1, new.contains(where: { $0.groupId != nil }) else { return }
            if let group = new.subtracting(old).first(where: { $0.groupId != nil }) {
                selection = [group]
            } else {
                selection = new.filter { $0.groupId == nil }
            }
        }
        .sheet(item: $newGroupDraft) { draft in
            NewGroupSheet(draft: draft, create: { name, type, ids in try viewModel.createGroup(name: name, type: type, moving: ids) }) { group in
                reveal(group)
            }
        }
        .newCategorySheet(draft: $newCategoryDraft, groups: viewModel.groups, create: viewModel.createCategory) { category in
            if let id = category.id { selection = [.category(id)] }
        }
        .sheet(item: $renaming) { target in
            switch target {
            case .category(let category):
                ScenarioNameSheet(title: "Rename category", message: nil, actionLabel: "Rename", initialName: category.name) { name in
                    guard let id = category.id else { return .failed("This category no longer exists.") }
                    return viewModel.renameCategory(id: id, to: name)
                }
            case .group(let group):
                ScenarioNameSheet(title: "Rename group", message: nil, actionLabel: "Rename", initialName: group.name) { name in
                    guard let id = group.id else { return .failed("This group no longer exists.") }
                    return viewModel.renameGroup(id: id, to: name)
                }
            }
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { target in
            switch target {
            case .group(let group, _):
                Button("Delete group", role: .destructive) {
                    if let id = group.id { viewModel.deleteGroup(id: id) }
                }
            case .categories(let categories):
                Button(categories.count == 1 ? "Delete category" : "Delete categories", role: .destructive) {
                    viewModel.deleteCategories(ids: categories.compactMap(\.id))
                }
            }
        } message: { target in
            switch target {
            case .group(_, let count):
                Text(count == 0 ? "It has no categories."
                     : count == 1 ? "Its 1 category moves to Ungrouped."
                     : "Its \(count) categories move to Ungrouped.")
            case .categories(let categories):
                Text(categories.count == 1 ? "Rules that file into it are deleted too."
                     : "Rules that file into them are deleted too. Any still in use are kept and listed.")
            }
        }
    }

    private var deleteTitle: String {
        switch deleting {
        case .group(let group, _): return "Delete the group “\(group.name)”?"
        case .categories(let categories) where categories.count == 1: return "Delete the category “\(categories[0].name)”?"
        case .categories(let categories): return "Delete \(categories.count) categories?"
        case nil: return ""
        }
    }

    // MARK: List

    private var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The collapsed rows, from their stored string.
    private var outline: CategoryOutline { CategoryOutline(string: collapsedStore) }

    private func updateOutline(_ change: (inout CategoryOutline) -> Void) {
        var updated = outline
        change(&updated)
        collapsedStore = updated.string
    }

    /// A section's collapsible rows' keys: its groups, then Ungrouped.
    private func rowKeys(_ section: CategorySection) -> [String] {
        section.groups.map(\.id) + [ungroupedKey(section.type)]
    }

    private func ungroupedKey(_ type: CategoryType) -> String { "\(type.rawValue)-ungrouped" }

    /// Every collapsible row's key (Collapse all).
    private var allRowKeys: [String] {
        viewModel.sections(search: "").filter { $0.type != .adjustment }.flatMap(rowKeys)
    }

    /// The New group sheet's starting type: the selected group's or category's section,
    /// else Expenses.
    private var newGroupType: CategoryType {
        let types: [CategoryType] = selection.compactMap { row in
            switch row {
            case .group(_, let type): return type
            case .category(let id): return viewModel.categories.first { $0.id == id }?.type
            }
        }
        guard Set(types).count == 1, let type = types.first, type != .adjustment else { return .expense }
        return type
    }

    private var list: some View {
        let searching = isSearching
        let reserves = viewModel.reserves(search: search)
        return ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(viewModel.sections(search: search)) { section in
                    let sectionKeys = rowKeys(section)
                    if section.type == .adjustment {
                        adjustmentsSection(section)
                    } else {
                    Section(section.title) {
                        ForEach(section.groups) { block in
                            // A plain row with its own chevron button (not a DisclosureGroup), so
                            // clicking the row selects the group and only the chevron expands it.
                            let key = block.id
                            let row = CategoryRowID.group(block.group.id ?? -1, section.type)
                            groupLabel(block.group, count: block.categories.count, type: section.type, key: key,
                                       isExpanded: isExpanded(key, forced: searching), sectionKeys: sectionKeys)
                                .tag(row)
                                .id(row)
                                .onAppear { if scrollTarget == row { scrollTarget = nil } }
                            if isExpanded(key, forced: searching) {
                                ForEach(block.categories) { memberRow($0) }
                            }
                        }
                        if !searching || !section.ungrouped.isEmpty {
                            // Not selectable (no tag): a drop target and its chevron.
                            let key = ungroupedKey(section.type)
                            dropRow(key: key, groupId: nil) {
                                chevron(key, isExpanded: isExpanded(key, forced: searching), disabled: searching, sectionKeys: sectionKeys)
                                countedName("Ungrouped", count: section.ungrouped.count)
                                Spacer()
                            }
                            if isExpanded(key, forced: searching) {
                                ForEach(section.ungrouped) { memberRow($0) }
                            }
                        }
                    }
                    }
                }
                if !reserves.isEmpty {
                    Section {
                        ForEach(reserves) { reserve in
                            HStack {
                                CategoryBadge(category: reserve, size: .medium)
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
            .contextMenu(forSelectionType: CategoryRowID.self) { rows in
                rowMenu(rows)
            }
            .onKeyPress(keys: [.return]) { _ in
                renameSelection() ? .handled : .ignored
            }
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                deleteSelection() ? .handled : .ignored
            }
            .onChange(of: scrollRequest) { _, _ in
                // After the list has laid out the new row.
                DispatchQueue.main.async {
                    guard let row = scrollTarget else { return }
                    withAnimation { proxy.scrollTo(row, anchor: .center) }
                    if scrollRetried { scrollTarget = nil }
                }
            }
        }
    }

    /// The built-in Balance adjustment and Market movement (spec 2026-10-14 §1): selectable
    /// (their transactions panel opens) but never renamed, moved, re-iconed or deleted.
    private func adjustmentsSection(_ section: CategorySection) -> some View {
        Section {
            ForEach(section.ungrouped) { category in
                HStack {
                    CategoryBadge(category: category, size: .medium)
                    Text(category.name).lineLimit(1)
                    Spacer()
                    if let id = category.id, let average = viewModel.averages[id] {
                        MoneyText(minorUnits: average)
                            .help("Average per month over the last 12 pay months")
                    } else {
                        Text("—").foregroundStyle(.secondary)
                            .help("No transactions in the last 12 pay months")
                    }
                }
                .tag(CategoryRowID.category(category.id ?? -1))
            }
        } header: {
            Text(section.title)
        } footer: {
            Text("Built in: Update balance files the difference here. They can't be renamed, moved or deleted, and never count as income or spending.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The ids a drag from `id` carries: the selection when it includes `id`, built-in
    /// categories left out (they can't be moved).
    private func dragIds(_ id: Int64) -> [Int64] {
        movableIds(selection.contains(.category(id)) ? selectedCategoryIds : [id])
    }

    /// `ids` without built-in or reserve categories (they can't be moved).
    private func movableIds(_ ids: [Int64]) -> [Int64] {
        let fixed = Set(viewModel.categories.filter { $0.isBuiltIn || $0.isReserved }.compactMap(\.id))
        return ids.filter { !fixed.contains($0) }
    }

    /// Whether a group (or Ungrouped) row's categories show; always while searching.
    private func isExpanded(_ key: String, forced: Bool) -> Bool {
        forced || outline.isExpanded(key)
    }

    /// A group or Ungrouped row's expand/collapse button (the row itself selects); ⌥-click
    /// gives every row of the section (`sectionKeys`) the clicked row's new state.
    private func chevron(_ key: String, isExpanded: Bool, disabled: Bool, sectionKeys: [String]) -> some View {
        Button {
            let allInSection = NSEvent.modifierFlags.contains(.option)
            updateOutline { $0.toggle(key, allIn: allInSection ? sectionKeys : nil) }
        } label: {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeOut(duration: 0.15), value: isExpanded)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(isExpanded ? "Collapse (⌥-click: every group in this section)" : "Expand (⌥-click: every group in this section)")
        .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
    }

    /// A category under its group (or Ungrouped) row, indented past the chevron.
    private func memberRow(_ category: Category) -> some View {
        categoryRow(category)
            .padding(.leading, 22)
    }

    private func countedName(_ name: String, count: Int) -> some View {
        let suffix = Text(" · \(count)").foregroundStyle(.secondary)
        return Text("\(Text(name).fontWeight(.semibold))\(suffix)")
            .lineLimit(1)
    }

    /// A group row: name · count and its ⋯ menu (shown on hover or selection); a drop target.
    private func groupLabel(_ group: CategoryGroup, count: Int, type: CategoryType, key: String, isExpanded: Bool, sectionKeys: [String]) -> some View {
        let showsMenu = hoveredGroupKey == key || selection.contains(.group(group.id ?? -1, type))
        let searching = !search.trimmingCharacters(in: .whitespaces).isEmpty
        return dropRow(key: key, groupId: group.id) {
            chevron(key, isExpanded: isExpanded, disabled: searching, sectionKeys: sectionKeys)
            countedName(group.name, count: count)
            Spacer()
            Menu {
                groupMenu(group, type: type)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Group actions")
            .opacity(showsMenu ? 1 : 0)
            .allowsHitTesting(showsMenu)
            .accessibilityHidden(!showsMenu)
        }
        .onHover { hovering in
            if hovering { hoveredGroupKey = key } else if hoveredGroupKey == key { hoveredGroupKey = nil }
        }
        .accessibilityAction(named: "Rename") { renaming = .group(group) }
        .accessibilityAction(named: "Delete") { confirmDelete(group) }
        .accessibilityAction(named: "Add category here") { newCategoryDraft = NewCategoryDraft(type: type, groupId: group.id) }
    }

    /// A group's actions, in its ⋯ menu and on right-click.
    @ViewBuilder
    private func groupMenu(_ group: CategoryGroup, type: CategoryType) -> some View {
        Button("Rename…") { renaming = .group(group) }
        Button("Add category here…") { newCategoryDraft = NewCategoryDraft(type: type, groupId: group.id) }
        Divider()
        Button("Delete…", role: .destructive) { confirmDelete(group) }
    }

    /// A group or Ungrouped row that dragged categories can be dropped on.
    private func dropRow<Content: View>(key: String, groupId: Int64?, @ViewBuilder content: () -> Content) -> some View {
        HStack { content() }
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.accent.opacity(dropTarget == key ? 0.2 : 0))
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
            Button { iconPickerCategoryId = id } label: {
                CategoryBadge(category: category, size: .medium)
            }
            .buttonStyle(.plain)
            .help("Change icon")
            .popover(isPresented: iconPickerBinding(id), arrowEdge: .trailing) {
                CategoryIconPicker(type: category.type, current: category.iconName) { iconName in
                    iconPickerCategoryId = nil
                    viewModel.setIcon(id: id, iconName: iconName)
                }
            }
            Text(category.name).lineLimit(1)
            if category.excludeFromAutoForecast {
                flagLabel("No auto-forecast")
                    .help("Not detected automatically for the plan")
            }
            if category.type == .transfer && category.isExternalTransfer {
                flagLabel("Not matched")
                    .help("Money goes to an account you don't import — never matched as a transfer")
            }
            if let account = viewModel.linkedAccount(of: category) {
                flagLabel("↔ \(account.displayName)")
                    .help("Linked account: a transfer with \(account.displayName) is filed here")
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
        .tag(CategoryRowID.category(id))
        .draggable(CategoryDrag.payload(dragIds(id))) {
            let count = dragIds(id).count
            Label(count == 1 ? category.name : "\(count) categories", systemImage: "tag")
                .padding(6)
        }
    }

    /// A small secondary note after a category's name (e.g. "No auto-forecast").
    private func flagLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    /// Whether the icon picker is open on this category's badge.
    private func iconPickerBinding(_ id: Int64) -> Binding<Bool> {
        Binding(
            get: { iconPickerCategoryId == id },
            set: { isPresented in
                if isPresented { iconPickerCategoryId = id } else if iconPickerCategoryId == id { iconPickerCategoryId = nil }
            }
        )
    }

    /// Right-click: a group's menu, or the categories' (a group selects on its own).
    @ViewBuilder
    private func rowMenu(_ rows: Set<CategoryRowID>) -> some View {
        if rows.count == 1, let row = rows.first, case .group(let id, let type) = row,
           let group = viewModel.groups.first(where: { $0.id == id }) {
            groupMenu(group, type: type)
        } else {
            categoryMenu(rows.compactMap(\.categoryId))
        }
    }

    /// Right-click on one or several categories (reserves aren't selectable, so never here;
    /// built-in ones are left out).
    @ViewBuilder
    private func categoryMenu(_ ids: [Int64]) -> some View {
        let chosen = viewModel.categories.filter { c in c.id.map(ids.contains) == true && !c.isReserved && !c.isBuiltIn }
        if !chosen.isEmpty {
            Menu("Move to group") {
                Button("Ungrouped") { viewModel.move(ids: chosen.compactMap(\.id), toGroupId: nil) }
                Divider()
                ForEach(viewModel.groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { group in
                    Button(group.name) { viewModel.move(ids: chosen.compactMap(\.id), toGroupId: group.id) }
                }
            }
            if chosen.count == 1, let category = chosen.first, let id = category.id {
                Button("Rename…") { renaming = .category(category) }
                Button("Change icon…") {
                    // Opened once the menu has closed, so the popover can anchor to the badge.
                    DispatchQueue.main.async { iconPickerCategoryId = id }
                }
                if category.type == .expense {
                    Toggle("Exclude from auto-forecast", isOn: Binding(
                        get: { category.excludeFromAutoForecast },
                        set: { viewModel.setExcludedFromAutoForecast(id: id, excluded: $0) }
                    ))
                }
                if category.type == .transfer {
                    linkedAccountMenu(category, id: id)
                        .disabled(category.isExternalTransfer)
                    Toggle("Money goes to an account you don't import — never match", isOn: Binding(
                        get: { category.isExternalTransfer },
                        set: { viewModel.setExternalTransfer(id: id, external: $0) }
                    ))
                    .disabled(category.transferAccountId != nil)
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { deleting = .categories(chosen) }
        }
    }

    /// Linked account (spec 2026-10-14 §4): one of the accounts — never none, since every
    /// account keeps a transfer category; an account already linked to another category shows
    /// that category and can't be picked (a tie moves by picking another account here).
    private func linkedAccountMenu(_ category: Category, id: Int64) -> some View {
        Menu("Linked account") {
            ForEach(viewModel.accounts.sortedByDisplayName(), id: \.id) { account in
                let owner = viewModel.linkedCategory(forAccountId: account.id).flatMap { $0.id == id ? nil : $0 }
                Toggle(owner.map { "\(account.displayName) — \($0.name)" } ?? account.displayName, isOn: Binding(
                    get: { category.transferAccountId != nil && category.transferAccountId == account.id },
                    set: { if $0, let accountId = account.id { viewModel.setLinkedAccount(id: id, accountId: accountId) } }
                ))
                .disabled(owner != nil)
            }
        }
        .help("Transfers with this account are filed here. Every account keeps a transfer category, so a link can't be removed — pick another account to move it.")
    }

    // MARK: Actions

    /// The selected categories that can be renamed, moved or deleted (built-in ones and
    /// reserves are left out).
    private var editableSelectedCategories: [Category] {
        let ids = Set(selectedCategoryIds)
        return viewModel.categories.filter { c in c.id.map(ids.contains) == true && !c.isReserved && !c.isBuiltIn }
    }

    /// The selected group, if a group is selected.
    private var selectedGroup: CategoryGroup? {
        guard selection.count == 1, let id = selection.first?.groupId else { return nil }
        return viewModel.groups.first { $0.id == id }
    }

    /// Return: Rename… the one selected group or category. False when there's nothing to rename.
    private func renameSelection() -> Bool {
        if let group = selectedGroup {
            renaming = .group(group)
            return true
        }
        let categories = editableSelectedCategories
        guard selection.count == 1, categories.count == 1 else { return false }
        renaming = .category(categories[0])
        return true
    }

    /// ⌫/⌦: Delete… the selected group or categories. False when there's nothing to delete.
    private func deleteSelection() -> Bool {
        if let group = selectedGroup {
            confirmDelete(group)
            return true
        }
        let categories = editableSelectedCategories
        guard !categories.isEmpty else { return false }
        deleting = .categories(categories)
        return true
    }

    private func confirmDelete(_ group: CategoryGroup) {
        deleting = .group(group, memberCount: group.id.map { viewModel.members(ofGroupId: $0).count } ?? 0)
    }

    /// Drops deleted categories and groups from the selection, and moves a selected group row
    /// whose section no longer lists it (its last member of that type moved away) to a
    /// section that still does — or drops it when none does.
    private func reconcileSelection() {
        let categoryIds = Set(viewModel.categories.compactMap(\.id))
        let sections = viewModel.sections(search: search)
        func types(listing groupId: Int64) -> [CategoryType] {
            sections.filter { $0.groups.contains { $0.group.id == groupId } }.map(\.type)
        }
        let reconciled = Set(selection.compactMap { row -> CategoryRowID? in
            switch row {
            case .category(let id):
                return categoryIds.contains(id) ? row : nil
            case .group(let id, let type):
                let listed = types(listing: id)
                if listed.contains(type) { return row }
                return listed.first.map { .group(id, $0) }
            }
        })
        if reconciled != selection { selection = reconciled }
    }

    /// A new group: selected, expanded and scrolled into view.
    private func reveal(_ group: CategoryGroup) {
        guard let id = group.id else { return }
        search = ""
        let type = viewModel.sections(search: "").first { $0.groups.contains { $0.group.id == id } }?.type ?? .expense
        updateOutline { $0.collapsedKeys.remove("\(type.rawValue)-\(id)") }
        let row = CategoryRowID.group(id, type)
        selection = [row]
        scrollTarget = row
        scrollRetried = false
        scrollRequest += 1
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
