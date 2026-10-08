import Foundation

/// Finds which date formats can read every value in a CSV date column, so the import
/// mapping screen can offer only formats that actually fit the statement.
public enum CSVDateFormatDetector {
    /// In preference order: day-first before month-first (UK default).
    public static let knownFormats: [String] = [
        "dd/MM/yyyy", "d/M/yyyy", "MM/dd/yyyy", "yyyy-MM-dd", "dd-MM-yyyy",
        "dd.MM.yyyy", "dd MMM yyyy", "d MMM yyyy", "dd/MM/yy", "yyyy/MM/dd"
    ]

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
