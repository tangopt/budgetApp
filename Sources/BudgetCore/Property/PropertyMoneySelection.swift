// Sources/BudgetCore/Property/PropertyMoneySelection.swift

/// Moving the selection through the Money tab's rows with the arrow keys: the rows that can be
/// opened, in the order they are drawn.
public enum PropertyMoneySelection {
    /// The row `steps` away from `current` among `ids` (negative: up), stopping at the first and
    /// last. With nothing selected (or a row that is gone), down picks the first and up the last.
    /// Nil when there are no rows.
    public static func step(ids: [String], from current: String?, by steps: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return steps >= 0 ? ids.first : ids.last }
        return ids[min(max(index + steps, 0), ids.count - 1)]
    }
}
