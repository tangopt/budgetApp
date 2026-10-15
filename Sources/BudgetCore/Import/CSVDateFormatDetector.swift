import Foundation

/// Finds which date formats can read every value in a CSV date column, so the import
/// mapping screen can offer only formats that actually fit the statement.
public enum CSVDateFormatDetector {
    /// In preference order: day-first before month-first (UK default). Date-time formats
    /// (e.g. Revolut's "2026-01-05 14:20:05") come last; the parser keeps only their calendar
    /// day (see `CSVStatementParser`).
    public static let knownFormats: [String] = [
        "dd/MM/yyyy", "d/M/yyyy", "MM/dd/yyyy", "yyyy-MM-dd", "dd-MM-yyyy",
        "dd.MM.yyyy", "dd MMM yyyy", "d MMM yyyy", "dd/MM/yy", "yyyy/MM/dd",
        "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss",
        "dd/MM/yyyy HH:mm:ss", "dd/MM/yyyy HH:mm", "MM/dd/yyyy HH:mm:ss", "MM/dd/yyyy HH:mm"
    ]

    /// True when `format` reads a time of day as well as a date.
    public static func includesTime(_ format: String) -> Bool {
        format.contains("H") || format.contains("h")
    }

    /// How the mapping screen's date-format menu shows `format`: date-time formats say the
    /// time is dropped, since only the calendar day is imported.
    public static func label(for format: String) -> String {
        includesTime(format) ? "\(format) (time ignored)" : format
    }

    /// Formats that parse every non-blank value, in `knownFormats` order. Empty when
    /// there are no non-blank values or nothing fits.
    public static func candidates(values: [String]) -> [String] {
        let trimmed = values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return [] }
        return knownFormats.filter { format in
            let formatter = StatementDateFormatter.make(format: format)
            // DateFormatter is lenient about separators and padding ("2026/10/01" reads as
            // yyyy-MM-dd), so require the parsed date to print back as the same text (case aside: banks often upper-case months).
            return trimmed.allSatisfy { value in
                guard let date = formatter.date(from: value) else { return false }
                return formatter.string(from: date).caseInsensitiveCompare(value) == .orderedSame
            }
        }
    }
}
