import XCTest
@testable import BudgetCore

final class FakeCategorizer: Categorizing {
    var stubbedSuggestion: CategorySuggestion?
    func suggestCategory(description: String, candidateCategoryNames: [String]) async throws -> CategorySuggestion? {
        stubbedSuggestion
    }
}

final class CategorizationServiceTests: XCTestCase {
    let groceries = Category(id: 1, name: "Groceries", type: .expense)
    let eatingOut = Category(id: 2, name: "Eating Out", type: .expense)

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
}
