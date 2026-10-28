import XCTest
@testable import BudgetCore
import struct BudgetCore.Category

/// Combining scenarios onto the budget (spec 2026-10-28-step17-scenario-comparison-design.md):
/// list order, the later scenario wins an overlap, exceptions follow their entries.
final class ScenarioCombinatorTests: XCTestCase {
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private let salaryId: Int64 = 1, rentId: Int64 = 2, groceriesId: Int64 = 3, carId: Int64 = 4
    private let s1: Int64 = 7, s2: Int64 = 8

    private var categories: [Category] {
        [Category(id: salaryId, name: "Salary", type: .income),
         Category(id: rentId, name: "Rent", type: .expense),
         Category(id: groceriesId, name: "Groceries", type: .expense),
         Category(id: carId, name: "Car", type: .expense)]
    }

    private func entry(_ id: Int64, _ category: Int64, _ amount: Int, start: Date? = nil, group: Int64 = 1, scenarioId: Int64? = nil, source: Int64? = nil,
                       change: ScenarioChange? = nil, enabled: Bool = true) -> ForecastEntry {
        ForecastEntry(id: id, groupId: group, categoryId: category, amountMinorUnits: amount, frequency: .monthly, interval: 1, startDate: start ?? utc(2026, 1, 1),
                      endDate: nil, isEnabled: enabled, status: .manual, note: nil, scenarioId: scenarioId, sourceEntryId: source, scenarioChange: change)
    }

    private let groups = [ForecastGroup(id: 1, name: "Planned", note: nil, isEnabled: true, isSystemManaged: false)]

    /// Salary +3,000 on the 25th, rent -1,000 and groceries -400 on the 1st.
    private var budget: PlanInput {
        PlanInput(entries: [entry(1, salaryId, 300_000, start: utc(2026, 1, 25)), entry(2, rentId, -100_000), entry(3, groceriesId, -40_000)],
                  exceptions: [], groups: groups)
    }

    /// Unchanged copies of the budget's three entries in `scenario`, ids from `base`.
    private func copies(_ scenario: Int64, base: Int64) -> [ForecastEntry] {
        [entry(base + 1, salaryId, 300_000, start: utc(2026, 1, 25), scenarioId: scenario, source: 1),
         entry(base + 2, rentId, -100_000, scenarioId: scenario, source: 2),
         entry(base + 3, groceriesId, -40_000, scenarioId: scenario, source: 3)]
    }

    /// Replaces the copy of `source` in `entries` with `replacement`.
    private func replacing(_ entries: [ForecastEntry], source: Int64, with replacement: ForecastEntry) -> [ForecastEntry] {
        entries.map { $0.sourceEntryId == source ? replacement : $0 }
    }

    private var salaryPlus10: ScenarioPlan {
        let changed = entry(11, salaryId, 330_000, start: utc(2026, 1, 25), scenarioId: s1, source: 1, change: .changed)
        return ScenarioPlan(id: s1, name: "Salary +10%", plan: PlanInput(entries: replacing(copies(s1, base: 10), source: 1, with: changed), exceptions: [], groups: groups))
    }

    private var buyACar: ScenarioPlan {
        ScenarioPlan(id: s2, name: "Buy a car", plan: PlanInput(entries: copies(s2, base: 20) + [entry(24, carId, -25_000, scenarioId: s2, change: .added)],
                                                                exceptions: [], groups: groups))
    }

    private func groceries(_ scenario: Int64, id: Int64, amount: Int) -> ScenarioPlan {
        let changed = entry(id, groceriesId, amount, scenarioId: scenario, source: 3, change: .changed)
        return ScenarioPlan(id: scenario, name: "S\(scenario)", plan: PlanInput(entries: replacing(copies(scenario, base: id - 3), source: 3, with: changed),
                                                                                exceptions: [], groups: groups))
    }

