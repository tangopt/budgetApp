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

    // Real-world trigger: a UK current-account export (e.g. Lloyds) with separate
    // "Debit Amount"/"Credit Amount" columns instead of one signed "Amount" column —
    // previously unsupported, every credit row (salary, refunds, transfers in) silently
    // landed in unparsedLines.
    func testParsesSeparateDebitAndCreditColumns() {
        let csv = """
        Date,Description,Debit,Credit
        01/07/2026,TESCO,12.00,
        02/07/2026,SALARY,,2800.00
        """
        let profile = ImportProfile(
            accountId: 1, format: .csv, csvDelimiter: ",",
            csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2,
            csvCreditAmountColumnIndex: 3, csvDateFormat: "dd/MM/yyyy"
        )
        let result = CSVStatementParser.parse(csvText: csv, profile: profile)
        XCTAssertEqual(result.transactions.count, 2)
        XCTAssertEqual(result.transactions[0].rawDescription, "TESCO")
        XCTAssertEqual(result.transactions[0].amountMinorUnits, -1200)
        XCTAssertEqual(result.transactions[1].rawDescription, "SALARY")
        XCTAssertEqual(result.transactions[1].amountMinorUnits, 280000)
        XCTAssertTrue(result.unparsedLines.isEmpty)
    }

    // A debit/credit column's own value is conventionally unsigned (the column itself
    // already says which direction the money moved) — a debit value should become
    // negative even if the statement itself wrote it as a positive number, which is the
    // normal case this feature exists for.
    func testDebitColumnValueBecomesNegativeRegardlessOfItsOwnSign() {
        let csv = "Date,Description,Debit,Credit\n01/07/2026,TESCO,12.00,"
        let profile = ImportProfile(
            accountId: 1, format: .csv, csvDelimiter: ",",
            csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2,
            csvCreditAmountColumnIndex: 3, csvDateFormat: "dd/MM/yyyy"
        )
        let result = CSVStatementParser.parse(csvText: csv, profile: profile)
        XCTAssertEqual(result.transactions.first?.amountMinorUnits, -1200)
    }

    func testDebitCreditSplitTreatsBothColumnsBlankAsUnparsable() {
        let csv = "Date,Description,Debit,Credit\n01/07/2026,MYSTERY ROW,,"
        let profile = ImportProfile(
            accountId: 1, format: .csv, csvDelimiter: ",",
            csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2,
            csvCreditAmountColumnIndex: 3, csvDateFormat: "dd/MM/yyyy"
        )
        let result = CSVStatementParser.parse(csvText: csv, profile: profile)
        XCTAssertTrue(result.transactions.isEmpty)
        XCTAssertEqual(result.unparsedLines.count, 1)
    }

    // Genuinely ambiguous data (both columns somehow populated) must never be guessed
    // at — the row is rejected for manual entry instead of silently picking one value.
    func testDebitCreditSplitTreatsBothColumnsPresentAsUnparsable() {
        let csv = "Date,Description,Debit,Credit\n01/07/2026,WEIRD ROW,12.00,8.00"
        let profile = ImportProfile(
            accountId: 1, format: .csv, csvDelimiter: ",",
            csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2,
            csvCreditAmountColumnIndex: 3, csvDateFormat: "dd/MM/yyyy"
        )
        let result = CSVStatementParser.parse(csvText: csv, profile: profile)
        XCTAssertTrue(result.transactions.isEmpty)
        XCTAssertEqual(result.unparsedLines.count, 1)
    }

    // Existing single-amount-column profiles (the vast majority today) have
    // csvCreditAmountColumnIndex == nil and must behave exactly as before.
    func testSingleAmountColumnProfileIsUnaffectedByCreditColumnFeature() {
        let csv = "Date,Description,Amount\n01/07/2026,SAINSBURYS,-45.64"
        let profile = ImportProfile(
            accountId: 1, format: .csv, csvDelimiter: ",",
            csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2,
            csvDateFormat: "dd/MM/yyyy"
        )
        XCTAssertNil(profile.csvCreditAmountColumnIndex)
        let result = CSVStatementParser.parse(csvText: csv, profile: profile)
        XCTAssertEqual(result.transactions.first?.amountMinorUnits, -4564)
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
