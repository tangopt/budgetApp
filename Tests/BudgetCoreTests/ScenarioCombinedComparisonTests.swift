import XCTest
@testable import BudgetCore
import struct BudgetCore.Category

/// The Compare tab's lines with the Combined line (spec 2026-10-28-step17-scenario-comparison-design.md).
final class ScenarioCombinedComparisonTests: XCTestCase {
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private let salaryId: Int64 = 1, rentId: Int64 = 2, gymId: Int64 = 3, foodId: Int64 = 4

    private var categories: [Category] {
        [Category(id: salaryId, name: "Salary", type: .income), Category(id: rentId, name: "Rent", type: .expense),
         Category(id: gymId, name: "Gym", type: .expense), Category(id: foodId, name: "Food", type: .expense)]
    }

    private func entry(_ id: Int64, _ category: Int64, _ amount: Int, start: Date, scenarioId: Int64? = nil, source: Int64? = nil, change: ScenarioChange? = nil) -> ForecastEntry {
        ForecastEntry(id: id, groupId: 1, categoryId: category, amountMinorUnits: amount, frequency: .monthly, interval: 1, startDate: start, endDate: nil, isEnabled: true, status: .manual, note: nil,
                      scenarioId: scenarioId, sourceEntryId: source, scenarioChange: change)
    }

    private let groups = [ForecastGroup(id: 1, name: "Planned", note: nil, isEnabled: true, isSystemManaged: false)]

    private var budget: PlanInput {
        PlanInput(entries: [entry(1, salaryId, 300_000, start: utc(2026, 1, 25)), entry(2, rentId, -100_000, start: utc(2026, 1, 1))], exceptions: [], groups: groups)
    }

    /// A scenario's unchanged copies of the budget's entries.
    private func copies(_ scenario: Int64) -> [ForecastEntry] {
        [entry(scenario * 100 + 1, salaryId, 300_000, start: utc(2026, 1, 25), scenarioId: scenario, source: 1),
         entry(scenario * 100 + 2, rentId, -100_000, start: utc(2026, 1, 1), scenarioId: scenario, source: 2)]
    }

    /// Scenario 7 adds a gym; scenario 8 adds food.
    private var disjoint: [ScenarioPlan] {
        [ScenarioPlan(id: 7, name: "Gym", plan: PlanInput(entries: copies(7) + [entry(11, gymId, -10_000, start: utc(2026, 4, 1), scenarioId: 7, change: .added)], exceptions: [], groups: groups)),
         ScenarioPlan(id: 8, name: "Food", plan: PlanInput(entries: copies(8) + [entry(21, foodId, -20_000, start: utc(2026, 5, 1), scenarioId: 8, change: .added)], exceptions: [], groups: groups))]
    }

    private var data: ComparisonData {
        let account = Account(id: 1, name: "Current", currency: .gbp, kind: .cash, trackingMode: .manual)
        func txn(_ id: Int64, _ date: Date, _ amount: Int, _ category: Int64) -> Transaction {
            Transaction(id: id, importBatchId: 1, accountId: 9, date: date, rawDescription: "T\(id)", amountMinorUnits: amount, categoryId: category, status: .confirmed, categorizedBy: .manual, fingerprint: "fp\(id)")
        }
        let calendar = PayCalendar(salaryDates: [], manualCloses: [PayMonthClose(year: 2026, month: 1, closeDate: utc(2026, 1, 31)), PayMonthClose(year: 2026, month: 2, closeDate: utc(2026, 2, 28))], today: utc(2026, 3, 15))
        return ComparisonData(today: utc(2026, 3, 15), accounts: [account],
                              snapshots: [BalanceSnapshot(accountId: 1, date: utc(2026, 1, 1), balanceMinorUnits: 1_000_000, note: nil)],
                              transactions: [txn(1, utc(2026, 1, 5), -100_000, rentId), txn(2, utc(2026, 1, 25), 300_000, salaryId),
                                             txn(3, utc(2026, 2, 5), -100_000, rentId), txn(4, utc(2026, 2, 25), 300_000, salaryId)], categories: categories, rate: ExchangeRateSetting(eurToGbpRate: 0.5, updatedAt: utc(2026, 1, 1)),
                              payCalendar: calendar, horizonYear: 2027, horizonMonth: 6)
    }