    /// As `ScenarioComparisonTests`: January and February closed (salary and rent actuals in an
    /// account outside the chart), today 15 March 2026, 10,000 in the account since 1 January;
    /// horizon December 2027.
    private var data: ComparisonData {
        let account = Account(id: 1, name: "Current", currency: .gbp, kind: .cash, trackingMode: .manual)
        func txn(_ id: Int64, _ date: Date, _ amount: Int, _ category: Int64) -> Transaction {
            Transaction(id: id, importBatchId: 1, accountId: 9, date: date, rawDescription: "T\(id)", amountMinorUnits: amount, categoryId: category, status: .confirmed, categorizedBy: .manual, fingerprint: "fp\(id)")
        }
        let calendar = PayCalendar(salaryDates: [], manualCloses: [PayMonthClose(year: 2026, month: 1, closeDate: utc(2026, 1, 31)),
                                                                  PayMonthClose(year: 2026, month: 2, closeDate: utc(2026, 2, 28))],
                                   today: utc(2026, 3, 15))
        return ComparisonData(today: utc(2026, 3, 15), accounts: [account],
                              snapshots: [BalanceSnapshot(accountId: 1, date: utc(2026, 1, 1), balanceMinorUnits: 1_000_000, note: nil)],
                              transactions: [txn(1, utc(2026, 1, 5), -100_000, rentId), txn(2, utc(2026, 1, 25), 300_000, salaryId),
                                             txn(3, utc(2026, 2, 5), -100_000, rentId), txn(4, utc(2026, 2, 25), 300_000, salaryId)],
                              categories: categories, rate: ExchangeRateSetting(eurToGbpRate: 0.5, updatedAt: utc(2026, 1, 1)),
                              payCalendar: calendar, horizonYear: 2027, horizonMonth: 12)
    }

    private func summaries(_ plan: PlanInput) -> [PlanYearSummary] {
        let budgetSeries = ScenarioComparison.netWorthSeries(data, plan: budget)
        let series = ScenarioComparison.netWorthSeries(data, plan: plan)
        return ScenarioComparison.yearSummaries(data, plan: plan, series: series, budgetSeries: budgetSeries)
    }

    // MARK: - Combining

    func testNoScenariosReturnsTheBudget() {
        let combined = ScenarioCombinator.combine(budget: budget, scenarios: [])
        XCTAssertEqual(combined.plan, budget)
        XCTAssertEqual(combined.overlaps, [])
        XCTAssertEqual(combined.contributions, [:])
    }

    func testUnchangedCopiesContributeNothing() {
        let unchanged = ScenarioPlan(id: s1, name: "Copy", plan: PlanInput(entries: copies(s1, base: 10),
                                                                           exceptions: [PlannedOccurrenceException(id: 1, entryId: 13, originalDate: utc(2026, 3, 1), isSkipped: true)],
                                                                           groups: groups))
        let combined = ScenarioCombinator.combine(budget: budget, scenarios: [unchanged])
        XCTAssertEqual(combined.plan.entries, budget.entries)
        XCTAssertEqual(combined.plan.exceptions, [])
        XCTAssertEqual(combined.contributions, [:])
        XCTAssertEqual(ScenarioComparison.netWorthSeries(data, plan: combined.plan), ScenarioComparison.netWorthSeries(data, plan: budget))
    }

    func testTwoDisjointScenariosApplyTogether() throws {
        let combined = ScenarioCombinator.combine(budget: budget, scenarios: [salaryPlus10, buyACar])
        XCTAssertEqual(combined.plan.entries.map(\.id), [11, 2, 3, 24])
        XCTAssertEqual(combined.plan.entries.first?.amountMinorUnits, 330_000)
        XCTAssertEqual(combined.contributions, [11: s1, 24: s2])
        XCTAssertEqual(combined.overlaps, [])

        let together = summaries(combined.plan)
        let salary = summaries(salaryPlus10.plan)
        let car = summaries(buyACar.plan)
        XCTAssertEqual(together.map(\.year), [2026, 2027])
        for (index, year) in together.enumerated() {
            let sum = try XCTUnwrap(salary[index].differenceVsBudget) + XCTUnwrap(car[index].differenceVsBudget)
            XCTAssertEqual(year.differenceVsBudget, sum)
            XCTAssertNotEqual(salary[index].differenceVsBudget, 0)
            XCTAssertNotEqual(car[index].differenceVsBudget, 0)
        }
    }

