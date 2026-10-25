import XCTest
import GRDB
@testable import BudgetCore
@testable import BudgetDemo
import TestSupport

/// The mortgage rate from the loan's rules (synthetic figures only): the fixing each convention
/// picks, the index rounded and the spread added, overrides and fixed rates, the instalment the
/// bank resets to (the annuity that leaves the balloon), interest by day count and rounding,
/// the ECB file and the automatic fetch (stubbed), and the rules on the demo database.
final class MortgageRateTests: XCTestCase {
    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func terms(index: InterestIndex = .euribor3M, spread: Double? = 1.0, convention: MortgageFixingConvention = .previousMonthAverage,
                       days: Int = 2) -> PropertyMortgageTerms {
        PropertyMortgageTerms(propertyId: 1, rateIndex: index, spreadPercent: spread, fixingConvention: convention, fixingBusinessDays: days)
    }

    // MARK: Fixing

    func testThePreviousMonthsAverageRoundedToThreeDecimalsPlusTheSpread() {
        let series = MortgageRate.Series(index: .euribor3M, monthly: [Self.date(2026, 9, 1): 2.1350455, Self.date(2026, 12, 1): 2.0004999])
        let october = MortgageRate.rate(periodStart: Self.date(2026, 10, 1), terms: terms(), series: series)!
        XCTAssertEqual(october.fixing?.date, Self.date(2026, 9, 1))
        XCTAssertEqual(october.fixing!.valuePercent, 2.135, accuracy: 1e-12)
        XCTAssertEqual(october.ratePercent, 3.135, accuracy: 1e-12)
        XCTAssertEqual(october.explanation.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{2060}", with: ""),
                       "Euribor 3M 2.135% (fixed Sep 2026 average) + 1.000% = 3.135%")
        // 1 January: December's average.
        XCTAssertEqual(MortgageRate.rate(periodStart: Self.date(2027, 1, 1), terms: terms(), series: series)!.ratePercent, 3.0, accuracy: 1e-12)
        // No November value: 1 December has no rate, unless the latest is held.
        XCTAssertNil(MortgageRate.rate(periodStart: Self.date(2026, 12, 1), terms: terms(), series: series))
        let held = MortgageRate.rate(periodStart: Self.date(2026, 12, 1), terms: terms(), series: series, holdLatest: true)!
        XCTAssertTrue(held.isHeld)
        XCTAssertEqual(held.fixing?.date, Self.date(2026, 9, 1))
        // Another tenor's series isn't this index's; no spread, no rate.
        XCTAssertNil(MortgageRate.rate(periodStart: Self.date(2026, 10, 1), terms: terms(index: .euribor6M), series: series))
        XCTAssertNil(MortgageRate.rate(periodStart: Self.date(2026, 10, 1), terms: terms(spread: nil), series: series))
        // A negative index is passed on.
        let negative = MortgageRate.Series(index: .euribor3M, monthly: [Self.date(2021, 12, 1): -0.5726])
        XCTAssertEqual(MortgageRate.rate(periodStart: Self.date(2022, 1, 1), terms: terms(), series: negative)!.ratePercent, 0.427, accuracy: 1e-12)
    }

