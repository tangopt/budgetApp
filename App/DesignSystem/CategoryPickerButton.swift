// App/DesignSystem/CategoryPickerButton.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

/// A button showing the chosen category that opens a searchable, keyboard-driven popover
/// (spec §3): Suggested, Recent, then every assignable category under its group, filtered
/// by the transaction's sign until "Show all categories" is picked.
struct CategoryPickerButton: View {
    @Binding var selection: Int64?
    let categories: [Category]
    let groups: [CategoryGroup]
    let suggestedId: Int64?
    let recentIds: [Int64]
    /// Sign drives the type filter (out → expense/transfer, in → income/transfer); `nil`
    /// or zero shows every category.
    let amountMinorUnits: Int?

    @State private var isPresented = false

    private var selectedName: String? {
        guard let selection else { return nil }
        return categories.first(where: { $0.id == selection })?.name
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 4) {
                Text(selectedName ?? "Choose category")
                    .foregroundStyle(selectedName == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            CategoryPickerPopover(
                selection: selection,
                categories: categories,
                groups: groups,
                suggestedId: suggestedId,
                recentIds: recentIds,
                amountMinorUnits: amountMinorUnits,
                onPick: { picked in
                    selection = picked
                    isPresented = false
                },
                onCancel: { isPresented = false }
            )
        }
    }
}

private struct CategoryPickerPopover: View {
    let selection: Int64?
    let categories: [Category]
    let groups: [CategoryGroup]
    let suggestedId: Int64?
    let recentIds: [Int64]
    let amountMinorUnits: Int?
    let onPick: (Int64?) -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var showAll = false
    @State private var highlighted: Int = 0
    @FocusState private var searchFocused: Bool

    /// One pickable line. `id` is unique per line (a category can appear under Suggested,
    /// Recent and its group at once), so it doubles as the scroll target.
    struct Entry: Identifiable {
        enum Action { case pick(Int64?), showAll }
        let id: String
        let title: String
        let action: Action
    }

    struct Section: Identifiable {
        let id: String
        let title: String?
        let entries: [Entry]
    }

    private var assignable: [Category] { categories.filter { $0.isAssignable && $0.id != nil } }

    /// The sign filter applies unless the user asked for everything or the amount has no sign.
    private var signFilterActive: Bool {
        guard !showAll, let amountMinorUnits, amountMinorUnits != 0 else { return false }
        return true
    }

    private func passesSign(_ category: Category) -> Bool {
        guard signFilterActive, let amountMinorUnits else { return true }
        switch category.type {
        case .transfer: return true
        case .expense: return amountMinorUnits < 0
        case .income: return amountMinorUnits > 0
        }
    }

    private func groupName(_ category: Category) -> String? {
        guard let groupId = category.groupId else { return nil }
        return groups.first(where: { $0.id == groupId })?.name
    }

