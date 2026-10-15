import XCTest
@testable import BudgetCore
import struct BudgetCore.Category

final class GridOutlineTests: XCTestCase {
    private let home = CategoryGroup(id: 1, name: "Home")
    private let car = CategoryGroup(id: 2, name: "Car")

    private var expenses: [Category] {
        [
            Category(id: 10, name: "Rent", type: .expense, groupId: 1),
            Category(id: 14, name: "Groceries", type: .expense),
            Category(id: 13, name: "Fuel", type: .expense, groupId: 2),
            Category(id: 11, name: "Council Tax", type: .expense, groupId: 1),
            Category(id: 15, name: "Orphan", type: .expense, groupId: 99)
        ]
    }

    private var groups: [CategoryGroup] { [home, car] }
    private let section = GridOutline.sectionKey(.expense)

    private func labels(_ rows: [GridOutline.Row]) -> [String] {
        rows.map {
            switch $0 {
            case .category(let category): return category.name
            case .groupHeader(let group, let members): return "[\(group.name): \(members.map(\.name).joined(separator: ", "))]"
            case .groupChild(let category): return "  \(category.name)"
            }
        }
    }

    func testGroupsCollapsedByDefaultInFirstSeenOrderAndUnknownGroupsLeftOut() {
        let rows = GridOutline().rows(section: section, categories: expenses, groups: groups)
        XCTAssertEqual(labels(rows), ["[Home: Rent, Council Tax]", "Groceries", "[Car: Fuel]"])
    }

    func testExpandedGroupShowsItsMembers() {
        let outline = GridOutline(expandedGroupIds: [1])
        XCTAssertEqual(labels(outline.rows(section: section, categories: expenses, groups: groups)),
                       ["[Home: Rent, Council Tax]", "  Rent", "  Council Tax", "Groceries", "[Car: Fuel]"])
    }

    func testCollapsedSectionHasNoBodyRowsWhateverItsGroups() {
        var outline = GridOutline(expandedGroupIds: [1, 2])
        outline.toggleSection(section)
        XCTAssertTrue(outline.isCollapsed(section))
        XCTAssertEqual(outline.rows(section: section, categories: expenses, groups: groups), [])
        // Other sections are unaffected.
        XCTAssertFalse(outline.isCollapsed(GridOutline.sectionKey(.income)))
        outline.toggleSection(section)
        XCTAssertEqual(outline.rows(section: section, categories: expenses, groups: groups).count, 6)
    }

    func testGroupIdsInRowOrder() {
        XCTAssertEqual(GridOutline.groupIds(categories: expenses, groups: groups), [1, 2])
        XCTAssertEqual(GridOutline.groupIds(categories: [Category(id: 1, name: "A", type: .income)], groups: groups), [])
    }

    func testToggleGroup() {
        var outline = GridOutline()
        outline.toggleGroup(1)
        XCTAssertTrue(outline.isExpanded(1))
        outline.toggleGroup(1)
        XCTAssertFalse(outline.isExpanded(1))
    }

    func testOptionToggleAppliesTheClickedGroupsNewStateToTheWholeSection() {
        var outline = GridOutline(expandedGroupIds: [2, 7])
        // Home was collapsed: ⌥-click expands every group of the section.
        outline.toggleGroup(1, allIn: [1, 2, 3])
        XCTAssertEqual(outline.expandedGroupIds, [1, 2, 3, 7])
        // Car is now expanded: ⌥-click collapses them all, leaving other sections' groups alone.
        outline.toggleGroup(2, allIn: [1, 2, 3])
        XCTAssertEqual(outline.expandedGroupIds, [7])
    }

    func testExpandAndCollapseAll() {
        var outline = GridOutline(expandedGroupIds: [1, 9])
        outline.setGroups([1, 2], expanded: true)
        XCTAssertEqual(outline.expandedGroupIds, [1, 2, 9])
        outline.setGroups([1, 2], expanded: false)
        XCTAssertEqual(outline.expandedGroupIds, [9])
    }

    func testStoredFormRoundTripsAndIgnoresJunk() {
        let outline = GridOutline(collapsedSections: ["income", GridOutline.accountsSection], expandedGroupIds: [12, 3])
        XCTAssertEqual(outline.sectionsString, "accounts,income")
        XCTAssertEqual(outline.groupsString, "3,12")
        XCTAssertEqual(GridOutline(sectionsString: outline.sectionsString, groupsString: outline.groupsString), outline)

        let messy = GridOutline(sectionsString: " expense,,reserved ", groupsString: "4, x,,-,5")
        XCTAssertEqual(messy.collapsedSections, ["expense", "reserved"])
        XCTAssertEqual(messy.expandedGroupIds, [4, 5])
        XCTAssertEqual(GridOutline(sectionsString: "", groupsString: ""), GridOutline())
    }

    func testUnknownExpandedGroupIdsAreHarmless() {
        let outline = GridOutline(expandedGroupIds: [404])
        XCTAssertEqual(labels(outline.rows(section: section, categories: expenses, groups: groups)),
                       ["[Home: Rent, Council Tax]", "Groceries", "[Car: Fuel]"])
    }
}
