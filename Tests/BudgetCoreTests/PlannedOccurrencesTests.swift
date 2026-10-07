import XCTest
import GRDB
@testable import BudgetCore

final class PlannedOccurrencesTests: XCTestCase {
    func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }
    func period(_ s: Date, _ e: Date) -> PayPeriod { PayPeriod(startDate: s, endDate: e, type: .projected) }
    var october: PayPeriod { period(utc(2026, 10, 1), utc(2026, 10, 31)) }
    func monthly(id: Int64 = 1, category: Int64 = 10, amount: Int = -10000, start: Date? = nil, interval: Int = 1) -> ForecastEntry {
        ForecastEntry(id: id, groupId: 1, categoryId: category, amountMinorUnits: amount, frequency: .monthly, interval: interval, startDate: start ?? utc(2026, 6, 15), endDate: nil, isEnabled: true, status: .manual, note: nil)
    }

    func testOriginalsWithoutExceptions() {
        let r = PlannedOccurrences.occurrences(entries: [monthly()], exceptions: [], in: october)
        XCTAssertEqual(r.map(\.date), [utc(2026, 10, 15)])
        XCTAssertEqual(r[0].amountMinorUnits, -10000)
        XCTAssertFalse(r[0].isException)
    }

    func testSkippedOccurrenceIsRemoved() {
        let ex = PlannedOccurrenceException(entryId: 1, originalDate: utc(2026, 10, 15), isSkipped: true)
        XCTAssertTrue(PlannedOccurrences.occurrences(entries: [monthly()], exceptions: [ex], in: october).isEmpty)
    }

    func testAmountOverride() {
        let ex = PlannedOccurrenceException(entryId: 1, originalDate: utc(2026, 10, 15), amountMinorUnits: -2500)
        let r = PlannedOccurrences.occurrences(entries: [monthly()], exceptions: [ex], in: october)
        XCTAssertEqual(r.map(\.amountMinorUnits), [-2500])
        XCTAssertTrue(r[0].isException)
    }

    func testMovedWithinPeriod() {
        let ex = PlannedOccurrenceException(entryId: 1, originalDate: utc(2026, 10, 15), date: utc(2026, 10, 20))
        let r = PlannedOccurrences.occurrences(entries: [monthly()], exceptions: [ex], in: october)
        XCTAssertEqual(r.map(\.date), [utc(2026, 10, 20)])
        XCTAssertEqual(r[0].originalDate, utc(2026, 10, 15))
    }

    func testMovedIntoPeriodFromPreviousMonth() {
        let ex = PlannedOccurrenceException(entryId: 1, originalDate: utc(2026, 9, 15), date: utc(2026, 10, 2))
        let r = PlannedOccurrences.occurrences(entries: [monthly()], exceptions: [ex], in: october)
        XCTAssertEqual(r.map(\.date), [utc(2026, 10, 2), utc(2026, 10, 15)])
        let sept = PlannedOccurrences.occurrences(entries: [monthly()], exceptions: [ex], in: period(utc(2026, 9, 1), utc(2026, 9, 30)))
        XCTAssertTrue(sept.isEmpty)
    }

    func testMovedOutOfPeriod() {
        let ex = PlannedOccurrenceException(entryId: 1, originalDate: utc(2026, 10, 15), date: utc(2026, 11, 3))
        XCTAssertTrue(PlannedOccurrences.occurrences(entries: [monthly()], exceptions: [ex], in: october).isEmpty)
        let nov = PlannedOccurrences.occurrences(entries: [monthly()], exceptions: [ex], in: period(utc(2026, 11, 1), utc(2026, 11, 30)))
        XCTAssertEqual(nov.map(\.date), [utc(2026, 11, 3), utc(2026, 11, 15)])
    }

    func testMovedInExceptionForNonOccurrenceIsIgnored() {
        let ex = PlannedOccurrenceException(entryId: 1, originalDate: utc(2026, 9, 16), date: utc(2026, 10, 2))
        XCTAssertEqual(PlannedOccurrences.occurrences(entries: [monthly()], exceptions: [ex], in: october).map(\.date), [utc(2026, 10, 15)])
    }

    func testRefiledCategory() {
        let ex = PlannedOccurrenceException(entryId: 1, originalDate: utc(2026, 10, 15), categoryId: 20)
        let r = PlannedOccurrences.occurrences(entries: [monthly()], exceptions: [ex], in: october)
        XCTAssertEqual(r.map(\.categoryId), [20])
    }

    func testWeeklyMonthlyIntervalAnnual() {
        let weekly = ForecastEntry(id: 1, groupId: 1, categoryId: 10, amountMinorUnits: -100, frequency: .weekly, interval: 1, startDate: utc(2026, 10, 1), endDate: nil, isEnabled: true, status: .manual, note: nil)
        XCTAssertEqual(PlannedOccurrences.occurrences(entries: [weekly], exceptions: [], in: october).count, 5)
        let skipSecond = PlannedOccurrenceException(entryId: 1, originalDate: utc(2026, 10, 8), isSkipped: true)
        XCTAssertEqual(PlannedOccurrences.occurrences(entries: [weekly], exceptions: [skipSecond], in: october).count, 4)
        let biMonthly = monthly(start: utc(2026, 8, 15), interval: 2)
        XCTAssertEqual(PlannedOccurrences.occurrences(entries: [biMonthly], exceptions: [], in: october).map(\.date), [utc(2026, 10, 15)])
        XCTAssertTrue(PlannedOccurrences.occurrences(entries: [biMonthly], exceptions: [], in: period(utc(2026, 9, 1), utc(2026, 9, 30))).isEmpty)
        let annual = ForecastEntry(id: 1, groupId: 1, categoryId: 10, amountMinorUnits: -9900, frequency: .annually, interval: 1, startDate: utc(2025, 10, 9), endDate: nil, isEnabled: true, status: .manual, note: nil)
        let override = PlannedOccurrenceException(entryId: 1, originalDate: utc(2026, 10, 9), amountMinorUnits: -12000)
        XCTAssertEqual(PlannedOccurrences.occurrences(entries: [annual], exceptions: [override], in: october).map(\.amountMinorUnits), [-12000])
    }

    func testMigrationTurnsAutoIntoManual() throws {
        let m = try DatabaseManager(path: nil)
        try m.migrate(upTo: "createPayMonthClose")
        try m.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO category (id, name, type) VALUES (1, 'Rent', 'expense')")
            try db.execute(sql: "INSERT INTO forecastGroup (id, name, isEnabled, isSystemManaged) VALUES (1, 'G', 1, 1)")
            try db.execute(sql: "INSERT INTO forecastEntry (groupId, categoryId, amountMinorUnits, frequency, interval, startDate, isEnabled, status) VALUES (1, 1, -100, 'monthly', 1, '2026-01-01 00:00:00.000', 1, 'auto'), (1, 1, -200, 'monthly', 1, '2026-01-01 00:00:00.000', 1, 'confirmed')")
        }
        try m.migrate()
        try m.dbQueue.read { db in
            let statuses = try ForecastEntry.order(Column("amountMinorUnits").desc).fetchAll(db).map(\.status)
            XCTAssertEqual(statuses, [.manual, .confirmed])
        }
    }

    func testExceptionsCascadeWithEntryAndAreUnique() throws {
        let m = try DatabaseManager(path: nil)
        try m.migrate()
        try m.dbQueue.write { db in
            var cat = Category(name: "Rent", type: .expense); try cat.insert(db)
            var g = ForecastGroup(name: "G", note: nil, isEnabled: true, isSystemManaged: false); try g.insert(db)
            var e = monthly(); e.id = nil; e.groupId = g.id!; e.categoryId = cat.id!; try e.insert(db)
            var ex = PlannedOccurrenceException(entryId: e.id!, originalDate: utc(2026, 10, 15), isSkipped: true); try ex.insert(db)
            var dup = PlannedOccurrenceException(entryId: e.id!, originalDate: utc(2026, 10, 15), amountMinorUnits: 1)
            XCTAssertThrowsError(try dup.insert(db))
            XCTAssertEqual(try PlannedOccurrenceException.fetchCount(db), 1)
            _ = try e.delete(db)
            XCTAssertEqual(try PlannedOccurrenceException.fetchCount(db), 0)
        }
    }

    func testFarMoveSeenFromBothMonths() {
        let ex = PlannedOccurrenceException(entryId: 1, originalDate: utc(2026, 10, 15), date: utc(2027, 2, 10))
        XCTAssertTrue(PlannedOccurrences.occurrences(entries: [monthly()], exceptions: [ex], in: october).isEmpty)
        let feb = PlannedOccurrences.occurrences(entries: [monthly()], exceptions: [ex], in: period(utc(2027, 2, 1), utc(2027, 2, 28)))
        XCTAssertEqual(feb.map(\.date), [utc(2027, 2, 10), utc(2027, 2, 15)])
    }

    func testBackwardMoveOutOfOctober() {
        let ex = PlannedOccurrenceException(entryId: 1, originalDate: utc(2026, 10, 15), date: utc(2026, 9, 28))
        XCTAssertTrue(PlannedOccurrences.occurrences(entries: [monthly()], exceptions: [ex], in: october).isEmpty)
        let sept = PlannedOccurrences.occurrences(entries: [monthly()], exceptions: [ex], in: period(utc(2026, 9, 1), utc(2026, 9, 30)))
        XCTAssertEqual(sept.map(\.date), [utc(2026, 9, 15), utc(2026, 9, 28)])
    }

    func testDeletingReserveNullsRefiledExceptionCategory() throws {
        let m = try DatabaseManager(path: nil)
        try m.migrate()
        try m.dbQueue.write { db in
            var cat = Category(name: "Rent", type: .expense); try cat.insert(db)
            let reserve = try ReservedCategories.create(db: db, name: "Fun")
            let group = try ReservedCategories.ensureGroup(db: db)
            var e = monthly(); e.id = nil; e.groupId = group.id!; e.categoryId = cat.id!; try e.insert(db)
            var ex = PlannedOccurrenceException(entryId: e.id!, originalDate: utc(2026, 10, 15), categoryId: reserve.id!); try ex.insert(db)
            try ReservedCategories.delete(db: db, categoryId: reserve.id!)
            XCTAssertNil(try PlannedOccurrenceException.fetchOne(db, key: ex.id!)?.categoryId)
        }
    }
}
