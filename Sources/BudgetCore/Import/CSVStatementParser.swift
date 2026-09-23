import Foundation

public struct CSVParseResult {
    public let transactions: [ParsedTransaction]
    public let unparsedLines: [String]
}

public enum CSVStatementParser {
    public static func parse(csvText: String, profile: ImportProfile) -> CSVParseResult {
        let delimiter = Character(profile.csvDelimiter ?? ",")
        let dateFormat = profile.csvDateFormat ?? "dd/MM/yyyy"
        let dateIndex = profile.csvDateColumnIndex ?? 0
        let descriptionIndex = profile.csvDescriptionColumnIndex ?? 1
        let amountIndex = profile.csvAmountColumnIndex ?? 2

        let formatter = StatementDateFormatter.make(format: dateFormat)

        // Split on any newline, not just "\n": Swift treats "\r\n" as a single
        // Character (one grapheme cluster), so splitting a CRLF (Windows) file on
        // "\n" alone finds no split points and yields one giant line.
        var lines = splitLines(csvText)
        guard !lines.isEmpty else { return CSVParseResult(transactions: [], unparsedLines: []) }
        lines.removeFirst() // header row

        var transactions: [ParsedTransaction] = []
        var unparsedLines: [String] = []

        for line in lines {
            let fields = CSVRowSplitter.split(line: line, delimiter: delimiter)
            guard fields.count > max(dateIndex, descriptionIndex, amountIndex) else {
                unparsedLines.append(line)
                continue
            }
            guard let date = formatter.date(from: fields[dateIndex]),
                  let minorUnits = Money.parseMinorUnits(fields[amountIndex]) else {
                unparsedLines.append(line)
                continue
            }
            transactions.append(ParsedTransaction(date: date, rawDescription: fields[descriptionIndex], amountMinorUnits: minorUnits))
        }

        return CSVParseResult(transactions: transactions, unparsedLines: unparsedLines)
    }

    /// Splits statement text into non-blank lines, treating LF, CRLF and CR alike.
    public static func splitLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// Fixed-format statement dates are parsed in UTC with a POSIX locale so that a
/// given calendar day always maps to the same instant (UTC midnight), matching the
/// UTC calendars used by `PayPeriodDetector`, `FrequencyExpander` and
/// `TransactionFingerprint`. A system-local timezone would put e.g. "26/06/2026"
/// at 23:00 UTC on the 25th during BST, on the wrong side of a UTC period boundary.
enum StatementDateFormatter {
    static func make(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }
}
