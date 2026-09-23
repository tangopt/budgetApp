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

    func testParsesZeroAmountsWithVariantSpellings() {
        let csv = """
        Date,Description,Amount
        01/07/2026,TRANSACTION ONE,0
        02/07/2026,TRANSACTION TWO,0.00
        03/07/2026,TRANSACTION THREE,0.0
        04/07/2026,TRANSACTION FOUR,0.000
        """
        let profile = ImportProfile(
            accountId: 1, format: .csv, csvDelimiter: ",",
            csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2,
            csvDateFormat: "dd/MM/yyyy"
        )
        let result = CSVStatementParser.parse(csvText: csv, profile: profile)
        XCTAssertEqual(result.transactions.count, 4)
        XCTAssertEqual(result.transactions[0].amountMinorUnits, 0)
        XCTAssertEqual(result.transactions[1].amountMinorUnits, 0)
        XCTAssertEqual(result.transactions[2].amountMinorUnits, 0)
        XCTAssertEqual(result.transactions[3].amountMinorUnits, 0)
        XCTAssertTrue(result.unparsedLines.isEmpty)
    }

    func testRejectsPrecisionLossZeroAmounts() {
        let csv = """
        Date,Description,Amount
        01/07/2026,TRANSACTION ONE,0.001
        02/07/2026,TRANSACTION TWO,0.009
        """
        let profile = ImportProfile(
            accountId: 1, format: .csv, csvDelimiter: ",",
            csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2,
            csvDateFormat: "dd/MM/yyyy"
        )
        let result = CSVStatementParser.parse(csvText: csv, profile: profile)
        XCTAssertEqual(result.transactions.count, 0)
        XCTAssertEqual(result.unparsedLines.count, 2)
    }

    let standardProfile = ImportProfile(
        accountId: 1, format: .csv, csvDelimiter: ",",
        csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2,
        csvDateFormat: "dd/MM/yyyy"
    )

    // C2: "\r\n" is a single Swift Character, so splitting on "\n" alone treated a
    // whole Windows-line-ending file as one line and imported nothing.
    func testParsesCRLFLineEndings() {
        let csv = "Date,Description,Amount\r\n01/07/2026,SAINSBURYS LONDON,-45.64\r\n02/07/2026,SALARY PAYMENT,2800.00\r\n"
        let result = CSVStatementParser.parse(csvText: csv, profile: standardProfile)
        XCTAssertEqual(result.transactions.count, 2)
        XCTAssertEqual(result.transactions[1].rawDescription, "SALARY PAYMENT")
        XCTAssertEqual(result.transactions[1].amountMinorUnits, 280000)
        XCTAssertTrue(result.unparsedLines.isEmpty)
    }

    func testParsesBareCRLineEndings() {
        let csv = "Date,Description,Amount\r01/07/2026,SAINSBURYS LONDON,-45.64\r"
        let result = CSVStatementParser.parse(csvText: csv, profile: standardProfile)
        XCTAssertEqual(result.transactions.count, 1)
    }

    // I8: dates are parsed as UTC midnight regardless of the machine's timezone,
    // consistent with the UTC calendars used for pay periods and fingerprints.
    func testParsesDatesAsUTCMidnight() {
        let csv = "Date,Description,Amount\n26/06/2026,SALARY,2800.00"
        let result = CSVStatementParser.parse(csvText: csv, profile: standardProfile)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let expected = utc.date(from: DateComponents(year: 2026, month: 6, day: 26))!
        XCTAssertEqual(result.transactions[0].date, expected)
    }

    func testParsesQuotedThousandsSeparatedAmount() {
        let csv = "Date,Description,Amount\n01/07/2026,BONUS,\"1,234.56\""
        let result = CSVStatementParser.parse(csvText: csv, profile: standardProfile)
        XCTAssertEqual(result.transactions.first?.amountMinorUnits, 123456)
    }

    func testRejectsAmountWithTrailingGarbage() {
        let csv = "Date,Description,Amount\n01/07/2026,SHOP,12abc"
        let result = CSVStatementParser.parse(csvText: csv, profile: standardProfile)
        XCTAssertTrue(result.transactions.isEmpty)
        XCTAssertEqual(result.unparsedLines.count, 1)
    }

    func testMoneyParseMinorUnits() {
        XCTAssertEqual(Money.parseMinorUnits("1,234.56"), 123456)
        XCTAssertEqual(Money.parseMinorUnits("£300"), 30000)
        XCTAssertEqual(Money.parseMinorUnits(" -45.6 "), -4560)
        XCTAssertEqual(Money.parseMinorUnits(".5"), 50)
        XCTAssertNil(Money.parseMinorUnits(""))
        XCTAssertNil(Money.parseMinorUnits("abc"))
        XCTAssertNil(Money.parseMinorUnits("1.2.3"))
        XCTAssertNil(Money.parseMinorUnits("1.005"))
    }
}
