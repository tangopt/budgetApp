// Sources/BudgetCore/Budget/BudgetGridExporter.swift
import Foundation

public enum BudgetGridExporter {
    public static func export(categories: [Category], periods: [PayPeriod], transactions: [Transaction]) -> String {
        let actualPeriods = periods.filter { $0.type == .actual }.sorted { $0.startDate < $1.startDate }
        let dateFormatter = DateFormatter()
        // Local timezone is deliberate (matches the grid UI's local-time display);
        // POSIX locale pins the fixed "yyyy-MM-dd" format against user calendar settings.
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"

        var lines = ["Category," + actualPeriods.map { dateFormatter.string(from: $0.startDate) }.joined(separator: ",")]
        for category in categories {
            let values = actualPeriods.map { period -> String in
                let total = BudgetGridCalculator.categoryTotal(category: category, period: period, transactions: transactions, forecastEntries: [], forecastGroups: [])
                return String(format: "%.2f", Double(total) / 100.0)
            }
            lines.append(([category.name] + values).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }
}
