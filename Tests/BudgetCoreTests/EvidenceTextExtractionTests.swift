import XCTest
import CoreGraphics
@testable import BudgetCore

final class EvidenceTextExtractionTests: XCTestCase {
    // MARK: Glyph names

    func testGlyphNamesDecode() {
        let table: [(String, String?)] = [
            ("UNIC0041", "A"), ("/UNIC00E9", "é"), ("UNIC20AC", "€"),
            ("LA020000", "A"), ("LA010000", "a"), ("LZ020000", "Z"),
            ("LE110000", "é"), ("LE120000", "É"), ("LA190000", "ã"), ("LA200000", "Ã"), ("LC410000", "ç"), ("LC420000", "Ç"),
            ("LA140000", "À"), ("LE150000", "ê"), ("LO190000", "õ"),
            ("ND010000", "1"), ("ND090000", "9"), ("ND100000", "0"),
            ("SP010000", " "), ("SP080000", ","), ("SP100000", "-"), ("SP110000", "."), ("SP120000", "/"), ("SP130000", ":"),
            ("SM020000", "%"), ("SA010000", "+"), ("SM200000", "º"),
            ("space", " "), ("eacute", "é"), ("Euro", "€"), ("B", "B"), ("uni00E7", "ç"),
            ("LA990000", nil), ("SP990000", ""), ("SM990000", ""), ("g42", nil)
        ]
        for (name, expected) in table {
            XCTAssertEqual(GlyphNameDecoder.character(forGlyphName: name), expected, name)
        }
    }

    func testDecodesGlyphNamesInText() {
        // As some extractors print them: the scratch scripts' `dec` on pypdf output.
        let raw = "/LA020000/LV010000/LI010000/LS010000/LO010000/SP010000/LD020000/LE120000/LB020000/LI020000/LT020000/LO020000 "
            + "/ND010000/SP110000/ND020000/ND030000/ND040000/SP080000/ND050000/ND060000 /UNIC20AC /LX050000/SM990000"
        XCTAssertEqual(GlyphNameDecoder.decode(raw), "Aviso DÉBITO 1.234,56 € ?", "unknown letters read ?, unknown symbols nothing")
        XCTAssertEqual(GlyphNameDecoder.decode("no glyphs here"), "no glyphs here")
    }

    // MARK: Extraction and text status

    func testReadsNormalTextLayer() {
        let url = EvidenceTestPDFs.textPDF(["Fatura-Recibo FR 2025/7", "Serviço de contabilidade", "Total: 135,00 €"])
        let result = EvidenceTextExtractor.extract(from: url)
        XCTAssertEqual(result.status, .text)
        XCTAssertTrue(result.text?.contains("Fatura-Recibo FR 2025/7") == true, result.text ?? "")
        XCTAssertTrue(result.text?.contains("135,00") == true)
    }

    func testDecodesGlyphObfuscatedPDF() throws {
        let lines = ["AVISO DÉBITO PRESTAÇÃO", "TOTAL EUR: 1.234,56", "DATA: 2025-03-14 (EUR 3M 2,5% + SPREAD)"]
        let url = EvidenceTestPDFs.glyphPDF(lines)
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        XCTAssertTrue(PDFGlyphTextExtractor.usesObfuscatedGlyphNames(document))
        XCTAssertEqual(PDFGlyphTextExtractor.text(of: document), lines.joined(separator: "\n"))

        let result = EvidenceTextExtractor.extract(from: url)
        XCTAssertEqual(result.status, .glyph)
        XCTAssertEqual(result.text, lines.joined(separator: "\n"))
    }

    func testTooLittleTextIsNoTextLayer() {
        // A page number or a stray mark isn't a text layer.
        XCTAssertEqual(EvidenceTextExtractor.extract(from: EvidenceTestPDFs.textPDF(["Page 1 of 1"])).status, .noText)
    }

    func testImageOnlyAndBlankPDFs() {
        XCTAssertEqual(EvidenceTextExtractor.extract(from: EvidenceTestPDFs.imagePDF()), .init(status: .image, text: nil))
        XCTAssertEqual(EvidenceTextExtractor.extract(from: EvidenceTestPDFs.blankPDF()), .init(status: .noText, text: nil))
    }

    func testNonPDFFiles() throws {
        let photo = EvidenceTestPDFs.temporaryURL("receipt.HEIC")
        try Data([0xFF, 0xD8]).write(to: photo)
        XCTAssertEqual(EvidenceTextExtractor.extract(from: photo).status, .image)

        let csv = EvidenceTestPDFs.temporaryURL("recibos.csv")
        try Data("Recibo de Renda Eletrónico;Período;Valor\n7;2025-03-01 a 2025-03-31;1.500,00\n".utf8).write(to: csv)
        let read = EvidenceTextExtractor.extract(from: csv)
        XCTAssertEqual(read.status, .text)
        XCTAssertTrue(read.text?.contains("Recibo de Renda") == true)

        let sheet = EvidenceTestPDFs.temporaryURL("tracker.xlsx")
        try Data([0x50, 0x4B]).write(to: sheet)
        XCTAssertEqual(EvidenceTextExtractor.extract(from: sheet), .init(status: .noText, text: nil))

        let broken = EvidenceTestPDFs.temporaryURL("broken.pdf")
        try Data("not a pdf".utf8).write(to: broken)
        XCTAssertEqual(EvidenceTextExtractor.extract(from: broken), .init(status: .noText, text: nil))
    }
}
