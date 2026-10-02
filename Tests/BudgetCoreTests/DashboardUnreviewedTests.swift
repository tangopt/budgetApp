import XCTest
@testable import BudgetCore

final class DashboardUnreviewedTests: XCTestCase {
    private typealias F = DashboardFixture
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { F.date(y, m, d) }

    func testCountsAndSumsOutflowOfUnreviewedTransactionsInTheRequestedYearOnly() {
        let input = F.input(today: date(2026, 10, 14), transactions: [
            // 2026: uncategorised, pending review, and a categorised-but-pending one.
            F.txn(1, date(2026, 1, 1), -3_000, category: nil, status: .confirmed),
            F.txn(2, date(2026, 6, 15), -2_000, category: F.groceriesId, status: .pendingReview),
            F.txn(3, date(2026, 12, 31), -500, category: nil, status: .pendingReview),
            // 2026 but reviewed: not counted.
            F.txn(4, date(2026, 3, 3), -9_000, category: F.rentId),
            // Other years: not counted for 2026.
            F.txn(5, date(2025, 12, 31), -7_000, category: nil),
            F.txn(6, date(2027, 1, 1), -8_000, category: nil, status: .pendingReview)
        ])
        XCTAssertEqual(DashboardCalculator.unreviewed(input, year: 2026), UnreviewedSummary(count: 3, outflowMinorUnits: 5_500))
        XCTAssertEqual(DashboardCalculator.unreviewed(input, year: 2025), UnreviewedSummary(count: 1, outflowMinorUnits: 7_000))
        XCTAssertEqual(DashboardCalculator.unreviewed(input, year: 2027), UnreviewedSummary(count: 1, outflowMinorUnits: 8_000))
    }

    func testAYearWithNoUnreviewedTransactionsIsZero() {
        let input = F.input(today: date(2026, 10, 14), transactions: [
            F.txn(1, date(2026, 10, 1), -100_000, category: F.rentId),
            F.txn(2, date(2026, 10, 2), 5_000, category: nil, status: .pendingReview)
        ])
        XCTAssertEqual(DashboardCalculator.unreviewed(input, year: 2024), UnreviewedSummary(count: 0, outflowMinorUnits: 0))
        XCTAssertEqual(DashboardCalculator.unreviewed(F.input(today: date(2026, 10, 14)), year: 2026), UnreviewedSummary(count: 0, outflowMinorUnits: 0))
    }

    func testPositiveUnreviewedAmountsCountButAddNothingToOutflow() {
        let input = F.input(today: date(2026, 10, 14), transactions: [
            F.txn(1, date(2026, 4, 1), 25_000, category: nil),
            F.txn(2, date(2026, 4, 2), -4_000, category: nil, status: .pendingReview),
            F.txn(3, date(2026, 4, 3), 1_000, category: F.salaryId, status: .pendingReview)
        ])
        XCTAssertEqual(DashboardCalculator.unreviewed(input, year: 2026), UnreviewedSummary(count: 3, outflowMinorUnits: 4_000))
    }
}
