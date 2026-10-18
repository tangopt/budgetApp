import XCTest
import GRDB
@testable import BudgetCore

/// The one-off tax data plan: categorising debits, the expense type map, receipts, payment
/// owners, filed-return rates and manual items — idempotent, refusing contradictions with
/// nothing written. Synthetic EUR property owned 50/50 by Person A and Person B.
final class TaxDataPlanTests: XCTestCase {
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
            ids["group"] = group.id!
            try Properties.addCategoryGroup(db: db, propertyId: p, categoryGroupId: group.id!)
            for (key, name, type) in [("insurance", "Building insurance", CategoryType.expense), ("contents", "Contents insurance", .expense),
                                      ("ptTax", "PT tax", .expense), ("fees", "Bank fees", .expense), ("rent", "Rental income", .income)] {
                var category = Category(name: name, type: type, groupId: group.id)
                try category.insert(db)
                ids[key] = category.id!
            }
        }
        try debit("contents1", (2021, 12, 2), -1_000, description: "CARD PAYMENT 77777/1")
        try debit("ins1", (2021, 8, 20), -20_000, description: "INSURER 0001")
        try debit("ins0", (2021, 6, 21), -30_000, category: "insurance", description: "SEPADD/INSURER")
        try debit("taxA", (2021, 8, 12), -500_000, category: "ptTax", description: "TAX PAYMENT 900111")
        try debit("taxB", (2021, 8, 12), -500_000, category: "ptTax", description: "TAX PAYMENT 900222")
    }

    @discardableResult
    private func debit(_ key: String, _ day: (Int, Int, Int), _ amount: Int, category: String? = nil, description: String) throws -> Int64 {
        try db.write { db in
            var transaction = Transaction(importBatchId: id("batch"), accountId: id("bank"), date: Self.date(day.0, day.1, day.2),
                                          rawDescription: description, amountMinorUnits: amount, categoryId: category.map(id),
                                          status: category == nil ? .pendingReview : .confirmed,
                                          categorizedBy: category == nil ? .none : .manual, fingerprint: UUID().uuidString)
            try transaction.insert(db)
            ids[key] = transaction.id!
            return transaction.id!
        }
    }

    private func plan(_ extra: (inout TaxDataPlan.Plan) -> Void = { _ in }) -> TaxDataPlan.Plan {
        var plan = TaxDataPlan.Plan(
            property: "Property A",
            categorize: [
                .init(account: "Bank A", date: "2021-12-02", amount: "10.00", description: "77777", category: "Contents insurance"),
                .init(account: "Bank A", date: "2021-08-20", amount: "200.00", description: nil, category: "Building insurance")
            ],
            expenseTypes: ["Building insurance": "insurance", "Contents insurance": "otherExpense", "PT tax": "foreignTax",
                           "Bank fees": "notDeductible", "Rental income": "rentalIncome"],
            policyReceipts: [
                .init(expenseType: nil, date: "2021-06-21", debitDate: nil, amount: "300.00", currency: nil, policyYear: 2021, instalment: 2,
                      of: 2, coverFrom: "2021-06-01", coverTo: "2021-12-01", note: nil),
                .init(expenseType: nil, date: "2021-08-20", debitDate: nil, amount: "200.00", currency: nil, policyYear: 2021, instalment: 3,
                      of: 3, coverFrom: "2021-08-01", coverTo: "2021-11-01", note: nil),
                // Before the bank history: kept on its own.
                .init(expenseType: "serviceCharge", date: "2020-03-03", debitDate: nil, amount: "400.00", currency: nil, policyYear: nil,
                      instalment: nil, of: nil, coverFrom: "2020-01-01", coverTo: "2020-07-01", note: "Synthetic quotas")
            ],
            transactionOwners: [
                .init(person: "Person A", reference: "900111", date: "2021-08-12", amount: "5000.00", note: nil),
                .init(person: "Person B", reference: "900222", date: nil, amount: nil, note: nil)
            ],
            rates: [.init(startYear: 2021, currency: "EUR", gbpPerUnit: 0.8, note: "Implied by the return")],
            manualItems: [
                .init(startYear: 2021, person: "Person A", expenseType: "accountancy", label: "UK accountant", amount: "250.00", currency: "GBP",
                      date: nil, wholeProperty: nil, note: nil),
                .init(startYear: 2021, person: "Person B", expenseType: "accountancy", label: "UK accountant", amount: "250.00", currency: "GBP",
                      date: nil, wholeProperty: nil, note: nil)
            ],
            summaryYears: [2021])
        extra(&plan)
        return plan
    }

    private func apply(_ plan: TaxDataPlan.Plan, fetched: TaxDataPlan.FetchedRates = .init()) throws -> TaxDataPlan.Outcome {
        try db.write { db in try TaxDataPlan.apply(db: db, plan: plan, fetched: fetched) }
    }

    private func refusal(_ plan: TaxDataPlan.Plan, fetched: TaxDataPlan.FetchedRates = .init(),
                         file: StaticString = #filePath, line: UInt = #line) -> [String] {
        do {
            _ = try apply(plan, fetched: fetched)
            XCTFail("Expected a refusal", file: file, line: line)
        } catch TaxDataPlan.PlanError.refused(let problems) {
            return problems
        } catch {
            XCTFail("Unexpected \(error)", file: file, line: line)
        }
        return []
    }

    private func transaction(_ key: String) throws -> Transaction { try db.read { db in try Transaction.fetchOne(db, key: id(key))! } }

    // MARK: Applying

    func testAppliesEverythingThenIsIdempotent() throws {
        let first = try apply(plan())
        XCTAssertEqual(first.count(.added, in: "Categorised debits"), 2)
        XCTAssertEqual(first.count(.added, in: "Expense types"), 5)
        XCTAssertEqual(first.count(.added, in: "Policy receipts"), 3)
        XCTAssertEqual(first.count(.added, in: "Payment owners"), 2)
        XCTAssertEqual(first.count(.added, in: "HMRC rates"), 1)
        XCTAssertEqual(first.count(.added, in: "Manual items"), 2)
        XCTAssertEqual(first.count(.unchanged), 0)

        let contents = try transaction("contents1")
        XCTAssertEqual(contents.categoryId, id("contents"))
        XCTAssertEqual(contents.status, .confirmed)
        XCTAssertEqual(contents.categorizedBy, .manual)
        try db.read { db in
            let receipts = try TaxPolicyReceipts.receipts(db: db, propertyId: id("property"))
            XCTAssertEqual(receipts.map(\.transactionId), [nil, id("ins0"), id("ins1")])
            XCTAssertEqual(receipts[0].expenseType, .serviceCharge)
            XCTAssertEqual(try TaxTransactionOwners.all(db: db), [id("taxA"): id("A"), id("taxB"): id("B")])
            let rate = try HMRCRates.rate(db: db, startYear: 2021, currencyCode: "EUR")
            XCTAssertEqual(rate?.gbpPerUnit, 0.8)
            XCTAssertEqual(rate?.source, .filedReturn)
            XCTAssertEqual(try TaxManualItems.items(db: db, startYear: 2021, personId: id("A")).map(\.amountMinorUnits), [25_000])
            XCTAssertEqual(try TaxExpenseTypeMapping.fetchCount(db), 5)
            // Tax year statuses are never touched.
            XCTAssertEqual(try TaxYear.fetchCount(db), 0)
        }

        let second = try apply(plan())
        XCTAssertEqual(second.count(.added), 0)
        XCTAssertEqual(second.count(.unchanged), first.count(.added))
        try db.read { db in
            XCTAssertEqual(try TaxPolicyReceipt.fetchCount(db), 3)
            XCTAssertEqual(try TaxManualItem.fetchCount(db), 2)
            XCTAssertEqual(try TaxTransactionOwner.fetchCount(db), 2)
        }
    }

    func testTheReportAndFiguresNameEachOwner() throws {
        let outcome = try apply(plan())
        let report = TaxDataPlan.report(outcome)
        XCTAssertTrue(report.contains("== Categorised debits: 2 added, 0 already there =="))
        XCTAssertTrue(report.contains("+ 2021-12-02 CARD PAYMENT 77777/1 €10.00 → Contents insurance"))
        let figures = try db.read { db in try TaxDataPlan.figures(db: db, propertyId: id("property"), years: [2021]) }
        XCTAssertTrue(figures.contains("== 2021/22 · Person A =="))
        XCTAssertTrue(figures.contains("== 2021/22 · Person B =="))
        XCTAssertTrue(figures.contains("Rate: £0.8 per EUR (filedReturn)"))
        XCTAssertTrue(figures.contains("Accountancy fee"))
    }

    // MARK: Refusals (nothing written)

    func testRefusesADebitAlreadyCategorisedDifferentlyAndWritesNothing() throws {
        try db.write { db in
            var t = try Transaction.fetchOne(db, key: id("ins1"))!
            t.categoryId = id("fees")
            try t.update(db)
        }
        let problems = refusal(plan())
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("already categorised as Bank fees"), problems[0])
        try db.read { db in
            XCTAssertNil(try Transaction.fetchOne(db, key: id("contents1"))!.categoryId)
            XCTAssertEqual(try TaxPolicyReceipt.fetchCount(db), 0)
            XCTAssertEqual(try TaxExpenseTypeMapping.fetchCount(db), 0)
            XCTAssertEqual(try HMRCRate.fetchCount(db), 0)
        }
    }

    func testRefusesUnlessExactlyOneDebitMatches() throws {
        try debit("twin", (2021, 12, 2), -1_000, description: "CARD PAYMENT 77777/2")
        let problems = refusal(plan { $0.categorize![1].date = "2021-08-21" })
        XCTAssertEqual(problems.count, 2)
        XCTAssertTrue(problems.contains { $0.contains("2 debits match 2021-12-02 10.00") })
        XCTAssertTrue(problems.contains { $0.contains("0 debits match 2021-08-21 200.00") })
    }

    func testRefusesAStoredExpenseTypeThatDiffers() throws {
        try db.write { db in try TaxExpenseTypeMap.set(db: db, categoryId: id("fees"), expenseType: .otherExpense) }
        let problems = refusal(plan())
        XCTAssertEqual(problems, ["Expense types: Bank fees is stored as Any other expense, the plan says Not deductible"])
    }

    func testAStoredExpenseTypeThatAgreesIsUnchanged() throws {
        try db.write { db in try TaxExpenseTypeMap.set(db: db, categoryId: id("fees"), expenseType: .notDeductible) }
        let outcome = try apply(plan())
        XCTAssertEqual(outcome.count(.unchanged, in: "Expense types"), 1)
        XCTAssertEqual(outcome.count(.added, in: "Expense types"), 4)
    }

    func testRefusesAPaymentAssignedToSomeoneElseOrOfAnotherAmount() throws {
        try db.write { db in try TaxTransactionOwners.set(db: db, transactionId: id("taxB"), personId: id("A")) }
        let problems = refusal(plan { $0.transactionOwners![0].amount = "4999.99" })
        XCTAssertEqual(problems.count, 2)
        XCTAssertTrue(problems.contains { $0.contains("is not 4999.99") })
        XCTAssertTrue(problems.contains { $0.contains("already assigned to Person A, not Person B") })
    }

    func testRefusesAnAmbiguousDebitForAReceiptAndADifferentExistingReceipt() throws {
        try debit("ins1twin", (2021, 8, 22), -20_000, description: "INSURER 0001")
        var problems = refusal(plan { $0.categorize = [] })
        XCTAssertEqual(problems, ["Policy receipts: 2 debits of 200.00 within a week of 2021-08-20: ambiguous"])

        try db.write { db in try Transaction.deleteOne(db, key: id("ins1twin")) }
        try db.write { db in
            var receipt = TaxPolicyReceipt(propertyId: id("property"), transactionId: id("ins0"), date: Self.date(2021, 6, 21), amountMinorUnits: 30_000,
                                           currency: .eur, policyYear: 2021, instalment: 1, instalmentCount: 2)
            try TaxPolicyReceipts.save(db: db, &receipt)
        }
        problems = refusal(plan())
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("a different receipt is already recorded for 2021-06-21 300.00"), problems[0])
    }

    // MARK: Only when missing

    func testRatesAndManualItemsAlreadyPresentAreLeftAsStored() throws {
        try db.write { db in
            try HMRCRates.set(db: db, startYear: 2021, currencyCode: "EUR", gbpPerUnit: 0.85, source: .manual)
            var mine = TaxManualItem(startYear: 2021, personId: id("A"), propertyId: id("property"), expenseType: .accountancy,
                                     label: "Accountant (UK)", amountMinorUnits: 25_000, currency: .gbp)
            try TaxManualItems.save(db: db, &mine)
            var theirs = TaxManualItem(startYear: 2021, personId: id("B"), propertyId: id("property"), expenseType: .accountancy,
                                       label: "UK accountant", amountMinorUnits: 20_000, currency: .gbp)
            try TaxManualItems.save(db: db, &theirs)
        }
        let outcome = try apply(plan())
        XCTAssertEqual(outcome.count(.kept, in: "HMRC rates"), 1)
        XCTAssertEqual(outcome.count(.kept, in: "Manual items"), 2)
        try db.read { db in
            XCTAssertEqual(try HMRCRates.rate(db: db, startYear: 2021, currencyCode: "EUR")?.gbpPerUnit, 0.85)
            XCTAssertEqual(try TaxManualItem.fetchCount(db), 2)
            XCTAssertEqual(try TaxManualItems.items(db: db, startYear: 2021, personId: id("B")).map(\.amountMinorUnits), [20_000])
        }
    }

    func testCreatesAMissingCategoryOnlyWhenAsked() throws {
        let missing = refusal(plan { $0.categorize![1].category = "Home insurance" })
        XCTAssertTrue(missing.contains { $0.contains("no category Home insurance") })

        let outcome = try apply(plan {
            $0.categorize![1].category = "Home insurance"
            $0.categorize![1].createCategory = true
        })
        XCTAssertEqual(outcome.createdCategories, ["Home insurance"])
        try db.read { db in
            let category = try Category.filter(Column("name") == "Home insurance").fetchOne(db)
            XCTAssertEqual(category?.groupId, id("group"))
            XCTAssertEqual(try Transaction.fetchOne(db, key: id("ins1"))?.categoryId, category?.id)
        }
        // Not in the plan's type map: left to the suggestion, and reported.
        XCTAssertTrue(outcome.changes.contains { $0.kind == .kept && $0.text.hasPrefix("Home insurance: not in the plan") })
    }

    // MARK: Decoding

    func testDecodingRefusesUnknownKeys() throws {
        let json = #"{"property": "P", "rate": [], "manualItems": [{"startYear": 2024, "person": "A", "expenseType": "accountancy", "label": "x", "amount": "1", "currency": "GBP", "whole": true}]}"#
        XCTAssertThrowsError(try TaxDataPlan.decodePlan(Data(json.utf8))) { error in
            XCTAssertEqual(error as? TaxDataPlan.PlanError, .unknownKeys(["rate", "manualItems[0].whole"]))
        }
        let good = #"{"property": "P", "rates": [{"startYear": 2024, "gbpPerUnit": 0.84}], "summaryYears": [2024]}"#
        let plan = try TaxDataPlan.decodePlan(Data(good.utf8))
        XCTAssertEqual(plan.rates?.first?.gbpPerUnit, 0.84)
        XCTAssertNil(plan.categorize)
    }

    func testABadDateIsRefusedNotIgnored() throws {
        let problems = refusal(plan { $0.policyReceipts![0].coverTo = "2021-13-40" })
        XCTAssertEqual(problems, ["Policy receipts: bad date in 2021-06-21 300.00"])
    }

    // MARK: Review fixes

    func testARecordedReceiptOnItsOwnIsLinkedToItsDebitNotDuplicated() throws {
        try db.write { db in
            var receipt = TaxPolicyReceipt(propertyId: id("property"), date: Self.date(2021, 6, 21), amountMinorUnits: 30_000, currency: .eur,
                                           policyYear: 2021, instalment: 2, instalmentCount: 2,
                                           coverStart: Self.date(2021, 6, 1), coverEnd: Self.date(2021, 12, 1))
            try TaxPolicyReceipts.save(db: db, &receipt)
        }
        let outcome = try apply(plan())
        XCTAssertTrue(outcome.changes.contains { $0.text.contains("now linked to its debit") })
        try db.read { db in
            let receipts = try TaxPolicyReceipt.filter(Column("amountMinorUnits") == 30_000).fetchAll(db)
            XCTAssertEqual(receipts.map(\.transactionId), [id("ins0")])
        }
        XCTAssertEqual(try apply(plan()).count(.added, in: "Policy receipts"), 0)
    }

    func testAFiledReturnRateReplacesAnAutomaticallyFetchedOne() throws {
        try db.write { db in
            try HMRCRates.set(db: db, startYear: 2021, currencyCode: "EUR", gbpPerUnit: 0.85, unitsPerPound: 1 / 0.85, source: .hmrcPublished,
                              fetchedAt: Self.date(2022, 4, 10), notes: "\(HMRCRates.autoFetchedNotePrefix): HMRC average for the year to 31 March 2022")
        }
        let outcome = try apply(plan())
        XCTAssertEqual(outcome.count(.added, in: "HMRC rates"), 1)
        XCTAssertTrue(TaxDataPlan.report(outcome).contains("2021/22 EUR £0.8 (filed return) replaces the automatically fetched £0.85"),
                      TaxDataPlan.report(outcome))
        try db.read { db in
            let rate = try XCTUnwrap(try HMRCRates.rate(db: db, startYear: 2021, currencyCode: "EUR"))
            XCTAssertEqual(rate.gbpPerUnit, 0.8)
            XCTAssertEqual(rate.source, .filedReturn)
            XCTAssertNil(rate.fetchedAt)
            XCTAssertFalse(rate.isFetchedAutomatically)
        }
        // Then it is the filed rate, unchanged on a second run.
        XCTAssertEqual(try apply(plan()).count(.unchanged, in: "HMRC rates"), 1)
    }

    func testAFiledReturnRateEqualToTheFetchedOneIsAlreadyThere() throws {
        _ = try db.write { db in
            try HMRCRates.set(db: db, startYear: 2021, currencyCode: "EUR", gbpPerUnit: 0.8, unitsPerPound: 1.25, source: .hmrcPublished,
                              fetchedAt: Self.date(2022, 4, 10), notes: "\(HMRCRates.autoFetchedNotePrefix): HMRC average for the year to 31 March 2022")
        }
        let outcome = try apply(plan())
        XCTAssertEqual(outcome.count(.added, in: "HMRC rates"), 0)
        XCTAssertEqual(outcome.count(.unchanged, in: "HMRC rates"), 1)
        XCTAssertTrue(TaxDataPlan.report(outcome).contains("the same as filed; now marked as the filed return's"), TaxDataPlan.report(outcome))
        // The figure stays; it is the filed return's now, so an automatic fetch won't replace it.
        try db.read { db in
            let rate = try XCTUnwrap(try HMRCRates.rate(db: db, startYear: 2021, currencyCode: "EUR"))
            XCTAssertEqual(rate.gbpPerUnit, 0.8)
            XCTAssertEqual(rate.unitsPerPound, 1.25)
            XCTAssertEqual(rate.source, .filedReturn)
            XCTAssertFalse(rate.isFetchedAutomatically)
        }
        let again = try apply(plan())
        XCTAssertEqual(again.count(.unchanged, in: "HMRC rates"), 1)
        XCTAssertTrue(TaxDataPlan.report(again).contains("already stored (filed return)"), TaxDataPlan.report(again))
    }

    func testAStoredFiledReturnRateThatDiffersIsRefused() throws {
        try db.write { db in try HMRCRates.set(db: db, startYear: 2021, currencyCode: "EUR", gbpPerUnit: 0.85, source: .filedReturn) }
        XCTAssertEqual(refusal(plan()), ["HMRC rates: 2021/22 EUR has the filed-return rate £0.85 stored, the plan says £0.8"])
    }

    func testCategorisesOnlyOnThePropertysAccountsAndOneDebitPerEntry() throws {
        try db.write { db in
            var other = Account(name: "Bank B", currency: .eur, kind: .cash, trackingMode: .imported)
            try other.insert(db)
        }
        var problems = refusal(plan { $0.categorize![0].account = "Bank B" })
        XCTAssertEqual(problems, ["Categorised debits: Bank B is not an account of the property (for 2021-12-02 10.00 (Bank B))"])
        problems = refusal(plan { $0.categorize!.append($0.categorize![0]) })
        XCTAssertEqual(problems, ["Categorised debits: 2021-12-02 CARD PAYMENT 77777/1 €10.00 is matched by more than one entry"])
    }

    func testAPaymentReferenceIsMatchedLiterallyOnThePropertysAccounts() throws {
        let problems = refusal(plan { $0.transactionOwners![1].reference = "9002_2" })
        XCTAssertEqual(problems, ["Payment owners: 0 transactions match 9002_2, expected exactly one"])
    }

    // MARK: Attribution rules

    private func ruleOnly(_ rules: [TaxDataPlan.Plan.AttributionRule]) -> TaxDataPlan.Plan {
        TaxDataPlan.Plan(property: "Property A", attributionRules: rules)
    }

    private static let previousYear = TaxDataPlan.Plan.AttributionRule(expenseType: "foreignTax", rule: "previousCalendarYear",
                                                                        startYear: nil, coverMonths: nil)

    func testAnAttributionRuleReplacesTheSeededDefaultThenIsUnchanged() throws {
        try db.write { db in _ = try TaxAttributionRules.seedDefaults(db: db) }
        let first = try apply(ruleOnly([Self.previousYear]))
        XCTAssertEqual(first.changes, [TaxDataPlan.Change(section: "Attribution rules", kind: .added,
            text: "Foreign tax paid (PT IRS), every year: Previous calendar year (replaces the seeded default, Calendar year, time-apportioned)")])
        try db.read { db in
            let rule = try TaxAttributionRules.effective(db: db, expenseType: .foreignTax, startYear: 2025)
            XCTAssertEqual(rule.rule, .previousCalendarYear)
            XCTAssertNil(rule.startYear)
            XCTAssertEqual(rule.notes, "Tax data plan")
        }
        let second = try apply(ruleOnly([Self.previousYear]))
        XCTAssertEqual(second.count(.unchanged, in: "Attribution rules"), 1)
        XCTAssertEqual(second.count(.added), 0)
    }

    func testAnAttributionRuleIsAddedWhereNoneIsStoredAndYearsWithTheirOwnRuleAreReported() throws {
        try db.write { db in
            try TaxAttributionRules.set(db: db, expenseType: .foreignTax, startYear: 2023, rule: .apportionCalendarYear, notes: "Chosen")
        }
        let outcome = try apply(ruleOnly([Self.previousYear,
                                          .init(expenseType: "insurance", rule: "apportionByCover", startYear: 2024, coverMonths: 6)]))
        XCTAssertEqual(outcome.changes.map(\.text), [
            "Foreign tax paid (PT IRS), every year: Previous calendar year (was the built-in default, Calendar year, time-apportioned)",
            "Foreign tax paid (PT IRS), 2023/24: its own rule, Calendar year, time-apportioned, still applies",
            "Insurance (building insurance), 2024/25: Apportioned by months of cover, 6 months of cover assumed (was the built-in default, Apportioned by months of cover)"
        ])
        XCTAssertEqual(outcome.changes.map(\.kind), [.added, .kept, .added])
        try db.read { db in
            XCTAssertEqual(try TaxAttributionRules.effective(db: db, expenseType: .insurance, startYear: 2024).defaultCoverMonths, 6)
            XCTAssertEqual(try TaxAttributionRules.effective(db: db, expenseType: .foreignTax, startYear: 2023).rule, .apportionCalendarYear)
        }
    }

    func testAnAttributionRuleContradictingTheUsersIsRefusedUnlessIdentical() throws {
        try db.write { db in try TaxAttributionRules.set(db: db, expenseType: .foreignTax, startYear: nil, rule: .apportionCalendarYear) }
        XCTAssertEqual(refusal(ruleOnly([Self.previousYear])),
                       ["Attribution rules: Foreign tax paid (PT IRS), every year is set to Calendar year, time-apportioned, the plan says Previous calendar year"])
        try db.write { db in try TaxAttributionRules.set(db: db, expenseType: .foreignTax, startYear: nil, rule: .previousCalendarYear) }
        XCTAssertEqual(try apply(ruleOnly([Self.previousYear])).count(.unchanged), 1)

        let problems = refusal(ruleOnly([.init(expenseType: "foreignTax", rule: "byWhim", startYear: nil, coverMonths: nil),
                                         .init(expenseType: "pension", rule: "byDate", startYear: nil, coverMonths: nil),
                                         .init(expenseType: "insurance", rule: "apportionByCover", startYear: nil, coverMonths: 0),
                                         Self.previousYear, Self.previousYear]))
        XCTAssertEqual(problems, ["Attribution rules: unknown rule byWhim for Foreign tax paid (PT IRS)",
                                  "Attribution rules: unknown type pension",
                                  "Attribution rules: Insurance (building insurance), every year: cover months must be 1 or more",
                                  "Attribution rules: Foreign tax paid (PT IRS), every year is in the plan more than once"])
    }

    // MARK: HMRC rates fetched

    private func fetchOnly(_ years: [Int], _ currencies: [String]? = nil) -> TaxDataPlan.Plan {
        TaxDataPlan.Plan(property: "Property A", fetchHMRCRates: .init(years: years, currencies: currencies))
    }

    func testFetchesOnlyTheMissingRatesAndReportsTheSource() async throws {
        try await db.write { db in try HMRCRates.set(db: db, startYear: 2021, currencyCode: "EUR", gbpPerUnit: 0.8, source: .filedReturn) }
        let plan = fetchOnly([2021, 2022, 2022])
        let years = try await db.read { db in try TaxDataPlan.yearsToFetch(db: db, plan: plan) }
        XCTAssertEqual(years, [2022])
        let fetcher = StubHMRCRateFetcher()
        fetcher.files[2022] = [HMRCPublishedRate(currencyCode: "EUR", unitsPerPound: 1.25)]
        let fetched = await TaxDataPlan.fetchRates(years: years, fetcher: fetcher)
        XCTAssertEqual(fetcher.requested, [2022])
        let now = Self.date(2026, 10, 18)
        let outcome = try await db.write { db in try TaxDataPlan.apply(db: db, plan: plan, fetched: fetched, now: now) }
        XCTAssertEqual(outcome.changes.map(\.text), [
            "2021/22 EUR: already stored, €1 = £0.8000 (1.2500 per £1) (filedReturn) — not fetched",
            "2022/23 EUR: €1 = £0.8000 (1.2500 per £1), HMRC average for the year to 31 March 2023 — https://www.trade-tariff.service.gov.uk/api/v2/exchange_rates/files/average_csv_2023-3.csv"
        ])
        XCTAssertEqual(outcome.changes.map(\.kind), [.unchanged, .added])
        try await db.read { db in
            let rate = try HMRCRates.rate(db: db, startYear: 2022, currencyCode: "EUR")
            XCTAssertEqual(rate?.source, .hmrcPublished)
            XCTAssertEqual(rate?.unitsPerPound, 1.25)
            XCTAssertEqual(rate?.fetchedAt, now)
            XCTAssertEqual(rate?.isFetchedAutomatically, true)
            XCTAssertTrue(rate?.notes?.contains("average_csv_2023-3.csv") ?? false)
        }
        // Stored now: nothing to fetch, unchanged.
        let none = try await db.read { db in try TaxDataPlan.yearsToFetch(db: db, plan: plan) }
        XCTAssertEqual(none, [])
        let figures = try await db.read { db in try TaxDataPlan.figures(db: db, propertyId: self.id("property"), years: [2022]) }
        XCTAssertTrue(figures.contains("Rate: £0.8000 per EUR (hmrcPublished) = 1.25 per £1"), figures)
        let again = try await db.write { db in try TaxDataPlan.apply(db: db, plan: plan) }
        XCTAssertEqual(again.count(.unchanged), 2)
        XCTAssertTrue(TaxDataPlan.report(again).contains("== HMRC rates fetched: 0 added, 2 already there =="))
    }

    func testARateThatCouldNotBeFetchedIsRefused() throws {
        let unreadable: [HMRCPublishedRate]? = nil
        let offline = TaxDataPlan.FetchedRates(byYear: [2022: unreadable])
        var problems = refusal(fetchOnly([2022]), fetched: offline)
        XCTAssertEqual(problems, ["HMRC rates fetched: couldn't fetch HMRC's average rates for 2022/23 from https://www.trade-tariff.service.gov.uk/api/v2/exchange_rates/files/average_csv_2023-3.csv (offline, or not published yet)"])
        let noEuro = TaxDataPlan.FetchedRates(byYear: [2022: [HMRCPublishedRate(currencyCode: "USD", unitsPerPound: 1.3)]])
        problems = refusal(fetchOnly([2022], ["EUR", "EURO"]), fetched: noEuro)
        XCTAssertEqual(problems, ["HMRC rates fetched: bad currency EURO",
                                  "HMRC rates fetched: HMRC's average rates for 2022/23 (https://www.trade-tariff.service.gov.uk/api/v2/exchange_rates/files/average_csv_2023-3.csv) have no EUR rate"])
        try db.read { db in XCTAssertEqual(try HMRCRate.fetchCount(db), 0) }
    }

    func testDecodingKnowsTheRuleAndFetchKeys() throws {
        let bad = #"{"property": "P", "attributionRules": [{"expenseType": "foreignTax", "rule": "previousCalendarYear", "year": 2024}], "fetchHMRCRates": {"years": [2025], "currency": "EUR"}}"#
        XCTAssertThrowsError(try TaxDataPlan.decodePlan(Data(bad.utf8))) { error in
            XCTAssertEqual(error as? TaxDataPlan.PlanError, .unknownKeys(["attributionRules[0].year", "fetchHMRCRates.currency"]))
        }
        let good = #"{"property": "P", "attributionRules": [{"expenseType": "foreignTax", "rule": "previousCalendarYear"}], "fetchHMRCRates": {"years": [2025], "currencies": ["EUR"]}}"#
        let plan = try TaxDataPlan.decodePlan(Data(good.utf8))
        XCTAssertEqual(plan.attributionRules, [Self.previousYear])
        XCTAssertEqual(plan.fetchHMRCRates, .init(years: [2025], currencies: ["EUR"]))
    }
}
