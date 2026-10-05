// Tests/BudgetCoreTests/BudgetGridExporterTests.swift
import XCTest
@testable import BudgetCore

final class BudgetGridExporterTests: XCTestCase {
    func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func txn(_ id: Int64, _ date: Date, _ amount: Int, category: Int64, status: TransactionStatus = .confirmed) -> Transaction {
        Transaction(id: id, importBatchId: 1, accountId: 1, date: date, rawDescription: "T\(id)", amountMinorUnits: amount, categoryId: category, status: status, categorizedBy: .manual, fingerprint: "f\(id)")
    }

    /// Salaries on 15 Aug and 15 Sep 2026, July closed manually on 20 Jul, today 5 Oct.
    func calendar() -> PayCalendar {
        PayCalendar(salaryDates: [utc(2026, 8, 15), utc(2026, 9, 15)],
                    manualCloses: [PayMonthClose(year: 2026, month: 7, closeDate: utc(2026, 7, 20))],
                    today: utc(2026, 10, 5))
    }

    func testColumnsArePayMonthsOfTheGridYearsUpToTheCurrentMonth() {
        let csv = BudgetGridExporter.export(categories: [], transactions: [txn(1, utc(2026, 3, 1), -100, category: 1)], calendar: calendar())
        let header = csv.split(separator: "\n")[0]
        // October (16 Sep – 15 Oct) has started; November (from 16 Oct) hasn't.
        XCTAssertEqual(header, "Category,January 2026,February 2026,March 2026,April 2026,May 2026,June 2026,July 2026,August 2026,September 2026,October 2026")
    }

    func testValuesArePayMonthTotalsHonouringSalariesAndManualCloses() {
        let rent = Category(id: 1, name: "Rent", type: .expense)
        let food = Category(id: 2, name: "Food, drink", type: .expense)
        let transactions = [
            txn(1, utc(2026, 7, 18), -1_000, category: 1),  // July (closed manually on 20 Jul)
            txn(2, utc(2026, 7, 22), -2_000, category: 1),  // after the manual close → August
            txn(3, utc(2026, 8, 16), -280_000, category: 1), // day after the August salary → September
            txn(4, utc(2026, 9, 20), -500, category: 2),     // October, in progress
            txn(5, utc(2026, 9, 21), -999, category: 2, status: .pendingReview), // not confirmed: excluded
        ]
        let cal = calendar()
        let csv = BudgetGridExporter.export(categories: [rent, food], transactions: transactions, calendar: cal)
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[1], "Rent,0.00,0.00,0.00,0.00,0.00,0.00,-10.00,-20.00,-2800.00,0.00")
        XCTAssertEqual(lines[2], "\"Food, drink\",0.00,0.00,0.00,0.00,0.00,0.00,0.00,0.00,0.00,-5.00")

        // Same numbers as the grid's lookup.
        let lookup = PayMonthTotals.lookup(transactions: transactions, calendar: cal)
        XCTAssertEqual(lookup[1]?[2026]?[9], -280_000)
        XCTAssertEqual(BudgetGridExporter.export(categories: [rent, food], years: [2026], calendar: cal, monthTotals: lookup), csv)
    }
}
