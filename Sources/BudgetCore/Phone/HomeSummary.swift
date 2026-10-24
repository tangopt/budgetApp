import Foundation
import GRDB

/// What the iPhone's Home shows (iPhone spec §3.2), packaged from the Mac dashboard's
/// calculators so the two can't disagree: the freshness line, net worth, this pay month,
/// what needs attention and what's coming up. Nothing here computes a figure of its own.
public struct HomeSummary: Equatable {
    /// One upcoming bill or property obligation.
    public struct UpcomingItem: Equatable, Identifiable {
        public enum Source: String, Equatable, Sendable {
            /// A confirmed planned expense (`DashboardCalculator.upcomingBills`).
            case bill
            /// A property's obligation (`PropertyCalendar.obligations`).
            case propertyObligation
        }

        /// "bill/<bill id>" or "property/<property id>/<obligation id>".
        public let id: String
        public let date: Date
        /// The bill's category, or the obligation's title.
        public let title: String
        /// Money out, positive, in `currency`; nil when the obligation's amount isn't known.
        public let amountMinorUnits: Int?
        public let currency: Currency
        public let source: Source
        /// Projected from history or a rule rather than known (obligations only).
        public let isEstimate: Bool
    }

    public let freshness: DataFreshness
    /// Days from the latest transaction to today; nil without data.
    public let dataAgeDays: Int?
    public let netWorth: NetWorthSeries
    public let month: CurrentMonthTracking
    /// The pay month's planned spending not spent yet (positive): the blended projection
    /// (`MonthBlend`, as the Mac's current month card) less the actual — the year chart's
    /// hatched "still expected" for the month.
    public let leftToSpendMinorUnits: Int
    /// The pay month's projected spending (`month.expenses.projected`, positive).
    public let plannedSpendingMinorUnits: Int
    /// Days from today to the current pay month's close day (its payday); 0 on payday.
    public let daysToPayday: Int
    public let attention: AttentionItems
    /// Bills and obligations over the next `upcomingDays`, by date.
    public let upcoming: [UpcomingItem]

    /// How far ahead Upcoming reads.
    public static let upcomingDays = 60
    /// Data older than this many days shows the freshness line in amber (iPhone spec §3.2).
    public static let freshnessAmberDays = 14

    /// The freshness line in amber: the latest transaction more than `freshnessAmberDays` old.
    /// (The line reads "Data through <date> · last import <when>"; the importing device
    /// waits for the sync records to name devices, step 6.)
    public var isFreshnessAmber: Bool { (dataAgeDays ?? 0) > Self.freshnessAmberDays }

    /// The summary for `today` (normally `input.today`); `db` gives the properties' obligations.
    public static func make(_ input: DashboardInput, db: Database, today: Date) throws -> HomeSummary {
        let calendar = MonthRange.calendar
        let day = calendar.startOfDay(for: today)
        let freshness = DashboardCalculator.dataFreshness(input)
        let age = freshness.dataThrough.map { calendar.dateComponents([.day], from: calendar.startOfDay(for: $0), to: day).day ?? 0 }

        let month = DashboardCalculator.currentMonth(input)
        let planned = month.expenses.projected
        let payday = input.payCalendar.closeDate(of: input.payCalendar.current)
        let daysToPayday = max(0, calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: payday)).day ?? 0)

        return HomeSummary(
            freshness: freshness,
            dataAgeDays: age,
            netWorth: DashboardCalculator.netWorthSeries(input),
            month: month,
            leftToSpendMinorUnits: max(0, planned - month.expenses.actual),
            plannedSpendingMinorUnits: planned,
            daysToPayday: daysToPayday,
            attention: DashboardCalculator.attentionItems(input),
            upcoming: try upcoming(input, db: db, today: day)
        )
    }

    /// The forecast's bills and every property's obligations over the next `upcomingDays`:
    /// by date, then bills before obligations, then title.
    static func upcoming(_ input: DashboardInput, db: Database, today: Date) throws -> [UpcomingItem] {
        let bills = DashboardCalculator.upcomingBills(input, days: upcomingDays).map { bill in
            UpcomingItem(id: "bill/\(bill.id)", date: bill.date, title: bill.categoryName, amountMinorUnits: -bill.amountMinorUnits,
                         currency: .gbp, source: .bill, isEstimate: false)
        }
        let end = MonthRange.calendar.date(byAdding: .day, value: upcomingDays, to: today)!
        var obligations: [UpcomingItem] = []
        for property in try Properties.all(db: db) {
            guard let propertyId = property.id else { continue }
            for obligation in try PropertyCalendar.obligations(db: db, propertyId: propertyId, from: today, to: end, today: today) {
                obligations.append(UpcomingItem(id: "property/\(propertyId)/\(obligation.id)", date: obligation.date, title: obligation.title,
                                                amountMinorUnits: obligation.expectedMinorUnits, currency: obligation.currency ?? property.currency,
                                                source: .propertyObligation, isEstimate: obligation.isEstimate))
            }
        }
        func rank(_ source: UpcomingItem.Source) -> Int { source == .bill ? 0 : 1 }
        return (bills + obligations).sorted {
            ($0.date, rank($0.source), $0.title, $0.id) < ($1.date, rank($1.source), $1.title, $1.id)
        }
    }
}
