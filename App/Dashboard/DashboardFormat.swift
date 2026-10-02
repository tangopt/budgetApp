import Foundation

enum DashboardFormat {
    private static let wholePounds: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "GBP"
        formatter.locale = Locale(identifier: "en_GB")
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return formatter
    }()

    private static func utcFormatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = pattern
        return formatter
    }
    private static let dayFormatter = utcFormatter("d MMM yyyy")
    private static let monthYearFormatter = utcFormatter("MMMM yyyy")

    /// "£161,340" — whole pounds, signed.
    static func pounds(_ minorUnits: Int) -> String {
        wholePounds.string(from: NSNumber(value: Double(minorUnits) / 100)) ?? "—"
    }

    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func monthYear(_ date: Date) -> String { monthYearFormatter.string(from: date) }

    /// "+36.4%" / "-4.0%"; "—" when unknown.
    static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return String(format: "%+.1f%%", fraction * 100)
    }

    /// "£12.4k"-style label for chart annotations; sign kept.
    static func compactPounds(_ minorUnits: Int) -> String {
        let thousands = Double(minorUnits) / 100_000
        return String(format: "%@£%.1fk", thousands < 0 ? "-" : "+", abs(thousands))
    }
}