    func testBusinessDaysBeforeTheRevisionOnTheTargetCalendar() {
        // 1 Jan 2027 is a Friday: 31 Dec, then 30 Dec.
        XCTAssertEqual(MortgageRate.fixingKey(revision: Self.date(2027, 1, 1), convention: .businessDaysBefore, businessDays: 2).date, Self.date(2026, 12, 30))
        // Easter 2027 is 28 March: Good Friday (26th) and Easter Monday (29th) are closed.
        XCTAssertEqual(TargetCalendar.easterSunday(2027), Self.date(2027, 3, 28))
        XCTAssertEqual(TargetCalendar.businessDay(before: Self.date(2027, 4, 1), count: 2), Self.date(2027, 3, 30))
        XCTAssertEqual(TargetCalendar.businessDay(before: Self.date(2027, 4, 1), count: 3), Self.date(2027, 3, 25))
        XCTAssertFalse(TargetCalendar.isBusinessDay(Self.date(2026, 12, 25)))
        XCTAssertFalse(TargetCalendar.isBusinessDay(Self.date(2026, 5, 1)))
        XCTAssertTrue(TargetCalendar.isBusinessDay(Self.date(2026, 12, 31)))
        // The daily value that day; the monthly averages don't count.
        let series = MortgageRate.Series(index: .euribor3M, monthly: [Self.date(2027, 3, 1): 9], daily: [Self.date(2027, 3, 30): 2.3456])
        let rate = MortgageRate.rate(periodStart: Self.date(2027, 4, 1), terms: terms(convention: .businessDaysBefore), series: series)!
        XCTAssertEqual(rate.ratePercent, 3.346, accuracy: 1e-12)
        XCTAssertEqual(rate.fixing?.dateText, "30 Mar 2027")
        XCTAssertNil(MortgageRate.rate(periodStart: Self.date(2027, 4, 1), terms: terms(convention: .businessDaysBefore, days: 3), series: series))
    }

    func testAnOverrideWinsAndAFixedRateNeedsNoIndex() {
        let series = MortgageRate.Series(index: .euribor3M, monthly: [Self.date(2026, 9, 1): 2.0])
        let given = MortgageRateOverride(propertyId: 1, periodStart: Self.date(2026, 10, 1), ratePercent: 3.7, note: "Bank notice")
        let rate = MortgageRate.rate(periodStart: Self.date(2026, 10, 1), terms: terms(), series: series, overrides: [given])!
        XCTAssertEqual(rate.ratePercent, 3.7)
        XCTAssertEqual(rate.source, .override(note: "Bank notice"))
        // Only for its period.
        XCTAssertNil(MortgageRate.rate(periodStart: Self.date(2027, 1, 1), terms: terms(), series: series, overrides: [given]))
        // Even without a fixing or a spread.
        XCTAssertEqual(MortgageRate.rate(periodStart: Self.date(2026, 10, 1), terms: terms(spread: nil), series: MortgageRate.Series(index: .euribor3M),
                                         overrides: [given])?.ratePercent, 3.7)
        var fixed = PropertyMortgageTerms(propertyId: 1, annualRatePercent: 2.25, rateIndex: .fixed)
        XCTAssertEqual(MortgageRate.rate(periodStart: Self.date(2030, 4, 1), terms: fixed, series: series)?.source, .fixed)
        XCTAssertTrue(fixed.hasRateRules)
        fixed.annualRatePercent = nil
        XCTAssertFalse(fixed.hasRateRules)
        XCTAssertFalse(PropertyMortgageTerms(propertyId: 1).hasRateRules)
    }

    // MARK: Instalment and interest

    func testTheInstalmentLeavesTheBalloonForTheFinalOne() {
        let owed = 20_000_000, balloon = 5_000_000, rate = 3.5, remaining = 120
        let instalment = MortgageRate.instalment(owed: owed, annualRatePercent: rate, remaining: remaining, balloon: balloon)!
        // Paying it on the 119 instalments before the final leaves the balloon (to the rounding).
        var left = Double(owed)
        for _ in 0..<(remaining - 1) { left = left * (1 + rate / 1200) - Double(instalment) }
        XCTAssertEqual(left, Double(balloon), accuracy: 150) // half a cent a month, compounded
        // The final one: the balloon with its month's interest.
        XCTAssertEqual(MortgageRate.interest(owed: balloon, annualRatePercent: rate, dayCount: .thirty360, previousDue: nil, due: Self.date(2030, 1, 31),
                                             rounding: .nearest), 14_583)
        // No balloon: the annuity over every instalment repays the loan.
        let plain = MortgageRate.instalment(owed: owed, annualRatePercent: rate, remaining: remaining, balloon: 0)!
        var rest = Double(owed)
        for _ in 0..<remaining { rest = rest * (1 + rate / 1200) - Double(plain) }
        XCTAssertEqual(rest, 0, accuracy: 150)
        // A rate change at a revision: recalculated from what's owed then, the balloon still left.
        let after = MortgageRate.instalment(owed: Int(left.rounded()) + 10_000_000, annualRatePercent: 4.0, remaining: 61, balloon: balloon)!
        var again = left + 10_000_000
        for _ in 0..<60 { again = again * (1 + 4.0 / 1200) - Double(after) }
        XCTAssertEqual(again, Double(balloon), accuracy: 150)
        XCTAssertNil(MortgageRate.instalment(owed: owed, annualRatePercent: rate, remaining: 1, balloon: balloon))
        XCTAssertNil(MortgageRate.instalment(owed: 0, annualRatePercent: rate, remaining: 10, balloon: 0))
    }

