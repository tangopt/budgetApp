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
}
