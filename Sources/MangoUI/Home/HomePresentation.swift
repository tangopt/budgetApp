import SwiftUI
import Foundation
import BudgetCore

/// Home's words (iPhone spec §3.2): how the cards name what `HomeSummary` gives them. Wording only, no figures.
public enum HomeCopy {
    /// "1 bill", "3 bills" (the recharges chart's readout).
    public static func billCount(_ count: Int) -> String { "\(count) \(count == 1 ? "bill" : "bills")" }

    /// Upcoming lists this many items.
    public static let upcomingLimit = 5
    /// The iPhone's Home lists this many (design review D1: the next 4, with the Calendar as the full list).
    public static let phoneUpcomingLimit = 4

    /// The iPhone Home's blocks, top to bottom (design review §2.3, §4): Left to spend leads, then the two tiles, then
    /// what needs the person and what is coming; the freshness line sits last, and above all of them only when the
    /// data is stale.
    public enum PhoneBlock: Equatable, Sendable {
        case staleData, leftToSpend, tiles, attention, upcoming, freshness
    }

    public static func phoneBlocks(_ summary: HomeSummary) -> [PhoneBlock] {
        (summary.isFreshnessAmber ? [.staleData] : []) + [.leftToSpend, .tiles, .attention, .upcoming]
            + (summary.isFreshnessAmber ? [] : [.freshness])
    }

    /// Under the Left to spend figure: "after spending and what is still expected · payday in 12 days".
    public static func leftToSpendCaption(_ summary: HomeSummary) -> String {
        "after spending and what is still expected · payday \(daysToPayday(summary.daysToPayday))"
    }

    /// Under the Net worth tile's figure: "+£1,200.00 since last month"; nil without a previous month.
    public static func netWorthTileCaption(_ netWorth: NetWorthSeries) -> String? {
        guard let change = netWorth.changeVsPreviousMonthMinorUnits else { return nil }
        let text = MoneyPresentation(minorUnits: change, currency: .gbp, role: .income).text
        return "\(change > 0 ? "+" : "")\(text) since last month"
    }

    /// The two tiles stand side by side only at sizes where a pound figure fits half the width (up to Large); above
    /// that each takes the full width.
    public static func tilesSideBySide(at size: DynamicTypeSize) -> Bool { size <= .large }

    /// "Data through 15 Oct 2026 · last import 15 Oct 2026"; past 14 days, with the age: "Data through 1 Oct 2026 ·
    /// 21 days old · last import 2 Oct 2026". "No data yet" without any.
    public static func freshness(_ summary: HomeSummary) -> String {
        guard let through = summary.freshness.dataThrough else { return "No data yet" }
        var parts = ["Data through \(PhoneDateFormat.day(through))"]
        if summary.isFreshnessAmber, let age = summary.dataAgeDays {
            parts.append("\(age) days old")
        }
        if let imported = summary.freshness.lastImportAt {
            parts.append("last import \(PhoneDateFormat.day(imported))")
        }
        return parts.joined(separator: " · ")
    }

    /// The days to payday as the figure beside "Payday": "in 12 days", "in 1 day", "today".
    public static func daysToPayday(_ days: Int) -> String {
        switch days {
        case 0: "today"
        case 1: "in 1 day"
        default: "in \(days) days"
        }
    }

    /// What VoiceOver reads for the sparkline: where it ends now and the year-end forecast.
    /// "now £129,358.48, forecast for the end of 2026 £134,622.20".
    public static func sparklineValue(_ netWorth: NetWorthSeries) -> String {
        var parts: [String] = []
        if let current = netWorth.currentNetWorthMinorUnits {
            parts.append("now \(MoneyPresentation(minorUnits: current, currency: .gbp, role: .neutral).text)")
        }
        if let yearEnd = netWorth.yearEnds.first {
            parts.append("forecast for the end of \(String(yearEnd.year)) \(MoneyPresentation(minorUnits: yearEnd.valueMinorUnits, currency: .gbp, role: .neutral).text)")
        }
        return parts.joined(separator: ", ")
    }

