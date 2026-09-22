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
}
