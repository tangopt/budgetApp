// Sources/BudgetCore/Budget/GridOutline.swift
import Foundation

/// What the Budget and Forecast grids show of their outline: which sections are collapsed
/// (only their header row shows) and which category groups are expanded (their members show
/// under the group row). Remembered per screen as two comma-separated strings
/// (`sectionsString` / `groupsString`); unknown or malformed entries are ignored.
public struct GridOutline: Equatable, Sendable {
    /// Keys of collapsed sections (`sectionKey(_:)`, `accountsSection`, `reservedSection`).
    public var collapsedSections: Set<String>
    public var expandedGroupIds: Set<Int64>

    public init(collapsedSections: Set<String> = [], expandedGroupIds: Set<Int64> = []) {
        self.collapsedSections = collapsedSections
        self.expandedGroupIds = expandedGroupIds
    }

    /// The stored form: section keys and group ids, each comma-separated.
    public init(sectionsString: String, groupsString: String) {
        collapsedSections = Set(Self.tokens(sectionsString))
        expandedGroupIds = Set(Self.tokens(groupsString).compactMap { Int64($0) })
    }

    public var sectionsString: String { collapsedSections.sorted().joined(separator: ",") }
    public var groupsString: String { expandedGroupIds.sorted().map(String.init).joined(separator: ",") }

    private static func tokens(_ string: String) -> [String] {
        string.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: Section keys

    /// A category type's section key (its raw value: "income", "expense", …).
    public static func sectionKey(_ type: CategoryType) -> String { type.rawValue }
    public static let accountsSection = "accounts"
    public static let reservedSection = "reserved"

    // MARK: Sections

    public func isCollapsed(_ section: String) -> Bool { collapsedSections.contains(section) }

    public mutating func toggleSection(_ section: String) {
        if collapsedSections.contains(section) { collapsedSections.remove(section) } else { collapsedSections.insert(section) }
    }

    // MARK: Groups

    public func isExpanded(_ groupId: Int64) -> Bool { expandedGroupIds.contains(groupId) }

    /// Toggles one group; with `allIn` (⌥-click, Finder's convention) every group of the
    /// clicked group's section takes the clicked group's new state.
    public mutating func toggleGroup(_ groupId: Int64, allIn sectionGroupIds: [Int64]? = nil) {
        let expand = !expandedGroupIds.contains(groupId)
        setGroups((sectionGroupIds ?? []) + [groupId], expanded: expand)
    }

    /// Expands (or collapses) every group in `groupIds` (a section's Expand all / Collapse all).
    public mutating func setGroups(_ groupIds: [Int64], expanded: Bool) {
        if expanded { expandedGroupIds.formUnion(groupIds) } else { expandedGroupIds.subtract(groupIds) }
    }

    // MARK: Rows

    /// A section body's row: an ungrouped category, a group's row (its members, for the
    /// combined figures), or a member of an expanded group.
    public enum Row: Equatable {
        case category(Category)
        case groupHeader(CategoryGroup, categories: [Category])
        case groupChild(Category)
    }

    /// A section's body rows for `categories` (already the section's, in order): categories
    /// sharing a `groupId` collapse into one `.groupHeader` (where the group's first member
    /// appears), followed by a `.groupChild` per member only while the group is expanded.
    /// A category whose group is unknown is left out (as the grids always did); ungrouped
    /// categories are `.category`, in order. A collapsed `section` has no body rows.
    public func rows(section: String, categories: [Category], groups: [CategoryGroup]) -> [Row] {
        guard !isCollapsed(section) else { return [] }
        return Self.groupedRows(categories: categories, groups: groups, expandedGroupIds: expandedGroupIds)
    }

    /// The ids of the groups a section's `categories` show, in row order (for Expand all /
    /// Collapse all and ⌥-click).
    public static func groupIds(categories: [Category], groups: [CategoryGroup]) -> [Int64] {
        groupedRows(categories: categories, groups: groups, expandedGroupIds: []).compactMap {
            if case .groupHeader(let group, _) = $0 { return group.id }
            return nil
        }
    }

    private static func groupedRows(categories: [Category], groups: [CategoryGroup], expandedGroupIds: Set<Int64>) -> [Row] {
        var rows: [Row] = []
        var seenGroupIds: Set<Int64> = []
        for category in categories {
            guard let groupId = category.groupId else {
                rows.append(.category(category))
                continue
            }
            guard seenGroupIds.insert(groupId).inserted,
                  let group = groups.first(where: { $0.id == groupId }) else { continue }
            let members = categories.filter { $0.groupId == groupId }
            rows.append(.groupHeader(group, categories: members))
            if expandedGroupIds.contains(groupId) { rows += members.map { .groupChild($0) } }
        }
        return rows
    }
}
