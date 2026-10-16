import XCTest
@testable import BudgetCore

/// The minimal ZIP and XLSX writers, read back with `ZipArchiveReader` and `XLSXReader`.
final class XLSXWriterTests: XCTestCase {
    func testZipRoundTripsStoredAndDeflatedEntries() throws {
        var writer = ZipArchiveWriter()
        let repetitive = String(repeating: "abc", count: 5_000)
        writer.add("a/big.txt", text: repetitive)
        writer.add("tiny.txt", text: "x")
        writer.add("empty.txt", data: Data())
        let data = try writer.archive()
        let reader = try ZipArchiveReader(data: data)
        XCTAssertEqual(reader.entries.map(\.path), ["a/big.txt", "tiny.txt", "empty.txt"])
        XCTAssertEqual(reader.entry("a/big.txt")?.method, 8)
        XCTAssertEqual(reader.entry("tiny.txt")?.method, 0)
        XCTAssertEqual(String(decoding: try reader.contents(of: "a/big.txt"), as: UTF8.self), repetitive)
        XCTAssertEqual(try reader.contents(of: "tiny.txt"), Data("x".utf8))
        XCTAssertEqual(try reader.contents(of: "empty.txt"), Data())
        XCTAssertEqual(try writer.archive(), data, "deterministic")
    }

    func testWorkbookRoundTripsTextNumbersAndFormulas() throws {
        let sheet = XLSXSheetContent(name: "Sheet & One", columnWidths: [2: 30], cells: [
            XLSXCell("B2", .number(12.5), style: .euro),
            XLSXCell("A1", .text("Fish & <chips> \"x\""), style: .bold),
            XLSXCell("C2", .formula("B2*2", cached: 25), style: .euroTotal),
            XLSXCell("AA3", .text("far"))
        ])
        let data = try XLSXWriter.data(sheets: [sheet, XLSXSheetContent(name: "Two")])
        XCTAssertEqual(try XLSXReader.sheetNames(data: data), ["Sheet & One", "Two"])
        let rows = try XLSXReader.read(data: data).rows
        XCTAssertEqual(rows[0][0], "Fish & <chips> \"x\"")
        XCTAssertEqual(rows[1][1], "12.5")
        XCTAssertEqual(rows[1][2], "25")
        XCTAssertEqual(rows[2][26], "far")
        XCTAssertTrue(String(decoding: try ZipArchiveReader(data: data).contents(of: "xl/worksheets/sheet1.xml"), as: UTF8.self)
            .contains("<f>B2*2</f>"))
        XCTAssertThrowsError(try XLSXWriter.data(sheets: [XLSXSheetContent(name: "Bad", cells: [XLSXCell("12", .number(1))])]))
        XCTAssertThrowsError(try XLSXWriter.data(sheets: [XLSXSheetContent(name: "a/b")]))
    }

    func testEscapingDropsXMLIllegalCharacters() throws {
        let data = try XLSXWriter.data(sheets: [XLSXSheetContent(name: "S", cells: [
            XLSXCell("A1", .text("a\u{0001}b\u{FFFE}c\td\u{0B}"))
        ])])
        XCTAssertEqual(try XLSXReader.read(data: data).rows[0][0], "abc\td")
    }

    func testRejectsBadSheetNamesAndDuplicateCells() {
        XCTAssertThrowsError(try XLSXWriter.data(sheets: [XLSXSheetContent(name: "'Quoted'")]))
        XCTAssertThrowsError(try XLSXWriter.data(sheets: [XLSXSheetContent(name: String(repeating: "😀", count: 16))]))
        XCTAssertNoThrow(try XLSXWriter.data(sheets: [XLSXSheetContent(name: String(repeating: "😀", count: 15))]))
        XCTAssertThrowsError(try XLSXWriter.data(sheets: [XLSXSheetContent(name: "S", cells: [
            XLSXCell("A1", .number(1)), XLSXCell("A1", .number(2))
        ])])) { XCTAssertEqual($0 as? XLSXWriter.WriteError, .duplicateCell("A1")) }
    }
}
