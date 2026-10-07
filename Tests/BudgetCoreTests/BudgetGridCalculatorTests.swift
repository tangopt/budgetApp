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
        let total = BudgetGridCalculator.categoryTotal(category: rent, period: period, transactions: transactions, forecastEntries: [], forecastGroups: [], exceptions: [])
        XCTAssertEqual(total, -280000)
    }

    func testProjectedPeriodUsesConfirmedForecastTotal() {
        let rent = Category(id: 1, name: "Rent", type: .expense)
        let period = PayPeriod(startDate: date(2026, 9, 26), endDate: date(2026, 10, 25), type: .projected)
        let group = ForecastGroup(id: 1, name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)
        let entry = ForecastEntry(id: 1, groupId: 1, categoryId: 1, amountMinorUnits: -280000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .auto, note: nil)
        let total = BudgetGridCalculator.categoryTotal(category: rent, period: period, transactions: [], forecastEntries: [entry], forecastGroups: [group], exceptions: [])
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
        let summary = BudgetGridCalculator.periodSummary(period: period, categories: [income, rent, isaTransfer], transactions: transactions, forecastEntries: [], forecastGroups: [], exceptions: [])
        XCTAssertEqual(summary.incomeMinorUnits, 280000)
        XCTAssertEqual(summary.expensesMinorUnits, 180000)
        XCTAssertEqual(summary.transfersMinorUnits, 50000)
        XCTAssertEqual(summary.moneyRemainingMinorUnits, 50000)
    }

    // I1: money coming IN on a transfer category (e.g. money moved back from savings,
    // or a refund routed through a transfer category) must increase Money Remaining.
    // With abs() it was counted as a further outflow.
    func testInboundTransferReducesTransfersAndIncreasesMoneyRemaining() {
        let income = Category(id: 1, name: "Income", type: .income)
        let isaTransfer = Category(id: 3, name: "Transfer: Lloyds Investment ISA", type: .transfer)
        let groceries = Category(id: 4, name: "Groceries", type: .expense)
        let period = PayPeriod(startDate: date(2026, 6, 26), endDate: date(2026, 7, 25), type: .actual)
        let transactions = [
            Transaction(id: 1, importBatchId: 1, accountId: 1, date: date(2026, 6, 26), rawDescription: "SALARY", amountMinorUnits: 280000, categoryId: 1, status: .confirmed, categorizedBy: .manual, fingerprint: "a"),
            Transaction(id: 2, importBatchId: 1, accountId: 1, date: date(2026, 6, 29), rawDescription: "ISA OUT", amountMinorUnits: -50000, categoryId: 3, status: .confirmed, categorizedBy: .manual, fingerprint: "b"),
            Transaction(id: 3, importBatchId: 1, accountId: 1, date: date(2026, 7, 2), rawDescription: "ISA BACK", amountMinorUnits: 80000, categoryId: 3, status: .confirmed, categorizedBy: .manual, fingerprint: "c"),
            Transaction(id: 4, importBatchId: 1, accountId: 1, date: date(2026, 7, 3), rawDescription: "SAINSBURYS", amountMinorUnits: -10000, categoryId: 4, status: .confirmed, categorizedBy: .manual, fingerprint: "d"),
            Transaction(id: 5, importBatchId: 1, accountId: 1, date: date(2026, 7, 4), rawDescription: "SAINSBURYS REFUND", amountMinorUnits: 2500, categoryId: 4, status: .confirmed, categorizedBy: .manual, fingerprint: "e")
        ]
        let summary = BudgetGridCalculator.periodSummary(period: period, categories: [income, isaTransfer, groceries], transactions: transactions, forecastEntries: [], forecastGroups: [], exceptions: [])
        XCTAssertEqual(summary.transfersMinorUnits, -30000) // net £300 came back in
        XCTAssertEqual(summary.expensesMinorUnits, 7500)    // refund offsets spend
        XCTAssertEqual(summary.moneyRemainingMinorUnits, 280000 - 7500 + 30000)
    }
}