    private func matchesQuery(_ category: Category) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return category.name.localizedCaseInsensitiveContains(trimmed)
            || (groupName(category)?.localizedCaseInsensitiveContains(trimmed) ?? false)
    }

    private func entry(_ category: Category, section: String) -> Entry {
        Entry(id: "\(section)-\(category.id!)", title: category.name, action: .pick(category.id))
    }

    private var sections: [Section] {
        let visible = assignable.filter(matchesQuery)
        let byId = Dictionary(uniqueKeysWithValues: visible.map { ($0.id!, $0) })
        var result: [Section] = []

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || "Uncategorized".localizedCaseInsensitiveContains(trimmed) {
            result.append(Section(id: "none", title: nil, entries: [Entry(id: "none", title: "Uncategorized", action: .pick(nil))]))
        }
        // The row's own suggestion is shown whatever its type — it's what the row will save.
        if let suggestedId, let suggested = byId[suggestedId] {
            result.append(Section(id: "suggested", title: "Suggested", entries: [entry(suggested, section: "suggested")]))
        }
        let recent = recentIds.compactMap { byId[$0] }.filter(passesSign)
        if !recent.isEmpty {
            result.append(Section(id: "recent", title: "Recent", entries: recent.map { entry($0, section: "recent") }))
        }

        let filtered = visible.filter(passesSign)
        let byName: (Category, Category) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let sortedGroups = groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for group in sortedGroups {
            let members = filtered.filter { $0.groupId == group.id }.sorted(by: byName)
            guard !members.isEmpty else { continue }
            result.append(Section(id: "group-\(group.id ?? 0)", title: group.name, entries: members.map { entry($0, section: "group") }))
        }
        let knownGroupIds = Set(groups.compactMap(\.id))
        let ungrouped = filtered.filter { $0.groupId.map { !knownGroupIds.contains($0) } ?? true }.sorted(by: byName)
        if !ungrouped.isEmpty {
            result.append(Section(id: "ungrouped", title: sortedGroups.isEmpty ? "Categories" : "Other", entries: ungrouped.map { entry($0, section: "group") }))
        }

        if signFilterActive {
            result.append(Section(id: "show-all", title: nil, entries: [Entry(id: "show-all", title: "Show all categories", action: .showAll)]))
        }
        return result
    }

    var body: some View {
        let sections = sections
        let entries = sections.flatMap(\.entries)
        VStack(spacing: 0) {
            TextField("Search categories", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(8)
                .onKeyPress(.downArrow) {
                    if !entries.isEmpty { highlighted = min(highlighted + 1, entries.count - 1) }
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    highlighted = max(highlighted - 1, 0)
                    return .handled
                }
                .onKeyPress(.escape) {
                    onCancel()
                    return .handled
                }
                .onKeyPress(.return) {
                    if entries.indices.contains(highlighted) { activate(entries[highlighted]) }
                    return .handled
                }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if entries.isEmpty {
                            Text("No matching categories")
                                .foregroundStyle(.secondary)
                                .padding(12)
                        }
                        ForEach(sections) { section in
                            if let title = section.title {
                                Text(title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 8)
                                    .padding(.bottom, 2)
                            } else if section.id == "show-all" {
                                Divider().padding(.vertical, 4)
                            }
                            ForEach(section.entries) { entry in
                                row(entry, index: entries.firstIndex(where: { $0.id == entry.id }) ?? 0)
                                    .id(entry.id)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: highlighted) { _, newValue in
                    guard entries.indices.contains(newValue) else { return }
                    proxy.scrollTo(entries[newValue].id)
                }
            }
        }
        .frame(width: 280, height: 360)
        .onAppear {
            highlighted = initialHighlight(in: entries)
            searchFocused = true
        }
        .onChange(of: query) { _, _ in
            // While searching, start on the first match rather than "Uncategorized".
            highlighted = query.isEmpty ? initialHighlight(in: self.sections.flatMap(\.entries)) : 0
        }
        .onChange(of: showAll) { _, _ in
            highlighted = initialHighlight(in: self.sections.flatMap(\.entries))
        }
    }

    /// Starts on the current selection (first place it's listed), else the first category.
    private func initialHighlight(in entries: [Entry]) -> Int {
        if let index = entries.firstIndex(where: { if case .pick(let id) = $0.action { return id == selection } else { return false } }),
           selection != nil {
            return index
        }
        return entries.firstIndex(where: { if case .pick(let id) = $0.action { return id != nil } else { return false } }) ?? 0
    }

    private func activate(_ entry: Entry) {
        switch entry.action {
        case .pick(let id): onPick(id)
        case .showAll: showAll = true
        }
    }

    private func row(_ entry: Entry, index: Int) -> some View {
        let isHighlighted = index == highlighted
        let isSelected: Bool = { if case .pick(let id) = entry.action { return id == selection } else { return false } }()
        return Button {
            activate(entry)
        } label: {
            HStack {
                Text(entry.title)
                    .foregroundStyle(isHighlighted ? Color.white : (entry.action.isShowAll ? Color.accentColor : Color.primary))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(isHighlighted ? Color.white : Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHighlighted ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { hovering in if hovering { highlighted = index } }
    }
}

private extension CategoryPickerPopover.Entry.Action {
    var isShowAll: Bool { if case .showAll = self { return true } else { return false } }
}
