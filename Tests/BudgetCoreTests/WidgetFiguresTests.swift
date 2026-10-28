import XCTest
import GRDB
@testable import BudgetCore
@testable import BudgetDemo
import TestSupport

/// Step 18: the figures behind the Property month and Month spend widgets. Synthetic data only.
final class WidgetFiguresTests: XCTestCase {
    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: Expected to date

    func testExpectedToDateProratesTheBudgetByDay() {
        XCTAssertEqual(MonthSpendFigures.expected(budget: 310_000, day: 10, daysInMonth: 31), 100_000)
        XCTAssertEqual(MonthSpendFigures.expected(budget: 310_000, day: 31, daysInMonth: 31), 310_000)
        XCTAssertEqual(MonthSpendFigures.expected(budget: 100_000, day: 1, daysInMonth: 30), 3_333)
        XCTAssertEqual(MonthSpendFigures.expected(budget: 100_000, day: 2, daysInMonth: 30), 6_667, "rounds to the nearest minor unit")
        XCTAssertEqual(MonthSpendFigures.expected(budget: 100_000, day: 0, daysInMonth: 30), 0)
        XCTAssertEqual(MonthSpendFigures.expected(budget: 100_000, day: 45, daysInMonth: 30), 100_000, "never past the budget")
        XCTAssertEqual(MonthSpendFigures.expected(budget: 0, day: 5, daysInMonth: 30), 0)
        XCTAssertEqual(MonthSpendFigures.expected(budget: 100_000, day: 5, daysInMonth: 0), 0)
    }

    func testPaceAndFractions() {
        let figures = MonthSpendFigures(start: Self.day(2026, 9, 25), spentMinorUnits: 150_000, budgetMinorUnits: 300_000, dayOfMonth: 10,
                                        daysInMonth: 30, cumulativeSpent: [], overBudget: [])
        XCTAssertEqual(figures.expectedToDateMinorUnits, 100_000)
        XCTAssertEqual(figures.overPaceMinorUnits, 50_000)
        XCTAssertEqual(figures.spentFraction, 0.5, accuracy: 1e-9)
        XCTAssertEqual(figures.elapsedFraction, 1.0 / 3.0, accuracy: 1e-9)
        let none = MonthSpendFigures(start: figures.start, spentMinorUnits: 5, budgetMinorUnits: 0, dayOfMonth: 1, daysInMonth: 30,
                                     cumulativeSpent: [5], overBudget: [])
        XCTAssertEqual(none.spentFraction, 0)
    }

    func testCumulativeIsTheRunningTotal() {
        XCTAssertEqual(MonthSpendFigures.cumulative([100, 0, 250, -50]), [100, 100, 350, 300])
        XCTAssertEqual(MonthSpendFigures.cumulative([]), [])
    }

    func testOverBudgetKeepsTheThreeMostOverAndSkipsUnbudgeted() {
        let rows = [
            CategorySpend(name: "Food", actual: 50_000, expected: 40_000, projected: 45_000),
            CategorySpend(name: "Fun", actual: 90_000, expected: 20_000, projected: 90_000),
            CategorySpend(name: "Fuel", actual: 30_000, expected: 30_000, projected: 30_000),
            CategorySpend(name: "Gifts", actual: 20_000, expected: 0, projected: 20_000),
            CategorySpend(name: "Bills", actual: 61_000, expected: 40_000, projected: 61_000),
            CategorySpend(name: "Books", actual: 41_000, expected: 40_000, projected: 41_000),
        ]
        let over = MonthSpendFigures.overBudget(rows)
        XCTAssertEqual(over.map(\.name), ["Fun", "Bills", "Food"])
        XCTAssertEqual(over.first?.overByMinorUnits, 70_000)
        XCTAssertEqual(MonthSpendFigures.overBudget([]).count, 0)
    }

    // MARK: Home's own figures

