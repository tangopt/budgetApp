import Foundation

/// Canonical document names (spec §3): `YYYYMMDD - <Area> - <Type> - <Detail>[ - period][ - amount]`,
/// the convention of the user's tidied folders, e.g.
/// `20210315 - Building Insurance - Premium - Example Seguros - 2021-03 to 2021-09 - €123.45`.
public enum EvidenceNaming {
    /// How much of the date is known: `20250331`, `202503` or `2025`.
    public enum DatePrecision: Sendable {
        case day, month, year
    }

    /// Blank parts are left out; the period is by month (`2025-03`, or `2016-06 to 2016-12`);
    /// the amount is shown sign-free with its currency symbol, without grouping, and only
    /// with a currency. Dates are read in UTC, like every stored day in the app.
    public static func canonicalName(date: Date, precision: DatePrecision = .day, area: String, type: String, detail: String? = nil,
                                     period: (start: Date, end: Date)? = nil, amountMinorUnits: Int? = nil, currency: Currency? = nil) -> String {
        let calendar = utcCalendar
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let datePart: String
        switch precision {
        case .day: datePart = String(format: "%04d%02d%02d", parts.year!, parts.month!, parts.day!)
        case .month: datePart = String(format: "%04d%02d", parts.year!, parts.month!)
        case .year: datePart = String(format: "%04d", parts.year!)
        }
        var components = [datePart, area, type, detail ?? ""]
        if let period {
            let start = monthLabel(period.start), end = monthLabel(period.end)
            components.append(start == end ? start : "\(start) to \(end)")
        }
        if let amountMinorUnits, let currency {
            let minor = abs(amountMinorUnits)
            components.append(String(format: "%@%d.%02d", currency.symbol, minor / 100, minor % 100))
        }
        return components
            .map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " - ")
    }

    /// A file name for `canonicalName` (exports, tidying folders): `/` becomes `:` — Finder
    /// shows it as `/`, as in the user's `SA 2024:25` folders — and the extension is lowercased.
    public static func fileName(canonicalName: String, fileExtension: String) -> String {
        let base = canonicalName.replacingOccurrences(of: "/", with: ":")
        return fileExtension.isEmpty ? base : "\(base).\(fileExtension.lowercased())"
    }

    private static func monthLabel(_ date: Date) -> String {
        let parts = utcCalendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year!, parts.month!)
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}
