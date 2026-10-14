import Foundation

/// One of the Categories screen's type sections (spec §4): its groups, then Ungrouped.
public struct CategorySection: Identifiable, Equatable {
    public let type: CategoryType
    public let groups: [GroupBlock]
    public let ungrouped: [Category]

    public var id: CategoryType { type }

    /// A group's members of this section's type (a group may hold any type, so a mixed
    /// group shows in each section it has members in).
    public struct GroupBlock: Identifiable, Equatable {
        public let type: CategoryType
        public let group: CategoryGroup
        public let categories: [Category]
        /// Unique per section ("<type>-<group id>"): a mixed group appears in several sections
        /// of one List, so the bare group id would be a duplicate row identity.
        public var id: String { "\(type.rawValue)-\(group.id ?? -1)" }
    }
}

public enum CategorySections {
    /// Expenses, Income, Transfers, Adjustments (the built-in categories, read-only).
    public static let order: [CategoryType] = [.expense, .income, .transfer, .adjustment]

    /// The type sections for the Categories screen; reserves are left out (listed apart).
    /// Groups and categories sort by name. A group with no (non-reserve) categories shows,
    /// empty, under Expenses. A category whose group no longer exists counts as ungrouped.
    ///
    /// Without a search every section and its Ungrouped row are kept (they're drop
    /// targets) — except Adjustments, which shows only when it has categories (the built-in
    /// ones, always ungrouped there). `search` matches category and group names
    /// case-insensitively: a matching group shows all its members, otherwise only matching
    /// categories show; groups and sections with nothing to show are dropped.
    public static func build(categories: [Category], groups: [CategoryGroup], search: String) -> [CategorySection] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let searching = !query.isEmpty
        func matches(_ name: String) -> Bool { name.localizedCaseInsensitiveContains(query) }
        func byName<T>(_ name: KeyPath<T, String>) -> (T, T) -> Bool {
            { $0[keyPath: name].localizedStandardCompare($1[keyPath: name]) == .orderedAscending }
        }
        let assignable = categories.filter { !$0.isReserved }
        let sortedGroups = groups.filter { $0.id != nil }.sorted(by: byName(\.name))
        let groupIds = Set(sortedGroups.compactMap(\.id))
        let occupied = Set(assignable.compactMap(\.groupId))
        return order.compactMap { type in
            let ofType = assignable.filter { $0.type == type }.sorted(by: byName(\.name))
            if type == .adjustment {
                let shown = ofType.filter { !searching || matches($0.name) }
                return shown.isEmpty ? nil : CategorySection(type: type, groups: [], ungrouped: shown)
            }
            let blocks: [CategorySection.GroupBlock] = sortedGroups.compactMap { group in
                let groupMatches = !searching || matches(group.name)
                let members = ofType.filter { $0.groupId == group.id && (groupMatches || matches($0.name)) }
                let showsEmpty = type == .expense && !occupied.contains(group.id!) && groupMatches
                if members.isEmpty && !showsEmpty { return nil }
                return CategorySection.GroupBlock(type: type, group: group, categories: members)
            }
            let ungrouped = ofType.filter { ($0.groupId.map { !groupIds.contains($0) } ?? true) && (!searching || matches($0.name)) }
            if searching && blocks.isEmpty && ungrouped.isEmpty { return nil }
            return CategorySection(type: type, groups: blocks, ungrouped: ungrouped)
        }
    }
}
