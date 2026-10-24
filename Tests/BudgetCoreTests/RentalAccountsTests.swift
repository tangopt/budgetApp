import XCTest
import GRDB
@testable import BudgetCore

/// The rental accounts engine (plan phase 3 Task 2): every attribution rule, splits, manual
/// items, GBP-native items, finance costs apart, FTCR input. One synthetic EUR property owned
/// 50/50 by Person A and Person B, tax year 2024/25, HMRC rate 0.8.
final class RentalAccountsTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var ids: [String: Int64] = [:]
    private let year = UKTaxYear(startYear: 2024)

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func id(_ key: String) -> Int64 { ids[key]! }

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
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
            func account(_ name: String, _ currency: Currency, _ kind: AccountKind) throws -> Int64 {
                var account = Account(name: name, currency: currency, kind: kind, trackingMode: .imported)
                try account.insert(db)
                var batch = ImportBatch(accountId: account.id!, sourceFileName: "\(name).csv", importedAt: Date())
                try batch.insert(db)
                ids["batch:\(account.id!)"] = batch.id!
                return account.id!
            }
            ids["bank"] = try account("Bank A", .eur, .cash)
            ids["loan"] = try account("Loan A", .eur, .credit)
            ids["pounds"] = try account("Bank B", .gbp, .cash)
            try Properties.setAccount(db: db, propertyId: p, accountId: id("bank"), role: .current)
            try Properties.setAccount(db: db, propertyId: p, accountId: id("loan"), role: .mortgage)
            var group = CategoryGroup(name: "Property A")
            try group.insert(db)
            try Properties.addCategoryGroup(db: db, propertyId: p, categoryGroupId: group.id!)
            for (key, name, type) in [("rent", "Rental income", CategoryType.income), ("interest", "Mortgage interest", .expense),
                                      ("condo", "Condomínio", .expense), ("insurance", "Building insurance", .expense),
                                      ("life", "Life insurance", .expense), ("imi", "IMI", .expense), ("ptTax", "PT tax", .expense),
                                      ("accountant", "PT accountant", .expense), ("repairs", "Repairs", .expense),
                                      ("utilities", "Utilities", .expense), ("fees", "Sundry fees", .expense)] {
                var category = Category(name: name, type: type, groupId: group.id)
                try category.insert(db)
                ids[key] = category.id!
            }
            try TaxExpenseTypeMap.seed(db: db, propertyId: p)
            try HMRCRates.set(db: db, startYear: 2024, currencyCode: "EUR", gbpPerUnit: 0.8, source: .manual)
            try TaxAttributionRules.set(db: db, expenseType: .insurance, startYear: nil, rule: .apportionByCover, defaultCoverMonths: 6)
            // The PT tax tests below use the whole-previous-year basis (the time-apportioned
            // default has its own tests in TaxPolicyReceiptTests).
            try TaxAttributionRules.set(db: db, expenseType: .foreignTax, startYear: nil, rule: .previousCalendarYear)

            // Rent: Mar 2024 (before the year), Apr 2024 – Feb 2025 monthly, Mar – May 2025 in one receipt, one cancelled.
            var tenancy = Tenancy(propertyId: p, referenceLabel: "Room Contract AB", contractNumber: "3001", startDate: Self.date(2024, 3, 1))
            try Tenancies.save(db: db, &tenancy)
            var number = 0
            func receipt(_ start: Date, _ end: Date, _ amount: Int, status: RentReceiptStatus = .issued) throws {
                number += 1
                var receipt = RentReceipt(tenancyId: tenancy.id!, receiptNumber: "\(number)", periodStart: start, periodEnd: end,
                                          receiptDate: start, amountMinorUnits: amount, status: status)
                try RentReceipts.save(db: db, &receipt)
                ids["receipt\(number)"] = receipt.id!
            }
            try receipt(Self.date(2024, 3, 1), Self.date(2024, 3, 31), 100_000)
            for month in 0..<11 {
                let start = MonthRange.calendar.date(byAdding: .month, value: month, to: Self.date(2024, 4, 1))!
                let end = MonthRange.calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start)!
                try receipt(start, end, 100_000)
            }
            try receipt(Self.date(2025, 3, 1), Self.date(2025, 5, 31), 330_000)
            try receipt(Self.date(2024, 6, 1), Self.date(2024, 6, 30), 999_999, status: .cancelled)
        }

        // A rent credit without a receipt link (the rent comes from the receipts, not credits).
        try transaction("bank", "rent", (2024, 5, 2), 100_000, "TRANSFER TENANT")
        // Mortgage interest by payment date: 2 April 2025 (before 6 April) in; 2 April 2024 and March 2024 out.
        // By debit month it would be April 2024 instead.
        try transaction("loan", "interest", (2024, 3, 31), -40_000, "INTEREST MAR")
        try transaction("loan", "interest", (2024, 4, 2), -40_000, "INTEREST APR", key: "interestApr")
        try transaction("loan", "interest", (2025, 4, 2), -40_000, "INTEREST APR NEXT", key: "interestAprNext")
        // Condomínio by quota month: the 2024 quota (9 of 12 months in), the 2025 quota paid after
        // the year (3 of 12), an extra with its period in the note (3 of 6).
        try transaction("bank", "condo", (2024, 8, 5), -120_000, "Condominio 2024 REF-A0001", key: "condo2024")
        try transaction("bank", "condo", (2025, 6, 13), -240_000, "Condominio 2025 REF-A0002", key: "condo2025")
        try transaction("bank", "condo", (2025, 2, 10), -60_000, "Condominio extr REF-A0003", note: "quota 2025-01..2025-06")
        // Insurance by cover: Dec 2023 debit with a Jan–Jun 2024 document (3 of 6), Jun 2024 with
        // nothing (6 months from July: all in), Dec 2024 with the period in the note (3 of 6).
        try transaction("bank", "insurance", (2023, 12, 20), -30_000, "SEPADD/INSURER", key: "insDec23")
        try transaction("bank", "insurance", (2024, 6, 21), -30_000, "SEPADD/INSURER", key: "insJun24")
        try transaction("bank", "insurance", (2024, 12, 19), -30_000, "SEPADD/INSURER", note: "cover 2025-01-01 – 2025-06-30")
        try db.write { db in
            var document = EvidenceDocument(sha256: "ins", storedRelativePath: "in/ins.pdf", originalFileName: "Insurance.pdf", byteCount: 1,
                                            kind: .insuranceReceipt, periodStart: Self.date(2024, 1, 1), periodEnd: Self.date(2024, 6, 30), addedAt: Date())
            try document.insert(db)
            ids["insDoc"] = document.id!
            try EvidenceLinks.link(db: db, documentId: document.id!, to: .transaction(id("insDec23")))
        }
        // Life insurance: not deductible.
        try transaction("bank", "life", (2024, 5, 1), -5_000, "LIFE")
        // IMI for the previous calendar year: 2024 payments are 2023's; 2025's are 2024's (in); 2026's out.
        try transaction("bank", "imi", (2024, 5, 8), -27_000, "PG PAGEST 111111111111111")
        try transaction("bank", "imi", (2025, 5, 19), -26_500, "PG PAGEST 222222222222222")
        try transaction("bank", "imi", (2025, 8, 12), -26_500, "PG PAGEST 333333333333333")
        try transaction("bank", "imi", (2025, 11, 3), -27_000, "PG PAGEST 444444444444444")
        try transaction("bank", "imi", (2026, 5, 8), -28_000, "PG PAGEST 555555555555555")
        // PT tax for 2024, one payment per person (named in the note); 2024's payment is 2023's.
        try transaction("bank", "ptTax", (2024, 8, 5), -280_000, "PG PAGEST 666666666666666", note: "Person A")
        try transaction("bank", "ptTax", (2025, 8, 12), -290_000, "PG PAGEST 777777777777777", note: "IRS Person A")
        try transaction("bank", "ptTax", (2025, 8, 12), -300_000, "PG PAGEST 888888888888888", note: "IRS Person B")
        // Accountant by date: June 2024 and 3 April 2025 (before 6 April) in.
        try transaction("bank", "accountant", (2024, 6, 17), -24_000, "Contabilista")
        try transaction("bank", "accountant", (2025, 4, 3), -10_000, "Contabilista")
        try transaction("bank", "accountant", (2025, 4, 6), -5_000, "Contabilista next year")
        // Repairs paid in pounds: GBP-native.
        try transaction("pounds", "repairs", (2024, 9, 1), -10_000, "PLUMBER")
        // Utilities: recharged, not deductible. Sundry fees: other expense.
        try transaction("bank", "utilities", (2024, 7, 1), -8_000, "EDP")
        try transaction("bank", "fees", (2024, 7, 1), -433, "SUNDRY FEE")
        // Manual items: A's UK accountant in GBP; a whole-property EUR item entered under B.
        try db.write { db in
            var uk = TaxManualItem(startYear: 2024, personId: id("A"), propertyId: id("property"), expenseType: .accountancy,
                                   label: "UK accountant", amountMinorUnits: 30_000, currency: .gbp, date: Self.date(2025, 1, 10))
            try TaxManualItems.save(db: db, &uk)
            ids["ukAccountant"] = uk.id!
            var postage = TaxManualItem(startYear: 2024, personId: id("B"), propertyId: id("property"), expenseType: .otherExpense,
                                        label: "Postage", amountMinorUnits: 10_000, currency: .eur, isWholeProperty: true)
            try TaxManualItems.save(db: db, &postage)
        }
    }

    @discardableResult
    private func transaction(_ account: String, _ category: String, _ day: (Int, Int, Int), _ amount: Int, _ description: String,
                             note: String? = nil, key: String? = nil) throws -> Int64 {
        try db.write { db in
            let accountId = id(account)
            var transaction = Transaction(importBatchId: id("batch:\(accountId)"), accountId: accountId, date: Self.date(day.0, day.1, day.2),
                                          rawDescription: description, amountMinorUnits: amount, categoryId: id(category), status: .confirmed,
                                          categorizedBy: .manual, fingerprint: UUID().uuidString, note: note)
            try transaction.insert(db)
            if let key { ids[key] = transaction.id! }
            return transaction.id!
        }
    }

    private func compute(_ person: String = "A") throws -> RentalAccounts.Result {
        try db.read { db in try RentalAccounts.compute(db: db, taxYear: year, personId: id(person), propertyId: id("property")) }
    }

    // MARK: Rent

    func testRentByRentPeriodFromReceipts() throws {
        let result = try compute()
        // 11 × 1,000 + one month of the 3-month receipt for March 2025 (whole months: by month).
        let march = 110_000
        XCTAssertEqual(result.income.whole.native, 1_100_000 + march)
        XCTAssertEqual(result.income.amount.native, Int((Double(1_100_000 + march) / 2).rounded()))
        XCTAssertEqual(result.income.amount.gbp, Int((Double(result.income.amount.native) * 0.8).rounded()))
        XCTAssertEqual(result.income.rule, .byRentPeriod)
        XCTAssertEqual(result.income.sources.count, 12)
        XCTAssertTrue(result.income.sources.allSatisfy { if case .rentReceipt = $0.reference { return true } else { return false } })
        XCTAssertEqual(result.income.sources.last?.explanation, "Rent period 2025-03-01 – 2025-05-31: 1 of 3 months in Apr 2024 – Mar 2025")
        XCTAssertEqual(result.rentMonths.count, 12)
        XCTAssertEqual(result.rentMonths.first?.whole, 100_000)
        XCTAssertEqual(result.rentMonths.first?.amount, 50_000)
        XCTAssertEqual(result.rentMonths.last?.whole, march)
        XCTAssertEqual(result.rentMonths.reduce(0) { $0 + $1.whole }, result.income.whole.native)
        XCTAssertTrue(result.warnings.contains { $0.contains("match no rent receipt") }, "\(result.warnings)")
    }

    // MARK: Expense rules

    func testFinanceCostsByPaymentDateAreApart() throws {
        let result = try compute()
        XCTAssertEqual(result.financeCosts.whole.native, 40_000)
        XCTAssertEqual(result.financeCosts.sources.map(\.reference), [.transaction(id("interestAprNext"))])
        XCTAssertEqual(result.financeCosts.amount, RentalAccounts.Amount(native: 20_000, gbpNative: 0, gbp: 16_000))
        XCTAssertEqual(result.totals.financeCosts.native, 20_000)
        XCTAssertFalse(result.expenses.contains { $0.expenseType == .financeCost })
        XCTAssertEqual(result.financeCosts.rule, .byDate)
        XCTAssertEqual(result.financeCosts.ruleExplanation, "By payment date (cash basis): the interest paid 6 April – 5 April.")
        XCTAssertEqual(result.financeCosts.sources.first?.explanation, "Dated 2025-04-02, in 2024-04-06 – 2025-04-05")
    }

    func testFinanceCostsByDebitMonthWhenChosen() throws {
        try db.write { db in try TaxAttributionRules.set(db: db, expenseType: .financeCost, startYear: nil, rule: .byDebitMonth) }
        let result = try compute()
        XCTAssertEqual(result.financeCosts.sources.map(\.reference), [.transaction(id("interestApr"))])
        XCTAssertEqual(result.financeCosts.sources.first?.explanation, "Debit month Apr 2024, in Apr 2024 – Mar 2025")
    }

    func testServiceChargeByQuotaMonth() throws {
        let line = try XCTUnwrap(compute().line(.serviceCharge))
        // 1,200 × 9/12 + 2,400 × 3/12 + 600 × 3/6.
        XCTAssertEqual(line.whole.native, 90_000 + 60_000 + 30_000)
        XCTAssertEqual(line.amount.native, 90_000)
        let byId = Dictionary(uniqueKeysWithValues: line.sources.map { ($0.reference, $0) })
        XCTAssertEqual(byId[.transaction(id("condo2024"))]?.explanation, "9 of 12 quota months, Jan 2024 – Dec 2024 (from the description)")
        XCTAssertEqual(byId[.transaction(id("condo2025"))]?.attributedMinorUnits, 60_000)
        XCTAssertTrue(line.sources.contains { $0.explanation == "3 of 6 quota months, Jan 2025 – Jun 2025 (from the note)" })
    }

    func testInsuranceApportionedByCover() throws {
        let line = try XCTUnwrap(compute().line(.insurance))
        XCTAssertEqual(line.whole.native, 15_000 + 30_000 + 15_000)
        let byId = Dictionary(uniqueKeysWithValues: line.sources.map { ($0.reference, $0) })
        XCTAssertEqual(byId[.transaction(id("insDec23"))]?.explanation, "3 of 6 cover months, Jan 2024 – Jun 2024 (from the document Insurance.pdf)")
        XCTAssertEqual(byId[.transaction(id("insDec23"))]?.documentIds, [id("insDoc")])
        XCTAssertEqual(byId[.transaction(id("insJun24"))]?.explanation,
                       "6 of 6 cover months, Jul 2024 – Dec 2024 (assumed: 6 months from the month after the debit)")
        XCTAssertTrue(line.sources.contains { $0.explanation.hasPrefix("3 of 6 cover months, Jan 2025 – Jun 2025 (from the note)") })
    }

    func testCouncilTaxIsThePreviousCalendarYear() throws {
        let line = try XCTUnwrap(compute().line(.councilTax))
        XCTAssertEqual(line.whole.native, 80_000)
        XCTAssertEqual(line.sources.count, 3)
        XCTAssertEqual(line.sources.first?.explanation, "Paid 2025-05-19 for 2024, the year before payment → 2024/25")
        XCTAssertEqual(line.rule, .previousCalendarYear)
    }

    func testALinkedDocumentSetsTheYearOfALatePayment() throws {
        // A 2024 IMI paid in January 2026 would count for 2025; its notice says 2024.
        let late = try transaction("bank", "imi", (2026, 1, 15), -1_000, "PG PAGEST 999999999999999")
        try db.write { db in
            var notice = EvidenceDocument(sha256: "imi", storedRelativePath: "im/imi.pdf", originalFileName: "IMI.pdf", byteCount: 1, kind: .imiNotice,
                                          periodStart: Self.date(2024, 1, 1), periodEnd: Self.date(2024, 12, 31), addedAt: Date())
            try notice.insert(db)
            try EvidenceLinks.link(db: db, documentId: notice.id!, to: .transaction(late))
        }
        let line = try XCTUnwrap(compute().line(.councilTax))
        XCTAssertEqual(line.whole.native, 81_000)
        XCTAssertEqual(line.sources.last?.explanation, "Paid 2026-01-15 for 2024 (from the document IMI.pdf) → 2024/25")
    }

    func testForeignTaxIsPerPersonWhenNamed() throws {
        let a = try compute("A")
        let b = try compute("B")
        XCTAssertEqual(a.foreignTax.amount.native, 290_000)
        XCTAssertEqual(b.foreignTax.amount.native, 300_000)
        XCTAssertEqual(a.foreignTax.whole.native, 590_000)
        XCTAssertEqual(a.totals.foreignTax.gbp, 232_000)
        XCTAssertTrue(a.foreignTax.sources.contains { $0.explanation.hasSuffix("Person A's (named)") })
    }

    func testForeignTaxSplitsWhenNoOneIsNamed() throws {
        try db.write { db in
            try db.execute(sql: "UPDATE transaction_ SET note = NULL WHERE categoryId = ?", arguments: [id("ptTax")])
        }
        XCTAssertEqual(try compute("A").foreignTax.amount.native, 295_000)
    }

    func testByDateUsesTheTaxYearDaysAndManualItemsStayGBP() throws {
        let a = try compute("A")
        let accountancy = try XCTUnwrap(a.line(.accountancy))
        // 240 + 100 (3 April 2025), halved; A's own GBP 300 in full.
        XCTAssertEqual(accountancy.whole.native, 34_000)
        XCTAssertEqual(accountancy.amount, RentalAccounts.Amount(native: 17_000, gbpNative: 30_000, gbp: 13_600 + 30_000))
        XCTAssertTrue(accountancy.sources.contains { $0.reference == .manualItem(id("ukAccountant")) && $0.shareBasisPoints == 10_000 })
        // B has no UK accountant item.
        XCTAssertEqual(try compute("B").line(.accountancy)?.amount.gbpNative, 0)
    }

    func testGBPNativeTransactionsAndWholePropertyManualItems() throws {
        let a = try compute("A")
        XCTAssertEqual(a.line(.repairs)?.amount, RentalAccounts.Amount(native: 0, gbpNative: 5_000, gbp: 5_000))
        // Sundry fee 4.33 + postage 100 (whole property, entered under B), halved together.
        XCTAssertEqual(a.line(.otherExpense)?.amount.native, 5_217)
        XCTAssertEqual(a.line(.otherExpense)?.amount.gbp, 4_174)
    }

    func testNotDeductibleKeepsLifeInsuranceAndUtilitiesOut() throws {
        let a = try compute("A")
        XCTAssertEqual(a.notDeductible.whole.native, 13_000)
        XCTAssertEqual(a.line(.utilities)?.whole.native, 0)
        XCTAssertFalse(a.expenses.contains { $0.expenseType == .notDeductible })
    }

    func testTotals() throws {
        let a = try compute("A")
        let expensesNative = 90_000 + 30_000 + 40_000 + 17_000 + 5_217
        XCTAssertEqual(a.totals.expenses.native, expensesNative)
        XCTAssertEqual(a.totals.expenses.gbpNative, 30_000 + 5_000)
        XCTAssertEqual(a.totals.expenses.gbp, 72_000 + 24_000 + 32_000 + 43_600 + 5_000 + 4_174)
        XCTAssertEqual(a.totals.profit.native, a.totals.income.native - expensesNative)
        XCTAssertEqual(a.totals.profit.gbp, a.totals.income.gbp! - a.totals.expenses.gbp!)
        XCTAssertEqual(a.expenses.map(\.expenseType), TaxExpenseType.expenseLines)
        XCTAssertEqual(a.rate?.gbpPerUnit, 0.8)
    }

    // MARK: Settings

    func testSplitsOverrideOwnership() throws {
        try db.write { db in
            try TaxSplits.set(db: db, startYear: 2024, personId: id("A"), propertyId: id("property"), expenseType: .insurance, shareBasisPoints: 10_000)
            try TaxSplits.set(db: db, startYear: 2024, personId: id("A"), propertyId: id("property"), expenseType: nil, shareBasisPoints: 6_000)
        }
        let a = try compute("A")
        XCTAssertEqual(a.line(.insurance)?.amount.native, 60_000)
        XCTAssertEqual(a.line(.insurance)?.shareExplanation, "100% (split for this type, 2024/25)")
        XCTAssertEqual(a.line(.councilTax)?.amount.native, 48_000)
        XCTAssertEqual(a.line(.councilTax)?.shareExplanation, "60% (split for 2024/25)")
    }

    func testAYearOverrideChangesTheRule() throws {
        try db.write { db in
            try TaxAttributionRules.set(db: db, expenseType: .councilTax, startYear: 2024, rule: .byDate)
        }
        let line = try XCTUnwrap(compute().line(.councilTax))
        // By date: only the May 2024 payment falls in 6 Apr 2024 – 5 Apr 2025.
        XCTAssertEqual(line.whole.native, 27_000)
        XCTAssertEqual(line.rule, .byDate)
    }

    func testRemappedCategoryMovesLines() throws {
        try db.write { db in try TaxExpenseTypeMap.set(db: db, categoryId: id("utilities"), expenseType: .utilities) }
        XCTAssertEqual(try compute().line(.utilities)?.whole.native, 8_000)
    }

    func testMissingRateLeavesGBPEmptyAndWarns() throws {
        try db.write { db in _ = try HMRCRates.remove(db: db, startYear: 2024, currencyCode: "EUR") }
        let a = try compute()
        XCTAssertNil(a.income.amount.gbp)
        XCTAssertNil(a.totals.profit.gbp)
        XCTAssertEqual(a.line(.repairs)?.amount.gbp, 5_000)
        XCTAssertTrue(a.warnings.contains { $0.hasPrefix("No HMRC average rate") })
    }

    func testUnconfirmedTypesAreFlagged() throws {
        try db.write { db in _ = try TaxExpenseTypeMapping.deleteAll(db) }
        let a = try compute()
        XCTAssertTrue(a.warnings.contains { $0.hasPrefix("Tax types suggested") })
        XCTAssertEqual(a.line(.councilTax)?.whole.native, 80_000)
    }

    // MARK: Period hints

    func testPeriodHints() {
        func interval(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> DateInterval {
            DateInterval(start: Self.date(a.0, a.1, a.2), end: Self.date(b.0, b.1, b.2))
        }
        XCTAssertEqual(TaxPeriodHint.period(in: "cover 2024-07-01 – 2024-12-31"), interval((2024, 7, 1), (2025, 1, 1)))
        XCTAssertEqual(TaxPeriodHint.period(in: "2024-07..2024-12"), interval((2024, 7, 1), (2025, 1, 1)))
        XCTAssertEqual(TaxPeriodHint.period(in: "07/2024-12/2024"), interval((2024, 7, 1), (2025, 1, 1)))
        XCTAssertEqual(TaxPeriodHint.period(in: "quota 2025-02"), interval((2025, 2, 1), (2025, 3, 1)))
        XCTAssertEqual(TaxPeriodHint.period(in: "03/2025"), interval((2025, 3, 1), (2025, 4, 1)))
        XCTAssertEqual(TaxPeriodHint.period(in: "Condominio 2024 REF-A0001"), interval((2024, 1, 1), (2025, 1, 1)))
        XCTAssertNil(TaxPeriodHint.period(in: "PG PAGEST 000020240000001"))
        XCTAssertNil(TaxPeriodHint.period(in: nil))
    }

    func testMonthSpan() {
        XCTAssertEqual(RentalAccounts.monthSpan(DateInterval(start: Self.date(2024, 1, 1), end: Self.date(2025, 1, 1))).count, 12)
        let mid = RentalAccounts.monthSpan(DateInterval(start: Self.date(2024, 6, 21), end: Self.date(2024, 12, 21)))
        XCTAssertEqual(mid.first, Self.date(2024, 7, 1))
        XCTAssertEqual(mid.count, 6)
    }
}

