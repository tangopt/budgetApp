import XCTest
import GRDB
@testable import BudgetCore

/// A debit settling several items (a condomínio payment of a year's quotas and an extra
/// charge), each attributed by its own months; and one filed year's moved window (a workbook
/// that counted October–September). Synthetic EUR property owned 50/50 by Person A and
/// Person B, HMRC rate 0.8.
final class TaxReceiptItemsTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var ids: [String: Int64] = [:]

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func id(_ key: String) -> Int64 { ids[key]! }

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try setUpData()
    }

    private func setUpData() throws {
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
            try db.execute(sql: "INSERT INTO importBatch (accountId, sourceFileName, importedAt) VALUES (?, 'bank.csv', ?)", arguments: [account.id!, Date()])
            ids["batch"] = db.lastInsertedRowID
            try Properties.setAccount(db: db, propertyId: p, accountId: account.id!, role: .current)
            var group = CategoryGroup(name: "Property A")
            try group.insert(db)
            try Properties.addCategoryGroup(db: db, propertyId: p, categoryGroupId: group.id!)
            for (key, name) in [("insurance", "Building insurance"), ("condo", "Condomínio")] {
                var category = Category(name: name, type: .expense, groupId: group.id)
                try category.insert(db)
                ids[key] = category.id!
            }
            try TaxExpenseTypeMap.seed(db: db, propertyId: p)
            for year in [2022, 2023, 2024, 2025] { try HMRCRates.set(db: db, startYear: year, currencyCode: "EUR", gbpPerUnit: 0.8, source: .manual) }
        }
    }

    @discardableResult
    private func debit(_ key: String, _ day: (Int, Int, Int), _ amount: Int, category: String = "condo",
                       description: String = "CONDO 2024") throws -> Int64 {
        try db.write { db in
            var transaction = Transaction(importBatchId: id("batch"), accountId: id("bank"), date: Self.date(day.0, day.1, day.2),
                                          rawDescription: description, amountMinorUnits: amount, categoryId: id(category), status: .confirmed,
                                          categorizedBy: .manual, fingerprint: UUID().uuidString)
            try transaction.insert(db)
            ids[key] = transaction.id!
            return transaction.id!
        }
    }

    /// An item of a debit (or, without `of`, a receipt of its own), its months `[from, to)`.
    @discardableResult
    private func item(_ key: String, of debit: String?, _ amount: Int, from: (Int, Int), to: (Int, Int), type: TaxExpenseType = .serviceCharge,
                      note: String? = nil) throws -> Int64 {
        try db.write { db in
            var receipt = TaxPolicyReceipt(propertyId: id("property"), expenseType: type, transactionId: debit.map(id),
                                           date: Self.date(2024, 8, 5), amountMinorUnits: amount, currency: .eur,
                                           coverStart: Self.date(from.0, from.1, 1), coverEnd: Self.date(to.0, to.1, 1), notes: note ?? key)
            try TaxPolicyReceipts.save(db: db, &receipt)
            ids[key] = receipt.id!
            return receipt.id!
        }
    }

    private func compute(_ startYear: Int, _ person: String = "A") throws -> RentalAccounts.Result {
        try db.read { db in
            try RentalAccounts.compute(db: db, taxYear: UKTaxYear(startYear: startYear), personId: id(person), propertyId: id("property"))
        }
    }

    /// One payment of €1,000: Jan–Apr quotas €400, an extra charge of April €130, May–Dec quotas €470.
    private func itemisedPayment() throws {
        try debit("pay", (2024, 8, 5), -100_000)
        try item("jan-apr", of: "pay", 40_000, from: (2024, 1), to: (2024, 5), note: "Quotas Jan–Apr 2024")
        try item("extra", of: "pay", 13_000, from: (2024, 4), to: (2024, 5), note: "Extra charge")
        try item("may-dec", of: "pay", 47_000, from: (2024, 5), to: (2025, 1), note: "Quotas May–Dec 2024")
    }

    // MARK: Items

    func testEachItemIsAttributedByItsOwnMonths() throws {
        try itemisedPayment()
        // 2023/24: Jan–Mar 2024 of the Jan–Apr quotas only (the even spread would give 3/12 of €1,000).
        let y2023 = try XCTUnwrap(try compute(2023).line(.serviceCharge))
        XCTAssertEqual(y2023.whole.native, 30_000)
        XCTAssertEqual(y2023.amount.native, 15_000)
        XCTAssertEqual(y2023.sources.map(\.reference), [.policyReceipt(id("jan-apr"))])
        XCTAssertEqual(y2023.sources.first?.transactionId, id("pay"))
        XCTAssertEqual(y2023.sources.first?.description, "CONDO 2024 · Quotas Jan–Apr 2024")
        XCTAssertEqual(y2023.sources.first?.explanation, "Item 1 of 3 of the payment: 3 of 4 quota months, Jan 2024 – Apr 2024 (from the receipt)")
        // 2024/25: April's quota, the April extra and May–Dec.
        let y2024 = try XCTUnwrap(try compute(2024).line(.serviceCharge))
        XCTAssertEqual(y2024.whole.native, 10_000 + 13_000 + 47_000)
        XCTAssertEqual(y2024.sources.count, 3)
        XCTAssertTrue(y2024.sources.allSatisfy { $0.transactionId == id("pay") })
    }

    func testItemsThatDontAddUpAreIgnoredWithAWarning() throws {
        try debit("pay", (2024, 8, 5), -100_000)
        try item("a", of: "pay", 40_000, from: (2024, 1), to: (2024, 5))
        try item("b", of: "pay", 50_000, from: (2024, 5), to: (2025, 1))
        let result = try compute(2024)
        let line = try XCTUnwrap(result.line(.serviceCharge))
        // The payment whole, by the year in its description (Jan–Dec 2024): 9 of 12 months.
        XCTAssertEqual(line.whole.native, 75_000)
        XCTAssertEqual(line.sources.map(\.reference), [.transaction(id("pay"))])
        XCTAssertTrue(result.warnings.contains { $0.contains("has 2 item receipts adding up to €900.00, not the payment's €1,000.00") })
    }

    func testAnItemOrTheWholePaymentCanBeLeftOffTheReturn() throws {
        try itemisedPayment()
        try db.write { db in
            try TaxNotClaimedSources.set(db: db, startYear: 2024, reference: .policyReceipt(id("extra")), notClaimed: true, notes: "Not in the workbook")
        }
        var line = try XCTUnwrap(try compute(2024).line(.serviceCharge))
        XCTAssertEqual(line.whole.native, 10_000 + 47_000)
        XCTAssertEqual(line.notClaimedSources.map(\.reference), [.policyReceipt(id("extra"))])
        XCTAssertEqual(line.notClaimedWhole.native, 13_000)
        // A mark on the payment covers every item.
        try db.write { db in
            try TaxNotClaimedSources.set(db: db, startYear: 2024, reference: .policyReceipt(id("extra")), notClaimed: false)
            try TaxNotClaimedSources.set(db: db, startYear: 2024, reference: .transaction(id("pay")), notClaimed: true)
        }
        line = try XCTUnwrap(try compute(2024).line(.serviceCharge))
        XCTAssertEqual(line.whole.native, 0)
        XCTAssertEqual(line.notClaimedSources.count, 3)
        XCTAssertTrue(line.notClaimedSources.allSatisfy { $0.reference == .transaction(id("pay")) })
    }

    func testItemsNeverAddUpToMoreThanTheDebit() throws {
        try debit("pay", (2024, 8, 5), -100_000)
        try item("a", of: "pay", 60_000, from: (2024, 1), to: (2024, 7))
        XCTAssertThrowsError(try item("b", of: "pay", 50_000, from: (2024, 7), to: (2025, 1))) {
            XCTAssertEqual($0 as? TaxError, .itemsExceedPayment)
        }
        // One receipt alone keeps the old meaning: the debit's amount is used.
        let line = try XCTUnwrap(try compute(2024).line(.serviceCharge))
        XCTAssertEqual(line.sources.map(\.reference), [.transaction(id("pay"))])
    }

    func testTheMigrationKeepsReceiptsMarksLinksAndTheirTriggers() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate(upTo: "addTaxAttributionRuleWindowShift")
        try setUpData()
        try debit("ins", (2024, 6, 21), -21_000, category: "insurance", description: "SEPADD/INSURER")
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO taxPolicyReceipt (propertyId, expenseType, transactionId, date, amountMinorUnits, currency, coverStart, coverEnd)
                VALUES (?, 'insurance', ?, '2024-06-21 00:00:00.000', 21000, 'eur', '2024-06-16 00:00:00.000', '2024-12-16 00:00:00.000'),
                       (?, 'insurance', NULL, '2023-12-21 00:00:00.000', 20000, 'eur', '2023-12-16 00:00:00.000', '2024-06-16 00:00:00.000'),
                       (?, 'insurance', NULL, '2023-06-21 00:00:00.000', 19000, 'eur', NULL, NULL)
                """, arguments: [id("property"), id("ins"), id("property"), id("property")])
            ids["gone"] = db.lastInsertedRowID
            ids["own"] = db.lastInsertedRowID - 1
            ids["linked"] = db.lastInsertedRowID - 2
            // A deleted receipt: its id is never reused (AUTOINCREMENT).
            try db.execute(sql: "DELETE FROM taxPolicyReceipt WHERE id = ?", arguments: [id("gone")])
            try db.execute(sql: "INSERT INTO taxNotClaimed (startYear, policyReceiptId) VALUES (2024, ?)", arguments: [id("own")])
            let now = "2026-01-01 00:00:00.000"
            try db.execute(sql: """
                INSERT INTO document (sha256, storedRelativePath, originalFileName, byteCount, addedAt) VALUES ('h1', 'r.pdf', 'r.pdf', 1, ?)
                """, arguments: [now])
            let document = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO documentLink (documentId, entityType, entityId, createdAt) VALUES (?, 'taxPolicyReceipt', ?, ?)",
                           arguments: [document, id("own"), now])
            try db.execute(sql: "INSERT INTO evidenceRequirement (name, scope, createdAt) VALUES ('Test', 'transaction', ?)", arguments: [now])
            let requirement = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO evidenceWaiver (requirementId, entityType, entityId, reason, createdAt) VALUES (?, 'taxPolicyReceipt', ?, 'test', ?)
                """, arguments: [requirement, id("own"), now])
        }
        try manager.migrate()
        try db.read { db in
            XCTAssertEqual(try TaxPolicyReceipt.fetchCount(db), 2)
            XCTAssertEqual(try TaxPolicyReceipt.fetchOne(db, key: id("linked"))?.transactionId, id("ins"))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM taxNotClaimed WHERE policyReceiptId = ?", arguments: [id("own")]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM documentLink WHERE entityType = 'taxPolicyReceipt' AND entityId = ?",
                                            arguments: [id("own")]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM evidenceWaiver WHERE entityType = 'taxPolicyReceipt' AND entityId = ?",
                                            arguments: [id("own")]), 1)
            let indexes = try db.indexes(on: "taxPolicyReceipt")
            XCTAssertTrue(indexes.contains { $0.columns == ["transactionId"] && !$0.isUnique })
            XCTAssertTrue(indexes.contains { $0.columns == ["propertyId"] })
            XCTAssertTrue(try db.triggerExists("documentLink_delete_taxPolicyReceipt"))
            XCTAssertTrue(try db.triggerExists("evidenceWaiver_delete_taxPolicyReceipt"))
            XCTAssertEqual(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count, 0)
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT seq FROM sqlite_sequence WHERE name = 'taxPolicyReceipt'"), id("gone"))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_sequence WHERE name = 'taxPolicyReceipt_new'"), 0)
        }
        // Now a second receipt on the debit is allowed, with a fresh id; deleting a receipt
        // still removes its mark, links and waivers.
        let second = try item("second", of: "ins", 0, from: (2024, 7), to: (2024, 8), type: .insurance)
        XCTAssertGreaterThan(second, id("gone"))
        try db.write { db in
            _ = try TaxPolicyReceipts.delete(db: db, id: id("own"))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM taxNotClaimed"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM documentLink WHERE entityType = 'taxPolicyReceipt'"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM evidenceWaiver WHERE entityType = 'taxPolicyReceipt'"), 0)
        }
    }

    // MARK: A year's moved window

    /// Insurance in half-year instalments, cover 16th to 16th (Jul–Dec and Jan–Jun).
    private func instalments() throws {
        try debit("jun22", (2022, 6, 22), -20_001, category: "insurance", description: "SEPADD/INSURER")
        try debit("dec22", (2022, 12, 21), -20_001, category: "insurance", description: "SEPADD/INSURER")
        try debit("jun23", (2023, 6, 22), -24_000, category: "insurance", description: "SEPADD/INSURER")
        try db.write { db in
            for (key, start, end) in [("jun22", (2022, 6), (2022, 12)), ("dec22", (2022, 12), (2023, 6)), ("jun23", (2023, 6), (2023, 12))] {
                let amount = -(try Transaction.fetchOne(db, key: id(key))!.amountMinorUnits)
                var receipt = TaxPolicyReceipt(propertyId: id("property"), transactionId: id(key), date: Self.date(2022, 1, 1), amountMinorUnits: amount,
                                               currency: .eur, coverStart: Self.date(start.0, start.1, 16), coverEnd: Self.date(end.0, end.1, 16))
                try TaxPolicyReceipts.save(db: db, &receipt)
            }
        }
    }

    func testAMovedWindowCountsItsOwnMonthsEachPartRoundedOnItsOwn() throws {
        try instalments()
        // April–March: Jul–Dec 2022, Jan–Mar of Jan–Jun 2023 (cumulative rounding).
        XCTAssertEqual(try compute(2022).line(.insurance)?.whole.native, 20_001 + 10_001)
        try db.write { db in
            try TaxAttributionRules.set(db: db, expenseType: .insurance, startYear: 2022, rule: .apportionByCover, windowShiftMonths: 6)
        }
        // October–September: Oct–Dec 2022 (half of €200.01, rounded up on its own), Jan–Jun 2023, Jul–Sep 2023.
        let line = try XCTUnwrap(try compute(2022).line(.insurance))
        XCTAssertEqual(line.whole.native, 10_001 + 20_001 + 12_000)
        XCTAssertEqual(line.amount.native, 21_001)
        XCTAssertTrue(line.ruleExplanation.hasSuffix("This year's window is moved 6 months, to Oct 2022 – Sep 2023 (as filed); each part is rounded on its own."))
        XCTAssertTrue(line.sources.contains {
            $0.explanation == "3 of 6 cover months, Jul 2022 – Dec 2022 (from the receipt, policy year 2022) in Oct 2022 – Sep 2023, the year's moved window"
        })
        XCTAssertTrue(try compute(2022).warnings.contains(
            "Insurance (building insurance): 2022/23 counts Oct 2022 – Sep 2023 (its window moved 6 months, as filed); Apr 2023 – Sep 2023 also count in 2023/24."))
        // The other years keep April–March.
        XCTAssertEqual(try compute(2023).line(.insurance)?.whole.native, 10_000 + 24_000)
        XCTAssertFalse(try compute(2024).warnings.contains { $0.contains("window moved") })
        // The settings row shows it.
        let page = try db.read { db in try TaxOverview.page(db: db, personId: id("A"), startYear: 2022, propertyId: id("property")) }
        XCTAssertEqual(page?.rules.first { $0.expenseType == .insurance }?.windowShiftMonths, 6)
    }

    func testAWindowMovesOnlyForOneYearsRuleWithMonths() throws {
        try db.write { db in
            XCTAssertThrowsError(try TaxAttributionRules.set(db: db, expenseType: .insurance, startYear: nil, rule: .apportionByCover, windowShiftMonths: 6)) {
                XCTAssertEqual($0 as? TaxError, .invalidWindowShift)
            }
            XCTAssertThrowsError(try TaxAttributionRules.set(db: db, expenseType: .insurance, startYear: 2022, rule: .byDate, windowShiftMonths: 6)) {
                XCTAssertEqual($0 as? TaxError, .invalidWindowShift)
            }
            XCTAssertThrowsError(try TaxAttributionRules.set(db: db, expenseType: .insurance, startYear: 2022, rule: .apportionByCover, windowShiftMonths: 12)) {
                XCTAssertEqual($0 as? TaxError, .invalidWindowShift)
            }
            // Editing the year's rule keeps its window; a rule without months drops it; 0 removes it.
            try TaxAttributionRules.set(db: db, expenseType: .insurance, startYear: 2022, rule: .apportionByCover, windowShiftMonths: 6)
            XCTAssertEqual(try TaxAttributionRules.set(db: db, expenseType: .insurance, startYear: 2022, rule: .apportionPolicyYear).windowShiftMonths, 6)
            XCTAssertNil(try TaxAttributionRules.set(db: db, expenseType: .insurance, startYear: 2022, rule: .byDate).windowShiftMonths)
            try TaxAttributionRules.set(db: db, expenseType: .insurance, startYear: 2022, rule: .apportionByCover, windowShiftMonths: 6)
            XCTAssertNil(try TaxAttributionRules.set(db: db, expenseType: .insurance, startYear: 2022, rule: .apportionByCover, windowShiftMonths: 0).windowShiftMonths)
        }
    }

    // MARK: The tax data plan

    private func plan(_ json: String) throws -> TaxDataPlan.Plan {
        try TaxDataPlan.decodePlan(Data(json.utf8))
    }

    private let itemsPlan = """
        {"property": "Property A",
         "policyReceipts": [
           {"expenseType": "serviceCharge", "date": "2024-08-05", "amount": "400.00", "debitAmount": "1000.00", "coverFrom": "2024-01-01", "coverTo": "2024-05-01", "note": "Quotas Jan–Apr 2024"},
           {"expenseType": "serviceCharge", "date": "2024-08-05", "amount": "130.00", "debitAmount": "1000.00", "coverFrom": "2024-04-01", "coverTo": "2024-05-01", "note": "Extra charge"},
           {"expenseType": "serviceCharge", "date": "2024-08-05", "amount": "470.00", "debitAmount": "1000.00", "coverFrom": "2024-05-01", "coverTo": "2025-01-01", "note": "Quotas May–Dec 2024"}
         ],
         "attributionRules": [{"expenseType": "insurance", "rule": "apportionByCover", "startYear": 2022, "windowShiftMonths": 6}]}
        """

    func testThePlanRecordsADebitsItemsAndAYearsWindowIdempotently() throws {
        try debit("pay", (2024, 8, 5), -100_000)
        let outcome = try db.write { db in try TaxDataPlan.apply(db: db, plan: try plan(itemsPlan)) }
        XCTAssertEqual(outcome.count(.added, in: "Policy receipts"), 3)
        XCTAssertEqual(outcome.count(.added, in: "Attribution rules"), 1)
        XCTAssertTrue(outcome.changes.contains { $0.text.contains("→ item of debit 2024-08-05 CONDO 2024 €1,000.00") })
        try db.read { db in
            XCTAssertEqual(try TaxPolicyReceipt.filter(Column("transactionId") == id("pay")).fetchCount(db), 3)
            XCTAssertEqual(try TaxAttributionRules.effective(db: db, expenseType: .insurance, startYear: 2022).windowShiftMonths, 6)
        }
        XCTAssertEqual(try compute(2023).line(.serviceCharge)?.whole.native, 30_000)
        let again = try db.write { db in try TaxDataPlan.apply(db: db, plan: try plan(itemsPlan)) }
        XCTAssertEqual(again.count(.added), 0)
        XCTAssertEqual(again.count(.unchanged, in: "Policy receipts"), 3)
        XCTAssertEqual(again.count(.unchanged, in: "Attribution rules"), 1)
    }

    func testThePlanRefusesItemsThatDontAddUpAndWindowsOnEveryYearRules() throws {
        try debit("pay", (2024, 8, 5), -100_000)
        let short = itemsPlan.replacingOccurrences(of: "\"amount\": \"470.00\"", with: "\"amount\": \"460.00\"")
        XCTAssertThrowsError(try db.write { db in try TaxDataPlan.apply(db: db, plan: try plan(short)) }) { error in
            guard case let .refused(problems) = error as? TaxDataPlan.PlanError else { return XCTFail("\(error)") }
            XCTAssertEqual(problems, ["Policy receipts: the items of 2024-08-05 CONDO 2024 €1,000.00 add up to €990.00, not the debit's €1,000.00"])
        }
        let everyYear = itemsPlan.replacingOccurrences(of: "\"startYear\": 2022, ", with: "")
        XCTAssertThrowsError(try db.write { db in try TaxDataPlan.apply(db: db, plan: try plan(everyYear)) }) { error in
            guard case let .refused(problems) = error as? TaxDataPlan.PlanError else { return XCTFail("\(error)") }
            XCTAssertEqual(problems, ["Attribution rules: Insurance (building insurance), every year: a window can only be moved for one year"])
        }
        try db.read { db in XCTAssertEqual(try TaxPolicyReceipt.fetchCount(db), 0) }
    }

    func testIdenticalItemsMatchDistinctStoredReceipts() throws {
        try debit("pay", (2024, 8, 5), -26_000)
        let twice = """
            {"property": "Property A", "policyReceipts": [
              {"expenseType": "serviceCharge", "date": "2024-08-05", "amount": "130.00", "debitAmount": "260.00", "coverFrom": "2024-04-01", "coverTo": "2024-05-01", "note": "Extra 1"},
              {"expenseType": "serviceCharge", "date": "2024-08-05", "amount": "130.00", "debitAmount": "260.00", "coverFrom": "2024-04-01", "coverTo": "2024-05-01", "note": "Extra 2"}]}
            """
        let outcome = try db.write { db in try TaxDataPlan.apply(db: db, plan: try plan(twice)) }
        XCTAssertEqual(outcome.count(.added, in: "Policy receipts"), 2)
        try db.read { db in XCTAssertEqual(try TaxPolicyReceipt.fetchCount(db), 2) }
        let again = try db.write { db in try TaxDataPlan.apply(db: db, plan: try plan(twice)) }
        XCTAssertEqual(again.count(.unchanged, in: "Policy receipts"), 2)
        XCTAssertEqual(again.count(.added), 0)
    }

    func testEachFallbackSaysWhyTheItemsWereIgnored() throws {
        try debit("pay", (2024, 8, 5), -100_000)
        try item("a", of: "pay", 40_000, from: (2024, 1), to: (2024, 5))
        try item("b", of: "pay", 60_000, from: (2024, 5), to: (2025, 1))
        try db.write { db in try db.execute(sql: "UPDATE taxPolicyReceipt SET currency = 'gbp' WHERE id = ?", arguments: [id("b")]) }
        let warnings = try compute(2024).warnings
        XCTAssertTrue(warnings.contains("“CONDO 2024” of 2024-08-05 has item receipts in GBP, not the payment's EUR: the items are ignored and the payment is attributed whole. Correct the items."),
                      "\(warnings)")
    }

    func testAnIgnoredMarkIsWarnedOncePerPayment() throws {
        try itemisedPayment()
        try db.write { db in
            // PT tax can't be left off: a mark on a payment typed as PT tax (paid 2024, for 2023:
            // 2023/24) is ignored, and warned once although its three items each meet it.
            try TaxExpenseTypeMap.set(db: db, categoryId: id("condo"), expenseType: .foreignTax)
            var mark = TaxNotClaimed(startYear: 2023, transactionId: id("pay"))
            try mark.insert(db)
        }
        let result = try compute(2023)
        XCTAssertEqual(result.foreignTax.sources.count, 3)
        let warnings = result.warnings.filter { $0.contains("can't be left off") }
        XCTAssertEqual(warnings.count, 1, "\(warnings)")
    }
}
