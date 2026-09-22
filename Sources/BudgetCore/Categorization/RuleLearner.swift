import GRDB

public enum RuleLearner {
    /// Creates (or reuses) a "contains" rule from a manually-corrected transaction description.
    public static func learnFromCorrection(description: String, categoryId: Int64, db: Database) throws {
        let pattern = description.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return }
        if var existing = try Rule.filter(Column("matchPattern") == pattern).fetchOne(db) {
            existing.categoryId = categoryId
            try existing.update(db)
        } else {
            var rule = Rule(matchPattern: pattern, matchType: .contains, categoryId: categoryId, priority: pattern.count)
            try rule.insert(db)
        }
    }
}
