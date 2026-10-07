import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category

/// Apply to budget, with undo (spec 2026-10-08-scenario-lab-design.md, "Apply to budget,
/// with undo").
final class ScenarioApplyTests: XCTestCase {
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// August, September and October closed (salary on 31 Aug, 30 Sep, 31 Oct); November is
    /// the current pay month (open, started), so the apply boundary is 1 Nov 2026.
    private var calendar: PayCalendar {
        PayCalendar(salaryDates: [utc(2026, 8, 31), utc(2026, 9, 30), utc(2026, 10, 31)], manualCloses: [], today: utc(2026, 11, 5))
    }

    private struct Fixture {
        let manager: DatabaseManager
        var categories: [String: Int64] = [:]
        var entries: [String: Int64] = [:]
        var plannedGroupId: Int64 = 0
        var reservedGroupId: Int64 = 0
        var accountId: Int64 = 0
        var scenarioId: Int64 = 0
    }

    /// Budget: rent (-1,000 from 28 Feb 2026, anchored on the 31st, note "flat"), gym (-50 from
    /// 1 Jan) and car (-300 from 15 Dec 2026, not started yet). A scenario copies it, then:
    /// rent changed to -1,200 with exceptions on 31 Oct (closed), 30 Nov and 31 Dec; gym and
    /// car removed; phone added (-20 from 10 Dec); streaming added (-10 from 15 Jun 2026,
    /// before the boundary; its 15 Nov moved into October, its 15 Dec at -15); a holiday
    /// reserve added (-200 from 1 Dec).
    private func fixture() throws -> Fixture {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        var f = Fixture(manager: manager)
        try manager.dbQueue.write { db in
            for (name, type) in [("Rent", CategoryType.expense), ("Gym", .expense), ("Car", .expense), ("Phone", .expense), ("Streaming", .expense)] {
                var c = Category(name: name, type: type)
                try c.insert(db)
                f.categories[name] = c.id!
            }
            var holiday = Category(name: "Holiday", type: .expense, isReserved: true)
            try holiday.insert(db)
            f.categories["Holiday"] = holiday.id!
            var planned = ForecastGroup(name: "Planned", note: nil, isEnabled: true, isSystemManaged: false)
            try planned.insert(db)
            f.plannedGroupId = planned.id!
            f.reservedGroupId = try ReservedCategories.ensureGroup(db: db).id!

            func add(_ key: String, amount: Int, start: Date, note: String? = nil, anchorDay: Int? = nil) throws {
                var e = ForecastEntry(groupId: planned.id!, categoryId: f.categories[key]!, amountMinorUnits: amount, frequency: .monthly, interval: 1, startDate: start, endDate: nil, isEnabled: true, status: .manual, note: note, anchorDay: anchorDay)
                try e.insert(db)
                f.entries[key] = e.id!
            }
            try add("Rent", amount: -100_000, start: utc(2026, 2, 28), note: "flat", anchorDay: 31)
            try add("Gym", amount: -5_000, start: utc(2026, 1, 1))
            try add("Car", amount: -30_000, start: utc(2026, 12, 15))
            var account = Account(name: "Current", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            f.accountId = account.id!

            let scenario = try Scenarios.create(db: db, name: "Move", now: utc(2026, 11, 1))
            f.scenarioId = scenario.id!
            let copies = try ForecastEntry.inScenario(db, id: scenario.id!)
            func copy(_ key: String) -> ForecastEntry { copies.first { $0.sourceEntryId == f.entries[key] }! }

            var rent = copy("Rent")
            rent.amountMinorUnits = -120_000
            rent.scenarioChange = .changed
            try rent.update(db)
            for (date, amount) in [(utc(2026, 10, 31), -105_000), (utc(2026, 11, 30), -125_000), (utc(2026, 12, 31), -130_000)] {
                var ex = PlannedOccurrenceException(entryId: rent.id!, originalDate: date, amountMinorUnits: amount)
                try ex.insert(db)
            }
            for key in ["Gym", "Car"] {
                var removed = copy(key)
                removed.isEnabled = false
                removed.scenarioChange = .removed
                try removed.update(db)
            }
            try PlannedItems.add(db: db, categoryId: f.categories["Phone"]!, amountMinorUnits: -2_000, frequency: .monthly, interval: 1, startDate: utc(2026, 12, 10), endDate: nil, scenarioId: scenario.id)
            let streaming = try PlannedItems.add(db: db, categoryId: f.categories["Streaming"]!, amountMinorUnits: -1_000, frequency: .monthly, interval: 1, startDate: utc(2026, 6, 15), endDate: nil, scenarioId: scenario.id)
            // 15 Nov moved back into closed October (confirmed in the budget); 15 Dec re-priced.
            var moved = PlannedOccurrenceException(entryId: streaming.id!, originalDate: utc(2026, 11, 15), date: utc(2026, 10, 25))
            try moved.insert(db)
            var repriced = PlannedOccurrenceException(entryId: streaming.id!, originalDate: utc(2026, 12, 15), amountMinorUnits: -1_500)
            try repriced.insert(db)
            var reserve = ForecastEntry(groupId: f.reservedGroupId, categoryId: holiday.id!, amountMinorUnits: -20_000, frequency: .monthly, interval: 1, startDate: utc(2026, 12, 1), endDate: nil, isEnabled: true, status: .confirmed, note: nil, scenarioId: scenario.id, scenarioChange: .added)
            try reserve.insert(db)
        }
        return f
    }

    // MARK: - Helpers

    /// The scenario's difference id (= scenario entry id) for `category`.
    private func difference(_ f: Fixture, _ category: String) throws -> Int64 {
        let differences = try f.manager.dbQueue.read { db in try Scenarios.differences(db: db, scenarioId: f.scenarioId) }
        return try XCTUnwrap(differences.first { $0.categoryName == category }).id
    }

    @discardableResult
    private func apply(_ f: Fixture, _ categories: [String]) throws -> ScenarioApplication {
        let ids = try categories.map { try difference(f, $0) }
        return try f.manager.dbQueue.write { db in
            try ScenarioApply.apply(db: db, scenarioId: f.scenarioId, differenceIds: ids, calendar: self.calendar, now: self.utc(2026, 11, 5))
        }
    }

    private func undo(_ f: Fixture) throws -> UndoReport {
        try f.manager.dbQueue.write { db in try ScenarioApply.undoLast(db: db, scenarioId: f.scenarioId, now: self.utc(2026, 11, 6)) }
    }

    private func canUndo(_ f: Fixture) throws -> Bool {
        try f.manager.dbQueue.read { db in try ScenarioApply.canUndo(db: db, scenarioId: f.scenarioId) }
    }

    private func budget(_ f: Fixture) throws -> [ForecastEntry] {
        try f.manager.dbQueue.read { db in try ForecastEntry.budget(db) }
    }

    private func budgetEntry(_ f: Fixture, _ key: String) throws -> ForecastEntry {
        try XCTUnwrap(try budget(f).first { $0.id == f.entries[key] })
    }

    /// Budget entries created by the apply (not one of the fixture's own).
    private func created(_ f: Fixture, _ category: String) throws -> [ForecastEntry] {
        let own = Set(f.entries.values)
        return try budget(f).filter { !own.contains($0.id!) && $0.categoryId == f.categories[category] }
    }

    private func exceptions(_ f: Fixture, entryId: Int64) throws -> [PlannedOccurrenceException] {
        try f.manager.dbQueue.read { db in try PlannedOccurrenceException.filter(Column("entryId") == entryId).order(Column("originalDate")).fetchAll(db) }
    }

    private func occurrences(_ entry: ForecastEntry, _ from: Date, _ to: Date) -> [Date] {
        FrequencyExpander.occurrences(for: entry, in: PayPeriod(startDate: from, endDate: to, type: .projected))
    }

    private func spend(_ f: Fixture, _ amount: Int, on date: Date, category: String) throws {
        try f.manager.dbQueue.write { db in
            var batch = ImportBatch(accountId: f.accountId, sourceFileName: "x.csv", importedAt: Date())
            try batch.insert(db)
            var t = Transaction(importBatchId: batch.id!, accountId: f.accountId, date: date, rawDescription: "T", amountMinorUnits: amount, categoryId: f.categories[category]!, status: .confirmed, categorizedBy: .manual, fingerprint: UUID().uuidString)
            try t.insert(db)
        }
    }

    private struct State: Equatable {
        let entries: [ForecastEntry]
        let exceptions: [PlannedOccurrenceException]
        let groups: [ForecastGroup]
    }

    private func state(_ f: Fixture) throws -> State {
        try f.manager.dbQueue.read { db in
            State(entries: try ForecastEntry.order(Column("id")).fetchAll(db),
                  exceptions: try PlannedOccurrenceException.order(Column("id")).fetchAll(db),
                  groups: try ForecastGroup.order(Column("id")).fetchAll(db))
        }
    }

    // MARK: - Apply

    func testApplyChangedEndsTheSourceAndStartsTheScenarioValuesFromTheCurrentMonthKeepingTheAnchor() throws {
        let f = try fixture()
        try apply(f, ["Rent"])

        let source = try budgetEntry(f, "Rent")
        XCTAssertEqual(source.endDate, utc(2026, 10, 31)) // the end of the month before the current pay month
        XCTAssertTrue(source.isEnabled)
        XCTAssertEqual(source.amountMinorUnits, -100_000)

        let new = try XCTUnwrap(try created(f, "Rent").first)
        XCTAssertEqual(try created(f, "Rent").count, 1)
        XCTAssertNil(new.scenarioId)
        XCTAssertNil(new.scenarioChange)
        XCTAssertNil(new.sourceEntryId)
        XCTAssertEqual(new.amountMinorUnits, -120_000)
        XCTAssertEqual(new.status, .manual)
        XCTAssertEqual(new.groupId, f.plannedGroupId)
        XCTAssertEqual(new.note, "flat")
        XCTAssertTrue(new.isEnabled)
        XCTAssertEqual(new.startDate, utc(2026, 11, 30)) // first occurrence on/after 1 Nov
        // The 31st anchor is kept past the short month.
        XCTAssertEqual(occurrences(new, utc(2026, 11, 1), utc(2027, 3, 31)),
                       [utc(2026, 11, 30), utc(2026, 12, 31), utc(2027, 1, 31), utc(2027, 2, 28), utc(2027, 3, 31)])
    }

    func testApplyCopiesLaterExceptionsAndSkipsOnesTheBudgetHasConfirmed() throws {
        let f = try fixture()
        let application = try apply(f, ["Streaming"])

        let new = try XCTUnwrap(try created(f, "Streaming").first)
        let copied = try exceptions(f, entryId: new.id!)
        // 15 Nov's edit lands in closed October, so the budget treats it as confirmed.
        XCTAssertEqual(copied.map(\.originalDate), [utc(2026, 12, 15)])
        XCTAssertEqual(copied.first?.amountMinorUnits, -1_500)
        XCTAssertEqual(application.skipped, ["Streaming: the 15 Nov 2026 edit wasn't applied (already confirmed in the budget)"])
    }

    func testApplyChangedWhoseCurrentMonthIsConfirmedAppliesFromTheNextMonth() throws {
        let f = try fixture()
        // November's rent is already paid in full against the budget's -1,000 plan.
        try spend(f, -100_000, on: utc(2026, 11, 2), category: "Rent")
        let application = try apply(f, ["Rent"])

        XCTAssertEqual(try budgetEntry(f, "Rent").endDate, utc(2026, 11, 30))
        let new = try XCTUnwrap(try created(f, "Rent").first)
        XCTAssertEqual(new.startDate, utc(2026, 12, 31))
        XCTAssertEqual(new.amountMinorUnits, -120_000)
        XCTAssertEqual(try exceptions(f, entryId: new.id!).map(\.originalDate), [utc(2026, 12, 31)])
        XCTAssertEqual(application.skipped, ["Rent: Nov 2026 is already confirmed in the budget; the change applies from Dec 2026"])

        _ = try undo(f)
        XCTAssertNil(try budgetEntry(f, "Rent").endDate)
        XCTAssertEqual(try created(f, "Rent"), [])
    }

    func testApplyCopiesAnUnconfirmedCurrentMonthException() throws {
        let f = try fixture()
        let application = try apply(f, ["Rent"])
        let new = try XCTUnwrap(try created(f, "Rent").first)
        XCTAssertEqual(try exceptions(f, entryId: new.id!).map(\.originalDate), [utc(2026, 11, 30), utc(2026, 12, 31)])
        XCTAssertEqual(application.skipped, [])
    }

    func testApplyRemovedEndsTheSourceOrDisablesOneNotYetStarted() throws {
        let f = try fixture()
        try apply(f, ["Gym", "Car"])

        let gym = try budgetEntry(f, "Gym")
        XCTAssertEqual(gym.endDate, utc(2026, 10, 31))
        XCTAssertTrue(gym.isEnabled)
        let car = try budgetEntry(f, "Car")
        XCTAssertFalse(car.isEnabled)
        XCTAssertNil(car.endDate)
        XCTAssertEqual(try created(f, "Gym"), [])
        XCTAssertEqual(try created(f, "Car"), [])
    }

    func testApplyAddedCreatesAnOrdinaryBudgetEntryInPlannedOrReserved() throws {
        let f = try fixture()
        try apply(f, ["Phone", "Holiday"])

        let phone = try XCTUnwrap(try created(f, "Phone").first)
        XCTAssertEqual(phone.startDate, utc(2026, 12, 10))
        XCTAssertEqual(phone.amountMinorUnits, -2_000)
        XCTAssertEqual(phone.groupId, f.plannedGroupId)
        XCTAssertEqual(phone.status, .manual)
        XCTAssertNil(phone.scenarioId)
        XCTAssertNil(phone.scenarioChange)
        let holiday = try XCTUnwrap(try created(f, "Holiday").first)
        XCTAssertEqual(holiday.groupId, f.reservedGroupId)
        XCTAssertEqual(holiday.amountMinorUnits, -20_000)
    }

    func testApplyAddedStartingBeforeTheCurrentMonthStartsAtItsFirstOccurrenceFromIt() throws {
        let f = try fixture()
        try apply(f, ["Streaming"])
        let streaming = try XCTUnwrap(try created(f, "Streaming").first)
        XCTAssertEqual(streaming.startDate, utc(2026, 11, 15))
    }

    func testApplyOnlyTouchesTheTickedDifferencesAndLeavesTheScenarioAlone() throws {
        let f = try fixture()
        let scenarioBefore = try f.manager.dbQueue.read { db in try ForecastEntry.inScenario(db, id: f.scenarioId) }
        let application = try apply(f, ["Gym"])

        XCTAssertEqual(try budgetEntry(f, "Rent").endDate, nil)
        XCTAssertEqual(try budgetEntry(f, "Car").isEnabled, true)
        XCTAssertEqual(try created(f, "Phone"), [])
        XCTAssertEqual(try f.manager.dbQueue.read { db in try ForecastEntry.inScenario(db, id: f.scenarioId) }, scenarioBefore)

        XCTAssertNotNil(application.id)
        XCTAssertEqual(application.scenarioId, f.scenarioId)
        XCTAssertEqual(application.appliedAt, utc(2026, 11, 5))
        XCTAssertNil(application.undoneAt)
        let stored = try f.manager.dbQueue.read { db in try ScenarioApplication.fetchAll(db) }
        XCTAssertEqual(stored, [application])
        let journal = try XCTUnwrap(application.decodedJournal)
        XCTAssertEqual(journal.operations.count, 1)
        XCTAssertEqual(journal.operations.first?.kind, .removed)
        XCTAssertEqual(journal.operations.first?.modified.first?.entryId, f.entries["Gym"])
        XCTAssertEqual(journal.operations.first?.modified.first?.before, ScenarioApplyJournal.EntryState(endDate: nil, isEnabled: true))
    }

    func testApplyRejectsAnIdThatIsNotADifferenceOfTheScenario() throws {
        let f = try fixture()
        XCTAssertThrowsError(try f.manager.dbQueue.write { db in
            try ScenarioApply.apply(db: db, scenarioId: f.scenarioId, differenceIds: [f.entries["Rent"]!], calendar: self.calendar)
        }) { XCTAssertEqual($0 as? ScenarioApplyError, .notADifference(f.entries["Rent"]!)) }
        XCTAssertEqual(try f.manager.dbQueue.read { db in try ScenarioApplication.fetchCount(db) }, 0)
    }

    func testApplyingADifferenceAgainBeforeUndoingIsSkipped() throws {
        let f = try fixture()
        try apply(f, ["Phone"])
        let again = try apply(f, ["Phone"])
        XCTAssertEqual(try created(f, "Phone").count, 1)
        XCTAssertEqual(again.skipped, ["Phone: already applied"])
        // Nothing applied: nothing recorded.
        XCTAssertNil(again.id)
        XCTAssertTrue(again.appliedNothing)
        XCTAssertEqual(try f.manager.dbQueue.read { db in try ScenarioApplication.fetchCount(db) }, 1)
    }

    func testDuplicateIdsApplyOnce() throws {
        let f = try fixture()
        let id = try difference(f, "Phone")
        let application = try f.manager.dbQueue.write { db in
            try ScenarioApply.apply(db: db, scenarioId: f.scenarioId, differenceIds: [id, id], calendar: self.calendar)
        }
        XCTAssertEqual(try created(f, "Phone").count, 1)
        XCTAssertEqual(application.decodedJournal?.operations.count, 1)
        XCTAssertEqual(application.skipped, [])
    }

    func testAnItemWithNoOccurrenceFromTheBoundaryIsSkippedAndNotRecorded() throws {
        let f = try fixture()
        let once = try f.manager.dbQueue.write { db in
            try PlannedItems.add(db: db, categoryId: f.categories["Car"]!, amountMinorUnits: -50_000, frequency: .once, interval: 1, startDate: self.utc(2026, 6, 1), endDate: nil, scenarioId: f.scenarioId)
        }
        let before = try state(f)
        let application = try f.manager.dbQueue.write { db in
            try ScenarioApply.apply(db: db, scenarioId: f.scenarioId, differenceIds: [once.id!], calendar: self.calendar)
        }
        XCTAssertEqual(application.skipped, ["Car: no occurrence from Nov 2026"])
        XCTAssertTrue(application.appliedNothing)
        XCTAssertNil(application.id)
        XCTAssertEqual(try state(f), before)
        XCTAssertFalse(try canUndo(f))
    }

    func testApplyCreatesMissingGroupsAndUndoRemovesThem() throws {
        // A budget with neither "Planned" nor "Reserved": the scenario's items sit in their own group.
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let (scenarioId, ids) = try manager.dbQueue.write { db -> (Int64, [Int64]) in
            var phone = Category(name: "Phone", type: .expense)
            try phone.insert(db)
            var holiday = Category(name: "Holiday", type: .expense, isReserved: true)
            try holiday.insert(db)
            var other = ForecastGroup(name: "Other", note: nil, isEnabled: true, isSystemManaged: false)
            try other.insert(db)
            let scenario = try Scenarios.create(db: db, name: "S")
            var ids: [Int64] = []
            for (category, amount) in [(phone.id!, -2_000), (holiday.id!, -20_000)] {
                var e = ForecastEntry(groupId: other.id!, categoryId: category, amountMinorUnits: amount, frequency: .monthly, interval: 1, startDate: self.utc(2026, 12, 1), endDate: nil, isEnabled: true, status: .manual, note: nil, scenarioId: scenario.id, scenarioChange: .added)
                try e.insert(db)
                ids.append(e.id!)
            }
            return (scenario.id!, ids)
        }
        func snapshot() throws -> State {
            try manager.dbQueue.read { db in
                State(entries: try ForecastEntry.order(Column("id")).fetchAll(db),
                      exceptions: try PlannedOccurrenceException.order(Column("id")).fetchAll(db),
                      groups: try ForecastGroup.order(Column("id")).fetchAll(db))
            }
        }
        let before = try snapshot()
        let application = try manager.dbQueue.write { db in
            try ScenarioApply.apply(db: db, scenarioId: scenarioId, differenceIds: ids, calendar: self.calendar)
        }
        let groups = try manager.dbQueue.read { db in try ForecastGroup.fetchAll(db) }
        XCTAssertEqual(Set(groups.map(\.name)), ["Other", "Planned", "Reserved"])
        XCTAssertEqual(application.decodedJournal?.createdGroupIds.count, 2)

        _ = try manager.dbQueue.write { db in try ScenarioApply.undoLast(db: db, scenarioId: scenarioId) }
        XCTAssertEqual(try snapshot(), before)
    }

    func testApplyEnablesADisabledReservedGroupAndUndoDisablesIt() throws {
        let f = try fixture()
        try f.manager.dbQueue.write { db in try db.execute(sql: "UPDATE forecastGroup SET isEnabled = 0 WHERE id = ?", arguments: [f.reservedGroupId]) }
        let before = try state(f)
        try apply(f, ["Holiday"])
        XCTAssertEqual(try f.manager.dbQueue.read { db in try ForecastGroup.fetchOne(db, key: f.reservedGroupId)?.isEnabled }, true)
        _ = try undo(f)
        XCTAssertEqual(try state(f), before)
    }

    // MARK: - Undo

    func testUndoRestoresTheBudgetExactly() throws {
        let f = try fixture()
        let before = try state(f)
        XCTAssertFalse(try canUndo(f))
        try apply(f, ["Rent", "Gym", "Car", "Phone", "Streaming", "Holiday"])
        XCTAssertTrue(try canUndo(f))
        XCTAssertNotEqual(try state(f), before)

        let report = try undo(f)
        XCTAssertEqual(try state(f), before)
        XCTAssertEqual(Set(report.restored), ["Rent", "Gym", "Car", "Phone", "Streaming", "Holiday"])
        XCTAssertEqual(report.warnings, [])
        XCTAssertFalse(try canUndo(f))
        let application = try XCTUnwrap(try f.manager.dbQueue.read { db in try ScenarioApplication.fetchOne(db) })
        XCTAssertEqual(application.undoneAt, utc(2026, 11, 6))
    }

    func testUndoRestoresADisabledPlannedGroup() throws {
        let f = try fixture()
        try f.manager.dbQueue.write { db in try db.execute(sql: "UPDATE forecastGroup SET isEnabled = 0 WHERE id = ?", arguments: [f.plannedGroupId]) }
        let before = try state(f)
        try apply(f, ["Phone"])
        XCTAssertEqual(try f.manager.dbQueue.read { db in try ForecastGroup.fetchOne(db, key: f.plannedGroupId)?.isEnabled }, true)
        _ = try undo(f)
        XCTAssertEqual(try state(f), before)
    }

    func testUndoReportsEntriesEditedAfterTheApplyAndStillRestoresThem() throws {
        let f = try fixture()
        try apply(f, ["Rent", "Gym"])
        try f.manager.dbQueue.write { db in
            try db.execute(sql: "UPDATE forecastEntry SET amountMinorUnits = -6000 WHERE id = ?", arguments: [f.entries["Gym"]!])
        }
        let new = try XCTUnwrap(try created(f, "Rent").first)
        try f.manager.dbQueue.write { db in
            var ex = PlannedOccurrenceException(entryId: new.id!, originalDate: self.utc(2027, 1, 31), isSkipped: true)
            try ex.insert(db)
        }

        let report = try undo(f)
        XCTAssertEqual(report.warnings.sorted(), [
            "Gym was edited after applying; restored to before the apply",
            "Rent: the item the apply added was edited since; removed anyway",
        ])
        let gym = try budgetEntry(f, "Gym")
        XCTAssertNil(gym.endDate)
        XCTAssertEqual(gym.amountMinorUnits, -6_000) // only the apply's own change is undone
        XCTAssertNil(try budgetEntry(f, "Rent").endDate)
        XCTAssertEqual(try created(f, "Rent"), [])
    }

    func testUndoReportsEntriesDeletedSinceTheApply() throws {
        let f = try fixture()
        try apply(f, ["Gym", "Phone"])
        let phone = try XCTUnwrap(try created(f, "Phone").first)
        try f.manager.dbQueue.write { db in
            _ = try ForecastEntry.deleteOne(db, key: f.entries["Gym"]!)
            _ = try ForecastEntry.deleteOne(db, key: phone.id!)
        }
        let report = try undo(f)
        XCTAssertEqual(report.warnings.sorted(), [
            "Gym couldn't be restored: it's no longer in the budget",
            "Phone: the item the apply added was already deleted",
        ])
    }

    func testOnlyTheLatestUnundoneApplicationIsUndone() throws {
        let f = try fixture()
        let first = try apply(f, ["Gym"])
        let second = try apply(f, ["Phone"])

        let report = try undo(f)
        XCTAssertEqual(report.restored, ["Phone"])
        XCTAssertEqual(try created(f, "Phone"), [])
        XCTAssertEqual(try budgetEntry(f, "Gym").endDate, utc(2026, 10, 31)) // the first apply stands
        let rows = try f.manager.dbQueue.read { db in try ScenarioApplication.order(Column("id")).fetchAll(db) }
        XCTAssertEqual(rows.map(\.id), [first.id, second.id])
        XCTAssertNil(rows[0].undoneAt)
        XCTAssertNotNil(rows[1].undoneAt)

        XCTAssertTrue(try canUndo(f))
        XCTAssertEqual(try undo(f).restored, ["Gym"])
        XCTAssertNil(try budgetEntry(f, "Gym").endDate)
        XCTAssertFalse(try canUndo(f))
        XCTAssertThrowsError(try undo(f)) { XCTAssertEqual($0 as? ScenarioApplyError, .nothingToUndo) }
    }

    func testApplicationsArePerScenario() throws {
        let f = try fixture()
        try apply(f, ["Gym"])
        let other = try f.manager.dbQueue.write { db in try Scenarios.create(db: db, name: "Other") }
        XCTAssertFalse(try f.manager.dbQueue.read { db in try ScenarioApply.canUndo(db: db, scenarioId: other.id!) })
        XCTAssertTrue(try canUndo(f))
    }
}
