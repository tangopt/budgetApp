import Foundation
import BudgetCore

/// Month's segments (iPhone spec §3.3): which rows of the pay month show.
public enum MonthSegment: String, CaseIterable, Identifiable, Sendable {
    case spending, income, transfers

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .spending: "Spending"
        case .income: "Income"
        case .transfers: "Transfers"
        }
    }

    var categoryType: CategoryType {
        switch self {
        case .spending: .expense
        case .income: .income
        case .transfers: .transfer
        }
    }

    /// The sentence a segment with no rows shows (the month has rows of another kind).
    var emptyMessage: String {
        switch self {
        case .spending: "No spending in this month."
        case .income: "No income in this month."
        case .transfers: "No transfers in this month."
        }
    }
}

/// One pay month as Month shows it: `PayMonthReview` and the months ‹ › can reach (the pay calendar's, from the
/// month of the first transaction to the current one).
public struct MonthPage: Equatable, Sendable {
    public let review: PayMonthReview
    public let months: ClosedRange<PayMonth>
    /// The month has closed (a salary or a manual close ends it), so nothing is still expected.
    public let isClosed: Bool

    public func rows(_ segment: MonthSegment) -> [PayMonthReview.Row] { review.rows(of: segment.categoryType) }

    /// Nothing in the month: no transactions and no plan ("No transactions in this month yet").
    public var isEmpty: Bool { review.rows.isEmpty }
}

/// One figure of the summary grid: its label, the review's figure, the role it's drawn in and what VoiceOver reads.
public struct MonthSummaryTile: Equatable, Sendable, Identifiable {
    public let label: String
    public let minorUnits: Int
    public let role: MoneyRole
    public let spoken: String
    public var id: String { label }

    /// Income · Spent so far · Still expected · Left to spend (iPhone spec §3.3), straight from the review. "Still
    /// expected" is planned spending not yet spent; "Left to spend" is the month's net (income − spent − still
    /// expected), drawn in the expense colour when it's negative and read as "minus", never as owed.
    public static func tiles(_ review: PayMonthReview) -> [MonthSummaryTile] {
        func tile(_ label: String, _ minorUnits: Int, _ role: MoneyRole, spokenAs spokenRole: MoneyRole? = nil) -> MonthSummaryTile {
            MonthSummaryTile(label: label, minorUnits: minorUnits, role: role,
                             spoken: MoneyPresentation(minorUnits: minorUnits, currency: .gbp, role: spokenRole ?? role).spoken)
        }
        return [
            tile("Income", review.incomeMinorUnits, .income),
            tile("Spent so far", review.spentMinorUnits, .expense),
            tile("Still expected", review.stillExpectedMinorUnits, .neutral),
            tile("Left to spend", review.leftToSpendMinorUnits, .balance, spokenAs: .neutral),
        ]
    }
}

/// A category row's words (iPhone spec §3.3): "actual / plan", how far along the plan it is, and "£x left" or
/// "£x over plan". Wording only: the figures are the review's (`PayMonthReview.Row`).
public struct CategoryRowPresentation: Equatable, Sendable {
    /// "£320.00 / £400.00"; just the actual without a plan.
    public let amounts: String
    /// The actual alone ("£320.00") and the plan as its second line at accessibility sizes ("of £400.00"; nil
    /// without a plan), where "actual / plan" can't fit on one line.
    public let actualText: String
    public let planText: String?
    /// The actual as a share of the plan, 0...1; nil without a plan.
    public let fraction: Double?
    /// "£80.00 left", "£100.00 over plan", "£3,000.00 to come"; nil when there's nothing to measure against.
    public let status: String?
    /// Past its plan (`Row.isOverPlan`): the status in the expense colour.
    public let isOverPlan: Bool
    /// What VoiceOver reads after the name: "£320.00 of £400.00 planned, £80.00 left".
    public let spoken: String

    public init(_ row: PayMonthReview.Row) {
        func money(_ minorUnits: Int) -> String { MoneyPresentation.format(minorUnits, currency: .gbp) }
        // The plan's direction: spending outward, income inward, a transfer by its plan's sign.
        let direction: Int? = switch row.category.type {
        case .expense: -1
        case .income: 1
        case .transfer, .adjustment: row.planMinorUnits == 0 ? nil : row.planMinorUnits.signum()
        }
        let hasPlan = row.planMinorUnits != 0
        let actual = direction.map { row.actualMinorUnits * $0 } ?? row.actualMinorUnits
        let plan = direction.map { row.planMinorUnits * $0 } ?? row.planMinorUnits
        actualText = money(actual)
        planText = hasPlan ? "of \(money(plan))" : nil
        if hasPlan {
            amounts = "\(money(actual)) / \(money(plan))"
            fraction = plan > 0 ? min(max(Double(actual) / Double(plan), 0), 1) : nil
        } else {
            amounts = money(actual)
            fraction = nil
        }
        isOverPlan = row.isOverPlan

        switch row.category.type {
        case .expense where !hasPlan:
            status = row.isOverPlan ? "\(money(actual)) over plan" : "No plan"
        case .income:
            if let remaining = row.remainingMinorUnits {
                status = remaining > 0 ? "\(money(remaining)) to come"
                    : remaining < 0 ? "\(money(-remaining)) more than planned" : "As planned"
            } else {
                status = nil
            }
        case .expense, .transfer, .adjustment:
            if let remaining = row.remainingMinorUnits {
                status = remaining >= 0 ? "\(money(remaining)) left" : "\(money(-remaining)) over plan"
            } else {
                status = nil
            }
        }
        spoken = ([hasPlan ? "\(money(actual)) of \(money(plan)) planned" : money(actual)] + [status].compactMap { $0 })
            .joined(separator: ", ")
    }
}

/// Month's words that aren't a row's.
public enum MonthCopy {
    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = MonthRange.calendar
        formatter.timeZone = MonthRange.calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    /// "October 2026": the pay month by the calendar month it closes in.
    public static func title(_ month: PayMonth) -> String {
        monthFormatter.string(from: MonthRange.of(year: month.year, month: month.month).start)
    }

    /// "26 Sep 2026 – 25 Oct 2026": payday to payday.
    public static func range(_ range: PayMonthReview.DayRange) -> String {
        "\(PhoneDateFormat.day(range.start)) – \(PhoneDateFormat.day(range.end))"
    }

    public static let emptyTitle = "No transactions in this month yet"
    public static let emptyMessage = "Spending, income and transfers show here once they sync from the Mac."
}
