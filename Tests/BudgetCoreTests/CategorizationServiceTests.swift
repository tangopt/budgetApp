import XCTest
@testable import BudgetCore

final class FakeCategorizer: Categorizing {
    var stubbedSuggestion: CategorySuggestion?
    /// When set, `suggestCategories` returns this verbatim instead of deriving from
    /// `stubbedSuggestion` — lets a test simulate a conformer returning the wrong number
    /// of results, which real code must never trust blindly.
    var stubbedBatchSuggestions: [CategorySuggestion?]?
    private(set) var lastBatchDescriptions: [String]?
    private(set) var lastCandidateNames: [String]?

    func suggestCategory(description: String, candidateCategoryNames: [String]) async throws -> CategorySuggestion? {
        lastCandidateNames = candidateCategoryNames
        return stubbedSuggestion
    }

    func suggestCategories(descriptions: [String], candidateCategoryNames: [String]) async throws -> [CategorySuggestion?] {
        lastCandidateNames = candidateCategoryNames
        lastBatchDescriptions = descriptions
        return stubbedBatchSuggestions ?? descriptions.map { _ in stubbedSuggestion }
    }
}

final class CategorizationServiceTests: XCTestCase {
    let groceries = Category(id: 1, name: "Groceries", type: .expense)
    let eatingOut = Category(id: 2, name: "Eating Out", type: .expense)

    func testReservedCategoriesAreNeverOfferedToTheModel() async {
        let reserve = Category(id: 3, name: "Remaining for expenses", type: .expense, isReserved: true)
        let fake = FakeCategorizer()
        let service = CategorizationService(categorizer: fake)

        _ = await service.categorize(description: "TESCO", rules: [], categories: [groceries, reserve])
        XCTAssertEqual(fake.lastCandidateNames, ["Groceries"])

        _ = await service.categorizeBatch(descriptions: ["TESCO", "ALDI"], rules: [], categories: [reserve, eatingOut])
        XCTAssertEqual(fake.lastCandidateNames, ["Eating Out"])
    }

    func testRuleMatchWinsOverLLM() async {
        let rule = Rule(id: 1, matchPattern: "SAINSBURYS", matchType: .contains, categoryId: 1, priority: 10)
        let fake = FakeCategorizer()
        fake.stubbedSuggestion = CategorySuggestion(categoryName: "Eating Out", confidence: 0.9)
        let service = CategorizationService(categorizer: fake)

        let result = await service.categorize(description: "SAINSBURYS LONDON", rules: [rule], categories: [groceries, eatingOut])
        XCTAssertEqual(result.categoryId, 1)
        XCTAssertEqual(result.source, .rule)
        XCTAssertEqual(result.confidence, 1.0)
    }

    func testFallsBackToLLMWhenNoRuleMatches() async {
        let fake = FakeCategorizer()
        fake.stubbedSuggestion = CategorySuggestion(categoryName: "Eating Out", confidence: 0.75)
        let service = CategorizationService(categorizer: fake)

        let result = await service.categorize(description: "NANDOS CROYDON", rules: [], categories: [groceries, eatingOut])
        XCTAssertEqual(result.categoryId, 2)
        XCTAssertEqual(result.source, .llm)
        XCTAssertEqual(result.confidence, 0.75)
    }

    func testUncategorizedWhenNoRuleAndNoLLMSuggestion() async {
        let fake = FakeCategorizer()
        fake.stubbedSuggestion = nil
        let service = CategorizationService(categorizer: fake)

        let result = await service.categorize(description: "UNKNOWN MERCHANT", rules: [], categories: [groceries, eatingOut])
        XCTAssertNil(result.categoryId)
        XCTAssertEqual(result.source, .none)
    }

    func testCategorizeBatchUsesRulesForMatchingDescriptionsWithoutCallingTheCategorizer() async {
        let rule = Rule(id: 1, matchPattern: "SAINSBURYS", matchType: .contains, categoryId: 1, priority: 10)
        let fake = FakeCategorizer()
        let service = CategorizationService(categorizer: fake)

        let results = await service.categorizeBatch(
            descriptions: ["SAINSBURYS LONDON", "TESCO EXPRESS"],
            rules: [rule], categories: [groceries, eatingOut]
        )

        XCTAssertEqual(results[0].categoryId, 1)
        XCTAssertEqual(results[0].source, .rule)
        // Only the unmatched description should have reached the batch categorizer.
        XCTAssertEqual(fake.lastBatchDescriptions, ["TESCO EXPRESS"])
    }