// MARK: - Accountant template and PDF

extension RentalAccountsTests {
    func testAccountantTemplateRoundTrips() throws {
        let data = try db.read { db in
            try AccountantTemplate.xlsx(db: db, taxYear: year, personId: id("A"), propertyId: id("property"),
                                        other: AccountantTemplate.OtherInformation(p60Pay: 5_000_000), notes: ["Synthetic note"])
        }
        XCTAssertEqual(try XLSXReader.sheetNames(data: data), ["Rental accounts - 2024.25", "Other information"])
        let accounts = try compute("A")
        let rental = try XLSXReader.read(data: data, sheet: "Rental accounts - 2024.25").rows
        func cell(_ rows: [[String?]], _ reference: String) -> String? {
            let (column, row) = XLSXWriter.split(reference)!
            guard row - 1 < rows.count, column - 1 < rows[row - 1].count else { return nil }
            return rows[row - 1][column - 1]
        }
        func euros(_ minor: Int) -> String { XLSXWriter.format(Double(minor) / 100) }
        XCTAssertEqual(cell(rental, "A1"), "Person A")
        XCTAssertEqual(cell(rental, "A3"), "Tax year: 2024/25")
        XCTAssertEqual(cell(rental, "D8"), "EUR")
        XCTAssertEqual(cell(rental, "B11"), "April")
        XCTAssertEqual(cell(rental, "D11"), "500")
        XCTAssertEqual(cell(rental, "B22"), "March")
        XCTAssertEqual(cell(rental, "D24"), euros(accounts.income.amount.native))
        XCTAssertNil(cell(rental, "G24"), "months add up to the rent line")
        XCTAssertEqual(cell(rental, "B28"), "Mortgage interest")
        XCTAssertEqual(cell(rental, "D28"), "200")
        XCTAssertEqual(cell(rental, "D32"), "900")
        XCTAssertEqual(cell(rental, "D33"), "300")
        XCTAssertEqual(cell(rental, "D38"), "400")
        XCTAssertEqual(cell(rental, "D42"), "170")
        XCTAssertEqual(cell(rental, "G42"), "Also £300.00 in GBP, not included above (UK accountant).")
        XCTAssertEqual(cell(rental, "D44"), "52.17")
        XCTAssertNil(cell(rental, "D30"))
        let expenses = 20_000 + 90_000 + 30_000 + 40_000 + 17_000 + 5_217
        XCTAssertEqual(cell(rental, "D47"), euros(expenses))
        XCTAssertEqual(cell(rental, "D49"), euros(accounts.income.amount.native - expenses))
        XCTAssertEqual(cell(rental, "A60"), "1")
        XCTAssertEqual(cell(rental, "B60"), "Synthetic note")
        XCTAssertEqual(cell(rental, "A70"), "11")

        let other = try XLSXReader.read(data: data, sheet: "Other information").rows
        // Calendar 2024 rent: March – December receipts (10 × 1,000), halved; PT tax for 2024.
        XCTAssertEqual(cell(other, "D5"), "Year 2024")
        XCTAssertEqual(cell(other, "D7"), "5000")
        XCTAssertEqual(cell(other, "D9"), "2900")
        XCTAssertEqual(cell(other, "D11"), "0.58")
        XCTAssertEqual(cell(other, "D20"), "50000")
        XCTAssertNil(cell(other, "D21"))
        XCTAssertEqual(AccountantTemplate.fileName(taxYear: year, personName: "Person A"), "Template - 2024-25 - Person A.xlsx")
    }

