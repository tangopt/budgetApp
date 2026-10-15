import XCTest
@testable import BudgetCore
import struct BudgetCore.Category

final class CategorySectionsTests: XCTestCase {
    private let home = CategoryGroup(id: 1, name: "Home")
    private let car = CategoryGroup(id: 2, name: "Car")
    private let empty = CategoryGroup(id: 3, name: "Spare")
    private let reservesOnly = CategoryGroup(id: 4, name: "Buffers")

    private var categories: [Category] {
        [
            Category(id: 10, name: "Rent", type: .expense, groupId: 1),
            Category(id: 11, name: "Council Tax", type: .expense, groupId: 1),
            Category(id: 12, name: "Lodger", type: .income, groupId: 1),
            Category(id: 13, name: "Fuel", type: .expense, groupId: 2),
            Category(id: 14, name: "Groceries", type: .expense),
            Category(id: 15, name: "Orphan", type: .expense, groupId: 99),
            Category(id: 16, name: "Salary", type: .income),
            Category(id: 17, name: "Unexpected", type: .expense, groupId: 4, isReserved: true)
        ]
    }

    private func build(_ search: String = "") -> [CategorySection] {
        CategorySections.build(categories: categories, groups: [home, car, empty, reservesOnly], search: search)
    }

    private func names(_ list: [Category]) -> [String] { list.map(\.name) }

    func testMixedGroupBlocksHaveDistinctIdsAcrossSections() {
        let sections = build()
        let ids = sections.flatMap(\.groups).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        let homeIds = sections.flatMap(\.groups).filter { $0.group.id == 1 }.map(\.id)
        XCTAssertEqual(homeIds.count, 2)
        XCTAssertEqual(Set(homeIds).count, 2)
    }

    func testSectionsByTypeWithSortedGroupsThenUngrouped() {
        let sections = build()
        XCTAssertEqual(sections.map(\.type), [.expense, .income, .transfer])
        let expenses = sections[0]
        XCTAssertEqual(expenses.groups.map(\.group.name), ["Buffers", "Car", "Home", "Spare"])
        XCTAssertEqual(names(expenses.groups[2].categories), ["Council Tax", "Rent"])
        // Unknown group ids count as ungrouped; reserves never appear here.
        XCTAssertEqual(names(expenses.ungrouped), ["Groceries", "Orphan"])
    }

    func testAMixedGroupShowsInEachSectionWithThatTypesMembers() {
        let income = build()[1]
        XCTAssertEqual(income.groups.map(\.group.name), ["Home"])
        XCTAssertEqual(names(income.groups[0].categories), ["Lodger"])
        XCTAssertEqual(names(income.ungrouped), ["Salary"])
    }

    func testEmptyGroupsIncludingReserveOnlyOnesShowUnderExpenses() {
        let sections = build()
        XCTAssertTrue(sections[0].groups.contains { $0.group.name == "Spare" && $0.categories.isEmpty })
        XCTAssertTrue(sections[0].groups.contains { $0.group.name == "Buffers" && $0.categories.isEmpty })
        XCTAssertFalse(sections[1].groups.contains { $0.group.name == "Spare" })
    }

    func testUngroupedAndEverySectionStayWithoutASearchAsDropTargets() {
        let transfers = build()[2]
        XCTAssertTrue(transfers.groups.isEmpty)
        XCTAssertTrue(transfers.ungrouped.isEmpty)
    }

    func testSearchMatchesCategoryNamesCaseInsensitively() {
        let sections = build("rEnT")
        XCTAssertEqual(sections.map(\.type), [.expense])
        XCTAssertEqual(sections[0].groups.map(\.group.name), ["Home"])
        XCTAssertEqual(names(sections[0].groups[0].categories), ["Rent"])
        XCTAssertTrue(sections[0].ungrouped.isEmpty)
    }

    func testAMatchingGroupNameShowsAllItsMembers() {
        let sections = build("home")
        XCTAssertEqual(sections.map(\.type), [.expense, .income])
        XCTAssertEqual(names(sections[0].groups[0].categories), ["Council Tax", "Rent"])
        XCTAssertEqual(names(sections[1].groups[0].categories), ["Lodger"])
    }

    func testSearchShowsAnEmptyGroupOnlyWhenItsNameMatches() {
        XCTAssertEqual(build("spa").first?.groups.map(\.group.name), ["Spare"])
        XCTAssertFalse(build("fuel").first?.groups.contains { $0.group.name == "Spare" } ?? true)
    }

    func testAnEmptyGroupShowsInItsTypesSection() {
        let pay = CategoryGroup(id: 5, name: "Pay", type: .income)
        let moves = CategoryGroup(id: 6, name: "Moves", type: .transfer)
        let sections = CategorySections.build(categories: categories, groups: [home, pay, moves], search: "")
        XCTAssertFalse(sections[0].groups.contains { $0.group.name == "Pay" || $0.group.name == "Moves" })
        XCTAssertEqual(sections[1].groups.map(\.group.name), ["Home", "Pay"])
        XCTAssertEqual(sections[2].groups.map(\.group.name), ["Moves"])
    }

    func testAGroupWithMembersShowsWhereItsMembersAreWhateverItsType() {
        let incomeHome = CategoryGroup(id: 1, name: "Home", type: .income)
        let sections = CategorySections.build(categories: categories, groups: [incomeHome], search: "")
        XCTAssertEqual(sections[0].groups.map(\.group.name), ["Home"])
        XCTAssertEqual(sections[1].groups.map(\.group.name), ["Home"])
        XCTAssertTrue(sections[2].groups.isEmpty)
    }
}
