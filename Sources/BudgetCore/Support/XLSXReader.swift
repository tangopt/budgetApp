import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A minimal .xlsx (OOXML spreadsheet) reader: the cell values of one worksheet as text.
/// Shared strings, inline strings and formula results are resolved; numbers come back as
/// written in the file ("100", "12.5"); dates stored as numbers stay serial numbers (see
/// `excelSerialDate` and `Sheet.uses1904Dates`). Styles, formulas and merged cells are ignored;
/// columns beyond `maxColumns` are dropped. Foundation-only (ZIP via `ZipArchiveReader`, XML
/// via `XMLParser`), so it runs on iOS too.
public enum XLSXReader {
    public enum XLSXError: Error, Equatable {
        case missingPart(String)
        case sheetNotFound
        case malformedXML(String)
    }

    /// A worksheet's rows top to bottom; each row is as wide as the widest row, empty cells `nil`.
    /// Rows absent from the file (gaps) come back empty.
    public struct Sheet: Equatable, Sendable {
        public let name: String
        public let rows: [[String?]]
        /// The workbook counts serial dates from 1904 (`workbookPr date1904`), not 1900.
        public var uses1904Dates = false

        public init(name: String, rows: [[String?]], uses1904Dates: Bool = false) {
            self.name = name
            self.rows = rows
            self.uses1904Dates = uses1904Dates
        }

        /// The date a serial number in this sheet stands for (`excelSerialDate`).
        public func date(fromSerial serial: Double) -> Date {
            XLSXReader.excelSerialDate(serial, date1904: uses1904Dates)
        }
    }

    /// Cells right of this many columns are ignored (a guard against bloated sheets).
    public static let maxColumns = 256

    /// The names of the workbook's sheets, in order.
    public static func sheetNames(data: Data) throws -> [String] {
        let archive = try ZipArchiveReader(data: data)
        return try parts(archive).sheets.map(\.name)
    }

    /// The sheet called `name`, or the first sheet when `nil`.
    public static func read(data: Data, sheet name: String? = nil) throws -> Sheet {
        let archive = try ZipArchiveReader(data: data)
        let workbook = try parts(archive)
        guard let sheet = name.map({ wanted in workbook.sheets.first { $0.name == wanted } }) ?? workbook.sheets.first else {
            throw XLSXError.sheetNotFound
        }
        let shared = try archive.entry(workbook.sharedStringsPath).map { try SharedStringsParser.parse(try archive.contents(of: $0)) } ?? []
        let rows = try WorksheetParser.parse(try archive.contents(of: sheet.path), sharedStrings: shared)
        return Sheet(name: sheet.name, rows: rows, uses1904Dates: workbook.uses1904Dates)
    }

    /// The date an Excel serial number stands for, at 00:00 UTC of that day; the fraction (time
    /// of day) is dropped. The 1900 date system is the default; `date1904` for workbooks saved
    /// with the 1904 system (old Mac Excel).
    public static func excelSerialDate(_ serial: Double, date1904: Bool = false) -> Date {
        let epoch = date1904
            ? MonthRange.calendar.date(from: DateComponents(year: 1904, month: 1, day: 1))!
            : MonthRange.calendar.date(from: DateComponents(year: 1899, month: 12, day: 30))!
        return MonthRange.calendar.date(byAdding: .day, value: Int(serial.rounded(.down)), to: epoch)!
    }

    // MARK: Parts

    private struct SheetRef { let name: String; let path: String }
    private struct WorkbookParts { let sheets: [SheetRef]; let sharedStringsPath: String; let uses1904Dates: Bool }

    private static func parts(_ archive: ZipArchiveReader) throws -> WorkbookParts {
        guard archive.entry("xl/workbook.xml") != nil else { throw XLSXError.missingPart("xl/workbook.xml") }
        let workbook = try ElementCollector.collect(try archive.contents(of: "xl/workbook.xml"), elements: ["sheet", "workbookPr"])
        let rels = try archive.entry("xl/_rels/workbook.xml.rels").map {
            try ElementCollector.collect(try archive.contents(of: $0), elements: ["Relationship"])
        } ?? []
        var targets: [String: String] = [:]
        var sharedStringsPath = "xl/sharedStrings.xml"
        func path(_ target: String) -> String { target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target }
        for rel in rels {
            guard let target = rel["Target"] else { continue }
            if let id = rel["Id"] { targets[id] = target }
            if rel["Type"]?.hasSuffix("/sharedStrings") == true { sharedStringsPath = path(target) }
        }
        let flag = workbook.first { $0["date1904"] != nil }?["date1904"]
        let uses1904 = flag == "1" || flag?.lowercased() == "true"
        let sheets = workbook.filter { $0["name"] != nil && $0["date1904"] == nil }
        let refs: [SheetRef] = sheets.enumerated().compactMap { index, sheet in
            guard let name = sheet["name"] else { return nil }
            // The relationship id attribute is namespaced ("r:id"); match any prefix.
            let relId = sheet.first { $0.key == "id" || $0.key.hasSuffix(":id") }?.value
            let target = relId.flatMap { targets[$0] } ?? "worksheets/sheet\(index + 1).xml"
            return SheetRef(name: name, path: path(target))
        }
        return WorkbookParts(sheets: refs, sharedStringsPath: sharedStringsPath, uses1904Dates: uses1904)
    }

