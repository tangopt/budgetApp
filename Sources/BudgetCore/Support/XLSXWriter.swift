import Foundation

/// A cell's look in `XLSXWriter`'s fixed style sheet (Calibri 11, like the accountant's file).
public enum XLSXCellStyle: Int, CaseIterable, Sendable {
    case normal = 0
    case bold
    case boldUnderline
    case boldItalic
    case underline
    case euro
    /// Euro with a thin line above and below (subtotals).
    case euroSubtotal
    /// Euro with a thin line above and a double line below (totals).
    case euroTotal
    case pound
    case percent
    /// Pound with a thin line above and below (subtotals of a GBP property).
    case poundSubtotal
    /// Pound with a thin line above and a double line below (totals of a GBP property).
    case poundTotal

    /// The `<xf>` of `styles.xml`'s cellXfs, in case order.
    fileprivate var xf: String {
        switch self {
        case .normal: return #"<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>"#
        case .bold: return #"<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>"#
        case .boldUnderline: return #"<xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>"#
        case .boldItalic: return #"<xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1"/>"#
        case .underline: return #"<xf numFmtId="0" fontId="4" fillId="0" borderId="0" xfId="0" applyFont="1"/>"#
        case .euro: return #"<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>"#
        case .euroSubtotal: return #"<xf numFmtId="164" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1"/>"#
        case .euroTotal: return #"<xf numFmtId="164" fontId="0" fillId="0" borderId="2" xfId="0" applyNumberFormat="1" applyBorder="1"/>"#
        case .pound: return #"<xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>"#
        case .percent: return #"<xf numFmtId="10" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>"#
        case .poundSubtotal: return #"<xf numFmtId="165" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1"/>"#
        case .poundTotal: return #"<xf numFmtId="165" fontId="0" fillId="0" borderId="2" xfId="0" applyNumberFormat="1" applyBorder="1"/>"#
        }
    }
}

public enum XLSXCellValue: Equatable, Sendable {
    case text(String)
    case number(Double)
    /// A formula (no leading "="), with the value it evaluates to for readers that don't calculate.
    case formula(String, cached: Double?)
}

public struct XLSXCell: Equatable, Sendable {
    /// "A1", "D24".
    public var reference: String
    public var value: XLSXCellValue
    public var style: XLSXCellStyle

    public init(_ reference: String, _ value: XLSXCellValue, style: XLSXCellStyle = .normal) {
        self.reference = reference
        self.value = value
        self.style = style
    }
}

public struct XLSXSheetContent: Equatable, Sendable {
    public var name: String
    /// Column width (Excel character units) by 1-based column number.
    public var columnWidths: [Int: Double]
    public var cells: [XLSXCell]

    public init(name: String, columnWidths: [Int: Double] = [:], cells: [XLSXCell] = []) {
        self.name = name
        self.columnWidths = columnWidths
        self.cells = cells
    }
}

/// Writes a minimal .xlsx (Office Open XML): workbook, worksheets with inline strings, numbers
/// and formulas with cached values, a fixed style sheet, column widths. Pure Foundation plus
/// `ZipArchiveWriter`, so it runs on iOS. `XLSXReader` reads its output back.
public enum XLSXWriter {
    public enum WriteError: Error, Equatable {
        case badReference(String)
        case badSheetName(String)
        case duplicateCell(String)
    }

    public static func data(sheets: [XLSXSheetContent]) throws -> Data {
        var zip = ZipArchiveWriter()
        let sheetOverrides = sheets.indices.map {
            #"<Override PartName="/xl/worksheets/sheet\#($0 + 1).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
        }.joined()
        zip.add("[Content_Types].xml", text: """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
            <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
            \(sheetOverrides)</Types>
            """)
        zip.add("_rels/.rels", text: """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
            </Relationships>
            """)
        var sheetEntries = ""
        var relationships = ""
        for (index, sheet) in sheets.enumerated() {
            let name = sheet.name.trimmingCharacters(in: .whitespaces)
            // Excel's rules: 1–31 UTF-16 units, none of []:*?/\, no apostrophe at either end.
            guard !name.isEmpty, sheet.name.utf16.count <= 31, sheet.name.rangeOfCharacter(from: CharacterSet(charactersIn: "[]:*?/\\")) == nil,
                  !sheet.name.hasPrefix("'"), !sheet.name.hasSuffix("'") else {
                throw WriteError.badSheetName(sheet.name)
            }
            sheetEntries += #"<sheet name="\#(escape(sheet.name))" sheetId="\#(index + 1)" r:id="rId\#(index + 1)"/>"#
            relationships += #"<Relationship Id="rId\#(index + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#(index + 1).xml"/>"#
            zip.add("xl/worksheets/sheet\(index + 1).xml", text: try worksheet(sheet))
        }
        relationships += #"<Relationship Id="rId\#(sheets.count + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>"#
        zip.add("xl/workbook.xml", text: """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            <sheets>\(sheetEntries)</sheets><calcPr calcId="191029" fullCalcOnLoad="1"/></workbook>
            """)
        zip.add("xl/_rels/workbook.xml.rels", text: """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(relationships)</Relationships>
            """)
        zip.add("xl/styles.xml", text: styles)
        return try zip.archive()
    }