    /// What VoiceOver reads for the pay month's bar: "spent £2,722.82, still expected £1,193.51, of £3,916.33 planned".
    public static func payMonthBarValue(_ summary: HomeSummary) -> String {
        func amount(_ minorUnits: Int) -> String { MoneyPresentation(minorUnits: minorUnits, currency: .gbp, role: .neutral).text }
        return "spent \(amount(summary.month.expenses.actual)), still expected \(amount(summary.leftToSpendMinorUnits)), "
            + "of \(amount(summary.plannedSpendingMinorUnits)) planned"
    }

    /// The next items, at most `upcomingLimit`.
    public static func nextUpcoming(_ items: [HomeSummary.UpcomingItem]) -> [HomeSummary.UpcomingItem] {
        Array(items.prefix(upcomingLimit))
    }

    /// An upcoming item's day and where it comes from. A property's recurring cost can also be a planned bill, so
    /// Upcoming may list one cost twice (ruling, Task 2): the source tells them apart. "20 Oct 2026 · Planned bill",
    /// "20 Oct 2026 · Property cost, estimated".
    public static func upcomingSource(_ item: HomeSummary.UpcomingItem) -> String {
        let source = switch item.source {
        case .bill: "Planned bill"
        case .propertyObligation: item.isEstimate ? "Property cost, estimated" : "Property cost"
        }
        return "\(PhoneDateFormat.day(item.date)) · \(source)"
    }
}

/// The pay month's bar: of the planned spending, the part spent (solid) and the part still expected (hatched), as
/// fractions of the bar's width. Drawing proportions, not figures: the amounts beside it come from `HomeSummary`.
public struct PayMonthBar: Equatable, Sendable {
    /// 0...1.
    public let spent: Double
    /// 0...(1 − spent).
    public let stillExpected: Double

    public init(spentMinorUnits: Int, stillExpectedMinorUnits: Int, plannedMinorUnits: Int) {
        guard plannedMinorUnits > 0 else {
            spent = 0
            stillExpected = 0
            return
        }
        let planned = Double(plannedMinorUnits)
        let spentShare = min(1, max(0, Double(spentMinorUnits) / planned))
        spent = spentShare
        stillExpected = min(1 - spentShare, max(0, Double(stillExpectedMinorUnits) / planned))
    }
}

/// One line of Needs attention (no actions in this step): a count with its label, or a sync problem in its words.
public struct AttentionLine: Equatable, Identifiable, Sendable {
    public let id: String
    public let symbol: String
    public let label: String
    /// Shown as the line's figure; nil for a sync problem.
    public let count: Int?
    public let detail: String?
    public let tone: SyncStatusCopy.Tone

    /// Uncategorised transactions, balances out of date, and the sync status when it is a problem
    /// (`SyncStatusCopy.isProblem`: waiting for the key is listed, neutral, never as a failure).
    public static func lines(_ items: AttentionItems, syncStatus: SyncStatus, now: Date) -> [AttentionLine] {
        var lines: [AttentionLine] = []
        if items.uncategorizedCount > 0 {
            lines.append(AttentionLine(id: "uncategorised", symbol: "tag", label: "Uncategorised transactions",
                                       count: items.uncategorizedCount, detail: nil, tone: .amber))
        }
        if items.staleBalanceCount > 0 {
            lines.append(AttentionLine(id: "stale", symbol: "clock.arrow.circlepath", label: "Balances out of date",
                                       count: items.staleBalanceCount,
                                       detail: items.oldestStaleSnapshotDate.map { "Oldest from \(PhoneDateFormat.day($0))" },
                                       tone: .amber))
        }
        if SyncStatusCopy.isProblem(syncStatus) {
            let copy = SyncStatusCopy.text(syncStatus, now: now)
            let symbol = if case .waitingForKey = syncStatus { "key" } else { "icloud.slash" }
            lines.append(AttentionLine(id: "sync", symbol: symbol, label: copy.text, count: nil, detail: nil, tone: copy.tone))
        }
        return lines
    }
}