    func testRentalAccountsPDFHasTheLinesAndSources() throws {
        let accounts = try compute("A")
        let data = RentalAccountsPDF.data(accounts: accounts, personName: "Person A", propertyName: "Property A", generatedAt: Self.date(2025, 6, 1))
        let url = EvidenceTestPDFs.temporaryURL("accounts.pdf")
        try data.write(to: url)
        let text = try XCTUnwrap(EvidenceTextExtractor.extract(from: url).text)
        for expected in ["Rental accounts 2024/25", "Person A", "Mortgage interest", "Service charge", "Foreign tax paid", "Sources",
                         "Condominio 2024", "quota months"] {
            XCTAssertTrue(text.contains(expected), expected)
        }
        XCTAssertGreaterThanOrEqual(CGPDFDocument(CGDataProvider(data: data as CFData)!)!.numberOfPages, 1)
    }
}

// MARK: - Review fixes

extension RentalAccountsTests {
    func testTenantWithholdingIsForeignTaxOfTheReceiptYear() throws {
        try db.write { db in
            // May 2024's receipt (dated 2024): PT tax for 2024; Feb 2025's (dated 2025): for 2025.
            try db.execute(sql: "UPDATE rentReceipt SET withholdingMinorUnits = 25000 WHERE id = ?", arguments: [id("receipt3")])
            try db.execute(sql: "UPDATE rentReceipt SET withholdingMinorUnits = 10000 WHERE id = ?", arguments: [id("receipt12")])
        }
        let a = try compute("A")
        XCTAssertEqual(a.foreignTax.amount.native, 290_000 + 12_500)
        let withheld = a.foreignTax.sources.filter { $0.reference == .rentReceipt(id("receipt3")) }
        XCTAssertEqual(withheld.count, 1)
        XCTAssertEqual(withheld.first?.explanation,
                       "Rent period 2024-05-01 – 2024-05-31: 31 of 31 days in 2024, PT tax for 2024 → 2024/25; at the rent share")
        XCTAssertFalse(a.foreignTax.sources.contains { $0.reference == .rentReceipt(id("receipt12")) })
    }

