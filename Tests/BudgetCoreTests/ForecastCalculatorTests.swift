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

    func testPreviewTotalAddsEnabledHypotheticals() {
        let period = PayPeriod(startDate: date(2026, 8, 26), endDate: date(2026, 9, 25), type: .projected)
        let groups = [ForecastGroup(id: 1, name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)]
        let entries = [
            ForecastEntry(id: 1, groupId: 1, categoryId: 10, amountMinorUnits: -280000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .auto, note: nil),
            ForecastEntry(id: 2, groupId: 1, categoryId: 10, amountMinorUnits: -5000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .hypothetical, note: nil)
        ]
        let preview = ForecastCalculator.previewTotal(categoryId: 10, period: period, entries: entries, groups: groups)
        XCTAssertEqual(preview, -285000)
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
}
