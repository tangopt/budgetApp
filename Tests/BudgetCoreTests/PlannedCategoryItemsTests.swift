import XCTest
import GRDB
@testable import BudgetCore
@testable import BudgetDemo

final class PlannedCategoryItemsTests: XCTestCase {
    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func entry(id: Int64, category: Int64 = 1, amount: Int, frequency: ForecastFrequency = .monthly, start: Date, note: String? = nil) -> ForecastEntry {
        ForecastEntry(id: id, groupId: 1, categoryId: category, amountMinorUnits: amount, frequency: frequency, interval: 1,
                      startDate: start, endDate: nil, isEnabled: true, status: .confirmed, note: note)
    }

    private func transaction(id: Int64, _ date: Date, _ amount: Int) -> Transaction {
        Transaction(id: id, importBatchId: 1, accountId: 1, date: date, rawDescription: "t\(id)", amountMinorUnits: amount, categoryId: 1, status: .confirmed, categorizedBy: .manual, fingerprint: "f\(id)")
    }

    private let group = ForecastGroup(id: 1, name: "Planned", note: nil, isEnabled: true, isSystemManaged: false)
    private var october: PayPeriod {
        PayPeriod(startDate: Self.day(2026, 10, 1), endDate: Self.day(2026, 10, 31), type: .projected)
    }

    func testItemsAreTheCategorysOccurrencesByDateAndMatchedOnesAreDone() {
        let entries = [entry(id: 1, amount: -50_000, start: Self.day(2026, 1, 20), note: "Rent share"),
                       entry(id: 2, amount: -3_000, frequency: .weekly, start: Self.day(2026, 10, 2)),
                       entry(id: 3, category: 2, amount: -999, start: Self.day(2026, 1, 5))]
        let items = PlannedCategoryItems.items(categoryId: 1, planPeriod: october, entries: entries, groups: [group], exceptions: [],
                                               transactions: [transaction(id: 10, Self.day(2026, 10, 19), -50_100),
                                                              transaction(id: 11, Self.day(2026, 10, 3), -3_000)])
        XCTAssertEqual(items.map(\.date), items.map(\.date).sorted())
        // Weekly from 2 Oct: 2, 9, 16, 23, 30; monthly on the 20th; none of category 2.
        XCTAssertEqual(items.count, 6)
        XCTAssertTrue(items.allSatisfy { $0.entryId != 3 })
        let rent = items.first { $0.entryId == 1 }
        XCTAssertEqual(rent?.note, "Rent share")
        XCTAssertEqual(rent?.matchedTransactionId, 10) // within 10% of -500.00
        // The weekly item on the 2nd takes the £30 payment; the others stay planned.
        XCTAssertEqual(items.filter { $0.entryId == 2 }.map(\.isDone), [true, false, false, false, false])
        XCTAssertEqual(items.reduce(0) { $0 + $1.amountMinorUnits }, -50_000 - 5 * 3_000)
    }

    func testATransactionCoversOnlyOneItemAndOnlyOneOfTheSameDirection() {
        let entries = [entry(id: 1, amount: -2_000, frequency: .weekly, start: Self.day(2026, 10, 1))]
        let items = PlannedCategoryItems.items(categoryId: 1, planPeriod: october, entries: entries, groups: [group], exceptions: [],
                                               transactions: [transaction(id: 1, Self.day(2026, 10, 2), -2_000),
                                                              transaction(id: 2, Self.day(2026, 10, 3), 2_000)]) // a refund
        XCTAssertEqual(items.filter(\.isDone).count, 1)
        XCTAssertEqual(items.compactMap(\.matchedTransactionId), [1])
    }

    func testOffPlanAmountsDoNotMatchAndDisabledGroupsHaveNoItems() {
        let entries = [entry(id: 1, amount: -10_000, start: Self.day(2026, 1, 10))]
        let far = PlannedCategoryItems.items(categoryId: 1, planPeriod: october, entries: entries, groups: [group], exceptions: [],
                                             transactions: [transaction(id: 1, Self.day(2026, 10, 10), -15_000)])
        XCTAssertEqual(far.map(\.isDone), [false])
        let off = ForecastGroup(id: 1, name: "Planned", note: nil, isEnabled: false, isSystemManaged: false)
        XCTAssertTrue(PlannedCategoryItems.items(categoryId: 1, planPeriod: october, entries: entries, groups: [off], exceptions: [], transactions: []).isEmpty)
    }

    func testMovedAndSkippedOccurrencesFollowThePlan() {
        let entries = [entry(id: 1, amount: -10_000, start: Self.day(2026, 1, 10))]
        let moved = PlannedOccurrenceException(entryId: 1, originalDate: Self.day(2026, 10, 10), date: Self.day(2026, 10, 14))
        let items = PlannedCategoryItems.items(categoryId: 1, planPeriod: october, entries: entries, groups: [group], exceptions: [moved], transactions: [])
        XCTAssertEqual(items.map(\.date), [Self.day(2026, 10, 14)])
        let skipped = PlannedOccurrenceException(entryId: 1, originalDate: Self.day(2026, 10, 10), isSkipped: true)
        XCTAssertTrue(PlannedCategoryItems.items(categoryId: 1, planPeriod: october, entries: entries, groups: [group], exceptions: [skipped], transactions: []).isEmpty)
    }

    /// On the demo, a row's items add up to its plan figure: both are the confirmed plan's occurrences.
    func testItemsSumToTheRowsPlanOnTheDemo() throws {
        let (manager, evidence) = try PhoneDemoFixture.build()
        defer { try? FileManager.default.removeItem(at: evidence) }
        let (review, today) = try manager.dbQueue.read { db -> (PayMonthReview, Date) in
            let input = try PhoneDemoFixture.input(db)
            return (PayMonthReview.make(month: input.payCalendar.current, input: input), input.today)
        }
        XCTAssertNotNil(review.range.month)
        var checked = 0
        for row in review.rows where row.planMinorUnits != 0 {
            let items = try manager.dbQueue.read { db in
                try PlannedCategoryItems.read(db: db, categoryId: row.id, range: review.range, viewer: SharingViewer(personId: nil), today: today)
            }
            XCTAssertEqual(items.reduce(0) { $0 + $1.amountMinorUnits }, row.planMinorUnits, row.category.name)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }
}
