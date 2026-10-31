import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category
import BudgetDemo
@testable import MangoUI
import TestSupport

/// Month's view models and the words its rows use (iPhone spec §3.3; plan step 4, Task 8). Figures come from
/// `PayMonthReview` and `TransactionSearch`; these tests pin what Month does with them.
@MainActor
final class MonthTests: XCTestCase {
    nonisolated private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func emptyDatabase() throws -> DatabaseQueue {
        return try TestDatabase.migrated()
    }

    private static var cachedDemo: DatabaseQueue?

    /// The demo, built once for the class (read-only use only).
    private func demoDatabase() throws -> DatabaseQueue {
        if let queue = Self.cachedDemo { return queue }
        let queue = try emptyDatabase()
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("MonthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidence) }
        try TestDatabase.fillDemo(queue, evidenceRoot: evidence)
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
        try TestDatabase.fillDemo(queue, evidenceRoot: evidence)

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
        XCTAssertEqual(CategoryRowPresentation(row(.income, actual: 400_000, plan: 400_000)).status, "On plan")
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

    /// Exactly at plan reads "On plan" whatever the type (ruling, Task 8 fix round 1).
    func testExactlyAtPlanIsOnPlanForEveryType() {
        XCTAssertEqual(CategoryRowPresentation(row(.expense, actual: -40_000, plan: -40_000)).status, "On plan")
        XCTAssertEqual(CategoryRowPresentation(row(.income, actual: 400_000, plan: 400_000)).status, "On plan")
        XCTAssertEqual(CategoryRowPresentation(row(.transfer, actual: -50_000, plan: -50_000)).status, "On plan")
    }

    func testARowReadsItsFiguresToVoiceOver() {
        let shown = CategoryRowPresentation(row(.expense, actual: -32_000, plan: -40_000))
        XCTAssertEqual(shown.spoken, "£320.00 of £400.00 planned, £80.00 left")
    }

    // MARK: A row's transactions

    /// The transactions a row opens add up to the row's actual, for every row of the demo's month.
    func testARowsTransactionsAddUpToItsActual() async throws {
        let queue = try demoDatabase()
        let review = try review(queue, month: nil, today: DemoDatabase.defaultAsOf)
        XCTAssertFalse(review.rows(of: .transfer).isEmpty)
        for row in review.rows {
            let model = MonthTransactionsModel(dbQueue: queue, row: row, range: review.range)
            await model.load()
            guard case let .loaded(days) = model.state else { return XCTFail("\(row.category.name): not loaded") }
            let rows = days.flatMap(\.rows)
            XCTAssertTrue(rows.allSatisfy { $0.transaction.categoryId == row.id })
            XCTAssertTrue(rows.allSatisfy { $0.date >= review.range.start && $0.date <= review.range.end })
            XCTAssertEqual(rows.reduce(0) { $0 + $1.gbpMinorUnits }, row.actualMinorUnits, row.category.name)
        }
    }

    /// Step 6: an iPhone whose iCloud user isn't named yet reads A's Category totals card as one line per row; the
    /// list's transactions and the lines still add up to each row's actual, and the card's own rows aren't listed.
    func testAnUnnamedViewersListAndPrivateLinesAddUpToTheRowsActual() async throws {
        let queue = try demoDatabase()
        let today = DemoDatabase.defaultAsOf
        let viewer = PhoneViewer.iCloudUser(recordName: nil)
        guard case let .loaded(page) = MonthViewModel.readNow(queue, today: today, viewer: viewer) else { return XCTFail("not loaded") }
        let card = try await queue.read { db in
            try XCTUnwrap(Account.filter(Column("name") == DemoSharing.categoryTotalsAccount).fetchOne(db)?.id)
        }
        var lines = 0
        for row in page.review.rows {
            let model = MonthTransactionsModel(dbQueue: queue, row: row, range: page.review.range, viewer: viewer, today: { today })
            await model.load()
            guard case let .loaded(days) = model.state else { return XCTFail("\(row.category.name): not loaded") }
            let rows = days.flatMap(\.rows)
            XCTAssertFalse(rows.contains { $0.transaction.accountId == card }, row.category.name)
            XCTAssertTrue(model.privateLines.allSatisfy { $0.id == card && $0.text.contains("details private") })
            lines += model.privateLines.count
            XCTAssertEqual(rows.reduce(0) { $0 + $1.gbpMinorUnits } + model.privateLines.reduce(0) { $0 + $1.amountMinorUnits },
                           row.actualMinorUnits, row.category.name)
        }
        XCTAssertGreaterThan(lines, 0, "the card has spending in the demo's month")
        // As the demo's admin, nothing is private.
        guard case let .loaded(adminPage) = MonthViewModel.readNow(queue, today: today, viewer: .demoAdmin) else { return XCTFail("not loaded") }
        for row in adminPage.review.rows {
            XCTAssertEqual(MonthTransactionsModel.privateLinesNow(queue, row: row, range: adminPage.review.range, viewer: .demoAdmin, today: today), [])
        }
    }

    /// A pending transaction, a euro one and the incoming leg of a linked transfer: the list is exactly what each
    /// row's figure counts (confirmed, budget-facing, in pounds), for expense, income and transfer rows.
    func testTheListIsExactlyWhatTheFigureCounts() async throws {
        let queue = try emptyDatabase()
        let today = Self.day(2026, 10, 20)
        let ids = try await queue.write { db -> (expense: Int64, income: Int64, transfer: Int64, pending: Int64, euro: Int64, inLeg: Int64) in
            var pounds = Account(name: "Current", currency: .gbp, kind: .cash, trackingMode: .imported)
            try pounds.insert(db)
            var euros = Account(name: "Euro", currency: .eur, kind: .cash, trackingMode: .imported)
            try euros.insert(db)
            var savings = Account(name: "Savings", currency: .gbp, kind: .cash, trackingMode: .imported)
            try savings.insert(db)
            _ = try ExchangeRateSetting(eurToGbpRate: 0.85, updatedAt: today).inserted(db)
            var batch = ImportBatch(accountId: pounds.id!, sourceFileName: "f", importedAt: today)
            try batch.insert(db)
            var expense = Category(name: "Groceries", type: .expense)
            try expense.insert(db)
            var income = Category(name: "Salary", type: .income)
            try income.insert(db)
            var transfer = Category(name: "Savings", type: .transfer)
            try transfer.insert(db)
            func add(_ account: Int64, _ day: Int, _ amount: Int, _ category: Int64, _ status: TransactionStatus = .confirmed) throws -> Int64 {
                var transaction = Transaction(importBatchId: batch.id!, accountId: account, date: Self.day(2026, 10, day),
                                              rawDescription: "ITEM \(day)", amountMinorUnits: amount, categoryId: category,
                                              status: status, categorizedBy: .manual, fingerprint: UUID().uuidString)
                try transaction.insert(db)
                return transaction.id!
            }
            _ = try add(pounds.id!, 3, -4_000, expense.id!)
            let pending = try add(pounds.id!, 4, -9_999, expense.id!, .pendingReview)
            let euro = try add(euros.id!, 5, -10_000, expense.id!)
            _ = try add(pounds.id!, 6, 300_000, income.id!)
            _ = try add(euros.id!, 7, 20_000, income.id!)
            let out = try add(pounds.id!, 8, -50_000, transfer.id!)
            let inLeg = try add(savings.id!, 8, 50_000, transfer.id!)
            var link = TransferLink(outTransactionId: out, inTransactionId: inLeg, origin: .manual)
            try link.insert(db)
            return (expense.id!, income.id!, transfer.id!, pending, euro, inLeg)
        }
        let review = try review(queue, month: nil, today: today)
        for categoryId in [ids.expense, ids.income, ids.transfer] {
            guard let row = review.rows.first(where: { $0.id == categoryId }) else { return XCTFail("no row \(categoryId)") }
            guard case let .loaded(days) = MonthTransactionsModel.readNow(queue, row: row, range: review.range) else {
                return XCTFail("not loaded")
            }
            let rows = days.flatMap(\.rows)
            XCTAssertEqual(rows.reduce(0) { $0 + $1.gbpMinorUnits }, row.actualMinorUnits, row.category.name)
            XCTAssertFalse(rows.contains { $0.id == ids.pending || $0.id == ids.inLeg })
        }
        guard let expense = review.rows.first(where: { $0.id == ids.expense }),
              case let .loaded(days) = MonthTransactionsModel.readNow(queue, row: expense, range: review.range),
              let euro = days.flatMap(\.rows).first(where: { $0.id == ids.euro }) else { return XCTFail("no euro row") }
        XCTAssertEqual(expense.actualMinorUnits, -4_000 - 8_500)
        XCTAssertEqual(euro.gbpMinorUnits, -8_500)
        XCTAssertEqual(euro.originalMinorUnits, -10_000)
        XCTAssertEqual(MonthTransactionsModel.secondary(euro), "Euro \u{00B7} \u{2212}€100.00")
    }

    /// A sync reloads a pushed list in place with its row's new figures.
    func testASyncRefreshesAPushedListInPlace() async throws {
        let queue = try demoDatabase()
        let model = MonthViewModel(dbQueue: queue, today: { DemoDatabase.defaultAsOf })
        await model.reload(for: Self.day(2026, 10, 1))
        guard case let .loaded(page) = model.state, let row = page.rows(.spending).first else { return XCTFail("not loaded") }
        let destination = MonthRowDestination(row: row, range: page.review.range)
        let list = model.transactionsModel(for: destination)
        await list.load()
        await model.reload(for: Self.day(2026, 10, 2))
        XCTAssertTrue(model.transactionsModel(for: destination) === list)
        guard case .loaded = list.state else { return XCTFail("the list was reset: \(list.state)") }
        XCTAssertEqual(list.row, row)
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

    func testTheCategoryDetailSummaryReadsAsTheRowDoes() {
        let under = CategorySummaryPresentation(row(.expense, actual: -32_000, plan: -40_000)).figures
        XCTAssertEqual(under.map(\.label), ["Spent", "Planned", "Left"])
        XCTAssertEqual(under.map(\.text), ["£320.00", "£400.00", "£80.00"])
        let over = CategorySummaryPresentation(row(.expense, actual: -45_000, plan: -40_000)).figures
        XCTAssertEqual(over.map(\.label), ["Spent", "Planned", "Over"])
        XCTAssertEqual(over.last?.text, "£50.00")
        XCTAssertEqual(over.last?.isOver, true)
        let income = CategorySummaryPresentation(row(.income, actual: 100_000, plan: 400_000)).figures
        XCTAssertEqual(income.map(\.label), ["Received", "Planned", "To come"])
        XCTAssertEqual(income.last?.text, "£3,000.00")
        // No plan and no measure: only what was spent and the (empty) plan.
        XCTAssertEqual(CategorySummaryPresentation(row(.income, actual: 100_000, plan: 0)).figures.count, 2)
    }
}
