import XCTest
@testable import BudgetCore

/// "Payments cover what's due — mark as paid?" (small batch item 3).
final class TaxPaymentCoverageTests: XCTestCase {
    private func payment(_ amount: Int, kind: HMRCPaymentKind = .balancingPayment, year: Int = 2024) -> HMRCPayment {
        HMRCPayment(personId: 1, startYear: year, date: Date(timeIntervalSince1970: 1_750_000_000), amountMinorUnits: amount, kind: kind)
    }

    private func suggests(_ status: TaxYearStatus = .filed, due: Int, _ payments: [HMRCPayment]) -> Bool {
        TaxPaymentCoverage.suggestsMarkingPaid(status: status, balancingDue: due, payments: payments, startYear: 2024)
    }

    func testExactAndWithinAPoundCover() {
        XCTAssertTrue(suggests(due: 123_456, [payment(123_456)]))
        XCTAssertTrue(suggests(due: 123_456, [payment(123_400)]))
        XCTAssertTrue(suggests(due: 123_456, [payment(123_356)]))
        XCTAssertTrue(suggests(due: 123_456, [payment(200_000)]))
    }

    func testSeveralPaymentsAddUp() {
        XCTAssertTrue(suggests(due: 100_000, [payment(60_000), payment(40_000)]))
        XCTAssertFalse(suggests(due: 100_000, [payment(60_000), payment(39_000)]))
    }

    func testShortOfDueOrNothingRecordedDoesNotCover() {
        XCTAssertFalse(suggests(due: 100_000, [payment(99_000)]))
        XCTAssertFalse(suggests(due: 100_000, []))
        // Nothing due (or a repayment): nothing to suggest.
        XCTAssertFalse(suggests(due: 0, [payment(100)]))
        XCTAssertFalse(suggests(due: -5_000, [payment(100)]))
    }

    func testOnlyBalancingPaymentsOfThatYearCount() {
        XCTAssertFalse(suggests(due: 100_000, [payment(100_000, kind: .firstPaymentOnAccount)]))
        XCTAssertFalse(suggests(due: 100_000, [payment(100_000, year: 2023)]))
    }

    func testOnlyAFiledYearIsOffered() {
        for status in [TaxYearStatus.preparing, .ready, .paid] {
            XCTAssertFalse(suggests(status, due: 100_000, [payment(100_000)]), "\(status)")
        }
        XCTAssertTrue(suggests(.filed, due: 100_000, [payment(100_000)]))
    }
}