    func testMonthSpendEqualsHomesPayMonth() throws {
        let (manager, evidence) = try PhoneDemoFixture.build()
        defer { try? FileManager.default.removeItem(at: evidence) }
        let (figures, home) = try manager.dbQueue.read { db -> (MonthSpendFigures, HomeSummary) in
            let input = try PhoneDemoFixture.input(db, today: PhoneDemoFixture.today)
            let home = try HomeSummary.make(input, db: db)
            return (MonthSpendFigures.make(input, month: home.month), home)
        }
        XCTAssertEqual(figures.spentMinorUnits, home.month.expenses.actual)
        XCTAssertEqual(figures.budgetMinorUnits, home.plannedSpendingMinorUnits)
        XCTAssertEqual(figures.dayOfMonth, home.month.dayOfMonth)
        XCTAssertEqual(figures.daysInMonth, home.month.daysInMonth)
        XCTAssertEqual(figures.cumulativeSpent.count, home.month.dayOfMonth)
        XCTAssertEqual(figures.cumulativeSpent.last, home.month.expenses.actual, "the days add up to what Home says was spent")
        XCTAssertGreaterThan(figures.spentMinorUnits, 0)
        XCTAssertEqual(zip(figures.cumulativeSpent, figures.cumulativeSpent.dropFirst()).filter { $0 > $1 }.count, 0, "demo has no refunds that day to day")
        XCTAssertLessThanOrEqual(figures.overBudget.count, MonthSpendFigures.overBudgetLimit)
        XCTAssertTrue(figures.overBudget.allSatisfy { $0.spentMinorUnits > $0.budgetMinorUnits })
    }

    func testSnapshotCarriesTheFiguresAndRoundTrips() throws {
        let (manager, evidence) = try PhoneDemoFixture.build()
        defer { try? FileManager.default.removeItem(at: evidence) }
        let snapshot = try XCTUnwrap(manager.dbQueue.read { db in
            try WidgetSnapshot.make(db: db, viewer: .demoAdmin, today: PhoneDemoFixture.today, settings: PhoneOutputSettings())
        })
        let spend = try XCTUnwrap(snapshot.monthSpend)
        XCTAssertEqual(spend.spentMinorUnits, try manager.dbQueue.read { db in
            try HomeSummary.make(try PhoneDemoFixture.input(db, today: PhoneDemoFixture.today), db: db).month.expenses.actual
        })
        let months = try XCTUnwrap(snapshot.propertyMonths)
        XCTAssertFalse(months.isEmpty, "the demo has tenancies running this month")
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
    }