    func testLaterScenarioWinsAndOverlapIsReported() {
        let combined = ScenarioCombinator.combine(budget: budget, scenarios: [groceries(s1, id: 13, amount: -50_000), groceries(s2, id: 23, amount: -60_000)])
        let groceriesEntries = combined.plan.entries.filter { $0.categoryId == groceriesId }
        XCTAssertEqual(groceriesEntries.map(\.id), [23])
        XCTAssertEqual(groceriesEntries.map(\.amountMinorUnits), [-60_000])
        XCTAssertEqual(combined.plan.entries.count, 3)
        XCTAssertEqual(combined.overlaps, [ScenarioOverlap(sourceEntryId: 3, categoryId: groceriesId, earlierScenarioId: s1, laterScenarioId: s2)])
        XCTAssertEqual(combined.contributions, [23: s2])
    }

    func testOrderIsTheListOrder() {
        let combined = ScenarioCombinator.combine(budget: budget, scenarios: [groceries(s2, id: 23, amount: -60_000), groceries(s1, id: 13, amount: -50_000)])
        XCTAssertEqual(combined.plan.entries.filter { $0.categoryId == groceriesId }.map(\.amountMinorUnits), [-50_000])
        XCTAssertEqual(combined.overlaps, [ScenarioOverlap(sourceEntryId: 3, categoryId: groceriesId, earlierScenarioId: s2, laterScenarioId: s1)])
        XCTAssertEqual(combined.contributions, [13: s1])
    }

    func testRemovedThenChangedUsesTheLaterAndReportsOverlap() {
        let tombstone = entry(12, rentId, -100_000, scenarioId: s1, source: 2, change: .removed, enabled: false)
        let removesRent = ScenarioPlan(id: s1, name: "No rent", plan: PlanInput(entries: replacing(copies(s1, base: 10), source: 2, with: tombstone), exceptions: [], groups: groups))
        let changed = entry(22, rentId, -120_000, scenarioId: s2, source: 2, change: .changed)
        let changesRent = ScenarioPlan(id: s2, name: "Rent up", plan: PlanInput(entries: replacing(copies(s2, base: 20), source: 2, with: changed), exceptions: [], groups: groups))

        let combined = ScenarioCombinator.combine(budget: budget, scenarios: [removesRent, changesRent])
        let rent = combined.plan.entries.filter { $0.categoryId == rentId }
        XCTAssertEqual(rent.map(\.id), [22])
        XCTAssertEqual(rent.map(\.isEnabled), [true])
        XCTAssertEqual(combined.overlaps, [ScenarioOverlap(sourceEntryId: 2, categoryId: rentId, earlierScenarioId: s1, laterScenarioId: s2)])

        // The other way round the tombstone stands, and rent counts for nothing.
        let reversed = ScenarioCombinator.combine(budget: budget, scenarios: [changesRent, removesRent])
        XCTAssertEqual(reversed.plan.entries.filter { $0.categoryId == rentId }.map(\.id), [12])
        XCTAssertEqual(reversed.overlaps, [ScenarioOverlap(sourceEntryId: 2, categoryId: rentId, earlierScenarioId: s2, laterScenarioId: s1)])
        let noRent = PlanInput(entries: budget.entries.filter { $0.categoryId != rentId }, exceptions: [], groups: groups)
        XCTAssertEqual(ScenarioComparison.netWorthSeries(data, plan: reversed.plan), ScenarioComparison.netWorthSeries(data, plan: noRent))
    }

    func testChangeWhoseSourceIsGoneIsKeptAsAdded() {
        let orphan = entry(19, groceriesId, -45_000, scenarioId: s1, source: 99, change: .changed)
        let scenario = ScenarioPlan(id: s1, name: "Old", plan: PlanInput(entries: copies(s1, base: 10) + [orphan], exceptions: [], groups: groups))
        let combined = ScenarioCombinator.combine(budget: budget, scenarios: [scenario])
        XCTAssertEqual(combined.plan.entries.count, budget.entries.count + 1)
        XCTAssertEqual(combined.plan.entries.last, orphan)
        XCTAssertEqual(combined.overlaps, [])
        XCTAssertEqual(combined.contributions, [19: s1])
    }

