import Foundation

public enum Currency: String, Codable, CaseIterable {
    case gbp
    case eur

    var symbol: String {
        switch self {
        case .gbp: return "£"
        case .eur: return "€"
        }
    }
}

public enum Money {
    /// Formats an integer minor-unit amount (e.g. pence) as a currency string.
    public static func format(_ minorUnits: Int, currency: Currency) -> String {
        let negative = minorUnits < 0
        let absValue = abs(minorUnits)
        let whole = absValue / 100
        let fraction = absValue % 100
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        let wholeString = formatter.string(from: NSNumber(value: whole)) ?? "\(whole)"
        let body = "\(currency.symbol)\(wholeString).\(String(format: "%02d", fraction))"
        return negative ? "-\(body)" : body
    }

    private static let plainDecimalPattern = try! NSRegularExpression(pattern: #"^[+-]?(\d+(\.\d*)?|\.\d+)$"#)

    /// Parses a human/bank-formatted amount ("1,234.56", "-45.64", "£300", " 12.5 ")
    /// into integer minor units. Thousands-separator commas, currency symbols and
    /// surrounding whitespace are stripped; anything else that isn't a plain decimal
    /// number is rejected (returns nil) rather than partially parsed — `Decimal(string:)`
    /// on its own silently parses only a numeric prefix ("12abc" → 12). Amounts with
    /// fractional minor units ("0.001") are also rejected rather than truncated.
    /// Decimal is used only as a parsing intermediate; the result is always `Int`.
    public static func parseMinorUnits(_ raw: String) -> Int? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for symbol in [",", "£", "€"] {
            cleaned = cleaned.replacingOccurrences(of: symbol, with: "")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        guard plainDecimalPattern.firstMatch(in: cleaned, range: range) != nil,
              let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        var scaled = value * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled else { return nil } // fractional minor units
        return NSDecimalNumber(decimal: rounded).intValue
    }
}
