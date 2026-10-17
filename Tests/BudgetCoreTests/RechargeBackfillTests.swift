import XCTest
import GRDB
@testable import BudgetCore

/// The recharges history backfill (plan phase 5 Task 4): plan, providers from presets,
/// invoice intake with outcomes, statements rebuilt from the tenant's transfers, and what
/// netting would change per tax year. Synthetic data only.
final class RechargeBackfillTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var ids: [String: Int64] = [:]
    private var root: URL!

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func id(_ key: String) -> Int64 { ids[key]! }

    private static let plan = RechargeBackfill.Plan(
        property: "Property A", tenancyContract: "3001", tenancyReference: nil, since: "2024-01-01", invoiceFolders: [],
        providers: [.init(preset: "Municipal water (SIMAR)", name: "Example Water", accountReference: nil, bankDescriptionPattern: "EXAMPLE WTR")],
        trackerTotals: nil, filedTaxYears: [2024])

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Backfill-\(UUID().uuidString)", isDirectory: true)
        try db.write { db in
            var a = Person(name: "Person A")
            try People.save(db: db, &a)
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            let p = property.id!
            ids["property"] = p
            _ = try Properties.setOwners(db: db, propertyId: p, [PropertyOwner(propertyId: p, personId: a.id!, shareBasisPoints: 10_000)])
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
            for (key, name, type) in [("rent", "Rental income", CategoryType.income), ("utilities", "Utilities", .expense)] {
                var category = Category(name: name, type: type, groupId: group.id)
                try category.insert(db)
                ids[key] = category.id!
            }
            try TaxExpenseTypeMap.seed(db: db, propertyId: p)
            try HMRCRates.set(db: db, startYear: 2024, currencyCode: "EUR", gbpPerUnit: 0.8, source: .manual)
            var tenancy = Tenancy(propertyId: p, referenceLabel: "Room Contract AB", contractNumber: "3001", startDate: Self.date(2024, 3, 15))
            try Tenancies.save(db: db, &tenancy)
            ids["tenancy"] = tenancy.id!
            for (number, month) in [("1", 5), ("2", 6), ("3", 7), ("4", 8)] {
                var receipt = RentReceipt(tenancyId: tenancy.id!, receiptNumber: number, periodStart: Self.date(2024, month, 1),
                                          periodEnd: MonthRange.calendar.date(byAdding: DateComponents(month: 1, day: -1), to: Self.date(2024, month, 1))!,
                                          receiptDate: Self.date(2024, month, 2), amountMinorUnits: 100_000)
                try RentReceipts.save(db: db, &receipt)
            }
            try RechargeBackfill.ensureProviders(db: db, propertyId: p, plan: Self.plan)
            ids["water"] = try XCTUnwrap(try UtilityProvider.fetchOne(db)).id!
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func transaction(_ category: String?, _ date: Date, _ amount: Int, _ text: String) throws -> Int64 {
        try db.write { db in
            var transaction = Transaction(importBatchId: id("batch"), accountId: id("bank"), date: date, rawDescription: text,
                                          amountMinorUnits: amount, categoryId: category.flatMap { ids[$0] }, status: .confirmed,
                                          categorizedBy: .manual, fingerprint: UUID().uuidString)
            try transaction.insert(db)
            return transaction.id!
        }
    }

    private func invoice(_ number: String, issued: Date, amount: Int, period: (Date, Date)? = nil) throws {
        try db.write { db in
            var invoice = UtilityInvoice(providerId: id("water"), invoiceNumber: number, periodStart: period?.0, periodEnd: period?.1,
                                         issueDate: issued, amountMinorUnits: amount)
            try Recharges.saveInvoice(db: db, &invoice)
        }
    }

    func testThePlanRefusesUnknownKeysAndBadDates() throws {
        XCTAssertThrowsError(try RechargeBackfill.decodePlan(Data(#"{"property":"P","since":"2024-01-01","invoiceFolders":[],"providers":[],"extra":1}"#.utf8))) {
            XCTAssertEqual($0 as? RechargeBackfill.BackfillError, .unknownKeys(["extra"]))
        }
        XCTAssertThrowsError(try RechargeBackfill.decodePlan(Data(#"{"property":"P","since":"2024-13-01","invoiceFolders":[],"providers":[]}"#.utf8)))
        let plan = try RechargeBackfill.decodePlan(Data(#"{"property":"P","since":"2024-01-01","invoiceFolders":["~/x"],"providers":[{"preset":"EDP"}]}"#.utf8))
        XCTAssertEqual(plan.providers.first?.preset, "EDP")
        // Providers from presets once, by name.
        try db.write { db in
            XCTAssertEqual(try RechargeBackfill.ensureProviders(db: db, propertyId: id("property"), plan: Self.plan).count, 1)
            var unknown = Self.plan
            unknown.providers = [.init(preset: "Nope", name: nil, accountReference: nil, bankDescriptionPattern: nil)]
            XCTAssertThrowsError(try RechargeBackfill.ensureProviders(db: db, propertyId: id("property"), plan: unknown))
        }
    }

    func testIntakeRecordsMatchesAndExplains() throws {
        try transaction("utilities", Self.date(2024, 5, 20), -2_000, "SEPADD/EXAMPLE WTR")
        try transaction(nil, Self.date(2024, 1, 2), 10, "OPENING")
        func pdf(_ lines: [String], _ name: String) -> URL { EvidenceTestPDFs.textPDF(lines, name: name) }
        let matched = pdf(["SIMAR services", "2024-05-02", "ATCUD:ABCD-1", "VALOR TOTAL 20,00€"], "matched.pdf")
        let early = pdf(["SIMAR services", "2023-11-02", "ATCUD:ABCD-2", "VALOR TOTAL 30,00€"], "early.pdf")
        let unmatched = pdf(["SIMAR services", "2024-06-02", "ATCUD:ABCD-3", "VALOR TOTAL 40,00€"], "unmatched.pdf")
        let unreadable = pdf(["SIMAR services 2024-07-01, nothing else on this page at all"], "unreadable.pdf")
        let library = EvidenceLibrary(root: root, database: db)
        let outcomes = try RechargeBackfill.intake(files: [matched, early, unmatched, unreadable, matched], library: library, propertyId: id("property"))
        XCTAssertEqual(outcomes.map(\.status), [.recorded(matched: true), .recorded(matched: false), .recorded(matched: false), .skipped, .duplicate])
        XCTAssertEqual(outcomes[1].reason, "issued before the bank history starts")
        XCTAssertEqual(outcomes[2].reason, "no debit of that amount from 5 days before to 60 after the issue date")
        XCTAssertEqual(outcomes[3].reason, "missing amount")
        XCTAssertEqual(try db.read { db in try UtilityInvoice.fetchCount(db) }, 3)
        // The unreadable file didn't become an invoice: it isn't kept in the library.
        XCTAssertEqual(try db.read { db in try EvidenceDocument.fetchCount(db) }, 3)
    }

    func testCandidateFilesAreTheProvidersByTextOrName() throws {
        let folder = root.appendingPathComponent("in", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: EvidenceTestPDFs.textPDF(["SIMAR services", "VALOR TOTAL 20,00€"], name: "a.pdf"),
                                         to: folder.appendingPathComponent("scan 1.pdf"))
        try FileManager.default.copyItem(at: EvidenceTestPDFs.imagePDF(name: "b.pdf"), to: folder.appendingPathComponent("20240101 - Agua.pdf"))
        try FileManager.default.copyItem(at: EvidenceTestPDFs.textPDF(["Insurance policy for the flat, nothing else"], name: "c.pdf"),
                                         to: folder.appendingPathComponent("policy.pdf"))
        let providers = try db.read { db in try Recharges.providers(db: db, propertyId: id("property")) }
        XCTAssertEqual(RechargeBackfill.candidateFiles(in: [folder], providers: providers).map(\.lastPathComponent).sorted(),
                       ["20240101 - Agua.pdf", "scan 1.pdf"])
    }

    /// April: 1,700 (prorated) + 1,000; May: 500, and a 800 issued on 2 June (before June's
    /// transfer); July's transfer is rent only; August's has 1 unexplained.
    private func seedHistory() throws {
        try invoice("P1", issued: Self.date(2024, 4, 3), amount: 6_000, period: (Self.date(2024, 2, 1), Self.date(2024, 3, 31)))
        try invoice("W1", issued: Self.date(2024, 4, 20), amount: 1_000)
        try invoice("W2", issued: Self.date(2024, 5, 28), amount: 500)
        try invoice("G1", issued: Self.date(2024, 6, 2), amount: 800)
        try transaction("utilities", Self.date(2024, 4, 25), -6_000, "SEPADD/EXAMPLE WTR")
        try transaction("utilities", Self.date(2024, 4, 28), -1_000, "SEPADD/EXAMPLE WTR")
        try transaction("rent", Self.date(2024, 5, 2), 102_700, "TRANSFER")
        try transaction("rent", Self.date(2024, 6, 3), 101_300, "TRANSFER")
        try transaction("rent", Self.date(2024, 7, 2), 100_100, "TRANSFER")
        try invoice("W3", issued: Self.date(2024, 7, 10), amount: 950)
        try transaction("rent", Self.date(2024, 8, 2), 101_000, "TRANSFER")
        try db.write { db in _ = try RentReceiptMatching.match(db: db, propertyId: id("property")) }
    }

    func testStatementsAreRebuiltFromTheTransfers() throws {
        try seedHistory()
        let outcomes = try db.write { db in
            try RechargeBackfill.rebuildStatements(db: db, tenancyId: id("tenancy"), since: Self.date(2024, 1, 1))
        }
        XCTAssertEqual(outcomes.map(\.month), [Self.date(2024, 4, 1), Self.date(2024, 5, 1), Self.date(2024, 6, 1), Self.date(2024, 7, 1)])
        XCTAssertEqual(outcomes.map(\.rechargePartMinorUnits), [2_700, 1_300, 100, 1_000])
        XCTAssertEqual(outcomes.map(\.totalMinorUnits), [2_700, 1_300, 0, 950])
        XCTAssertEqual(outcomes.map(\.linkedMinorUnits), [2_700, 1_300, 0, 950])
        XCTAssertEqual(outcomes[0].explanation, "exact: the invoices pending at month end")
        XCTAssertEqual(outcomes[1].explanation, "exact with 1 invoice issued after month end (before the transfer)")
        XCTAssertEqual(outcomes[2].explanation, "no invoices pending: the transfer's part isn't explained by invoices")
        XCTAssertEqual(outcomes[3].explanation, "within €0.50 (transfer rounded): 1 invoice")
        try db.read { db in
            XCTAssertEqual(try RechargeStatement.order(Column("month")).fetchAll(db).map(\.status), [.paid, .paid, .paid])
        }
        // Idempotent: statements already made are left alone.
        let again = try db.write { db in
            try RechargeBackfill.rebuildStatements(db: db, tenancyId: id("tenancy"), since: Self.date(2024, 1, 1))
        }
        XCTAssertEqual(again.map(\.linkedMinorUnits), [0, 0])
        XCTAssertEqual(try db.read { db in try RechargeStatement.fetchCount(db) }, 3)
    }

    func testNettingImpactPerYear() throws {
        try seedHistory()
        try db.write { db in _ = try RechargeBackfill.rebuildStatements(db: db, tenancyId: id("tenancy"), since: Self.date(2024, 1, 1)) }
        var impact = try db.write { db in try RechargeBackfill.nettingImpact(db: db, propertyId: id("property"), years: [UKTaxYear(startYear: 2024)]) }
        XCTAssertEqual(impact.first?.automaticMode, .netOfRecharges)
        XCTAssertEqual(impact.first?.utilitiesPaid, 7_000)
        XCTAssertEqual(impact.first?.rechargesReceived, 4_950)
        XCTAssertEqual(impact.first?.nettedUtilities, 2_050)
        XCTAssertEqual(impact.first?.automaticNotDeductible, 7_000)
        XCTAssertEqual(impact.first?.profitChange, -2_050)
        XCTAssertEqual(impact.first?.automaticChange, -2_050)
        // Marked filed from the plan: the filed treatment stays; netting would lower its profit by 2,050.
        let marked = try db.write { db in try RechargeBackfill.markFiledYears(db: db, propertyId: id("property"), years: Self.plan.filedTaxYears!) }
        XCTAssertEqual(marked.map(\.status), [.filed])
        XCTAssertNil(marked.first?.previous)
        // Idempotent; paid is never downgraded.
        try db.write { db in
            var year = try XCTUnwrap(try TaxYears.year(db: db, startYear: 2024, personId: try XCTUnwrap(try Person.fetchOne(db)).id!))
            year.status = .paid
            try TaxYears.save(db: db, &year)
            let again = try RechargeBackfill.markFiledYears(db: db, propertyId: id("property"), years: [2024])
            XCTAssertEqual(again.map(\.previous), [.paid])
            XCTAssertEqual(again.map(\.status), [.paid])
        }
        impact = try db.write { db in try RechargeBackfill.nettingImpact(db: db, propertyId: id("property"), years: [UKTaxYear(startYear: 2024)]) }
        XCTAssertNil(impact.first?.automaticMode)
        XCTAssertEqual(impact.first?.status, .paid)
        XCTAssertEqual(impact.first?.automaticChange, 0)
        XCTAssertEqual(impact.first?.automaticNotDeductible, 7_000)
        XCTAssertEqual(impact.first?.profitChange, -2_050)
        XCTAssertNil(try db.read { db in try RechargeNetting.mode(db: db, startYear: 2024) })
    }

    func testATransferRoundedDownSettlesItsStatement() throws {
        try invoice("W1", issued: Self.date(2024, 4, 20), amount: 1_030)
        try transaction("rent", Self.date(2024, 5, 2), 101_000, "TRANSFER")
        try db.write { db in _ = try RentReceiptMatching.match(db: db, propertyId: id("property")) }
        let outcomes = try db.write { db in
            try RechargeBackfill.rebuildStatements(db: db, tenancyId: id("tenancy"), since: Self.date(2024, 1, 1))
        }
        XCTAssertEqual(outcomes.first?.explanation, "within €0.30 (transfer rounded): 1 invoice")
        XCTAssertEqual(outcomes.first?.totalMinorUnits, 1_000)
        XCTAssertEqual(outcomes.first?.linkedMinorUnits, 1_000)
        try db.read { db in
            let statement = try XCTUnwrap(try RechargeStatement.fetchOne(db))
            XCTAssertEqual(statement.status, .paid)
            XCTAssertEqual(try Recharges.lines(db: db, statementId: statement.id!).compactMap(\.lineDescription),
                           ["Rounding: the transfer was €0.30 less"])
            XCTAssertEqual(try Recharges.paymentSuggestions(db: db, propertyId: id("property")), [])
        }
    }

    func testOnlyOwnersOfTheYearAreMarkedAndCompared() throws {
        try db.write { db in
            var b = Person(name: "Person B")
            try People.save(db: db, &b)
            let a = try XCTUnwrap(try Person.filter(Column("name") == "Person A").fetchOne(db))
            _ = try Properties.setOwners(db: db, propertyId: id("property"), [
                PropertyOwner(propertyId: id("property"), personId: b.id!, shareBasisPoints: 10_000, toDate: Self.date(2023, 12, 31)),
                PropertyOwner(propertyId: id("property"), personId: a.id!, shareBasisPoints: 10_000, fromDate: Self.date(2024, 1, 1))
            ])
            XCTAssertEqual(try RechargeBackfill.markFiledYears(db: db, propertyId: id("property"), years: [2024]).map(\.person), ["Person A"])
            XCTAssertEqual(try RechargeBackfill.markFiledYears(db: db, propertyId: id("property"), years: [2023]).map(\.person),
                           ["Person A", "Person B"])
            XCTAssertEqual(try RechargeBackfill.nettingImpact(db: db, propertyId: id("property"), years: [UKTaxYear(startYear: 2024)]).map(\.person),
                           ["Person A"])
        }
    }
}