    /// Column index (0-based) of a cell reference such as "AB12".
    static func columnIndex(of reference: String) -> Int? {
        var index = 0
        var sawLetter = false
        for scalar in reference.unicodeScalars {
            guard (65...90).contains(scalar.value) || (97...122).contains(scalar.value) else { break }
            index = index * 26 + Int((scalar.value & ~0x20) - 64)
            sawLetter = true
        }
        return sawLetter ? index - 1 : nil
    }
}

/// Attributes of every element with one of the given names.
private final class ElementCollector: NSObject, XMLParserDelegate {
    private let names: Set<String>
    private var found: [[String: String]] = []

    private init(names: Set<String>) { self.names = names }

    static func collect(_ data: Data, elements: Set<String>) throws -> [[String: String]] {
        let collector = ElementCollector(names: elements)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { throw XLSXReader.XLSXError.malformedXML(parser.parserError?.localizedDescription ?? "") }
        return collector.found
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if names.contains(localName(elementName)) { found.append(attributes) }
    }
}

private func localName(_ name: String) -> String {
    name.split(separator: ":").last.map(String.init) ?? name
}

/// `xl/sharedStrings.xml`: each `<si>` is the concatenation of its `<t>` texts (rich-text runs
/// included, phonetic `<rPh>` hints left out).
private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current: String?
    private var inText = false
    private var phoneticDepth = 0

    static func parse(_ data: Data) throws -> [String] {
        let handler = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        guard parser.parse() else { throw XLSXReader.XLSXError.malformedXML(parser.parserError?.localizedDescription ?? "") }
        return handler.strings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch localName(elementName) {
        case "si": current = ""
        case "rPh": phoneticDepth += 1
        case "t": inText = phoneticDepth == 0
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        switch localName(elementName) {
        case "si":
            strings.append(current ?? "")
            current = nil
        case "rPh": phoneticDepth -= 1
        case "t": inText = false
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current?.append(string) }
    }
}

/// A worksheet's `<sheetData>`: `<row r>` of `<c r t>` with `<v>` or `<is><t>`.
private final class WorksheetParser: NSObject, XMLParserDelegate {
    private let shared: [String]
    private var rows: [Int: [Int: String]] = [:]
    private var rowIndex = -1
    private var nextColumn = 0
    private var cellColumn = 0
    private var cellType: String?
    private var value: String?
    private var capturing = false
    private var phoneticDepth = 0
    private var badSharedIndex: String?

    private init(shared: [String]) { self.shared = shared }

    static func parse(_ data: Data, sharedStrings: [String]) throws -> [[String?]] {
        let handler = WorksheetParser(shared: sharedStrings)
        let parser = XMLParser(data: data)
        parser.delegate = handler
        guard parser.parse() else { throw XLSXReader.XLSXError.malformedXML(parser.parserError?.localizedDescription ?? "") }
        if let bad = handler.badSharedIndex { throw XLSXReader.XLSXError.malformedXML("shared string \(bad) out of range") }
        guard let last = handler.rows.keys.max() else { return [] }
        let width = (handler.rows.values.compactMap { $0.keys.max() }.max() ?? -1) + 1
        return (0...last).map { index in
            let cells = handler.rows[index] ?? [:]
            return (0..<width).map { cells[$0] }
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch localName(elementName) {
        case "row":
            rowIndex = attributes["r"].flatMap(Int.init).map { $0 - 1 } ?? rowIndex + 1
            nextColumn = 0
        case "c":
            cellColumn = attributes["r"].flatMap(XLSXReader.columnIndex(of:)) ?? nextColumn
            nextColumn = cellColumn + 1
            cellType = attributes["t"]
            value = nil
        case "rPh":
            phoneticDepth += 1
        case "v", "t":
            capturing = phoneticDepth == 0
            if value == nil { value = "" }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        switch localName(elementName) {
        case "v", "t":
            capturing = false
        case "rPh":
            phoneticDepth -= 1
        case "c":
            guard var text = value, cellColumn < XLSXReader.maxColumns else { return }
            if cellType == "s" {
                guard let index = Int(text), shared.indices.contains(index) else { badSharedIndex = text; return }
                text = shared[index]
            }
            guard !text.isEmpty else { return }
            rows[rowIndex, default: [:]][cellColumn] = text
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { value?.append(string) }
    }
}
