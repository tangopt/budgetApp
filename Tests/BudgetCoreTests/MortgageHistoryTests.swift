import XCTest
import GRDB
@testable import BudgetCore
@testable import BudgetDemo
import TestSupport

/// The loan's history before its first record, estimated from its terms (synthetic Euribor
/// series only): the rules instalment by instalment, the revisions resetting the instalment,
/// the gap to the first real figure and the adjustment that meets it, the principal that
/// lands on it, progress, and the demo loan.
final class MortgageHistoryTests: XCTestCase {
    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// Euribor 3M + 1%, quarterly, `total` instalments from 31 Mar 2012, a balloon.
    private func terms(total: Int = 300, balloon: Int = 2_000_000, borrowed: Int? = 18_000_000) -> PropertyMortgageTerms {
        PropertyMortgageTerms(propertyId: 1, balloonMinorUnits: balloon, rateIndex: .euribor3M, spreadPercent: 1.0,
                              totalInstalments: total, firstInstalmentDate: Self.date(2012, 3, 31), amountBorrowedMinorUnits: borrowed)
    }

    /// Monthly averages from Jan 2011 to Dec 2061: `value(offset)` for the month `offset` after Jan 2011.
    private func series(_ value: (Int) -> Double) -> MortgageRate.Series {
        var monthly: [Date: Double] = [:]
        for offset in 0..<(51 * 12) {
            monthly[MonthRange.calendar.date(byAdding: .month, value: offset, to: Self.date(2011, 1, 1))!] = value(offset)
        }
        return MortgageRate.Series(index: .euribor3M, monthly: monthly)
    }

    func testAFlatIndexRepaysToTheBalloonThenTheFinalInstalment() throws {
        // 1% + 1% = 2% throughout.
        let flat = series { _ in 1.0 }
        let all = try MortgageHistory.reconstruct(principal: 18_000_000, terms: terms(), series: flat, through: 400)
        XCTAssertEqual(all.count, 300)
        // Due on the 31st, the last day of shorter months.
        XCTAssertEqual(all[0].due, Self.date(2012, 3, 31))
        XCTAssertEqual(all[1].due, Self.date(2012, 4, 30))
        XCTAssertEqual(all[2].due, Self.date(2012, 5, 31))
        XCTAssertEqual(all[0].ratePercent, 2.0, accuracy: 1e-12)
        // The first instalment: the annuity over 299 leaving the balloon; interest at 2% ÷ 12.
        let annuity = MortgageRate.instalment(owed: 18_000_000, annualRatePercent: 2, remaining: 300, balloon: 2_000_000)!
        XCTAssertEqual(all[0].paidMinorUnits, annuity)
        XCTAssertEqual(all[0].interestMinorUnits, 30_000)
        XCTAssertEqual(all[0].owedAfterMinorUnits, 18_000_000 + 30_000 - annuity)
        // Same rate at every revision: the instalment barely moves (cent rounding only).
        XCTAssertTrue(all.dropLast().allSatisfy { abs($0.paidMinorUnits - annuity) <= 2 })
        // Before the final one, about the balloon; the final one repays it with its interest.
        XCTAssertEqual(all[298].owedAfterMinorUnits, 2_000_000, accuracy: 500)
        XCTAssertEqual(all[299].owedAfterMinorUnits, 0)
        XCTAssertEqual(all[299].paidMinorUnits, all[298].owedAfterMinorUnits + all[299].interestMinorUnits)
    }

