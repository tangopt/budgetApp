// Tests/BudgetCoreTests/BudgetGridExporterTests.swift
import XCTest
@testable import BudgetCore

final class BudgetGridExporterTests: XCTestCase {
    func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func testExportsOnlyActualPeriodsAsCSV() {
        let rent = Category(id: 1, name: "Rent", type: .expense)
        let actualPeriod = PayPeriod(startDate: date(2026, 6, 26), endDate: date(2026, 7, 25), type: .actual)
        let projectedPeriod = PayPeriod(startDate: date(2026, 7, 26), endDate: date(2026, 8, 25), type: .projected)
        let transactions = [
            Transaction(id: 1, importBatchId: 1, accountId: 1, date: date(2026, 6, 28), rawDescription: "RENT", amountMinorUnits: -280000, categoryId: 1, status: .confirmed, categorizedBy: .manual, fingerprint: "a")
        ]
        let csv = BudgetGridExporter.export(categories: [rent], periods: [actualPeriod, projectedPeriod], transactions: transactions)
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines[0], "Category,2026-06-26")
        XCTAssertEqual(lines[1], "Rent,-2800.00")
    }
}
