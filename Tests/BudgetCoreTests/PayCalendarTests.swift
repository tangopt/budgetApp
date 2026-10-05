import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category

final class PayCalendarTests: XCTestCase {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private func d(_ y: Int, _ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: day))! }
    private func s(_ y: Int, _ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: day, hour: 12))! }
    private func pm(_ y: Int, _ m: Int) -> PayMonth { PayMonth(year: y, month: m) }
    private func make(_ salaries: [Date], manual: [PayMonthClose] = [], today: Date? = nil) -> PayCalendar {
        PayCalendar(salaryDates: salaries, manualCloses: manual, today: today ?? d(2026, 10, 5))
    }

    func testRangeAndMonthContaining() {
        let c = make([d(2026, 9, 15), d(2026, 10, 15)])
        let r = c.range(of: pm(2026, 10))
        XCTAssertEqual(r.start, d(2026, 9, 16))
        XCTAssertEqual(r.end, d(2026, 10, 16).addingTimeInterval(-1))
        XCTAssertEqual(c.month(containing: s(2026, 9, 15)), pm(2026, 9))
        XCTAssertEqual(c.month(containing: s(2026, 9, 16)), pm(2026, 10))
        XCTAssertEqual(c.month(containing: s(2026, 10, 15)), pm(2026, 10))
        XCTAssertEqual(c.month(containing: s(2026, 10, 16)), pm(2026, 11))
    }

    func testProjection() {
        let c = make([d(2026, 2, 14)])
        XCTAssertEqual(c.closeDate(of: pm(2026, 3)), d(2026, 3, 14))
        let c2 = make([d(2026, 1, 31)])
        XCTAssertEqual(c2.closeDate(of: pm(2026, 2)), d(2026, 2, 28))
        XCTAssertEqual(c2.closeDate(of: pm(2028, 2)), d(2028, 2, 29))
    }

    func testMonthsBeforeFirstSalaryAndNoSalaries() {
        let c = make([d(2026, 5, 20)])
        XCTAssertEqual(c.closeDate(of: pm(2026, 3)), d(2026, 3, 20))
        let none = make([])
        let r = none.range(of: pm(2026, 3))
        XCTAssertEqual(r.start, d(2026, 3, 1))
        XCTAssertEqual(r.end, d(2026, 4, 1).addingTimeInterval(-1))
    }

    func testManualCloseForProjectedMonth() {
        let c = make([d(2026, 9, 15)], manual: [PayMonthClose(year: 2026, month: 10, closeDate: d(2026, 10, 10))])
        XCTAssertTrue(c.isClosed(pm(2026, 10)))
        XCTAssertEqual(c.closeSource(of: pm(2026, 10)), .manual)
        XCTAssertEqual(c.range(of: pm(2026, 11)).start, d(2026, 10, 11))
    }

    func testManualCloseOverridesSalary() {
        let c = make([d(2026, 10, 15)], manual: [PayMonthClose(year: 2026, month: 10, closeDate: d(2026, 10, 12))])
        XCTAssertEqual(c.closeSource(of: pm(2026, 10)), .manual)
        XCTAssertEqual(c.closeDate(of: pm(2026, 10)), d(2026, 10, 12))
    }

    func testIsClosedAndMonthClass() {
        let c = make([d(2026, 9, 15)])
        XCTAssertTrue(c.isClosed(pm(2026, 9)))
        XCTAssertFalse(c.isClosed(pm(2026, 10)))
        XCTAssertEqual(c.monthClass(pm(2026, 9)), .actual)
        XCTAssertEqual(c.monthClass(pm(2026, 10)), .blended)
        XCTAssertEqual(c.monthClass(pm(2026, 11)), .forecast)
        XCTAssertEqual(c.current, pm(2026, 10))

        let old = make([d(2026, 2, 14)])
        for m in 3...10 { XCTAssertEqual(old.monthClass(pm(2026, m)), .blended, "month \(m)") }
        XCTAssertEqual(old.monthClass(pm(2026, 11)), .forecast)
    }

    func testValidateClose() {
        let c = make([d(2026, 9, 15), d(2026, 12, 15)])
        // Oct starts 16 Sep.
        XCTAssertThrowsError(try c.validateClose(pm(2026, 10), on: d(2026, 9, 15))) {
            XCTAssertEqual($0 as? PayCalendarError, .invalidCloseDate)
        }
        // Dec is closed on 15 Dec, so Nov cannot close on/after it.
        XCTAssertThrowsError(try c.validateClose(pm(2026, 11), on: d(2026, 12, 15)))
        XCTAssertNoThrow(try c.validateClose(pm(2026, 11), on: d(2026, 11, 10)))
        XCTAssertNoThrow(try c.validateClose(pm(2026, 10), on: d(2026, 10, 10)))
    }

    func testCloseReopenAndLoad() throws {
        let m = try DatabaseManager(path: nil)
        try m.migrate()
        try m.dbQueue.write { db in
            var acct = Account(name: "A", currency: .gbp, kind: .cash, trackingMode: .manual); try acct.insert(db)
            var batch = ImportBatch(accountId: acct.id!, sourceFileName: "f", importedAt: d(2026, 9, 1)); try batch.insert(db)
            var income = Category(name: "Income", type: .income); try income.insert(db)
            var t = Transaction(importBatchId: batch.id!, accountId: acct.id!, date: d(2026, 9, 15), rawDescription: "SAL", amountMinorUnits: 300_000, categoryId: income.id, status: .confirmed, categorizedBy: .manual, fingerprint: "x")
            try t.insert(db)

            let today = d(2026, 10, 5)
            try PayCalendar.close(db: db, month: pm(2026, 10), on: d(2026, 10, 10), today: today)
            try PayCalendar.close(db: db, month: pm(2026, 10), on: d(2026, 10, 12), today: today)
            XCTAssertEqual(try PayMonthClose.fetchCount(db), 1)
            let loaded = try PayCalendar.load(db: db, today: today)
            XCTAssertEqual(loaded.closeSource(of: pm(2026, 9)), .salary)
            XCTAssertEqual(loaded.closeSource(of: pm(2026, 10)), .manual)
            XCTAssertEqual(loaded.closeDate(of: pm(2026, 10)), d(2026, 10, 12))
            XCTAssertThrowsError(try PayCalendar.close(db: db, month: pm(2026, 10), on: d(2026, 9, 1), today: today))
            try PayCalendar.reopen(db: db, month: pm(2026, 10))
            XCTAssertEqual(try PayMonthClose.fetchCount(db), 0)
        }
    }

    func testPayMonthTotals() {
        let c = make([d(2026, 9, 15), d(2026, 10, 15)])
        func txn(_ day: Date, _ amount: Int, cat: Int64?, status: TransactionStatus = .confirmed) -> Transaction {
            Transaction(importBatchId: 1, accountId: 1, date: day, rawDescription: "t", amountMinorUnits: amount, categoryId: cat, status: status, categorizedBy: .manual, fingerprint: "f")
        }
        let lookup = PayMonthTotals.lookup(transactions: [
            txn(s(2026, 10, 15), -100, cat: 7),
            txn(s(2026, 10, 16), -50, cat: 7),
            txn(s(2026, 10, 10), -999, cat: nil),
            txn(s(2026, 10, 10), -999, cat: 7, status: .pendingReview)
        ], calendar: c)
        XCTAssertEqual(lookup[7]?[2026]?[10], -100)
        XCTAssertEqual(lookup[7]?[2026]?[11], -50)
    }

    func testNearbySalaryCreditsCollapseToFirst() {
        let c = make([d(2026, 10, 10), d(2026, 10, 15)])
        XCTAssertEqual(c.closeDate(of: pm(2026, 10)), d(2026, 10, 10))
    }

    func testManualCloseBeyondProjectedNextMonthIsRejected() {
        let c = make([d(2026, 9, 15)])
        XCTAssertThrowsError(try c.validateClose(pm(2026, 10), on: d(2026, 11, 20))) {
            XCTAssertEqual($0 as? PayCalendarError, .invalidCloseDate)
        }
        XCTAssertNoThrow(try c.validateClose(pm(2026, 10), on: d(2026, 11, 14)))
        // Must be after close(M-1).
        XCTAssertThrowsError(try c.validateClose(pm(2026, 10), on: d(2026, 9, 15)))
    }

    func testOvertakenMonthIsEmpty() {
        let c = make([d(2026, 9, 15), d(2026, 11, 7)], manual: [PayMonthClose(year: 2026, month: 10, closeDate: d(2026, 11, 10))])
        XCTAssertEqual(c.closeDate(of: pm(2026, 11)), d(2026, 11, 10))
        XCTAssertEqual(c.month(containing: s(2026, 11, 8)), pm(2026, 10))
        XCTAssertEqual(c.month(containing: s(2026, 11, 11)), pm(2026, 12))
        let r = c.range(of: pm(2026, 11))
        XCTAssertGreaterThanOrEqual(r.start, r.end)
        XCTAssertEqual(c.range(of: pm(2026, 10)).end, d(2026, 11, 11).addingTimeInterval(-1))
    }

    func testPaydayBoundaryStaysInClosingMonth() {
        let c = make([d(2026, 9, 15), d(2026, 10, 15)])
        XCTAssertEqual(c.month(containing: d(2026, 10, 16).addingTimeInterval(-0.5)), pm(2026, 10))
        XCTAssertEqual(c.month(containing: d(2026, 10, 16)), pm(2026, 11))
    }

    func testLaterSalaryWinsWithinCalendarMonth() {
        let c = make([d(2026, 9, 1), d(2026, 9, 28)])
        XCTAssertEqual(c.closeDate(of: pm(2026, 9)), d(2026, 9, 28))
        XCTAssertEqual(c.closeSource(of: pm(2026, 9)), .salary)
    }

    func testSuggestedCloseDate() {
        // Today (5 Oct) is inside October's pay month (16 Sep – 15 Oct): today wins.
        let c = make([d(2026, 8, 15), d(2026, 9, 15)], today: s(2026, 10, 5))
        XCTAssertEqual(c.suggestedCloseDate(of: pm(2026, 10)), d(2026, 10, 5))
        // An earlier open month (no salary in it) suggests its projected close.
        let gap = make([d(2026, 7, 15), d(2026, 9, 15)], today: s(2026, 10, 5))
        XCTAssertEqual(gap.suggestedCloseDate(of: pm(2026, 8)), d(2026, 8, 15))
        // A future month never suggests a day before its start.
        XCTAssertEqual(c.suggestedCloseDate(of: pm(2026, 12)), d(2026, 11, 16))
    }

    func testUTCDayFromLocalPickerValue() {
        let london = TimeZone(identifier: "Europe/London")!
        var local = Calendar(identifier: .gregorian)
        local.timeZone = london
        // BST midnight on 5 Oct is 23:00 UTC on 4 Oct.
        let bstMidnight = local.date(from: DateComponents(year: 2026, month: 10, day: 5))!
        XCTAssertEqual(bstMidnight, d(2026, 10, 4).addingTimeInterval(23 * 3600))
        XCTAssertEqual(PayCalendar.utcDay(sameDayAs: bstMidnight, in: london), d(2026, 10, 5))
        XCTAssertEqual(PayCalendar.localDay(sameDayAs: d(2026, 10, 5), in: london), bstMidnight)
        // GMT (winter): local midnight is UTC midnight.
        let gmtMidnight = local.date(from: DateComponents(year: 2026, month: 12, day: 1))!
        XCTAssertEqual(PayCalendar.utcDay(sameDayAs: gmtMidnight, in: london), d(2026, 12, 1))
        XCTAssertEqual(PayCalendar.utcDay(sameDayAs: s(2026, 10, 5), in: TimeZone(identifier: "UTC")!), d(2026, 10, 5))
    }
}