    func testEachRevisionTakesThePreviousMonthsAverageAndResetsTheInstalment() throws {
        // 0.5% to June 2013, 2.5% from July 2013 (offset 30).
        let step = series { $0 < 30 ? 0.5 : 2.5 }
        let rows = try MortgageHistory.reconstruct(principal: 18_000_000, terms: terms(), series: step, through: 21)
        // Mar 2012 (the 1 January period: December's average): 1.5%; the step shows at
        // 1 October 2013 (September's average), not 1 July (June's).
        XCTAssertEqual(rows[0].ratePercent, 1.5, accuracy: 1e-12)
        let september = rows.first { $0.due == Self.date(2013, 9, 30) }!
        XCTAssertEqual(september.ratePercent, 1.5, accuracy: 1e-12)
        let october = rows.first { $0.due == Self.date(2013, 10, 31) }!
        XCTAssertEqual(october.ratePercent, 3.5, accuracy: 1e-12)
        // The instalment reset at October's: the annuity on what was owed after September's.
        XCTAssertEqual(october.paidMinorUnits, MortgageRate.instalment(owed: september.owedAfterMinorUnits, annualRatePercent: 3.5,
                                                                         remaining: 300 - october.number + 1, balloon: 2_000_000))
        XCTAssertEqual(october.interestMinorUnits, Int((Double(september.owedAfterMinorUnits) * 3.5 / 1200).rounded(.toNearestOrAwayFromZero)))
        // Within a period the instalment holds.
        let november = rows.first { $0.due == Self.date(2013, 11, 30) }!
        XCTAssertEqual(november.paidMinorUnits, october.paidMinorUnits)
        // No value for a period: it can't be estimated.
        let gap = MortgageRate.Series(index: .euribor3M, monthly: [Self.date(2011, 12, 1): 1])
        XCTAssertThrowsError(try MortgageHistory.reconstruct(principal: 18_000_000, terms: terms(), series: gap, through: 6)) {
            XCTAssertEqual($0 as? MortgageHistory.Failure, .missingFixing(Self.date(2012, 4, 1)))
        }
        XCTAssertThrowsError(try MortgageHistory.reconstruct(principal: 18_000_000, terms: terms().with { $0.spreadPercent = nil },
                                                             series: step, through: 6))
    }

    func testTheEstimateMeetsTheFirstRealFigureAndSaysByHowMuch() throws {
        let wave = series { 1 + sin(Double($0) / 9) }
        // The bank's loan (synthetic): lent 181,234.56; the first statement is before instalment 100.
        let real = try MortgageHistory.reconstruct(principal: 18_123_456, terms: terms(), series: wave, through: 99)
        let anchor = MortgageHistory.Anchor(number: 100, due: Self.date(2020, 6, 30), paidOn: Self.date(2020, 7, 1),
                                            owedBeforeMinorUnits: real.last!.owedAfterMinorUnits)
        let estimate = try XCTUnwrap(try MortgageHistory.estimate(principal: 18_000_000, terms: terms(), series: wave, anchor: anchor))
        XCTAssertEqual(estimate.instalments.count, 99)
        XCTAssertGreaterThan(estimate.gapMinorUnits, 0)
        XCTAssertEqual(estimate.gapMinorUnits, anchor.owedBeforeMinorUnits - estimate.instalments.last!.owedAfterMinorUnits)
        XCTAssertTrue(estimate.isAdjusted)
        // The points: the amount borrowed a month before the first instalment, then one per
        // instalment, the last one on the real figure; the adjustment grows along the way.
        XCTAssertEqual(estimate.points.count, 100)
        XCTAssertEqual(estimate.points.first, MortgageHistory.Point(date: Self.date(2012, 2, 29), owedMinorUnits: 18_000_000))
        XCTAssertEqual(estimate.points.last?.owedMinorUnits, anchor.owedBeforeMinorUnits)
        XCTAssertEqual(estimate.points.last?.date, Self.date(2020, 5, 31))
        let middle = estimate.points[50].owedMinorUnits - estimate.instalments[49].owedAfterMinorUnits
        XCTAssertEqual(middle, estimate.gapMinorUnits * 50 / 99, accuracy: 1)
        XCTAssertEqual(zip(estimate.points, estimate.points.dropFirst()).filter { $1.owedMinorUnits > $0.owedMinorUnits }.count, 0)
        XCTAssertFalse(estimate.isLargeGap)
        // 10% off: too far to adjust away, left as it is (never rising) for the chart to flag.
        let off = try XCTUnwrap(try MortgageHistory.estimate(principal: 20_000_000, terms: terms(), series: wave, anchor: anchor))
        XCTAssertTrue(off.isLargeGap)
        XCTAssertFalse(off.isAdjusted)
        XCTAssertEqual(off.points.last?.owedMinorUnits, off.estimatedOwedBeforeMinorUnits)
        XCTAssertEqual(zip(off.points, off.points.dropFirst()).filter { $1.owedMinorUnits > $0.owedMinorUnits }.count, 0)
        // The principal that lands on it is the bank's.
        XCTAssertEqual(try MortgageHistory.solvePrincipal(near: 18_000_000, terms: terms(), series: wave, anchor: anchor), 18_123_456, accuracy: 1)
        // From the right principal: no gap, nothing adjusted.
        let exact = try XCTUnwrap(try MortgageHistory.estimate(principal: 18_123_456, terms: terms(), series: wave, anchor: anchor))
        XCTAssertEqual(exact.gapMinorUnits, 0)
        XCTAssertFalse(exact.isAdjusted)
        // An anchor at the first instalment: nothing to estimate.
        XCTAssertNil(try MortgageHistory.estimate(principal: 18_000_000, terms: terms(), series: wave,
                                                  anchor: .init(number: 1, due: Self.date(2012, 3, 31), paidOn: Self.date(2012, 3, 31), owedBeforeMinorUnits: 1)))
    }