    func testOlderSnapshotWithoutTheNewFieldsStillDecodes() throws {
        let old = WidgetSnapshot(generatedAt: Self.day(2026, 10, 15), netWorthMinorUnits: 1, leftToSpendMinorUnits: 2,
                                 paydayDate: Self.day(2026, 10, 24), showFiguresOnLockScreen: false)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        object["monthSpend"] = nil
        object["propertyMonths"] = nil
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.monthSpend)
        XCTAssertNil(decoded.propertyMonths)
    }

    // MARK: Property month pipeline

    private func provider(_ name: String, _ kind: UtilityKind, _ state: ThisMonthChecklist.ProviderBill.State) -> ThisMonthChecklist.ProviderBill {
        .init(providerId: 1, name: name, kind: kind, state: state, stage: nil, trayItemIds: [])
    }

    private let month = day(2026, 10, 1)

    func testPipelineCountsBillsAndSteps() {
        let providers = [provider("Power Co", .electricity, .checked), provider("Gas Co", .gas, .fetched), provider("Water Co", .water, .missing)]
        let draft = RechargeStatement(id: 1, tenancyId: 1, month: month, totalMinorUnits: 12_000, status: .draft)
        let figures = RechargePipelineFigures.make(tenancyName: "Tenancy 1", month: month, providers: providers, statement: draft,
                                                paidMinorUnits: 0, currency: .eur)
        XCTAssertEqual(figures.billsIn, 1)
        XCTAssertEqual(figures.billsExpected, 3)
        XCTAssertFalse(figures.allBillsIn)
        XCTAssertFalse(figures.statementSent)
        XCTAssertFalse(figures.paidByTenant)
        XCTAssertEqual(figures.stepsDone, 0)
        XCTAssertEqual(figures.outstandingMinorUnits, 12_000)
        XCTAssertEqual(figures.utilities.map(\.isIn), [true, false, false])
        XCTAssertEqual(figures.currencyCode, "EUR")
    }

    func testPipelineSentThenPartlyPaidThenPaid() {
        let providers = [provider("Power Co", .electricity, .checked), provider("Gas Co", .gas, .checked)]
        var sent = RechargeStatement(id: 1, tenancyId: 1, month: month, totalMinorUnits: 12_000, status: .sent)
        var figures = RechargePipelineFigures.make(tenancyName: "T", month: month, providers: providers, statement: sent, paidMinorUnits: 5_000, currency: .eur)
        XCTAssertTrue(figures.allBillsIn)
        XCTAssertTrue(figures.statementSent)
        XCTAssertFalse(figures.paidByTenant)
        XCTAssertEqual(figures.stepsDone, 2)
        XCTAssertEqual(figures.outstandingMinorUnits, 7_000)

        figures = RechargePipelineFigures.make(tenancyName: "T", month: month, providers: providers, statement: sent, paidMinorUnits: 12_000, currency: .eur)
        XCTAssertTrue(figures.paidByTenant)
        XCTAssertEqual(figures.outstandingMinorUnits, 0)
        XCTAssertEqual(figures.stepsDone, 3)

        sent.status = .paid
        figures = RechargePipelineFigures.make(tenancyName: "T", month: month, providers: providers, statement: sent, paidMinorUnits: 0, currency: .eur)
        XCTAssertTrue(figures.paidByTenant, "marked paid by hand")
        XCTAssertEqual(figures.outstandingMinorUnits, 0)
    }

    func testPipelineWithoutStatementOrBills() {
        let figures = RechargePipelineFigures.make(tenancyName: "T", month: month, providers: [], statement: nil, paidMinorUnits: 0, currency: .gbp)
        XCTAssertEqual(figures.billsExpected, 0)
        XCTAssertFalse(figures.allBillsIn, "nothing expected is not 'all in'")
        XCTAssertEqual(figures.stepsDone, 0)
        XCTAssertEqual(figures.outstandingMinorUnits, 0)
    }

    /// The database read labels by the tenancy's name and agrees with the Mac's This month checklist.
    func testPipelineFromTheDemoMatchesTheChecklist() throws {
        let (manager, evidence) = try PhoneDemoFixture.build()
        defer { try? FileManager.default.removeItem(at: evidence) }
        let today = PhoneDemoFixture.today
        let (rows, checklists, tenantNames) = try manager.dbQueue.read { db -> ([RechargePipelineFigures], [ThisMonthChecklist], [String]) in
            let rows = try RechargePipelineFigures.all(db: db, today: today, viewer: nil)
            let ids = try Tenancy.fetchAll(db).compactMap(\.id)
            let lists = try ids.map { try ThisMonthChecklist.build(db: db, tenancyId: $0, today: today, trayCount: 0) }
            return (rows, lists, try Tenancy.fetchAll(db).compactMap(\.tenantName))
        }
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            let checklist = try XCTUnwrap(checklists.first { $0.tenancyName == row.tenancyName })
            let providers = checklist.step(.billsIn)?.providers ?? []
            XCTAssertEqual(row.billsExpected, providers.count)
            XCTAssertEqual(row.billsIn, providers.filter { $0.state == .checked }.count)
            XCTAssertFalse(tenantNames.contains(row.tenancyName), "labelled by tenancy name, never the tenant's")
        }
    }

    func testMemberWithoutPropertyAccessSeesNoPipeline() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            try db.execute(sql: "UPDATE appUser SET cloudKitUserRecordName = ? WHERE personId = ?", arguments: ["_member", f.personB])
        }
        let rows = try queue.read { db in
            try WidgetSnapshot.propertyMonths(db: db, viewer: .iCloudUser(recordName: "_nobody"), today: Self.day(2026, 9, 30))
        }
        XCTAssertEqual(rows, [], "a device whose user isn't bound shows no pipeline")
    }
}