    func testInterestByDayCountAndRounding() {
        // 30/360: owed × rate ÷ 12, to the nearest cent (20,000,123 × 3.135% ÷ 12 = 52,250.32…).
        XCTAssertEqual(MortgageRate.interest(owed: 20_000_123, annualRatePercent: 3.135, dayCount: .thirty360, previousDue: nil,
                                             due: Self.date(2026, 10, 31), rounding: .nearest), 52_250)
        XCTAssertEqual(MortgageRate.interest(owed: 10_000_050, annualRatePercent: 1.2, dayCount: .thirty360, previousDue: nil,
                                             due: Self.date(2026, 10, 31), rounding: .nearest), 10_000)
        XCTAssertEqual(MortgageRate.interest(owed: 10_000_950, annualRatePercent: 1.2, dayCount: .thirty360, previousDue: nil,
                                             due: Self.date(2026, 10, 31), rounding: .down), 10_000)
        // Actual/360: 31 days in October.
        XCTAssertEqual(MortgageRate.interest(owed: 36_000_000, annualRatePercent: 3.0, dayCount: .actual360, previousDue: Self.date(2026, 9, 30),
                                             due: Self.date(2026, 10, 31), rounding: .nearest), 93_000)
    }

    func testTheProjectionFollowsTheRatesOfEachRevision() {
        let owed = 10_000_000, balloon = 2_000_000
        let instalment = MortgageRate.instalment(owed: owed, annualRatePercent: 3, remaining: 48, balloon: balloon)!
        let result = MortgageProjection.project(.init(owedMinorUnits: owed, asOf: Self.date(2026, 10, 15), annualRatePercent: 3,
                                                      instalmentMinorUnits: instalment, paymentDay: 31, finalInstalmentDate: Self.date(2030, 9, 30),
                                                      balloonMinorUnits: balloon,
                                                      rateChanges: [.init(date: Self.date(2027, 1, 1), ratePercent: 4)]))
        XCTAssertEqual(result.payments.count, 48)
        XCTAssertEqual(result.payments[2].date, Self.date(2026, 12, 31))
        XCTAssertEqual(result.payments[2].paidMinorUnits, instalment)
        // From 31 January: 4%, the instalment reset for the 45 left.
        let january = result.payments[3]
        XCTAssertEqual(january.date, Self.date(2027, 1, 31))
        XCTAssertEqual(january.interestMinorUnits, Int((Double(result.payments[2].owedMinorUnits) * 4 / 1200).rounded()))
        XCTAssertEqual(january.paidMinorUnits, MortgageRate.instalment(owed: result.payments[2].owedMinorUnits, annualRatePercent: 4, remaining: 45, balloon: balloon))
        XCTAssertEqual(result.payments[result.payments.count - 2].owedMinorUnits, balloon, accuracy: 100)
        XCTAssertEqual(result.payments.last?.owedMinorUnits, 0)

        // A new period whose instalment isn't paid yet resets at the first projected one.
        let reset = MortgageProjection.project(.init(owedMinorUnits: owed, asOf: Self.date(2026, 10, 15), annualRatePercent: 4,
                                                     instalmentMinorUnits: instalment, paymentDay: 31, finalInstalmentDate: Self.date(2030, 9, 30),
                                                     balloonMinorUnits: balloon, resetsAtFirstPayment: true))
        XCTAssertEqual(reset.payments.first?.paidMinorUnits, MortgageRate.instalment(owed: owed, annualRatePercent: 4, remaining: 48, balloon: balloon))
    }

