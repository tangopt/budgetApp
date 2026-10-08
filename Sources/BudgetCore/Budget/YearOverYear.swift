// Sources/BudgetCore/Budget/YearOverYear.swift
import Foundation

/// The Budget grid's multi-year columns: each selected year compared with the previous
/// selected year.
public enum YearOverYear {
    /// current − previous, and the change as a fraction of |previous| (nil when previous is 0).
    public static func delta(current: Int, previous: Int) -> (amount: Int, fraction: Double?) {
        let amount = current - previous
        return (amount, previous == 0 ? nil : Double(amount) / Double(abs(previous)))
    }

    /// Whether the change is good for a line of this type: expenses (negative values) improve when
    /// less negative, income when higher; transfers/balances return nil (neutral).
    public static func isImprovement(amount: Int, categoryType: CategoryType?) -> Bool? {
        guard amount != 0 else { return nil }
        switch categoryType {
        case .expense?, .income?: return amount > 0
        case .transfer?, nil: return nil
        }
    }
}
