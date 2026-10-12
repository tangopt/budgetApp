import XCTest
@testable import BudgetCore

final class ReviewTabTests: XCTestCase {
    private func counts(_ needs: Int, _ ready: Int, _ confirmed: Int) -> [ReviewTab: Int] {
        [.needsAttention: needs, .ready: ready, .confirmed: confirmed]
    }

    // Spec §7: opens on Needs your attention, or Ready to confirm if Needs is empty.
    func testOpensOnNeedsOrReadyWhenNeedsIsEmpty() {
        XCTAssertEqual(ReviewTab.settled(current: .needsAttention, rowCounts: counts(2, 5, 0)), .needsAttention)
        XCTAssertEqual(ReviewTab.settled(current: .needsAttention, rowCounts: counts(0, 5, 0)), .ready)
    }

    func testStaysOnACurrentTabThatHasRows() {
        XCTAssertEqual(ReviewTab.settled(current: .ready, rowCounts: counts(2, 1, 3)), .ready)
        XCTAssertEqual(ReviewTab.settled(current: .confirmed, rowCounts: counts(2, 1, 3)), .confirmed)
    }

    // An emptied tab gives way to the first non-empty one in order: Needs → Ready → Confirmed.
    func testEmptiedTabSwitchesToTheFirstNonEmptyTab() {
        XCTAssertEqual(ReviewTab.settled(current: .needsAttention, rowCounts: counts(0, 0, 4)), .confirmed)
        XCTAssertEqual(ReviewTab.settled(current: .ready, rowCounts: counts(3, 0, 4)), .needsAttention)
        XCTAssertEqual(ReviewTab.settled(current: .ready, rowCounts: counts(0, 0, 4)), .confirmed)
        XCTAssertEqual(ReviewTab.settled(current: .confirmed, rowCounts: counts(0, 2, 0)), .ready)
    }

    func testEverythingEmptyKeepsTheCurrentTab() {
        XCTAssertEqual(ReviewTab.settled(current: .ready, rowCounts: counts(0, 0, 0)), .ready)
        XCTAssertEqual(ReviewTab.settled(current: .confirmed, rowCounts: [:]), .confirmed)
    }
}
