import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category

/// Scenario model (spec 2026-10-08-scenario-lab-design.md, "Model"): migration, legacy
/// conversion, and the budget filter (scenario entries never count toward the budget).
final class ScenarioModelTests: XCTestCase {
    private typealias F = DashboardFixture
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { F.date(y, m, d) }

    // MARK: - Migration

    func testMigrationAddsScenarioTablesAndEntryColumns() throws {
        let m = try DatabaseManager(path: nil)
        try m.migrate()
        try m.dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("scenario"))
            XCTAssertTrue(try db.tableExists("scenarioApplication"))
            let columns = Set(try db.columns(in: "forecastEntry").map(\.name))
            XCTAssertTrue(columns.isSuperset(of: ["scenarioId", "sourceEntryId", "scenarioChange"]))
            let scenarioColumns = Set(try db.columns(in: "scenario").map(\.name))
            XCTAssertEqual(scenarioColumns, ["id", "name", "createdAt", "refreshedAt"])
            let applicationColumns = Set(try db.columns(in: "scenarioApplication").map(\.name))
            XCTAssertEqual(applicationColumns, ["id", "scenarioId", "appliedAt", "undoneAt", "journal"])
        }
    }

    func testRecordsRoundTripAndDeletingAScenarioCascades() throws {
        let m = try DatabaseManager(path: nil)
        try m.migrate()
        try m.dbQueue.write { db in
            var rent = Category(name: "Rent", type: .expense)
            try rent.insert(db)
            var group = ForecastGroup(name: "Planned", note: nil, isEnabled: true, isSystemManaged: false)
            try group.insert(db)
            var budget = ForecastEntry(groupId: group.id!, categoryId: rent.id!, amountMinorUnits: -100, frequency: .monthly, interval: 1, startDate: self.date(2026, 1, 1), endDate: nil, isEnabled: true, status: .manual, note: nil)
            try budget.insert(db)
            var scenario = Scenario(name: "Move house", createdAt: self.date(2026, 10, 1))
            try scenario.insert(db)
            XCTAssertThrowsError(try { var dup = Scenario(name: "Move house", createdAt: Date()); try dup.insert(db) }()) // unique name
            var copy = budget
            copy.id = nil
            copy.scenarioId = scenario.id
            copy.sourceEntryId = budget.id
            copy.scenarioChange = .changed
            try copy.insert(db)
            var exception = PlannedOccurrenceException(entryId: copy.id!, originalDate: self.date(2026, 2, 1), isSkipped: true)
            try exception.insert(db)
            var application = ScenarioApplication(scenarioId: scenario.id!, appliedAt: self.date(2026, 10, 2), journal: "{}")
            try application.insert(db)

            let fetched = try XCTUnwrap(ForecastEntry.fetchOne(db, key: copy.id!))
            XCTAssertEqual(fetched.scenarioId, scenario.id)
            XCTAssertEqual(fetched.sourceEntryId, budget.id)
            XCTAssertEqual(fetched.scenarioChange, .changed)
            XCTAssertEqual(try Scenario.fetchOne(db, key: scenario.id!), scenario)
            XCTAssertEqual(try ScenarioApplication.fetchOne(db, key: application.id!), application)

            _ = try scenario.delete(db)
            XCTAssertEqual(try ForecastEntry.fetchAll(db).map(\.id), [budget.id])
            XCTAssertEqual(try PlannedOccurrenceException.fetchCount(db), 0)
            XCTAssertEqual(try ScenarioApplication.fetchCount(db), 0)
        }
    }

    func testLegacyScenarioGroupsBecomeScenariosWithAddedEntries() throws {
        let m = try DatabaseManager(path: nil)
        try m.migrate(upTo: "addForecastEntryAnchorDay")
        try m.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO category (id, name, type) VALUES (1, 'Rent', 'expense')")
            try db.execute(sql: """
                INSERT INTO forecastGroup (id, name, isEnabled, isSystemManaged) VALUES
                (1, 'Planned', 1, 0), (2, 'New flat', 1, 0), (3, 'Empty', 1, 0)
                """)
            try db.execute(sql: """
                INSERT INTO forecastEntry (id, groupId, categoryId, amountMinorUnits, frequency, interval, startDate, isEnabled, status) VALUES
                (1, 1, 1, -100, 'monthly', 1, '2026-01-01 00:00:00.000', 1, 'confirmed'),
                (2, 2, 1, -200, 'monthly', 1, '2026-01-01 00:00:00.000', 1, 'hypothetical'),
                (3, 2, 1, -300, 'once', 1, '2026-03-01 00:00:00.000', 1, 'hypothetical'),
                (4, 2, 1, -400, 'monthly', 1, '2026-01-01 00:00:00.000', 1, 'confirmed')
                """)
        }
        try m.migrate()
        try m.dbQueue.read { db in
            let scenarios = try Scenario.fetchAll(db)
            XCTAssertEqual(scenarios.map(\.name), ["New flat"])
            let scenarioId = try XCTUnwrap(scenarios.first?.id)
            let entries = Dictionary(uniqueKeysWithValues: try ForecastEntry.fetchAll(db).map { ($0.id!, $0) })
            for id: Int64 in [2, 3] {
                XCTAssertEqual(entries[id]?.scenarioId, scenarioId)
                XCTAssertEqual(entries[id]?.scenarioChange, .added)
                XCTAssertEqual(entries[id]?.status, .manual)
                XCTAssertNil(entries[id]?.sourceEntryId)
            }
            for id: Int64 in [1, 4] { // budget entries (a confirmed one in the scenario group too) stay in the budget
                XCTAssertNil(entries[id]?.scenarioId)
                XCTAssertNil(entries[id]?.scenarioChange)
                XCTAssertEqual(entries[id]?.status, .confirmed)
            }
            XCTAssertEqual(try ForecastEntry.budget(db).map(\.id), [1, 4])
            XCTAssertEqual(try ForecastEntry.inScenario(db, id: scenarioId).map(\.id), [2, 3])
        }
    }

    // MARK: - Budget filter

    /// +500/month rent in a scenario: it must never show in any budget figure.
    private var scenarioEntry: ForecastEntry {
        ForecastEntry(id: 99, groupId: 1, categoryId: F.rentId, amountMinorUnits: -500_000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 3), endDate: nil, isEnabled: true, status: .manual, note: nil, scenarioId: 1, sourceEntryId: nil, scenarioChange: .added)
    }

    func testConfirmedEntriesExcludeScenarioEntries() {
        let groups = [ForecastGroup(id: 1, name: "G", note: nil, isEnabled: true, isSystemManaged: false)]
        let entries = F.withDining + [scenarioEntry]
        XCTAssertEqual(ForecastCalculator.confirmedEntries(entries: entries, groups: groups).map(\.id), [1, 2, 3])
        let period = PayPeriod(startDate: date(2026, 11, 1), endDate: date(2026, 11, 30), type: .projected)
        XCTAssertEqual(ForecastCalculator.confirmedTotal(categoryId: F.rentId, period: period, entries: entries, groups: groups, exceptions: []), -100_000)
        XCTAssertEqual(ForecastCalculator.confirmedTotalsByCategory(period: period, entries: entries, groups: groups, exceptions: [])[F.rentId], -100_000)
        let rent = Category(id: F.rentId, name: "Rent", type: .expense)
        XCTAssertEqual(BudgetGridCalculator.categoryTotal(category: rent, period: period, transactions: [], forecastEntries: entries, forecastGroups: groups, exceptions: []), -100_000)
    }

    func testPlanEntriesKeepScenarioEntriesButNotRemovedOrDisabledOnes() {
        let groups = [ForecastGroup(id: 1, name: "G", note: nil, isEnabled: true, isSystemManaged: false),
                      ForecastGroup(id: 2, name: "Off", note: nil, isEnabled: false, isSystemManaged: false)]
        func entry(_ id: Int64, group: Int64 = 1, enabled: Bool = true, change: ScenarioChange?) -> ForecastEntry {
            ForecastEntry(id: id, groupId: group, categoryId: F.rentId, amountMinorUnits: -1, frequency: .monthly, interval: 1, startDate: date(2026, 1, 1), endDate: nil, isEnabled: enabled, status: .manual, note: nil, scenarioId: 7, sourceEntryId: nil, scenarioChange: change)
        }
        let entries = [entry(1, change: nil), entry(2, change: .added), entry(3, change: .changed),
                       entry(4, enabled: false, change: .removed), entry(5, change: .removed),
                       entry(6, enabled: false, change: nil), entry(7, group: 2, change: nil)]
        XCTAssertEqual(ForecastCalculator.planEntries(entries: entries, groups: groups).map(\.id), [1, 2, 3])
    }

    func testDashboardIgnoresScenarioEntries() {
        let today = date(2026, 10, 10)
        let plain = F.input(today: today, snapshots: [F.snapshot(1, date(2026, 9, 30), 1_000_000)], entries: F.withDining)
        let withScenario = F.input(today: today, snapshots: [F.snapshot(1, date(2026, 9, 30), 1_000_000)], entries: F.withDining + [scenarioEntry])
        XCTAssertEqual(DashboardCalculator.currentMonth(withScenario), DashboardCalculator.currentMonth(plain))
        XCTAssertEqual(DashboardCalculator.upcomingBills(withScenario, days: 30), DashboardCalculator.upcomingBills(plain, days: 30))
        XCTAssertEqual(DashboardCalculator.netWorthSeries(withScenario), DashboardCalculator.netWorthSeries(plain))
        XCTAssertEqual(DashboardCalculator.monthlyFlows(withScenario, year: 2026), DashboardCalculator.monthlyFlows(plain, year: 2026))
        XCTAssertEqual(DashboardCalculator.attentionItems(withScenario), DashboardCalculator.attentionItems(plain))
    }

    func testProjectionIgnoresScenarioEntries() {
        let input = F.input(today: date(2026, 10, 10))
        let groups = input.forecastGroups
        let plain = ForecastProjector.monthlyProjection(startingNetWorth: 0, latestRealMonth: (2026, 9), throughYear: 2027, categories: input.categories, entries: F.withDining, groups: groups, exceptions: [])
        let withScenario = ForecastProjector.monthlyProjection(startingNetWorth: 0, latestRealMonth: (2026, 9), throughYear: 2027, categories: input.categories, entries: F.withDining + [scenarioEntry], groups: groups, exceptions: [])
        XCTAssertEqual(withScenario, plain)
    }

    func testBudgetRequestsSplitBudgetAndScenarioEntries() throws {
        let m = try DatabaseManager(path: nil)
        try m.migrate()
        try m.dbQueue.write { db in
            var rent = Category(name: "Rent", type: .expense)
            try rent.insert(db)
            var group = ForecastGroup(name: "Planned", note: nil, isEnabled: true, isSystemManaged: false)
            try group.insert(db)
            var a = Scenario(name: "A", createdAt: Date()), b = Scenario(name: "B", createdAt: Date())
            try a.insert(db); try b.insert(db)
            for scenarioId in [nil, a.id, b.id, a.id] {
                var e = ForecastEntry(groupId: group.id!, categoryId: rent.id!, amountMinorUnits: -1, frequency: .monthly, interval: 1, startDate: self.date(2026, 1, 1), endDate: nil, isEnabled: true, status: .manual, note: nil, scenarioId: scenarioId)
                try e.insert(db)
            }
            XCTAssertEqual(try ForecastEntry.budget(db).map(\.id), [1])
            XCTAssertEqual(try ForecastEntry.inScenario(db, id: a.id!).map(\.id), [2, 4])
            XCTAssertEqual(try ForecastEntry.inScenario(db, id: b.id!).map(\.id), [3])
            XCTAssertEqual(try ForecastEntry.budgetEntries.fetchCount(db), 1)
        }
    }

    /// Detection adds a plan for a category whose only entries are in a scenario.
    func testDetectionTreatsAScenarioOnlyCategoryAsUnplanned() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let periods = [
            PayPeriod(startDate: date(2026, 4, 26), endDate: date(2026, 5, 25), type: .actual),
            PayPeriod(startDate: date(2026, 5, 26), endDate: date(2026, 6, 25), type: .actual),
            PayPeriod(startDate: date(2026, 6, 26), endDate: date(2026, 7, 25), type: .actual)
        ]
        let rentId: Int64 = try manager.dbQueue.write { db in
            var rent = Category(name: "Rent", type: .expense)
            try rent.insert(db)
            var account = Account(name: "Current", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "x.csv", importedAt: Date())
            try batch.insert(db)
            for (i, day) in [self.date(2026, 4, 28), self.date(2026, 5, 28), self.date(2026, 6, 28)].enumerated() {
                var t = Transaction(importBatchId: batch.id!, accountId: account.id!, date: day, rawDescription: "RENT", amountMinorUnits: -280_000, categoryId: rent.id!, status: .confirmed, categorizedBy: .manual, fingerprint: "r\(i)")
                try t.insert(db)
            }
            var group = ForecastGroup(name: "Planned", note: nil, isEnabled: true, isSystemManaged: false)
            try group.insert(db)
            var scenario = Scenario(name: "S", createdAt: Date())
            try scenario.insert(db)
            var e = ForecastEntry(groupId: group.id!, categoryId: rent.id!, amountMinorUnits: -1, frequency: .monthly, interval: 1, startDate: self.date(2026, 1, 1), endDate: nil, isEnabled: true, status: .manual, note: nil, scenarioId: scenario.id, scenarioChange: .added)
            try e.insert(db)
            try AutoForecastGenerator.regenerate(db: db, actualPeriods: periods)
            return rent.id!
        }
        try manager.dbQueue.read { db in
            let budget = try ForecastEntry.budgetEntries.filter(Column("categoryId") == rentId).fetchAll(db)
            XCTAssertEqual(budget.map(\.amountMinorUnits), [-280_000])
        }
    }
}
