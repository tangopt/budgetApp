import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// `TaxFigures.snapshot` reads what the years share once per call (`TaxReadCache`) and works
/// each year out once: its figures must be those of working every year out on its own, with
/// nothing read (`SelfAssessment.compute`, `RentalAccounts.compute` without a memo). Synthetic
/// data: one person, one property, made-up amounts.
final class TaxFiguresSnapshotTests: XCTestCase {
    private func pounds(_ value: Int) -> Int { value * 100 }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// The year's "SA calculation · …" figures as a snapshot holds them.
    private func calculation(_ result: SelfAssessment.Result) -> [String: TaxFigures.Value] {
        let c = result.calculation
        let pairs: [(String, Int)] = [
            ("total income", c.totalIncome), ("property profit", c.propertyProfit), ("taxable income", c.taxableIncome),
            ("income tax charged", c.incomeTaxCharged), ("finance costs", c.financeCosts), ("finance cost reduction", c.financeCostReduction),
            ("finance costs carried forward", c.financeCostsCarriedForward), ("foreign tax credit relief", c.foreignTaxCreditRelief),
            ("income tax due", c.incomeTaxDue), ("SA liability", c.selfAssessmentLiability), ("balancing payment", c.balancingPayment),
            ("property loss carried forward", c.propertyLossCarriedForward)
        ]
        return Dictionary(uniqueKeysWithValues: pairs.map { ("SA calculation · \($0.0)", .amount($0.1)) })
    }

    private func values(_ snapshot: TaxFigures.Snapshot, year: Int) -> [TaxFigures.Key: TaxFigures.Value] {
        snapshot.values.filter { $0.key.startYear == year }
    }

    // MARK: Brought forward

    /// Four years whose finance costs and a loss carry forward from year to year: each year's
    /// brought-forward figures are the year before's carried-forward ones, the same whether the
    /// snapshot takes every year, the year alone, or the return is worked out on its own.
    func testBroughtForwardChainIsTheSameInOneSnapshotAndYearByYear() throws {
        let manager = try TestDatabase.migratedManager()
        let personId = try manager.dbQueue.write { db -> Int64 in
            var person = Person(name: "Person A")
            try People.save(db: db, &person)
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            _ = try Properties.setOwners(db: db, propertyId: property.id!, [PropertyOwner(propertyId: property.id!, personId: person.id!, shareBasisPoints: 10_000)])
            // Rent, other expenses, finance costs (pounds): profit 1,000, 4,000, a 3,000 loss, 5,000.
            let years: [(Int, Int, Int, Int)] = [(2020, 5_000, 4_000, 3_000), (2021, 5_000, 1_000, 3_000), (2022, 2_000, 5_000, 1_000),
                                                 (2023, 6_000, 1_000, 500)]
            for (year, rent, expenses, finance) in years {
                try HMRCRates.set(db: db, startYear: year, currencyCode: "EUR", gbpPerUnit: 0.85, unitsPerPound: nil, source: .manual)
                var employment = Employment(startYear: year, personId: person.id!, employerName: "Example Ltd")
                try Employments.save(db: db, &employment)
                var income = EmploymentIncome(employmentId: employment.id!, source: .p60, payMinorUnits: pounds(30_000),
                                              taxDeductedMinorUnits: pounds(3_000))
                try Employments.save(db: db, &income)
                for (type, amount) in [(TaxExpenseType.rentalIncome, rent), (.otherExpense, expenses), (.financeCost, finance)] {
                    var item = TaxManualItem(startYear: year, personId: person.id!, propertyId: property.id!, expenseType: type, label: type.rawValue,
                                             amountMinorUnits: pounds(amount), currency: .gbp)
                    try TaxManualItems.save(db: db, &item)
                }
            }
            return person.id!
        }
        try manager.dbQueue.read { db in
            let all = try TaxFigures.snapshot(db: db, years: [2020, 2021, 2022, 2023])
            var previous: SelfAssessment.Result?
            for year in 2020...2023 {
                let alone = try TaxFigures.snapshot(db: db, only: [year])
                XCTAssertEqual(values(alone, year: year), values(all, year: year), "\(year)")
                // Worked out on its own (every earlier year again, nothing cached): the same figures.
                let result = try SelfAssessment.compute(db: db, startYear: year, personId: personId)
                for (field, value) in calculation(result) {
                    XCTAssertEqual(all.values[TaxFigures.Key(startYear: year, person: "Person A", field: field)], value, "\(year) \(field)")
                }
                XCTAssertEqual(result.inputs.financeCostsBroughtForward, previous?.calculation.financeCostsCarriedForward ?? 0, "\(year)")
                XCTAssertEqual(result.inputs.propertyLossBroughtForward, previous?.calculation.propertyLossCarriedForward ?? 0, "\(year)")
                previous = result
            }
            func figure(_ year: Int, _ name: String) -> TaxFigures.Value? {
                all.values[TaxFigures.Key(startYear: year, person: "Person A", field: "SA calculation · \(name)")]
            }
            // 2020/21: profit £1,000 limits the relief, £2,000 carried; 2021/22: £5,000 against £4,000, £1,000 carried;
            // 2022/23: a £3,000 loss, no relief, £2,000 carried; 2023/24: the loss and £2,500 against £5,000.
            XCTAssertEqual(figure(2020, "finance costs carried forward"), .amount(pounds(2_000)))
            XCTAssertEqual(figure(2021, "finance costs carried forward"), .amount(pounds(1_000)))
            XCTAssertEqual(figure(2022, "finance costs carried forward"), .amount(pounds(2_000)))
            XCTAssertEqual(figure(2022, "property loss carried forward"), .amount(pounds(3_000)))
            XCTAssertEqual(figure(2023, "property loss carried forward"), .amount(0))
            XCTAssertEqual(figure(2023, "property profit"), .amount(pounds(2_000)))
            XCTAssertEqual(figure(2023, "finance costs carried forward"), .amount(pounds(500)))
        }
    }

