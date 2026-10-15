import XCTest
@testable import BudgetCore

final class CSVDateFormatDetectorTests: XCTestCase {
    func testDayFirstValuesExcludeMonthFirst() {
        let result = CSVDateFormatDetector.candidates(values: ["01/10/2026", "30/09/2026"])
        XCTAssertEqual(result.first, "dd/MM/yyyy")
        XCTAssertFalse(result.contains("MM/dd/yyyy"))
    }

    func testAmbiguousValuesPreferDayFirst() throws {
        let result = CSVDateFormatDetector.candidates(values: ["01/02/2026", "03/04/2026"])
        let dayFirst = try XCTUnwrap(result.firstIndex(of: "dd/MM/yyyy"))
        let monthFirst = try XCTUnwrap(result.firstIndex(of: "MM/dd/yyyy"))
        XCTAssertLessThan(dayFirst, monthFirst)
    }

    func testISODates() {
        XCTAssertEqual(CSVDateFormatDetector.candidates(values: ["2026-10-01"]), ["yyyy-MM-dd"])
    }

    func testTextMonth() {
        XCTAssertTrue(CSVDateFormatDetector.candidates(values: ["1 Oct 2026"]).contains("d MMM yyyy"))
    }

    func testNothingMatches() {
        XCTAssertEqual(CSVDateFormatDetector.candidates(values: ["hello"]), [])
    }

    func testBlanksIgnored() {
        XCTAssertEqual(CSVDateFormatDetector.candidates(values: ["", "2026-10-01", "  "]), ["yyyy-MM-dd"])
    }

    func testUnpaddedValuesMatchSingleDigitFormatOnly() {
        let result = CSVDateFormatDetector.candidates(values: ["1/10/2026"])
        XCTAssertTrue(result.contains("d/M/yyyy"))
        XCTAssertFalse(result.contains("dd/MM/yyyy"))
    }

    func testTwoDigitYear() {
        XCTAssertEqual(CSVDateFormatDetector.candidates(values: ["01/10/26"]), ["dd/MM/yy"])
    }

    func testUppercaseAndLowercaseMonths() {
        XCTAssertTrue(CSVDateFormatDetector.candidates(values: ["01 OCT 2026"]).contains("dd MMM yyyy"))
        XCTAssertTrue(CSVDateFormatDetector.candidates(values: ["1 oct 2026"]).contains("d MMM yyyy"))
    }

    func testDateTimeFormats() {
        XCTAssertEqual(CSVDateFormatDetector.candidates(values: ["2026-01-05 14:20:05"]), ["yyyy-MM-dd HH:mm:ss"])
        XCTAssertEqual(CSVDateFormatDetector.candidates(values: ["2026-01-05 14:20"]), ["yyyy-MM-dd HH:mm"])
        XCTAssertEqual(CSVDateFormatDetector.candidates(values: ["2026-01-05T14:20:05"]), ["yyyy-MM-dd'T'HH:mm:ss"])
        XCTAssertEqual(CSVDateFormatDetector.candidates(values: ["25/01/2026 14:20:05"]), ["dd/MM/yyyy HH:mm:ss"])
        XCTAssertEqual(CSVDateFormatDetector.candidates(values: ["25/01/2026 14:20"]), ["dd/MM/yyyy HH:mm"])
        XCTAssertEqual(CSVDateFormatDetector.candidates(values: ["01/25/2026 14:20:05"]), ["MM/dd/yyyy HH:mm:ss"])
        XCTAssertEqual(CSVDateFormatDetector.candidates(values: ["05/01/2026 14:20:05"]), ["dd/MM/yyyy HH:mm:ss", "MM/dd/yyyy HH:mm:ss"])
    }

    func testDateOnlyValuesDoNotMatchDateTimeFormats() {
        XCTAssertFalse(CSVDateFormatDetector.candidates(values: ["2026-01-05"]).contains { CSVDateFormatDetector.includesTime($0) })
    }

    func testFormatLabelsSayTheTimeIsIgnored() {
        XCTAssertEqual(CSVDateFormatDetector.label(for: "dd/MM/yyyy"), "dd/MM/yyyy")
        XCTAssertEqual(CSVDateFormatDetector.label(for: "yyyy-MM-dd HH:mm:ss"), "yyyy-MM-dd HH:mm:ss (time ignored)")
        XCTAssertEqual(CSVDateFormatDetector.label(for: "yyyy-MM-dd'T'HH:mm:ss"), "yyyy-MM-dd'T'HH:mm:ss (time ignored)")
    }
}
