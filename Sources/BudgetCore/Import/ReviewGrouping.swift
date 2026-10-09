import Foundation

/// What a list row or group is selected by. Group ids carry a scope (e.g. the list
/// section) because the same merchant key can appear in more than one section.
public enum ReviewSelectionId<RowID: Hashable>: Hashable {
    case row(RowID)
    case group(scope: String, key: String)
}

/// Rows sharing a merchant key (spec §4). A single-row group renders as a plain row.
public struct ReviewGroup<Row: Identifiable>: Identifiable {
    public let key: String
    public let scope: String
    public let rows: [Row]

    public var id: ReviewSelectionId<Row.ID> { .group(scope: scope, key: key) }
    public var isMultiRow: Bool { rows.count > 1 }

    /// The id the list tags this group's top-level line with: the group for 2+ rows, the
    /// row itself for a single-row group.
    public var selectionId: ReviewSelectionId<Row.ID> {
        if !isMultiRow, let only = rows.first { return .row(only.id) }
        return id
    }
}

/// A group's category: one shared value (possibly none), or "Mixed".
public enum ReviewCategoryState: Equatable {
    case uniform(Int64?)
    case mixed
}

/// Pure helpers behind the grouped, multi-select review lists (import Review and
/// Uncategorized): grouping by merchant key, a group's shared category, date range and
/// total, the Remember default, and resolving a selection to rows.
public enum ReviewGrouping {
    /// Groups rows by `MerchantKey.make` of their description, groups and rows in order of
    /// first appearance.
    public static func groups<Row: Identifiable>(_ rows: [Row], scope: String, description: (Row) -> String) -> [ReviewGroup<Row>] {
        var keys: [String] = []
        var rowsByKey: [String: [Row]] = [:]
        for row in rows {
            let key = MerchantKey.make(description(row))
            if rowsByKey[key] == nil { keys.append(key) }
            rowsByKey[key, default: []].append(row)
        }
        return keys.map { ReviewGroup(key: $0, scope: scope, rows: rowsByKey[$0] ?? []) }
    }

    public static func categoryState(of categoryIds: [Int64?]) -> ReviewCategoryState {
        guard let first = categoryIds.first else { return .uniform(nil) }
        return categoryIds.allSatisfy({ $0 == first }) ? .uniform(first) : .mixed
    }

    public static func dateRange(_ dates: [Date]) -> ClosedRange<Date>? {
        guard let earliest = dates.min(), let latest = dates.max() else { return nil }
        return earliest...latest
    }

    public static func total(_ amountsMinorUnits: [Int]) -> Int {
        amountsMinorUnits.reduce(0, +)
    }

    /// An amount with the rows' common sign (-1 or 1) for the category picker's type
    /// filter, or `nil` when the signs differ (or there are no non-zero amounts), which
    /// shows every category.
    public static func sharedSign(_ amountsMinorUnits: [Int]) -> Int? {
        let nonZero = amountsMinorUnits.filter { $0 != 0 }
        if !nonZero.isEmpty && nonZero.allSatisfy({ $0 < 0 }) { return -1 }
        if !nonZero.isEmpty && nonZero.allSatisfy({ $0 > 0 }) { return 1 }
        return nil
    }

    /// "Remember for <key>" starts on when categorising a group or 2+ rows at once, off
    /// for a single row.
    public static func rememberDefault(rowCount: Int) -> Bool {
        rowCount >= 2
    }

    /// Whether a row learns a rule: its explicit Remember choice, else the default for the
    /// group it's shown in. Used both for the checkbox and for the saved decision, so what
    /// the checkbox shows is what happens.
    public static func remembers(choice: Bool?, groupRowCount: Int) -> Bool {
        choice ?? rememberDefault(rowCount: groupRowCount)
    }

    /// Every row the selection covers (a selected group means all its rows), in display
    /// order and without duplicates. Ids that no longer exist are ignored.
    public static func selectedRowIds<Row: Identifiable>(_ selection: Set<ReviewSelectionId<Row.ID>>, in groups: [ReviewGroup<Row>]) -> [Row.ID] {
        var result: [Row.ID] = []
        for group in groups {
            // A group id only selects while it is still a multi-row group (a stale id can
            // linger after confirming leaves one row).
            let wholeGroup = group.isMultiRow && selection.contains(group.id)
            for row in group.rows where wholeGroup || selection.contains(.row(row.id)) {
                result.append(row.id)
            }
        }
        return result
    }

    /// The list's selectable lines in display order: each group (or single row), followed
    /// by its rows when it is a multi-row group that is expanded.
    public static func visibleItems<Row: Identifiable>(_ groups: [ReviewGroup<Row>], expanded: Set<ReviewSelectionId<Row.ID>>) -> [ReviewSelectionId<Row.ID>] {
        groups.flatMap { group -> [ReviewSelectionId<Row.ID>] in
            guard group.isMultiRow else { return [group.selectionId] }
            return [group.id] + (expanded.contains(group.id) ? group.rows.map { .row($0.id) } : [])
        }
    }

    /// Every line that can be selected (all groups expanded) — used to drop stale ids.
    public static func selectableItems<Row: Identifiable>(_ groups: [ReviewGroup<Row>]) -> [ReviewSelectionId<Row.ID>] {
        visibleItems(groups, expanded: Set(groups.map(\.id)))
    }
}