    func testExceptionsFollowTheirEntries() {
        let rentException = PlannedOccurrenceException(id: 1, entryId: 2, originalDate: utc(2026, 4, 1), amountMinorUnits: -110_000)
        let groceriesException = PlannedOccurrenceException(id: 2, entryId: 3, originalDate: utc(2026, 5, 1), amountMinorUnits: -80_000)
        let skipped = PlannedOccurrenceException(id: 3, entryId: 13, originalDate: utc(2026, 6, 1), isSkipped: true)
        var withExceptions = budget
        withExceptions.exceptions = [rentException, groceriesException]
        let changed = entry(13, groceriesId, -50_000, scenarioId: s1, source: 3, change: .changed)
        let scenario = ScenarioPlan(id: s1, name: "Groceries", plan: PlanInput(entries: replacing(copies(s1, base: 10), source: 3, with: changed),
                                                                               exceptions: [skipped], groups: groups))
        let combined = ScenarioCombinator.combine(budget: withExceptions, scenarios: [scenario])
        XCTAssertEqual(combined.plan.exceptions, [rentException, skipped])
    }

    func testGroupsAreUnionedById() {
        let carGroup = ForecastGroup(id: 2, name: "Car", note: nil, isEnabled: true, isSystemManaged: false)
        let scenario = ScenarioPlan(id: s1, name: "Car", plan: PlanInput(entries: copies(s1, base: 10) + [entry(14, carId, -30_000, group: 2, scenarioId: s1, change: .added)],
                                                                         exceptions: [], groups: groups + [carGroup]))
        let combined = ScenarioCombinator.combine(budget: budget, scenarios: [scenario, salaryPlus10])
        XCTAssertEqual(combined.plan.groups, groups + [carGroup])
        XCTAssertEqual(combined.plan.entries.last?.groupId, 2)
    }

    // MARK: - Overlapping salary scenarios and a car (the 2026-10-28 report)

    private func once(_ id: Int64, _ category: Int64, _ amount: Int, on date: Date, scenarioId: Int64) -> ForecastEntry {
        ForecastEntry(id: id, groupId: 1, categoryId: category, amountMinorUnits: amount, frequency: .once, interval: 1, startDate: date,
                      endDate: nil, isEnabled: true, status: .manual, note: nil, scenarioId: scenarioId, sourceEntryId: nil, scenarioChange: .added)
    }

    /// A job offer as `OfferScenarioBuilder` writes one: the salary copy ends the day before
    /// `from` (changed), and the offer's salary follows as an added entry, after `gapMonths`.
    private func offer(_ scenario: Int64, name: String, base: Int64, salary: Int, from: Date, gapMonths: Int = 0) -> ScenarioPlan {
        var ended = entry(base + 1, salaryId, 300_000, start: utc(2026, 1, 25), scenarioId: scenario, source: 1, change: .changed)
        ended.endDate = MonthRange.calendar.date(byAdding: .day, value: -1, to: from)
        let start = MonthRange.calendar.date(byAdding: .month, value: gapMonths, to: from)!
        var added = entry(base + 4, salaryId, salary, start: MonthRange.calendar.date(byAdding: .day, value: 24, to: start), scenarioId: scenario, change: .added)
        added.note = "Offer: salary"
        return ScenarioPlan(id: scenario, name: name, plan: PlanInput(entries: replacing(copies(scenario, base: base), source: 1, with: ended) + [added],
                                                                      exceptions: [], groups: groups))
    }

    private let s3: Int64 = 9

    /// "200" (3,500 from January 2027), "220" (3,800 after a month's gap) and "New Car" (17,385 once in March 2027).
    private var offer200: ScenarioPlan { offer(s1, name: "200", base: 10, salary: 350_000, from: utc(2027, 1, 1)) }
    private var offer220: ScenarioPlan { offer(s2, name: "220", base: 20, salary: 380_000, from: utc(2027, 1, 1), gapMonths: 1) }
    private var newCar: ScenarioPlan {
        ScenarioPlan(id: s3, name: "New Car", plan: PlanInput(entries: copies(s3, base: 30) + [once(34, carId, -1_738_500, on: utc(2027, 3, 1), scenarioId: s3)],
                                                              exceptions: [], groups: groups))
    }

