import Foundation

/// One pickable line in the category picker. `id` is unique per line (a category can be
/// listed under Suggested, Recent and its group at once), so it doubles as a scroll target.
public struct CategoryPickerEntry: Equatable, Identifiable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Pick this category; `nil` clears it (Uncategorized).
        case pick(Int64?)
        /// Lift the sign filter.
        case showAll
    }
    public let id: String
    public let title: String
    public let action: Action
}

public struct CategoryPickerSection: Equatable, Identifiable, Sendable {
    public let id: String
    /// `nil` for the untitled Uncategorized and "Show all categories" sections.
    public let title: String?
    public let entries: [CategoryPickerEntry]
}

/// What the category picker lists (spec §3): Uncategorized, Suggested, Recent, then every
/// assignable category under its group (groups alphabetical, ungrouped last, alphabetical
/// within), filtered by the transaction's sign until "Show all categories" is picked.
public enum CategoryPickerSections {
    public static let uncategorizedTitle = "Uncategorized"

    /// Money out → expense and transfer; money in → income and transfer. Off when
    /// `showAll` is set or the amount is missing or zero.
    public static func signFilterActive(amountMinorUnits: Int?, showAll: Bool) -> Bool {
        guard !showAll, let amountMinorUnits else { return false }
        return amountMinorUnits != 0
    }

    public static func build(categories: [Category], groups: [CategoryGroup], suggestedId: Int64?, recentIds: [Int64],
                             amountMinorUnits: Int?, query: String, showAll: Bool) -> [CategoryPickerSection] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let groupNames = Dictionary(groups.compactMap { group in group.id.map { ($0, group.name) } }, uniquingKeysWith: { first, _ in first })
        let filterBySign = signFilterActive(amountMinorUnits: amountMinorUnits, showAll: showAll)
        func passesSign(_ category: Category) -> Bool {
            guard filterBySign, let amountMinorUnits else { return true }
            switch category.type {
            case .transfer: return true
            case .expense: return amountMinorUnits < 0
            case .income: return amountMinorUnits > 0
            }
        }
        func matchesQuery(_ category: Category) -> Bool {
            guard !trimmed.isEmpty else { return true }
            return category.name.localizedCaseInsensitiveContains(trimmed)
                || (category.groupId.flatMap { groupNames[$0] }?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
        func entry(_ category: Category, section: String) -> CategoryPickerEntry {
            CategoryPickerEntry(id: "\(section)-\(category.id!)", title: category.name, action: .pick(category.id))
        }
        let byName: (Category, Category) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let visible = categories.filter { $0.isAssignable && $0.id != nil && matchesQuery($0) }
        let byId = Dictionary(visible.map { ($0.id!, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [CategoryPickerSection] = []

        // Shown only for an empty query or a prefix of "Uncategorized", so a one-letter
        // search ("e", "cat") never surfaces it ahead of real matches.
        if trimmed.isEmpty || uncategorizedTitle.lowercased().hasPrefix(trimmed.lowercased()) {
            result.append(CategoryPickerSection(id: "none", title: nil, entries: [CategoryPickerEntry(id: "none", title: uncategorizedTitle, action: .pick(nil))]))
        }
        // The row's own suggestion is shown whatever its type — it's what the row will save.
        if let suggestedId, let suggested = byId[suggestedId] {
            result.append(CategoryPickerSection(id: "suggested", title: "Suggested", entries: [entry(suggested, section: "suggested")]))
        }
        let recent = recentIds.compactMap { byId[$0] }.filter(passesSign)
        if !recent.isEmpty {
            result.append(CategoryPickerSection(id: "recent", title: "Recent", entries: recent.map { entry($0, section: "recent") }))
        }

        let filtered = visible.filter(passesSign)
        let sortedGroups = groups.filter { $0.id != nil }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for group in sortedGroups {
            let members = filtered.filter { $0.groupId == group.id }.sorted(by: byName)
            guard !members.isEmpty else { continue }
            result.append(CategoryPickerSection(id: "group-\(group.id!)", title: group.name, entries: members.map { entry($0, section: "group") }))
        }
        let ungrouped = filtered.filter { $0.groupId.map { groupNames[$0] == nil } ?? true }.sorted(by: byName)
        if !ungrouped.isEmpty {
            result.append(CategoryPickerSection(id: "ungrouped", title: sortedGroups.isEmpty ? "Categories" : "Other", entries: ungrouped.map { entry($0, section: "group") }))
        }

        if filterBySign {
            result.append(CategoryPickerSection(id: "show-all", title: nil, entries: [CategoryPickerEntry(id: "show-all", title: "Show all categories", action: .showAll)]))
        }
        return result
    }

    /// Where the highlight starts: the current selection when not searching, otherwise the
    /// first real category (never Uncategorized or "Show all", so type + Return picks a
    /// match); 0 when nothing qualifies.
    public static func initialHighlight(entries: [CategoryPickerEntry], selection: Int64?, query: String) -> Int {
        if query.trimmingCharacters(in: .whitespaces).isEmpty, let selection,
           let index = entries.firstIndex(where: { $0.action == .pick(selection) }) {
            return index
        }
        return entries.firstIndex(where: { if case .pick(let id) = $0.action { return id != nil } else { return false } }) ?? 0
    }
}