    /// Nothing read is kept after the call, even on a memo used again: after the ownership changes,
    /// a snapshot on the same memo of a year it hasn't worked out yet reads the new owners.
    func testASnapshotAfterAnEditReadsTheEdit() throws {
        let manager = try TestDatabase.migratedManager()
        let (personId, propertyId) = try manager.dbQueue.write { db -> (Int64, Int64) in
            var person = Person(name: "Person A")
            try People.save(db: db, &person)
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            _ = try Properties.setOwners(db: db, propertyId: property.id!, [PropertyOwner(propertyId: property.id!, personId: person.id!, shareBasisPoints: 10_000)])
            for year in [2022, 2023] {
                var rent = TaxManualItem(startYear: year, personId: person.id!, propertyId: property.id!, expenseType: .rentalIncome, label: "Rent",
                                         amountMinorUnits: pounds(5_000), currency: .gbp, isWholeProperty: true)
                try TaxManualItems.save(db: db, &rent)
            }
            return (person.id!, property.id!)
        }
        let memo = TaxComputationMemo()
        let field = "Property A · total income in GBP"
        func income(_ snapshot: TaxFigures.Snapshot, _ year: Int) -> TaxFigures.Value? {
            snapshot.values[TaxFigures.Key(startYear: year, person: "Person A", field: field)]
        }
        try manager.dbQueue.writeWithoutTransaction { db in
            // Reads the ownership rows (2022/23's accounts and return) with this memo.
            let before = try TaxFigures.snapshot(db: db, only: [2022], memo: memo)
            XCTAssertEqual(income(before, 2022), .amount(pounds(5_000)))
            XCTAssertNil(memo.reads, "the call's reads end with it")
            try db.inSavepoint {
                // Half the property: 2023/24's accounts, new to the memo, must see it.
                var other = Person(name: "Person B")
                try People.save(db: db, &other)
                _ = try Properties.setOwners(db: db, propertyId: propertyId, [
                    PropertyOwner(propertyId: propertyId, personId: personId, shareBasisPoints: 5_000),
                    PropertyOwner(propertyId: propertyId, personId: other.id!, shareBasisPoints: 5_000)
                ])
                let after = try TaxFigures.snapshot(db: db, only: [2023], memo: memo)
                XCTAssertEqual(income(after, 2023), .amount(pounds(2_500)))
                return .rollback
            }
            XCTAssertNil(memo.reads)
        }
    }

