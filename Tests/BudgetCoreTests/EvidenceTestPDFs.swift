import CoreGraphics
import CoreText
import Foundation

/// Synthetic PDFs for the evidence tests (never real documents).
enum EvidenceTestPDFs {
    static func temporaryURL(_ name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EvidenceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    /// A one-page PDF with `lines` as a normal text layer (CoreText).
    static func textPDF(_ lines: [String], name: String = "text.pdf") -> URL {
        let url = temporaryURL(name)
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        for (index, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            context.textPosition = CGPoint(x: 50, y: 790 - CGFloat(index) * 16)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        context.endPDFPage()
        context.closePDF()
        return url
    }

    /// A one-page PDF that only draws an image (a "scan").
    static func imagePDF(name: String = "scan.pdf") -> URL {
        let url = temporaryURL(name)
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let bitmap = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        let image = bitmap.makeImage()!
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.draw(image, in: CGRect(x: 10, y: 10, width: 180, height: 180))
        context.endPDFPage()
        context.closePDF()
        return url
    }

    /// A one-page PDF with nothing on it.
    static func blankPDF(name: String = "blank.pdf") -> URL {
        let url = temporaryURL(name)
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    /// A hand-written PDF like BBVA's: a Type 3 font with no `ToUnicode`, whose encoding names
    /// each glyph the obfuscated way (`LA020000`, `ND050000`, `SP110000`, `UNIC00E9` …), and
    /// character codes that are *not* ASCII, so only decoding the glyph names reads the text.
    static func glyphPDF(_ lines: [String], name: String = "glyph.pdf") -> URL {
        // Assign codes from 1 upward to each distinct character.
        var codes: [Character: UInt8] = [:]
        var names: [String] = []
        for character in lines.joined() where codes[character] == nil {
            codes[character] = UInt8(names.count + 1)
            names.append(glyphName(character))
        }
        let content = lines.enumerated().map { index, line in
            let hex = line.map { String(format: "%02X", codes[$0]!) }.joined()
            return index == 0 ? "BT /F1 12 Tf 50 780 Td <\(hex)> Tj" : "0 -16 Td <\(hex)> Tj"
        }.joined(separator: "\n") + "\nET"
        let widths = Array(repeating: "600", count: names.count).joined(separator: " ")
        let charProcs = names.map { "/\($0) 6 0 R" }.joined(separator: " ")
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix [0.001 0 0 0.001 0 0] "
                + "/CharProcs << \(charProcs) >> /Encoding << /Type /Encoding /Differences [1 \(names.map { "/\($0)" }.joined(separator: " "))] >> "
                + "/FirstChar 1 /LastChar \(names.count) /Widths [\(widths)] /Resources << >> >>",
            "<< /Length 9 >>\nstream\n600 0 d0\nendstream"
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        pdf += offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        let url = temporaryURL(name)
        try! Data(pdf.utf8).write(to: url)
        return url
    }

    /// BBVA's name for `character`.
    static func glyphName(_ character: Character) -> String {
        let accents: [Character: String] = ["é": "LE110000", "É": "LE120000", "ç": "LC410000", "Ç": "LC420000", "ã": "LA190000", "Ã": "LA200000"]
        if let name = accents[character] { return name }
        if character.isASCII, character.isLetter { return "L\(character.uppercased())\(character.isUppercase ? "02" : "01")0000" }
        if let digit = character.wholeNumberValue { return String(format: "ND%02d0000", digit == 0 ? 10 : digit) }
        let punctuation: [Character: String] = [" ": "SP010000", "(": "SP060000", ")": "SP070000", ",": "SP080000", "-": "SP100000",
                                                ".": "SP110000", "/": "SP120000", ":": "SP130000", "%": "SM020000", "+": "SA010000"]
        if let name = punctuation[character] { return name }
        return String(format: "UNIC%04X", character.unicodeScalars.first!.value)
    }
}
