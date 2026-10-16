import Foundation
import Compression
@testable import BudgetCore

/// Builds small synthetic .xlsx files (and plain ZIPs) for tests — never real exports.
enum XLSXTestWriter {
    /// A cell: text goes to the shared strings, numbers are written as number cells, inline
    /// strings as `inlineStr`.
    enum Cell {
        case text(String)
        case number(String)
        case inline(String)
        case empty
    }

    /// A ZIP of the given entries (deflated when `deflate`, else stored).
    static func zip(_ entries: [(path: String, data: Data)], deflate: Bool = true) -> Data {
        var archive = [UInt8]()
        var directory = [UInt8]()
        for entry in entries {
            let raw = [UInt8](entry.data)
            let crc = CRC32.checksum(raw)
            let compressed = deflate ? deflated(raw) : raw
            let method: UInt16 = deflate ? 8 : 0
            let name = [UInt8](entry.path.utf8)
            let offset = UInt32(archive.count)
            archive += le32(0x0403_4b50) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0)
            archive += le32(crc) + le32(UInt32(compressed.count)) + le32(UInt32(raw.count)) + le16(UInt16(name.count)) + le16(0)
            archive += name + compressed
            directory += le32(0x0201_4b50) + le16(20) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0)
            directory += le32(crc) + le32(UInt32(compressed.count)) + le32(UInt32(raw.count))
            directory += le16(UInt16(name.count)) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + name
        }
        let directoryOffset = UInt32(archive.count)
        archive += directory
        archive += le32(0x0605_4b50) + le16(0) + le16(0) + le16(UInt16(entries.count)) + le16(UInt16(entries.count))
        archive += le32(UInt32(directory.count)) + le32(directoryOffset) + le16(0)
        return Data(archive)
    }

    /// A one-sheet workbook laid out like Excel writes it.
    static func workbook(sheetName: String = "Sheet1", rows: [[Cell]], deflate: Bool = true) -> Data {
        var shared: [String] = []
        var sheetRows = ""
        for (r, row) in rows.enumerated() {
            var cells = ""
            for (c, cell) in row.enumerated() {
                let ref = column(c) + String(r + 1)
                switch cell {
                case .text(let text):
                    let index = shared.firstIndex(of: text) ?? { shared.append(text); return shared.count - 1 }()
                    cells += "<c r=\"\(ref)\" t=\"s\"><v>\(index)</v></c>"
                case .number(let value):
                    cells += "<c r=\"\(ref)\"><v>\(value)</v></c>"
                case .inline(let text):
                    cells += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t>\(escape(text))</t></is></c>"
                case .empty:
                    break
                }
            }
            sheetRows += "<row r=\"\(r + 1)\">\(cells)</row>"
        }
        let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let workbook = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="\(ns)" xmlns:r="\(rel)"><sheets><sheet sheetId="1" name="\(escape(sheetName))" r:id="rId4"/></sheets></workbook>
            """
        let rels = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId4" Type="\(rel)/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
            """
        let sheet = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="\(ns)"><sheetData>\(sheetRows)</sheetData></worksheet>
            """
        let strings = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <sst xmlns="\(ns)" count="\(shared.count)" uniqueCount="\(shared.count)">\(shared.map { "<si><t>\(escape($0))</t></si>" }.joined())</sst>
            """
        return zip([("[Content_Types].xml", Data("<Types/>".utf8)),
                    ("xl/workbook.xml", Data(workbook.utf8)),
                    ("xl/_rels/workbook.xml.rels", Data(rels.utf8)),
                    ("xl/worksheets/sheet1.xml", Data(sheet.utf8)),
                    ("xl/sharedStrings.xml", Data(strings.utf8))], deflate: deflate)
    }

    static func column(_ index: Int) -> String {
        var index = index + 1
        var name = ""
        while index > 0 {
            let remainder = (index - 1) % 26
            name = String(UnicodeScalar(65 + remainder)!) + name
            index = (index - 1) / 26
        }
        return name
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func deflated(_ raw: [UInt8]) -> [UInt8] {
        guard !raw.isEmpty else { return [] }
        var output = [UInt8](repeating: 0, count: raw.count + 1024)
        let written = raw.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_encode_buffer(destination.baseAddress!, destination.count, source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        precondition(written > 0)
        return Array(output[0..<written])
    }

    private static func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    private static func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } }
}
