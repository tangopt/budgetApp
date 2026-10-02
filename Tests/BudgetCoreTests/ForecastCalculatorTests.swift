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
        let confirmed = ForecastCalculator.confirmedTotal(categoryId: 10, period: period, entries: entries, groups: groups)
        XCTAssertEqual(confirmed, -280000)
    }

    func testPreviewTotalAddsSelectedScenarioHypotheticals() {
        let period = PayPeriod(startDate: date(2026, 8, 26), endDate: date(2026, 9, 25), type: .projected)
        let groups = [ForecastGroup(id: 1, name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)]
        let entries = [
            ForecastEntry(id: 1, groupId: 1, categoryId: 10, amountMinorUnits: -280000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .auto, note: nil),
            ForecastEntry(id: 2, groupId: 1, categoryId: 10, amountMinorUnits: -5000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .hypothetical, note: nil)
        ]
        let preview = ForecastCalculator.previewTotal(categoryId: 10, period: period, entries: entries, groups: groups, selectedScenarioGroupId: 1)
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
        let preview = ForecastCalculator.previewTotal(categoryId: 10, period: period, entries: entries, groups: groups, selectedScenarioGroupId: 1)
        XCTAssertEqual(preview, -280000) // only the auto entry — group 2's hypothetical is excluded
    }

    func testPreviewTotalWithNoSelectionExcludesAllHypotheticals() {
        let period = PayPeriod(startDate: date(2026, 8, 26), endDate: date(2026, 9, 25), type: .projected)
        let groups = [ForecastGroup(id: 1, name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)]
        let entries = [
            ForecastEntry(id: 1, groupId: 1, categoryId: 10, amountMinorUnits: -280000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .auto, note: nil),
            ForecastEntry(id: 2, groupId: 1, categoryId: 10, amountMinorUnits: -5000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .hypothetical, note: nil)
        ]
        let preview = ForecastCalculator.previewTotal(categoryId: 10, period: period, entries: entries, groups: groups, selectedScenarioGroupId: nil)
        XCTAssertEqual(preview, -280000)
    }

    func testDisabledGroupExcludesAllItsEntriesRegardlessOfEntryToggle() {
        let period = PayPeriod(startDate: date(2026, 8, 26), endDate: date(2026, 9, 25), type: .projected)
        let groups = [ForecastGroup(id: 2, name: "New car", note: nil, isEnabled: false, isSystemManaged: false)]
        let entries = [
            ForecastEntry(id: 3, groupId: 2, categoryId: 20, amountMinorUnits: -30000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .confirmed, note: nil)
        ]
        XCTAssertEqual(ForecastCalculator.confirmedTotal(categoryId: 20, period: period, entries: entries, groups: groups), 0)
    }

    func testDisabledIndividualEntryIsExcludedEvenIfGroupEnabled() {
        let period = PayPeriod(startDate: date(2026, 8, 26), endDate: date(2026, 9, 25), type: .projected)
        let groups = [ForecastGroup(id: 1, name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)]
        let entries = [
            ForecastEntry(id: 1, groupId: 1, categoryId: 10, amountMinorUnits: -280000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: false, status: .auto, note: nil)
        ]
        XCTAssertEqual(ForecastCalculator.confirmedTotal(categoryId: 10, period: period, entries: entries, groups: groups), 0)
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
        let impact = ForecastCalculator.confirmedNetWorthImpact(period: period, categories: [income, rent, isaTransfer], entries: entries, groups: [group])
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
        let impact = ForecastCalculator.confirmedNetWorthImpact(period: period, categories: [groceries], entries: entries, groups: [group])
        XCTAssertEqual(impact, -20000)
    }

    func testConfirmedNetWorthImpactSkipsCategoriesWithNoId() {
        let period = PayPeriod(startDate: date(2026, 3, 1), endDate: date(2026, 3, 31), type: .projected)
        let unsaved = Category(id: nil, name: "Draft", type: .expense)
        let impact = ForecastCalculator.confirmedNetWorthImpact(period: period, categories: [unsaved], entries: [], groups: [])
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
        let delta = ForecastCalculator.previewNetWorthDelta(period: period, categories: [salary, carPayment, transfer], entries: entries, groups: groups, selectedScenarioGroupId: 2)
        XCTAssertEqual(delta, 100000 - 35000) // transfer excluded; delta is preview minus confirmed (0, nothing confirmed here)
    }

    func testPreviewNetWorthDeltaIsZeroWithNoSelection() {
        let period = PayPeriod(startDate: date(2026, 3, 1), endDate: date(2026, 3, 31), type: .projected)
        let carPayment = Category(id: 2, name: "Car Payments", type: .expense)
        let groups = [ForecastGroup(id: 2, name: "New car", note: nil, isEnabled: true, isSystemManaged: false)]
        let entries = [
            ForecastEntry(id: 2, groupId: 2, categoryId: 2, amountMinorUnits: -35000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 1), endDate: nil, isEnabled: true, status: .hypothetical, note: nil)
        ]
        let delta = ForecastCalculator.previewNetWorthDelta(period: period, categories: [carPayment], entries: entries, groups: groups, selectedScenarioGroupId: nil)
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
}
