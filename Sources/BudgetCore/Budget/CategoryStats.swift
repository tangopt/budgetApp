import Foundation

/// Figures shown next to each category on the Categories screen (spec §4).
public enum CategoryStats {
    /// Each category's average monthly actual over the last `months` complete pay months
    /// (the current, still-open month is left out), rounded to the nearest minor unit.
    /// A category whose first confirmed transaction falls inside the window is averaged over
    /// the months since then, so a new category isn't diluted by months it didn't exist.
    /// Categories with no actuals in the window are absent ("—").
    public static func monthlyAverages(transactions: [Transaction], calendar: PayCalendar, months: Int = 12) -> [Int64: Int] {
        let last = calendar.current.previous
        var first = last
        for _ in 1..<months { first = first.previous }
        var totals: [Int64: Int] = [:]
        var earliest: [Int64: PayMonth] = [:]
        for transaction in transactions {
            guard transaction.status == .confirmed, let categoryId = transaction.categoryId else { continue }
            let month = calendar.month(containing: transaction.date)
            earliest[categoryId] = min(earliest[categoryId] ?? month, month)
            if month >= first && month <= last { totals[categoryId, default: 0] += transaction.amountMinorUnits }
        }
        var result: [Int64: Int] = [:]
        for (categoryId, total) in totals {
            let start = max(first, earliest[categoryId] ?? first)
            let divisor = last.index - start.index + 1
            result[categoryId] = Int((Double(total) / Double(divisor)).rounded())
        }
        return result
    }
}
