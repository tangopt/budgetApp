import Foundation
import BudgetCore

/// Home's words (iPhone spec §3.2): how the cards name what `HomeSummary` gives them. Wording only, no figures.
public enum HomeCopy {
    /// Upcoming lists this many items.
    public static let upcomingLimit = 5

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
