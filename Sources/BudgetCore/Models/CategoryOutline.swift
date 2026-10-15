import Foundation

/// Which group (and Ungrouped) rows of the Categories screen are collapsed (spec 2026-10-15
/// §1). Rows are keyed "<type>-<group id>" or "<type>-ungrouped" (`CategorySection.GroupBlock.id`)
/// and start expanded. Remembered as one comma-separated string (`string`).
public struct CategoryOutline: Equatable, Sendable {
    public var collapsedKeys: Set<String>

    public init(collapsedKeys: Set<String> = []) {
        self.collapsedKeys = collapsedKeys
    }

    /// The stored form; blank entries are ignored.
    public init(string: String) {
        collapsedKeys = Set(string.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    public var string: String { collapsedKeys.sorted().joined(separator: ",") }

    public func isExpanded(_ key: String) -> Bool { !collapsedKeys.contains(key) }

    /// Toggles one row; with `allIn` (⌥-click, Finder's convention) every row of the clicked
    /// row's section takes the clicked row's new state.
    public mutating func toggle(_ key: String, allIn sectionKeys: [String]? = nil) {
        let collapse = isExpanded(key)
        for k in (sectionKeys ?? []) + [key] {
            if collapse { collapsedKeys.insert(k) } else { collapsedKeys.remove(k) }
        }
    }

    /// Expand all: nothing stays collapsed (stale keys are dropped too).
    public mutating func expandAll() { collapsedKeys.removeAll() }

    /// Collapse all: every row in `keys` collapses.
    public mutating func collapseAll(_ keys: [String]) { collapsedKeys.formUnion(keys) }
}