    func testNamingRequiresOneSideAndWholeWords() {
        XCTAssertEqual(RentalAccounts.named(person: "Person A", others: ["Person B"], note: "IRS Person A", documents: []), .this)
        XCTAssertEqual(RentalAccounts.named(person: "Person A", others: ["Person B"], note: "IRS person b", documents: []), .other)
        XCTAssertEqual(RentalAccounts.named(person: "Person A", others: ["Person B"], note: "Person A and Person B", documents: []), .none)
        XCTAssertEqual(RentalAccounts.named(person: "Person A", others: ["Person B"], note: "Person AB", documents: []), .none)
        let joint = EvidenceDocument(sha256: "j", storedRelativePath: "j/j.pdf", originalFileName: "j.pdf", byteCount: 1,
                                     persons: ["Person A", "Person B"], addedAt: Date())
        XCTAssertEqual(RentalAccounts.named(person: "Person A", others: ["Person B"], note: nil, documents: [joint]), .none)
    }

    func testJointNoteSplitsThePTTax() throws {
        try db.write { db in
            try db.execute(sql: "UPDATE transaction_ SET note = 'IRS Person A and Person B' WHERE categoryId = ?", arguments: [id("ptTax")])
        }
        XCTAssertEqual(try compute("A").foreignTax.amount.native, 295_000)
    }

