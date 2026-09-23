// Sources/BudgetCore/Import/PDFTextExtractor.swift
import PDFKit

public enum PDFTextExtractionError: Error {
    case couldNotOpenDocument
}

public enum PDFTextExtractor {
    public static func extractLines(from url: URL) throws -> [String] {
        guard let document = PDFDocument(url: url) else {
            throw PDFTextExtractionError.couldNotOpenDocument
        }
        var lines: [String] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex), let text = page.string else { continue }
            // Split on any newline (LF, CRLF, CR): "\r\n" is a single Swift Character,
            // so splitting on "\n" alone misses CRLF-terminated lines.
            lines.append(contentsOf: text.split(whereSeparator: \.isNewline).map(String.init))
        }
        return lines
    }
}
