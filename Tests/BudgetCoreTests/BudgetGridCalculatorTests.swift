// Tests/BudgetCoreTests/BudgetGridCalculatorTests.swift
import XCTest
@testable import BudgetCore

final class BudgetGridCalculatorTests: XCTestCase {
    func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func testActualPeriodSumsConfirmedTransactions() {
        let rent = Category(id: 1, name: "Rent", type: .expense)
        let period = PayPeriod(startDate: date(2026, 6, 26), endDate: date(2026, 7, 25), type: .actual)
        let transactions = [
            Transaction(id: 1, importBatchId: 1, accountId: 1, date: date(2026, 6, 28), rawDescription: "RENT", amountMinorUnits: -280000, categoryId: 1, status: .confirmed, categorizedBy: .manual, fingerprint: "a")
        ]
        let total = BudgetGridCalculator.categoryTotal(category: rent, period: period, transactions: transactions, forecastEntries: [], forecastGroups: [])
        XCTAssertEqual(total, -280000)
    }

    func testProjectedPeriodUsesConfirmedForecastTotal() {
        let rent = Category(id: 1, name: "Rent", type: .expense)
        let period = PayPeriod(startDate: date(2026, 9, 26), endDate: date(2026, 10, 25), type: .projected)
        let group = ForecastGroup(id: 1, name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)
        let entry = ForecastEntry(id: 1, groupId: 1, categoryId: 1, amountMinorUnits: -280000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .auto, note: nil)
        let total = BudgetGridCalculator.categoryTotal(category: rent, period: period, transactions: [], forecastEntries: [entry], forecastGroups: [group])
        XCTAssertEqual(total, -280000)
    }

    func testPeriodSummaryComputesIncomeExpensesTransfersAndRemaining() {
        let income = Category(id: 1, name: "Income", type: .income)
        let rent = Category(id: 2, name: "Rent", type: .expense)
        let isaTransfer = Category(id: 3, name: "Transfer: Lloyds Investment ISA", type: .transfer)
        let period = PayPeriod(startDate: date(2026, 6, 26), endDate: date(2026, 7, 25), type: .actual)
        let transactions = [
            Transaction(id: 1, importBatchId: 1, accountId: 1, date: date(2026, 6, 26), rawDescription: "SALARY", amountMinorUnits: 280000, categoryId: 1, status: .confirmed, categorizedBy: .manual, fingerprint: "a"),
            Transaction(id: 2, importBatchId: 1, accountId: 1, date: date(2026, 6, 28), rawDescription: "RENT", amountMinorUnits: -180000, categoryId: 2, status: .confirmed, categorizedBy: .manual, fingerprint: "b"),
            Transaction(id: 3, importBatchId: 1, accountId: 1, date: date(2026, 6, 29), rawDescription: "ISA", amountMinorUnits: -50000, categoryId: 3, status: .confirmed, categorizedBy: .manual, fingerprint: "c")
        ]
        let summary = BudgetGridCalculator.periodSummary(period: period, categories: [income, rent, isaTransfer], transactions: transactions, forecastEntries: [], forecastGroups: [])
        XCTAssertEqual(summary.incomeMinorUnits, 280000)
        XCTAssertEqual(summary.expensesMinorUnits, 180000)
        XCTAssertEqual(summary.transfersMinorUnits, 50000)
        XCTAssertEqual(summary.moneyRemainingMinorUnits, 50000)
    }
}