    // MARK: Recharges received across the year's end

    /// Utility recharges paid on 5 and 6 April 2025: by date the first is 2024/25's and the
    /// second 2025/26's; by debit month (April) both are 2025/26's. Each year's accounts net
    /// only their own, in one snapshot as when worked out alone.
    func testRechargesReceivedOnEitherSideOfTheYearEnd() throws {
        let manager = try TestDatabase.migratedManager()
        let db = manager.dbQueue
        var ids: [String: Int64] = [:]
        try db.write { db in
            var person = Person(name: "Person A")
            try People.save(db: db, &person)
            ids["A"] = person.id!
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            let p = property.id!
            ids["property"] = p
            _ = try Properties.setOwners(db: db, propertyId: p, [PropertyOwner(propertyId: p, personId: person.id!, shareBasisPoints: 10_000)])
            var account = Account(name: "Bank A", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "bank.csv", importedAt: Date())
            try batch.insert(db)
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
            for year in [2024, 2025] {
                try HMRCRates.set(db: db, startYear: year, currencyCode: "EUR", gbpPerUnit: 0.8, source: .manual)
            }
            var tenancy = Tenancy(propertyId: p, referenceLabel: "Room Contract AB", contractNumber: "3001", startDate: Self.date(2024, 1, 1))
            try Tenancies.save(db: db, &tenancy)
            var power = UtilityProvider(propertyId: p, name: "Example Power", kind: .electricity)
            try Recharges.saveProvider(db: db, &power)

            func transaction(_ category: String, _ date: Date, _ amount: Int) throws -> Int64 {
                var transaction = Transaction(importBatchId: batch.id!, accountId: account.id!, date: date, rawDescription: "TRANSFER",
                                              amountMinorUnits: amount, categoryId: ids[category], status: .confirmed, categorizedBy: .manual,
                                              fingerprint: UUID().uuidString)
                try transaction.insert(db)
                return transaction.id!
            }
            // Utilities paid in 2024/25 and in 2025/26; a February and a March statement, paid on either side of 5/6 April.
            for (number, month, debitDay, amount, paidOn, key) in [("P-1", 2, Self.date(2025, 2, 10), 3_000, Self.date(2025, 4, 5), "early"),
                                                                    ("P-2", 3, Self.date(2025, 4, 20), 2_000, Self.date(2025, 4, 6), "late")] {
                let debit = try transaction("utilities", debitDay, -amount)
                var invoice = UtilityInvoice(providerId: power.id!, invoiceNumber: number, issueDate: Self.date(2025, month, 1),
                                             amountMinorUnits: amount, transactionId: debit)
                try Recharges.saveInvoice(db: db, &invoice)
                let statement = try Recharges.draftStatement(db: db, tenancyId: tenancy.id!, month: Self.date(2025, month, 1))
                _ = try Recharges.markSent(db: db, statementId: statement.id!, at: Self.date(2025, month, 28))
                let credit = try transaction("rent", paidOn, amount)
                ids[key] = credit
                try Recharges.linkPayment(db: db, statementId: statement.id!, transactionId: credit, amountMinorUnits: amount)
            }
        }
        let property = ids["property"]!
        func received(_ interval: DateInterval?) throws -> [Int64] {
            try db.read { db in try Recharges.received(db: db, propertyId: property, in: interval).map { $0.transaction.id! } }
        }
        XCTAssertEqual(try received(nil), [ids["early"]!, ids["late"]!])
        XCTAssertEqual(try received(UKTaxYear(startYear: 2024).interval), [ids["early"]!])
        XCTAssertEqual(try received(UKTaxYear(startYear: 2025).interval), [ids["late"]!])
        XCTAssertEqual(try received(UKTaxYear(startYear: 2025).monthsInterval), [ids["early"]!, ids["late"]!])
        XCTAssertEqual(try received(UKTaxYear(startYear: 2024).monthsInterval), [])

        func check(_ expected: [Int: Int], _ label: String) throws {
            try db.read { db in
                let memo = TaxComputationMemo()
                let all = try TaxFigures.snapshot(db: db, only: [2024, 2025], memo: memo)
                for (year, recharges) in expected {
                    let key = TaxComputationMemo.AccountsKey(startYear: year, personId: ids["A"]!, propertyId: property)
                    let inSnapshot = try XCTUnwrap(memo.knownAccounts(key))
                    let alone = try RentalAccounts.compute(db: db, taxYear: UKTaxYear(startYear: year), personId: ids["A"]!, propertyId: property)
                    XCTAssertEqual(inSnapshot, alone, "\(label) \(year)")
                    XCTAssertEqual(alone.utilityNetting.rechargesReceived, recharges, "\(label) \(year)")
                    XCTAssertEqual(values(try TaxFigures.snapshot(db: db, only: [year]), year: year), values(all, year: year), "\(label) \(year)")
                }
            }
        }
        // By date (the default): 3,000 in 2024/25, 2,000 in 2025/26.
        try check([2024: 3_000, 2025: 2_000], "by date")
        try db.write { db in
            for year in [2024, 2025] {
                _ = try TaxAttributionRules.set(db: db, expenseType: .utilities, startYear: year, rule: .byDebitMonth)
            }
        }
        try check([2024: 0, 2025: 5_000], "by debit month")
    }
}

