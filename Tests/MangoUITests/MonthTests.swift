import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category
import BudgetDemo
@testable import MangoUI

/// Month's view models and the words its rows use (iPhone spec §3.3; plan step 4, Task 8). Figures come from
/// `PayMonthReview` and `TransactionSearch`; these tests pin what Month does with them.
@MainActor
final class MonthTests: XCTestCase {
    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func emptyDatabase() throws -> DatabaseQueue {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        return manager.dbQueue
    }

    private static var cachedDemo: DatabaseQueue?

    /// The demo, built once for the class (read-only use only).
    private func demoDatabase() throws -> DatabaseQueue {
        if let queue = Self.cachedDemo { return queue }
        let queue = try emptyDatabase()
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("MonthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidence) }
        try DemoDatabase.build(dbQueue: queue, evidenceRoot: evidence)
        Self.cachedDemo = queue
        return queue
    }

    private func review(_ queue: DatabaseQueue, month: PayMonth?, today: Date) throws -> PayMonthReview {
        try queue.read { db in
            let input = try DashboardInput.load(db: db, today: today)
            return PayMonthReview.make(month: month ?? input.payCalendar.current, input: input)
        }
    }

    // MARK: Loading

    func testTheDemoOpensOnTheCurrentPayMonthWithTheReviewsFigures() async throws {
        let queue = try demoDatabase()
        let today = DemoDatabase.defaultAsOf
        let model = MonthViewModel(dbQueue: queue, today: { today })
        XCTAssertEqual(model.state, .idle)
        await model.load()
        guard case let .loaded(page) = model.state else { return XCTFail("not loaded: \(model.state)") }
        let expected = try review(queue, month: nil, today: today)
        XCTAssertEqual(page.review, expected)
        XCTAssertFalse(page.review.rows.isEmpty)
        XCTAssertTrue(try MonthViewModel.summaryCheck(dbQueue: queue, today: today, shown: page).matches)
    }

    /// The ‹ › range is the calendar's months from the demo's history start to the current month (plan Task 8 step 1).
    func testTheMonthsRunFromTheFirstTransactionToTheCurrentMonth() async throws {
        let queue = try demoDatabase()
        let today = DemoDatabase.defaultAsOf
        let calendar = try await queue.read { db in try DashboardInput.load(db: db, today: today).payCalendar }
        let model = MonthViewModel(dbQueue: queue, today: { today })
        await model.load()
        guard case let .loaded(page) = model.state else { return XCTFail("not loaded") }
        XCTAssertEqual(page.months.lowerBound, calendar.month(containing: DemoDatabase.historyStart))
        XCTAssertEqual(page.months.upperBound, calendar.current)
        XCTAssertEqual(page.review.month, calendar.current)
        XCTAssertFalse(model.canShowNext)
        XCTAssertTrue(model.canShowPrevious)
    }

    func testMovingBackAndForwardReadsThatMonthAndStopsAtTheEnds() async throws {
        let queue = try demoDatabase()
        let today = DemoDatabase.defaultAsOf
        let model = MonthViewModel(dbQueue: queue, today: { today })
        await model.load()
        guard case let .loaded(first) = model.state else { return XCTFail("not loaded") }
        let current = first.review.month

        await model.showPrevious()
        guard case let .loaded(previous) = model.state else { return XCTFail("not loaded") }
        XCTAssertEqual(previous.review.month, current.previous)
        XCTAssertEqual(previous.review, try review(queue, month: current.previous, today: today))
        XCTAssertTrue(model.canShowNext)

        await model.showNext()
        guard case let .loaded(back) = model.state else { return XCTFail("not loaded") }
        XCTAssertEqual(back.review.month, current)
        await model.showNext()  // past the current month: stays
        guard case let .loaded(still) = model.state else { return XCTFail("not loaded") }
        XCTAssertEqual(still.review.month, current)

        // All the way back: stops at the first month.
        var steps = 0
        while model.canShowPrevious, steps < 200 {
            await model.showPrevious()
            steps += 1
        }
        guard case let .loaded(earliest) = model.state else { return XCTFail("not loaded") }
        XCTAssertEqual(earliest.review.month, earliest.months.lowerBound)
        await model.showPrevious()
        guard case let .loaded(stays) = model.state else { return XCTFail("not loaded") }
        XCTAssertEqual(stays.review.month, earliest.months.lowerBound)
    }

    func testTheSegmentStaysWhenTheMonthChanges() async throws {
        let model = MonthViewModel(dbQueue: try demoDatabase(), today: { DemoDatabase.defaultAsOf })
        await model.load()
        model.segment = .income
        await model.showPrevious()
        XCTAssertEqual(model.segment, .income)
    }

    /// Before the first sync: the current month, nothing in it, the four figures at zero.
    func testAnEmptyDatabaseIsAMonthWithNoRows() async throws {
        let model = MonthViewModel(dbQueue: try emptyDatabase(), today: { Self.day(2026, 10, 15) })
        await model.load()
        guard case let .loaded(page) = model.state else { return XCTFail("not loaded: \(model.state)") }
        XCTAssertTrue(page.review.rows.isEmpty)
        XCTAssertTrue(page.isEmpty)
        XCTAssertEqual(page.months.lowerBound, page.months.upperBound)
        XCTAssertFalse(model.canShowPrevious)
        XCTAssertFalse(model.canShowNext)
    }

    func testAFailedReadKeepsThePageAndAFirstFailureShowsTheFixedSentence() async throws {
        let queue = try emptyDatabase()
        let model = MonthViewModel(dbQueue: queue, today: { Self.day(2026, 10, 15) })
        await model.load()
        guard case .loaded = model.state else { return XCTFail("not loaded") }
        try await queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "DROP TABLE account")
        }
        await model.load()
        guard case .loaded = model.state else { return XCTFail("the page was dropped: \(model.state)") }
        XCTAssertEqual(model.errorMessage, MonthViewModel.loadFailureMessage)