    // MARK: The ECB file and the fetch

    static let ecbCSV = """
        KEY,FREQ,REF_AREA,CURRENCY,PROVIDER_FM,INSTRUMENT_FM,PROVIDER_FM_ID,DATA_TYPE_FM,TIME_PERIOD,OBS_VALUE
        FM.M.U2.EUR.RT.MM.EURIBOR3MD_.HSTA,M,U2,EUR,RT,MM,EURIBOR3MD_,HSTA,2026-08,1.5131429
        FM.M.U2.EUR.RT.MM.EURIBOR3MD_.HSTA,M,U2,EUR,RT,MM,EURIBOR3MD_,HSTA,2026-07,1.4253913
        FM.M.U2.EUR.RT.MM.EURIBOR3MD_.HSTA,M,U2,EUR,RT,MM,EURIBOR3MD_,HSTA,2026-13,9
        FM.M.U2.EUR.RT.MM.EURIBOR3MD_.HSTA,M,U2,EUR,RT,MM,EURIBOR3MD_,HSTA,2026-09,NaN
        FM.M.U2.EUR.RT.MM.EURIBOR3MD_.HSTA,M,U2,EUR,RT,MM,EURIBOR3MD_,HSTA,2026-09,
        """

    func testTheECBFileParses() throws {
        let values = try ECBEuriborFile.parse(Self.ecbCSV)
        XCTAssertEqual(values, [.init(month: Self.date(2026, 7, 1), valuePercent: 1.4253913), .init(month: Self.date(2026, 8, 1), valuePercent: 1.5131429)])
        XCTAssertThrowsError(try ECBEuriborFile.parse("A,B\n1,2")) { XCTAssertEqual($0 as? ECBEuriborFile.ParseError, .missingColumns) }
        XCTAssertEqual(ECBEuriborFile.monthlyURL(for: .euribor12M, startPeriod: "2000-01")?.absoluteString,
                       "https://data-api.ecb.europa.eu/service/data/FM/M.U2.EUR.RT.MM.EURIBOR1YD_.HSTA?format=csvdata&detail=dataonly&startPeriod=2000-01")
        XCTAssertNil(ECBEuriborFile.monthlyURL(for: .fixed, startPeriod: "2000-01"))
    }

    private final class StubFetcher: InterestIndexFetching, @unchecked Sendable {
        var values: [ECBEuriborFile.Observation]?
        var asked: [InterestIndex] = []
        init(_ values: [ECBEuriborFile.Observation]?) { self.values = values }
        func fetchMonthlyAverages(for index: InterestIndex, startPeriod: String) async -> [ECBEuriborFile.Observation]? {
            asked.append(index)
            return values
        }
    }