/// The reads `TaxReadCache` batches (a year's splits and rules, the ownership rows, the documents
/// linked to records) still show a change on a filed year to the filed-year guard's replay of
/// what the figures read (`FiledYearGuard.recordedSnapshot`, `YearReads.changedYears`) and to
/// the edit check (`FiledYearEditCheck`). Synthetic data: Person A filed 2022/23; Property A
/// (wholly A's, GBP) has rent and a repair that year.
final class TaxFiguresGuardReplayTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var ids: [String: Int64] = [:]

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func id(_ key: String) -> Int64 { ids[key]! }

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
        ids = try db.write { db in
            var ids: [String: Int64] = [:]
            var person = Person(name: "Person A")
            try People.save(db: db, &person)
            ids["A"] = person.id!
            var year = TaxYear(startYear: 2022, personId: person.id!, status: .filed)
            try year.insert(db)
            var property = Property(name: "Property A", country: "PT", currency: .gbp)
            try Properties.save(db: db, &property)
            ids["property"] = property.id!
            _ = try Properties.setOwners(db: db, propertyId: property.id!, [
                PropertyOwner(propertyId: property.id!, personId: person.id!, shareBasisPoints: 10_000)
            ])
            var account = Account(name: "Bank A", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "bank.csv", importedAt: Self.date(2025, 1, 1))
            try batch.insert(db)
            ids["batch"] = batch.id!
            ids["account"] = account.id!
            try Properties.setAccount(db: db, propertyId: property.id!, accountId: account.id!, role: .current)
            var group = CategoryGroup(name: "Property A")
            try group.insert(db)
            try Properties.addCategoryGroup(db: db, propertyId: property.id!, categoryGroupId: group.id!)
            for (key, name, type) in [("rent", "Rental income", CategoryType.income), ("repairs", "Repairs", .expense)] {
                var category = Category(name: name, type: type, groupId: group.id)
                try category.insert(db)
                ids[key] = category.id!
            }
            try TaxExpenseTypeMap.seed(db: db, propertyId: property.id!)
            for (key, day, description, amount, category) in [("rentRow", Self.date(2022, 6, 1), "TENANT RENT", 500_000, ids["rent"]!),
                                                               ("plumber", Self.date(2022, 7, 1), "PLUMBER", -10_000, ids["repairs"]!)] {
                var t = Transaction(importBatchId: batch.id!, accountId: account.id!, date: day, rawDescription: description,
                                    amountMinorUnits: amount, categoryId: category, status: .confirmed, categorizedBy: .manual,
                                    fingerprint: "fp-\(key)")
                try t.insert(db)
                ids[key] = t.id!
            }
            // An invoice dated in 2023/24, not yet linked: linked to the repair, it moves it out of 2022/23.
            var invoice = EvidenceDocument(sha256: "synthetic-invoice", storedRelativePath: "", originalFileName: "invoice.pdf", byteCount: 1,
                                           kind: .utilityInvoice, docDate: Self.date(2023, 5, 1), addedAt: Self.date(2025, 1, 1))
            try invoice.insert(db)
            ids["invoice"] = invoice.id!
            return ids
        }
    }

    private func repairType(_ db: Database) throws -> TaxExpenseType {
        try XCTUnwrap(TaxExpenseTypeMap.entries(db: db, propertyId: id("property")).first { $0.category.id == id("repairs") }).expenseType
    }

    private var changes: [(String, (Database) throws -> Void)] {
        [
            ("split", { db in
                try TaxSplits.set(db: db, startYear: 2022, personId: self.id("A"), propertyId: self.id("property"), expenseType: nil,
                                  shareBasisPoints: 5_000)
            }),
            ("attribution rule", { db in
                _ = try TaxAttributionRules.set(db: db, expenseType: try self.repairType(db), startYear: 2022, rule: .previousCalendarYear)
            }),
            ("owner", { db in
                var other = Person(name: "Person B")
                try People.save(db: db, &other)
                _ = try Properties.setOwners(db: db, propertyId: self.id("property"), [
                    PropertyOwner(propertyId: self.id("property"), personId: self.id("A"), shareBasisPoints: 5_000),
                    PropertyOwner(propertyId: self.id("property"), personId: other.id!, shareBasisPoints: 5_000)
                ])
            }),
            ("document link", { db in
                try EvidenceLinks.link(db: db, documentId: self.id("invoice"), to: .transaction(self.id("plumber")))
            })
        ]
    }

    func testTheGuardReplayFindsEachBatchedReadChangingInAFiledYear() throws {
        for (label, change) in changes {
            try db.writeWithoutTransaction { db in
                let (before, recorded) = try FiledYearGuard.recordedSnapshot(db: db, years: try TaxFigures.years(db: db))
                let reads = try XCTUnwrap(recorded, label)
                try db.inSavepoint {
                    // A change the figures don't read: nothing to take again.
                    var groceries = Category(name: "Groceries", type: .expense)
                    try groceries.insert(db)
                    XCTAssertEqual(try reads.changedYears(db: db, written: nil), [], label)
                    let written = try TaxFiguresReads.writtenTables(db: db) { try change(db) }
                    XCTAssertEqual(try reads.changedYears(db: db, written: written), [2022], label)
                    XCTAssertEqual(try reads.changedYears(db: db, written: nil), [2022], label)
                    // And it does move 2022/23's figures.
                    let after = try TaxFigures.snapshot(db: db, only: [2022])
                    XCTAssertNotEqual(after.values.filter { $0.key.startYear == 2022 }, before.values.filter { $0.key.startYear == 2022 }, label)
                    return .rollback
                }
            }
        }
    }

    func testTheEditCheckAsksForEachBatchedReadChangingInAFiledYear() throws {
        for (label, change) in changes {
            let outcome = try db.write { db in
                try FiledYearEditCheck.save(db: db, edit: label, scope: .everyYear, now: Self.date(2026, 10, 25)) { try change(db) }
            }
            guard case .asks(let question) = outcome else {
                XCTFail("\(label): saved without asking")
                continue
            }
            // The filed 2022/23 return's boxes move (later years follow through brought-forward figures).
            XCTAssertTrue(question.years.contains { $0.startYear == 2022 && !$0.lines.isEmpty }, "\(label): \(question.years.map(\.startYear))")
        }
    }
}
