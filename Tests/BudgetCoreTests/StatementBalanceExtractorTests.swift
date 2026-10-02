import XCTest
@testable import BudgetCore

final class StatementBalanceExtractorTests: XCTestCase {
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func row(_ y: Int, _ m: Int, _ d: Int, _ amount: Int, _ balance: Int?) -> ParsedTransaction {
        ParsedTransaction(date: utc(y, m, d), rawDescription: "X", amountMinorUnits: amount, balanceAfterMinorUnits: balance)
    }

    /// Chronological fixture (pence). Opening balance 100_000.
    /// 15 Jan -1000 → 99_000 · 31 Jan -2000 → 97_000 · 1 Feb RENT -500 → 96_500 ·
    /// 1 Feb REFUND +3000 → 99_500 · 20 Feb -1500 → 98_000 · 2 Mar -250 → 97_750
    private var chronological: [ParsedTransaction] {
        [row(2026, 1, 15, -1000, 99_000), row(2026, 1, 31, -2000, 97_000),
         row(2026, 2, 1, -500, 96_500), row(2026, 2, 1, 3000, 99_500),
         row(2026, 2, 20, -1500, 98_000), row(2026, 3, 2, -250, 97_750)]
    }

    private func points(_ result: StatementBalanceResult, file: StaticString = #filePath, line: UInt = #line) -> [StatementBalancePoint] {
        guard case .available(let points) = result else {
            XCTFail("expected .available, got \(result)", file: file, line: line)
            return []
        }
        return points
    }

    private var expectedPoints: [StatementBalancePoint] {
        [StatementBalancePoint(date: utc(2026, 2, 1), balanceMinorUnits: 99_500, isClosing: false),
         StatementBalancePoint(date: utc(2026, 3, 1), balanceMinorUnits: 98_000, isClosing: false),
         StatementBalancePoint(date: utc(2026, 3, 2), balanceMinorUnits: 97_750, isClosing: true)]
    }

    // The real bank export is newest-first, with several rows per day in reverse order.
    func testNewestFirstFileWithSameDayRowsResolvesOrder() {
        let newestFirst = Array(chronological.reversed())
        XCTAssertEqual(points(StatementBalanceExtractor.extract(from: newestFirst)), expectedPoints)
    }

    func testOldestFirstFileGivesTheSamePoints() {
        XCTAssertEqual(points(StatementBalanceExtractor.extract(from: chronological)), expectedPoints)
    }

    // The 1 Feb point is the balance after BOTH rows dated 1 Feb (the rent and the refund).
    func testBalanceOnTheFirstIncludesThatDaysTransactions() {
        XCTAssertEqual(points(StatementBalanceExtractor.extract(from: chronological)).first?.balanceMinorUnits, 99_500)
    }

    func testQuietFirstOfMonthCarriesThePreviousBalance() {
        let rows = [row(2026, 1, 10, -1000, 99_000), row(2026, 2, 20, -2000, 97_000)]
        XCTAssertEqual(points(StatementBalanceExtractor.extract(from: rows)), [
            StatementBalancePoint(date: utc(2026, 2, 1), balanceMinorUnits: 99_000, isClosing: false),
            StatementBalancePoint(date: utc(2026, 2, 20), balanceMinorUnits: 97_000, isClosing: true)
        ])
    }

    func testLastTransactionOnAFirstYieldsASingleClosingPoint() {
        let rows = [row(2026, 1, 15, -1000, 99_000), row(2026, 2, 1, -500, 98_500)]
        XCTAssertEqual(points(StatementBalanceExtractor.extract(from: rows)), [
            StatementBalancePoint(date: utc(2026, 2, 1), balanceMinorUnits: 98_500, isClosing: true)
        ])
    }

    func testFirstTransactionOnAFirstIncludesThatDate() {
        let rows = [row(2026, 1, 1, -1000, 99_000), row(2026, 1, 15, -500, 98_500)]
        XCTAssertEqual(points(StatementBalanceExtractor.extract(from: rows)), [
            StatementBalancePoint(date: utc(2026, 1, 1), balanceMinorUnits: 99_000, isClosing: false),
            StatementBalancePoint(date: utc(2026, 1, 15), balanceMinorUnits: 98_500, isClosing: true)
        ])
    }

    func testSingleRowFileHasOnlyAClosingPoint() {
        XCTAssertEqual(points(StatementBalanceExtractor.extract(from: [row(2026, 1, 15, -1000, 99_000)])), [
            StatementBalancePoint(date: utc(2026, 1, 15), balanceMinorUnits: 99_000, isClosing: true)
        ])
    }

    func testMonthStartPointsCrossAYearBoundary() {
        let rows = [row(2025, 12, 20, -100, 9_900), row(2026, 1, 5, -100, 9_800)]
        XCTAssertEqual(points(StatementBalanceExtractor.extract(from: rows)), [
            StatementBalancePoint(date: utc(2026, 1, 1), balanceMinorUnits: 9_900, isClosing: false),
            StatementBalancePoint(date: utc(2026, 1, 5), balanceMinorUnits: 9_800, isClosing: true)
        ])
    }

    func testBalancesThatDoNotAddUpAreUnverified() {
        var rows = chronological
        rows[3] = row(2026, 2, 1, 3000, 123_456) // breaks the chain
        guard case .unverified = StatementBalanceExtractor.extract(from: rows) else {
            return XCTFail("expected .unverified")
        }
    }

    func testOneMissingBalanceIsUnverified() {
        var rows = chronological
        rows[2] = row(2026, 2, 1, -500, nil)
        guard case .unverified = StatementBalanceExtractor.extract(from: rows) else {
            return XCTFail("expected .unverified")
        }
    }

    func testNoBalancesAtAllIsNotProvided() {
        let rows = [row(2026, 1, 15, -1000, nil), row(2026, 1, 16, -500, nil)]
        XCTAssertEqual(StatementBalanceExtractor.extract(from: rows), .notProvided)
        XCTAssertEqual(StatementBalanceExtractor.extract(from: []), .notProvided)
    }
}