        let fresh = MonthViewModel(dbQueue: queue, today: { Self.day(2026, 10, 15) })
        await fresh.load()
        XCTAssertEqual(fresh.state, .failed(MonthViewModel.loadFailureMessage))
        XCTAssertFalse(MonthViewModel.loadFailureMessage.contains("SQL"))
    }

    func testAReloadWaitsForANewSync() async throws {
        let queue = try emptyDatabase()
        let model = MonthViewModel(dbQueue: queue, today: { DemoDatabase.defaultAsOf })
        await model.reload(for: nil)
        guard case let .loaded(empty) = model.state else { return XCTFail("not loaded") }
        XCTAssertTrue(empty.isEmpty)

        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("MonthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidence) }
        try DemoDatabase.build(dbQueue: queue, evidenceRoot: evidence)

        await model.reload(for: nil)  // a sync running: keeps what is shown
        guard case let .loaded(stillEmpty) = model.state else { return XCTFail("not loaded") }
        XCTAssertTrue(stillEmpty.isEmpty)
        await model.reload(for: Self.day(2026, 10, 15))
        guard case let .loaded(synced) = model.state else { return XCTFail("not loaded") }
        XCTAssertFalse(synced.isEmpty)
    }

    // MARK: Segments and the summary grid

    func testSegmentsSplitTheRowsByType() async throws {
        let model = MonthViewModel(dbQueue: try demoDatabase(), today: { DemoDatabase.defaultAsOf })
        await model.load()
        guard case let .loaded(page) = model.state else { return XCTFail("not loaded") }
        XCTAssertTrue(page.rows(.spending).allSatisfy { $0.category.type == .expense })
        XCTAssertTrue(page.rows(.income).allSatisfy { $0.category.type == .income })
        XCTAssertTrue(page.rows(.transfers).allSatisfy { $0.category.type == .transfer })
        XCTAssertFalse(page.rows(.spending).isEmpty)
        XCTAssertFalse(page.rows(.income).isEmpty)
        XCTAssertEqual(MonthSegment.allCases.map(\.title), ["Spending", "Income", "Transfers"])
    }

    func testTheSummaryGridIsTheReviewsFourFiguresInOrder() {
        let review = PayMonthReview(month: PayMonth(year: 2026, month: 10),
                                    range: .init(start: Self.day(2026, 9, 26), end: Self.day(2026, 10, 25)),
                                    incomeMinorUnits: 400_000, spentMinorUnits: 250_000, stillExpectedMinorUnits: 100_000,
                                    leftToSpendMinorUnits: 50_000, rows: [])
        let tiles = MonthSummaryTile.tiles(review)
        XCTAssertEqual(tiles.map(\.label), ["Income", "Spent so far", "Still expected", "Left to spend"])
        XCTAssertEqual(tiles.map(\.minorUnits), [400_000, 250_000, 100_000, 50_000])
        XCTAssertEqual(tiles.map(\.role), [.income, .expense, .neutral, .balance])
        XCTAssertEqual(tiles[1].spoken, "spent £2,500.00")
        XCTAssertEqual(tiles[3].spoken, "£500.00")
    }

    /// A month that leaves less than nothing: in the expense colour, read as "minus", never as "owed".
    func testANegativeLeftToSpendIsRedAndReadAsMinus() {
        let review = PayMonthReview(month: PayMonth(year: 2026, month: 10),
                                    range: .init(start: Self.day(2026, 9, 26), end: Self.day(2026, 10, 25)),
                                    incomeMinorUnits: 100_000, spentMinorUnits: 150_000, stillExpectedMinorUnits: 0,
                                    leftToSpendMinorUnits: -50_000, rows: [])
        let left = MonthSummaryTile.tiles(review)[3]
        XCTAssertEqual(MoneyPresentation(minorUnits: left.minorUnits, currency: .gbp, role: left.role).tone, .expense)
        XCTAssertEqual(left.spoken, "minus £500.00")
    }

    func testTheHeaderNamesTheMonthAndItsRange() {
        XCTAssertEqual(MonthCopy.title(PayMonth(year: 2026, month: 10)), "October 2026")
        let range = PayMonthReview.DayRange(start: Self.day(2026, 9, 26), end: Self.day(2026, 10, 26).addingTimeInterval(-1))
        XCTAssertEqual(MonthCopy.range(range), "26 Sep 2026 – 25 Oct 2026")
    }

    // MARK: Category rows

    private func category(_ type: CategoryType, reserved: Bool = false, excluded: Bool = false) -> Category {
        Category(id: 7, name: "Groceries", type: type, isReserved: reserved, excludeFromAutoForecast: excluded)
    }

    private func row(_ type: CategoryType, actual: Int, plan: Int, excluded: Bool = false) -> PayMonthReview.Row {
        let category = category(type, excluded: excluded)
        return PayMonthReview.Row(id: 7, category: category, actualMinorUnits: actual, planMinorUnits: plan,
                                  isOverPlan: PayMonthReview.isOverPlan(category, actual: actual, plan: plan))
    }

    func testAnExpenseUnderPlanSaysWhatIsLeft() {
        let shown = CategoryRowPresentation(row(.expense, actual: -32_000, plan: -40_000))
        XCTAssertEqual(shown.amounts, "£320.00 / £400.00")
        XCTAssertEqual(shown.actualText, "£320.00")
        XCTAssertEqual(shown.planText, "of £400.00")
        XCTAssertEqual(shown.fraction!, 0.8, accuracy: 0.0001)
        XCTAssertEqual(shown.status, "£80.00 left")
        XCTAssertFalse(shown.isOverPlan)
    }

    func testAnExpenseOverPlanSaysHowFarInTheExpenseColour() {
        let shown = CategoryRowPresentation(row(.expense, actual: -50_000, plan: -40_000))
        XCTAssertEqual(shown.amounts, "£500.00 / £400.00")
        XCTAssertEqual(shown.fraction, 1)
        XCTAssertEqual(shown.status, "£100.00 over plan")
        XCTAssertTrue(shown.isOverPlan)
    }

    func testAnUnplannedExpenseIsAllOverPlanUnlessAReserveCoversIt() {
        let unplanned = CategoryRowPresentation(row(.expense, actual: -2_499, plan: 0))
        XCTAssertEqual(unplanned.amounts, "£24.99")
        XCTAssertNil(unplanned.planText)
        XCTAssertNil(unplanned.fraction)
        XCTAssertEqual(unplanned.status, "£24.99 over plan")
        XCTAssertTrue(unplanned.isOverPlan)

        let covered = CategoryRowPresentation(row(.expense, actual: -2_499, plan: 0, excluded: true))
        XCTAssertEqual(covered.status, "No plan")
        XCTAssertFalse(covered.isOverPlan)
    }

    func testIncomeSaysWhatIsStillToCome() {
        let shown = CategoryRowPresentation(row(.income, actual: 100_000, plan: 400_000))
        XCTAssertEqual(shown.amounts, "£1,000.00 / £4,000.00")
        XCTAssertEqual(shown.status, "£3,000.00 to come")
        XCTAssertFalse(shown.isOverPlan)
        XCTAssertEqual(CategoryRowPresentation(row(.income, actual: 450_000, plan: 400_000)).status, "£500.00 more than planned")
        XCTAssertEqual(CategoryRowPresentation(row(.income, actual: 400_000, plan: 400_000)).status, "As planned")
        XCTAssertNil(CategoryRowPresentation(row(.income, actual: 5_000, plan: 0)).status)
    }

    func testATransferIsMeasuredInItsPlansDirection() {
        let saving = CategoryRowPresentation(row(.transfer, actual: -30_000, plan: -50_000))
        XCTAssertEqual(saving.amounts, "£300.00 / £500.00")
        XCTAssertEqual(saving.status, "£200.00 left")
        let unplanned = CategoryRowPresentation(row(.transfer, actual: -30_000, plan: 0))
        XCTAssertEqual(unplanned.amounts, "\u{2212}£300.00")
        XCTAssertNil(unplanned.status)
        XCTAssertFalse(unplanned.isOverPlan)
    }

    func testARowReadsItsFiguresToVoiceOver() {
        let shown = CategoryRowPresentation(row(.expense, actual: -32_000, plan: -40_000))
        XCTAssertEqual(shown.spoken, "£320.00 of £400.00 planned, £80.00 left")
    }

    // MARK: A row's transactions

    /// The transactions a row opens add up to the row's actual (compared where they're all in pounds, as the review
    /// converts euro amounts).
    func testARowsTransactionsAddUpToItsActual() async throws {
        let queue = try demoDatabase()
        let today = DemoDatabase.defaultAsOf
        let review = try review(queue, month: nil, today: today)
        var compared = 0
        for row in review.rows(of: .expense) {
            let model = MonthTransactionsModel(dbQueue: queue, row: row, range: review.range)
            await model.load()
            guard case let .loaded(days) = model.state else { return XCTFail("\(row.category.name): not loaded") }
            let rows = days.flatMap(\.rows)
            XCTAssertTrue(rows.allSatisfy { $0.transaction.categoryId == row.id })
            XCTAssertTrue(rows.allSatisfy { $0.date >= review.range.start && $0.date <= review.range.end })
            guard rows.allSatisfy({ $0.currency == .gbp }) else { continue }
            XCTAssertEqual(rows.reduce(0) { $0 + $1.amountMinorUnits }, row.actualMinorUnits, row.category.name)
            compared += 1
        }
        XCTAssertGreaterThan(compared, 3)
    }

    func testTransactionsAreGroupedByDayNewestFirst() async throws {
        let queue = try demoDatabase()
        let review = try review(queue, month: nil, today: DemoDatabase.defaultAsOf)
        guard let busiest = review.rows(of: .expense).max(by: { abs($0.actualMinorUnits) < abs($1.actualMinorUnits) }) else {
            return XCTFail("no spending")
        }
        let state = MonthTransactionsModel.readNow(queue, row: busiest, range: review.range)
        guard case let .loaded(days) = state else { return XCTFail("not loaded: \(state)") }
        XCTAssertFalse(days.isEmpty)
        XCTAssertEqual(days.map(\.day), days.map(\.day).sorted(by: >))
        XCTAssertEqual(Set(days.map(\.day)).count, days.count)
        for day in days {
            XCTAssertTrue(day.rows.allSatisfy { MonthRange.calendar.startOfDay(for: $0.date) == day.day })
        }
    }

    func testATransactionsAmountTakesItsCategorysRole() {
        XCTAssertEqual(MonthTransactionsModel.amount(-2_499, type: .expense).role, .expense)
        XCTAssertEqual(MonthTransactionsModel.amount(-2_499, type: .expense).minorUnits, 2_499)
        XCTAssertEqual(MoneyPresentation(minorUnits: MonthTransactionsModel.amount(-2_499, type: .expense).minorUnits,
                                         currency: .gbp, role: .expense).text, "\u{2212}£24.99")
        XCTAssertEqual(MonthTransactionsModel.amount(500, type: .expense).minorUnits, -500)  // a refund
        XCTAssertEqual(MonthTransactionsModel.amount(400_000, type: .income).role, .income)
        XCTAssertEqual(MonthTransactionsModel.amount(-30_000, type: .transfer).role, .transfer)
        XCTAssertEqual(MonthTransactionsModel.amount(-30_000, type: .transfer).minorUnits, -30_000)
    }
}
