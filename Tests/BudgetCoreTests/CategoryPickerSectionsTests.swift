import XCTest
@testable import BudgetCore

final class CategoryPickerSectionsTests: XCTestCase {
    let groups = [CategoryGroup(id: 2, name: "Living"), CategoryGroup(id: 1, name: "Fun")]
    let categories = [
        Category(id: 1, name: "Groceries", type: .expense, groupId: 2),
        Category(id: 2, name: "Bills", type: .expense, groupId: 2),
        Category(id: 3, name: "Eating Out", type: .expense, groupId: 1),
        Category(id: 4, name: "Salary", type: .income),
        Category(id: 5, name: "Transfer", type: .transfer),
        Category(id: 6, name: "Holiday Reserve", type: .expense, groupId: 1, isReserved: true),
        Category(id: 7, name: "Cash", type: .expense)
    ]

    func build(suggestedId: Int64? = nil, recentIds: [Int64] = [], amount: Int? = -100, query: String = "", showAll: Bool = false) -> [CategoryPickerSection] {
        CategoryPickerSections.build(categories: categories, groups: groups, suggestedId: suggestedId, recentIds: recentIds,
                                     amountMinorUnits: amount, query: query, showAll: showAll)
    }

    func titles(_ sections: [CategoryPickerSection]) -> [String?] { sections.map(\.title) }
    func names(_ section: CategoryPickerSection?) -> [String] { section?.entries.map(\.title) ?? [] }
    func section(_ sections: [CategoryPickerSection], _ title: String) -> CategoryPickerSection? { sections.first { $0.title == title } }

    func testOrderGroupsAlphabeticalUngroupedLastAndReservesExcluded() {
        let sections = build(suggestedId: 3, recentIds: [1])
        XCTAssertEqual(titles(sections), [nil, "Suggested", "Recent", "Fun", "Living", "Other", nil])
        XCTAssertEqual(names(sections.first), ["Uncategorized"])
        XCTAssertEqual(names(section(sections, "Living")), ["Bills", "Groceries"])
        XCTAssertEqual(names(section(sections, "Fun")), ["Eating Out"])
        XCTAssertEqual(names(section(sections, "Other")), ["Cash", "Transfer"])
        XCTAssertEqual(sections.last?.entries.map(\.action), [.showAll])
    }

    func testSignFilterMoneyOutAndMoneyIn() {
        let out = build(amount: -100).flatMap(\.entries).map(\.title)
        XCTAssertFalse(out.contains("Salary"))
        XCTAssertTrue(out.contains("Transfer"))
        let incoming = build(amount: 100).flatMap(\.entries).map(\.title)
        XCTAssertEqual(incoming.filter { $0 != "Uncategorized" && $0 != "Show all categories" }, ["Salary", "Transfer"])
    }

    func testShowAllOrNoSignRemovesFilterAndShowAllRow() {
        for sections in [build(showAll: true), build(amount: nil), build(amount: 0)] {
            let entries = sections.flatMap(\.entries)
            XCTAssertTrue(entries.map(\.title).contains("Salary"))
            XCTAssertFalse(entries.contains { $0.action == .showAll })
        }
    }

    func testRecentIsSignFilteredButSuggestionIsNot() {
        let sections = build(suggestedId: 4, recentIds: [4, 1], amount: -100)
        XCTAssertEqual(names(section(sections, "Suggested")), ["Salary"])
        XCTAssertEqual(names(section(sections, "Recent")), ["Groceries"])
    }

    func testReserveNeverSuggestedOrRecent() {
        let sections = build(suggestedId: 6, recentIds: [6])
        XCTAssertNil(section(sections, "Suggested"))
        XCTAssertNil(section(sections, "Recent"))
    }

    func testSearchMatchesNameOrGroupName() {
        XCTAssertEqual(build(query: "gro").flatMap(\.entries).filter { $0.action != .showAll }.map(\.title), ["Groceries"])
        XCTAssertEqual(names(section(build(query: "living"), "Living")), ["Bills", "Groceries"])
    }

    func testUncategorizedOnlyWhenQueryEmptyOrPrefix() {
        XCTAssertFalse(build(query: "e").flatMap(\.entries).contains { $0.title == "Uncategorized" })
        XCTAssertFalse(build(query: "cat").flatMap(\.entries).contains { $0.title == "Uncategorized" })
        XCTAssertTrue(build(query: "Unc").flatMap(\.entries).contains { $0.title == "Uncategorized" })
    }

    func testInitialHighlightIsSelectionWhenNotSearchingElseFirstCategory() {
        let entries = build(suggestedId: 3).flatMap(\.entries)
        XCTAssertEqual(entries[CategoryPickerSections.initialHighlight(entries: entries, selection: 1, query: "")].action, .pick(1))
        XCTAssertEqual(entries[CategoryPickerSections.initialHighlight(entries: entries, selection: nil, query: "")].action, .pick(3))

        // Typing a letter then Return must never land on "Uncategorized".
        let searched = build(query: "u").flatMap(\.entries)
        XCTAssertEqual(searched.first?.title, "Uncategorized")
        let index = CategoryPickerSections.initialHighlight(entries: searched, selection: 1, query: "u")
        XCTAssertNotEqual(searched[index].action, .pick(nil))
        XCTAssertNotEqual(searched[index].action, .showAll)
    }
}
