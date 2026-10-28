import Foundation

public enum Currency: String, Codable, CaseIterable, Sendable {
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
    /// Formats an integer minor-unit amount (e.g. pence) as a currency string: "£1,234,567.89", "-€0.05".
    /// Grouped in threes with "," by hand, never by the device's locale, so the Mac and the phone show the same
    /// strings.
    public static func format(_ minorUnits: Int, currency: Currency) -> String {
        let magnitude = minorUnits.magnitude
        let body = "\(currency.symbol)\(grouped(magnitude / 100)).\(String(format: "%02d", Int(magnitude % 100)))"
        return minorUnits < 0 ? "-\(body)" : body
    }

    /// Formats minor units for a text field: thousands separators, always two decimals,
    /// "-" prefix when negative, no currency symbol ("44,007.51"). Round-trips with
    /// `parseMinorUnits`.
    public static func formatInput(_ minorUnits: Int) -> String {
        let magnitude = minorUnits.magnitude
        return "\(minorUnits < 0 ? "-" : "")\(grouped(magnitude / 100)).\(String(format: "%02d", Int(magnitude % 100)))"
    }

    /// What a pounds field shows for what was typed: "£" then the digits grouped in threes, at most two
    /// decimals, with a trailing "." kept so the next digits can follow ("65000" gives "£65,000", "1234.5"
    /// gives "£1,234.5"). Anything else typed is dropped; nothing typed gives "". Parses back with
    /// `parseMinorUnits`.
    public static func poundsFieldText(typed: String) -> String {
        var whole = ""
        var fraction = ""
        var sawPoint = false
        for character in typed {
            if character.isASCII, character.isNumber {
                if sawPoint { if fraction.count < 2 { fraction.append(character) } } else if whole.count < 12 { whole.append(character) }
            } else if character == ".", !sawPoint {
                sawPoint = true
            }
        }
        if whole.isEmpty, fraction.isEmpty, !sawPoint { return "" }
        let trimmed = String(whole.drop(while: { $0 == "0" }))
        let digits = trimmed.isEmpty ? "0" : trimmed
        return "£" + grouped(UInt(digits) ?? .max) + (sawPoint ? "." + fraction : "")
    }

    /// What a pounds field shows for an amount: "" for nothing, "£65,000" for whole pounds, "£1,234.50" otherwise.
    public static func poundsFieldText(pence: Int) -> String {
        if pence == 0 { return "" }
        let magnitude = pence.magnitude
        return poundsFieldText(typed: magnitude % 100 == 0 ? String(magnitude / 100) : "\(magnitude / 100).\(String(format: "%02d", Int(magnitude % 100)))")
    }

    /// Whole units grouped in threes with "," ("1,234,567"), independent of the locale.
    private static func grouped(_ whole: UInt) -> String {
        var result = ""
        for (index, digit) in String(whole).reversed().enumerated() {
            if index > 0, index % 3 == 0 { result.append(",") }
            result.append(digit)
        }
        return String(result.reversed())
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
