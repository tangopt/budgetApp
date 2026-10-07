import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category

/// Scenario operations (spec 2026-10-08-scenario-lab-design.md, "Operations"): create /
/// duplicate / rename / delete, scenario-aware editing and its change markers, refresh, and
/// the differences list.
final class ScenariosTests: XCTestCase {
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
        var categories: [String: Int64] = [:]
        var entries: [String: Int64] = [:]
        var plannedGroupId: Int64 = 0
        var oldGroupId: Int64 = 0
        var accountId: Int64 = 0
    }

    /// Budget: rent (28 Feb 2026, anchored on the 31st, note, skip-less exception on 31 Dec),
    /// salary (25th, confirmed), gym (disabled entry), groceries (in a disabled group), car
    /// (from 15 Nov 2026) and phone (from 10 Nov 2026).
    private func fixture() throws -> Fixture {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        var f = Fixture(manager: manager)
        try manager.dbQueue.write { db in
            for (name, type) in [("Rent", CategoryType.expense), ("Salary", .income), ("Gym", .expense), ("Groceries", .expense), ("Car", .expense), ("Phone", .expense)] {
                var c = Category(name: name, type: type)
                try c.insert(db)
                f.categories[name] = c.id!
            }
            var planned = ForecastGroup(name: "Planned", note: nil, isEnabled: true, isSystemManaged: false)
            try planned.insert(db)
            var old = ForecastGroup(name: "Old", note: nil, isEnabled: false, isSystemManaged: false)
            try old.insert(db)
            f.plannedGroupId = planned.id!
            f.oldGroupId = old.id!
            func add(_ key: String, group: Int64, amount: Int, start: Date, status: ForecastEntryStatus = .manual, enabled: Bool = true, note: String? = nil, anchorDay: Int? = nil) throws {
                var e = ForecastEntry(groupId: group, categoryId: f.categories[key]!, amountMinorUnits: amount, frequency: .monthly, interval: 1, startDate: start, endDate: nil, isEnabled: enabled, status: status, note: note, anchorDay: anchorDay)
                try e.insert(db)
                f.entries[key] = e.id!
            }
            try add("Rent", group: planned.id!, amount: -100_000, start: utc(2026, 2, 28), note: "flat", anchorDay: 31)
            try add("Salary", group: planned.id!, amount: 300_000, start: utc(2026, 1, 25), status: .confirmed)
            try add("Gym", group: planned.id!, amount: -5_000, start: utc(2026, 1, 1), enabled: false)
            try add("Groceries", group: old.id!, amount: -20_000, start: utc(2026, 1, 1))
            try add("Car", group: planned.id!, amount: -30_000, start: utc(2026, 11, 15))
            try add("Phone", group: planned.id!, amount: -2_000, start: utc(2026, 11, 10))
            var ex = PlannedOccurrenceException(entryId: f.entries["Rent"]!, originalDate: utc(2026, 12, 31), amountMinorUnits: -110_000)
            try ex.insert(db)
            var account = Account(name: "Current", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            f.accountId = account.id!
        }
        return f
    }

    private func create(_ f: Fixture, _ name: String = "Move house") throws -> Scenario {
        try f.manager.dbQueue.write { db in try Scenarios.create(db: db, name: name, now: self.utc(2026, 10, 5)) }
    }

    private func scenarioEntries(_ f: Fixture, _ id: Int64) throws -> [ForecastEntry] {
        try f.manager.dbQueue.read { db in try ForecastEntry.inScenario(db, id: id) }
    }

    /// The scenario copy of the budget entry `key`.
    private func copy(_ f: Fixture, _ scenario: Scenario, _ key: String) throws -> ForecastEntry {
        try XCTUnwrap(try scenarioEntries(f, scenario.id!).first { $0.sourceEntryId == f.entries[key] })
    }

    private func budgetSnapshot(_ f: Fixture) throws -> ([ForecastEntry], [PlannedOccurrenceException]) {
        try f.manager.dbQueue.read { db in
            let entries = try ForecastEntry.budget(db)
            let ids = entries.compactMap(\.id)
            let exceptions = try PlannedOccurrenceException.filter(ids.contains(Column("entryId"))).order(Column("id")).fetchAll(db)
            return (entries, exceptions)
        }
    }

    private func exceptions(_ f: Fixture, entryId: Int64) throws -> [PlannedOccurrenceException] {
        try f.manager.dbQueue.read { db in try PlannedOccurrenceException.filter(Column("entryId") == entryId).order(Column("originalDate")).fetchAll(db) }
    }

    private func editOccurrence(_ f: Fixture, _ entryId: Int64, _ original: Date, _ change: OccurrenceChange) throws {
        try f.manager.dbQueue.write { db in
            try PlannedItemEditing.editOccurrence(db: db, entryId: entryId, originalDate: original, change: change, calendar: self.calendar)
        }
    }

    private func editFollowing(_ f: Fixture, _ entryId: Int64, _ original: Date, _ change: OccurrenceChange) throws {
        try f.manager.dbQueue.write { db in
            try PlannedItemEditing.editFollowing(db: db, entryId: entryId, originalDate: original, change: change, calendar: self.calendar)
        }
    }

    private func spend(_ f: Fixture, _ amount: Int, on date: Date, category: Int64) throws {
        try f.manager.dbQueue.write { db in
            var batch = ImportBatch(accountId: f.accountId, sourceFileName: "x.csv", importedAt: Date())
            try batch.insert(db)
            var t = Transaction(importBatchId: batch.id!, accountId: f.accountId, date: date, rawDescription: "RENT", amountMinorUnits: amount, categoryId: category, status: .confirmed, categorizedBy: .manual, fingerprint: UUID().uuidString)
            try t.insert(db)
        }
    }

    private func expectError(_ expected: PlannedItemEditError, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? PlannedItemEditError, expected, file: file, line: line)
        }
    }

    /// The fields a copy must keep from its source.
    private func assertSameValues(_ a: ForecastEntry, _ b: ForecastEntry, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.groupId, b.groupId, file: file, line: line)
        XCTAssertEqual(a.categoryId, b.categoryId, file: file, line: line)
        XCTAssertEqual(a.amountMinorUnits, b.amountMinorUnits, file: file, line: line)
        XCTAssertEqual(a.frequency, b.frequency, file: file, line: line)
        XCTAssertEqual(a.interval, b.interval, file: file, line: line)
        XCTAssertEqual(a.startDate, b.startDate, file: file, line: line)
        XCTAssertEqual(a.endDate, b.endDate, file: file, line: line)
        XCTAssertEqual(a.isEnabled, b.isEnabled, file: file, line: line)
        XCTAssertEqual(a.status, b.status, file: file, line: line)
        XCTAssertEqual(a.note, b.note, file: file, line: line)
        XCTAssertEqual(a.anchorDay, b.anchorDay, file: file, line: line)
    }

    // MARK: - Create, duplicate, rename, delete

    func testCreateCopiesEveryBudgetEntryAndItsExceptions() throws {
        let f = try fixture()
        let before = try budgetSnapshot(f)
        let scenario = try create(f)
        XCTAssertEqual(scenario.name, "Move house")
        XCTAssertEqual(scenario.createdAt, utc(2026, 10, 5))
        XCTAssertNil(scenario.refreshedAt)

        let copies = try scenarioEntries(f, scenario.id!)
        XCTAssertEqual(copies.count, before.0.count) // disabled entry and disabled group's entry included
        for source in before.0 {
            let copy = try XCTUnwrap(copies.first { $0.sourceEntryId == source.id })
            XCTAssertNotEqual(copy.id, source.id)
            XCTAssertEqual(copy.scenarioId, scenario.id)
            XCTAssertNil(copy.scenarioChange)
            assertSameValues(copy, source)
        }
        let rentCopy = try copy(f, scenario, "Rent")
        XCTAssertEqual(rentCopy.anchorDay, 31)
        XCTAssertEqual(rentCopy.note, "flat")
        let copiedExceptions = try exceptions(f, entryId: rentCopy.id!)
        XCTAssertEqual(copiedExceptions.count, 1)
        XCTAssertEqual(copiedExceptions.first?.originalDate, utc(2026, 12, 31))
        XCTAssertEqual(copiedExceptions.first?.amountMinorUnits, -110_000)

        // The budget is untouched.
        let after = try budgetSnapshot(f)
        XCTAssertEqual(after.0, before.0)
        XCTAssertEqual(after.1, before.1)
    }

    func testCreateRejectsBlankAndDuplicateNames() throws {
        let f = try fixture()
        _ = try create(f, "Plan A")
        XCTAssertThrowsError(try create(f, "  ")) { XCTAssertEqual($0 as? ScenarioError, .emptyName) }
        XCTAssertThrowsError(try create(f, " Plan A ")) { XCTAssertEqual($0 as? ScenarioError, .duplicateName) }
    }

    func testDuplicateCopiesEntriesMarkersAndExceptions() throws {
        let f = try fixture()
        let scenario = try create(f)
        let rentCopy = try copy(f, scenario, "Rent")
        try editOccurrence(f, rentCopy.id!, utc(2026, 10, 31), OccurrenceChange(amountMinorUnits: -120_000))
        let added = try f.manager.dbQueue.write { db in
            try PlannedItems.add(db: db, categoryId: f.categories["Car"]!, amountMinorUnits: -1_000, frequency: .once, interval: 1, startDate: self.utc(2026, 12, 1), endDate: nil, scenarioId: scenario.id)
        }

        let dup = try f.manager.dbQueue.write { db in try Scenarios.duplicate(db: db, scenarioId: scenario.id!, name: "Move house 2", now: self.utc(2026, 10, 6)) }
        XCTAssertEqual(dup.name, "Move house 2")
        let originals = try scenarioEntries(f, scenario.id!)
        let copies = try scenarioEntries(f, dup.id!)
        XCTAssertEqual(copies.count, originals.count)
        for (original, copy) in zip(originals, copies) {
            XCTAssertEqual(copy.scenarioId, dup.id)
            XCTAssertEqual(copy.sourceEntryId, original.sourceEntryId)
            XCTAssertEqual(copy.scenarioChange, original.scenarioChange)
            assertSameValues(copy, original)
            let a = try exceptions(f, entryId: original.id!)
            let b = try exceptions(f, entryId: copy.id!)
            XCTAssertEqual(a.map(\.originalDate), b.map(\.originalDate))
            XCTAssertEqual(a.map(\.amountMinorUnits), b.map(\.amountMinorUnits))
            XCTAssertEqual(a.map(\.isSkipped), b.map(\.isSkipped))
        }
        XCTAssertEqual(copies.first { $0.sourceEntryId == f.entries["Rent"] }?.scenarioChange, .changed)
        XCTAssertEqual(copies.filter { $0.scenarioChange == .added }.map(\.amountMinorUnits), [added.amountMinorUnits])
        XCTAssertEqual(try exceptions(f, entryId: copies.first { $0.sourceEntryId == f.entries["Rent"] }!.id!).count, 2)
    }

    func testRenameAndDelete() throws {
        let f = try fixture()
        let a = try create(f, "A")
        _ = try create(f, "B")
        try f.manager.dbQueue.write { db in try Scenarios.rename(db: db, scenarioId: a.id!, to: " C ") }
        XCTAssertEqual(try f.manager.dbQueue.read { db in try Scenario.fetchOne(db, key: a.id!)?.name }, "C")
        XCTAssertThrowsError(try f.manager.dbQueue.write { db in try Scenarios.rename(db: db, scenarioId: a.id!, to: "B") }) {
            XCTAssertEqual($0 as? ScenarioError, .duplicateName)
        }
        let rentCopyId = try copy(f, a, "Rent").id!
        try f.manager.dbQueue.write { db in try Scenarios.delete(db: db, scenarioId: a.id!) }
        try f.manager.dbQueue.read { db in
            XCTAssertNil(try Scenario.fetchOne(db, key: a.id!))
            XCTAssertNil(try ForecastEntry.fetchOne(db, key: rentCopyId))
            XCTAssertEqual(try PlannedOccurrenceException.filter(Column("entryId") == rentCopyId).fetchCount(db), 0)
            XCTAssertEqual(try ForecastEntry.budget(db).count, 6)
        }
    }

    // MARK: - Scenario-aware editing

    func testEditOccurrenceOnACopyMarksItChangedAndLeavesTheBudgetAlone() throws {
        let f = try fixture()
        let scenario = try create(f)
        let before = try budgetSnapshot(f)
        let rentCopy = try copy(f, scenario, "Rent")
        try editOccurrence(f, rentCopy.id!, utc(2026, 10, 31), OccurrenceChange(amountMinorUnits: -120_000))
        XCTAssertEqual(try copy(f, scenario, "Rent").scenarioChange, .changed)
        XCTAssertEqual(try exceptions(f, entryId: rentCopy.id!).map(\.originalDate), [utc(2026, 10, 31), utc(2026, 12, 31)])
        let after = try budgetSnapshot(f)
        XCTAssertEqual(after.0, before.0)
        XCTAssertEqual(after.1, before.1)
    }

    func testBudgetEditsLeaveScenarioCopiesAlone() throws {
        let f = try fixture()
        let scenario = try create(f)
        let copiesBefore = try scenarioEntries(f, scenario.id!)
        let rentCopy = try copy(f, scenario, "Rent")
        try editOccurrence(f, f.entries["Rent"]!, utc(2026, 10, 31), OccurrenceChange(amountMinorUnits: -120_000))
        try editFollowing(f, f.entries["Rent"]!, utc(2026, 11, 30), OccurrenceChange(amountMinorUnits: -130_000))
        try editFollowing(f, f.entries["Car"]!, utc(2026, 11, 15), OccurrenceChange(remove: true))
        XCTAssertEqual(try scenarioEntries(f, scenario.id!), copiesBefore)
        XCTAssertEqual(try exceptions(f, entryId: rentCopy.id!).map(\.originalDate), [utc(2026, 12, 31)])
        // Budget entries never get scenario markers.
        XCTAssertTrue(try budgetSnapshot(f).0.allSatisfy { $0.scenarioChange == nil && $0.scenarioId == nil })
    }

    func testEditOccurrenceOnAnAddedEntryKeepsItAdded() throws {
        let f = try fixture()
        let scenario = try create(f)
        let added = try f.manager.dbQueue.write { db in
            try PlannedItems.add(db: db, categoryId: f.categories["Gym"]!, amountMinorUnits: -4_000, frequency: .monthly, interval: 1, startDate: self.utc(2026, 11, 1), endDate: nil, scenarioId: scenario.id)
        }
        try editOccurrence(f, added.id!, utc(2026, 12, 1), OccurrenceChange(amountMinorUnits: -4_500))
        let stored = try f.manager.dbQueue.read { db in try ForecastEntry.fetchOne(db, key: added.id!) }
        XCTAssertEqual(stored?.scenarioChange, .added)
    }

    func testSplitInAScenarioMarksTheOriginalChangedAndTheNewEntryAdded() throws {
        let f = try fixture()
        let scenario = try create(f)
        let before = try budgetSnapshot(f)
        let rentCopy = try copy(f, scenario, "Rent")
        try editFollowing(f, rentCopy.id!, utc(2026, 11, 30), OccurrenceChange(amountMinorUnits: -120_000))

        let entries = try scenarioEntries(f, scenario.id!)
        let original = try XCTUnwrap(entries.first { $0.id == rentCopy.id })
        XCTAssertEqual(original.scenarioChange, .changed)
        XCTAssertEqual(original.endDate, utc(2026, 11, 29))
        let new = try XCTUnwrap(entries.first { $0.id! > rentCopy.id! && $0.categoryId == f.categories["Rent"] })
        XCTAssertEqual(new.scenarioId, scenario.id)
        XCTAssertEqual(new.scenarioChange, .added)
        XCTAssertNil(new.sourceEntryId)
        XCTAssertEqual(new.amountMinorUnits, -120_000)
        XCTAssertEqual(new.anchorDay, 31)
        XCTAssertEqual(try exceptions(f, entryId: new.id!).map(\.originalDate), [utc(2026, 12, 31)])
        let after = try budgetSnapshot(f)
        XCTAssertEqual(after.0, before.0)
        XCTAssertEqual(after.1, before.1)
    }

    func testEditFollowingAtACopysFirstOccurrenceKeepsItsSource() throws {
        let f = try fixture()
        let scenario = try create(f)
        let carCopy = try copy(f, scenario, "Car")
        try editFollowing(f, carCopy.id!, utc(2026, 11, 15), OccurrenceChange(amountMinorUnits: -35_000))
        let cars = try scenarioEntries(f, scenario.id!).filter { $0.categoryId == f.categories["Car"] }
        XCTAssertEqual(cars.count, 1)
        XCTAssertNotEqual(cars.first?.id, carCopy.id)
        XCTAssertEqual(cars.first?.sourceEntryId, f.entries["Car"])
        XCTAssertEqual(cars.first?.scenarioChange, .changed)
        XCTAssertEqual(cars.first?.amountMinorUnits, -35_000)
    }

    func testRemoveFromACopysFirstOccurrenceLeavesATombstone() throws {
        let f = try fixture()
        let scenario = try create(f)
        let carCopy = try copy(f, scenario, "Car")
        try editFollowing(f, carCopy.id!, utc(2026, 11, 15), OccurrenceChange(remove: true))
        let tombstone = try copy(f, scenario, "Car")
        XCTAssertEqual(tombstone.id, carCopy.id)
        XCTAssertEqual(tombstone.scenarioChange, .removed)
        XCTAssertFalse(tombstone.isEnabled)
        XCTAssertEqual(tombstone.amountMinorUnits, -30_000)
        try f.manager.dbQueue.read { db in
            // Category flags belong to the budget: a scenario never sets them.
            XCTAssertEqual(try Category.fetchOne(db, key: f.categories["Car"]!)?.excludeFromAutoForecast, false)
            XCTAssertNotNil(try ForecastEntry.fetchOne(db, key: f.entries["Car"]!))
        }
        // A tombstone isn't a planned item: it can't be edited.
        expectError(.notFound) { try self.editOccurrence(f, carCopy.id!, self.utc(2026, 12, 15), OccurrenceChange(amountMinorUnits: -1)) }
    }

    func testRemoveFromAnAddedEntrysFirstOccurrenceDeletesIt() throws {
        let f = try fixture()
        let scenario = try create(f)
        let added = try f.manager.dbQueue.write { db in
            try PlannedItems.add(db: db, categoryId: f.categories["Gym"]!, amountMinorUnits: -4_000, frequency: .monthly, interval: 1, startDate: self.utc(2026, 11, 1), endDate: nil, scenarioId: scenario.id)
        }
        try editFollowing(f, added.id!, utc(2026, 11, 1), OccurrenceChange(remove: true))
        try f.manager.dbQueue.read { db in
            XCTAssertNil(try ForecastEntry.fetchOne(db, key: added.id!))
            XCTAssertEqual(try Category.fetchOne(db, key: f.categories["Gym"]!)?.excludeFromAutoForecast, false)
        }
    }

    func testScenarioEditsIgnoreActualsButNotClosedMonths() throws {
        let f = try fixture()
        let scenario = try create(f)
        try spend(f, -100_000, on: utc(2026, 10, 5), category: f.categories["Rent"]!)
        // The budget's October rent is covered by actuals: confirmed.
        expectError(.occurrenceConfirmed) { try self.editOccurrence(f, f.entries["Rent"]!, self.utc(2026, 10, 31), OccurrenceChange(amountMinorUnits: -1)) }
        // A scenario has no confirmation restriction for open months.
        let rentCopy = try copy(f, scenario, "Rent")
        try editOccurrence(f, rentCopy.id!, utc(2026, 10, 31), OccurrenceChange(amountMinorUnits: -120_000))
        // Closed months stay closed.
        expectError(.occurrenceConfirmed) { try self.editOccurrence(f, rentCopy.id!, self.utc(2026, 9, 30), OccurrenceChange(amountMinorUnits: -1)) }
        expectError(.occurrenceConfirmed) { try self.editFollowing(f, rentCopy.id!, self.utc(2026, 9, 30), OccurrenceChange(amountMinorUnits: -1)) }
    }

    func testCopiesInADisabledGroupOrDisabledAreNotEditable() throws {
        let f = try fixture()
        let scenario = try create(f)
        let groceries = try copy(f, scenario, "Groceries")
        let gym = try copy(f, scenario, "Gym")
        expectError(.notFound) { try self.editOccurrence(f, groceries.id!, self.utc(2026, 11, 1), OccurrenceChange(amountMinorUnits: -1)) }
        expectError(.notFound) { try self.editOccurrence(f, gym.id!, self.utc(2026, 11, 1), OccurrenceChange(amountMinorUnits: -1)) }
    }

    func testAddInAScenarioCreatesAnAddedEntryWithoutTouchingTheBudget() throws {
        let f = try fixture()
        let scenario = try create(f)
        let before = try budgetSnapshot(f)
        let entry = try f.manager.dbQueue.write { db in
            try PlannedItems.add(db: db, categoryId: f.categories["Gym"]!, amountMinorUnits: -4_000, frequency: .monthly, interval: 1, startDate: self.utc(2026, 11, 1), endDate: nil, scenarioId: scenario.id)
        }
        XCTAssertEqual(entry.scenarioId, scenario.id)
        XCTAssertEqual(entry.scenarioChange, .added)
        XCTAssertNil(entry.sourceEntryId)
        let (category, newEntry) = try f.manager.dbQueue.write { db in
            try PlannedItems.add(db: db, newCategoryName: "Boat", type: .expense, amountMinorUnits: -9_000, frequency: .monthly, interval: 1, startDate: self.utc(2026, 11, 1), endDate: nil, scenarioId: scenario.id)
        }
        XCTAssertEqual(newEntry.scenarioId, scenario.id)
        XCTAssertEqual(newEntry.scenarioChange, .added)
        try f.manager.dbQueue.read { db in
            XCTAssertEqual(try Category.fetchOne(db, key: f.categories["Gym"]!)?.excludeFromAutoForecast, false)
            XCTAssertEqual(try Category.fetchOne(db, key: category.id!)?.excludeFromAutoForecast, false)
        }
        XCTAssertEqual(try budgetSnapshot(f).0, before.0)
    }

    // MARK: - Refresh

    func testRefreshRecopiesTheBudgetAndReappliesChanges() throws {
        let f = try fixture()
        let scenario = try create(f)
        // Scenario changes.
        let rentCopy = try copy(f, scenario, "Rent")
        try editOccurrence(f, rentCopy.id!, utc(2026, 10, 31), OccurrenceChange(amountMinorUnits: -120_000)) // changed, source stays
        let carCopy = try copy(f, scenario, "Car")
        try editOccurrence(f, carCopy.id!, utc(2026, 12, 15), OccurrenceChange(amountMinorUnits: -31_000)) // changed, source goes
        let phoneCopy = try copy(f, scenario, "Phone")
        try editFollowing(f, phoneCopy.id!, utc(2026, 11, 10), OccurrenceChange(remove: true)) // removed, source stays
        let gymCopy = try copy(f, scenario, "Gym")
        try f.manager.dbQueue.write { db in // removed, source goes
            try db.execute(sql: "UPDATE forecastEntry SET scenarioChange = 'removed' WHERE id = ?", arguments: [gymCopy.id!])
        }
        let added = try f.manager.dbQueue.write { db in
            try PlannedItems.add(db: db, categoryId: f.categories["Groceries"]!, amountMinorUnits: -1_000, frequency: .once, interval: 1, startDate: self.utc(2026, 12, 1), endDate: nil, scenarioId: scenario.id)
        }
        let oldSalaryCopy = try copy(f, scenario, "Salary")

        // Budget changes since the copy.
        var phoneNumber: Int64 = 0
        try f.manager.dbQueue.write { db in
            try db.execute(sql: "UPDATE forecastEntry SET amountMinorUnits = 310000 WHERE id = ?", arguments: [f.entries["Salary"]!])
            try db.execute(sql: "UPDATE forecastEntry SET amountMinorUnits = -105000 WHERE id = ?", arguments: [f.entries["Rent"]!])
            var ex = PlannedOccurrenceException(entryId: f.entries["Salary"]!, originalDate: self.utc(2026, 12, 25), isSkipped: true)
            try ex.insert(db)
            _ = try ForecastEntry.deleteOne(db, key: f.entries["Car"]!)
            _ = try ForecastEntry.deleteOne(db, key: f.entries["Gym"]!)
            var fresh = ForecastEntry(groupId: f.plannedGroupId, categoryId: f.categories["Phone"]!, amountMinorUnits: -2_500, frequency: .monthly, interval: 1, startDate: self.utc(2027, 1, 10), endDate: nil, isEnabled: true, status: .manual, note: nil)
            try fresh.insert(db)
            phoneNumber = fresh.id!
        }

        let report = try f.manager.dbQueue.write { db in try Scenarios.refresh(db: db, scenarioId: scenario.id!, now: self.utc(2026, 10, 7)) }
        XCTAssertEqual(report.reapplied, ["Rent", "Phone"])
        XCTAssertEqual(report.couldNotReapply, ["Gym: couldn't reapply: source no longer in the budget",
                                                "Car: couldn't reapply: source no longer in the budget"])

        let entries = try scenarioEntries(f, scenario.id!)
        // Changed / removed with a live source: kept as they were, no fresh copy beside them.
        XCTAssertEqual(entries.filter { $0.sourceEntryId == f.entries["Rent"] }.map(\.id), [rentCopy.id])
        XCTAssertEqual(entries.first { $0.id == rentCopy.id }?.amountMinorUnits, -100_000)
        XCTAssertEqual(entries.filter { $0.sourceEntryId == f.entries["Phone"] }.map(\.scenarioChange), [.removed])
        // Changed with its source gone: kept as added. Removed with its source gone: dropped.
        let car = try XCTUnwrap(entries.first { $0.id == carCopy.id })
        XCTAssertEqual(car.scenarioChange, .added)
        XCTAssertNil(car.sourceEntryId)
        XCTAssertNil(entries.first { $0.id == gymCopy.id })
        // Added entries are kept.
        XCTAssertEqual(entries.first { $0.id == added.id }?.scenarioChange, .added)
        // Unchanged copies re-copied from today's budget, exceptions included.
        XCTAssertNil(entries.first { $0.id == oldSalaryCopy.id })
        let salary = try XCTUnwrap(entries.first { $0.sourceEntryId == f.entries["Salary"] })
        XCTAssertNil(salary.scenarioChange)
        XCTAssertEqual(salary.amountMinorUnits, 310_000)
        XCTAssertEqual(try exceptions(f, entryId: salary.id!).map(\.isSkipped), [true])
        XCTAssertEqual(entries.filter { $0.sourceEntryId == phoneNumber }.count, 1)
        XCTAssertEqual(entries.filter { $0.sourceEntryId == f.entries["Groceries"] }.count, 1)
        XCTAssertEqual(entries.count, 7) // rent, car, phone tombstone, added, salary, groceries, new phone

        let refreshed = try f.manager.dbQueue.read { db in try Scenario.fetchOne(db, key: scenario.id!) }
        XCTAssertEqual(refreshed?.refreshedAt, utc(2026, 10, 7))
    }

    // MARK: - Differences

    func testDifferencesDescribeEachChange() throws {
        let f = try fixture()
        let scenario = try create(f)
        let rentCopy = try copy(f, scenario, "Rent")
        try editFollowing(f, rentCopy.id!, utc(2026, 11, 30), OccurrenceChange(amountMinorUnits: -120_000))
        let salaryCopy = try copy(f, scenario, "Salary")
        try editOccurrence(f, salaryCopy.id!, utc(2026, 10, 25), OccurrenceChange(amountMinorUnits: 350_000))
        let carCopy = try copy(f, scenario, "Car")
        try editFollowing(f, carCopy.id!, utc(2026, 11, 15), OccurrenceChange(amountMinorUnits: -35_000, categoryId: f.categories["Phone"]!, interval: 2))
        let phoneCopy = try copy(f, scenario, "Phone")
        try editFollowing(f, phoneCopy.id!, utc(2026, 11, 10), OccurrenceChange(remove: true))
        _ = try f.manager.dbQueue.write { db in
            try PlannedItems.add(db: db, categoryId: f.categories["Salary"]!, amountMinorUnits: 100_000, frequency: .once, interval: 1, startDate: self.utc(2026, 12, 20), endDate: nil, scenarioId: scenario.id)
        }

        let differences = try f.manager.dbQueue.read { db in try Scenarios.differences(db: db, scenarioId: scenario.id!) }
        XCTAssertEqual(differences.map(\.kind), [.changed, .changed, .removed, .added, .changed, .added])
        XCTAssertEqual(differences.map(\.categoryName), ["Rent", "Salary", "Phone", "Rent", "Phone", "Salary"])
        XCTAssertEqual(differences[0].id, rentCopy.id)
        XCTAssertEqual(differences[0].summary, "-£1,000.00 monthly from 28 Feb 2026 until 29 Nov 2026")
        XCTAssertEqual(differences[0].fieldChanges, ["End: none → 29 Nov 2026"])
        XCTAssertEqual(differences[1].fieldChanges, ["1 occurrence edited"])
        XCTAssertEqual(differences[2].summary, "-£20.00 monthly from 10 Nov 2026")
        XCTAssertEqual(differences[2].fieldChanges, [])
        XCTAssertEqual(differences[3].summary, "-£1,200.00 monthly from 30 Nov 2026")
        XCTAssertEqual(differences[4].fieldChanges, ["Amount: -£300.00 → -£350.00", "Frequency: monthly → every 2 months", "Category: Car → Phone"])
        XCTAssertEqual(differences[5].summary, "£1,000.00 once on 20 Dec 2026")
        // Unchanged copies (and disabled ones) aren't differences.
        XCTAssertFalse(differences.contains { $0.categoryName == "Gym" || $0.categoryName == "Groceries" })
    }

    // MARK: - Fix round 1

    func testScenarioAddIntoADisabledPlannedGroupThrowsAndLeavesTheBudgetAlone() throws {
        let f = try fixture()
        let scenario = try create(f)
        try f.manager.dbQueue.write { db in
            try db.execute(sql: "UPDATE forecastGroup SET isEnabled = 0 WHERE id = ?", arguments: [f.plannedGroupId])
        }
        let before = try budgetSnapshot(f)
        let totalBefore = try budgetNovemberTotal(f)
        XCTAssertThrowsError(try f.manager.dbQueue.write { db in
            try PlannedItems.add(db: db, categoryId: f.categories["Gym"]!, amountMinorUnits: -4_000, frequency: .monthly, interval: 1, startDate: self.utc(2026, 11, 1), endDate: nil, scenarioId: scenario.id)
        }) { XCTAssertEqual($0 as? PlannedItemsError, .plannedGroupDisabled) }
        try f.manager.dbQueue.read { db in
            XCTAssertEqual(try ForecastGroup.fetchOne(db, key: f.plannedGroupId)?.isEnabled, false)
        }
        XCTAssertEqual(try budgetSnapshot(f).0, before.0)
        XCTAssertEqual(try budgetNovemberTotal(f), totalBefore)
    }

    func testScenarioAddCreatesAMissingPlannedGroup() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in
            var gym = Category(name: "Gym", type: .expense)
            try gym.insert(db)
            let scenario = try Scenarios.create(db: db, name: "S")
            let entry = try PlannedItems.add(db: db, categoryId: gym.id!, amountMinorUnits: -4_000, frequency: .monthly, interval: 1, startDate: self.utc(2026, 11, 1), endDate: nil, scenarioId: scenario.id)
            let group = try XCTUnwrap(ForecastGroup.fetchOne(db, key: entry.groupId))
            XCTAssertEqual(group.name, PlannedItems.groupName)
            XCTAssertTrue(group.isEnabled)
        }
    }

    private func budgetNovemberTotal(_ f: Fixture) throws -> Int {
        try f.manager.dbQueue.read { db in
            let range = MonthRange.of(year: 2026, month: 11)
            return ForecastCalculator.confirmedTotalsByCategory(period: PayPeriod(startDate: range.start, endDate: range.end, type: .projected),
                                                               entries: try ForecastEntry.budget(db), groups: try ForecastGroup.fetchAll(db),
                                                               exceptions: try PlannedOccurrenceException.fetchAll(db)).values.reduce(0, +)
        }
    }

    func testRefreshReportsChangesWhoseSourceWasSplitInTheBudget() throws {
        let f = try fixture()
        let scenario = try create(f)
        let rentCopy = try copy(f, scenario, "Rent")
        try editOccurrence(f, rentCopy.id!, utc(2026, 10, 31), OccurrenceChange(amountMinorUnits: -120_000))
        let salaryCopy = try copy(f, scenario, "Salary")
        try editOccurrence(f, salaryCopy.id!, utc(2026, 10, 25), OccurrenceChange(amountMinorUnits: 320_000))
        // The budget splits rent from 30 Nov: its source now ends 29 Nov with a successor.
        try editFollowing(f, f.entries["Rent"]!, utc(2026, 11, 30), OccurrenceChange(amountMinorUnits: -130_000))

        let report = try f.manager.dbQueue.write { db in try Scenarios.refresh(db: db, scenarioId: scenario.id!, now: self.utc(2026, 10, 7)) }
        XCTAssertEqual(report.reapplied, ["Rent", "Salary"])
        XCTAssertEqual(report.sourceChanged, ["Rent"])
        XCTAssertEqual(report.couldNotReapply, [])
    }

    func testRefreshKeepsAChangedEntrysOwnExceptions() throws {
        let f = try fixture()
        let scenario = try create(f)
        let rentCopy = try copy(f, scenario, "Rent")
        try editOccurrence(f, rentCopy.id!, utc(2026, 10, 31), OccurrenceChange(amountMinorUnits: -120_000))
        try f.manager.dbQueue.write { db in // the budget's own exception changes meanwhile
            try db.execute(sql: "DELETE FROM plannedOccurrenceException WHERE entryId = ?", arguments: [f.entries["Rent"]!])
        }
        _ = try f.manager.dbQueue.write { db in try Scenarios.refresh(db: db, scenarioId: scenario.id!) }
        let kept = try exceptions(f, entryId: rentCopy.id!)
        XCTAssertEqual(kept.map(\.originalDate), [utc(2026, 10, 31), utc(2026, 12, 31)])
        XCTAssertEqual(kept.map(\.amountMinorUnits), [-120_000, -110_000])
    }

    func testDifferencesFlagAChangedEntryWhoseSourceIsGone() throws {
        let f = try fixture()
        let scenario = try create(f)
        let carCopy = try copy(f, scenario, "Car")
        try editOccurrence(f, carCopy.id!, utc(2026, 12, 15), OccurrenceChange(amountMinorUnits: -31_000))
        try f.manager.dbQueue.write { db in _ = try ForecastEntry.deleteOne(db, key: f.entries["Car"]!) }
        let differences = try f.manager.dbQueue.read { db in try Scenarios.differences(db: db, scenarioId: scenario.id!) }
        XCTAssertEqual(differences.map(\.id), [carCopy.id!])
        XCTAssertEqual(differences.first?.kind, .changed)
        XCTAssertEqual(differences.first?.fieldChanges, ["Source no longer in the budget"])
    }

    func testRenameAndDeleteOfAnUnknownScenarioThrowNotFound() throws {
        let f = try fixture()
        XCTAssertThrowsError(try f.manager.dbQueue.write { db in try Scenarios.rename(db: db, scenarioId: 999, to: "X") }) {
            XCTAssertEqual($0 as? ScenarioError, .notFound)
        }
        XCTAssertThrowsError(try f.manager.dbQueue.write { db in try Scenarios.delete(db: db, scenarioId: 999) }) {
            XCTAssertEqual($0 as? ScenarioError, .notFound)
        }
    }

    func testRemoveFromAChangedCopysFirstOccurrenceLeavesATombstone() throws {
        let f = try fixture()
        let scenario = try create(f)
        let carCopy = try copy(f, scenario, "Car")
        try editOccurrence(f, carCopy.id!, utc(2026, 12, 15), OccurrenceChange(amountMinorUnits: -31_000))
        XCTAssertEqual(try copy(f, scenario, "Car").scenarioChange, .changed)
        try editFollowing(f, carCopy.id!, utc(2026, 11, 15), OccurrenceChange(remove: true))
        let tombstone = try copy(f, scenario, "Car")
        XCTAssertEqual(tombstone.id, carCopy.id)
        XCTAssertEqual(tombstone.scenarioChange, .removed)
        XCTAssertFalse(tombstone.isEnabled)
    }
}
