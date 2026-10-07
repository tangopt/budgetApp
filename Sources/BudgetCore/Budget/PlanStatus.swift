import Foundation

/// Whether a Budget cell still carries unconfirmed (planned, not yet happened) money.
public enum PendingState: Equatable {
    /// Nothing pending: a closed month, nothing planned, or actuals cover the plan.
    case none
    /// Nothing has happened yet; the whole plan is pending.
    case allExpected
    /// Some has happened, less than planned.
    case partial
}

/// How a Budget grid cell combines a category's pay-month actual with its planned total for
/// the calendar month (spec 2026-10-07-budget-plan-design.md, "Confirmation").
public enum PlanStatus {
    /// `value = actual + pending`; closed months: `(actual, 0, .none)`.
    ///
    /// The plan is an envelope in its own direction — expenses outward, income inward,
    /// transfers by the sign of the plan (as `MonthBlend`). `pending` is what the plan still
    /// expects beyond the actual, signed like the plan, so an open month's `value` equals
    /// `MonthBlend.projectedTotal` for a blended month.
    public static func cell(actual: Int, planned: Int, categoryType: CategoryType, monthClass: MonthClass) -> (value: Int, pending: Int, state: PendingState) {
        if monthClass == .actual { return (actual, 0, .none) }
        let direction: Int
        switch categoryType {
        case .expense: direction = -1
        case .income: direction = 1
        case .transfer: direction = planned.signum()
        }
        let plannedMagnitude = direction * planned
        guard direction != 0, plannedMagnitude > 0 else { return (actual, 0, .none) }
        let actualMagnitude = direction * actual
        let remaining = max(0, plannedMagnitude - actualMagnitude)
        guard remaining > 0 else { return (actual, 0, .none) }
        let pending = direction * remaining
        return (actual + pending, pending, actual == 0 ? .allExpected : .partial)
    }
}
