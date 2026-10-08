import GRDB

public enum RuleLearner {
    /// Keys shorter than this are too generic to match safely; the full description is used.
    private static let minimumKeyLength = 4

    /// Payment-processor prefixes: a key made only of these ("PAYPAL") would capture every
    /// merchant behind the processor, so such descriptions keep their full text.
    private static let processorTokens: Set<String> = ["PAYPAL", "SQ", "SUMUP", "ZETTLE", "IZ", "STRIPE", "CRV", "CKO", "AMZN", "MKTP", "AMAZON", "GOOGLE"]

    /// Creates (or updates) a "contains" rule from a description: the pattern is its merchant
    /// key, or the uppercased full description when the key is very short.
    public static func learn(description: String, categoryId: Int64, db: Database) throws {
        let trimmed = description.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = MerchantKey.make(description)
        let processorOnly = key.split(separator: " ").allSatisfy { processorTokens.contains(String($0)) }
        let pattern = key.count < minimumKeyLength || processorOnly ? trimmed : key
        if var existing = try Rule.filter(Column("matchPattern") == pattern).fetchOne(db) {
            existing.categoryId = categoryId
            try existing.update(db)
        } else {
            var rule = Rule(matchPattern: pattern, matchType: .contains, categoryId: categoryId, priority: pattern.count)
            try rule.insert(db)
        }
    }

    public static func learnFromCorrection(description: String, categoryId: Int64, db: Database) throws {
        try learn(description: description, categoryId: categoryId, db: db)
    }
}
