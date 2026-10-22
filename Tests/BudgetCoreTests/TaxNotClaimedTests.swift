import XCTest
import GRDB
@testable import BudgetCore

/// "Deductible, not claimed" (`TaxNotClaimed`): a source left off a year's return is out of
/// that year's line and totals, listed apart with its figures; the plan's year set-up (splits,
/// employments, HMRC payments, statuses, the foreign tax in pence) is idempotent and refuses
/// contradictions. Synthetic EUR property owned 50/50 by Person A and Person B.
final class TaxNotClaimedTests: XCTestCase {
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
            for (key, name, type) in [("accountant", "PT accountant", CategoryType.expense), ("ptTax", "PT tax", .expense),
                                      ("rent", "Rental income", .income)] {
                var category = Category(name: name, type: type, groupId: group.id)
                try category.insert(db)
                ids[key] = category.id!
            }
            try HMRCRates.set(db: db, startYear: 2021, currencyCode: "EUR", gbpPerUnit: 0.85, source: .filedReturn)
            try HMRCRates.set(db: db, startYear: 2020, currencyCode: "EUR", gbpPerUnit: 0.9, source: .filedReturn)
        }
        try transaction("fee", (2022, 3, 14), -18_000, category: "accountant", description: "ACCOUNTANT 220314")
        try transaction("fee2", (2021, 10, 4), -10_000, category: "accountant", description: "ACCOUNTANT 211004")
        try transaction("tax", (2022, 8, 8), -100_000, category: "ptTax", description: "PG PAGEST 1")
        try transaction("rent", (2021, 6, 1), 100_000, category: "rent", description: "RENT JUNE")
    }

    @discardableResult
    private func transaction(_ key: String, _ day: (Int, Int, Int), _ amount: Int, category: String, description: String) throws -> Int64 {
        try db.write { db in
            var row = Transaction(importBatchId: id("batch"), accountId: id("bank"), date: Self.date(day.0, day.1, day.2),
                                  rawDescription: description, amountMinorUnits: amount, categoryId: id(category), status: .confirmed,
                                  categorizedBy: .manual, fingerprint: UUID().uuidString)
            try row.insert(db)
            ids[key] = row.id!
            return row.id!
        }
    }

    private func accounts(_ person: String = "A", year: Int = 2021) throws -> RentalAccounts.Result {
        try db.read { db in try RentalAccounts.compute(db: db, taxYear: UKTaxYear(startYear: year), personId: id(person), propertyId: id("property")) }
    }

    private func mark(_ reference: RentalAccounts.SourceReference, year: Int = 2021, _ notClaimed: Bool = true, notes: String? = "Not on the return") throws {
        try db.write { db in try TaxNotClaimedSources.set(db: db, startYear: year, reference: reference, notClaimed: notClaimed, notes: notes) }
    }

    // MARK: The rental accounts

    func testANotClaimedDebitLeavesTheLineAndIsListedApartForEveryOwner() throws {
        let before = try accounts()
        XCTAssertEqual(before.line(.accountancy)?.whole.native, 28_000)
        XCTAssertEqual(before.totals.expenses.native, 14_000)

        try mark(.transaction(id("fee")))
        for person in ["A", "B"] {
            let after = try accounts(person)
            let line = try XCTUnwrap(after.line(.accountancy))
            XCTAssertEqual(line.sources.map(\.reference), [.transaction(id("fee2"))])
            XCTAssertEqual(line.whole.native, 10_000)
            XCTAssertEqual(line.amount.native, 5_000)
            XCTAssertEqual(after.totals.expenses.native, 5_000)
            XCTAssertEqual(line.notClaimedSources.map(\.reference), [.transaction(id("fee"))])
            XCTAssertEqual(line.notClaimedWhole.native, 18_000)
            XCTAssertEqual(line.notClaimed.native, 9_000)
            XCTAssertEqual(line.notClaimed.gbp, 7_650)
            XCTAssertEqual(after.notClaimedLines.map(\.expenseType), [.accountancy])
            XCTAssertEqual(after.notClaimedTotal.gbp, 7_650)
            XCTAssertTrue(line.notClaimedSources[0].explanation.contains("deductible, not claimed in 2021/22 (Not on the return)"))
        }

        // Claimed again: back on the line.
        try mark(.transaction(id("fee")), false)
        XCTAssertEqual(try accounts(), before)
    }

    func testAMarkCountsOnlyInItsYearAndOnlyASourceOfThatYearCanBeMarked() throws {
        // The fee feeds 2021/22, not 2022/23: refused there.
        XCTAssertThrowsError(try mark(.transaction(id("fee")), year: 2022)) { XCTAssertEqual($0 as? TaxError, .notASourceOfTheYear) }
        // A stored mark of another year (written directly) leaves this year alone.
        try db.write { db in
            var row = TaxNotClaimed(startYear: 2022, transactionId: id("fee"))
            try row.insert(db)
        }
        XCTAssertEqual(try accounts().line(.accountancy)?.whole.native, 28_000)
        XCTAssertTrue(try accounts().notClaimedLines.isEmpty)
    }

    func testANotClaimedUtilityIsNotCountedAsPaidWhenRechargesAreNetted() throws {
        try db.write { db in
            var utilities = Category(name: "Utilities", type: .expense, groupId: try Category.fetchOne(db, key: id("accountant"))!.groupId)
            try utilities.insert(db)
            ids["utilities"] = utilities.id!
            try RechargeNetting.set(db: db, startYear: 2021, mode: .netOfRecharges)
        }
        try transaction("power", (2021, 9, 10), -6_000, category: "utilities", description: "POWER 0921")
        try transaction("water", (2021, 10, 10), -2_000, category: "utilities", description: "WATER 1021")
        XCTAssertEqual(try accounts().utilityNetting.utilitiesPaid, 8_000)
        XCTAssertEqual(try accounts().line(.utilities)?.whole.native, 8_000)
        // On the Utilities line once netted (its category alone says not deductible): it can be left out.
        try mark(.transaction(id("power")))
        let after = try accounts()
        XCTAssertEqual(after.utilityNetting.utilitiesPaid, 2_000)
        XCTAssertEqual(after.line(.utilities)?.whole.native, 2_000)
        XCTAssertEqual(after.line(.utilities)?.notClaimedWhole.native, 6_000)
    }

    func testManualItemsAndReceiptsOnTheirOwnCanBeLeftOut() throws {
        let (item, receipt) = try db.write { db -> (Int64, Int64) in
            var item = TaxManualItem(startYear: 2021, personId: id("A"), propertyId: id("property"), expenseType: .repairs, label: "Repairs",
                                     amountMinorUnits: 50_000, currency: .eur, isWholeProperty: true)
            try TaxManualItems.save(db: db, &item)
            var receipt = TaxPolicyReceipt(propertyId: id("property"), expenseType: .insurance, date: Self.date(2021, 6, 20), amountMinorUnits: 20_000,
                                           currency: .eur, coverStart: Self.date(2021, 6, 1), coverEnd: Self.date(2021, 12, 1))
            try TaxPolicyReceipts.save(db: db, &receipt)
            return (item.id!, receipt.id!)
        }
        XCTAssertEqual(try accounts().line(.repairs)?.amount.native, 25_000)
        XCTAssertEqual(try accounts().line(.insurance)?.amount.native, 10_000)
        try mark(.manualItem(item))
        try mark(.policyReceipt(receipt))
        let after = try accounts()
        XCTAssertEqual(after.line(.repairs)?.amount.native, 0)
        XCTAssertEqual(after.line(.repairs)?.notClaimed.native, 25_000)
        XCTAssertEqual(after.line(.insurance)?.amount.native, 0)
        XCTAssertEqual(after.line(.insurance)?.notClaimed.native, 10_000)
        XCTAssertEqual(after.notClaimedLines.map(\.expenseType), [.insurance, .repairs])
        // The item's own year only; deleting it drops the mark.
        try db.write { db in _ = try TaxManualItems.delete(db: db, id: item) }
        XCTAssertEqual(try db.read { db in try TaxNotClaimed.fetchCount(db) }, 1)
    }

    func testOnlyACostOfADeductibleLineCanBeMarked() throws {
        for reference in [RentalAccounts.SourceReference.transaction(id("tax")), .rentReceipt(1)] {
            XCTAssertThrowsError(try mark(reference)) { XCTAssertEqual($0 as? TaxError, .notClaimable) }
        }
        // Rent comes from the receipts (by rent period): the credit feeds no line.
        XCTAssertThrowsError(try mark(.transaction(id("rent")))) { XCTAssertEqual($0 as? TaxError, .notASourceOfTheYear) }
        XCTAssertThrowsError(try mark(.manualItem(999))) { XCTAssertEqual($0 as? TaxError, .sourceNotFound) }
        XCTAssertThrowsError(try mark(.transaction(999))) { XCTAssertEqual($0 as? TaxError, .transactionNotFound) }
        // The finance costs can be.
        let item = try db.write { db -> Int64 in
            var item = TaxManualItem(startYear: 2021, personId: id("A"), propertyId: id("property"), expenseType: .financeCost, label: "Interest",
                                     amountMinorUnits: 10_000, currency: .eur, isWholeProperty: true)
            try TaxManualItems.save(db: db, &item)
            return item.id!
        }
        try mark(.manualItem(item))
        XCTAssertEqual(try accounts().financeCosts.notClaimed.native, 5_000)
        XCTAssertEqual(try accounts().totals.financeCosts.native, 0)
    }

    func testAMarkOnALineThatCantBeLeftOutIsIgnoredWithAWarning() throws {
        try mark(.transaction(id("fee")))
        // The category later feeds another line: the mark stays but is ignored.
        try db.write { db in try TaxExpenseTypeMap.set(db: db, categoryId: id("accountant"), expenseType: .foreignTax) }
        let result = try accounts()
        XCTAssertTrue(result.notClaimedLines.isEmpty)
        XCTAssertTrue(result.warnings.contains { $0.contains("is marked not claimed in 2021/22") && $0.contains("the mark is ignored") })
    }

    func testMarkingIsIdempotentAndDeletingTheTransactionDropsTheMark() throws {
        try mark(.transaction(id("fee")), notes: "first")
        try mark(.transaction(id("fee")), notes: "second")
        try db.read { db in
            let rows = try TaxNotClaimed.fetchAll(db)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.notes, "second")
            XCTAssertTrue(try TaxNotClaimedSources.isMarked(db: db, startYear: 2021, reference: .transaction(id("fee"))))
        }
        try db.write { db in _ = try Transaction.deleteOne(db, key: id("fee")) }
        XCTAssertEqual(try db.read { db in try TaxNotClaimed.fetchCount(db) }, 0)
    }

    func testTheTableTakesExactlyOneSource() throws {
        XCTAssertThrowsError(try db.write { db in
            var row = TaxNotClaimed(startYear: 2021)
            try row.insert(db)
        })
        XCTAssertThrowsError(try db.write { db in
            var row = TaxNotClaimed(startYear: 2021, transactionId: id("fee"), manualItemId: nil, policyReceiptId: nil)
            try row.insert(db)
            var twice = TaxNotClaimed(startYear: 2021, transactionId: id("fee"))
            try twice.insert(db)
        })
    }

    // MARK: The plan

    private func plan(_ extra: (inout TaxDataPlan.Plan) -> Void = { _ in }) -> TaxDataPlan.Plan {
        var plan = TaxDataPlan.Plan(property: "Property A")
        plan.notClaimed = [.init(account: "Bank A", date: "2022-03-14", amount: "180.00", description: "ACCOUNTANT", startYear: 2021,
                                 note: "Not on the filed return")]
        plan.manualItems = [.init(startYear: 2020, person: "Person A", expenseType: "accountancy", label: "Accountant 2021-03-15",
                                  amount: "150.00", currency: "EUR", date: "2021-03-15", wholeProperty: true, note: "Not on the 2020/21 return",
                                  notClaimed: true)]
        plan.splits = [.init(startYear: 2020, person: "Person A", expenseType: nil, percent: 100),
                       .init(startYear: 2020, person: "Person B", expenseType: nil, percent: 0)]
        plan.employments = [.init(startYear: 2020, person: "Person A", employer: "Example Ltd", payeReference: "123/AB456", source: "p60",
                                  pay: "50000.00", tax: "9000.00", benefits: [.init(kind: "medical", amount: "1000.00", description: "Medical")],
                                  note: nil)]
        plan.hmrcPayments = [.init(person: "Person A", startYear: 2020, date: "2021-12-10", amount: "100.25", kind: "balancingPayment",
                                   reference: "1234567890K", note: nil)]
        plan.taxYears = [.init(startYear: 2020, person: "Person A", status: "paid", note: "Filed", foreignTaxInPence: true),
                         .init(startYear: 2020, person: "Person B", status: nil, note: "No return", foreignTaxInPence: nil)]
        extra(&plan)
        return plan
    }

    private func apply(_ plan: TaxDataPlan.Plan) throws -> TaxDataPlan.Outcome {
        try db.write { db in try TaxDataPlan.apply(db: db, plan: plan) }
    }

    private func refusal(_ plan: TaxDataPlan.Plan, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        do {
            _ = try apply(plan)
            XCTFail("Expected a refusal", file: file, line: line)
        } catch TaxDataPlan.PlanError.refused(let problems) {
            return problems
        } catch {
            XCTFail("Unexpected \(error)", file: file, line: line)
        }
        return []
    }

    func testThePlanSetsAYearUpThenIsIdempotent() throws {
        let first = try apply(plan())
        XCTAssertEqual(first.count(.added, in: "Not claimed"), 2)
        XCTAssertEqual(first.count(.added, in: "Splits"), 2)
        XCTAssertEqual(first.count(.added, in: "Employments"), 1)
        XCTAssertEqual(first.count(.added, in: "HMRC payments"), 1)
        XCTAssertEqual(first.count(.added, in: "Tax years"), 2)
        try db.read { db in
            XCTAssertTrue(try TaxNotClaimedSources.isMarked(db: db, startYear: 2021, reference: .transaction(id("fee"))))
            let item = try XCTUnwrap(try TaxManualItems.items(db: db, startYear: 2020, personId: id("A")).first)
            XCTAssertTrue(try TaxNotClaimedSources.isMarked(db: db, startYear: 2020, reference: .manualItem(item.id!)))
            XCTAssertEqual(try TaxSplits.share(db: db, startYear: 2020, personId: id("B"), propertyId: id("property"), expenseType: .rentalIncome)
                .shareBasisPoints, 0)
            let job = try XCTUnwrap(try Employments.employments(db: db, startYear: 2020, personId: id("A")).first)
            XCTAssertEqual(job.payeReference, "123/AB456")
            XCTAssertEqual(try Employments.effectiveIncome(db: db, employmentId: job.id!)?.taxDeductedMinorUnits, 900_000)
            XCTAssertEqual(try Employments.benefits(db: db, employmentId: job.id!).map(\.cashEquivalentMinorUnits), [100_000])
            XCTAssertEqual(try HMRCPayments.payments(db: db, personId: id("A"), startYear: 2020).map(\.amountMinorUnits), [10_025])
            let year = try XCTUnwrap(try TaxYears.year(db: db, startYear: 2020, personId: id("A")))
            XCTAssertEqual(year.status, .paid)
            XCTAssertEqual(year.notes, "Filed")
            XCTAssertTrue(year.foreignTaxInPence)
            let other = try XCTUnwrap(try TaxYears.year(db: db, startYear: 2020, personId: id("B")))
            XCTAssertEqual(other.status, .preparing)
            XCTAssertEqual(other.notes, "No return")
        }
        let accounts = try self.accounts(year: 2020)
        XCTAssertEqual(accounts.line(.accountancy)?.notClaimed.native, 15_000)
        XCTAssertEqual(accounts.totals.expenses.native, 0)
        XCTAssertTrue(TaxDataPlan.report(first).contains("== Not claimed: 2 added, 0 already there =="))

        let second = try apply(plan())
        XCTAssertEqual(second.count(.added), 0)
        XCTAssertEqual(second.count(.unchanged), first.count(.added))
    }

    func testThePlanRefusesContradictionsAndWritesNothing() throws {
        _ = try apply(plan())
        var problems = refusal(plan { $0.splits = [.init(startYear: 2020, person: "Person B", expenseType: nil, percent: 50)] })
        XCTAssertTrue(problems.contains { $0.contains("Splits") && $0.contains("0% stored") }, "\(problems)")
        problems = refusal(plan { $0.employments![0].tax = "9100.00" })
        XCTAssertTrue(problems.contains { $0.contains("other figures") }, "\(problems)")
        problems = refusal(plan { $0.hmrcPayments![0].amount = "100.00" })
        XCTAssertTrue(problems.contains { $0.contains("is recorded for that day") }, "\(problems)")
        problems = refusal(plan { $0.taxYears![0].status = "filed" })
        XCTAssertTrue(problems.contains { $0.contains("is Paid, the plan says Filed") }, "\(problems)")
        problems = refusal(plan { $0.taxYears![1].note = "Another note" })
        XCTAssertTrue(problems.contains { $0.contains("another note") }, "\(problems)")
        problems = refusal(plan { $0.notClaimed = [.init(account: "Bank A", date: "2022-03-15", amount: "180.00", description: nil, startYear: 2021, note: nil)] })
        XCTAssertTrue(problems.contains { $0.contains("0 debits match") }, "\(problems)")
        problems = refusal(plan { $0.notClaimed = [.init(account: "Bank A", date: "2022-08-08", amount: "1000.00", description: nil, startYear: 2021, note: nil)] })
        XCTAssertTrue(problems.contains { $0.contains("notClaimable") }, "\(problems)")
        // A debit of another year.
        problems = refusal(plan { $0.notClaimed = [.init(account: "Bank A", date: "2022-03-14", amount: "180.00", description: nil, startYear: 2022, note: nil)] })
        XCTAssertTrue(problems.contains { $0.contains("notASourceOfTheYear") }, "\(problems)")
        // A manual item to mark, found only under another label: which record is meant isn't guessed.
        problems = refusal(plan { $0.manualItems![0].label = "Accountant (renamed)" })
        XCTAssertTrue(problems.contains { $0.contains("use that label") }, "\(problems)")
        // Nothing of the refused runs was written.
        try db.read { db in
            XCTAssertEqual(try TaxNotClaimed.fetchCount(db), 2)
            XCTAssertEqual(try TaxYearSplit.fetchCount(db), 2)
        }
    }

    func testDecodingKnowsTheYearSetUpKeys() throws {
        let json = """
            {"property": "Property A", "notClaimed": [{"account": "Bank A", "date": "2022-03-14", "amount": "180.00", "startYear": 2021}],
             "splits": [{"startYear": 2020, "person": "Person A", "percent": 100}],
             "taxYears": [{"startYear": 2020, "person": "Person A", "status": "paid", "foreignTaxInPence": true}],
             "manualItems": [{"startYear": 2020, "person": "Person A", "expenseType": "accountancy", "label": "x", "amount": "1.00",
                              "currency": "EUR", "notClaimed": true}]}
            """
        let plan = try TaxDataPlan.decodePlan(Data(json.utf8))
        XCTAssertEqual(plan.taxYears?.first?.foreignTaxInPence, true)
        XCTAssertEqual(plan.manualItems?.first?.notClaimed, true)
        XCTAssertThrowsError(try TaxDataPlan.decodePlan(Data(#"{"property": "P", "notClaimed": [{"acount": "x"}]}"#.utf8))) {
            XCTAssertEqual($0 as? TaxDataPlan.PlanError, .unknownKeys(["notClaimed[0].acount"]))
        }
        let benefit = #"{"property": "P", "employments": [{"startYear": 2020, "person": "A", "employer": "E", "source": "p60", "pay": "1", "tax": "0", "benefits": [{"kind": "medical", "amout": "1"}]}]}"#
        XCTAssertThrowsError(try TaxDataPlan.decodePlan(Data(benefit.utf8))) {
            XCTAssertEqual($0 as? TaxDataPlan.PlanError, .unknownKeys(["employments[0].benefits[0].amout"]))
        }
        XCTAssertEqual(TaxDataPlan.years(self.plan()), [2020, 2021])
        var more = self.plan()
        more.rates = [.init(startYear: 2019, currency: nil, gbpPerUnit: 0.9, note: nil)]
        more.hmrcPayments![0].startYear = 2018
        more.splits![0].startYear = 2017
        XCTAssertEqual(TaxDataPlan.years(more), [2017, 2018, 2019, 2020, 2021])
    }

    // MARK: The tool's guards

    func testTheWriteGuardRefusesTheAppsDataUnlessAllowed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NotClaimedGuard-\(UUID().uuidString)", isDirectory: true)
        let app = folder.appendingPathComponent("Library/Application Support/Budget", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let isAppData: (String) -> Bool = { TaxRegression.isAppDatabase($0, folders: TaxRegression.appDataFolders(home: folder)) }
        let real = app.appendingPathComponent("budget.sqlite").path
        let copy = folder.appendingPathComponent("copy.sqlite").path
        XCTAssertNotNil(TaxDataPlan.writeRefusal(path: real, what: "the database", allowAppData: false, isAppData: isAppData))
        XCTAssertNil(TaxDataPlan.writeRefusal(path: real, what: "the database", allowAppData: true, isAppData: isAppData))
        XCTAssertNil(TaxDataPlan.writeRefusal(path: copy, what: "the database", allowAppData: false, isAppData: isAppData))
        #if os(macOS)
        // The default checks the real home too (getpwuid), whatever HOME says.
        let home = try XCTUnwrap(TaxRegression.realHomeDirectory)
        let realApp = home.appendingPathComponent("Library/Application Support/Budget/budget.sqlite").path
        XCTAssertNotNil(TaxDataPlan.writeRefusal(path: realApp, what: "the database", allowAppData: false))
        #endif
        // On every platform the default refuses the process's own app database.
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let ownApp = support.appendingPathComponent("Budget/budget.sqlite").path
        XCTAssertNotNil(TaxDataPlan.writeRefusal(path: ownApp, what: "the database", allowAppData: false))

        // The app's database must be at this build's version; a copy is migrated by the tool.
        let partial = try DatabaseManager(path: real)
        try partial.migrate(upTo: "createTax")
        XCTAssertTrue(try XCTUnwrap(TaxDataPlan.migrationRefusal(path: real, isAppData: isAppData)).contains("addTaxNotClaimed"))
        let older = try DatabaseManager(path: copy)
        try older.migrate(upTo: "createTax")
        XCTAssertNil(try TaxDataPlan.migrationRefusal(path: copy, isAppData: isAppData))
        try partial.migrate()
        XCTAssertNil(try TaxDataPlan.migrationRefusal(path: real, isAppData: isAppData))
    }

    // MARK: Foreign tax in pence

    func testForeignTaxInPenceKeepsThePenceInTheCalculation() throws {
        let rules = try XCTUnwrap(UKTaxRules.forYear(2020))
        var inputs = SelfAssessment.Inputs(startYear: 2020, employments: [.init(employerName: "Example Ltd", pay: 9_000_000, taxDeducted: 2_500_000)],
                                           properties: [.init(name: "Property A", country: "PT", income: 800_050, expenses: 150_075,
                                                              financeCosts: 120_010, foreignTax: 150_043)])
        XCTAssertEqual(SelfAssessment.calculate(inputs, rules: rules).calculation.foreignTaxCreditRelief, 150_100)
        inputs.foreignTaxInPence = true
        let result = SelfAssessment.calculate(inputs, rules: rules)
        XCTAssertEqual(result.calculation.foreignTaxCreditRelief, 150_043)
        XCTAssertTrue(result.steps.contains { $0.detail.contains("foreign tax paid stays in pounds and pence") })
    }
}