    func testTheFetchStoresMonthsOnceADayAndNeverOverAManualValue() async throws {
        let manager = try TestDatabase.migratedManager()
        let db = manager.dbQueue
        // A value the user entered for August.
        try await db.write { db in
            try InterestIndexValues.set(db: db, index: .euribor3M, period: .month, date: Self.date(2026, 8, 15), valuePercent: 1.6, source: .manual)
        }
        let fetcher = StubFetcher(try ECBEuriborFile.parse(Self.ecbCSV))
        let log = InterestIndexFetchMemoryLog()
        let today = Self.date(2026, 10, 19)
        // No terms saved: Euribor 3M.
        let first = try await InterestIndexValues.fetchInUse(db: db, today: today, fetcher: fetcher, log: log)
        XCTAssertEqual(first.stored, [.euribor3M: 1])
        let stored = try await db.read { db in try InterestIndexValues.all(db: db, index: .euribor3M) }
        XCTAssertEqual(stored.map(\.valuePercent), [1.4253913, 1.6])
        XCTAssertEqual(stored.map(\.source), [.ecb, .manual])
        XCTAssertEqual(stored.first?.date, Self.date(2026, 7, 1))
        // Asked again the same day: left alone.
        let again = try await InterestIndexValues.fetchInUse(db: db, today: today.addingTimeInterval(3_600), fetcher: fetcher, log: log)
        XCTAssertEqual(again.throttled, [.euribor3M])
        XCTAssertEqual(fetcher.asked.count, 1)
        // The next day, offline: quiet, nothing changes.
        fetcher.values = nil
        let offline = try await InterestIndexValues.fetchInUse(db: db, today: today.addingTimeInterval(90_000), fetcher: fetcher, log: log)
        XCTAssertEqual(offline.failed, [.euribor3M])
        let count = try await db.read { db in try InterestIndexValues.all(db: db, index: .euribor3M).count }
        XCTAssertEqual(count, 2)
        // A revised ECB value replaces the ECB row; the indices the terms use are fetched.
        fetcher.values = [.init(month: Self.date(2026, 7, 1), valuePercent: 1.43)]
        try await db.write { db in
            var property = Property(name: "Flat", country: "PT", currency: .eur)
            try Properties.save(db: db, &property)
            try MortgageTerms.save(db: db, PropertyMortgageTerms(propertyId: property.id!, rateIndex: .euribor6M, spreadPercent: 1))
        }
        let later = try await InterestIndexValues.fetchInUse(db: db, today: today.addingTimeInterval(200_000), fetcher: fetcher, log: log)
        XCTAssertEqual(later.stored, [.euribor6M: 1])
        XCTAssertEqual(fetcher.asked.last, .euribor6M)
        do {
            try await db.write { db in
                _ = try InterestIndexValues.set(db: db, index: .fixed, period: .month, date: today, valuePercent: 1, source: .manual)
            }
            XCTFail("a fixed rate has no index values")
        } catch {
            XCTAssertEqual(error as? InterestIndexError, .notAnIndex)
        }
    }

    // MARK: Terms and migration

