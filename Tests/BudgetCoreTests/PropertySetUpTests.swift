import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// The property set-up from a plan (phase 2, Task 5). Synthetic names and values only.
final class PropertySetUpTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
        try db.write { db in
            for (name, kind) in [("Bank A", AccountKind.cash), ("Loan A", .credit), ("Deposit A", .credit)] {
                var account = Account(name: name, currency: .eur, kind: kind, trackingMode: .imported)
                try account.insert(db)
                var batch = ImportBatch(accountId: account.id!, sourceFileName: "\(name).csv", importedAt: Date())
                try batch.insert(db)
            }
            var group = CategoryGroup(name: "Group A")
            try group.insert(db)
            var rent = Category(name: "Rental income", type: .income, groupId: group.id)
            try rent.insert(db)
            let bank = try Account.filter(Column("name") == "Bank A").fetchOne(db)!
            let batch = try ImportBatch.filter(Column("accountId") == bank.id!).fetchOne(db)!
            for (month, amount) in [(1, 100_000), (2, 100_000), (3, 110_000)] {
                var credit = Transaction(importBatchId: batch.id!, accountId: bank.id!, date: Self.date(2025, month, 2), rawDescription: "Rent",
                                         amountMinorUnits: amount, categoryId: rent.id, status: .confirmed, categorizedBy: .manual,
                                         fingerprint: UUID().uuidString)
                try credit.insert(db)
            }
        }
    }

    private func rows() -> [RentReceiptsExport.Row] {
        [(1, "1", 100_000), (2, "2", 100_000), (3, "3", 110_000)].map { month, number, amount in
            let (start, _) = MonthRange.of(year: 2025, month: month)
            let end = MonthRange.calendar.date(byAdding: .day, value: -1, to: MonthRange.calendar.date(byAdding: .month, value: 1, to: start)!)!
            return RentReceiptsExport.Row(rowNumber: month + 1, reference: "Room Contract AB", contractNumber: "3001", receiptNumber: number,
                                          tenant: "Tenant B", periodStart: start, periodEnd: end, receiptDate: start, amountMinorUnits: amount)
        }
    }

    private var plan: PropertySetUp.Plan {
        PropertySetUp.Plan(
            property: .init(name: "Property A", country: "PT", currency: .eur, matrixArticle: nil, purchasePrice: "200000", purchaseDate: nil),
            owners: [.init(name: "Person A", shortName: "A", share: 50, from: nil, to: nil),
                     .init(name: "Person B", shortName: "B", share: 50, from: nil, to: nil)],
            accounts: [.init(account: "Bank A", role: .current), .init(account: "Loan A", role: .mortgage), .init(account: "Deposit A", role: .deposit)],
            categoryGroups: ["Group A"],
            tenancies: [.init(contractNumber: nil, advanceRentMonths: 2, depositMonths: 2,
                              rents: [.init(from: "start", amount: "1000"), .init(from: "2025-03-01", amount: "1100")], rentsFromReceipts: nil)],
            seedEvidenceRules: true)
    }

    func testRunsThePlanIdempotently() throws {
        let first = try db.write { db in try PropertySetUp.run(db: db, plan: plan, receiptRows: rows()) }
        XCTAssertTrue(first.createdProperty)
        XCTAssertEqual(first.createdPeople, ["Person A", "Person B"])
        XCTAssertEqual(first.receiptsImport?.createdReceipts, 3)
        XCTAssertEqual(first.matching.created.count, 3)
        XCTAssertEqual(first.matching.unmatchedReceipts, [])
        XCTAssertEqual(first.seededRules.count, 2)
        let tenancyId = try XCTUnwrap(first.derivedRents.keys.first)
        XCTAssertEqual(first.derivedRents[tenancyId]?.map(\.monthlyAmountMinorUnits), [100_000, 110_000])
        XCTAssertEqual(first.derivedRents[tenancyId]?.map(\.fromDate), [Self.date(2025, 1, 1), Self.date(2025, 3, 1)])
        try db.read { db in
            let p = first.propertyId
            XCTAssertEqual(try Properties.shares(db: db, propertyId: p, at: Self.date(2030, 1, 1)).map(\.shareBasisPoints), [5_000, 5_000])
            XCTAssertEqual(try Properties.accounts(db: db, propertyId: p).map(\.role), [.current, .mortgage, .deposit])
            XCTAssertEqual(try Properties.categoryGroupIds(db: db, propertyId: p).count, 1)
            let tenancy = try Tenancy.fetchOne(db, key: tenancyId)!
            XCTAssertEqual([tenancy.advanceRentMonths, tenancy.depositMonths], [2, 2])
            XCTAssertEqual(try Tenancies.rents(db: db, tenancyId: tenancyId).map(\.fromDate), [Self.date(2025, 1, 1), Self.date(2025, 3, 1)])
            XCTAssertEqual(try Property.fetchOne(db, key: p)?.purchasePriceMinorUnits, 20_000_000)
        }

        let second = try db.write { db in try PropertySetUp.run(db: db, plan: plan, receiptRows: rows()) }
        XCTAssertFalse(second.createdProperty)
        XCTAssertEqual(second.createdPeople, [])
        XCTAssertEqual(second.receiptsImport?.unchangedReceipts, 3)
        XCTAssertEqual(second.matching.created, [])
        XCTAssertEqual(second.seededRules, [])
        try db.read { db in
            XCTAssertEqual(try Property.fetchCount(db), 1)
            XCTAssertEqual(try Person.fetchCount(db), 2)
            XCTAssertEqual(try RentReceiptPayment.fetchCount(db), 3)
        }
    }

    func testRentsFromReceiptsAndErrors() throws {
        var derive = plan
        derive.tenancies = [.init(contractNumber: "3001", advanceRentMonths: nil, depositMonths: nil, rents: nil, rentsFromReceipts: true)]
        let outcome = try db.write { db in try PropertySetUp.run(db: db, plan: derive, receiptRows: rows()) }
        try db.read { db in
            XCTAssertEqual(try Tenancies.rents(db: db, tenancyId: outcome.derivedRents.keys.first!).map(\.monthlyAmountMinorUnits), [100_000, 110_000])
        }
        var missing = plan
        missing.accounts = [.init(account: "Nope", role: .current)]
        XCTAssertThrowsError(try db.write { db in try PropertySetUp.run(db: db, plan: missing, receiptRows: nil) }) {
            XCTAssertEqual($0 as? PropertySetUp.SetUpError, .accountNotFound("Nope"))
        }
        var noTenancy = plan
        noTenancy.tenancies = [.init(contractNumber: "9999", advanceRentMonths: 1, depositMonths: nil, rents: nil, rentsFromReceipts: nil)]
        XCTAssertThrowsError(try db.write { db in try PropertySetUp.run(db: db, plan: noTenancy, receiptRows: nil) }) {
            XCTAssertEqual($0 as? PropertySetUp.SetUpError, .tenancyNotFound("9999"))
        }
        // The plan reads from JSON.
        let json = try JSONEncoder().encode(plan)
        XCTAssertEqual(try JSONDecoder().decode(PropertySetUp.Plan.self, from: json), plan)
    }

    func testPlanHardening() throws {
        let json = try JSONEncoder().encode(plan)
        XCTAssertEqual(try PropertySetUp.decodePlan(json), plan)
        let typo = Data((#"{"property": {"name": "P", "country": "PT", "currency": "eur", "purchse": "1"}, "owners": [{"name": "A", "share": 100, "sharee": 1}],"#
            + #""accounts": [], "categoryGroups": [], "tenancies": [{"rents": [{"from": "start", "amount": "1", "x": 1}]}], "extra": true}"#).utf8)
        XCTAssertThrowsError(try PropertySetUp.decodePlan(typo)) {
            XCTAssertEqual($0 as? PropertySetUp.SetUpError, .unknownKeys(["extra", "property.purchse", "owners[0].sharee", "tenancies[0].rents[0].x"]))
        }
        // No whole-month receipt to read the rent from: refused rather than clearing the history.
        var derive = plan
        derive.tenancies = [.init(contractNumber: "3001", advanceRentMonths: nil, depositMonths: nil, rents: nil, rentsFromReceipts: true)]
        let partial = rows().map { row -> RentReceiptsExport.Row in
            var row = row
            row.periodEnd = MonthRange.calendar.date(byAdding: .day, value: -1, to: row.periodEnd)!
            return row
        }
        XCTAssertThrowsError(try db.write { db in try PropertySetUp.run(db: db, plan: derive, receiptRows: partial) }) {
            XCTAssertEqual($0 as? PropertySetUp.SetUpError, .noWholeMonthReceipts("3001"))
        }
    }
}
