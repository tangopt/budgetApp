import XCTest
import GRDB
@testable import BudgetCore
import BudgetDemo
@testable import MangoUI

/// Step 10 Task 15: Calendar: the agenda is the Mac's obligations grouped by month, the grid places them on their days, a
/// tapped day narrows the list, Upcoming and Past switch, and nothing here writes. Demo data.
@MainActor
final class PadCalendarModelTests: XCTestCase {
    private var db: DatabaseQueue!
    private let today = DemoDatabase.defaultAsOf

    override func setUp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pad-calendar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("demo.sqlite").path
        try DemoDatabase.build(at: path, evidenceRoot: folder.appendingPathComponent("Evidence"))
        db = try DatabaseQueue(path: path)
    }

    private func model() async -> PadCalendarModel {
        let today = today
        let property = PadPropertyModel(dbQueue: db, today: { today })
        await property.reload()
        let model = PadCalendarModel(property: property, dbQueue: db, today: { today })
        await model.reload()
        return model
    }

    func testAgendaIsTheMacsObligationsByMonth() async throws {
        let model = await model()
        let propertyId = try XCTUnwrap(model.property.property?.id)
        let day = MonthRange.calendar.startOfDay(for: today)
        let end = MonthRange.calendar.date(byAdding: .month, value: 12, to: day)!
        let macs = try await db.read { db in try PropertyCalendar.obligations(db: db, propertyId: propertyId, from: day, to: end, today: day) }
        XCTAssertFalse(macs.isEmpty)
        XCTAssertEqual(model.agenda.flatMap(\.obligations), macs.sorted { ($0.date, $0.id) < ($1.date, $1.id) })
        XCTAssertEqual(model.agenda.map(\.start), model.agenda.map(\.start).sorted())
        XCTAssertLessThanOrEqual(model.agenda.count, 13, "twelve months from a day in the month touch thirteen")
        // The month grid places every one of them on its day.
        model.shownMonth = try XCTUnwrap(model.agenda.first?.start)
        let placed = model.gridDays.flatMap(\.items)
        XCTAssertTrue(model.agenda[0].obligations.allSatisfy { item in placed.contains(item) })
    }

    func testTappingADayNarrowsTheAgendaAndTapAgainLiftsIt() async throws {
        let model = await model()
        let month = try XCTUnwrap(model.agenda.first)
        model.shownMonth = month.start
        let target = try XCTUnwrap(model.gridDays.first { !$0.items.isEmpty && $0.isInMonth })
        model.tap(target)
        XCTAssertEqual(model.selectedDay, target.date)
        XCTAssertEqual(model.agenda.flatMap(\.obligations), target.items)
        XCTAssertEqual(model.shownMonthItems, target.items)
        if target.items.count == 1 { XCTAssertEqual(model.selected, target.items[0]) }
        model.tap(target)
        XCTAssertNil(model.selectedDay)
        XCTAssertGreaterThan(model.agenda.flatMap(\.obligations).count, target.items.count - 1)
    }

    func testPastRangeListsEarlierObligationsNearestFirst() async throws {
        let model = await model()
        model.range = .past
        let past = model.agenda
        XCTAssertEqual(past.map(\.start), past.map(\.start).sorted(by: >))
        XCTAssertTrue(past.flatMap(\.obligations).allSatisfy { $0.date < MonthRange.calendar.startOfDay(for: today) })
        model.range = .upcoming
        XCTAssertTrue(model.agenda.flatMap(\.obligations).allSatisfy { $0.date >= MonthRange.calendar.startOfDay(for: today) })
    }

    func testSelectedObligationCardWordsAndMonthPaging() async throws {
        let model = await model()
        let first = try XCTUnwrap(model.snapshot.upcoming.first)
        model.select(first)
        XCTAssertEqual(model.selected, first)
        XCTAssertFalse(PadCalendarModel.explanation(first).isEmpty)
        XCTAssertFalse(PadCalendarModel.kindName(first.kind).isEmpty)
        model.closeCard()
        XCTAssertNil(model.selected)
        let start = model.shownMonth
        model.shiftMonth(by: 1)
        XCTAssertEqual(MonthRange.calendar.date(byAdding: .month, value: 1, to: start), model.shownMonth)
        model.showToday()
        XCTAssertEqual(model.shownMonth, start)
        XCTAssertEqual(PadCalendarModel.kindName(.ukSelfAssessmentJanuary), "Tax deadline")
    }
}
