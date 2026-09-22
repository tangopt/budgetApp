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

        let formatter = DateFormatter()
        formatter.dateFormat = dateFormat
        formatter.locale = Locale(identifier: "en_GB")

        var lines = csvText.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
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
                  let minorUnits = parseAmountMinorUnits(fields[amountIndex]) else {
                unparsedLines.append(line)
                continue
            }
            transactions.append(ParsedTransaction(date: date, rawDescription: fields[descriptionIndex], amountMinorUnits: minorUnits))
        }

        return CSVParseResult(transactions: transactions, unparsedLines: unparsedLines)
    }

    private static func parseAmountMinorUnits(_ raw: String) -> Int? {
        let cleaned = raw.replacingOccurrences(of: ",", with: "")
        guard let decimalValue = Decimal(string: cleaned) else { return nil }
        let scaled = decimalValue * 100
        return NSDecimalNumber(decimal: scaled).intValue == 0 && cleaned != "0" && cleaned != "0.00"
            ? nil
            : NSDecimalNumber(decimal: scaled).intValue
    }
}
