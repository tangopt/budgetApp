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

    // Blank in both columns has no amount at all; both populated is genuinely ambiguous and must never be guessed
    // at: either way the row is rejected for manual entry instead of silently picking one value.
    func testDebitCreditSplitRowsThatCannotBeReadAreUnparsable() {
        let cases: [(name: String, row: String)] = [
            ("both columns blank", "01/07/2026,MYSTERY ROW,,"),
            ("both columns present", "01/07/2026,WEIRD ROW,12.00,8.00"),
        ]
        for c in cases {
            let csv = "Date,Description,Debit,Credit\n" + c.row
            let profile = ImportProfile(
                accountId: 1, format: .csv, csvDelimiter: ",",
                csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2,
                csvCreditAmountColumnIndex: 3, csvDateFormat: "dd/MM/yyyy"
            )
            let result = CSVStatementParser.parse(csvText: csv, profile: profile)
            XCTAssertTrue(result.transactions.isEmpty, c.name)
            XCTAssertEqual(result.unparsedLines.count, 1, c.name)
        }
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

    func testParsesBalanceColumnWhenMapped() {
        let cases: [(name: String, csv: String, expected: [Int])] = [
            ("quoted thousands separator", "Date,Description,Amount,Balance\n01/07/2026,SAINSBURYS,-45.64,\"1,954.36\"\n02/07/2026,SALARY,2800.00,4754.36", [195436, 475436]),
            ("negative balance", "Date,Description,Amount,Balance\n01/07/2026,OVERDRAFT FEE,-5.00,-120.50", [-12050]),
        ]
        for c in cases {
            let profile = ImportProfile(
                accountId: 1, format: .csv, csvDelimiter: ",",
                csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2,
                csvBalanceColumnIndex: 3, csvDateFormat: "dd/MM/yyyy"
            )
            let result = CSVStatementParser.parse(csvText: c.csv, profile: profile)
            let balances: [Int?] = result.transactions.map { $0.balanceAfterMinorUnits.map { Int($0) } }
            XCTAssertEqual(balances, c.expected.map { Optional($0) }, c.name)
        }
    }

    // A blank or missing balance cell must never cost the transaction itself.
    func testBlankOrMissingBalanceCellGivesNilWithoutFailingTheRow() {
        let csv = "Date,Description,Amount,Balance\n01/07/2026,SHOP,-10.00,\n02/07/2026,SHOP,-5.00"
        let profile = ImportProfile(
            accountId: 1, format: .csv, csvDelimiter: ",",
            csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2,
            csvBalanceColumnIndex: 3, csvDateFormat: "dd/MM/yyyy"
        )
        let result = CSVStatementParser.parse(csvText: csv, profile: profile)
        XCTAssertEqual(result.transactions.count, 2)
        XCTAssertEqual(result.transactions.map(\.balanceAfterMinorUnits), [nil, nil])
        XCTAssertTrue(result.unparsedLines.isEmpty)
    }

    func testBalanceIsNilWhenNoBalanceColumnIsMapped() {
        let csv = "Date,Description,Amount\n01/07/2026,SAINSBURYS LONDON,-45.64"
        let result = CSVStatementParser.parse(csvText: csv, profile: standardProfile)
        XCTAssertNil(result.transactions.first?.balanceAfterMinorUnits)
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

    func testNegateAmounts() {
        let cases: [(name: String, csv: String, creditColumn: Int?)] = [
            ("flips a single column", "Date,Description,Amount\n01/07/2026,SHOP,45.64\n02/07/2026,PAY,-2800.00", nil),
            ("leaves split columns unchanged", "Date,Description,Out,In\n01/07/2026,SHOP,45.64,\n02/07/2026,PAY,,2800.00", 3),
        ]
        for c in cases {
            var profile = ImportProfile(accountId: 1, format: .csv, csvDelimiter: ",", csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2, csvCreditAmountColumnIndex: c.creditColumn, csvDateFormat: "dd/MM/yyyy")
            profile.csvNegateAmounts = true
            let result = CSVStatementParser.parse(csvText: c.csv, profile: profile)
            XCTAssertEqual(result.transactions.map(\.amountMinorUnits), [-4564, 280000], c.name)
        }
    }

    // MARK: - Date-time, fee and status columns

    private func profile(dateFormat: String, fee: Int? = nil, status: Int? = nil) -> ImportProfile {
        ImportProfile(accountId: 1, format: .csv, csvDelimiter: ",", csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1,
                      csvAmountColumnIndex: 2, csvFeeColumnIndex: fee, csvStatusColumnIndex: status, csvDateFormat: dateFormat)
    }

    private func utcDay(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testDateTimesKeepOnlyTheCalendarDay() {
        let cases: [(String, String)] = [
            ("yyyy-MM-dd HH:mm:ss", "2026-01-05 23:59:59"), ("yyyy-MM-dd HH:mm", "2026-01-05 00:01"),
            ("yyyy-MM-dd'T'HH:mm:ss", "2026-01-05T14:20:05"), ("dd/MM/yyyy HH:mm:ss", "05/01/2026 14:20:05"),
            ("dd/MM/yyyy HH:mm", "05/01/2026 14:20"), ("MM/dd/yyyy HH:mm:ss", "01/05/2026 14:20:05")
        ]
        for (format, value) in cases {
            let result = CSVStatementParser.parse(csvText: "Date,Description,Amount\n\(value),SHOP,-1.00", profile: profile(dateFormat: format))
            XCTAssertEqual(result.transactions.map(\.date), [utcDay(2026, 1, 5)], format)
        }
    }

    func testFeeIsChargedOnTopOfTheAmount() {
        let csv = "Date,Description,Amount,Fee\n01/07/2026,SHOP,-23.59,0.24\n02/07/2026,IN,100.00,1.00\n03/07/2026,NEG FEE,-10.00,-0.50\n04/07/2026,NO FEE,-5.00,"
        let result = CSVStatementParser.parse(csvText: csv, profile: profile(dateFormat: "dd/MM/yyyy", fee: 3))
        XCTAssertEqual(result.transactions.map(\.amountMinorUnits), [-2_383, 9_900, -1_050, -500])
        XCTAssertEqual(result.unparsedLines, [])
    }

    func testUnreadableFeeIsUnparsed() {
        let csv = "Date,Description,Amount,Fee\n01/07/2026,SHOP,-23.59,abc"
        let result = CSVStatementParser.parse(csvText: csv, profile: profile(dateFormat: "dd/MM/yyyy", fee: 3))
        XCTAssertEqual(result.transactions.count, 0)
        XCTAssertEqual(result.unparsedLines.count, 1)
    }

    func testRowsThatAreNotCompletedAreSkippedNotUnparsed() {
        let csv = """
        Date,Description,Amount,State
        01/07/2026,A,-1.00,COMPLETED
        01/07/2026,B,-1.00,completed
        01/07/2026,C,-1.00,Settled
        01/07/2026,D,-1.00,BOOKED
        01/07/2026,E,-1.00,posted
        01/07/2026,F,-1.00,Complete
        01/07/2026,G,-1.00,
        01/07/2026,H,-1.00,PENDING
        ,I,-1.00,REVERTED
        01/07/2026,J,-1.00,DECLINED
        """
        let result = CSVStatementParser.parse(csvText: csv, profile: profile(dateFormat: "dd/MM/yyyy", status: 3))
        XCTAssertEqual(result.transactions.map(\.rawDescription), ["A", "B", "C", "D", "E", "F", "G"])
        XCTAssertEqual(result.skippedRows, 3)
        XCTAssertEqual(result.unparsedLines, [])
    }

    func testProfilesWithoutFeeOrStatusIgnoreThoseColumns() {
        let csv = "Date,Description,Amount,Fee,State\n01/07/2026,SHOP,-23.59,0.24,PENDING"
        let result = CSVStatementParser.parse(csvText: csv, profile: profile(dateFormat: "dd/MM/yyyy"))
        XCTAssertEqual(result.transactions.map(\.amountMinorUnits), [-2_359])
        XCTAssertEqual(result.skippedRows, 0)
    }
}
