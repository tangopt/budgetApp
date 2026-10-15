import XCTest
import GRDB
@testable import BudgetCore

/// A synthetic statement in Revolut's export shape: date-time columns, a Fee column charged on
/// top of Amount, a State column (pending/reverted rows have no Completed Date or Balance),
/// and rows ordered by completed date rather than started date.
final class RevolutCSVImportTests: XCTestCase {
    static let header = "Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State,Balance"

    /// Opening balance 115.60. File order (by completed date):
    /// +100.00 → 215.60 · −23.59 fee 0.24 → 191.77 · pending · −12.00 (started a day EARLIER) → 179.77 ·
    /// reverted · +50.00 fee 1.00 → 228.77 (started 10 Feb) · −5.00 (started 9 Feb, completed last) → 223.77
    static let csv = """
    \(header)
    Topup,Current,2026-02-01 10:00:00,2026-02-01 10:00:05,Top up from bank,100.00,0.00,GBP,COMPLETED,215.60
    Card Payment,Current,2026-02-07 09:14:35,2026-02-08 12:09:47,Corner Bakery,-23.59,0.24,GBP,COMPLETED,191.77
    Card Payment,Current,2026-02-08 08:00:00,,Coffee Shop,-3.20,0.00,GBP,PENDING,
    Card Payment,Current,2026-02-06 18:30:00,2026-02-09 07:00:00,Book Store,-12.00,0.00,GBP,COMPLETED,179.77
    Card Payment,Current,2026-02-09 11:00:00,,Cinema,-9.50,0.00,GBP,REVERTED,
    Transfer,Current,2026-02-10 09:00:00,2026-02-10 09:00:01,Transfer from A Person,50.00,1.00,GBP,COMPLETED,228.77
    Card Payment,Current,2026-02-09 23:59:00,2026-02-11 06:00:00,Late Shop,-5.00,0.00,GBP,COMPLETED,223.77
    """

    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// The mapping the wizard suggests for this header.
    private func suggestedProfile(accountId: Int64 = 1) throws -> ImportProfile {
        let header = CSVRowSplitter.split(line: Self.header, delimiter: ",")
        let mapping = CSVColumnMapping(columnCount: header.count, suggestion: CSVColumnSuggester.suggest(header: header))
        return try XCTUnwrap(mapping.profile(accountId: accountId, dateFormat: "yyyy-MM-dd HH:mm:ss", negateAmounts: false, allowBalance: true))
    }

    func testSuggestedMappingForRevolutHeader() throws {
        let p = try suggestedProfile()
        XCTAssertEqual(p.csvDateColumnIndex, 2) // Started Date, not Completed Date
        XCTAssertEqual(p.csvDescriptionColumnIndex, 4)
        XCTAssertEqual(p.csvAmountColumnIndex, 5)
        XCTAssertNil(p.csvCreditAmountColumnIndex)
        XCTAssertEqual(p.csvFeeColumnIndex, 6)
        XCTAssertEqual(p.csvStatusColumnIndex, 8)
        XCTAssertEqual(p.csvBalanceColumnIndex, 9)
    }

    func testDetectsTheDateTimeFormat() throws {
        let values = CSVStatementParser.splitLines(Self.csv).dropFirst().map { CSVRowSplitter.split(line: $0, delimiter: ",")[2] }
        XCTAssertEqual(CSVDateFormatDetector.candidates(values: Array(values)).first, "yyyy-MM-dd HH:mm:ss")
    }

    func testParsesCompletedRowsWithFeesAndSkipsPendingAndReverted() throws {
        let result = CSVStatementParser.parse(csvText: Self.csv, profile: try suggestedProfile())
        XCTAssertEqual(result.unparsedLines, [])
        XCTAssertEqual(result.skippedRows, 2)
        XCTAssertEqual(result.transactions.map(\.rawDescription),
                       ["Top up from bank", "Corner Bakery", "Book Store", "Transfer from A Person", "Late Shop"])
        XCTAssertEqual(result.transactions.map(\.amountMinorUnits), [10_000, -2_383, -1_200, 4_900, -500])
        XCTAssertEqual(result.transactions.map(\.date),
                       [utc(2026, 2, 1), utc(2026, 2, 7), utc(2026, 2, 6), utc(2026, 2, 10), utc(2026, 2, 9)])
        XCTAssertEqual(result.transactions.map(\.balanceAfterMinorUnits), [21_560, 19_177, 17_977, 22_877, 22_377])
    }

    /// Started-date order breaks the balance chain; file order holds it, so the closing balance
    /// is the last file row's (223.77) at the latest transaction date (10 Feb).
    func testClosingBalanceFollowsFileOrderWhenDatesAreOutOfOrder() throws {
        let rows = CSVStatementParser.parse(csvText: Self.csv, profile: try suggestedProfile()).transactions
        XCTAssertEqual(StatementBalanceExtractor.extract(from: rows), .available([
            StatementBalancePoint(date: utc(2026, 2, 1), balanceMinorUnits: 21_560, isClosing: false),
            StatementBalancePoint(date: utc(2026, 2, 10), balanceMinorUnits: 22_377, isClosing: true)
        ]))
    }

    func testStagingReportsSkippedRowsAndAClosingBalance() async throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try await manager.dbQueue.write { db in try CategorySeeder.seedDefaults(db) }
        var account = Account(name: "Revolut", currency: .gbp, kind: .cash, trackingMode: .imported)
        try await manager.dbQueue.write { db in try account.insert(db) }
        let coordinator = ImportCoordinator(dbQueue: manager.dbQueue, categorizationService: CategorizationService(categorizer: FakeCategorizer()))

        let staged = try await coordinator.stageCSVImport(csvText: Self.csv, profile: try suggestedProfile(accountId: account.id!), accountId: account.id!)
        XCTAssertEqual(staged.staged.count, 5)
        XCTAssertEqual(staged.skippedRowCount, 2)
        XCTAssertEqual(staged.unparsedLines, [])
        guard case .available(let points) = staged.statementBalances else { return XCTFail("expected balances") }
        XCTAssertEqual(points.last, StatementBalancePoint(date: utc(2026, 2, 10), balanceMinorUnits: 22_377, isClosing: true))
    }
}