    func testCoverApportionmentAddsUpAcrossYears() throws {
        let split = try transaction("bank", "insurance", (2025, 1, 20), -10_000, "SEPADD/INSURER", note: "cover 2025-02-01 – 2025-04-30")
        let first = try XCTUnwrap(compute().line(.insurance)?.sources.first { $0.reference == .transaction(split) })
        let next = try db.read { db in try RentalAccounts.compute(db: db, taxYear: year.next, personId: id("A"), propertyId: id("property")) }
        let second = try XCTUnwrap(next.line(.insurance)?.sources.first { $0.reference == .transaction(split) })
        XCTAssertEqual(first.attributedMinorUnits, 6_667)
        XCTAssertEqual(first.attributedMinorUnits + second.attributedMinorUnits, 10_000)
    }

    func testPreviousYearHintsMustBeAWholeYearAndInvoicesDateByDate() throws {
        // A month in the note isn't a year: the payment year rule still applies (2025 → 2024).
        try transaction("bank", "imi", (2025, 9, 1), -1_000, "PG PAGEST 000000000000002", note: "2025-02")
        // An accountant paid after the year, invoiced inside it.
        let late = try transaction("bank", "accountant", (2025, 4, 20), -6_000, "Contabilista")
        try db.write { db in
            var invoice = EvidenceDocument(sha256: "inv", storedRelativePath: "in/inv.pdf", originalFileName: "Invoice.pdf", byteCount: 1,
                                           kind: .accountantInvoice, docDate: Self.date(2025, 3, 20), addedAt: Date())
            try invoice.insert(db)
            try EvidenceLinks.link(db: db, documentId: invoice.id!, to: .transaction(late))
        }
        let a = try compute()
        XCTAssertEqual(a.line(.councilTax)?.whole.native, 81_000)
        XCTAssertEqual(a.line(.accountancy)?.whole.native, 34_000 + 6_000)
        XCTAssertEqual(a.line(.accountancy)?.sources.first { $0.reference == .transaction(late) }?.explanation,
                       "Invoice dated 2025-03-20 (Invoice.pdf), in 2024-04-06 – 2025-04-05")
    }

    func testRateUsesUnitsPerPoundWhenStored() throws {
        try db.write { db in
            try HMRCRates.set(db: db, startYear: 2024, currencyCode: "EUR", gbpPerUnit: 1 / 1.25, unitsPerPound: 1.25, source: .hmrcPublished)
        }
        let a = try compute()
        XCTAssertEqual(a.financeCosts.amount.gbp, 16_000)
        XCTAssertEqual(a.rate?.gbp(100_001), 80_001)
    }

