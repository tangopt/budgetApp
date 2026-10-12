import XCTest
@testable import BudgetCore
import struct BudgetCore.Transaction

final class CategoryStatsTests: XCTestCase {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private func s(_ y: Int, _ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: day, hour: 12))! }
    /// No salaries: pay months are calendar months. Today is 12 Oct 2026, so the window is
    /// Oct 2025 – Sep 2026.
    private var calendar: PayCalendar { PayCalendar(salaryDates: [], manualCloses: [], today: s(2026, 10, 12)) }

    private func txn(_ date: Date, _ amount: Int, cat: Int64?, status: TransactionStatus = .confirmed) -> Transaction {
        Transaction(importBatchId: 1, accountId: 1, date: date, rawDescription: "t", amountMinorUnits: amount, categoryId: cat, status: status, categorizedBy: .manual, fingerprint: "f")
    }

    func testAveragesTheLastTwelveCompletePayMonths() {
        var transactions: [Transaction] = []
        for month in 1...12 { transactions.append(txn(s(month >= 10 ? 2025 : 2026, month, 5), -1000, cat: 1)) }
        transactions.append(txn(s(2025, 9, 5), -99_999, cat: 1))   // before the window
        transactions.append(txn(s(2026, 10, 5), -99_999, cat: 1))  // the current, incomplete month
        transactions.append(txn(s(2026, 3, 5), -99_999, cat: 1, status: .pendingReview))
        transactions.append(txn(s(2026, 3, 5), -99_999, cat: nil))
        XCTAssertEqual(CategoryStats.monthlyAverages(transactions: transactions, calendar: calendar), [1: -1000])
    }

    func testAYoungerCategoryAveragesOverTheMonthsSinceItsFirstTransaction() {
        // First ever transaction in Jul 2026: Jul, Aug, Sep → 3 months.
        let transactions = [txn(s(2026, 7, 2), -300, cat: 2), txn(s(2026, 9, 20), -600, cat: 2)]
        XCTAssertEqual(CategoryStats.monthlyAverages(transactions: transactions, calendar: calendar), [2: -300])
    }

    func testOlderHistoryKeepsTheFullTwelveMonthDivisor() {
        let transactions = [txn(s(2024, 1, 2), -5000, cat: 3), txn(s(2026, 9, 20), -1200, cat: 3)]
        XCTAssertEqual(CategoryStats.monthlyAverages(transactions: transactions, calendar: calendar), [3: -100])
    }

    func testNoActualsInTheWindowGivesNoAverage() {
        let transactions = [txn(s(2024, 1, 2), -5000, cat: 4), txn(s(2026, 10, 2), -5000, cat: 4)]
        XCTAssertEqual(CategoryStats.monthlyAverages(transactions: transactions, calendar: calendar), [:])
    }

    func testRoundsToTheNearestMinorUnit() {
        let transactions = [txn(s(2026, 8, 2), -100, cat: 5), txn(s(2026, 9, 2), -101, cat: 5)]
        XCTAssertEqual(CategoryStats.monthlyAverages(transactions: transactions, calendar: calendar), [5: -101])
    }
}
