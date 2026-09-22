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
            lines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
        }
        return lines
    }
}
