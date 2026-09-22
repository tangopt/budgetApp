import XCTest
@testable import BudgetCore

final class RuleMatcherTests: XCTestCase {
    func testContainsMatchIsCaseInsensitive() {
        let rule = Rule(id: 1, matchPattern: "sainsburys", matchType: .contains, categoryId: 1, priority: 10)
        let match = RuleMatcher.match(description: "SAINSBURYS LONDON SW1", rules: [rule])
        XCTAssertEqual(match?.id, 1)
    }

    func testRegexMatch() {
        let rule = Rule(id: 2, matchPattern: "^TFL TRAVEL.*$", matchType: .regex, categoryId: 2, priority: 10)
        let match = RuleMatcher.match(description: "TFL TRAVEL CH 1234", rules: [rule])
        XCTAssertEqual(match?.id, 2)
    }

    func testHigherPriorityWinsWhenMultipleMatch() {
        let low = Rule(id: 1, matchPattern: "AMAZON", matchType: .contains, categoryId: 1, priority: 1)
        let high = Rule(id: 2, matchPattern: "AMAZON PRIME", matchType: .contains, categoryId: 2, priority: 10)
        let match = RuleMatcher.match(description: "AMAZON PRIME MEMBERSHIP", rules: [low, high])
        XCTAssertEqual(match?.id, 2)
    }

    func testNoMatchReturnsNil() {
        let rule = Rule(id: 1, matchPattern: "SAINSBURYS", matchType: .contains, categoryId: 1, priority: 10)
        let match = RuleMatcher.match(description: "TESCO EXPRESS", rules: [rule])
        XCTAssertNil(match)
    }
}
