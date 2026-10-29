import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// The Dashboard's tenancy cash flow and property return widgets: synthetic data only. One EUR property "Property A"
/// with a tenancy "Room A" from July 2025 at €1,000 a month; rent credits each month, a few costs, a valuation account.
final class DashboardPropertyWidgetsTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var ids: [String: Int64] = [:]
    private static let tenantName = "Synthetic Tenant Person"

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
    }

    private func makeProperty(valuation: Bool = true, purchasePrice: Int? = nil) throws {
        try db.write { db in
            var rate = ExchangeRateSetting(eurToGbpRate: 0.85, updatedAt: Self.date(2025, 1, 1))
            try rate.insert(db)
            var property = Property(name: "Property A", country: "PT", purchasePriceMinorUnits: purchasePrice)
            try Properties.save(db: db, &property)
            let p = property.id!
            ids["property"] = p
            var account = Account(name: "Bank A", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "bank.csv", importedAt: Date())
            try batch.insert(db)
            ids["bank"] = account.id!
            ids["batch"] = batch.id!
            try Properties.setAccount(db: db, propertyId: p, accountId: account.id!, role: .current)
            var group = CategoryGroup(name: "Property A")
            try group.insert(db)
            try Properties.addCategoryGroup(db: db, propertyId: p, categoryGroupId: group.id!)
            var rent = Category(name: "Rental income", type: .income, groupId: group.id)
            try rent.insert(db)
            var repairs = Category(name: "Repairs", type: .expense, groupId: group.id)
            try repairs.insert(db)
            ids["rent"] = rent.id!
            ids["repairs"] = repairs.id!
            var tenancy = Tenancy(propertyId: p, referenceLabel: "Room A", contractNumber: "Room A", tenantName: Self.tenantName, startDate: Self.date(2025, 7, 1))
            try Tenancies.save(db: db, &tenancy)
            try Tenancies.setRent(db: db, tenancyId: tenancy.id!, from: Self.date(2025, 7, 1), monthlyAmountMinorUnits: 100_000)
            if valuation {
                // Not linked to the property: found by its name.
                var value = Account(name: "Property A valuation", currency: .eur, kind: .investment, trackingMode: .manual)
                try value.insert(db)
                var snapshot = BalanceSnapshot(accountId: value.id!, date: Self.date(2025, 12, 31), balanceMinorUnits: 20_000_000, note: nil)
                try snapshot.insert(db)
            }
        }
        for month in 7...12 { try movement(Self.date(2025, month, 2), 100_000, "rent") }
        try movement(Self.date(2025, 10, 9), -20_000, "repairs")
        for month in 1...10 { try movement(Self.date(2026, month, 2), 100_000, "rent") }
        try movement(Self.date(2026, 3, 9), -30_000, "repairs")
        try movement(Self.date(2026, 8, 9), -60_000, "repairs")
    }

    private func movement(_ date: Date, _ amount: Int, _ category: String) throws {
        try db.write { db in
            var t = Transaction(importBatchId: ids["batch"]!, accountId: ids["bank"]!, date: date, rawDescription: category, amountMinorUnits: amount,
                                categoryId: ids[category], status: .confirmed, categorizedBy: .manual, fingerprint: UUID().uuidString)
            try t.insert(db)
        }
    }

    private func load(year: Int = 2026, today: Date = DashboardPropertyWidgetsTests.date(2026, 10, 15), viewer: AccessActor? = nil) throws -> DashboardPropertyWidgets {
        try db.read { db in try DashboardPropertyWidgets.load(db: db, today: today, year: year, viewer: viewer) }
    }

    func testNoPropertyNoWidgets() throws {
        XCTAssertTrue(try load().isEmpty)
    }

    func testCashFlowByMonth() throws {
        try makeProperty()
        let flow = try XCTUnwrap(try load().cashFlows.first)
        XCTAssertEqual(flow.propertyName, "Property A")
        XCTAssertEqual(flow.currency, .eur)
        XCTAssertEqual(flow.year, 2026)
        XCTAssertEqual(flow.tenancyNames, ["Room A"])
        XCTAssertFalse(flow.tenancyNames.joined().contains(Self.tenantName))
        XCTAssertEqual(flow.months.count, 12)
        XCTAssertEqual(flow.months[0].received, 100_000)
        XCTAssertEqual(flow.months[0].paidOut, 0)
        XCTAssertEqual(flow.months[2].paidOut, 30_000)
        XCTAssertEqual(flow.months[2].net, 70_000)
        XCTAssertEqual(flow.months[7].net, 40_000)
        XCTAssertEqual(flow.months[10].received, 0)
        XCTAssertEqual(flow.months[11].net, 0)
        XCTAssertEqual(flow.totalReceived, 1_000_000)
        XCTAssertEqual(flow.totalPaidOut, 90_000)
        XCTAssertEqual(flow.totalNet, 910_000)
        // Another year shows that year's months.
        let last = try XCTUnwrap(try load(year: 2025).cashFlows.first)
        XCTAssertEqual(last.months[5].received, 0)
        XCTAssertEqual(last.months[6].received, 100_000)
        XCTAssertEqual(last.months[9].net, 80_000)
        XCTAssertEqual(last.totalNet, 580_000)
        // Nothing for a year that hasn't started.
        XCTAssertTrue(try load(year: 2027).isEmpty)
    }

    func testReturnForTheYearProjectedAndAgainstLastYear() throws {
        try makeProperty()
        let result = try XCTUnwrap(try load().returns.first)
        XCTAssertEqual(result.incomeToDate, 1_000_000)
        XCTAssertEqual(result.costsToDate, 90_000)
        XCTAssertEqual(result.mortgageInterestToDate, 0)
        XCTAssertEqual(result.netToDate, 910_000)
        // Jan 1 to 15 Oct inclusive is 288 days, 77 more to the year's end.
        XCTAssertEqual(Double(try XCTUnwrap(result.projectedNet)), 910_000 + 910_000.0 / 288 * 77, accuracy: 1)
        XCTAssertEqual(result.lastYearNet, 580_000)
        XCTAssertEqual(result.value, 20_000_000)
        XCTAssertEqual(result.valueBasis, .valuation("Property A valuation"))
        XCTAssertEqual(try XCTUnwrap(result.grossYield), 1_000_000.0 / 20_000_000 * 365 / 288, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(result.netYield), 910_000.0 / 20_000_000 * 365 / 288, accuracy: 1e-9)
        XCTAssertEqual(result.cumulative.count, 12)
        XCTAssertEqual(result.cumulative[0], 100_000)
        XCTAssertEqual(result.cumulative[2], 270_000)
        XCTAssertEqual(result.cumulative[9], 910_000)
        XCTAssertNil(result.cumulative[10])
        XCTAssertEqual(result.lastYearCumulative.count, 12)
        XCTAssertEqual(result.lastYearCumulative[5], 0)
        XCTAssertEqual(result.lastYearCumulative[11], 580_000)
        // A finished year is its own projection, with no later months to come.
        let past = try XCTUnwrap(try load(year: 2025, today: Self.date(2026, 10, 15)).returns.first)
        XCTAssertEqual(past.projectedNet, 580_000)
        XCTAssertNil(past.lastYearNet)
        XCTAssertEqual(past.cumulative.compactMap { $0 }.count, 12)
    }

    func testValueFallsBackToThePurchasePriceAndMayBeMissing() throws {
        try makeProperty(valuation: false, purchasePrice: 10_000_000)
        let priced = try XCTUnwrap(try load().returns.first)
        XCTAssertEqual(priced.value, 10_000_000)
        XCTAssertEqual(priced.valueBasis, .purchasePrice)
        XCTAssertEqual(try XCTUnwrap(priced.grossYield), 1_000_000.0 / 10_000_000 * 365 / 288, accuracy: 1e-9)
    }

    func testNoValueNoYields() throws {
        try makeProperty(valuation: false)
        let result = try XCTUnwrap(try load().returns.first)
        XCTAssertNil(result.value)
        XCTAssertNil(result.grossYield)
        XCTAssertNil(result.netYield)
        XCTAssertEqual(result.netToDate, 910_000)
    }

    func testViewerWithoutPropertyAccessSeesNothing() throws {
        try makeProperty()
        let member = try db.write { db -> AccessActor in
            var person = Person(name: "Synthetic Member")
            try People.save(db: db, &person)
            var user = AppUser(personId: person.id!, displayName: "Member", isAdmin: false, createdAt: Self.date(2026, 10, 1))
            try user.insert(db)
            return try AccessActor.load(appUserId: user.id!, db: db)
        }
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO memberPermission(appUserId, area, level) VALUES (?, ?, ?)
                ON CONFLICT(appUserId, area) DO UPDATE SET level = excluded.level
                """, arguments: [member.appUserId, AccessArea.property.storageKey, PermissionLevel.none.rawValue])
        }
        XCTAssertTrue(try load(viewer: member).isEmpty)
        XCTAssertFalse(try load().isEmpty)
    }
}