    func testProgressCountsWhatsRepaidAndTheInstalmentsDue() throws {
        let progress = try XCTUnwrap(MortgageHistory.progress(terms: terms(), owedMinorUnits: 10_000_000, today: Self.date(2026, 10, 19)))
        XCTAssertEqual(progress.repaidMinorUnits, 8_000_000)
        XCTAssertEqual(progress.percent, 44)
        // September's (due the 30th) is the latest: Mar 2012 is 1, Sep 2026 is 175.
        XCTAssertEqual(progress.instalmentNumber, 175)
        XCTAssertEqual(progress.totalInstalments, 300)
        XCTAssertEqual(MortgageHistory.progress(terms: terms(), owedMinorUnits: 1, today: Self.date(2026, 10, 31))?.instalmentNumber, 176)
        XCTAssertNil(MortgageHistory.progress(terms: terms(borrowed: nil), owedMinorUnits: 1, today: Self.date(2026, 10, 19)))
        XCTAssertEqual(MortgageHistory.progress(terms: terms(), owedMinorUnits: 0, today: Self.date(2060, 1, 1))?.percent, 100)
    }

    func testTheAmountBorrowedIsSavedAndChecked() throws {
        let manager = try TestDatabase.migratedManager()
        try manager.dbQueue.write { db in
            var property = Property(name: "Flat", country: "PT", currency: .eur)
            try Properties.save(db: db, &property)
            var saved = terms()
            saved.propertyId = property.id!
            try MortgageTerms.save(db: db, saved)
            XCTAssertEqual(try MortgageTerms.terms(db: db, propertyId: property.id!).amountBorrowedMinorUnits, 18_000_000)
            saved.amountBorrowedMinorUnits = 2_000_000
            XCTAssertThrowsError(try MortgageTerms.save(db: db, saved)) { XCTAssertEqual($0 as? MortgageTermsError, .invalidAmountBorrowed) }
            // The ECB fetch reaches back to the loan's start (from 2000 at the latest).
            XCTAssertEqual(try InterestIndexValues.fetchStartPeriod(db: db), "2000-01")
            saved.amountBorrowedMinorUnits = 18_000_000
            saved.firstInstalmentDate = Self.date(1999, 6, 30)
            try MortgageTerms.save(db: db, saved)
            XCTAssertEqual(try InterestIndexValues.fetchStartPeriod(db: db), "1999-01")
        }
    }

