import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category
import TestSupport

/// Saving a combination as a scenario (spec 2026-10-28-step17-scenario-comparison-design.md).
final class ScenarioCombinedSaveTests: XCTestCase {
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private struct Fixture {
        let manager: DatabaseManager
        var categories: [String: Int64] = [:]
        var entries: [String: Int64] = [:]
        var a: Int64 = 0
        var b: Int64 = 0
    }

    /// Budget: salary, rent, gym. Scenario A: rent raised, gym removed. Scenario B: rent
    /// raised differently (overlap), a car added, salary's 31 Dec occurrence edited.
    private func fixture() throws -> Fixture {
        let manager = try TestDatabase.migratedManager()
        var f = Fixture(manager: manager)
        try manager.dbQueue.write { db in
            for (name, type) in [("Salary", CategoryType.income), ("Rent", .expense), ("Gym", .expense), ("Car", .expense)] {
                var c = Category(name: name, type: type)
                try c.insert(db)
                f.categories[name] = c.id!
            }
            var group = ForecastGroup(name: "Planned", note: nil, isEnabled: true, isSystemManaged: false)
            try group.insert(db)
            for (key, amount, start) in [("Salary", 300_000, utc(2026, 1, 25)), ("Rent", -100_000, utc(2026, 1, 1)), ("Gym", -5_000, utc(2026, 1, 1))] {
                var e = ForecastEntry(groupId: group.id!, categoryId: f.categories[key]!, amountMinorUnits: amount, frequency: .monthly, interval: 1, startDate: start, endDate: nil, isEnabled: true, status: .manual, note: nil)
                try e.insert(db)
                f.entries[key] = e.id!
            }
            let a = try Scenarios.create(db: db, name: "A", now: utc(2026, 10, 5))
            let b = try Scenarios.create(db: db, name: "B", now: utc(2026, 10, 5))
            f.a = a.id!; f.b = b.id!

            var rentA = try XCTUnwrap(try ForecastEntry.inScenario(db, id: a.id!).first { $0.sourceEntryId == f.entries["Rent"] })
            rentA.amountMinorUnits = -120_000; rentA.scenarioChange = .changed
            try rentA.update(db)
            var gymA = try XCTUnwrap(try ForecastEntry.inScenario(db, id: a.id!).first { $0.sourceEntryId == f.entries["Gym"] })
            gymA.isEnabled = false; gymA.scenarioChange = .removed
            try gymA.update(db)

            var rentB = try XCTUnwrap(try ForecastEntry.inScenario(db, id: b.id!).first { $0.sourceEntryId == f.entries["Rent"] })
            rentB.amountMinorUnits = -150_000; rentB.scenarioChange = .changed
            try rentB.update(db)
            let car = try PlannedItems.add(db: db, categoryId: f.categories["Car"]!, amountMinorUnits: -30_000, frequency: .monthly, interval: 1, startDate: utc(2026, 11, 15), endDate: nil, scenarioId: b.id!)
            var ex = PlannedOccurrenceException(entryId: car.id!, originalDate: utc(2026, 12, 15), amountMinorUnits: -40_000)
            try ex.insert(db)
        }
        return f
    }

    private func save(_ f: Fixture, _ name: String = "A + B", from ids: [Int64]? = nil) throws -> Scenario {
        try f.manager.dbQueue.write { db in try Scenarios.createCombined(db: db, name: name, from: ids ?? [f.a, f.b], now: self.utc(2026, 10, 6)) }
    }

    private func plan(_ db: Database, scenarioId: Int64?) throws -> PlanInput {
        let entries = try scenarioId.map { try ForecastEntry.inScenario(db, id: $0) } ?? ForecastEntry.budget(db)
        let ids = entries.compactMap(\.id)
        let exceptions = try PlannedOccurrenceException.filter(ids.contains(Column("entryId"))).order(Column("id")).fetchAll(db)
        return PlanInput(entries: entries, exceptions: exceptions, groups: try ForecastGroup.fetchAll(db))
    }

    private func data(_ f: Fixture) throws -> ComparisonData {
        let categories = try f.manager.dbQueue.read { try Category.fetchAll($0) }
        let account = Account(id: 1, name: "Current", currency: .gbp, kind: .cash, trackingMode: .manual)
        let calendar = PayCalendar(salaryDates: [], manualCloses: [PayMonthClose(year: 2026, month: 1, closeDate: utc(2026, 1, 31)), PayMonthClose(year: 2026, month: 2, closeDate: utc(2026, 2, 28))], today: utc(2026, 3, 15))
        func txn(_ id: Int64, _ date: Date, _ amount: Int, _ category: String) -> Transaction {
            Transaction(id: id, importBatchId: 1, accountId: 9, date: date, rawDescription: "T\(id)", amountMinorUnits: amount, categoryId: f.categories[category]!, status: .confirmed, categorizedBy: .manual, fingerprint: "fp\(id)")
        }
        return ComparisonData(today: utc(2026, 3, 15), accounts: [account],
                              snapshots: [BalanceSnapshot(accountId: 1, date: utc(2026, 1, 1), balanceMinorUnits: 1_000_000, note: nil)],
                              transactions: [txn(1, utc(2026, 1, 5), -100_000, "Rent"), txn(2, utc(2026, 1, 25), 300_000, "Salary"), txn(3, utc(2026, 2, 5), -100_000, "Rent"), txn(4, utc(2026, 2, 25), 300_000, "Salary")], categories: categories, rate: ExchangeRateSetting(eurToGbpRate: 0.5, updatedAt: utc(2026, 1, 1)),
                              payCalendar: calendar, horizonYear: 2027, horizonMonth: 12)
    }