    func testAGBPPropertyConvertsEURSourcesAtTheEURRate() throws {
        let (propertyId, categoryId) = try db.write { db -> (Int64, Int64) in
            var property = Property(name: "Property B", country: "GB", currency: .gbp)
            try Properties.save(db: db, &property)
            _ = try Properties.setOwners(db: db, propertyId: property.id!, [
                PropertyOwner(propertyId: property.id!, personId: id("A"), shareBasisPoints: 10_000)
            ])
            var group = CategoryGroup(name: "Property B")
            try group.insert(db)
            try Properties.addCategoryGroup(db: db, propertyId: property.id!, categoryGroupId: group.id!)
            var repairs = Category(name: "Repairs B", type: .expense, groupId: group.id)
            try repairs.insert(db)
            return (property.id!, repairs.id!)
        }
        ids["repairsB"] = categoryId
        try transaction("bank", "repairsB", (2024, 9, 1), -10_000, "BUILDER")
        func accounts(_ person: String) throws -> RentalAccounts.Result {
            try db.read { db in try RentalAccounts.compute(db: db, taxYear: year, personId: id(person), propertyId: propertyId) }
        }
        XCTAssertEqual(try accounts("A").line(.repairs)?.amount, RentalAccounts.Amount(native: 8_000, gbpNative: 0, gbp: 8_000))
        XCTAssertTrue(try accounts("B").warnings.contains { $0.contains("owns no share") })
        try db.write { db in _ = try HMRCRates.remove(db: db, startYear: 2024, currencyCode: "EUR") }
        let missing = try accounts("A")
        XCTAssertNil(missing.line(.repairs)?.amount.gbp)
        XCTAssertTrue(missing.warnings.contains { $0.hasPrefix("No HMRC average rate for EUR") })
    }
}

// MARK: - Screens

extension RentalAccountsTests {
    func testOverviewRowsFromOwnershipToNow() throws {
        let rows = try db.read { db in try TaxOverview.rows(db: db, now: Self.date(2025, 10, 1)) }
        // The first tenancy starts March 2024 (2023/24) through 2025/26, both people, latest first.
        XCTAssertEqual(rows.map { "\($0.year.startYear) \($0.person.name)" },
                       ["2025 Person A", "2025 Person B", "2024 Person A", "2024 Person B", "2023 Person A", "2023 Person B"])
        XCTAssertEqual(rows[2].eurRate?.gbpPerUnit, 0.8)
        XCTAssertNil(rows[0].eurRate)
        XCTAssertEqual(rows[2].properties.map(\.name), ["Property A"])
        XCTAssertEqual(rows[2].status, .preparing)
        try db.write { db in try TaxOverview.setStatus(db: db, startYear: 2024, personId: id("A"), status: .filed) }
        let after = try db.read { db in try TaxOverview.rows(db: db, now: Self.date(2025, 10, 1)) }
        XCTAssertEqual(after[2].status, .filed)
        XCTAssertNotNil(after[2].taxYearId)
    }

    func testYearPageGathersTheSettings() throws {
        try db.write { db in
            try TaxSplits.set(db: db, startYear: 2024, personId: id("A"), propertyId: id("property"), expenseType: .insurance, shareBasisPoints: 10_000)
            try TaxAttributionRules.set(db: db, expenseType: .councilTax, startYear: 2024, rule: .byDate)
        }
        let page = try XCTUnwrap(try db.read { db in try TaxOverview.page(db: db, personId: id("A"), startYear: 2024, now: Self.date(2025, 10, 1)) })
        XCTAssertEqual(page.property?.name, "Property A")
        XCTAssertEqual(page.accounts?.line(.insurance)?.amount.native, 60_000)
        XCTAssertEqual(page.splits.count, 1)
        XCTAssertEqual(page.ownershipShareBasisPoints, 5_000)
        XCTAssertEqual(page.rules.first { $0.expenseType == .councilTax }?.scope, .thisYear)
        XCTAssertEqual(page.rules.first { $0.expenseType == .insurance }?.scope, .allYears)
        XCTAssertEqual(page.rules.first { $0.expenseType == .rentalIncome }?.scope, .builtIn)
        XCTAssertEqual(page.manualItems.map(\.label), ["UK accountant"])
        XCTAssertEqual(page.rates.map(\.currencyCode), ["EUR"])
        XCTAssertFalse(page.categoryTypes.isEmpty)
    }

    func testAsFiledTagOnlyOnAFiledYearsExpenseItems() throws {
        try db.write { db in
            var fee = TaxManualItem(startYear: 2024, personId: id("A"), propertyId: id("property"), expenseType: .otherExpense,
                                    label: "Cover the rules don't allow", amountMinorUnits: 5_000, currency: .eur,
                                    notes: "As filed: kept as the return deducted it")
            try TaxManualItems.save(db: db, &fee)
            var interest = TaxManualItem(startYear: 2024, personId: id("A"), propertyId: id("property"), expenseType: .financeCost,
                                         label: "Interest as filed", amountMinorUnits: 5_000, currency: .eur,
                                         notes: "As filed: not an expense item")
            try TaxManualItems.save(db: db, &interest)
        }
        func notes() throws -> (expense: String?, finance: String?) {
            let result = try compute()
            let expense = result.expenses.first { $0.expenseType == .otherExpense }!.sources.first { $0.description == "Cover the rules don't allow" }!
            let finance = result.financeCosts.sources.first { $0.description == "Interest as filed" }!
            return (expense.asFiledNote, finance.asFiledNote)
        }
        // An open year: worked out by the rules, no tag.
        var tags = try notes()
        XCTAssertNil(tags.expense)
        XCTAssertNil(tags.finance)
        // Filed: the expense item carries the reason; the finance cost item doesn't.
        try db.write { db in try TaxOverview.setStatus(db: db, startYear: 2024, personId: id("A"), status: .filed) }
        tags = try notes()
        XCTAssertEqual(tags.expense, "kept as the return deducted it")
        XCTAssertNil(tags.finance)
    }

    func testManualItemSaveAppliesStagedDocuments() throws {
        try db.write { db in
            var document = EvidenceDocument(sha256: "pp", storedRelativePath: "pp/pp.pdf", originalFileName: "Postage.pdf", byteCount: 1, addedAt: Date())
            try document.insert(db)
            var item = TaxManualItem(startYear: 2024, personId: id("A"), propertyId: id("property"), expenseType: .otherExpense,
                                     label: "Postage", amountMinorUnits: 500, currency: .gbp)
            try TaxManualItems.save(db: db, &item, documents: EvidenceLinkChanges(link: [document.id!]))
            XCTAssertEqual(try EvidenceLinks.documents(db: db, for: .taxManualItem(item.id!)).map(\.id), [document.id])
        }
    }

    func testEvidencePackListsEachDocumentOncePerLine() throws {
        try db.write { db in
            var notice = EvidenceDocument(sha256: "n2", storedRelativePath: "n2/n2.pdf", originalFileName: "Notice.pdf", byteCount: 1,
                                          canonicalName: "20240101 - Lisbon: Insurance", addedAt: Date())
            try notice.insert(db)
            try EvidenceLinks.link(db: db, documentId: notice.id!, to: .transaction(id("insJun24")))
        }
        let accounts = try compute()
        let files = try db.read { db in try TaxEvidencePack.files(db: db, accounts: accounts, taxYearId: nil) }
        let insurance = files.filter { $0.folder.hasSuffix("Insurance (building insurance)") }
        XCTAssertEqual(insurance.map(\.fileName).sorted(), ["20240101 - Lisbon- Insurance.pdf", "Insurance.pdf"])
        XCTAssertEqual(TaxEvidencePack.folderName(year: year, personName: "Person A"), "Evidence 2024-25 - Person A")
    }
}