    func testTheDemoLoanIsEstimatedFromItsStart() throws {
        let manager = try TestDatabase.migratedManager()
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("MortgageHistoryDemo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidence) }
        try TestDatabase.fillDemo(manager.dbQueue, evidenceRoot: evidence)
        try manager.dbQueue.read { db in
            let propertyId = try Property.filter(Column("name") == DemoDatabase.propertyName).fetchOne(db)!.id!
            let terms = try MortgageTerms.terms(db: db, propertyId: propertyId)
            let anchor = try XCTUnwrap(try MortgageHistory.anchor(db: db, propertyId: propertyId, terms: terms))
            // The first instalment paid into the demo loan: 1 Oct 2023, the 84th; €182,000 owed before it.
            XCTAssertEqual(anchor.due, DemoDatabase.date(2023, 10, 1))
            XCTAssertEqual(anchor.number, 84)
            XCTAssertEqual(anchor.owedBeforeMinorUnits, 18_200_000)
            let estimate = try XCTUnwrap(try MortgageHistory.estimate(db: db, propertyId: propertyId))
            XCTAssertEqual(estimate.principalMinorUnits, terms.amountBorrowedMinorUnits)
            XCTAssertEqual(estimate.points.first?.date, DemoDatabase.date(2016, 10, 1))
            XCTAssertEqual(estimate.points.last?.owedMinorUnits, 18_200_000)
            // A small gap, so the chart's caption has an adjustment to explain.
            XCTAssertNotEqual(estimate.gapMinorUnits, 0)
            XCTAssertLessThan(abs(estimate.gapFraction), 0.01, "gap \(estimate.gapMinorUnits)")
            XCTAssertNil(estimate.suggestedPrincipalMinorUnits)
        }
        // A wrong amount borrowed: the estimate suggests the one that meets the statement.
        try manager.dbQueue.write { db in
            let propertyId = try Property.filter(Column("name") == DemoDatabase.propertyName).fetchOne(db)!.id!
            var terms = try MortgageTerms.terms(db: db, propertyId: propertyId)
            terms.amountBorrowedMinorUnits = 25_000_000
            try MortgageTerms.save(db: db, terms)
            let estimate = try XCTUnwrap(try MortgageHistory.estimate(db: db, propertyId: propertyId))
            XCTAssertTrue(estimate.isLargeGap)
            let suggested = try XCTUnwrap(estimate.suggestedPrincipalMinorUnits)
            let check = try XCTUnwrap(try MortgageHistory.estimate(principal: suggested, terms: terms, series: try MortgageRate.series(db: db, terms: terms),
                                                                   anchor: estimate.anchor))
            XCTAssertEqual(check.gapMinorUnits, 0, accuracy: 2)
        }
    }
}

final class MortgageInstalmentDueDayTests: XCTestCase {
    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func row(_ id: Int64, _ day: Date, _ amount: Int, category: Int64, account: Int64 = 1) -> Transaction {
        Transaction(id: id, importBatchId: 1, accountId: account, date: day, rawDescription: "", amountMinorUnits: amount, categoryId: category,
                    status: .confirmed, categorizedBy: .manual, fingerprint: "\(id)")
    }

    func testOnlyInstalmentsAndTheirInterestShift() {
        let transfer: Int64 = 9, interest: Int64 = 5
        let rows = [
            row(1, Self.date(2026, 6, 1), 100_000, category: transfer),   // May's instalment, late
            row(2, Self.date(2026, 6, 1), -60_000, category: interest),   // its interest
            row(3, Self.date(2026, 7, 1), -500, category: interest),      // a fee, no instalment that day
            row(4, Self.date(2026, 8, 1), 5_000_000, category: transfer), // an early repayment
            row(5, Self.date(2026, 6, 30), 100_000, category: transfer),  // June's, on time
            row(6, Self.date(2026, 6, 1), -40_000, category: interest, account: 2) // another account's row that day
        ]
        let due = MortgageRate.instalmentDueDays(rows: rows, transferCategoryIds: [transfer], paymentDay: 31, typicalInstalment: 100_000)
        XCTAssertEqual(due, [1: Self.date(2026, 5, 31), 2: Self.date(2026, 5, 31)])
        // Without a usual instalment, any leg near a due day is one.
        XCTAssertEqual(MortgageRate.instalmentDueDays(rows: rows, transferCategoryIds: [transfer], paymentDay: 31, typicalInstalment: nil)[4],
                       Self.date(2026, 7, 31))
    }
}

private extension PropertyMortgageTerms {
    func with(_ change: (inout PropertyMortgageTerms) -> Void) -> PropertyMortgageTerms {
        var copy = self
        change(&copy)
        return copy
    }
}

