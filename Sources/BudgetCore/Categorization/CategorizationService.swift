import Foundation

public struct CategorizationResult: Equatable {
    public let categoryId: Int64?
    public let source: CategorizedBy
    public let confidence: Double
}

public final class CategorizationService {
    private let categorizer: Categorizing

    public init(categorizer: Categorizing) {
        self.categorizer = categorizer
    }

    public func categorize(description: String, rules: [Rule], categories: [Category]) async -> CategorizationResult {
        // Reserves are forecast-only; the model must never suggest one.
        let categories = categories.filter(\.isAssignable)
        if let rule = RuleMatcher.match(description: description, rules: rules) {
            return CategorizationResult(categoryId: rule.categoryId, source: .rule, confidence: 1.0)
        }

        let candidateNames = categories.map(\.name)
        if let suggestion = try? await categorizer.suggestCategory(description: description, candidateCategoryNames: candidateNames),
           let matchedCategory = categories.first(where: { $0.name == suggestion.categoryName }) {
            return CategorizationResult(categoryId: matchedCategory.id, source: .llm, confidence: suggestion.confidence)
        }

        return CategorizationResult(categoryId: nil, source: .none, confidence: 0.0)
    }

    /// Batched form of `categorize`: rule-matches every description first (fast, no model
    /// call), then tries the history of past categorised transactions, then sends only the
    /// still-unmatched descriptions through one `suggestCategories` call instead of one `suggestCategory` call each. Results are
    /// returned in the same order as `descriptions`, same as calling `categorize` once per
    /// description would — callers can't tell which path was used from the shape of the
    /// result, only from `.source` on each one.
    public func categorizeBatch(descriptions: [String], rules: [Rule], categories: [Category], history: [HistoryEntry] = []) async -> [CategorizationResult] {
        // Reserves are forecast-only; the model must never suggest one.
        let categories = categories.filter(\.isAssignable)
        let historyIndex = HistoryIndex(history)
        var results = [CategorizationResult?](repeating: nil, count: descriptions.count)
        var unmatchedIndices: [Int] = []
        var unmatchedDescriptions: [String] = []
        for (index, description) in descriptions.enumerated() {
            if let rule = RuleMatcher.match(description: description, rules: rules) {
                results[index] = CategorizationResult(categoryId: rule.categoryId, source: .rule, confidence: 1.0)
            } else if !historyIndex.isEmpty,
                      let hit = historyIndex.suggest(merchantKey: MerchantKey.make(description)),
                      categories.contains(where: { $0.id == hit.categoryId }) {
                results[index] = CategorizationResult(categoryId: hit.categoryId, source: .history, confidence: hit.share)
            } else {
                unmatchedIndices.append(index)
                unmatchedDescriptions.append(description)
            }
        }

        if !unmatchedDescriptions.isEmpty {
            let candidateNames = categories.map(\.name)
            var suggestions = (try? await categorizer.suggestCategories(descriptions: unmatchedDescriptions, candidateCategoryNames: candidateNames))
                ?? Array(repeating: nil, count: unmatchedDescriptions.count)
            // Defensive: `Categorizing` is a protocol, and `categorizeBatch` pairs results
            // with descriptions purely by array position below — trust no conformer's
            // count over the one actually given, or a short/long response would either
            // crash on out-of-bounds or silently pair a guess with the wrong description.
            if suggestions.count != unmatchedDescriptions.count {
                suggestions = Array(repeating: nil, count: unmatchedDescriptions.count)
            }
            for (offset, index) in unmatchedIndices.enumerated() {
                if let suggestion = suggestions[offset], let matchedCategory = categories.first(where: { $0.name == suggestion.categoryName }) {
                    results[index] = CategorizationResult(categoryId: matchedCategory.id, source: .llm, confidence: suggestion.confidence)
                } else {
                    results[index] = CategorizationResult(categoryId: nil, source: .none, confidence: 0.0)
                }
            }
        }

        return results.map { $0! }
    }
}
