// Tests/BudgetCoreTests/PDFLineParserTests.swift
import XCTest
@testable import BudgetCore

final class PDFLineParserTests: XCTestCase {
    // A typical Lloyds PDF statement line, extracted as one line of text:
    // "01 Jul 26   SAINSBURYS LONDON SW1        45.64 DR"
    let lloydsConfig = PDFLayoutConfig(
        regexPattern: #"^(\d{2} \w{3} \d{2})\s+(.+?)\s+([\d.]+)\s*(?:DR|CR)?$"#,
        dateFormat: "dd MMM yy"
    )

    func testParsesDebitLineAsNegativeAmount() {
        let result = PDFLineParser.parse(lines: ["01 Jul 26   SAINSBURYS LONDON SW1        45.64 DR"], config: lloydsConfig)
        XCTAssertEqual(result.transactions.count, 1)
        XCTAssertEqual(result.transactions[0].amountMinorUnits, -4564)
        XCTAssertEqual(result.transactions[0].rawDescription, "SAINSBURYS LONDON SW1")
    }

    func testParsesCreditLineAsPositiveAmount() {
        let result = PDFLineParser.parse(lines: ["02 Jul 26   SALARY PAYMENT        2800.00 CR"], config: lloydsConfig)
        XCTAssertEqual(result.transactions[0].amountMinorUnits, 280000)
    }

    func testNonMatchingLinesAreFlaggedUnparsed() {
        let result = PDFLineParser.parse(lines: ["Statement period: 01 Jul 2026 to 31 Jul 2026", "01 Jul 26   SAINSBURYS LONDON SW1        45.64 DR"], config: lloydsConfig)
        XCTAssertEqual(result.transactions.count, 1)
        XCTAssertEqual(result.unparsedLines.count, 1)
    }

    func testConfigRoundTripsThroughJSON() throws {
        let encoded = try lloydsConfig.encoded()
        let decoded = try PDFLayoutConfig.decode(encoded)
        XCTAssertEqual(decoded.regexPattern, lloydsConfig.regexPattern)
        XCTAssertEqual(decoded.dateFormat, lloydsConfig.dateFormat)
    }

    // I9: comma thousands separators must not truncate the amount ("1,234.56" → 1).
    func testParsesCommaThousandsSeparatedAmount() {
        let config = PDFLayoutConfig(regexPattern: #"^(\d{2} \w{3} \d{2})\s+(.+?)\s+([\d,.]+)\s*(?:DR|CR)?$"#, dateFormat: "dd MMM yy")
        let result = PDFLineParser.parse(lines: ["03 Jul 26   RENT PAYMENT        1,234.56 DR"], config: config)
        XCTAssertEqual(result.transactions.count, 1)
        XCTAssertEqual(result.transactions[0].amountMinorUnits, -123456)
    }

    // I9: trailing whitespace after "CR" must still mark the line as a credit.
    func testCreditSuffixWithTrailingWhitespaceIsPositive() {
        let config = PDFLayoutConfig(regexPattern: #"^(\d{2} \w{3} \d{2})\s+(.+?)\s+([\d.]+)\s*(?:DR|CR)?\s*$"#, dateFormat: "dd MMM yy")
        let result = PDFLineParser.parse(lines: ["02 Jul 26   SALARY PAYMENT        2800.00 CR  "], config: config)
        XCTAssertEqual(result.transactions.count, 1)
        XCTAssertEqual(result.transactions[0].amountMinorUnits, 280000)
    }

    // I8: PDF dates parse as UTC midnight.
    func testParsesDatesAsUTCMidnight() {
        let result = PDFLineParser.parse(lines: ["01 Jul 26   SAINSBURYS LONDON SW1        45.64 DR"], config: lloydsConfig)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(result.transactions[0].date, utc.date(from: DateComponents(year: 2026, month: 7, day: 1))!)
    }
}
