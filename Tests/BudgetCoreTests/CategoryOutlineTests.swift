import XCTest
@testable import BudgetCore

final class CategoryOutlineTests: XCTestCase {
    func testEverythingStartsExpandedAndToggleCollapsesOne() {
        var outline = CategoryOutline(string: "")
        XCTAssertTrue(outline.isExpanded("expense-1"))
        outline.toggle("expense-1")
        XCTAssertFalse(outline.isExpanded("expense-1"))
        XCTAssertTrue(outline.isExpanded("income-1"))
        outline.toggle("expense-1")
        XCTAssertTrue(outline.isExpanded("expense-1"))
    }

    func testRoundTripsThroughItsStoredStringIgnoringBlanks() {
        let outline = CategoryOutline(string: " income-2 ,,expense-1,expense-ungrouped")
        XCTAssertEqual(outline.collapsedKeys, ["expense-1", "income-2", "expense-ungrouped"])
        XCTAssertEqual(outline.string, "expense-1,expense-ungrouped,income-2")
        XCTAssertEqual(CategoryOutline(string: outline.string), outline)
    }

    func testOptionToggleGivesEveryRowOfTheSectionTheClickedRowsNewState() {
        var outline = CategoryOutline(string: "expense-2,income-5")
        let expenseKeys = ["expense-1", "expense-2", "expense-3", "expense-ungrouped"]
        // expense-1 was expanded, so it and the rest of its section collapse.
        outline.toggle("expense-1", allIn: expenseKeys)
        XCTAssertTrue(expenseKeys.allSatisfy { !outline.isExpanded($0) })
        XCTAssertFalse(outline.isExpanded("income-5"))
        // expense-3 is now collapsed, so the whole section expands; other sections untouched.
        outline.toggle("expense-3", allIn: expenseKeys)
        XCTAssertTrue(expenseKeys.allSatisfy { outline.isExpanded($0) })
        XCTAssertFalse(outline.isExpanded("income-5"))
    }

    func testExpandAllAndCollapseAll() {
        var outline = CategoryOutline(string: "expense-1,stale-9")
        outline.collapseAll(["expense-1", "expense-2", "income-3"])
        XCTAssertEqual(outline.collapsedKeys, ["expense-1", "expense-2", "income-3", "stale-9"])
        outline.expandAll()
        XCTAssertTrue(outline.collapsedKeys.isEmpty)
    }
}