// MARK: - Export polish

extension RentalAccountsTests {
    func testWithholdingOnAReceiptAcrossTheYearEndIsSpreadByDays() throws {
        try db.write { db in
            var tenancy = Tenancy(propertyId: id("property"), referenceLabel: "Room Contract CD", contractNumber: "3002", startDate: Self.date(2024, 12, 1))
            try Tenancies.save(db: db, &tenancy)
            var receipt = RentReceipt(tenancyId: tenancy.id!, receiptNumber: "X1", periodStart: Self.date(2024, 12, 1), periodEnd: Self.date(2025, 1, 31),
                                      receiptDate: Self.date(2025, 1, 5), amountMinorUnits: 200_000, withholdingMinorUnits: 62_000)
            try RentReceipts.save(db: db, &receipt)
            ids["across"] = receipt.id!
        }
        let source = try XCTUnwrap(compute().foreignTax.sources.first { $0.reference == .rentReceipt(id("across")) })
        XCTAssertEqual(source.attributedMinorUnits, 31_000)
    }

    func testRefundsReduceTheirLineAndUnclearNamesAreFlagged() throws {
        try db.write { db in
            let groupId = try XCTUnwrap(try Properties.categoryGroupIds(db: db, propertyId: id("property")).first)
            for (key, name, type) in [("irsRefund", "IRS refund", CategoryType.income), ("refund", "Insurance refund", .income),
                                      ("instalments", "Mortgage instalments", .expense)] {
                var category = Category(name: name, type: type, groupId: groupId)
                try category.insert(db)
                ids[key] = category.id!
            }
        }
        try transaction("bank", "irsRefund", (2025, 9, 1), 20_000, "REEMBOLSO IRS")
        let a = try compute()
        // 290,000 + 300,000 paid, 200 refunded (split, not named).
        XCTAssertEqual(a.foreignTax.whole.native, 590_000 - 20_000)
        XCTAssertTrue(a.warnings.contains { $0.contains("“Insurance refund” looks like a refund") })
        XCTAssertTrue(a.warnings.contains { $0.contains("“Mortgage instalments” looks like loan instalments") })
        XCTAssertFalse(a.warnings.contains { $0.contains("“IRS refund” looks like") })
    }

    func testAGBPPropertyTemplateUsesPoundTotals() throws {
        var accounts = try compute()
        accounts.currency = .gbp
        let sheets = AccountantTemplate.sheets(accounts: accounts, personName: "Person A", foreignTaxBasisRent: 0)
        let styles = Dictionary(uniqueKeysWithValues: sheets[0].cells.map { ($0.reference, $0.style) })
        XCTAssertEqual(styles["D24"], .poundSubtotal)
        XCTAssertEqual(styles["D47"], .poundSubtotal)
        XCTAssertEqual(styles["D49"], .poundTotal)
        XCTAssertEqual(styles["D11"], .pound)
    }

    func testPDFWrapsLongTextInsteadOfTruncating() throws {
        var accounts = try compute()
        let long = "A warning long enough to need several lines on an A4 page, ending with the word ZEBRAFINAL"
        accounts.warnings = [String(repeating: "word ", count: 30) + long]
        let data = RentalAccountsPDF.data(accounts: accounts, personName: "Person A", propertyName: "Property A")
        let url = EvidenceTestPDFs.temporaryURL("wrapped.pdf")
        try data.write(to: url)
        let text = try XCTUnwrap(EvidenceTextExtractor.extract(from: url).text)
        XCTAssertTrue(text.contains("ZEBRAFINAL"))
    }
}

// MARK: - Regression

extension RentalAccountsTests {
    static let history = """
        country,year,person,field,value,currency,source_file
        UK,2024-25,Person A,rental_income,6000.0,EUR,Draft.pdf
        UK,2024-25,Person A,rental_income,6050.00,EUR,Example approval pack.pdf
        UK,2024-25,Person A,rental_exp_council_tax_if_paid_by_landlord,400.00,EUR,Example approval pack.pdf
        UK,2024-25,Person A,rental_exp_council_tax_if_paid_by_landlord,320.00,GBP,Example approval pack.pdf
        UK,2024-25,Person A,fx_rate_implied_gbp_per_eur,0.8,GBP/EUR,Example approval pack.pdf
        UK,2024-25,Person A,tax_rate,"28% (note, with comma)",,x.pdf
        PT,2024,Person A,rental_income,1.0,EUR,y.pdf
        UK,2024-25,Person A,rental_exp_accountancy_fee,300.0,GBP,Example approval pack.pdf
        """

    func testParseHistoryPrefersTheApprovalPack() {
        let filed = TaxRegression.parseHistory(Self.history)
        XCTAssertEqual(filed.map(\.field), ["rental_income", "rental_exp_council_tax_if_paid_by_landlord",
                                            "rental_exp_council_tax_if_paid_by_landlord", "rental_exp_accountancy_fee"])
        XCTAssertEqual(filed[0].minorUnits, 605_000)
        XCTAssertEqual(filed[0].startYear, 2024)
        XCTAssertEqual(filed[2].currency, "GBP")
    }

    func testRegressionAppliesSettingsAndCompares() throws {
        let settings = TaxRegression.Settings(property: "Property A", personAliases: nil, years: [
            .init(startYear: 2024, eurGbpPerUnit: 0.8, rateNote: nil,
                  splits: [.init(person: "Person A", expenseType: "insurance", percent: 100)],
                  manualItems: [.init(person: "Person A", expenseType: "accountancy", label: "UK accountant", amount: "300.00",
                                      currency: "GBP", wholeProperty: nil)])
        ])
        let (accounts, comparisons) = try db.write { db -> ([String: RentalAccounts.Result], [TaxRegression.Comparison]) in
            try db.execute(sql: "DELETE FROM taxManualItem")
            try TaxRegression.apply(db: db, settings: settings)
            try TaxRegression.apply(db: db, settings: settings) // idempotent
            return try TaxRegression.compare(db: db, settings: settings, filed: TaxRegression.parseHistory(Self.history))
        }
        XCTAssertEqual(try db.read { db in try TaxManualItem.fetchCount(db) }, 1)
        XCTAssertEqual(accounts["2024|Person A"]?.rate?.source, .filedReturn)
        XCTAssertEqual(accounts["2024|Person A"]?.line(.insurance)?.amount.native, 60_000)
        XCTAssertTrue(comparisons[0].matches, "\(comparisons[0])")
        XCTAssertTrue(comparisons[1].matches)
        XCTAssertEqual(comparisons[2].app, 32_000)
        XCTAssertEqual(comparisons[3].difference, Int((17_000 * 0.8).rounded()))
        let report = TaxRegression.report(comparisons, accounts: accounts)
        XCTAssertTrue(report.contains("*rental_exp_accountancy_fee"))
        XCTAssertTrue(report.contains("Contabilista"))
    }