    static func worksheet(_ sheet: XLSXSheetContent) throws -> String {
        var rows: [Int: [(column: Int, cell: XLSXCell)]] = [:]
        var seen: Set<String> = []
        for cell in sheet.cells {
            guard let (column, row) = split(cell.reference) else { throw WriteError.badReference(cell.reference) }
            guard seen.insert(cell.reference).inserted else { throw WriteError.duplicateCell(cell.reference) }
            rows[row, default: []].append((column, cell))
        }
        var body = ""
        for row in rows.keys.sorted() {
            body += #"<row r="\#(row)">"#
            for (_, cell) in rows[row]!.sorted(by: { $0.column < $1.column }) {
                let head = #"<c r="\#(cell.reference)" s="\#(cell.style.rawValue)""#
                switch cell.value {
                case let .text(text):
                    body += head + #" t="inlineStr"><is><t xml:space="preserve">\#(escape(text))</t></is></c>"#
                case let .number(number):
                    body += head + "><v>\(format(number))</v></c>"
                case let .formula(formula, cached):
                    body += head + "><f>\(escape(formula))</f>" + (cached.map { "<v>\(format($0))</v>" } ?? "") + "</c>"
                }
            }
            body += "</row>"
        }
        let columns = sheet.columnWidths.keys.sorted().map { column in
            #"<col min="\#(column)" max="\#(column)" width="\#(format(sheet.columnWidths[column]!))" customWidth="1"/>"#
        }.joined()
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
            <sheetFormatPr defaultRowHeight="15"/>\(columns.isEmpty ? "" : "<cols>\(columns)</cols>")<sheetData>\(body)</sheetData></worksheet>
            """
    }

    /// "D24" → (4, 24), 1-based.
    static func split(_ reference: String) -> (Int, Int)? {
        let letters = reference.prefix { $0.isASCII && $0.isUppercase }
        guard !letters.isEmpty, let row = Int(reference.dropFirst(letters.count)), row > 0,
              let index = XLSXReader.columnIndex(of: reference) else { return nil }
        return (index + 1, row)
    }

    static func format(_ number: Double) -> String {
        if number == number.rounded(), abs(number) < 1e15 { return String(Int(number)) }
        return String(number)
    }

    /// XML text: markup characters escaped; characters XML 1.0 forbids (controls other than
    /// tab, line feed and carriage return; U+FFFE, U+FFFF) dropped.
    static func escape(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "\t", "\n", "\r": result.unicodeScalars.append(scalar)
            default:
                if scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF { continue }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    static let styles: String = {
        let xfs = XLSXCellStyle.allCases.map(\.xf).joined()
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
            <numFmts count="2">\
            <numFmt numFmtId="164" formatCode="_([$€-2]\\ * #,##0.00_);_([$€-2]\\ * \\(#,##0.00\\);_([$€-2]\\ * &quot;-&quot;??_);_(@_)"/>\
            <numFmt numFmtId="165" formatCode="_(&quot;£&quot;* #,##0.00_);_(&quot;£&quot;* \\(#,##0.00\\);_(&quot;£&quot;* &quot;-&quot;??_);_(@_)"/>\
            </numFmts>\
            <fonts count="5">\
            <font><sz val="11"/><name val="Calibri"/><family val="2"/></font>\
            <font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font>\
            <font><b/><u/><sz val="11"/><name val="Calibri"/><family val="2"/></font>\
            <font><b/><i/><sz val="11"/><name val="Calibri"/><family val="2"/></font>\
            <font><u/><sz val="11"/><name val="Calibri"/><family val="2"/></font>\
            </fonts>\
            <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
            <borders count="3"><border><left/><right/><top/><bottom/><diagonal/></border>\
            <border><left/><right/><top style="thin"><color indexed="64"/></top><bottom style="thin"><color indexed="64"/></bottom><diagonal/></border>\
            <border><left/><right/><top style="thin"><color indexed="64"/></top><bottom style="double"><color indexed="64"/></bottom><diagonal/></border></borders>\
            <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
            <cellXfs count="\(XLSXCellStyle.allCases.count)">\(xfs)</cellXfs>\
            <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
            </styleSheet>
            """
    }()
}
