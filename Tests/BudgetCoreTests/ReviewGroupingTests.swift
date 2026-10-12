import XCTest
@testable import BudgetCore

final class ReviewGroupingTests: XCTestCase {
    struct Row: Identifiable {
        let id: Int
        let description: String
    }

    private func groups(_ rows: [Row], scope: String = "s") -> [ReviewGroup<Row>] {
        ReviewGrouping.groups(rows, scope: scope, description: \.description)
    }

    func testGroupsByMerchantKeyInFirstAppearanceOrder() {
        let rows = [Row(id: 1, description: "TESCO STORES 2041"), Row(id: 2, description: "PLAYTOMIC* PI-5B20"),
                    Row(id: 3, description: "TESCO STORES 3312"), Row(id: 4, description: "PLAYTOMIC* PI-793A"),
                    Row(id: 5, description: "TFL TRAVEL CH")]
        let result = groups(rows)
        XCTAssertEqual(result.map(\.key), ["TESCO STORES", "PLAYTOMIC", "TFL TRAVEL CH"])
        XCTAssertEqual(result.map { $0.rows.map(\.id) }, [[1, 3], [2, 4], [5]])
        XCTAssertEqual(result.map(\.isMultiRow), [true, true, false])
    }

    // Spec §2: truncated variants and processor purchases group together under the
    // longer key / the processor name.
    func testGroupsByReviewKey() {
        let rows = [Row(id: 1, description: "SAINSBURYS S/MKT"), Row(id: 2, description: "AMAZON* NQ7KP7EB5"),
                    Row(id: 3, description: "SAINSBURYS S/MKTS"), Row(id: 4, description: "AMAZON* 2K4LL0QX1")]
        let result = groups(rows)
        XCTAssertEqual(result.map(\.key), ["SAINSBURYS S/MKTS", "AMAZON"])
        XCTAssertEqual(result.map { $0.rows.map(\.id) }, [[1, 3], [2, 4]])
        XCTAssertEqual(result.map(\.isProcessorGroup), [false, true])
    }

    // Keys come from the whole review, so a section holding only the truncated variant
    // still names its group after the longer key.
    func testGroupsByPrecomputedKeys() {
        let rows = [Row(id: 1, description: "SAINSBURYS S/MKT"), Row(id: 2, description: "TFL TRAVEL CH")]
        let keyById = [1: "SAINSBURYS S/MKTS", 2: "TFL TRAVEL CH"]
        let result = ReviewGrouping.groups(rows, scope: "s", key: { keyById[$0.id]! })
        XCTAssertEqual(result.map(\.key), ["SAINSBURYS S/MKTS", "TFL TRAVEL CH"])
    }

    func testGroupIdIncludesScope() {
        let rows = [Row(id: 1, description: "TESCO 1"), Row(id: 2, description: "TESCO 2")]
        XCTAssertEqual(groups(rows, scope: "ready").first?.id, .group(scope: "ready", key: "TESCO"))
        XCTAssertNotEqual(groups(rows, scope: "ready").first?.id, groups(rows, scope: "attention").first?.id)
    }

    func testEmptyInputHasNoGroups() {
        XCTAssertTrue(groups([]).isEmpty)
    }

    func testCategoryStateUniformOrMixed() {
        XCTAssertEqual(ReviewGrouping.categoryState(of: [3, 3]), .uniform(3))
        XCTAssertEqual(ReviewGrouping.categoryState(of: [nil, nil]), .uniform(nil))
        XCTAssertEqual(ReviewGrouping.categoryState(of: [3, nil]), .mixed)
        XCTAssertEqual(ReviewGrouping.categoryState(of: [3, 4]), .mixed)
        XCTAssertEqual(ReviewGrouping.categoryState(of: []), .uniform(nil))
    }

    func testDateRangeAndTotal() {
        let early = Date(timeIntervalSince1970: 0)
        let late = Date(timeIntervalSince1970: 86_400 * 3)
        XCTAssertEqual(ReviewGrouping.dateRange([late, early, late]), early...late)
        XCTAssertNil(ReviewGrouping.dateRange([]))
        XCTAssertEqual(ReviewGrouping.total([-450, -1200, 300]), -1350)
    }

    func testSharedSign() {
        XCTAssertEqual(ReviewGrouping.sharedSign([-450, -1200]), -1)
        XCTAssertEqual(ReviewGrouping.sharedSign([450, 0, 1200]), 1)
        XCTAssertNil(ReviewGrouping.sharedSign([-450, 1200]))
        XCTAssertNil(ReviewGrouping.sharedSign([0]))
        XCTAssertNil(ReviewGrouping.sharedSign([]))
    }

    // What the Remember checkbox shows is what gets saved: an explicit choice wins,
    // otherwise rows of a 2+ row group learn and a single row doesn't.
    func testRemembersResolvesAnUnsetChoiceFromTheGroupSize() {
        XCTAssertTrue(ReviewGrouping.remembers(choice: nil, groupRowCount: 2))
        XCTAssertFalse(ReviewGrouping.remembers(choice: nil, groupRowCount: 1))
        XCTAssertFalse(ReviewGrouping.remembers(choice: false, groupRowCount: 3))
        XCTAssertTrue(ReviewGrouping.remembers(choice: true, groupRowCount: 1))
    }

