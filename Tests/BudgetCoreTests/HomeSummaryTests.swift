import XCTest
import GRDB
@testable import BudgetCore
@testable import BudgetDemo

final class HomeSummaryTests: XCTestCase {
    private var manager: DatabaseManager!
    private var evidence: URL!

    override func setUpWithError() throws {
        (manager, evidence) = try PhoneDemoFixture.build()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: evidence)
    }

    private func summary(today: Date = PhoneDemoFixture.today) throws -> (HomeSummary, DashboardInput) {
        try manager.dbQueue.read { db in
            let input = try PhoneDemoFixture.input(db, today: today)
            return (try HomeSummary.make(input, db: db), input)
        }
    }

    /// Home's pay-month figures are the Mac dashboard's: the current month card's tracking,
    /// planned spending its blended (`MonthBlend`) projection, left to spend the part of it
    /// not yet spent — the year chart's hatched "still expected" for the month.
    func testHomeLeftToSpendEqualsTheMacDashboard() throws {
        let (home, input) = try summary()
        let month = DashboardCalculator.currentMonth(input)
        XCTAssertEqual(home.month, month)
        XCTAssertEqual(home.freshness, DashboardCalculator.dataFreshness(input))
        XCTAssertEqual(home.netWorth, DashboardCalculator.netWorthSeries(input))
        XCTAssertEqual(home.attention, DashboardCalculator.attentionItems(input))

        XCTAssertEqual(home.plannedSpendingMinorUnits, month.expenses.projected)
        XCTAssertEqual(home.leftToSpendMinorUnits, max(0, month.expenses.projected - month.expenses.actual))
        let flow = DashboardCalculator.monthlyFlows(input, year: month.year)[month.month - 1]
        XCTAssertEqual(home.leftToSpendMinorUnits, flow.expenseRemaining)
        XCTAssertEqual(home.plannedSpendingMinorUnits, flow.expenseTotal)
        // The demo's October is open and part spent: both figures mean something.
        XCTAssertEqual(month.monthClass, .blended)
        XCTAssertGreaterThan(home.leftToSpendMinorUnits, 0)
        XCTAssertGreaterThan(month.expenses.actual, 0)

        // Days to payday: today to the current pay month's close day (its payday).
        let close = input.payCalendar.closeDate(of: input.payCalendar.current)
        let days = MonthRange.calendar.dateComponents([.day], from: PhoneDemoFixture.today, to: close).day!
        XCTAssertEqual(home.daysToPayday, days)
        XCTAssertGreaterThanOrEqual(home.daysToPayday, 0)
    }

    /// Upcoming merges the forecast's bills (the Mac's `upcomingBills`) with every property's
    /// obligations over the next 60 days, by date.
    func testUpcomingMergesBillsAndObligationsByDate() throws {
        let (home, input) = try summary()
        let today = PhoneDemoFixture.today
        let end = MonthRange.calendar.date(byAdding: .day, value: HomeSummary.upcomingDays, to: today)!
        let bills = DashboardCalculator.upcomingBills(input, days: HomeSummary.upcomingDays)
        let obligations = try manager.dbQueue.read { db in
            try Properties.all(db: db).flatMap { try PropertyCalendar.obligations(db: db, propertyId: $0.id!, from: today, to: end, today: today) }
        }
        XCTAssertFalse(bills.isEmpty)
        XCTAssertFalse(obligations.isEmpty)

        XCTAssertEqual(home.upcoming.filter { $0.source == .bill }.count, bills.count)
        XCTAssertEqual(home.upcoming.filter { $0.source == .propertyObligation }.count, obligations.count)
        XCTAssertEqual(home.upcoming.map(\.date), home.upcoming.map(\.date).sorted())
        XCTAssertEqual(Set(home.upcoming.map(\.id)).count, home.upcoming.count)

        // A bill: its category, money out as a positive amount, in pounds.
        let bill = try XCTUnwrap(bills.first)
        let billItem = try XCTUnwrap(home.upcoming.first { $0.source == .bill && $0.date == bill.date && $0.title == bill.categoryName })
        XCTAssertEqual(billItem.amountMinorUnits, -bill.amountMinorUnits)
        XCTAssertEqual(billItem.currency, .gbp)
        // An obligation: its title, expected amount and currency (the demo flat's euros).
        let instalment = try XCTUnwrap(obligations.first { $0.kind == .mortgageInstalment })
        let item = try XCTUnwrap(home.upcoming.first { $0.source == .propertyObligation && $0.date == instalment.date && $0.title == instalment.title })
        XCTAssertEqual(item.amountMinorUnits, instalment.expectedMinorUnits)
        XCTAssertEqual(item.currency, .eur)
        XCTAssertEqual(item.isEstimate, instalment.isEstimate)
        XCTAssertTrue(home.upcoming.allSatisfy { $0.date >= today && $0.date < end.addingTimeInterval(86_400) })
    }

    /// The freshness line turns amber once the data is more than 14 days old.
    func testFreshnessIsAmberAfter14Days() throws {
        let (home, input) = try summary()
        let dataThrough = try XCTUnwrap(input.dataThrough)
        XCTAssertEqual(home.freshness.dataThrough, dataThrough)
        XCTAssertFalse(home.isFreshnessAmber)

        let calendar = MonthRange.calendar
        let day14 = calendar.date(byAdding: .day, value: 14, to: calendar.startOfDay(for: dataThrough))!
        let day15 = calendar.date(byAdding: .day, value: 15, to: calendar.startOfDay(for: dataThrough))!
        XCTAssertEqual(try summary(today: day14).0.dataAgeDays, 14)
        XCTAssertFalse(try summary(today: day14).0.isFreshnessAmber)
        XCTAssertEqual(try summary(today: day15).0.dataAgeDays, 15)
        XCTAssertTrue(try summary(today: day15).0.isFreshnessAmber)
        // Still "up to date" for the Mac (its threshold is 31 days); the phone is stricter.
        XCTAssertEqual(try summary(today: day15).0.freshness.status, .upToDate)

        // No data: nothing to be stale.
        let empty = try DatabaseManager(path: nil)
        try empty.migrate()
        let none = try empty.dbQueue.read { db in
            try HomeSummary.make(try PhoneDemoFixture.input(db, today: day15), db: db)
        }
        XCTAssertEqual(none.freshness.status, .noData)
        XCTAssertNil(none.dataAgeDays)
        XCTAssertFalse(none.isFreshnessAmber)
        XCTAssertTrue(none.upcoming.isEmpty)
    }

    /// Two planned bills alike in category, day and amount still get distinct ids (SwiftUI
    /// identity): each is its own planned occurrence.
    func testTwinBillsHaveDistinctIds() throws {
        let d = DashboardFixture.date
        let today = d(2026, 3, 10)
        let entries = (1...2).map { id in
            ForecastEntry(id: Int64(10 + id), groupId: 1, categoryId: DashboardFixture.rentId, amountMinorUnits: -5_000, frequency: .monthly,
                          interval: 1, startDate: d(2026, 1, 20), endDate: nil, isEnabled: true, status: .manual, note: nil)
        }
        let input = DashboardFixture.input(today: today, entries: entries)
        let empty = try DatabaseManager(path: nil)
        try empty.migrate()
        let home = try empty.dbQueue.read { db in try HomeSummary.make(input, db: db) }
        let bills = home.upcoming.filter { $0.source == .bill && $0.date == d(2026, 3, 20) }
        XCTAssertEqual(bills.count, 2)
        XCTAssertEqual(Set(home.upcoming.map(\.id)).count, home.upcoming.count)
    }

    /// Home's whole day is the input's: the freshness age, Upcoming's window and the days to
    /// payday all count from `input.today` (never earlier than the data).
    func testHomeUsesTheInputsToday() throws {
        let (home, input) = try summary()
        XCTAssertEqual(input.today, PhoneDemoFixture.today)
        XCTAssertTrue(home.upcoming.allSatisfy { $0.date >= MonthRange.calendar.startOfDay(for: input.today) })
        XCTAssertEqual(home.daysToPayday, home.month.daysInMonth - home.month.dayOfMonth)
    }

    /// The phone's summaries cross actors (a GRDB read in the background, a view on the main actor).
    func testSummariesAreSendable() {
        func sendable<T: Sendable>(_: T.Type) {}
        sendable(HomeSummary.self)
        sendable(HomeSummary.UpcomingItem.self)
        sendable(PayMonthReview.self)
        sendable(PayMonthReview.Row.self)
        sendable(PropertyGlance.self)
    }
}
