import XCTest
import Compression
@testable import BudgetCore

/// The minimal ZIP and .xlsx readers used for the rent-receipts export. Synthetic files only.
final class XLSXReaderTests: XCTestCase {
    func testZipReadsStoredAndDeflatedEntries() throws {
        let text = Data(String(repeating: "rent receipts ", count: 200).utf8)
        for deflate in [false, true] {
            let archive = try ZipArchiveReader(data: XLSXTestWriter.zip([("a.txt", text), ("dir/empty.txt", Data())], deflate: deflate))
            XCTAssertEqual(archive.entries.map(\.path), ["a.txt", "dir/empty.txt"])
            XCTAssertEqual(try archive.contents(of: "a.txt"), text)
            XCTAssertEqual(try archive.contents(of: "dir/empty.txt"), Data())
            XCTAssertThrowsError(try archive.contents(of: "missing")) { XCTAssertEqual($0 as? ZipArchiveReader.ZipError, .entryNotFound("missing")) }
        }
    }

    func testZipRejectsGarbageAndDetectsCorruption() throws {
        XCTAssertThrowsError(try ZipArchiveReader(data: Data("not a zip at all, just text".utf8))) {
            XCTAssertEqual($0 as? ZipArchiveReader.ZipError, .notAZipArchive)
        }
        var bytes = [UInt8](XLSXTestWriter.zip([("a.txt", Data("hello world".utf8))], deflate: false))
        bytes[30 + 5] ^= 0xFF // flip a byte of the stored data (after the 30-byte header and "a.txt")
        let archive = try ZipArchiveReader(data: Data(bytes))
        XCTAssertThrowsError(try archive.contents(of: "a.txt")) { XCTAssertEqual($0 as? ZipArchiveReader.ZipError, .corrupt("checksum of a.txt")) }
    }

    func testCRC32KnownValue() {
        XCTAssertEqual(CRC32.checksum([UInt8]("123456789".utf8)), 0xCBF4_3926)
    }

    func testColumnIndexes() {
        XCTAssertEqual(XLSXReader.columnIndex(of: "A1"), 0)
        XCTAssertEqual(XLSXReader.columnIndex(of: "M119"), 12)
        XCTAssertEqual(XLSXReader.columnIndex(of: "AA3"), 26)
        XCTAssertNil(XLSXReader.columnIndex(of: "12"))
        XCTAssertEqual(XLSXTestWriter.column(27), "AB")
    }

    func testReadsSharedInlineAndNumberCellsWithGaps() throws {
        let data = XLSXTestWriter.workbook(sheetName: "Lista", rows: [
            [.text("Name"), .text("Amount"), .text("Note")],
            [.text("Ação & <x>"), .number("777.77"), .empty, .inline("inline")],
            [],
            [.empty, .number("50")]
        ])
        XCTAssertEqual(try XLSXReader.sheetNames(data: data), ["Lista"])
        let sheet = try XLSXReader.read(data: data)
        XCTAssertEqual(sheet.name, "Lista")
        XCTAssertEqual(sheet.rows, [
            ["Name", "Amount", "Note", nil],
            ["Ação & <x>", "777.77", nil, "inline"],
            [nil, nil, nil, nil],
            [nil, "50", nil, nil]
        ])
        XCTAssertEqual(try XLSXReader.read(data: data, sheet: "Lista").rows.count, 4)
        XCTAssertThrowsError(try XLSXReader.read(data: data, sheet: "Other")) { XCTAssertEqual($0 as? XLSXReader.XLSXError, .sheetNotFound) }
    }

    func testRichTextSharedStringsAreConcatenatedWithoutPhonetics() throws {
        let strings = """
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><r><t>Room </t></r><r><t>A</t></r>\
            <rPh><t>ignored</t></rPh></si></sst>
            """
        let sheet = """
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="B1" t="s"><v>0</v></c></row></sheetData></worksheet>
            """
        let workbook = """
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="x"><sheets><sheet name="S" r:id="rId1"/></sheets></workbook>
            """
        let rels = "<Relationships><Relationship Id=\"rId1\" Target=\"/xl/worksheets/other.xml\"/></Relationships>"
        let data = XLSXTestWriter.zip([("xl/workbook.xml", Data(workbook.utf8)), ("xl/_rels/workbook.xml.rels", Data(rels.utf8)),
                                       ("xl/worksheets/other.xml", Data(sheet.utf8)), ("xl/sharedStrings.xml", Data(strings.utf8))])
        XCTAssertEqual(try XLSXReader.read(data: data).rows, [[nil, "Room A"]])
    }

    func testExcelSerialDates() {
        XCTAssertEqual(XLSXReader.excelSerialDate(45658), MonthRange.calendar.date(from: DateComponents(year: 2025, month: 1, day: 1)))
        XCTAssertEqual(XLSXReader.excelSerialDate(45658.75), MonthRange.calendar.date(from: DateComponents(year: 2025, month: 1, day: 1)))
    }

    func testEmptyDeflatedDataIsCorruptNotACrash() throws {
        var bytes = [UInt8](XLSXTestWriter.zip([("a.txt", Data("abc".utf8))], deflate: false))
        // Claim the 3 bytes were deflated into nothing: method 8, compressed size 0 (local and central headers).
        let central = bytes.count - 22 - (46 + 5)
        for (methodAt, sizeAt) in [(8, 18), (central + 10, central + 20)] {
            bytes[methodAt] = 8
            for i in 0..<4 { bytes[sizeAt + i] = 0 }
        }
        let archive = try ZipArchiveReader(data: Data(bytes))
        XCTAssertThrowsError(try archive.contents(of: "a.txt")) { XCTAssertEqual($0 as? ZipArchiveReader.ZipError, .corrupt("data of a.txt")) }
    }

    func testSharedStringsFromRelsInlinePhoneticsWidthCapAnd1904Dates() throws {
        let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let workbook = """
            <workbook xmlns="\(ns)" xmlns:r="x"><workbookPr date1904="1"/><sheets><sheet name="S" r:id="rId1"/></sheets></workbook>
            """
        let rels = """
            <Relationships><Relationship Id="rId1" Type="x/worksheet" Target="worksheets/s.xml"/>\
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="strings/custom.xml"/></Relationships>
            """
        let strings = "<sst xmlns=\"\(ns)\"><si><t>Shared</t></si></sst>"
        let sheet = """
            <worksheet xmlns="\(ns)"><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c>\
            <c r="B1" t="inlineStr"><is><r><t>Inline</t></r><rPh><t>hint</t></rPh></is></c><c r="IW1"><v>9</v></c></row></sheetData></worksheet>
            """
        let data = XLSXTestWriter.zip([("xl/workbook.xml", Data(workbook.utf8)), ("xl/_rels/workbook.xml.rels", Data(rels.utf8)),
                                       ("xl/worksheets/s.xml", Data(sheet.utf8)), ("xl/strings/custom.xml", Data(strings.utf8))])
        let read = try XLSXReader.read(data: data)
        XCTAssertEqual(read.rows, [["Shared", "Inline"]]) // column IW (257th) is dropped
        XCTAssertTrue(read.uses1904Dates)
        XCTAssertEqual(read.date(fromSerial: 0), MonthRange.calendar.date(from: DateComponents(year: 1904, month: 1, day: 1)))
        XCTAssertFalse(try XLSXReader.read(data: XLSXTestWriter.workbook(rows: [[.text("x")]])).uses1904Dates)
    }
}