    func testRuleAlternativesLeaveTheSettingsAlone() throws {
        let alternatives = try db.write { db in
            try TaxRegression.ruleAlternatives(db: db, propertyId: id("property"), personId: id("A"), startYear: 2024, type: .councilTax)
        }
        XCTAssertEqual(alternatives.first { $0.0 == "Previous calendar year" }?.1, 80_000)
        XCTAssertEqual(alternatives.first { $0.0 == "By date" }?.1, 27_000)
        XCTAssertEqual(try db.read { db in try TaxAttributionRules.effective(db: db, expenseType: .councilTax, startYear: 2024).rule }, .previousCalendarYear)
    }
}

// MARK: - Screen review fixes

extension RentalAccountsTests {
    func testFileNamesAreSafe() {
        XCTAssertEqual(TaxFileNames.sanitized("..Person\n A/B:C\u{0007} "), "Person A-B-C")
        XCTAssertEqual(TaxFileNames.sanitized(" . "), "Untitled")
        let long = TaxFileNames.fileName(String(repeating: "é", count: 300), ext: "pdf")
        XCTAssertLessThanOrEqual(long.utf8.count, 200)
        XCTAssertTrue(long.hasSuffix(".pdf"))
        XCTAssertEqual(TaxFileNames.rentalAccountsPDF(year: year, personName: "Person A"), "Rental accounts - 2024-25 - Person A.pdf")
        XCTAssertEqual(year.fileLabel, "2024-25")
    }

    func testPageReusesKnownRows() throws {
        let page = try db.read { db -> TaxOverview.YearPage? in
            let rows = try TaxOverview.rows(db: db, now: Self.date(2025, 10, 1))
            return try TaxOverview.page(db: db, personId: id("A"), startYear: 2024, rows: rows)
        }
        XCTAssertEqual(page?.row.year.startYear, 2024)
    }

    func testInstalmentCategoriesStayUnconfirmed() throws {
        try db.write { db in
            let groupId = try XCTUnwrap(try Properties.categoryGroupIds(db: db, propertyId: id("property")).first)
            var category = Category(name: "Mortgage instalments", type: .expense, groupId: groupId)
            try category.insert(db)
            ids["instalments"] = category.id!
            try TaxExpenseTypeMap.seed(db: db, propertyId: id("property"))
            XCTAssertNil(try TaxExpenseTypeMapping.filter(Column("categoryId") == category.id!).fetchOne(db))
        }
        try transaction("bank", "instalments", (2024, 6, 1), -100_000, "INSTALMENT")
        let a = try compute()
        XCTAssertEqual(a.notDeductible.whole.native, 13_000 + 100_000)
        XCTAssertTrue(a.warnings.contains { $0.contains("put the interest part under a finance-cost category") })
    }
}

// MARK: - Regression guard

extension RentalAccountsTests {
    func testAppDatabaseGuardResolvesLinksAndCase() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("Guard-\(UUID().uuidString)", isDirectory: true)
        let app = base.appendingPathComponent("Support/Budget", isDirectory: true)
        let elsewhere = base.appendingPathComponent("Elsewhere", isDirectory: true)
        try manager.createDirectory(at: app, withIntermediateDirectories: true)
        try manager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        let real = app.appendingPathComponent("budget.sqlite")
        try Data("db".utf8).write(to: real)
        let copy = elsewhere.appendingPathComponent("copy.sqlite")
        try Data("db".utf8).write(to: copy)
        let folders = [app]

        XCTAssertTrue(TaxRegression.isAppDatabase(real.path, folders: folders))
        XCTAssertTrue(TaxRegression.isAppDatabase(app.appendingPathComponent("report.txt").path, folders: folders), "a new file in the folder")
        XCTAssertTrue(TaxRegression.isAppDatabase(real.path.replacingOccurrences(of: "/Budget/", with: "/BUDGET/"), folders: folders))
        XCTAssertTrue(TaxRegression.isAppDatabase(elsewhere.appendingPathComponent("../Support/Budget/budget.sqlite").path, folders: folders))
        let symlink = elsewhere.appendingPathComponent("link")
        try manager.createSymbolicLink(at: symlink, withDestinationURL: app)
        XCTAssertTrue(TaxRegression.isAppDatabase(symlink.appendingPathComponent("budget.sqlite").path, folders: folders))
        let hardLink = elsewhere.appendingPathComponent("hard.sqlite")
        try manager.linkItem(at: real, to: hardLink)
        XCTAssertTrue(TaxRegression.isAppDatabase(hardLink.path, folders: folders))
        XCTAssertFalse(TaxRegression.isAppDatabase(copy.path, folders: folders))
        XCTAssertFalse(TaxRegression.isAppDatabase(elsewhere.appendingPathComponent("report.txt").path, folders: folders))

        XCTAssertTrue(TaxRegression.isSameFile(copy.path, elsewhere.appendingPathComponent("./copy.sqlite").path))
        XCTAssertTrue(TaxRegression.isSameFile(hardLink.path, real.path))
        XCTAssertFalse(TaxRegression.isSameFile(copy.path, real.path))
        XCTAssertFalse(TaxRegression.appDataFolders().isEmpty)
    }

    func testParseHistoryIgnoresAByteOrderMark() {
        XCTAssertEqual(TaxRegression.parseHistory("\u{FEFF}" + Self.history).count, 4)
    }

    func testLinkedDocumentsReadsOnlyTheRecordsAskedForInChunksWithoutTheirText() throws {
        let documents = try db.write { db -> [Int64: [EvidenceDocument]] in
            func link(_ name: String, docDate: Date, to entityId: Int64) throws {
                var document = EvidenceDocument(sha256: name, storedRelativePath: "x/\(name).pdf", originalFileName: "\(name).pdf", byteCount: 1,
                                                docDate: docDate, textStatus: .text, extractedText: "Synthetic text", addedAt: Date())
                try document.insert(db)
                // Ids only (no receipts behind them): the query is what's tested.
                try db.execute(sql: "INSERT INTO documentLink (documentId, entityType, entityId, createdAt) VALUES (?, ?, ?, ?)",
                               arguments: [document.id!, EvidenceEntityType.rentReceipt.rawValue, entityId, Date()])
            }
            try link("late", docDate: Self.date(2024, 9, 1), to: 7)
            try link("early", docDate: Self.date(2024, 5, 1), to: 7)
            try link("far", docDate: Self.date(2024, 6, 1), to: 1_100)
            try link("other", docDate: Self.date(2024, 6, 1), to: 3)
            // More ids than one query takes, the records with documents in different chunks.
            let ids = Array(Int64(5)...Int64(1_200)).reversed()
            return try RentalAccounts.linkedDocuments(db: db, type: .rentReceipt, ids: Array(ids))
        }
        XCTAssertEqual(documents.mapValues { $0.map(\.sha256) }, [7: ["early", "late"], 1_100: ["far"]])
        XCTAssertNil(documents[7]?.first?.extractedText)
        XCTAssertEqual(documents[7]?.first?.textStatus, .text)
    }
}
