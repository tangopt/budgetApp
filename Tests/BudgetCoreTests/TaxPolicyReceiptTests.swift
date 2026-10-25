import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Insurers' receipts (cover periods, policy years, receipts paid outside the bank history)
/// and payments assigned to one person. Synthetic EUR property owned 50/50 by Person A and
/// Person B, HMRC rate 0.8.
final class TaxPolicyReceiptTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var ids: [String: Int64] = [:]

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func id(_ key: String) -> Int64 { ids[key]! }

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
        try db.write { db in
            var a = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &a)
            var b = Person(name: "Person B", shortName: "B")
            try People.save(db: db, &b)
            ids["A"] = a.id!; ids["B"] = b.id!
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            let p = property.id!
            ids["property"] = p
            _ = try Properties.setOwners(db: db, propertyId: p, [
                PropertyOwner(propertyId: p, personId: a.id!, shareBasisPoints: 5_000),
                PropertyOwner(propertyId: p, personId: b.id!, shareBasisPoints: 5_000)
            ])
            var account = Account(name: "Bank A", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            ids["bank"] = account.id!
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "bank.csv", importedAt: Date())
            try batch.insert(db)
            ids["batch"] = batch.id!
            try Properties.setAccount(db: db, propertyId: p, accountId: account.id!, role: .current)
            var group = CategoryGroup(name: "Property A")
            try group.insert(db)
            try Properties.addCategoryGroup(db: db, propertyId: p, categoryGroupId: group.id!)
            for (key, name) in [("insurance", "Building insurance"), ("ptTax", "PT tax"), ("condo", "Condomínio")] {
                var category = Category(name: name, type: .expense, groupId: group.id)
                try category.insert(db)
                ids[key] = category.id!
            }
            try TaxExpenseTypeMap.seed(db: db, propertyId: p)
            for year in [2024, 2025] { try HMRCRates.set(db: db, startYear: year, currencyCode: "EUR", gbpPerUnit: 0.8, source: .manual) }
        }
        // Policy 2024 in two instalments, 2025 in three (two paid outside the bank history).
        try debit("dec23", (2023, 12, 21), -20_000)
        try debit("jun24", (2024, 6, 21), -21_000)
        try debit("dec24", (2024, 12, 19), -22_000)
        try receipt("dec23", (2023, 12, 21), 20_000, policy: 2024, 1, of: 2, cover: ((2023, 12, 16), (2024, 6, 16)))
        try receipt("jun24", (2024, 6, 21), 21_000, policy: 2024, 2, of: 2, cover: ((2024, 6, 16), (2024, 12, 16)))
        try receipt("dec24", (2024, 12, 19), 22_000, policy: 2025, 1, of: 3, cover: ((2024, 12, 16), (2025, 6, 16)))
        try receipt(nil, (2025, 8, 20), 10_000, policy: 2025, 2, of: 3, cover: ((2025, 6, 16), (2025, 9, 16)), key: "aug25")
        try receipt(nil, (2025, 10, 20), 10_000, policy: 2025, 3, of: 3, cover: ((2025, 9, 16), (2025, 12, 16)), key: "oct25")
    }

    @discardableResult
    private func debit(_ key: String, _ day: (Int, Int, Int), _ amount: Int, category: String = "insurance",
                       description: String = "SEPADD/INSURER", note: String? = nil) throws -> Int64 {
        try db.write { db in
            var transaction = Transaction(importBatchId: id("batch"), accountId: id("bank"), date: Self.date(day.0, day.1, day.2),
                                          rawDescription: description, amountMinorUnits: amount, categoryId: id(category), status: .confirmed,
                                          categorizedBy: .manual, fingerprint: UUID().uuidString, note: note)
            try transaction.insert(db)
            ids[key] = transaction.id!
            return transaction.id!
        }
    }

    private func receipt(_ transaction: String?, _ day: (Int, Int, Int), _ amount: Int, policy: Int, _ n: Int, of m: Int,
                         cover: ((Int, Int, Int), (Int, Int, Int)), key: String? = nil) throws {
        try db.write { db in
            var receipt = TaxPolicyReceipt(propertyId: id("property"), transactionId: transaction.map(id), date: Self.date(day.0, day.1, day.2),
                                           amountMinorUnits: amount, currency: .eur, policyYear: policy, instalment: n, instalmentCount: m,
                                           coverStart: Self.date(cover.0.0, cover.0.1, cover.0.2), coverEnd: Self.date(cover.1.0, cover.1.1, cover.1.2))
            try TaxPolicyReceipts.save(db: db, &receipt)
            ids["receipt:" + (key ?? transaction!)] = receipt.id!
        }
    }

    private func compute(_ startYear: Int, _ person: String = "A") throws -> RentalAccounts.Result {
        try db.read { db in
            try RentalAccounts.compute(db: db, taxYear: UKTaxYear(startYear: startYear), personId: id(person), propertyId: id("property"))
        }
    }

    // MARK: Cover periods

    func testCoverFromTheReceiptsIncludingThoseOutsideTheBankHistory() throws {
        // 2024/25: Apr–Jun of the Dec 2023 receipt (3 of 6), Jul–Dec 2024 (6 of 6), Jan–Mar of Dec 2024 (3 of 6).
        let y2024 = try XCTUnwrap(try compute(2024).line(.insurance))
        XCTAssertEqual(y2024.whole.native, 10_000 + 21_000 + 11_000)
        XCTAssertEqual(y2024.amount.native, 21_000)
        let byRef = Dictionary(uniqueKeysWithValues: y2024.sources.map { ($0.reference, $0) })
        XCTAssertEqual(byRef[.transaction(id("dec24"))]?.explanation,
                       "3 of 6 cover months, Jan 2025 – Jun 2025 (from the receipt, instalment 1 of 3, policy year 2025)")
        // 2025/26: Apr–Jun 2025 of the Dec 2024 receipt, and both receipts paid outside the bank.
        let y2025 = try XCTUnwrap(try compute(2025).line(.insurance))
        XCTAssertEqual(y2025.whole.native, 11_000 + 10_000 + 10_000)
        let outside = y2025.sources.filter { if case .policyReceipt = $0.reference { return true } else { return false } }
        XCTAssertEqual(outside.count, 2)
        XCTAssertEqual(outside.first?.description, "Insurance receipt (instalment 2 of 3, policy year 2025), paid outside the bank history")
        XCTAssertEqual(outside.first?.reference.entity, .taxPolicyReceipt(id("receipt:aug25")))
    }

    func testTheNoteStillWinsOverTheReceipt() throws {
        try db.write { db in
            try db.execute(sql: "UPDATE transaction_ SET note = 'cover 2024-07-01 – 2024-09-30' WHERE id = ?", arguments: [id("jun24")])
        }
        let line = try XCTUnwrap(try compute(2024).line(.insurance))
        XCTAssertTrue(line.sources.contains { $0.explanation == "3 of 3 cover months, Jul 2024 – Sep 2024 (from the note)" })
    }

    // MARK: Policy year

    func testPolicyYearSpreadsEachYearsReceiptsOverItsCalendarMonths() throws {
        try db.write { db in try TaxAttributionRules.set(db: db, expenseType: .insurance, startYear: nil, rule: .apportionPolicyYear) }
        // 2024/25: 9/12 of policy 2024 (200 + 210) + 3/12 of policy 2025 (220 + 100 + 100).
        let line = try XCTUnwrap(try compute(2024).line(.insurance))
        XCTAssertEqual(line.whole.native, 15_000 + 15_750 + 5_500 + 2_500 + 2_500)
        XCTAssertEqual(line.rule, .apportionPolicyYear)
        let byRef = Dictionary(uniqueKeysWithValues: line.sources.map { ($0.reference, $0) })
        XCTAssertEqual(byRef[.transaction(id("dec23"))]?.explanation,
                       "9 of 12 months of policy year 2024, Jan 2024 – Dec 2024 (from the receipt, instalment 1 of 2, policy year 2024)")
        // 2025/26: 9/12 of policy 2025.
        XCTAssertEqual(try compute(2025).line(.insurance)?.whole.native, 16_500 + 7_500 + 7_500)
    }

    func testPolicyYearWithoutAReceiptIsTheYearOfTheMonthAfterTheDebit() throws {
        try db.write { db in
            try TaxPolicyReceipt.deleteAll(db)
            try TaxAttributionRules.set(db: db, expenseType: .insurance, startYear: nil, rule: .apportionPolicyYear)
        }
        let line = try XCTUnwrap(try compute(2024).line(.insurance))
        let byRef = Dictionary(uniqueKeysWithValues: line.sources.map { ($0.reference, $0) })
        // December 2024 pays policy 2025 (3 of its months are in 2024/25); June 2024 policy 2024.
        XCTAssertEqual(byRef[.transaction(id("dec24"))]?.attributedMinorUnits, 5_500)
        XCTAssertEqual(byRef[.transaction(id("jun24"))]?.attributedMinorUnits, 15_750)
        XCTAssertTrue(byRef[.transaction(id("dec24"))]!.explanation.contains("assumed: policy year 2025"))
        XCTAssertEqual(TaxPolicyReceipts.policyYear(afterDebit: Self.date(2024, 12, 19)), 2025)
        XCTAssertEqual(TaxPolicyReceipts.policyYear(afterDebit: Self.date(2024, 6, 21)), 2024)
    }

    func testQuotaPeriodsFromReceiptsForTheServiceCharge() throws {
        // A Jan–Jun quota paid in March (3 of 6 months in 2023/24), and Jul–Dec paid before the bank history.
        let march = try debit("condoMar", (2023, 3, 6), -60_000, category: "condo", description: "Condominio 230305")
        try db.write { db in
            var paid = TaxPolicyReceipt(propertyId: id("property"), expenseType: .serviceCharge, transactionId: march, date: Self.date(2023, 3, 6),
                                        amountMinorUnits: 60_000, currency: .eur, coverStart: Self.date(2023, 1, 1), coverEnd: Self.date(2023, 7, 1))
            try TaxPolicyReceipts.save(db: db, &paid)
            var early = TaxPolicyReceipt(propertyId: id("property"), expenseType: .serviceCharge, date: Self.date(2022, 9, 19),
                                         amountMinorUnits: 24_000, currency: .eur, coverStart: Self.date(2022, 7, 1), coverEnd: Self.date(2023, 1, 1),
                                         notes: "Condomínio 2022, second half (before the bank history)")
            try TaxPolicyReceipts.save(db: db, &early)
        }
        let y2023 = try XCTUnwrap(try compute(2023).line(.serviceCharge))
        XCTAssertEqual(y2023.whole.native, 30_000)
        XCTAssertEqual(y2023.sources.first?.explanation, "3 of 6 quota months, Jan 2023 – Jun 2023 (from the receipt)")
        XCTAssertEqual(try compute(2022).line(.serviceCharge)?.whole.native, 30_000 + 24_000)
    }

    // MARK: Records

    func testSaveValidatesAndDeletingTheDebitDropsItsReceipt() throws {
        try db.write { db in
            var bad = TaxPolicyReceipt(propertyId: id("property"), date: Self.date(2025, 1, 1), amountMinorUnits: 100, currency: .eur,
                                       instalment: 3, instalmentCount: 2)
            XCTAssertThrowsError(try TaxPolicyReceipts.save(db: db, &bad)) { XCTAssertEqual($0 as? TaxError, .invalidInstalment) }
            var backwards = TaxPolicyReceipt(propertyId: id("property"), date: Self.date(2025, 1, 1), amountMinorUnits: 100, currency: .eur,
                                             coverStart: Self.date(2025, 6, 1), coverEnd: Self.date(2025, 1, 1))
            XCTAssertThrowsError(try TaxPolicyReceipts.save(db: db, &backwards)) { XCTAssertEqual($0 as? TaxError, .invalidCoverPeriod) }
            try Transaction.deleteOne(db, key: id("jun24"))
            XCTAssertFalse(try TaxPolicyReceipt.exists(db, key: id("receipt:jun24")))
            XCTAssertEqual(try TaxEvidence.title(db: db, entity: .taxPolicyReceipt(id("receipt:aug25"))),
                           "Insurance (building insurance) receipt · instalment 2 of 3, policy year 2025")
        }
    }

    // MARK: Foreign tax, time-apportioned (HMRC INTM161220)

    func testForeignTaxIsTimeApportionedByDefaultAndWarnsWhileNextYearIsMissing() throws {
        // PT tax for 2024 (paid Aug 2025) and 2025 (paid Aug 2026).
        try debit("pt2024", (2025, 8, 12), -36_500, category: "ptTax", description: "PG PAGEST 1")
        try debit("pt2025", (2026, 8, 19), -73_000, category: "ptTax", description: "PG PAGEST 2")
        let line = try compute(2024).foreignTax
        XCTAssertEqual(line.rule, .apportionCalendarYear)
        // 270/365 of 2024's (366 days: 6 Apr – 31 Dec = 270) + 95/365 of 2025's.
        let part2024 = 36_500 - Int((36_500.0 * 96 / 366).rounded())
        let part2025 = Int((73_000.0 * 95 / 365).rounded())
        XCTAssertEqual(line.whole.native, part2024 + part2025)
        let byRef = Dictionary(uniqueKeysWithValues: line.sources.map { ($0.reference, $0) })
        XCTAssertEqual(byRef[.transaction(id("pt2025"))]?.explanation,
                       "Paid 2026-08-19 for 2025, the year before payment: 95 of 365 days in 2024/25 (time-apportioned)")
        XCTAssertFalse(try compute(2024).warnings.contains { $0.hasPrefix("No PT tax for") })
        // 2025/26 has 2025's 270 days but nothing for 2026 yet.
        let next = try compute(2025)
        XCTAssertEqual(next.foreignTax.whole.native, 73_000 - part2025)
        XCTAssertTrue(next.warnings.contains { $0.hasPrefix("No PT tax for 2026 recorded yet: 95 of its 365 days belong to 2025/26") })
        // The parts add up to each year's tax.
        XCTAssertEqual(RentalAccounts.timeApportioned(36_500, calendarYear: 2024, to: UKTaxYear(startYear: 2023))!.0 + part2024, 36_500)
    }

    func testTheSeededForeignTaxDefaultMovesToTheApportionedBasis() throws {
        let migrated = try DatabaseManager(path: nil)
        var migrator = DatabaseMigrator()
        try migrated.dbQueue.write { db in
            try db.execute(sql: "CREATE TABLE taxAttributionRule (id INTEGER PRIMARY KEY, expenseType TEXT, startYear INTEGER, rule TEXT, defaultCoverMonths INTEGER, notes TEXT)")
            try db.execute(sql: "INSERT INTO taxAttributionRule (expenseType, startYear, rule, notes) VALUES ('foreignTax', NULL, 'previousCalendarYear', ?)",
                           arguments: [TaxAttributionRules.seededNote])
            try db.execute(sql: "INSERT INTO taxAttributionRule (expenseType, startYear, rule, notes) VALUES ('foreignTax', 2023, 'previousCalendarYear', 'As filed')")
            try db.execute(sql: "INSERT INTO taxAttributionRule (expenseType, startYear, rule, notes) VALUES ('councilTax', NULL, 'previousCalendarYear', ?)",
                           arguments: [TaxAttributionRules.seededNote])
        }
        registerForeignTaxApportionedMigration(&migrator)
        try migrator.migrate(migrated.dbQueue)
        let rules = try migrated.dbQueue.read { db in try String.fetchAll(db, sql: "SELECT expenseType || ':' || IFNULL(startYear, '-') || ':' || rule FROM taxAttributionRule ORDER BY id") }
        XCTAssertEqual(rules, ["foreignTax:-:apportionCalendarYear", "foreignTax:2023:previousCalendarYear", "councilTax:-:previousCalendarYear"])
    }

    // MARK: Assigned to a person

    func testAPaymentAssignedToOnePersonIsAllTheirs() throws {
        let tax = try debit("ptB", (2025, 8, 12), -30_000, category: "ptTax", description: "PG PAGEST 1")
        try debit("ptJoint", (2025, 8, 12), -20_000, category: "ptTax", description: "PG PAGEST 2")
        try db.write { db in
            try TaxAttributionRules.set(db: db, expenseType: .foreignTax, startYear: nil, rule: .previousCalendarYear)
            try TaxTransactionOwners.set(db: db, transactionId: tax, personId: id("B"))
        }
        XCTAssertEqual(try compute(2024, "A").foreignTax.amount.native, 10_000)
        let b = try compute(2024, "B").foreignTax
        XCTAssertEqual(b.amount.native, 40_000)
        XCTAssertTrue(b.sources.contains { $0.explanation.hasSuffix("Person B's (assigned)") })
        try db.write { db in try TaxTransactionOwners.set(db: db, transactionId: tax, personId: nil) }
        XCTAssertEqual(try compute(2024, "A").foreignTax.amount.native, 25_000)
    }

    // MARK: Review fixes

    private func ptDebits() throws {
        try debit("pt2024", (2025, 8, 12), -36_500, category: "ptTax", description: "PG PAGEST 1")
        try debit("pt2025", (2026, 8, 19), -73_000, category: "ptTax", description: "PG PAGEST 2")
    }

    func testAFiledYearKeepsThePreviousCalendarYearBasisUnlessItsOwnRuleSaysOtherwise() throws {
        try ptDebits()
        let apportioned = try compute(2024).foreignTax.whole.native
        try db.write { db in
            var year = try TaxYears.ensure(db: db, startYear: 2024, personId: id("A"))
            year.status = .filed
            try TaxYears.save(db: db, &year)
        }
        let filed = try compute(2024, "A")
        XCTAssertEqual(filed.foreignTax.rule, .previousCalendarYear)
        XCTAssertEqual(filed.foreignTax.whole.native, 36_500)
        XCTAssertTrue(filed.warnings.contains { $0.hasPrefix("2024/25 is filed: foreign tax stays on the previous-calendar-year basis") })
        XCTAssertFalse(filed.warnings.contains { $0.hasPrefix("No PT tax for") })
        // B's year is still open: apportioned.
        XCTAssertEqual(try compute(2024, "B").foreignTax.whole.native, apportioned)
        // The year's own rule wins over the filed pin.
        try db.write { db in try TaxAttributionRules.set(db: db, expenseType: .foreignTax, startYear: 2024, rule: .apportionCalendarYear) }
        XCTAssertEqual(try compute(2024, "A").foreignTax.whole.native, apportioned)
    }

    func testAStoredPreviousCalendarYearDefaultNeedsNoFiledPinOrNextYearWarning() throws {
        // The accountant's basis kept for every year (a user decision): PT tax for calendar
        // year N in full against UK year N/N+1.
        try ptDebits()
        try db.write { db in
            try TaxAttributionRules.set(db: db, expenseType: .foreignTax, startYear: nil, rule: .previousCalendarYear, notes: "Tax data plan")
            var year = try TaxYears.ensure(db: db, startYear: 2024, personId: id("A"))
            year.status = .filed
            try TaxYears.save(db: db, &year)
        }
        let filed = try compute(2024, "A")
        XCTAssertEqual(filed.foreignTax.rule, .previousCalendarYear)
        XCTAssertEqual(filed.foreignTax.whole.native, 36_500)
        XCTAssertFalse(filed.warnings.contains { $0.contains("foreign tax stays on") }, "\(filed.warnings)")
        XCTAssertFalse(filed.warnings.contains { $0.hasPrefix("No PT tax for") })
        // Open years: the same basis, and nothing asks for next year's tax.
        XCTAssertEqual(try compute(2024, "B").foreignTax.whole.native, 36_500)
        let open = try compute(2025, "A")
        XCTAssertEqual(open.foreignTax.rule, .previousCalendarYear)
        XCTAssertEqual(open.foreignTax.whole.native, 73_000)
        XCTAssertEqual(open.foreignTax.amount.native, 36_500)
        XCTAssertFalse(open.warnings.contains { $0.hasPrefix("No PT tax for") || $0.contains("foreign tax stays on") }, "\(open.warnings)")
    }

    func testARefundDoesNotCountAsNextYearsTax() throws {
        try ptDebits()
        try debit("refund2026", (2027, 9, 1), 5_000, category: "ptTax", description: "REEMBOLSO IRS")
        XCTAssertTrue(try compute(2025).warnings.contains { $0.hasPrefix("No PT tax for 2026 recorded yet") })
    }

    func testTheTemplateRentFollowsTheForeignTaxBasis() throws {
        try db.write { db in
            var tenancy = Tenancy(propertyId: id("property"), referenceLabel: "Room Contract AB", contractNumber: "3001", startDate: Self.date(2024, 1, 1))
            try Tenancies.save(db: db, &tenancy)
            for (index, (y, m)) in ((1...12).map { (2024, $0) } + (1...12).map { (2025, $0) }).enumerated() {
                let start = Self.date(y, m, 1)
                let end = MonthRange.calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start)!
                var receipt = RentReceipt(tenancyId: tenancy.id!, receiptNumber: "\(index + 1)", periodStart: start, periodEnd: end,
                                          receiptDate: start, amountMinorUnits: y == 2024 ? 100_000 : 120_000, status: .issued)
                try RentReceipts.save(db: db, &receipt)
            }
        }
        try ptDebits()
        try db.read { db in
            let accounts = try RentalAccounts.compute(db: db, taxYear: UKTaxYear(startYear: 2024), personId: id("A"), propertyId: id("property"))
            // Person A's half: 2024 €6,000 × 270/366 + 2025 €7,200 × 95/365.
            let expected = (600_000 - Int((600_000.0 * 96 / 366).rounded())) + Int((720_000.0 * 95 / 365).rounded())
            XCTAssertEqual(try RentalAccounts.foreignTaxBasisRent(db: db, accounts: accounts), expected)
            let sheets = AccountantTemplate.sheets(accounts: accounts, personName: "Person A", foreignTaxBasisRent: expected)
            XCTAssertTrue(sheets[1].cells.contains { $0.reference == "D5" && $0.value == .text("2024/25 (by days)") })
        }
        try db.write { db in try TaxAttributionRules.set(db: db, expenseType: .foreignTax, startYear: nil, rule: .previousCalendarYear) }
        try db.read { db in
            let accounts = try RentalAccounts.compute(db: db, taxYear: UKTaxYear(startYear: 2024), personId: id("A"), propertyId: id("property"))
            XCTAssertEqual(try RentalAccounts.foreignTaxBasisRent(db: db, accounts: accounts), 600_000)
        }
    }

    func testAReceiptKeptOnItsOwnNextToTheSameDebitWarnsOfADoubleCount() throws {
        try db.write { db in
            try db.execute(sql: "UPDATE taxPolicyReceipt SET transactionId = NULL WHERE id = ?", arguments: [id("receipt:jun24")])
        }
        XCTAssertTrue(try compute(2024).warnings.contains { $0.contains("receipt of 2024-06-21") && $0.contains("counts twice") })
    }

    func testAServiceChargeReceiptWithoutCoverReadsTheUsersNotesNotItsDescription() throws {
        try db.write { db in
            var receipt = TaxPolicyReceipt(propertyId: id("property"), expenseType: .serviceCharge, date: Self.date(2024, 9, 19),
                                           amountMinorUnits: 60_000, currency: .eur, policyYear: 2024, notes: "quotas 2024-01-01 – 2024-06-30")
            try TaxPolicyReceipts.save(db: db, &receipt)
        }
        let line = try XCTUnwrap(try compute(2024).line(.serviceCharge))
        XCTAssertEqual(line.whole.native, 30_000)
        XCTAssertTrue(line.sources[0].explanation.hasPrefix("3 of 6 quota months, Jan 2024 – Jun 2024 (from the note)"))
    }

    func testOwnersMustOwnThePropertyAndASplitConflictWarns() throws {
        let tax = try debit("ptA", (2025, 8, 12), -30_000, category: "ptTax", description: "PG PAGEST 9")
        try db.write { db in
            var c = Person(name: "Person C", shortName: "C")
            try People.save(db: db, &c)
            XCTAssertThrowsError(try TaxTransactionOwners.set(db: db, transactionId: tax, personId: c.id!)) {
                XCTAssertEqual($0 as? TaxError, .notAnOwner)
            }
            try TaxTransactionOwners.set(db: db, transactionId: tax, personId: id("A"))
            try TaxSplits.set(db: db, startYear: 2024, personId: id("A"), propertyId: id("property"), expenseType: .foreignTax, shareBasisPoints: 6_000)
        }
        XCTAssertTrue(try compute(2024).warnings.contains { $0.hasPrefix("Foreign tax paid (PT IRS): payments assigned to one person override the 2024/25 split") })
    }
}
