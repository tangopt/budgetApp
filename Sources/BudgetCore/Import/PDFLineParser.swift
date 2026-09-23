// Sources/BudgetCore/Import/PDFLineParser.swift
import Foundation

public struct PDFParseResult {
    public let transactions: [ParsedTransaction]
    public let unparsedLines: [String]
}

public enum PDFLineParser {
    public static func parse(lines: [String], config: PDFLayoutConfig) -> PDFParseResult {
        guard let regex = try? NSRegularExpression(pattern: config.regexPattern) else {
            return PDFParseResult(transactions: [], unparsedLines: lines)
        }
        let formatter = StatementDateFormatter.make(format: config.dateFormat)

        var transactions: [ParsedTransaction] = []
        var unparsedLines: [String] = []

        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges >= 4,
                  let dateRange = Range(match.range(at: 1), in: line),
                  let descriptionRange = Range(match.range(at: 2), in: line),
                  let amountRange = Range(match.range(at: 3), in: line) else {
                unparsedLines.append(line)
                continue
            }
            let dateString = String(line[dateRange])
            let description = String(line[descriptionRange]).trimmingCharacters(in: .whitespaces)
            let amountString = String(line[amountRange])

            // Money.parseMinorUnits strips thousands-separator commas ("1,234.56")
            // before parsing — the same cleaning CSVStatementParser applies.
            guard let date = formatter.date(from: dateString),
                  let magnitude = Money.parseMinorUnits(amountString) else {
                unparsedLines.append(line)
                continue
            }

            // Trim first so a line ending "CR " (trailing whitespace from PDF
            // text extraction) is still recognised as a credit.
            let isCredit = line.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasSuffix("CR")
            let signedMinorUnits = abs(magnitude) * (isCredit ? 1 : -1)
            transactions.append(ParsedTransaction(date: date, rawDescription: description, amountMinorUnits: signedMinorUnits))
        }

        return PDFParseResult(transactions: transactions, unparsedLines: unparsedLines)
    }
}
