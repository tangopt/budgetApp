import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category

final class PlannedItemEditingTests: XCTestCase {
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// August and September closed (salary on 31 Aug and 30 Sep); October open and started.
    private var calendar: PayCalendar {
        PayCalendar(salaryDates: [utc(2026, 8, 31), utc(2026, 9, 30)], manualCloses: [], today: utc(2026, 10, 5))
    }

    private struct Fixture {
        let manager: DatabaseManager
        let groupId: Int64
        let rentId: Int64
        let groceriesId: Int64
        let entryId: Int64
        let accountId: Int64
    }

    /// Rent, monthly on the 15th from `start`, −£1,000, status `status`, in a "Planned" group.
    private func fixture(start: Date? = nil, status: ForecastEntryStatus = .auto, frequency: ForecastFrequency = .monthly) throws -> Fixture {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        return try manager.dbQueue.write { db in
            var rent = Category(name: "Rent", type: .expense)
            var groceries = Category(name: "Groceries", type: .expense)
            try rent.insert(db); try groceries.insert(db)
            var group = ForecastGroup(name: "Planned", note: nil, isEnabled: true, isSystemManaged: false)
            try group.insert(db)
            var entry = ForecastEntry(groupId: group.id!, categoryId: rent.id!, amountMinorUnits: -100_000, frequency: frequency, interval: 1, startDate: start ?? utc(2026, 8, 15), endDate: nil, isEnabled: true, status: status, note: "flat")
            try entry.insert(db)
            var account = Account(name: "Current", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            return Fixture(manager: manager, groupId: group.id!, rentId: rent.id!, groceriesId: groceries.id!, entryId: entry.id!, accountId: account.id!)
        }
    }

    private func spend(_ f: Fixture, _ amount: Int, on date: Date, category: Int64? = nil) throws {
        try f.manager.dbQueue.write { db in
            var batch = ImportBatch(accountId: f.accountId, sourceFileName: "x.csv", importedAt: Date())
            try batch.insert(db)
            var t = Transaction(importBatchId: batch.id!, accountId: f.accountId, date: date, rawDescription: "RENT", amountMinorUnits: amount, categoryId: category ?? f.rentId, status: .confirmed, categorizedBy: .manual, fingerprint: UUID().uuidString)
            try t.insert(db)
        }
    }

    private func editOccurrence(_ f: Fixture, _ original: Date, _ change: OccurrenceChange) throws {
        try f.manager.dbQueue.write { db in
            try PlannedItemEditing.editOccurrence(db: db, entryId: f.entryId, originalDate: original, change: change, calendar: self.calendar)
        }
    }

    private func editFollowing(_ f: Fixture, _ original: Date, _ change: OccurrenceChange) throws {
        try f.manager.dbQueue.write { db in
            try PlannedItemEditing.editFollowing(db: db, entryId: f.entryId, originalDate: original, change: change, calendar: self.calendar)
        }
    }

    private func exceptions(_ f: Fixture) throws -> [PlannedOccurrenceException] {
        try f.manager.dbQueue.read { db in try PlannedOccurrenceException.order(Column("originalDate")).fetchAll(db) }
    }

    private func entries(_ f: Fixture) throws -> [ForecastEntry] {
        try f.manager.dbQueue.read { db in try ForecastEntry.order(Column("id")).fetchAll(db) }
    }

    private func addException(_ f: Fixture, _ e: PlannedOccurrenceException) throws {
        var e = e
        try f.manager.dbQueue.write { db in try e.insert(db) }
    }

    private func expectError(_ expected: PlannedItemEditError, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? PlannedItemEditError, expected, file: file, line: line)
        }
    }

    // MARK: - Only this occurrence

    func testEditOccurrenceUpsertsAmount() throws {
        let f = try fixture()
        try editOccurrence(f, utc(2026, 10, 15), OccurrenceChange(amountMinorUnits: -120_000))
        try editOccurrence(f, utc(2026, 10, 15), OccurrenceChange(amountMinorUnits: -130_000))
        let ex = try exceptions(f)
        XCTAssertEqual(ex.count, 1)
        XCTAssertEqual(ex[0].entryId, f.entryId)
        XCTAssertEqual(ex[0].originalDate, utc(2026, 10, 15))
        XCTAssertEqual(ex[0].amountMinorUnits, -130_000)
        XCTAssertNil(ex[0].date)
        XCTAssertFalse(ex[0].isSkipped)
    }

    func testEditOccurrenceKeepsEarlierFieldsWhenAddingAnother() throws {
        let f = try fixture()
        try editOccurrence(f, utc(2026, 10, 15), OccurrenceChange(amountMinorUnits: -120_000))
        try editOccurrence(f, utc(2026, 10, 15), OccurrenceChange(date: utc(2026, 10, 20)))
        let ex = try exceptions(f)
        XCTAssertEqual(ex.count, 1)
        XCTAssertEqual(ex[0].amountMinorUnits, -120_000)
        XCTAssertEqual(ex[0].date, utc(2026, 10, 20))
    }

    func testEditOccurrenceDateAndCategory() throws {
        let f = try fixture()
        try editOccurrence(f, utc(2026, 11, 15), OccurrenceChange(date: utc(2026, 12, 2), categoryId: f.groceriesId))
        let ex = try exceptions(f)
        XCTAssertEqual(ex.count, 1)
        XCTAssertEqual(ex[0].date, utc(2026, 12, 2))
        XCTAssertEqual(ex[0].categoryId, f.groceriesId)
    }

    func testEditOccurrenceSkip() throws {
        let f = try fixture()
        try editOccurrence(f, utc(2026, 10, 15), OccurrenceChange(remove: true))
        let ex = try exceptions(f)
        XCTAssertEqual(ex.count, 1)
        XCTAssertTrue(ex[0].isSkipped)
        let october = PayPeriod(startDate: utc(2026, 10, 1), endDate: utc(2026, 10, 31), type: .projected)
        XCTAssertTrue(PlannedOccurrences.occurrences(entries: try entries(f), exceptions: ex, in: october).isEmpty)
    }

    func testEditOccurrenceTurnsAutoIntoManual() throws {
        let f = try fixture(status: .auto)
        try editOccurrence(f, utc(2026, 10, 15), OccurrenceChange(amountMinorUnits: -1))
        XCTAssertEqual(try entries(f)[0].status, .manual)
    }

    func testEditOccurrenceRejectsFrequencyChange() throws {
        let f = try fixture()
        expectError(.frequencyNeedsFollowing) { try editOccurrence(f, utc(2026, 10, 15), OccurrenceChange(frequency: .weekly)) }
        expectError(.frequencyNeedsFollowing) { try editOccurrence(f, utc(2026, 10, 15), OccurrenceChange(interval: 2)) }
        XCTAssertTrue(try exceptions(f).isEmpty)
    }

    func testEditOccurrenceRejectsNonOccurrence() throws {
        let f = try fixture()
        expectError(.notFound) { try editOccurrence(f, utc(2026, 10, 16), OccurrenceChange(amountMinorUnits: -1)) }
        let missing = Fixture(manager: f.manager, groupId: f.groupId, rentId: f.rentId, groceriesId: f.groceriesId, entryId: 999, accountId: f.accountId)
        expectError(.notFound) { try editOccurrence(missing, utc(2026, 10, 15), OccurrenceChange(amountMinorUnits: -1)) }
    }

    func testConfirmedInClosedMonthIsRejected() throws {
        let f = try fixture()
        expectError(.occurrenceConfirmed) { try editOccurrence(f, utc(2026, 9, 15), OccurrenceChange(amountMinorUnits: -1)) }
        expectError(.occurrenceConfirmed) { try editFollowing(f, utc(2026, 9, 15), OccurrenceChange(amountMinorUnits: -1)) }
        XCTAssertTrue(try exceptions(f).isEmpty)
        XCTAssertEqual(try entries(f).count, 1)
        XCTAssertEqual(try entries(f)[0].status, .auto) // rolled back
    }

    func testConfirmedWhenActualsCoverThePlan() throws {
        let f = try fixture()
        try spend(f, -100_000, on: utc(2026, 10, 3))
        expectError(.occurrenceConfirmed) { try editOccurrence(f, utc(2026, 10, 15), OccurrenceChange(amountMinorUnits: -1)) }
        expectError(.occurrenceConfirmed) { try editFollowing(f, utc(2026, 10, 15), OccurrenceChange(amountMinorUnits: -1)) }
    }

    func testPartlyCoveredOccurrenceIsEditable() throws {
        let f = try fixture()
        try spend(f, -40_000, on: utc(2026, 10, 3))
        try editOccurrence(f, utc(2026, 10, 15), OccurrenceChange(amountMinorUnits: -50_000))
        XCTAssertEqual(try exceptions(f).count, 1)
    }

    func testMoveIntoClosedMonthIsInvalid() throws {
        let f = try fixture()
        expectError(.invalidDate) { try editOccurrence(f, utc(2026, 10, 15), OccurrenceChange(date: utc(2026, 9, 20))) }
        expectError(.invalidDate) { try editFollowing(f, utc(2026, 10, 15), OccurrenceChange(date: utc(2026, 9, 20))) }
        XCTAssertTrue(try exceptions(f).isEmpty)
    }

    func testIsConfirmedUsesTheMovedDatesMonthAndRefiledCategory() throws {
        let f = try fixture()
        let entry = try entries(f)[0]
        let groups = try f.manager.dbQueue.read { db in try ForecastGroup.fetchAll(db) }
        let categories = try f.manager.dbQueue.read { db in try Category.fetchAll(db) }
        // Nov 15 occurrence moved into October, re-filed to Groceries; Groceries spent £1,000 in October.
        let ex = PlannedOccurrenceException(entryId: f.entryId, originalDate: utc(2026, 11, 15), date: utc(2026, 10, 25), categoryId: f.groceriesId)
        let occurrence = PlannedOccurrence(entryId: f.entryId, originalDate: utc(2026, 11, 15), date: utc(2026, 10, 25), categoryId: f.groceriesId, amountMinorUnits: -100_000, isException: true)
        let covered: [Int64: [Int: [Int: Int]]] = [f.groceriesId: [2026: [10: -100_000]]]
        XCTAssertTrue(PlannedItemEditing.isConfirmed(entry: entry, occurrence: occurrence, calendar: calendar, monthTotals: covered, entries: [entry], groups: groups, exceptions: [ex], categories: categories))
        let rentCovered: [Int64: [Int: [Int: Int]]] = [f.rentId: [2026: [10: -500_000]]]
        XCTAssertFalse(PlannedItemEditing.isConfirmed(entry: entry, occurrence: occurrence, calendar: calendar, monthTotals: rentCovered, entries: [entry], groups: groups, exceptions: [ex], categories: categories))
        // Moved back into closed September: confirmed.
        let intoSeptember = PlannedOccurrence(entryId: f.entryId, originalDate: utc(2026, 10, 15), date: utc(2026, 9, 28), categoryId: f.rentId, amountMinorUnits: -100_000, isException: true)
        XCTAssertTrue(PlannedItemEditing.isConfirmed(entry: entry, occurrence: intoSeptember, calendar: calendar, monthTotals: [:], entries: [entry], groups: groups, exceptions: [], categories: categories))
    }

    // MARK: - This and all following

    func testFollowingSplitsTheSeries() throws {
        let f = try fixture()
        try addException(f, PlannedOccurrenceException(entryId: f.entryId, originalDate: utc(2026, 10, 15), amountMinorUnits: -90_000))
        try addException(f, PlannedOccurrenceException(entryId: f.entryId, originalDate: utc(2027, 1, 15), date: utc(2027, 1, 20)))
        try editFollowing(f, utc(2026, 11, 15), OccurrenceChange(amountMinorUnits: -110_000, categoryId: f.groceriesId))

        let all = try entries(f)
        XCTAssertEqual(all.count, 2)
        let original = all[0], new = all[1]
        XCTAssertEqual(original.endDate, utc(2026, 11, 14))
        XCTAssertEqual(original.status, .manual)
        XCTAssertEqual(new.groupId, f.groupId)
        XCTAssertEqual(new.categoryId, f.groceriesId)
        XCTAssertEqual(new.amountMinorUnits, -110_000)
        XCTAssertEqual(new.frequency, .monthly)
        XCTAssertEqual(new.interval, 1)
        XCTAssertEqual(new.startDate, utc(2026, 11, 15))
        XCTAssertNil(new.endDate)
        XCTAssertEqual(new.status, .manual)
        XCTAssertEqual(new.note, "flat")
        XCTAssertTrue(new.isEnabled)

        let ex = try exceptions(f)
        XCTAssertEqual(ex.count, 2)
        XCTAssertEqual(ex[0].entryId, original.id) // earlier exception stays
        XCTAssertEqual(ex[0].originalDate, utc(2026, 10, 15))
        XCTAssertEqual(ex[1].entryId, new.id)      // later exception moves, same key date
        XCTAssertEqual(ex[1].originalDate, utc(2027, 1, 15))
        XCTAssertEqual(ex[1].date, utc(2027, 1, 20))
    }

    func testFollowingKeepsTheMonthEndAnchorAndExceptionKeys() throws {
        // Rent on the 31st: 31 Oct, 30 Nov, 31 Dec, 31 Jan, 28 Feb, 31 Mar …; split at 28 Feb.
        let f = try fixture(start: utc(2026, 10, 31))
        try addException(f, PlannedOccurrenceException(entryId: f.entryId, originalDate: utc(2027, 3, 31), amountMinorUnits: -5))
        try editFollowing(f, utc(2027, 2, 28), OccurrenceChange(amountMinorUnits: -7))
        let all = try entries(f)
        let new = all[1]
        XCTAssertEqual(all[0].endDate, utc(2027, 2, 27))
        XCTAssertEqual(new.startDate, utc(2027, 2, 28))
        XCTAssertEqual(new.anchorDay, 31)
        let generated = FrequencyExpander.occurrences(for: new, in: PayPeriod(startDate: utc(2027, 2, 1), endDate: utc(2027, 5, 31), type: .projected))
        XCTAssertEqual(generated, [utc(2027, 2, 28), utc(2027, 3, 31), utc(2027, 4, 30), utc(2027, 5, 31)])
        let ex = try exceptions(f)
        XCTAssertEqual(ex.count, 1)
        XCTAssertEqual(ex[0].entryId, new.id)
        XCTAssertEqual(ex[0].originalDate, utc(2027, 3, 31))
    }

    func testFollowingWithoutMonthEndKeepsNoAnchor() throws {
        let f = try fixture()
        try editFollowing(f, utc(2026, 11, 15), OccurrenceChange(amountMinorUnits: -7))
        XCTAssertNil(try entries(f)[1].anchorDay)
    }

    func testFollowingExceptionOnTheEditedOccurrenceKeepsUnchangedFields() throws {
        let f = try fixture()
        try addException(f, PlannedOccurrenceException(entryId: f.entryId, originalDate: utc(2026, 11, 15), amountMinorUnits: -90_000, date: utc(2026, 11, 18)))
        try editFollowing(f, utc(2026, 11, 15), OccurrenceChange(amountMinorUnits: -110_000))
        let new = try entries(f)[1]
        let ex = try exceptions(f)
        XCTAssertEqual(ex.count, 1)
        XCTAssertEqual(ex[0].entryId, new.id)
        XCTAssertEqual(ex[0].originalDate, utc(2026, 11, 15))
        XCTAssertNil(ex[0].amountMinorUnits) // the series amount now applies
        XCTAssertEqual(ex[0].date, utc(2026, 11, 18))
    }

    func testFollowingDateMoveShiftsStartAndDropsLaterExceptions() throws {
        let f = try fixture()
        try addException(f, PlannedOccurrenceException(entryId: f.entryId, originalDate: utc(2026, 12, 15), amountMinorUnits: -1))
        try editFollowing(f, utc(2026, 11, 15), OccurrenceChange(date: utc(2026, 11, 20)))
        let all = try entries(f)
        XCTAssertEqual(all[0].endDate, utc(2026, 11, 14))
        XCTAssertEqual(all[1].startDate, utc(2026, 11, 20))
        XCTAssertNil(all[1].anchorDay) // the moved date's day
        XCTAssertEqual(all[1].amountMinorUnits, -100_000)
        XCTAssertTrue(try exceptions(f).isEmpty)
    }

    func testFollowingFrequencyChange() throws {
        let f = try fixture()
        try addException(f, PlannedOccurrenceException(entryId: f.entryId, originalDate: utc(2026, 12, 15), amountMinorUnits: -1))
        try editFollowing(f, utc(2026, 11, 15), OccurrenceChange(frequency: .weekly, interval: 2))
        let all = try entries(f)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[1].frequency, .weekly)
        XCTAssertEqual(all[1].interval, 2)
        XCTAssertEqual(all[1].startDate, utc(2026, 11, 15))
        XCTAssertTrue(try exceptions(f).isEmpty)
    }

    func testFollowingFromFirstOccurrenceReplacesTheSeries() throws {
        let f = try fixture(start: utc(2026, 10, 15))
        try addException(f, PlannedOccurrenceException(entryId: f.entryId, originalDate: utc(2026, 12, 15), amountMinorUnits: -1))
        try editFollowing(f, utc(2026, 10, 15), OccurrenceChange(amountMinorUnits: -110_000))
        let all = try entries(f)
        XCTAssertEqual(all.count, 1)
        XCTAssertNotEqual(all[0].id, f.entryId)
        XCTAssertEqual(all[0].startDate, utc(2026, 10, 15))
        XCTAssertEqual(all[0].amountMinorUnits, -110_000)
        XCTAssertEqual(all[0].status, .manual)
        let ex = try exceptions(f)
        XCTAssertEqual(ex.count, 1)
        XCTAssertEqual(ex[0].entryId, all[0].id)
        XCTAssertEqual(ex[0].originalDate, utc(2026, 12, 15))
    }

    func testRemoveFollowingEndsTheSeries() throws {
        let f = try fixture()
        try addException(f, PlannedOccurrenceException(entryId: f.entryId, originalDate: utc(2026, 10, 15), amountMinorUnits: -2))
        try addException(f, PlannedOccurrenceException(entryId: f.entryId, originalDate: utc(2026, 12, 15), amountMinorUnits: -1))
        try editFollowing(f, utc(2026, 11, 15), OccurrenceChange(remove: true))
        let all = try entries(f)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].endDate, utc(2026, 11, 14))
        XCTAssertEqual(try exceptions(f).map(\.originalDate), [utc(2026, 10, 15)])
    }

    func testRemoveFollowingFromFirstOccurrenceDeletesTheSeries() throws {
        let f = try fixture(start: utc(2026, 10, 15))
        try addException(f, PlannedOccurrenceException(entryId: f.entryId, originalDate: utc(2026, 12, 15), amountMinorUnits: -1))
        try editFollowing(f, utc(2026, 10, 15), OccurrenceChange(remove: true))
        XCTAssertTrue(try entries(f).isEmpty)
        XCTAssertTrue(try exceptions(f).isEmpty)
    }

    func testRemoveFollowingFromFirstOccurrenceStopsDetectionReAddingIt() throws {
        let f = try fixture(start: utc(2026, 10, 15), status: .manual)
        try editFollowing(f, utc(2026, 10, 15), OccurrenceChange(remove: true))
        try f.manager.dbQueue.read { db in
            XCTAssertTrue(try XCTUnwrap(Category.fetchOne(db, key: f.rentId)).excludeFromAutoForecast)
            XCTAssertFalse(try XCTUnwrap(Category.fetchOne(db, key: f.groceriesId)).excludeFromAutoForecast)
        }
    }

    func testRemoveFollowingLaterOrReplacingLeavesDetectionAlone() throws {
        let ended = try fixture(status: .manual)
        try editFollowing(ended, utc(2026, 11, 15), OccurrenceChange(remove: true))
        let replaced = try fixture(start: utc(2026, 10, 15), status: .manual)
        try editFollowing(replaced, utc(2026, 10, 15), OccurrenceChange(amountMinorUnits: -110_000))
        for f in [ended, replaced] {
            try f.manager.dbQueue.read { db in
                XCTAssertFalse(try XCTUnwrap(Category.fetchOne(db, key: f.rentId)).excludeFromAutoForecast)
            }
        }
    }

    func testFollowingOnOneOffReplacesIt() throws {
        let f = try fixture(start: utc(2026, 11, 3), status: .manual, frequency: .once)
        try editFollowing(f, utc(2026, 11, 3), OccurrenceChange(amountMinorUnits: -5, date: utc(2026, 11, 9)))
        let all = try entries(f)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].frequency, .once)
        XCTAssertEqual(all[0].startDate, utc(2026, 11, 9))
        XCTAssertEqual(all[0].amountMinorUnits, -5)
    }

    // MARK: - Fix round 1

    func testDateMovesStayBetweenNeighbouringOccurrences() throws {
        let f = try fixture()
        expectError(.invalidDate) { try editOccurrence(f, utc(2026, 11, 15), OccurrenceChange(date: utc(2026, 10, 15))) }
        expectError(.invalidDate) { try editOccurrence(f, utc(2026, 11, 15), OccurrenceChange(date: utc(2026, 12, 15))) }
        expectError(.invalidDate) { try editOccurrence(f, utc(2026, 11, 15), OccurrenceChange(date: utc(2027, 1, 2))) }
        expectError(.invalidDate) { try editFollowing(f, utc(2026, 11, 15), OccurrenceChange(date: utc(2026, 10, 15))) }
        XCTAssertTrue(try exceptions(f).isEmpty)
        XCTAssertEqual(try entries(f).count, 1)
        try editOccurrence(f, utc(2026, 11, 15), OccurrenceChange(date: utc(2026, 10, 16)))
        try editOccurrence(f, utc(2026, 12, 15), OccurrenceChange(date: utc(2027, 1, 14)))
        XCTAssertEqual(try exceptions(f).map(\.date), [utc(2026, 10, 16), utc(2027, 1, 14)])
        try editFollowing(f, utc(2027, 2, 15), OccurrenceChange(date: utc(2027, 3, 20))) // past the next is fine for "following"
        XCTAssertEqual(try entries(f).last?.startDate, utc(2027, 3, 20))
    }

    func testValueChangeUnskipsAnOccurrence() throws {
        let f = try fixture()
        try editOccurrence(f, utc(2026, 10, 15), OccurrenceChange(remove: true))
        try editOccurrence(f, utc(2026, 10, 15), OccurrenceChange(amountMinorUnits: -90_000))
        let ex = try exceptions(f)
        XCTAssertEqual(ex.count, 1)
        XCTAssertFalse(ex[0].isSkipped)
        XCTAssertEqual(ex[0].amountMinorUnits, -90_000)
    }

    func testOnlyPlannedItemsCanBeEdited() throws {
        for setup in ["entryDisabled", "groupDisabled", "hypothetical"] {
            let f = try fixture()
            try f.manager.dbQueue.write { db in
                switch setup {
                case "entryDisabled": try db.execute(sql: "UPDATE forecastEntry SET isEnabled = 0")
                case "groupDisabled": try db.execute(sql: "UPDATE forecastGroup SET isEnabled = 0")
                default: try db.execute(sql: "UPDATE forecastEntry SET status = 'hypothetical'")
                }
            }
            expectError(.notFound) { try editOccurrence(f, utc(2026, 10, 15), OccurrenceChange(amountMinorUnits: -1)) }
            expectError(.notFound) { try editFollowing(f, utc(2026, 10, 15), OccurrenceChange(amountMinorUnits: -1)) }
        }
    }

    func testIntervalMustBeAtLeastOne() throws {
        let f = try fixture()
        expectError(.invalidInterval) { try editFollowing(f, utc(2026, 11, 15), OccurrenceChange(interval: 0)) }
        expectError(.invalidInterval) { try editOccurrence(f, utc(2026, 11, 15), OccurrenceChange(interval: 0)) }
        XCTAssertEqual(try entries(f).count, 1)
    }

    // MARK: - Fix round 2

    func testWeeklyToMonthlySplitStartsOnTheSplitDate() throws {
        let f = try fixture(start: utc(2026, 10, 1), frequency: .weekly)
        try addException(f, PlannedOccurrenceException(entryId: f.entryId, originalDate: utc(2026, 10, 15), amountMinorUnits: -5))
        try editFollowing(f, utc(2026, 10, 15), OccurrenceChange(frequency: .monthly))
        let all = try entries(f)
        XCTAssertEqual(all.count, 2)
        let new = all[1]
        XCTAssertNil(new.anchorDay)
        let period = PayPeriod(startDate: utc(2026, 10, 1), endDate: utc(2026, 12, 31), type: .projected)
        XCTAssertEqual(FrequencyExpander.occurrences(for: new, in: period), [utc(2026, 10, 15), utc(2026, 11, 15), utc(2026, 12, 15)])
        XCTAssertEqual(FrequencyExpander.occurrences(for: all[0], in: period), [utc(2026, 10, 1), utc(2026, 10, 8)])
        let ex = try exceptions(f)
        XCTAssertEqual(ex.count, 1) // the edited occurrence's own exception follows the new start
        XCTAssertEqual(ex[0].entryId, new.id)
        XCTAssertEqual(ex[0].originalDate, utc(2026, 10, 15))
        XCTAssertEqual(PlannedOccurrences.occurrences(entries: all, exceptions: ex, in: PayPeriod(startDate: utc(2026, 10, 1), endDate: utc(2026, 10, 31), type: .projected)).map(\.amountMinorUnits), [-100_000, -100_000, -5])
    }

    func testMonthlyToAnnualSplitKeepsTheMonthEndAnchor() throws {
        let f = try fixture(start: utc(2026, 10, 31))
        try editFollowing(f, utc(2027, 2, 28), OccurrenceChange(frequency: .annually))
        let new = try entries(f)[1]
        XCTAssertEqual(new.anchorDay, 31)
        XCTAssertEqual(FrequencyExpander.occurrences(for: new, in: PayPeriod(startDate: utc(2027, 1, 1), endDate: utc(2028, 12, 31), type: .projected)), [utc(2027, 2, 28), utc(2028, 2, 29)])
    }
}
