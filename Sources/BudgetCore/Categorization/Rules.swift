import Foundation
import GRDB

/// Why a rule from the Rules screen's sheet can't be saved.
public enum RuleSaveError: Error, Equatable {
    case emptyPattern
    case invalidRegex
    /// Missing, built-in or a reserve: rules file only into assignable categories.
    case unassignableCategory
    /// Editing a rule into the pattern (and type) another rule already has.
    case duplicatePattern
    case ruleNotFound

    public var message: String {
        switch self {
        case .emptyPattern: return "Enter a pattern."
        case .invalidRegex: return "This isn't a valid regular expression."
        case .unassignableCategory: return "Choose a category."
        case .duplicatePattern: return "Another rule already has this pattern."
        case .ruleNotFound: return "This rule no longer exists."
        }
    }
}

/// What a pattern would match among the saved transactions (the rule sheet's live preview).
public struct RulePreview: Equatable, Sendable {
    /// Every saved transaction the pattern matches.
    public let matchCount: Int
    /// Of those, the ones still needing a category (`UncategorizedTransactions`).
    public let uncategorisedCount: Int
    /// The first few matching descriptions, newest first.
    public let sampleDescriptions: [String]

    public init(matchCount: Int, uncategorisedCount: Int, sampleDescriptions: [String]) {
        self.matchCount = matchCount
        self.uncategorisedCount = uncategorisedCount
        self.sampleDescriptions = sampleDescriptions
    }

    public static let empty = RulePreview(matchCount: 0, uncategorisedCount: 0, sampleDescriptions: [])
}

/// Rules added or edited by hand on the Rules screen (spec 2026-10-16 §B). Matching uses
/// `RuleMatcher`, the same as imports; priority follows `RuleLearner` (the pattern's length,
/// so a more specific pattern wins).
public enum Rules {
    /// The reason `pattern` can't be saved as a `matchType` rule, or nil when it can.
    public static func validationError(pattern: String, matchType: RuleMatchType) -> RuleSaveError? {
        let trimmed = normalized(pattern)
        guard !trimmed.isEmpty else { return .emptyPattern }
        if matchType == .regex, (try? NSRegularExpression(pattern: trimmed, options: .caseInsensitive)) == nil {
            return .invalidRegex
        }
        return nil
    }

    /// What the pattern matches now. An invalid pattern matches nothing.
    public static func preview(db: Database, pattern: String, matchType: RuleMatchType, sampleLimit: Int = 5) throws -> RulePreview {
        guard validationError(pattern: pattern, matchType: matchType) == nil else { return .empty }
        let rule = Rule(matchPattern: normalized(pattern), matchType: matchType, categoryId: 0, priority: 0)
        let matches = RuleMatcher.predicate(for: rule)
        let rows = try Row.fetchAll(db, sql: "SELECT id, rawDescription FROM transaction_ ORDER BY date DESC, id DESC")
        var matchedIds: [Int64] = []
        var samples: [String] = []
        for row in rows {
            let description: String = row["rawDescription"]
            guard matches(description) else { continue }
            matchedIds.append(row["id"])
            if samples.count < sampleLimit { samples.append(description) }
        }
        let uncategorised = try uncategorisedIds(db: db, among: matchedIds)
        return RulePreview(matchCount: matchedIds.count, uncategorisedCount: uncategorised.count, sampleDescriptions: samples)
    }

    /// Saves a new rule; a rule with the same pattern and type is updated instead (as the
    /// learner does). With `applyToUncategorised`, every matching transaction still needing
    /// a category is filed into it (confirmed, by rule) in the same write.
    @discardableResult
    public static func add(db: Database, pattern: String, matchType: RuleMatchType, categoryId: Int64, applyToUncategorised: Bool) throws -> Rule {
        try validate(db: db, pattern: pattern, matchType: matchType, categoryId: categoryId)
        let trimmed = normalized(pattern)
        var rule: Rule
        if var existing = try existingRule(db: db, pattern: trimmed, matchType: matchType) {
            existing.categoryId = categoryId
            try existing.update(db)
            rule = existing
        } else {
            rule = Rule(matchPattern: trimmed, matchType: matchType, categoryId: categoryId, priority: priority(for: trimmed))
            try rule.insert(db)
        }
        if applyToUncategorised { try apply(rule, db: db) }
        return rule
    }

    /// Edits rule `id` (its priority follows the new pattern); `applyToUncategorised` as in `add`.
    @discardableResult
    public static func update(db: Database, id: Int64, pattern: String, matchType: RuleMatchType, categoryId: Int64, applyToUncategorised: Bool) throws -> Rule {
        guard var rule = try Rule.fetchOne(db, key: id) else { throw RuleSaveError.ruleNotFound }
        try validate(db: db, pattern: pattern, matchType: matchType, categoryId: categoryId)
        let trimmed = normalized(pattern)
        if let other = try existingRule(db: db, pattern: trimmed, matchType: matchType), other.id != id {
            throw RuleSaveError.duplicatePattern
        }
        rule.matchPattern = trimmed
        rule.matchType = matchType
        rule.categoryId = categoryId
        rule.priority = priority(for: trimmed)
        try rule.update(db)
        if applyToUncategorised { try apply(rule, db: db) }
        return rule
    }

    // MARK: - Private

    private static func normalized(_ pattern: String) -> String {
        pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `RuleLearner`'s ordering: longer (more specific) patterns win.
    private static func priority(for pattern: String) -> Int { pattern.count }

    private static func validate(db: Database, pattern: String, matchType: RuleMatchType, categoryId: Int64) throws {
        if let error = validationError(pattern: pattern, matchType: matchType) { throw error }
        guard let category = try Category.fetchOne(db, key: categoryId), category.isAssignable else {
            throw RuleSaveError.unassignableCategory
        }
    }

    /// A rule with the same pattern (ignoring case, as matching does) and type.
    private static func existingRule(db: Database, pattern: String, matchType: RuleMatchType) throws -> Rule? {
        try Rule.filter(Column("matchType") == matchType.rawValue).fetchAll(db)
            .first { $0.matchPattern.caseInsensitiveCompare(pattern) == .orderedSame }
    }

    private static func uncategorisedIds(db: Database, among ids: [Int64]) throws -> [Int64] {
        guard !ids.isEmpty else { return [] }
        return try UncategorizedTransactions.request.filter(ids.contains(Column("id"))).select(Column("id"), as: Int64.self).fetchAll(db)
    }

    private static func apply(_ rule: Rule, db: Database) throws {
        let matches = RuleMatcher.predicate(for: rule)
        var targets = try UncategorizedTransactions.request.fetchAll(db).filter { matches($0.rawDescription) }
        for index in targets.indices {
            targets[index].categoryId = rule.categoryId
            targets[index].status = .confirmed
            targets[index].categorizedBy = .rule
            try targets[index].update(db, columns: ["categoryId", "status", "categorizedBy"])
        }
    }
}