    func testTermsDeriveTheFinalInstalmentAndValidate() throws {
        var terms = PropertyMortgageTerms(propertyId: 1, totalInstalments: 360, firstInstalmentDate: Self.date(2016, 11, 30))
        XCTAssertEqual(terms.effectiveFinalInstalmentDate, Self.date(2046, 10, 30))
        XCTAssertEqual(terms.instalmentNumber(dueIn: Self.date(2016, 11, 30)), 1)
        XCTAssertEqual(terms.instalmentNumber(dueIn: Self.date(2026, 10, 31)), 120)
        terms.firstInstalmentDate = Self.date(2016, 1, 31)
        XCTAssertEqual(terms.effectiveFinalInstalmentDate, Self.date(2045, 12, 31))
        XCTAssertEqual(MortgageTerms.dueDate(monthsAfter: 1, first: Self.date(2016, 1, 31)), Self.date(2016, 2, 29))
        terms.finalInstalmentDate = Self.date(2040, 1, 31)
        XCTAssertEqual(terms.effectiveFinalInstalmentDate, Self.date(2040, 1, 31))

        let manager = try TestDatabase.migratedManager()
        try manager.dbQueue.write { db in
            var property = Property(name: "Flat", country: "PT", currency: .eur)
            try Properties.save(db: db, &property)
            let id = property.id!
            XCTAssertThrowsError(try MortgageTerms.save(db: db, PropertyMortgageTerms(propertyId: id, spreadPercent: 30))) {
                XCTAssertEqual($0 as? MortgageTermsError, .invalidSpread)
            }
            XCTAssertThrowsError(try MortgageTerms.save(db: db, PropertyMortgageTerms(propertyId: id, totalInstalments: 0))) {
                XCTAssertEqual($0 as? MortgageTermsError, .invalidCount)
            }
            XCTAssertThrowsError(try MortgageTerms.save(db: db, PropertyMortgageTerms(propertyId: id, finalInstalmentDate: Self.date(2010, 1, 1),
                                                                                      firstInstalmentDate: Self.date(2011, 1, 1)))) {
                XCTAssertEqual($0 as? MortgageTermsError, .finalBeforeFirst)
            }
            let saved = PropertyMortgageTerms(propertyId: id, balloonMinorUnits: 100, rateIndex: .euribor6M, spreadPercent: 0.9,
                                              fixingConvention: .businessDaysBefore, fixingBusinessDays: 2, dayCount: .actual360,
                                              totalInstalments: 300, firstInstalmentDate: Self.date(2020, 1, 31), indexDecimals: 2, interestRounding: .down)
            try MortgageTerms.save(db: db, saved)
            XCTAssertEqual(try MortgageTerms.terms(db: db, propertyId: id), saved)
            // Overrides: one per period, replaced, removed.
            try MortgageRate.setOverride(db: db, propertyId: id, periodStart: Self.date(2026, 10, 1), ratePercent: 3.5)
            try MortgageRate.setOverride(db: db, propertyId: id, periodStart: Self.date(2026, 10, 1), ratePercent: 3.6, note: " notice ")
            XCTAssertEqual(try MortgageRate.overrides(db: db, propertyId: id).map(\.ratePercent), [3.6])
            XCTAssertEqual(try MortgageRate.overrides(db: db, propertyId: id).first?.note, "notice")
            XCTAssertThrowsError(try MortgageRate.setOverride(db: db, propertyId: id, periodStart: Self.date(2027, 1, 1), ratePercent: 80))
            XCTAssertTrue(try MortgageRate.removeOverride(db: db, propertyId: id, periodStart: Self.date(2026, 10, 1)))
            XCTAssertEqual(try MortgageRate.overrides(db: db, propertyId: id), [])
        }
    }

