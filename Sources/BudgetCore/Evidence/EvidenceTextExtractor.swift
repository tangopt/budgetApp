import CoreGraphics
import Foundation
import PDFKit

/// Reads a document's text and says how readable it is (spec §3): a normal PDF text layer
/// (PDFKit), else BBVA's glyph-named fonts (`PDFGlyphTextExtractor`), else image-only (scans,
/// photos) or no text at all.
public enum EvidenceTextExtractor {
    public struct Result: Equatable, Sendable {
        public var status: DocumentTextStatus
        /// The text read, whitespace kept (`nil` for image-only and text-less files).
        public var text: String?

        public init(status: DocumentTextStatus, text: String?) {
            self.status = status
            self.text = text
        }
    }

    /// Image formats: never a text layer.
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]
    /// Plain-text formats, read as they are (e.g. a receipts CSV export).
    static let plainTextExtensions: Set<String> = ["txt", "csv", "tsv", "md"]
    /// Fewer letters than this is not a usable text layer (a page number, a stray mark).
    static let minimumLetters = 20

    public static func extract(from url: URL, maxPages: Int = 20) -> Result {
        let fileExtension = url.pathExtension.lowercased()
        if imageExtensions.contains(fileExtension) { return Result(status: .image, text: nil) }
        if plainTextExtensions.contains(fileExtension) {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252),
                  hasText(text) else { return Result(status: .noText, text: nil) }
            return Result(status: .text, text: text)
        }
        guard fileExtension == "pdf" else { return Result(status: .noText, text: nil) }

        if let document = PDFDocument(url: url) {
            var pages: [String] = []
            for index in 0..<min(document.pageCount, maxPages) {
                if let text = document.page(at: index)?.string { pages.append(text) }
            }
            let text = pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if hasText(text) { return Result(status: .text, text: text) }
        }
        guard let document = CGPDFDocument(url as CFURL) else { return Result(status: .noText, text: nil) }
        // Only trusted when the fonts name their glyphs the BBVA way, or the result reads as
        // text (not codes mapped to arbitrary characters).
        let glyphText = PDFGlyphTextExtractor.text(of: document, maxPages: maxPages)
        if hasText(glyphText), PDFGlyphTextExtractor.usesObfuscatedGlyphNames(document) || readableShare(glyphText) >= 0.8 {
            return Result(status: .glyph, text: glyphText)
        }
        return Result(status: PDFGlyphTextExtractor.containsImages(document) ? .image : .noText, text: nil)
    }

    /// The share of non-space characters that are letters, digits or common punctuation.
    static func readableShare(_ text: String) -> Double {
        let common = Set(".,:;/-()%€£+'\"ºª&@#*")
        var total = 0
        var readable = 0
        for character in text where !character.isWhitespace {
            total += 1
            if character.isLetter || character.isNumber || common.contains(character) { readable += 1 }
        }
        return total == 0 ? 0 : Double(readable) / Double(total)
    }

    static func hasText(_ text: String) -> Bool {
        var letters = 0
        for character in text where character.isLetter {
            letters += 1
            if letters >= minimumLetters { return true }
        }
        return false
    }
}