final class BudgetGridCalculatorCalendarModeTests: XCTestCase {
    func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func testPayMonthTotalsWithoutSalariesGroupByCalendarMonth() {
        let transactions = [
            Transaction(id: 1, importBatchId: 1, accountId: 1, date: date(2026, 3, 16), rawDescription: "Rent", amountMinorUnits: -280000, categoryId: 1, status: .confirmed, categorizedBy: .manual, fingerprint: "a"),
            Transaction(id: 2, importBatchId: 1, accountId: 1, date: date(2026, 4, 16), rawDescription: "Rent", amountMinorUnits: -280000, categoryId: 1, status: .confirmed, categorizedBy: .manual, fingerprint: "b"),
            Transaction(id: 3, importBatchId: 1, accountId: 1, date: date(2026, 3, 20), rawDescription: "Rent2", amountMinorUnits: -1000, categoryId: 1, status: .confirmed, categorizedBy: .manual, fingerprint: "c")
        ]
        let lookup = PayMonthTotals.lookup(transactions: transactions, calendar: PayCalendar(salaryDates: [], manualCloses: [], today: date(2026, 10, 5)))
        XCTAssertEqual(lookup[1]?[2026]?[3], -281000)
        XCTAssertEqual(lookup[1]?[2026]?[4], -280000)
    }

    func testPayMonthTotalsIgnoreUnconfirmedAndUncategorized() {
        let transactions = [
            Transaction(id: 1, importBatchId: 1, accountId: 1, date: date(2026, 3, 16), rawDescription: "Rent", amountMinorUnits: -280000, categoryId: 1, status: .pendingReview, categorizedBy: .none, fingerprint: "a"),
            Transaction(id: 2, importBatchId: 1, accountId: 1, date: date(2026, 3, 16), rawDescription: "X", amountMinorUnits: -500, categoryId: nil, status: .confirmed, categorizedBy: .none, fingerprint: "b")
        ]
        let lookup = PayMonthTotals.lookup(transactions: transactions, calendar: PayCalendar(salaryDates: [], manualCloses: [], today: date(2026, 10, 5)))
        XCTAssertTrue(lookup.isEmpty)
    }

    func testYearsWithDataReturnsAscendingDistinctYears() {
        let transactions = [
            Transaction(id: 1, importBatchId: 1, accountId: 1, date: date(2025, 6, 1), rawDescription: "X", amountMinorUnits: -100, categoryId: 1, status: .confirmed, categorizedBy: .manual, fingerprint: "a"),
            Transaction(id: 2, importBatchId: 1, accountId: 1, date: date(2023, 1, 1), rawDescription: "X", amountMinorUnits: -100, categoryId: 1, status: .confirmed, categorizedBy: .manual, fingerprint: "b"),
            Transaction(id: 3, importBatchId: 1, accountId: 1, date: date(2025, 12, 1), rawDescription: "X", amountMinorUnits: -100, categoryId: 1, status: .confirmed, categorizedBy: .manual, fingerprint: "c")
        ]
        XCTAssertEqual(BudgetGridCalculator.yearsWithData(transactions: transactions, calendar: PayCalendar(salaryDates: [], manualCloses: [], today: date(2026, 10, 5))), [2023, 2025])
    }

    func testYearsWithDataFollowPayMonths() {
        // December's salary on the 15th: a transaction on 20 Dec 2025 is in January 2026's pay month.
        let calendar = PayCalendar(salaryDates: [date(2025, 11, 15), date(2025, 12, 15)], manualCloses: [], today: date(2026, 10, 5))
        let transactions = [
            Transaction(id: 1, importBatchId: 1, accountId: 1, date: date(2025, 12, 10), rawDescription: "X", amountMinorUnits: -100, categoryId: 1, status: .confirmed, categorizedBy: .manual, fingerprint: "a"),
            Transaction(id: 2, importBatchId: 1, accountId: 1, date: date(2025, 12, 20), rawDescription: "X", amountMinorUnits: -100, categoryId: 1, status: .confirmed, categorizedBy: .manual, fingerprint: "b")
        ]
        XCTAssertEqual(BudgetGridCalculator.yearsWithData(transactions: transactions, calendar: calendar), [2025, 2026])
        XCTAssertEqual(BudgetGridCalculator.yearsWithData(transactions: [transactions[1]], calendar: calendar), [2026])
    }
}
