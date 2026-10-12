import Foundation

/// The review's three lists (spec §7), in tab order.
public enum ReviewTab: Int, CaseIterable, Hashable, Sendable {
    case needsAttention
    case ready
    case confirmed

    /// The tab to show for these row counts: `current` while it has rows, otherwise the
    /// first non-empty tab in order (Needs → Ready → Confirmed), or `current` when every
    /// tab is empty. Settling `.needsAttention` gives the opening tab: Needs, or Ready
    /// when Needs is empty.
    public static func settled(current: ReviewTab, rowCounts: [ReviewTab: Int]) -> ReviewTab {
        let hasRows: (ReviewTab) -> Bool = { (rowCounts[$0] ?? 0) > 0 }
        if hasRows(current) { return current }
        return allCases.first(where: hasRows) ?? current
    }
}