    func testSavedCombinationHasTheSameNetWorthAsTheCombinedLine() throws {
        let f = try fixture()
        let saved = try save(f)
        let (budget, a, b, new) = try f.manager.dbQueue.read { db in
            (try plan(db, scenarioId: nil), try plan(db, scenarioId: f.a), try plan(db, scenarioId: f.b), try plan(db, scenarioId: saved.id!))
        }
        let combined = ScenarioCombinator.combine(budget: budget, scenarios: [ScenarioPlan(id: f.a, name: "A", plan: a), ScenarioPlan(id: f.b, name: "B", plan: b)])
        let d = try data(f)
        let expected = ScenarioComparison.netWorthSeries(d, plan: combined.plan)
        let actual = ScenarioComparison.netWorthSeries(d, plan: new)
        XCTAssertEqual(actual.forecast, expected.forecast)
        XCTAssertFalse(actual.forecast.isEmpty)
        XCTAssertNotEqual(actual.forecast, ScenarioComparison.netWorthSeries(d, plan: budget).forecast)
    }

    func testSavedCombinationIsAnOrdinaryScenario() throws {
        let f = try fixture()
        let saved = try save(f)
        let entries = try f.manager.dbQueue.read { try ForecastEntry.inScenario($0, id: saved.id!) }
        // One entry per budget entry, plus the added car.
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(Set(entries.compactMap(\.sourceEntryId)), Set(f.entries.values))
        XCTAssertEqual(entries.filter { $0.scenarioChange == nil }.compactMap(\.sourceEntryId), [f.entries["Salary"]!])
        let diffs = try f.manager.dbQueue.read { try Scenarios.differences(db: $0, scenarioId: saved.id!) }
        XCTAssertEqual(Set(diffs.map(\.categoryName)), ["Rent", "Gym", "Car"])
        XCTAssertEqual(diffs.first { $0.categoryName == "Gym" }?.kind, .removed)
        XCTAssertEqual(diffs.first { $0.categoryName == "Car" }?.kind, .added)
        // Later wins on the overlap: B's rent.
        let rent = try XCTUnwrap(entries.first { $0.sourceEntryId == f.entries["Rent"] })
        XCTAssertEqual(rent.amountMinorUnits, -150_000)
        XCTAssertEqual(rent.scenarioChange, .changed)
        // The car keeps its edited occurrence.
        let car = try XCTUnwrap(entries.first { $0.scenarioChange == .added })
        let exceptions = try f.manager.dbQueue.read { try PlannedOccurrenceException.filter(Column("entryId") == car.id!).fetchAll($0) }
        XCTAssertEqual(exceptions.map(\.amountMinorUnits), [-40_000])
        // Nothing was applied to the budget.
        let applications = try f.manager.dbQueue.read { try ScenarioApplication.fetchCount($0) }
        XCTAssertEqual(applications, 0)
    }

    func testSavingDoesNotTouchTheBudgetOrTheSourceScenarios() throws {
        let f = try fixture()
        let before = try f.manager.dbQueue.read { db in (try plan(db, scenarioId: nil), try plan(db, scenarioId: f.a), try plan(db, scenarioId: f.b)) }
        _ = try save(f)
        let after = try f.manager.dbQueue.read { db in (try plan(db, scenarioId: nil), try plan(db, scenarioId: f.a), try plan(db, scenarioId: f.b)) }
        XCTAssertEqual(before.0, after.0)
        XCTAssertEqual(before.1, after.1)
        XCTAssertEqual(before.2, after.2)
    }

    func testDuplicateOrEmptyNameIsRefused() throws {
        let f = try fixture()
        XCTAssertThrowsError(try save(f, "  ")) { XCTAssertEqual($0 as? ScenarioError, .emptyName) }
        XCTAssertThrowsError(try save(f, "A")) { XCTAssertEqual($0 as? ScenarioError, .duplicateName) }
        XCTAssertThrowsError(try save(f, "Solo", from: [f.a])) { XCTAssertEqual($0 as? ScenarioError, .notFound) }
        XCTAssertThrowsError(try save(f, "Ghost", from: [f.a, 9_999])) { XCTAssertEqual($0 as? ScenarioError, .notFound) }
        let count = try f.manager.dbQueue.read { try Scenario.fetchCount($0) }
        XCTAssertEqual(count, 2)
    }
}
