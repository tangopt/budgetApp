// Tests/BudgetCoreTests/ForecastCalculatorTests.swift
import XCTest
@testable import BudgetCore

final class ForecastCalculatorTests: XCTestCase {
    func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func testConfirmedTotalIncludesAutoAndManualAndConfirmedButNotHypothetical() {
        let period = PayPeriod(startDate: date(2026, 8, 26), endDate: date(2026, 9, 25), type: .projected)
        let groups = [ForecastGroup(id: 1, name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)]
        let entries = [
            ForecastEntry(id: 1, groupId: 1, categoryId: 10, amountMinorUnits: -280000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .auto, note: nil),
            ForecastEntry(id: 2, groupId: 1, categoryId: 10, amountMinorUnits: -5000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .hypothetical, note: nil)
        ]
        let confirmed = ForecastCalculator.confirmedTotal(categoryId: 10, period: period, entries: entries, groups: groups, exceptions: [])
        XCTAssertEqual(confirmed, -280000)
    }

    func testPreviewTotalAddsSelectedScenarioHypotheticals() {
        let period = PayPeriod(startDate: date(2026, 8, 26), endDate: date(2026, 9, 25), type: .projected)
        let groups = [ForecastGroup(id: 1, name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)]
        let entries = [
            ForecastEntry(id: 1, groupId: 1, categoryId: 10, amountMinorUnits: -280000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .auto, note: nil),
            ForecastEntry(id: 2, groupId: 1, categoryId: 10, amountMinorUnits: -5000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .hypothetical, note: nil)
        ]
        let preview = ForecastCalculator.previewTotal(categoryId: 10, period: period, entries: entries, groups: groups, selectedScenarioGroupId: 1, exceptions: [])
        XCTAssertEqual(preview, -285000)
    }

    func testPreviewTotalExcludesHypotheticalsFromUnselectedScenario() {
        let period = PayPeriod(startDate: date(2026, 8, 26), endDate: date(2026, 9, 25), type: .projected)
        let groups = [
            ForecastGroup(id: 1, name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true),
            ForecastGroup(id: 2, name: "New car", note: nil, isEnabled: true, isSystemManaged: false)
        ]
        let entries = [
            ForecastEntry(id: 1, groupId: 1, categoryId: 10, amountMinorUnits: -280000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .auto, note: nil),
            // This scenario's group (id 2) is enabled, but it isn't the *selected* one (id 1 is selected below) — its hypothetical must not count.
            ForecastEntry(id: 2, groupId: 2, categoryId: 10, amountMinorUnits: -35000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .hypothetical, note: nil)
        ]
        let preview = ForecastCalculator.previewTotal(categoryId: 10, period: period, entries: entries, groups: groups, selectedScenarioGroupId: 1, exceptions: [])
        XCTAssertEqual(preview, -280000) // only the auto entry — group 2's hypothetical is excluded
    }

    func testPreviewTotalWithNoSelectionExcludesAllHypotheticals() {
        let period = PayPeriod(startDate: date(2026, 8, 26), endDate: date(2026, 9, 25), type: .projected)
        let groups = [ForecastGroup(id: 1, name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)]
        let entries = [
            ForecastEntry(id: 1, groupId: 1, categoryId: 10, amountMinorUnits: -280000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .auto, note: nil),
            ForecastEntry(id: 2, groupId: 1, categoryId: 10, amountMinorUnits: -5000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .hypothetical, note: nil)
        ]
        let preview = ForecastCalculator.previewTotal(categoryId: 10, period: period, entries: entries, groups: groups, selectedScenarioGroupId: nil, exceptions: [])
        XCTAssertEqual(preview, -280000)
    }

    func testDisabledGroupExcludesAllItsEntriesRegardlessOfEntryToggle() {
        let period = PayPeriod(startDate: date(2026, 8, 26), endDate: date(2026, 9, 25), type: .projected)
        let groups = [ForecastGroup(id: 2, name: "New car", note: nil, isEnabled: false, isSystemManaged: false)]
        let entries = [
            ForecastEntry(id: 3, groupId: 2, categoryId: 20, amountMinorUnits: -30000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .confirmed, note: nil)
        ]
        XCTAssertEqual(ForecastCalculator.confirmedTotal(categoryId: 20, period: period, entries: entries, groups: groups, exceptions: []), 0)
    }

    func testDisabledIndividualEntryIsExcludedEvenIfGroupEnabled() {
        let period = PayPeriod(startDate: date(2026, 8, 26), endDate: date(2026, 9, 25), type: .projected)
        let groups = [ForecastGroup(id: 1, name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)]
        let entries = [
            ForecastEntry(id: 1, groupId: 1, categoryId: 10, amountMinorUnits: -280000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: false, status: .auto, note: nil)
        ]
        XCTAssertEqual(ForecastCalculator.confirmedTotal(categoryId: 10, period: period, entries: entries, groups: groups, exceptions: []), 0)
    }