    func testLinesAreBudgetThenScenariosThenCombined() {
        let with = CombinedComparison.lines(data, budget: budget, scenarios: disjoint, includeCombined: true)
        XCTAssertEqual(with.lines.map(\.id), ["budget", "scenario-7", "scenario-8", "combined"])
        let without = CombinedComparison.lines(data, budget: budget, scenarios: disjoint, includeCombined: false)
        XCTAssertEqual(without.lines.map(\.id), ["budget", "scenario-7", "scenario-8"])
    }

    func testCombinedEqualsSumOfDifferencesWhenDisjoint() throws {
        let result = CombinedComparison.lines(data, budget: budget, scenarios: disjoint, includeCombined: true)
        let end = { (line: ComparisonLine) in line.years.last?.differenceVsBudget }
        let gym = try XCTUnwrap(end(result.lines[1])), food = try XCTUnwrap(end(result.lines[2]))
        XCTAssertNotEqual(gym, 0)
        XCTAssertEqual(end(result.lines[3]), gym + food)
        XCTAssertEqual(result.lines[0].forecast, ScenarioComparison.netWorthSeries(data, plan: budget).forecast)
    }

    func testOverlapsPassThrough() {
        func change(_ id: Int64, _ scenario: Int64, _ amount: Int) -> ScenarioPlan {
            ScenarioPlan(id: scenario, name: "S\(scenario)", plan: PlanInput(entries: [copies(scenario)[0]] + [entry(id, rentId, amount, start: utc(2026, 1, 1), scenarioId: scenario, source: 2, change: .changed)], exceptions: [], groups: groups))
        }
        let result = CombinedComparison.lines(data, budget: budget, scenarios: [change(31, 7, -110_000), change(32, 8, -120_000)], includeCombined: false)
        XCTAssertEqual(result.overlaps.count, 1)
    }

    /// Each year's own average (not one figure over the whole horizon), hand-computed: the budget
    /// keeps 2,000 a month; the gym (-100 from April 2026) and food (-200 from May 2026) take theirs
    /// from their months; 2027 runs to June.
    func testAverageMonthlySurplusIsEachYearsOwn() {
        let result = CombinedComparison.lines(data, budget: budget, scenarios: disjoint, includeCombined: true)
        let byId = Dictionary(uniqueKeysWithValues: result.lines.map { ($0.id, $0.averageMonthlySurplus) })
        XCTAssertEqual(byId["budget"], [2026: 200_000, 2027: 200_000])
        XCTAssertEqual(byId["scenario-7"], [2026: (2_400_000 - 9 * 10_000) / 12, 2027: 190_000])
        XCTAssertEqual(byId["scenario-8"], [2026: 186_667, 2027: 180_000])
        XCTAssertEqual(byId["combined"], [2026: 179_167, 2027: 170_000])
        for line in result.lines {
            for year in line.years {
                XCTAssertEqual(line.averageMonthlySurplus[year.year], ScenarioImpact.averageMonthlySurplus([year], horizon: (2027, 6)))
            }
        }
    }

    func testCombinedUnavailableBelowTwoTicked() {
        let result = CombinedComparison.lines(data, budget: budget, scenarios: [disjoint[0]], includeCombined: true)
        XCTAssertEqual(result.lines.map(\.id), ["budget", "scenario-7"])
    }

    func testMaxTickedIsFour() {
        XCTAssertEqual(CombinedComparison.maxTicked, 4)
    }

    func testFifthTickIsRefused() {
        let four: Set<Int64> = [1, 2, 3, 4]
        XCTAssertEqual(CombinedComparison.limited(old: four, new: four.union([5])), four)
        XCTAssertEqual(CombinedComparison.limited(old: four, new: [1, 2, 3]), [1, 2, 3])
        XCTAssertEqual(CombinedComparison.initialSelection([1, 2, 3, 4, 5, 6]), four)
    }

    func testDeletingATickedScenarioRecomputesCombined() {
        XCTAssertEqual(CombinedComparison.pruned(selection: [7, 8], available: [7]), [7])
    }
}
