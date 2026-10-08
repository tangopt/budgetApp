import Foundation

/// The Differences tab's matrix: one row per budget item changed or removed in any scenario,
/// one per added entry, one cell per scenario that differs there.
public struct DifferenceMatrix {
    public struct Row: Identifiable, Equatable {
        /// "source-<budgetEntryId>" or "added-<scenarioId>-<entryId>".
        public var id: String
        /// The budget item's category for source rows (a scenario may re-file it), else the added entry's.
        public var categoryName: String
        /// The row's earliest series start, for ordering.
        public var startDate: Date
        public var isAdded: Bool
        /// The budget item in words; nil for added rows.
        public var budgetSummary: String?
        /// scenarioId → that scenario's difference.
        public var cells: [Int64: ScenarioDifference]

        public init(id: String, categoryName: String, startDate: Date = .distantPast, isAdded: Bool, budgetSummary: String?, cells: [Int64: ScenarioDifference]) {
            self.id = id
            self.startDate = startDate
            self.categoryName = categoryName
            self.isAdded = isAdded
            self.budgetSummary = budgetSummary
            self.cells = cells
        }
    }

    /// `differences` in the scenarios' display order. Rows: one per budget source id (changed/removed
    /// across scenarios merged), one per added entry; sorted by category name, then start date, then id (numeric for source rows).
    public static func rows(differences: [(scenarioId: Int64, differences: [ScenarioDifference])]) -> [Row] {
        var rows: [String: Row] = [:]
        for (scenarioId, list) in differences {
            for difference in list {
                if difference.kind != .added, let sourceId = difference.sourceEntryId {
                    let id = "source-\(sourceId)"
                    var row = rows[id] ?? Row(id: id, categoryName: difference.sourceCategoryName ?? difference.categoryName, startDate: difference.startDate, isAdded: false, budgetSummary: difference.sourceSummary, cells: [:])
                    row.startDate = min(row.startDate, difference.startDate)
                    row.cells[scenarioId] = difference
                    rows[id] = row
                } else {
                    // Added, or a change whose source is gone: its own row.
                    let id = "added-\(scenarioId)-\(difference.id)"
                    rows[id] = Row(id: id, categoryName: difference.categoryName, startDate: difference.startDate, isAdded: true, budgetSummary: nil, cells: [scenarioId: difference])
                }
            }
        }
        return rows.values.sorted { a, b in
            if a.categoryName != b.categoryName { return a.categoryName < b.categoryName }
            if a.startDate != b.startDate { return a.startDate < b.startDate }
            return a.id.compare(b.id, options: .numeric) == .orderedAscending
        }
    }
}
