import XCTest
import GRDB
@testable import BudgetCore
@testable import BudgetDemo

final class PropertyGlanceTests: XCTestCase {
    private var manager: DatabaseManager!
    private var evidence: URL!
    private var db: DatabaseQueue { manager.dbQueue }

    override func setUpWithError() throws {
        (manager, evidence) = try PhoneDemoFixture.build()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: evidence)
    }

    private var propertyId: Int64 {
        get throws { try db.read { db in try Property.filter(Column("name") == DemoDatabase.propertyName).fetchOne(db)!.id! } }
    }

    /// The demo flat on 15 October 2026: let since August 2024 with no end, October's rent
    /// received on the 12th with no receipt issued yet, September's recharge drafted (ready to
    /// send), the mortgage as the Mac's property screen reads it, and the next 60 days' obligations.
    func testPropertyGlanceOnTheDemo() throws {
        let today = PhoneDemoFixture.today
        let id = try propertyId
        let summary = try db.read { db in try PropertyGlance.make(db: db, propertyId: id, today: today) }
        XCTAssertEqual(summary.property.name, DemoDatabase.propertyName)
        XCTAssertEqual(summary.letSince, DemoDatabase.date(2024, 8, 1))
        XCTAssertNil(summary.contractTo)

        // Rent: the rent line of October's cash flow (`PropertyMonthBreakdown`).
        let october = DateInterval(start: DemoDatabase.date(2026, 10, 1), end: DemoDatabase.date(2026, 11, 1))
        let rentLine = try XCTUnwrap(try db.read { db in
            try PropertyFinance.monthBreakdown(db: db, propertyId: id, interval: october).group(.rent)?.lines.last
        })
        XCTAssertEqual(summary.rent, .received(PropertyDates.day(rentLine.transaction.date)))
        XCTAssertEqual(summary.rent, .received(DemoDatabase.date(2026, 10, 12)))
        // The rent figure beside it is that line's amount, in the property's currency.
        XCTAssertEqual(summary.rentMinorUnits, rentLine.counted.native)
        XCTAssertGreaterThan(summary.rentMinorUnits ?? 0, 0)
        XCTAssertEqual(summary.receipt, .pending)
        XCTAssertEqual(summary.lastRecharge, .readyToSend)
        // The latest statement's month and total (`Recharges.statements`).
        let statement = try XCTUnwrap(try db.read { db -> RechargeStatement? in
            try Tenancies.all(db: db, propertyId: id).compactMap(\.id)
                .compactMap { try Recharges.statements(db: db, tenancyId: $0).first }.max { $0.month < $1.month }
        })
        XCTAssertEqual(summary.lastRechargeMonth, statement.month)
        XCTAssertEqual(summary.lastRechargeMonth, DemoDatabase.date(2026, 9, 1))
        XCTAssertEqual(summary.lastRechargeTotalMinorUnits, statement.totalMinorUnits)
        XCTAssertGreaterThan(summary.lastRechargeTotalMinorUnits ?? 0, 0)

        // Mortgage: outstanding as the Mac's loan chart and summary read it
        // (`PropertyFinance.balance` of the mortgage accounts), progress from
        // `MortgageHistory.progress`, the next instalment, rate and review from `MortgageRate.status`.
        let mortgage = try XCTUnwrap(summary.mortgage)
        let (owed, terms, status, estimate) = try db.read { db -> (Int, PropertyMortgageTerms, MortgageRate.Status, MortgageHistory.Estimate?) in
            let property = try Property.fetchOne(db, key: id)!
            let accounts = try Properties.accounts(db: db, propertyId: id, role: .mortgage).map(\.accountId)
            let owed = try PropertyFinance.balance(db: db, property: property, conversion: try CurrencyConversion.current(db: db),
                                                   accountIds: accounts, asOf: PropertyDates.day(today)).native
            return (owed, try MortgageTerms.terms(db: db, propertyId: id), try MortgageRate.status(db: db, propertyId: id, today: today)!,
                    try MortgageHistory.estimate(db: db, propertyId: id))
        }
        XCTAssertGreaterThan(owed, 0)
        XCTAssertEqual(mortgage.outstandingMinorUnits, owed)
        // In pounds too, as the Mac's property summary (`PropertySummary.outstandingLoan`) reads it to the end of today.
        let macSummary = try db.read { db in
            try PropertyFinance.summary(db: db, propertyId: id, period: .custom(DateInterval(
                start: DemoDatabase.date(2026, 10, 1), end: PropertyDates.nextDay(PropertyDates.day(today)))), today: today)
        }
        XCTAssertEqual(mortgage.outstandingMinorUnits, macSummary.outstandingLoan.native)
        XCTAssertEqual(mortgage.outstandingGBPMinorUnits, macSummary.outstandingLoan.gbp)
        XCTAssertGreaterThan(mortgage.outstandingGBPMinorUnits, 0)
        // The Mac screen's own path: the loan chart's last point (`PropertyFinance.loanBalances`).
        let chartOwed = try db.read { db -> Int in
            let property = try Property.fetchOne(db, key: id)!
            let accounts = try Properties.accounts(db: db, propertyId: id, role: .mortgage).map(\.accountId)
            return try PropertyFinance.loanBalances(db: db, property: property, accountIds: accounts, days: [PropertyDates.day(today)]).last!.native
        }
        XCTAssertEqual(mortgage.outstandingMinorUnits, chartOwed)
        XCTAssertEqual(mortgage.progress, MortgageHistory.progress(terms: terms, owedMinorUnits: owed, today: today))
        XCTAssertNotNil(mortgage.progress)
        // The estimated history before the first statement starts from the amount borrowed the
        // progress bar measures against, and ends above what is owed today.
        let history = try XCTUnwrap(estimate)
        XCTAssertEqual(history.principalMinorUnits, mortgage.progress?.borrowedMinorUnits)
        XCTAssertGreaterThan(history.anchor.owedBeforeMinorUnits, mortgage.outstandingMinorUnits)
        XCTAssertEqual(mortgage.nextInstalmentDate, status.nextDue)
        XCTAssertEqual(mortgage.nextInstalmentDate, DemoDatabase.date(2026, 11, 1))
        XCTAssertEqual(mortgage.nextInstalmentMinorUnits, status.nextInstalmentMinorUnits)
        XCTAssertNotNil(mortgage.nextInstalmentMinorUnits)
        XCTAssertEqual(mortgage.ratePercent, status.current?.ratePercent)
        XCTAssertNotNil(mortgage.ratePercent)
        XCTAssertEqual(mortgage.nextReview, status.nextRevision)
        XCTAssertEqual(mortgage.nextReview, DemoDatabase.date(2027, 1, 1))

        // Coming up: the obligations calendar over the next 60 days, by date.
        let end = MonthRange.calendar.date(byAdding: .day, value: PropertyGlance.comingUpDays, to: today)!
        let obligations = try db.read { db in try PropertyCalendar.obligations(db: db, propertyId: id, from: today, to: end, today: today) }
        XCTAssertFalse(summary.comingUp.isEmpty)
        XCTAssertEqual(summary.comingUp, obligations)
        XCTAssertEqual(summary.comingUp.map(\.date), summary.comingUp.map(\.date).sorted())

        // Every property, by name.
        XCTAssertEqual(try db.read { db in try PropertyGlance.all(db: db, today: today) }, [summary])
    }

    /// Rent not in yet: expected on the day of the month the last one came, late once that
    /// day is more than the receipt matching window (10 days) behind.
    func testRentExpectedThenLate() throws {
        let id = try propertyId
        let early = try db.read { db in try PropertyGlance.make(db: db, propertyId: id, today: DemoDatabase.date(2026, 11, 5)) }
        XCTAssertEqual(early.rent, .expected(DemoDatabase.date(2026, 11, 12)))
        // Not in yet: the tenancy's rent on the day it's due (`Tenancies.rent`).
        let tenancyId = try XCTUnwrap(try db.read { db in try Tenancies.all(db: db, propertyId: id).last?.id })
        let due = try db.read { db in try Tenancies.rent(db: db, tenancyId: tenancyId, at: DemoDatabase.date(2026, 11, 12)) }
        XCTAssertNotNil(due)
        XCTAssertEqual(early.rentMinorUnits, due)
        let onTheWindow = try db.read { db in try PropertyGlance.make(db: db, propertyId: id, today: DemoDatabase.date(2026, 11, 22)) }
        XCTAssertEqual(onTheWindow.rent, .expected(DemoDatabase.date(2026, 11, 12)))
        let late = try db.read { db in try PropertyGlance.make(db: db, propertyId: id, today: DemoDatabase.date(2026, 11, 23)) }
        XCTAssertEqual(late.rent, .late(since: DemoDatabase.date(2026, 11, 12)))
        XCTAssertEqual(late.rentMinorUnits, due)
    }

    /// A receipt covering the month: issued.
    func testReceiptIssuedWhenOneCoversTheMonth() throws {
        let id = try propertyId
        let september = try db.read { db in try PropertyGlance.make(db: db, propertyId: id, today: DemoDatabase.date(2026, 9, 20)) }
        XCTAssertEqual(september.receipt, .issued)
    }

    /// A property with no mortgage account, tenancy or recharge has none of them.
    func testPropertyWithoutMortgageHasNilMortgage() throws {
        let today = PhoneDemoFixture.today
        let other = try db.write { db -> Int64 in
            var property = Property(name: "Property B", country: "PT", currency: .eur)
            try Properties.save(db: db, &property)
            return property.id!
        }
        let summary = try db.read { db in try PropertyGlance.make(db: db, propertyId: other, today: today) }
        XCTAssertEqual(summary.property.name, "Property B")
        XCTAssertNil(summary.mortgage)
        XCTAssertNil(summary.letSince)
        XCTAssertNil(summary.contractTo)
        XCTAssertEqual(summary.rent, PropertyGlance.RentStatus.none)
        XCTAssertEqual(summary.receipt, PropertyGlance.ReceiptStatus.none)
        XCTAssertNil(summary.lastRecharge)
        XCTAssertNil(summary.rentMinorUnits)
        XCTAssertNil(summary.lastRechargeMonth)
        XCTAssertNil(summary.lastRechargeTotalMinorUnits)
        XCTAssertEqual(summary.comingUp.map(\.date), summary.comingUp.map(\.date).sorted())

        let all = try db.read { db in try PropertyGlance.all(db: db, today: today) }
        XCTAssertEqual(all.map(\.property.name), [DemoDatabase.propertyName, "Property B"])
        XCTAssertThrowsError(try db.read { db in try PropertyGlance.make(db: db, propertyId: 9_999, today: today) })
    }

    /// A tenancy that starts mid-month isn't due (or late) before it starts: rent is expected
    /// from its first day.
    func testRentNeverLateBeforeTheTenancyStarts() throws {
        let other = try db.write { db -> Int64 in
            var property = Property(name: "Property B", country: "PT", currency: .eur)
            try Properties.save(db: db, &property)
            var tenancy = Tenancy(propertyId: property.id!, referenceLabel: "Tenancy B", startDate: DemoDatabase.date(2026, 11, 20))
            try tenancy.insert(db)
            _ = try Tenancies.setRent(db: db, tenancyId: tenancy.id!, from: DemoDatabase.date(2026, 11, 20), monthlyAmountMinorUnits: 90_000)
            return property.id!
        }
        let before = try db.read { db in try PropertyGlance.make(db: db, propertyId: other, today: DemoDatabase.date(2026, 11, 10)) }
        XCTAssertEqual(before.rent, PropertyGlance.RentStatus.none)
        let firstWeek = try db.read { db in try PropertyGlance.make(db: db, propertyId: other, today: DemoDatabase.date(2026, 11, 25)) }
        XCTAssertEqual(firstWeek.letSince, DemoDatabase.date(2026, 11, 20))
        XCTAssertEqual(firstWeek.rent, .expected(DemoDatabase.date(2026, 11, 20)))
        XCTAssertEqual(firstWeek.rentMinorUnits, 90_000)
        let late = try db.read { db in try PropertyGlance.make(db: db, propertyId: other, today: DemoDatabase.date(2026, 12, 12)) }
        XCTAssertEqual(late.rent, .late(since: DemoDatabase.date(2026, 12, 1)))
    }
}
