import Foundation

public struct CSVParseResult {
    public let transactions: [ParsedTransaction]
    public let unparsedLines: [String]
    /// Rows left out on purpose because their status column says they aren't completed
    /// (pending, reverted, declined…) — neither imported nor counted as unparsed.
    public let skippedRows: Int

    public init(transactions: [ParsedTransaction], unparsedLines: [String], skippedRows: Int = 0) {
        self.transactions = transactions
        self.unparsedLines = unparsedLines
        self.skippedRows = skippedRows
    }
}

public enum CSVStatementParser {
    /// Status values (case-insensitive) that mean a row has gone through. A row with any
    /// other non-blank status is skipped; a blank status is imported.
    public static let completedStatuses: Set<String> = ["completed", "complete", "settled", "booked", "posted"]

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Transactions keep only the calendar day: a date-time ("2026-01-05 14:20:05") is cut back
    /// to UTC midnight of that day, the same instant a date-only format gives (see
    /// `StatementDateFormatter`), so fingerprints and balance rules behave the same.
    ///
    /// With a fee column, the fee is charged on top of the amount: the stored amount is
    /// `amount − |fee|` (a blank fee is zero; an unreadable one makes the row unparsed).
    public static func parse(csvText: String, profile: ImportProfile) -> CSVParseResult {
        let delimiter = Character(profile.csvDelimiter ?? ",")
        let dateFormat = profile.csvDateFormat ?? "dd/MM/yyyy"
        let dateIndex = profile.csvDateColumnIndex ?? 0
        let descriptionIndex = profile.csvDescriptionColumnIndex ?? 1
        let amountIndex = profile.csvAmountColumnIndex ?? 2
        let creditIndex = profile.csvCreditAmountColumnIndex
        let balanceIndex = profile.csvBalanceColumnIndex
        let feeIndex = profile.csvFeeColumnIndex
        let statusIndex = profile.csvStatusColumnIndex
        let negate = profile.csvNegateAmounts && profile.csvCreditAmountColumnIndex == nil

        let formatter = StatementDateFormatter.make(format: dateFormat)

        // Split on any newline, not just "\n": Swift treats "\r\n" as a single
        // Character (one grapheme cluster), so splitting a CRLF (Windows) file on
        // "\n" alone finds no split points and yields one giant line.
        var lines = splitLines(csvText)
        guard !lines.isEmpty else { return CSVParseResult(transactions: [], unparsedLines: []) }
        lines.removeFirst() // header row

        var transactions: [ParsedTransaction] = []
        var unparsedLines: [String] = []
        var skippedRows = 0

        for line in lines {
            let fields = CSVRowSplitter.split(line: line, delimiter: delimiter)
            if let statusIndex, statusIndex < fields.count {
                let status = fields[statusIndex].trimmingCharacters(in: .whitespaces).lowercased()
                if !status.isEmpty, !completedStatuses.contains(status) {
                    skippedRows += 1
                    continue
                }
            }
            let requiredIndices = [dateIndex, descriptionIndex, amountIndex, creditIndex].compactMap { $0 }
            guard fields.count > requiredIndices.max()! else {
                unparsedLines.append(line)
                continue
            }
            guard let parsedDate = formatter.date(from: fields[dateIndex]) else {
                unparsedLines.append(line)
                continue
            }
            guard var minorUnits = resolveAmount(fields: fields, amountIndex: amountIndex, creditIndex: creditIndex) else {
                unparsedLines.append(line)
                continue
            }
            if negate { minorUnits = -minorUnits }
            if let feeIndex, feeIndex < fields.count, !fields[feeIndex].trimmingCharacters(in: .whitespaces).isEmpty {
                guard let fee = Money.parseMinorUnits(fields[feeIndex]) else {
                    unparsedLines.append(line)
                    continue
                }
                minorUnits -= abs(fee)
            }
            let date = utcCalendar.startOfDay(for: parsedDate)
            let balance: Int? = balanceIndex.flatMap { $0 < fields.count ? Money.parseMinorUnits(fields[$0]) : nil }
            transactions.append(ParsedTransaction(date: date, rawDescription: fields[descriptionIndex], amountMinorUnits: minorUnits, balanceAfterMinorUnits: balance))
        }

        return CSVParseResult(transactions: transactions, unparsedLines: unparsedLines, skippedRows: skippedRows)
    }

    /// Single-column statements (`creditIndex == nil`): the amount column already carries
    /// its own sign, parsed as-is.
    ///
    /// Debit/credit-split statements (`creditIndex` set): `amountIndex` is the debit
    /// (money out) column and `creditIndex` is the credit (money in) column. Exactly one
    /// is expected to hold a value per row — the other is blank. Debit values become
    /// negative, credit values become positive, regardless of whatever sign the statement
    /// itself put on them (debit/credit columns are conventionally unsigned, since the
    /// column itself already says which direction the money moved). Both columns blank,
    /// or both holding a value (genuinely ambiguous — which one is the real amount?),
    /// return `nil` so the row is treated as unparsable rather than guessed at.
    private static func resolveAmount(fields: [String], amountIndex: Int, creditIndex: Int?) -> Int? {
        guard let creditIndex else {
            return Money.parseMinorUnits(fields[amountIndex])
        }
        let debitValue = Money.parseMinorUnits(fields[amountIndex])
        let creditValue = Money.parseMinorUnits(fields[creditIndex])
        switch (debitValue, creditValue) {
        case (let debit?, nil): return -abs(debit)
        case (nil, let credit?): return abs(credit)
        default: return nil
        }
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