    // Spec §2/§3: a processor group defaults off; a single row defaults on once its
    // category was picked by hand; an explicit choice always wins.
    func testRemembersDefaultsForProcessorGroupsAndHandPickedSingleRows() {
        XCTAssertFalse(ReviewGrouping.remembers(choice: nil, groupRowCount: 3, isProcessorGroup: true, pickedByHand: false))
        XCTAssertFalse(ReviewGrouping.remembers(choice: nil, groupRowCount: 3, isProcessorGroup: true, pickedByHand: true))
        XCTAssertTrue(ReviewGrouping.remembers(choice: true, groupRowCount: 3, isProcessorGroup: true, pickedByHand: false))
        XCTAssertTrue(ReviewGrouping.remembers(choice: nil, groupRowCount: 3, isProcessorGroup: false, pickedByHand: false))
        XCTAssertFalse(ReviewGrouping.remembers(choice: nil, groupRowCount: 1, isProcessorGroup: false, pickedByHand: false))
        XCTAssertTrue(ReviewGrouping.remembers(choice: nil, groupRowCount: 1, isProcessorGroup: false, pickedByHand: true))
        XCTAssertFalse(ReviewGrouping.remembers(choice: false, groupRowCount: 1, isProcessorGroup: false, pickedByHand: true))
        XCTAssertTrue(ReviewGrouping.remembers(choice: nil, groupRowCount: 1, isProcessorGroup: true, pickedByHand: true))
    }

    func testRememberDefaultForProcessorGroupsIsOff() {
        XCTAssertFalse(ReviewGrouping.rememberDefault(rowCount: 4, isProcessorGroup: true))
        XCTAssertTrue(ReviewGrouping.rememberDefault(rowCount: 1, pickedByHand: true))
    }

    func testRememberDefaultsOnForTwoOrMoreRows() {
        XCTAssertFalse(ReviewGrouping.rememberDefault(rowCount: 0))
        XCTAssertFalse(ReviewGrouping.rememberDefault(rowCount: 1))
        XCTAssertTrue(ReviewGrouping.rememberDefault(rowCount: 2))
        XCTAssertTrue(ReviewGrouping.rememberDefault(rowCount: 7))
    }

    func testSelectedRowIdsExpandsGroupsInDisplayOrderWithoutDuplicates() {
        let rows = [Row(id: 1, description: "TESCO 1"), Row(id: 2, description: "AMAZON"), Row(id: 3, description: "TESCO 2")]
        let grouped = groups(rows)
        let selection: Set<ReviewSelectionId<Int>> = [.row(2), .group(scope: "s", key: "TESCO"), .row(3)]
        XCTAssertEqual(ReviewGrouping.selectedRowIds(selection, in: grouped), [1, 3, 2])
    }

    func testSelectedRowIdsIgnoresUnknownIds() {
        let grouped = groups([Row(id: 1, description: "TESCO 1")])
        let selection: Set<ReviewSelectionId<Int>> = [.row(9), .group(scope: "other", key: "TESCO"), .row(1)]
        XCTAssertEqual(ReviewGrouping.selectedRowIds(selection, in: grouped), [1])
    }

    func testSingleRowGroupIsSelectedByRowId() {
        let grouped = groups([Row(id: 1, description: "TESCO 1")])
        XCTAssertEqual(grouped.first?.selectionId, .row(1))
        XCTAssertEqual(groups([Row(id: 1, description: "TESCO 1"), Row(id: 2, description: "TESCO 2")]).first?.selectionId, .group(scope: "s", key: "TESCO"))
    }

    func testVisibleItemsListsGroupRowsOnlyWhenExpanded() {
        let rows = [Row(id: 1, description: "TESCO 1"), Row(id: 2, description: "AMAZON"), Row(id: 3, description: "TESCO 2")]
        let grouped = groups(rows)
        let tesco = ReviewSelectionId<Int>.group(scope: "s", key: "TESCO")
        XCTAssertEqual(ReviewGrouping.visibleItems(grouped, expanded: []), [tesco, .row(2)])
        XCTAssertEqual(ReviewGrouping.visibleItems(grouped, expanded: [tesco]), [tesco, .row(1), .row(3), .row(2)])
    }

    func testStaleGroupIdDoesNotSelectASingleRowGroup() {
        let grouped = groups([Row(id: 1, description: "TESCO 1"), Row(id: 2, description: "AMAZON")])
        let selection: Set<ReviewSelectionId<Int>> = [.group(scope: "s", key: "TESCO")]
        XCTAssertEqual(ReviewGrouping.selectedRowIds(selection, in: grouped), [])
    }

    func testSelectableItemsIncludeEveryGroupAndRow() {
        let rows = [Row(id: 1, description: "TESCO 1"), Row(id: 2, description: "AMAZON"), Row(id: 3, description: "TESCO 2")]
        XCTAssertEqual(ReviewGrouping.selectableItems(groups(rows)), [.group(scope: "s", key: "TESCO"), .row(1), .row(3), .row(2)])
    }
}