    func testTwoOffersChangingTheSalaryFollowTheLaterOneWithANotice() throws {
        let combined = ScenarioCombinator.combine(budget: budget, scenarios: [offer200, offer220, newCar])
        // 220's ended copy and its offer salary stand in for the budget's salary; 200's are gone.
        XCTAssertEqual(combined.plan.entries.map(\.id), [21, 24, 2, 3, 34])
        XCTAssertEqual(combined.contributions, [21: s2, 24: s2, 34: s3])
        XCTAssertEqual(combined.overlaps, [ScenarioOverlap(sourceEntryId: 1, categoryId: salaryId, earlierScenarioId: s1, laterScenarioId: s2)])
        XCTAssertEqual(ScenarioCombinator.overlapNotice(combined.overlaps[0], scenarioNames: [s1: "200", s2: "220", s3: "New Car"],
                                                        categoryNames: [salaryId: "Salary"]),
                       "200 and 220 both change 'Salary'; the later one is used")

        // Hand-computed 2027: budget income 12 × 3,000; 220's is 11 × 3,800 (no pay in January);
        // expenses rent 12 × 1,000 + groceries 12 × 400, plus the car's 17,385.
        let together = summaries(combined.plan)
        let year2027 = try XCTUnwrap(together.first { $0.year == 2027 })
        XCTAssertEqual(year2027.income, 11 * 380_000)
        XCTAssertEqual(year2027.expenses, 12 * 100_000 + 12 * 40_000 + 1_738_500)
        let budget2027 = try XCTUnwrap(summaries(budget).first { $0.year == 2027 })
        XCTAssertEqual(budget2027.income, 12 * 300_000)

        // Net worth: the budget plus 220's change plus the car's, every year.
        let salary = summaries(offer220.plan), car = summaries(newCar.plan)
        for (index, year) in together.enumerated() {
            XCTAssertEqual(year.differenceVsBudget, try XCTUnwrap(salary[index].differenceVsBudget) + XCTUnwrap(car[index].differenceVsBudget))
        }
        XCTAssertEqual(year2027.differenceVsBudget, 11 * 380_000 - 12 * 300_000 - 1_738_500)
    }

    func testOfferOrderDecidesWhichSalaryIsUsed() {
        let combined = ScenarioCombinator.combine(budget: budget, scenarios: [offer220, offer200])
        XCTAssertEqual(combined.plan.entries.filter { $0.categoryId == salaryId }.map(\.id), [11, 14])
        XCTAssertEqual(combined.overlaps, [ScenarioOverlap(sourceEntryId: 1, categoryId: salaryId, earlierScenarioId: s2, laterScenarioId: s1)])
    }

    func testAnAdditionInAnotherCategoryStaysIndependent() {
        // The car isn't tied to any salary change: both offers keep it, and it counts once.
        let combined = ScenarioCombinator.combine(budget: budget, scenarios: [offer200, newCar])
        XCTAssertEqual(combined.plan.entries.map(\.id), [11, 14, 2, 3, 34])
        XCTAssertEqual(combined.overlaps, [])
    }

    func testTheSameAdditionInTwoScenariosCountsOnce() {
        // "200" duplicated from "New Car": its car is a copy of New Car's.
        var duplicated = offer200
        duplicated = ScenarioPlan(id: s1, name: "200", plan: PlanInput(entries: duplicated.plan.entries + [once(15, carId, -1_738_500, on: utc(2027, 3, 1), scenarioId: s1)],
                                                                       exceptions: [], groups: groups))
        let combined = ScenarioCombinator.combine(budget: budget, scenarios: [duplicated, newCar])
        XCTAssertEqual(combined.plan.entries.filter { $0.categoryId == carId }.map(\.id), [34])
        XCTAssertEqual(combined.contributions[34], s3)
        XCTAssertNil(combined.contributions[15])
    }

    func testOverlapNoticeWording() {
        let overlap = ScenarioOverlap(sourceEntryId: 3, categoryId: groceriesId, earlierScenarioId: s2, laterScenarioId: s1)
        let names = [s1: "Salary +10%", s2: "Buy a car"]
        XCTAssertEqual(ScenarioCombinator.overlapNotice(overlap, scenarioNames: names, categoryNames: [groceriesId: "Groceries"]),
                       "Buy a car and Salary +10% both change 'Groceries'; the later one is used")
        XCTAssertEqual(ScenarioCombinator.overlapNotice(overlap, scenarioNames: names, categoryNames: [:]),
                       "Buy a car and Salary +10% both change an item; the later one is used")
    }
}