    func testCategorizeBatchPreservesOrderAcrossRuleMatchedAndLLMFallbackItems() async {
        let rule = Rule(id: 1, matchPattern: "SAINSBURYS", matchType: .contains, categoryId: 1, priority: 10)
        let fake = FakeCategorizer()
        fake.stubbedBatchSuggestions = [CategorySuggestion(categoryName: "Eating Out", confidence: 0.8)]
        let service = CategorizationService(categorizer: fake)

        let results = await service.categorizeBatch(
            descriptions: ["NANDOS CROYDON", "SAINSBURYS LONDON"],
            rules: [rule], categories: [groceries, eatingOut]
        )

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].categoryId, eatingOut.id)
        XCTAssertEqual(results[0].source, .llm)
        XCTAssertEqual(results[1].categoryId, 1)
        XCTAssertEqual(results[1].source, .rule)
    }

    func testCategorizeBatchSkipsTheCategorizerEntirelyWhenAllDescriptionsMatchRules() async {
        let rule = Rule(id: 1, matchPattern: "SAINSBURYS", matchType: .contains, categoryId: 1, priority: 10)
        let fake = FakeCategorizer()
        let service = CategorizationService(categorizer: fake)

        let results = await service.categorizeBatch(descriptions: ["SAINSBURYS"], rules: [rule], categories: [groceries])

        XCTAssertEqual(results[0].source, .rule)
        XCTAssertNil(fake.lastBatchDescriptions, "the batch categorizer must not be called when every description matched a rule")
    }

    func testCategorizeBatchFallsBackToNoSuggestionWhenCategorizerReturnsWrongCount() async {
        let fake = FakeCategorizer()
        // Simulates a conformer returning fewer guesses than descriptions given — the
        // same shape a misaligned on-device model response would produce. Must never
        // crash or pair a guess with the wrong description.
        fake.stubbedBatchSuggestions = [CategorySuggestion(categoryName: "Eating Out", confidence: 0.9)]
        let service = CategorizationService(categorizer: fake)

        let results = await service.categorizeBatch(
            descriptions: ["NANDOS", "WAGAMAMA", "PRET"],
            rules: [], categories: [groceries, eatingOut]
        )

        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { $0.categoryId == nil && $0.source == .none })
    }

    func testCategorizeBatchReturnsEmptyForEmptyInput() async {
        let fake = FakeCategorizer()
        let service = CategorizationService(categorizer: fake)

        let results = await service.categorizeBatch(descriptions: [], rules: [], categories: [groceries])

        XCTAssertEqual(results, [])
        XCTAssertNil(fake.lastBatchDescriptions)
    }

    func testHistoryBeatsTheModelButLosesToARule() async {
        let history = [HistoryEntry(merchantKey: "TESCO STORES", categoryId: 1), HistoryEntry(merchantKey: "TESCO STORES", categoryId: 1),
                       HistoryEntry(merchantKey: "TESCO STORES", categoryId: 1), HistoryEntry(merchantKey: "TESCO STORES", categoryId: 2)]
        let fake = FakeCategorizer()
        fake.stubbedSuggestion = CategorySuggestion(categoryName: "Eating Out", confidence: 0.9)
        let service = CategorizationService(categorizer: fake)

        let results = await service.categorizeBatch(descriptions: ["TESCO STORES 2041", "NANDOS"], rules: [], categories: [groceries, eatingOut], history: history)
        XCTAssertEqual(results[0].categoryId, 1)
        XCTAssertEqual(results[0].source, .history)
        XCTAssertEqual(results[0].confidence, 0.75, accuracy: 0.0001)
        XCTAssertEqual(results[1].source, .llm)
        XCTAssertEqual(fake.lastBatchDescriptions, ["NANDOS"])

        let rule = Rule(id: 1, matchPattern: "TESCO", matchType: .contains, categoryId: 2, priority: 10)
        let ruled = await service.categorizeBatch(descriptions: ["TESCO STORES 2041"], rules: [rule], categories: [groceries, eatingOut], history: history)
        XCTAssertEqual(ruled[0].categoryId, 2)
        XCTAssertEqual(ruled[0].source, .rule)
    }

    func testHistorySuggestingANonAssignableCategoryFallsThrough() async {
        let reserve = Category(id: 3, name: "Remaining for expenses", type: .expense, isReserved: true)
        let history = [HistoryEntry(merchantKey: "X SHOP", categoryId: 3), HistoryEntry(merchantKey: "X SHOP", categoryId: 3)]
        let fake = FakeCategorizer()
        let service = CategorizationService(categorizer: fake)
        let results = await service.categorizeBatch(descriptions: ["X SHOP"], rules: [], categories: [groceries, reserve], history: history)
        XCTAssertNil(results[0].categoryId)
        XCTAssertEqual(results[0].source, .none)
    }

    func testHistoryPointingAtAnUnknownCategoryFallsThroughToTheModel() async {
        let history = [HistoryEntry(merchantKey: "GONE SHOP", categoryId: 99), HistoryEntry(merchantKey: "GONE SHOP", categoryId: 99)]
        let fake = FakeCategorizer()
        fake.stubbedSuggestion = CategorySuggestion(categoryName: "Eating Out", confidence: 0.8)
        let service = CategorizationService(categorizer: fake)
        let results = await service.categorizeBatch(descriptions: ["GONE SHOP"], rules: [], categories: [groceries, eatingOut], history: history)
        XCTAssertEqual(results[0].source, .llm)
        XCTAssertEqual(results[0].categoryId, 2)
    }
}
