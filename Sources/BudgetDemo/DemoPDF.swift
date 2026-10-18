import Foundation

/// Small synthetic one-page PDFs for the demo database (never real documents): a coloured
/// header band with the issuer's name, a title, and key/value lines as a real text layer
/// (standard Helvetica, WinAnsi), so previews, text extraction and classification behave as
/// with genuine paperwork. Written by hand rather than through CoreGraphics, whose files carry
/// a creation date and a random ID: the same page always gives the same bytes (and hash).
enum DemoPDF {
    struct Page {
        var issuer: String
        var title: String
        var lines: [(String, String)]
        /// Header band colour, 0…1 RGB.
        var tint: (Double, Double, Double)
        var footer: String = "Synthetic demo document - not a real record."
    }

    /// Writes `page` to `url` (A5 portrait, 420 × 595 pt).
    static func write(_ page: Page, to url: URL) throws {
        try data(page).write(to: url)
    }

    static func data(_ page: Page) -> Data {
        var content = ""
        func number(_ value: Double) -> String { String(format: "%.3f", value) }
        func text(_ string: String, x: Double, y: Double, size: Double, bold: Bool, gray: Double) {
            content += "BT /\(bold ? "F2" : "F1") \(number(size)) Tf \(number(gray)) g \(number(x)) \(number(y)) Td <\(hex(string))> Tj ET\n"
        }
        // Header band and rule.
        content += "\(number(page.tint.0)) \(number(page.tint.1)) \(number(page.tint.2)) rg 0 525 420 70 re f\n"
        content += "0.8 g 28 471 364 0.8 re f\n"
        text(page.issuer, x: 28, y: 551, size: 18, bold: true, gray: 1)
        text(page.title, x: 28, y: 485, size: 15, bold: true, gray: 0.1)
        var y = 445.0
        for (key, value) in page.lines {
            text(key, x: 28, y: y, size: 10.5, bold: false, gray: 0.35)
            text(value, x: 190, y: y, size: 10.5, bold: true, gray: 0.1)
            y -= 20
        }
        text(page.footer, x: 28, y: 28, size: 8, bold: false, gray: 0.55)

        let stream = Data(content.utf8)
        let objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 420 595] /Resources << /Font << /F1 5 0 R /F2 6 0 R >> >> /Contents 4 0 R >>".utf8),
            Data("<< /Length \(stream.count) >>\nstream\n".utf8) + stream + Data("endstream".utf8),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".utf8),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>".utf8)
        ]
        var output = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(output.count)
            output += Data("\(index + 1) 0 obj\n".utf8) + object + Data("\nendobj\n".utf8)
        }
        let xref = output.count
        output += Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8)
        for offset in offsets { output += Data(String(format: "%010d 00000 n \n", offset).utf8) }
        output += Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        return output
    }

    /// The string in WinAnsi (Windows-1252) as hex; characters outside it become "?".
    private static func hex(_ string: String) -> String {
        let bytes = string.unicodeScalars.flatMap { scalar -> [UInt8] in
            String(scalar).data(using: .windowsCP1252).map(Array.init) ?? [0x3F]
        }
        return bytes.map { String(format: "%02X", $0) }.joined()
    }
}
