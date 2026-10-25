import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Recurring costs read per payee series within a category, and the "Not expected any more"
/// decision on an overdue one (2026-10-24 fix). Synthetic payees and amounts only.
final class PropertyRecurringSeriesTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var ids: [String: Int64] = [:]

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
        try db.write { db in
            var property = Property(name: "Property R", country: "PT", purchasePriceMinorUnits: 10_000_000)
            try Properties.save(db: db, &property)
            ids["property"] = property.id!
            var account = Account(name: "Bank R", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            ids["bank"] = account.id!
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "r.csv", importedAt: Date())
            try batch.insert(db)
            ids["batch"] = batch.id!
            try Properties.setAccount(db: db, propertyId: property.id!, accountId: account.id!, role: .current)
            var group = CategoryGroup(name: "Property R")
            try group.insert(db)
            try Properties.addCategoryGroup(db: db, propertyId: property.id!, categoryGroupId: group.id!)
            for (key, name) in [("insurance", "Building insurance"), ("licence", "Licence"), ("extra", "Condo extra"),
                                ("utilities", "Utilities"), ("condo", "Condomínio")] {
                var category = Category(name: name, type: .expense, groupId: group.id)
                try category.insert(db)
                ids[key] = category.id!
            }
        }
    }

    private var propertyId: Int64 { ids["property"]! }

    private func add(_ category: String, _ date: Date, _ amount: Int, _ description: String) throws {
        try db.write { db in
            var row = Transaction(importBatchId: ids["batch"]!, accountId: ids["bank"]!, date: date, rawDescription: description,
                                  amountMinorUnits: amount, categoryId: ids[category], status: .confirmed, categorizedBy: .manual,
                                  fingerprint: UUID().uuidString)
            try row.insert(db)
        }
    }

    private func checks(_ year: Int, today: Date) throws -> PropertyCheckReport {
        try db.read { db in
            try PropertyChecks.run(db: db, propertyId: propertyId, period: PropertyPeriod.calendarYear(year).interval, today: today)
        }
    }

    private func patterns(today: Date, yearlyInsurance: Bool = false) throws -> [PropertyRecurringPattern] {
        try db.read { db in
            try PropertyCalendar.recurringPatterns(db: db, propertyId: propertyId, asOf: today, includeYearlyInsurance: yearlyInsurance)
        }
    }

    // MARK: Detection

    /// Semi-annual insurer, then a quarterly one, then a yearly one: the insurer changed, so the
    /// earlier series have ended and only the latest is expected, a year after its payment.
    func testProviderSwitchEndsTheEarlierSeries() throws {
        for (y, m) in [(2023, 6), (2023, 12), (2024, 6), (2024, 12)] {
            try add("insurance", Self.date(y, m, 2), -19_850, "SEPA DD SEGUROS ALFA APOLICE 7781")
        }
        for (y, m, d) in [(2025, 8, 18), (2025, 10, 20), (2026, 1, 19)] {
            try add("insurance", Self.date(y, m, d), -10_512, "DD SEGURADORA BETA 55120")
        }
        try add("insurance", Self.date(2026, 3, 23), -40_144, "DD GAMA SEGUROS GERAIS 990001")
        let today = Self.date(2026, 10, 24)
        let report = try checks(2026, today: today)
        XCTAssertEqual(report.missingRecurringCosts, [])
        // The new insurer's policy is read as yearly: next due about a year on.
        let insurance = try patterns(today: today, yearlyInsurance: true).filter { $0.categoryId == ids["insurance"] }
        XCTAssertEqual(insurance.count, 1)
        XCTAssertEqual(insurance.first?.everyMonths, 12)
        XCTAssertEqual(insurance.first?.nextDate, Self.date(2027, 3, 23))
        XCTAssertEqual(insurance.first?.lastAmountMinorUnits, 40_144)
        // The renewal follows the new policy.
        let obligations = try db.read { db in
            try PropertyCalendar.obligations(db: db, propertyId: propertyId, from: today, to: Self.date(2027, 10, 1), today: today)
        }
        XCTAssertEqual(obligations.filter { $0.kind == .insuranceRenewal }.map(\.date), [Self.date(2027, 3, 23)])
        XCTAssertFalse(obligations.contains { $0.kind == .recurringCost && $0.categoryId == ids["insurance"] })
    }

    /// The same creditor identifier is one series however the bank words the rest; two
    /// creditors with the same wording are two.
    func testSEPACreditorIdentifierNamesTheSeries() {
        let keys = PropertyRecurringSeries.keys(["SEPA DD PT12ZZZ100200 SEGURO CASA", "SEPA DD PT12ZZZ100200 SEG. HABITACAO",
                                                 "SEPA DD PT55ZZZ300400 SEGURO CASA"])
        XCTAssertEqual(keys[0], keys[1])
        XCTAssertNotEqual(keys[0], keys[2])
        // Month names and references don't split a payee.
        let condo = PropertyRecurringSeries.keys(["CONDOMINIO JAN 2025 REF 11", "CONDOMINIO ABRIL 2025 REF 12", "Condominio Jul"])
        XCTAssertEqual(Set(condo).count, 1)
    }

    func testAnnualIsExpectedTwelveMonthsOn() throws {
        try add("licence", Self.date(2024, 3, 10), -2_000, "CAMARA LICENCA")
        try add("licence", Self.date(2025, 3, 10), -2_000, "CAMARA LICENCA")
        XCTAssertEqual(try checks(2025, today: Self.date(2025, 10, 1)).missingRecurringCosts, [])
        XCTAssertEqual(try patterns(today: Self.date(2025, 10, 1)).first { $0.categoryId == ids["licence"] }?.everyMonths, 12)
        let late = try checks(2026, today: Self.date(2026, 4, 1))
        XCTAssertEqual(late.missingRecurringCosts.map(\.expectedDate), [Self.date(2026, 3, 10)])
    }

    func testSemiAnnualIsExpectedSixMonthsOn() throws {
        for (y, m) in [(2025, 1), (2025, 7), (2026, 1)] { try add("extra", Self.date(y, m, 5), -30_000, "CONDOMINIO OBRAS FUNDO") }
        let pattern = try XCTUnwrap(try patterns(today: Self.date(2026, 3, 1)).first { $0.categoryId == ids["extra"] })
        XCTAssertEqual(pattern.everyMonths, 6)
        XCTAssertEqual(pattern.nextDate, Self.date(2026, 7, 5))
        XCTAssertEqual(try checks(2026, today: Self.date(2026, 7, 15)).missingRecurringCosts, [])
        XCTAssertEqual(try checks(2026, today: Self.date(2026, 8, 10)).missingRecurringCosts.map(\.expectedDate), [Self.date(2026, 7, 5)])
    }

    func testMonthlyOverdueAfterTheGrace() throws {
        for month in 1...9 { try add("utilities", Self.date(2025, month, 8), -4_500, "ELECTRICIDADE DELTA \(month)00\(month)") }
        XCTAssertEqual(try checks(2025, today: Self.date(2025, 10, 20)).missingRecurringCosts, [])
        let late = try checks(2025, today: Self.date(2025, 10, 30))
        XCTAssertEqual(late.missingRecurringCosts.map(\.expectedDate), [Self.date(2025, 10, 8)])
        XCTAssertEqual(late.missingRecurringCosts.first?.pattern.title, "Utilities")
    }

    /// Two payees in one category that ran side by side: one stopping is still overdue (no
    /// switch: the other didn't start after it), and it's named by its payee.
    func testAStoppedSeriesBesideAnotherIsStillOverdue() throws {
        for month in 1...9 { try add("utilities", Self.date(2025, month, 8), -4_500, "ELECTRICIDADE DELTA") }
        for month in 1...6 { try add("utilities", Self.date(2025, month, 20), -2_000, "AGUAS EPSILON") }
        let report = try checks(2025, today: Self.date(2025, 9, 25))
        XCTAssertEqual(report.missingRecurringCosts.map(\.expectedDate), [Self.date(2025, 7, 20)])
        XCTAssertEqual(report.missingRecurringCosts.first?.pattern.title, "Utilities · Aguas Epsilon")
    }

    // MARK: Clearing

    func testNotExpectedAnyMoreClearsTheItemAndCanBeUndone() throws {
        try add("licence", Self.date(2024, 3, 10), -2_000, "CAMARA LICENCA")
        try add("licence", Self.date(2025, 3, 10), -2_000, "CAMARA LICENCA")
        let today = Self.date(2026, 4, 1)
        let item = try XCTUnwrap(try checks(2026, today: today).missingRecurringCosts.first)

        try db.write { db in
            try PropertyCheckDecisions.stopExpecting(db: db, propertyId: propertyId, pattern: item.pattern, now: Self.date(2026, 4, 1))
        }
        let cleared = try checks(2026, today: today)
        XCTAssertEqual(cleared.missingRecurringCosts, [])
        XCTAssertEqual(cleared.notExpectedRecurringCosts.map(\.series), [item.pattern.series])
        XCTAssertEqual(cleared.issueCount, 0)
        // Nor projected in the calendar any more.
        XCTAssertFalse(try patterns(today: today).contains { $0.categoryId == ids["licence"] })

        // Undo: appended, not erased.
        try db.write { db in
            try PropertyCheckDecisions.expectAgain(db: db, propertyId: propertyId, series: item.pattern.series, now: Self.date(2026, 4, 2))
        }
        let back = try checks(2026, today: today)
        XCTAssertEqual(back.missingRecurringCosts.map(\.pattern.series), [item.pattern.series])
        XCTAssertEqual(back.notExpectedRecurringCosts, [])
        XCTAssertEqual(try db.read { db in try PropertyCheckDecision.fetchCount(db) }, 2)
    }

    /// A payment of the series after the decision means it carries on: expected again.
    func testAPaymentAfterTheDecisionExpectsTheSeriesAgain() throws {
        try add("licence", Self.date(2024, 3, 20), -2_000, "CAMARA LICENCA")
        try add("licence", Self.date(2025, 3, 20), -2_000, "CAMARA LICENCA")
        let item = try XCTUnwrap(try checks(2026, today: Self.date(2026, 4, 10)).missingRecurringCosts.first)
        try db.write { db in
            try PropertyCheckDecisions.stopExpecting(db: db, propertyId: propertyId, pattern: item.pattern, now: Self.date(2026, 4, 10))
        }
        // Paid late, imported after the decision.
        try add("licence", Self.date(2026, 3, 28), -2_100, "CAMARA LICENCA")
        let later = try checks(2027, today: Self.date(2027, 4, 15))
        XCTAssertEqual(later.missingRecurringCosts.map(\.expectedDate), [Self.date(2027, 3, 28)])
        XCTAssertEqual(later.notExpectedRecurringCosts, [])
    }

    func testTheDecisionTableSyncs() {
        let table = SyncSchema.tables.first { $0.name == PropertyCheckDecision.databaseTableName }
        XCTAssertEqual(table?.foreignKeys, ["propertyId": "property", "categoryId": "category", "accountId": "account"])
    }
}