    func testConfirmedNetWorthImpactSumsIncomeMinusExpensesExcludingTransfers() {
        let period = PayPeriod(startDate: date(2026, 3, 1), endDate: date(2026, 3, 31), type: .projected)
        let income = Category(id: 1, name: "Income", type: .income)
        let rent = Category(id: 2, name: "Rent", type: .expense)
        let isaTransfer = Category(id: 3, name: "Transfer: ISA", type: .transfer)
        let group = ForecastGroup(id: 1, name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)
        let entries = [
            ForecastEntry(id: 1, groupId: 1, categoryId: 1, amountMinorUnits: 280000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 26), endDate: nil, isEnabled: true, status: .auto, note: nil),
            ForecastEntry(id: 2, groupId: 1, categoryId: 2, amountMinorUnits: -180000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 26), endDate: nil, isEnabled: true, status: .auto, note: nil),
            ForecastEntry(id: 3, groupId: 1, categoryId: 3, amountMinorUnits: -50000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 26), endDate: nil, isEnabled: true, status: .auto, note: nil)
        ]
        let impact = ForecastCalculator.confirmedNetWorthImpact(period: period, categories: [income, rent, isaTransfer], entries: entries, groups: [group], exceptions: [])
        XCTAssertEqual(impact, 280000 - 180000) // the -50000 transfer is excluded
    }

    func testConfirmedNetWorthImpactExcludesHypotheticalEntries() {
        let period = PayPeriod(startDate: date(2026, 3, 1), endDate: date(2026, 3, 31), type: .projected)
        let groceries = Category(id: 1, name: "Groceries", type: .expense)
        let group = ForecastGroup(id: 1, name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)
        let entries = [
            ForecastEntry(id: 1, groupId: 1, categoryId: 1, amountMinorUnits: -20000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 1), endDate: nil, isEnabled: true, status: .auto, note: nil),
            ForecastEntry(id: 2, groupId: 1, categoryId: 1, amountMinorUnits: -5000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 1), endDate: nil, isEnabled: true, status: .hypothetical, note: nil)
        ]
        let impact = ForecastCalculator.confirmedNetWorthImpact(period: period, categories: [groceries], entries: entries, groups: [group], exceptions: [])
        XCTAssertEqual(impact, -20000)
    }

    func testConfirmedNetWorthImpactSkipsCategoriesWithNoId() {
        let period = PayPeriod(startDate: date(2026, 3, 1), endDate: date(2026, 3, 31), type: .projected)
        let unsaved = Category(id: nil, name: "Draft", type: .expense)
        let impact = ForecastCalculator.confirmedNetWorthImpact(period: period, categories: [unsaved], entries: [], groups: [], exceptions: [])
        XCTAssertEqual(impact, 0)
    }

    func testPreviewNetWorthDeltaSumsSelectedScenarioIncomeMinusExpensesExcludingTransfers() {
        let period = PayPeriod(startDate: date(2026, 3, 1), endDate: date(2026, 3, 31), type: .projected)
        let salary = Category(id: 1, name: "Bonus", type: .income)
        let carPayment = Category(id: 2, name: "Car Payments", type: .expense)
        let transfer = Category(id: 3, name: "Transfer: ISA", type: .transfer)
        let groups = [ForecastGroup(id: 2, name: "New car", note: nil, isEnabled: true, isSystemManaged: false)]
        let entries = [
            ForecastEntry(id: 1, groupId: 2, categoryId: 1, amountMinorUnits: 100000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 1), endDate: nil, isEnabled: true, status: .hypothetical, note: nil),
            ForecastEntry(id: 2, groupId: 2, categoryId: 2, amountMinorUnits: -35000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 1), endDate: nil, isEnabled: true, status: .hypothetical, note: nil),
            ForecastEntry(id: 3, groupId: 2, categoryId: 3, amountMinorUnits: -20000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 1), endDate: nil, isEnabled: true, status: .hypothetical, note: nil)
        ]
        let delta = ForecastCalculator.previewNetWorthDelta(period: period, categories: [salary, carPayment, transfer], entries: entries, groups: groups, selectedScenarioGroupId: 2, exceptions: [])
        XCTAssertEqual(delta, 100000 - 35000) // transfer excluded; delta is preview minus confirmed (0, nothing confirmed here)
    }

    func testPreviewNetWorthDeltaIsZeroWithNoSelection() {
        let period = PayPeriod(startDate: date(2026, 3, 1), endDate: date(2026, 3, 31), type: .projected)
        let carPayment = Category(id: 2, name: "Car Payments", type: .expense)
        let groups = [ForecastGroup(id: 2, name: "New car", note: nil, isEnabled: true, isSystemManaged: false)]
        let entries = [
            ForecastEntry(id: 2, groupId: 2, categoryId: 2, amountMinorUnits: -35000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 1), endDate: nil, isEnabled: true, status: .hypothetical, note: nil)
        ]
        let delta = ForecastCalculator.previewNetWorthDelta(period: period, categories: [carPayment], entries: entries, groups: groups, selectedScenarioGroupId: nil, exceptions: [])
        XCTAssertEqual(delta, 0)
    }

    func testConfirmedEntriesExcludesHypotheticalDisabledAndDisabledGroupEntries() {
        let groups = [
            ForecastGroup(id: 1, name: "On", note: nil, isEnabled: true, isSystemManaged: false),
            ForecastGroup(id: 2, name: "Off", note: nil, isEnabled: false, isSystemManaged: false)
        ]
        func entry(_ id: Int64, group: Int64, status: ForecastEntryStatus, enabled: Bool = true) -> ForecastEntry {
            ForecastEntry(id: id, groupId: group, categoryId: 10, amountMinorUnits: -100, frequency: .monthly, interval: 1, startDate: date(2026, 1, 1), endDate: nil, isEnabled: enabled, status: status, note: nil)
        }
        let entries = [
            entry(1, group: 1, status: .auto), entry(2, group: 1, status: .manual), entry(3, group: 1, status: .confirmed),
            entry(4, group: 1, status: .hypothetical), entry(5, group: 1, status: .auto, enabled: false), entry(6, group: 2, status: .auto)
        ]
        XCTAssertEqual(ForecastCalculator.confirmedEntries(entries: entries, groups: groups).map(\.id), [1, 2, 3])
    }

    // MARK: exceptions

    private func utcDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testConfirmedTotalAppliesExceptionsAndRefilesCategory() {
        let oct = PayPeriod(startDate: utcDate(2026, 10, 1), endDate: utcDate(2026, 10, 31), type: .projected)
        let groups = [ForecastGroup(id: 1, name: "G", note: nil, isEnabled: true, isSystemManaged: false)]
        let entries = [ForecastEntry(id: 1, groupId: 1, categoryId: 10, amountMinorUnits: -10000, frequency: .monthly, interval: 1, startDate: utcDate(2026, 6, 15), endDate: nil, isEnabled: true, status: .manual, note: nil)]
        XCTAssertEqual(ForecastCalculator.confirmedTotal(categoryId: 10, period: oct, entries: entries, groups: groups, exceptions: []), -10000)
        let amount = PlannedOccurrenceException(entryId: 1, originalDate: utcDate(2026, 10, 15), amountMinorUnits: -4000)
        XCTAssertEqual(ForecastCalculator.confirmedTotal(categoryId: 10, period: oct, entries: entries, groups: groups, exceptions: [amount]), -4000)
        let skip = PlannedOccurrenceException(entryId: 1, originalDate: utcDate(2026, 10, 15), isSkipped: true)
        XCTAssertEqual(ForecastCalculator.confirmedTotal(categoryId: 10, period: oct, entries: entries, groups: groups, exceptions: [skip]), 0)
        let refile = PlannedOccurrenceException(entryId: 1, originalDate: utcDate(2026, 10, 15), categoryId: 20)
        XCTAssertEqual(ForecastCalculator.confirmedTotal(categoryId: 10, period: oct, entries: entries, groups: groups, exceptions: [refile]), 0)
        XCTAssertEqual(ForecastCalculator.confirmedTotal(categoryId: 20, period: oct, entries: entries, groups: groups, exceptions: [refile]), -10000)
    }

    func testNetWorthImpactAppliesExceptions() {
        let oct = PayPeriod(startDate: utcDate(2026, 10, 1), endDate: utcDate(2026, 10, 31), type: .projected)
        let groups = [ForecastGroup(id: 1, name: "G", note: nil, isEnabled: true, isSystemManaged: false)]
        let cats = [Category(id: 10, name: "Rent", type: .expense), Category(id: 20, name: "Isa", type: .transfer)]
        let entries = [ForecastEntry(id: 1, groupId: 1, categoryId: 10, amountMinorUnits: -10000, frequency: .monthly, interval: 1, startDate: utcDate(2026, 6, 15), endDate: nil, isEnabled: true, status: .manual, note: nil)]
        XCTAssertEqual(ForecastCalculator.confirmedNetWorthImpact(period: oct, categories: cats, entries: entries, groups: groups, exceptions: []), -10000)
        let amount = PlannedOccurrenceException(entryId: 1, originalDate: utcDate(2026, 10, 15), amountMinorUnits: -4000)
        XCTAssertEqual(ForecastCalculator.confirmedNetWorthImpact(period: oct, categories: cats, entries: entries, groups: groups, exceptions: [amount]), -4000)
        // Re-filed into a transfer category: no longer a net-worth effect.
        let toTransfer = PlannedOccurrenceException(entryId: 1, originalDate: utcDate(2026, 10, 15), categoryId: 20)
        XCTAssertEqual(ForecastCalculator.confirmedNetWorthImpact(period: oct, categories: cats, entries: entries, groups: groups, exceptions: [toTransfer]), 0)
        XCTAssertEqual(ForecastCalculator.previewNetWorthDelta(period: oct, categories: cats, entries: entries, groups: groups, selectedScenarioGroupId: nil, exceptions: [amount]), 0)
    }

    func testPreviewTotalWithScenarioAndExceptionsOnConfirmedEntries() {
        let oct = PayPeriod(startDate: utcDate(2026, 10, 1), endDate: utcDate(2026, 10, 31), type: .projected)
        let groups = [ForecastGroup(id: 1, name: "G", note: nil, isEnabled: true, isSystemManaged: false)]
        let entries = [
            ForecastEntry(id: 1, groupId: 1, categoryId: 10, amountMinorUnits: -10000, frequency: .monthly, interval: 1, startDate: utcDate(2026, 6, 15), endDate: nil, isEnabled: true, status: .manual, note: nil),
            ForecastEntry(id: 2, groupId: 1, categoryId: 10, amountMinorUnits: -3000, frequency: .monthly, interval: 1, startDate: utcDate(2026, 6, 20), endDate: nil, isEnabled: true, status: .hypothetical, note: nil)
        ]
        let amount = PlannedOccurrenceException(entryId: 1, originalDate: utcDate(2026, 10, 15), amountMinorUnits: -4000)
        XCTAssertEqual(ForecastCalculator.previewTotal(categoryId: 10, period: oct, entries: entries, groups: groups, selectedScenarioGroupId: 1, exceptions: [amount]), -7000)
        let refile = PlannedOccurrenceException(entryId: 1, originalDate: utcDate(2026, 10, 15), categoryId: 20)
        XCTAssertEqual(ForecastCalculator.previewTotal(categoryId: 10, period: oct, entries: entries, groups: groups, selectedScenarioGroupId: 1, exceptions: [refile]), -3000)
    }

    func testConfirmedTotalsByCategoryMatchesConfirmedTotal() {
        let oct = PayPeriod(startDate: utcDate(2026, 10, 1), endDate: utcDate(2026, 10, 31), type: .projected)
        let groups = [ForecastGroup(id: 1, name: "G", note: nil, isEnabled: true, isSystemManaged: false),
                      ForecastGroup(id: 2, name: "Off", note: nil, isEnabled: false, isSystemManaged: false)]
        let entries = [
            ForecastEntry(id: 1, groupId: 1, categoryId: 10, amountMinorUnits: -10000, frequency: .monthly, interval: 1, startDate: utcDate(2026, 6, 15), endDate: nil, isEnabled: true, status: .manual, note: nil),
            ForecastEntry(id: 2, groupId: 1, categoryId: 10, amountMinorUnits: -1000, frequency: .weekly, interval: 1, startDate: utcDate(2026, 10, 1), endDate: nil, isEnabled: true, status: .manual, note: nil),
            ForecastEntry(id: 3, groupId: 1, categoryId: 30, amountMinorUnits: 300000, frequency: .monthly, interval: 1, startDate: utcDate(2026, 1, 25), endDate: nil, isEnabled: true, status: .confirmed, note: nil),
            ForecastEntry(id: 4, groupId: 1, categoryId: 30, amountMinorUnits: 5000, frequency: .monthly, interval: 1, startDate: utcDate(2026, 1, 25), endDate: nil, isEnabled: true, status: .hypothetical, note: nil),
            ForecastEntry(id: 5, groupId: 2, categoryId: 30, amountMinorUnits: 7000, frequency: .monthly, interval: 1, startDate: utcDate(2026, 1, 25), endDate: nil, isEnabled: true, status: .manual, note: nil)
        ]
        let exceptions = [
            PlannedOccurrenceException(entryId: 1, originalDate: utcDate(2026, 10, 15), categoryId: 20),
            PlannedOccurrenceException(entryId: 2, originalDate: utcDate(2026, 10, 8), isSkipped: true)
        ]
        let totals = ForecastCalculator.confirmedTotalsByCategory(period: oct, entries: entries, groups: groups, exceptions: exceptions)
        XCTAssertEqual(totals, [10: -4000, 20: -10000, 30: 300000])
        for id: Int64 in [10, 20, 30, 40] {
            XCTAssertEqual(totals[id] ?? 0, ForecastCalculator.confirmedTotal(categoryId: id, period: oct, entries: entries, groups: groups, exceptions: exceptions))
        }
    }
}
