import XCTest
@testable import BudgetCore

final class CSVStatementParserTests: XCTestCase {
    func testSplitsQuotedFieldsWithEmbeddedCommas() {
        let fields = CSVRowSplitter.split(line: "01/07/2026,\"SAINSBURYS, LONDON\",-45.64", delimiter: ",")
        XCTAssertEqual(fields, ["01/07/2026", "SAINSBURYS, LONDON", "-45.64"])
    }

    func testParsesLloydsStyleCSV() {
        let csv = """
        Date,Description,Amount
        01/07/2026,SAINSBURYS LONDON,-45.64
        02/07/2026,SALARY PAYMENT,2800.00
        """
        let profile = ImportProfile(
            accountId: 1,
            format: .csv,
            csvDelimiter: ",",
            csvDateColumnIndex: 0,
            csvDescriptionColumnIndex: 1,
            csvAmountColumnIndex: 2,
            csvDateFormat: "dd/MM/yyyy"
        )
        let result = CSVStatementParser.parse(csvText: csv, profile: profile)
        XCTAssertEqual(result.transactions.count, 2)
        XCTAssertEqual(result.transactions[0].rawDescription, "SAINSBURYS LONDON")
        XCTAssertEqual(result.transactions[0].amountMinorUnits, -4564)
        XCTAssertEqual(result.transactions[1].amountMinorUnits, 280000)
        XCTAssertTrue(result.unparsedLines.isEmpty)
    }

    func testFlagsUnparsableRows() {
        let csv = """
        Date,Description,Amount
        01/07/2026,SAINSBURYS LONDON,-45.64
        NOT-A-DATE,BROKEN ROW,notanumber
        """
        let profile = ImportProfile(
            accountId: 1, format: .csv, csvDelimiter: ",",
            csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2,
            csvDateFormat: "dd/MM/yyyy"
        )
        let result = CSVStatementParser.parse(csvText: csv, profile: profile)
        XCTAssertEqual(result.transactions.count, 1)
        XCTAssertEqual(result.unparsedLines.count, 1)
        XCTAssertTrue(result.unparsedLines[0].contains("BROKEN ROW"))
    }
}