    func testARateEnteredBeforeBecomesAFixedRate() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate(upTo: "createPropertyMortgageTerms")
        try manager.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO property (name, country, currency) VALUES ('Flat', 'PT', 'eur')")
            let id = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO propertyMortgageTerms (propertyId, revisionMonths, annualRatePercent) VALUES (?, '1,7', 3.25)", arguments: [id])
            try db.execute(sql: "INSERT INTO property (name, country, currency) VALUES ('Other', 'PT', 'eur')")
            try db.execute(sql: "INSERT INTO propertyMortgageTerms (propertyId, revisionMonths) VALUES (?, '1,4,7,10')", arguments: [db.lastInsertedRowID])
        }
        try manager.migrate()
        try manager.dbQueue.read { db in
            let rows = try PropertyMortgageTerms.order(Column("propertyId")).fetchAll(db)
            XCTAssertEqual(rows.map(\.rateIndex), [.fixed, nil])
            XCTAssertEqual(rows.first?.annualRatePercent, 3.25)
            XCTAssertEqual(rows.first?.revisionMonths, [1, 7])
            XCTAssertEqual(rows.map(\.fixingConvention), [.previousMonthAverage, .previousMonthAverage])
            XCTAssertEqual(rows.map(\.dayCount), [.thirty360, .thirty360])
            XCTAssertEqual(rows.map(\.indexDecimals), [3, 3])
        }
    }

    // MARK: On the demo database

    func testTheDemoLoanFollowsItsRules() throws {
        let manager = try TestDatabase.migratedManager()
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("MortgageRateDemo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidence) }
        try TestDatabase.fillDemo(manager.dbQueue, evidenceRoot: evidence)
        let today = DemoDatabase.date(2026, 10, 15)
        try manager.dbQueue.write { db in
            let propertyId = try Property.filter(Column("name") == DemoDatabase.propertyName).fetchOne(db)!.id!
            let terms = try MortgageTerms.terms(db: db, propertyId: propertyId)
            let series = try MortgageRate.series(db: db, terms: terms)
            let september = DemoDatabase.euribor3M().first { $0.0 == DemoDatabase.date(2026, 9, 1) }!.1

            // Every interest row the demo charged is owed × the rules' rate ÷ 12.
            let charged = try MortgageRate.chargedInstalments(db: db, propertyId: propertyId, paymentDay: terms.paymentDay!)
            XCTAssertEqual(charged.count, 37)
            for item in charged {
                let start = MortgageRate.periodStart(containing: item.due, months: terms.revisionMonths)!
                let rate = MortgageRate.rate(periodStart: start, terms: terms, series: series)!
                XCTAssertEqual(item.interestMinorUnits, MortgageRate.interest(owed: item.owedBeforeMinorUnits, annualRatePercent: rate.ratePercent,
                                                                              dayCount: terms.dayCount, previousDue: nil, due: item.due,
                                                                              rounding: terms.interestRounding), "\(item.due)")
            }

            // Now: September's average + 1%, revised next on 1 January; the next instalment is
            // the one paid on 1 October (the same period).
            let status = try MortgageRate.status(db: db, propertyId: propertyId, today: today)!
            XCTAssertEqual(status.current?.start, DemoDatabase.date(2026, 10, 1))
            XCTAssertEqual(status.current!.ratePercent, MortgageRate.round(september, decimals: 3) + 1, accuracy: 1e-9)
            XCTAssertEqual(status.nextRevision, DemoDatabase.date(2027, 1, 1))
            XCTAssertEqual(status.nextDue, DemoDatabase.date(2026, 11, 1))
            XCTAssertEqual(status.remainingInstalments, 360 - 121 + 1)
            XCTAssertEqual(status.nextInstalmentMinorUnits, charged.last?.paidMinorUnits)

            // The projection: from the rules, September held from 1 January to the end.
            let basis = try MortgageProjection.basis(db: db, propertyId: propertyId, today: today)!
            guard case let .rules(current) = basis.rateSource else { return XCTFail("not from the rules") }
            XCTAssertEqual(current.start, DemoDatabase.date(2026, 10, 1))
            XCTAssertEqual(basis.heldFrom?.start, DemoDatabase.date(2027, 1, 1))
            XCTAssertEqual(basis.heldFrom?.fixing?.date, DemoDatabase.date(2026, 9, 1))
            XCTAssertFalse(basis.input.resetsAtFirstPayment)
            let projection = MortgageProjection.project(basis.input)
            XCTAssertEqual(projection.finalDate, DemoDatabase.date(2046, 10, 1))
            XCTAssertEqual(projection.payments.first?.paidMinorUnits, status.nextInstalmentMinorUnits)
            XCTAssertEqual(projection.payments[projection.payments.count - 2].owedMinorUnits, 2_480_000, accuracy: 500)

            // The calendar: 1 January's rate isn't known yet; once December's average is in, it is.
            func revisionTitle() throws -> String? {
                try PropertyCalendar.obligations(db: db, propertyId: propertyId, from: today, to: DemoDatabase.date(2027, 2, 1), today: today)
                    .first { $0.kind == .mortgageRateReset }?.title
            }
            XCTAssertEqual(try revisionTitle(), "Mortgage rate revision")
            try InterestIndexValues.set(db: db, index: .euribor3M, period: .month, date: DemoDatabase.date(2026, 12, 1), valuePercent: 1.9, source: .manual)
            let title = try revisionTitle()!.replacingOccurrences(of: "\u{00A0}", with: " ")
            XCTAssertTrue(title.hasPrefix("Mortgage rate revision: 2.900%, instalment €"), title)

            // An override for the period wins in Profile.
            try MortgageRate.setOverride(db: db, propertyId: propertyId, periodStart: DemoDatabase.date(2026, 10, 1), ratePercent: 4)
            XCTAssertEqual(try MortgageRate.status(db: db, propertyId: propertyId, today: today)?.current?.ratePercent, 4)
        }
    }
}
