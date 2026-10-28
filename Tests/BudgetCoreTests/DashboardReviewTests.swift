import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// The Mac Dashboard's review read model (step 12 Task 1): synthetic data only. One EUR property with a tenancy
/// "Room A" from January 2025 at €1,000 a month; today is injected per test.
final class DashboardReviewTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var ids: [String: Int64] = [:]
    private static let tenantName = "Synthetic Tenant Person"

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func pounds(_ value: Int) -> Int { value * 100 }

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
    }

    // MARK: Fixture

    /// The property, its bank account and categories, and Room A.
    private func makeProperty() throws {
        try db.write { db in
            var property = Property(name: "Property A", country: "PT")
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
            var utilities = Category(name: "Utilities", type: .expense, groupId: group.id)
            try utilities.insert(db)
            var rent = Category(name: "Rental income", type: .income, groupId: group.id)
            try rent.insert(db)
            var repairs = Category(name: "Repairs", type: .expense, groupId: group.id)
            try repairs.insert(db)
            ids["utilities"] = utilities.id!
            ids["rent"] = rent.id!
            ids["repairs"] = repairs.id!
            try TaxExpenseTypeMap.seed(db: db, propertyId: p)
        }
        try tenancy("tenancy", "Room A", from: Self.date(2025, 1, 1))
    }

    private func tenancy(_ key: String, _ label: String, from start: Date) throws {
        try db.write { db in
            var tenancy = Tenancy(propertyId: ids["property"]!, referenceLabel: label, contractNumber: label, tenantName: Self.tenantName,
                                  startDate: start)
            try Tenancies.save(db: db, &tenancy)
            try Tenancies.setRent(db: db, tenancyId: tenancy.id!, from: start, monthlyAmountMinorUnits: 100_000)
            ids[key] = tenancy.id!
        }
    }

    @discardableResult
    private func movement(_ date: Date, _ amount: Int, _ text: String = "MOVEMENT", category: String? = nil) throws -> Int64 {
        try db.write { db in
            var t = Transaction(importBatchId: ids["batch"]!, accountId: ids["bank"]!, date: date, rawDescription: text, amountMinorUnits: amount,
                                categoryId: category.flatMap { ids[$0] }, status: .confirmed, categorizedBy: .manual, fingerprint: UUID().uuidString)
            try t.insert(db)
            return t.id!
        }
    }

    /// A rent receipt for `tenancy`'s month, paid by `transactionId`.
    private func linkRent(_ tenancy: String, month: Date, transactionId: Int64) throws {
        try db.write { db in
            let end = MonthRange.calendar.date(byAdding: .day, value: -1, to: MonthRange.calendar.date(byAdding: .month, value: 1, to: month)!)!
            var receipt = RentReceipt(tenancyId: ids[tenancy]!, receiptNumber: "R-\(tenancy)-\(month.timeIntervalSince1970)", periodStart: month,
                                      periodEnd: end, receiptDate: month, amountMinorUnits: 100_000)
            try RentReceipts.save(db: db, &receipt)
            _ = try RentReceiptMatching.link(db: db, receiptId: receipt.id!, transactionId: transactionId, rentMinorUnits: 100_000)
        }
    }

    @discardableResult
    private func person(_ name: String) throws -> Int64 {
        try db.write { db in
            var person = Person(name: name, shortName: String(name.prefix(1)))
            try People.save(db: db, &person)
            return person.id!
        }
    }

    /// An employment in 2025/26 paying £60,000 with £9,000 deducted: £2,432 to pay through Self Assessment, and
    /// payments on account of £1,216 for 2026/27.
    private func employed(_ personId: Int64) throws {
        try db.write { db in
            var employment = Employment(startYear: 2025, personId: personId, employerName: "Example Ltd", payeReference: "123/AB456")
            try Employments.save(db: db, &employment, documents: EvidenceLinkChanges())
            var income = EmploymentIncome(employmentId: employment.id!, source: .p60, payMinorUnits: pounds(60_000),
                                          taxDeductedMinorUnits: pounds(9_000))
            try Employments.save(db: db, &income, documents: EvidenceLinkChanges())
        }
    }

    private func waitingImport() throws {
        try db.write { db in
            let sha = String(repeating: "c", count: 64)
            var file = ImportWaitingFile(sha256: sha, originalFileName: "statement.pdf", byteCount: 10, storedRelativePath: "\(sha)/statement.pdf",
                                         text: nil, textStatus: .unknown, reason: "Left out by you", recognisedAs: "Bank statement",
                                         keptAt: Self.date(2026, 10, 1))
            try file.insert(db)
        }
    }

    @discardableResult
    private func requirement(_ name: String, category: String) throws -> EvidenceRequirement {
        try db.write { db in
            var r = EvidenceRequirement(name: name, scope: .transactionsInCategory(categoryId: ids[category]!), kinds: [.repairInvoice],
                                        direction: .outflows)
            try EvidenceRequirements.save(db: db, &r)
            return r
        }
    }

    @discardableResult
    private func document(date: Date, amount: Int) throws -> Int64 {
        try db.write { db in
            let sha = UUID().uuidString
            var document = EvidenceDocument(sha256: sha, storedRelativePath: "x/\(sha).pdf", originalFileName: "\(sha).pdf", byteCount: 1,
                                            kind: .utilityInvoice, docDate: date, amountMinorUnits: amount, currency: .eur, addedAt: date)
            try document.insert(db)
            return document.id!
        }
    }

    private func mortgage(owed: Int, terms: ((Int64) -> PropertyMortgageTerms)? = nil) throws {
        try db.write { db in
            var loan = Account(name: "Loan A", currency: .eur, kind: .credit, trackingMode: .manual)
            try loan.insert(db)
            try Properties.setAccount(db: db, propertyId: ids["property"]!, accountId: loan.id!, role: .mortgage)
            var snapshot = BalanceSnapshot(accountId: loan.id!, date: Self.date(2026, 9, 30),
                                           balanceMinorUnits: NetWorthCalculator.signedSnapshotBalance(enteredMinorUnits: owed, accountKind: .credit),
                                           note: nil)
            try snapshot.insert(db)
            if let terms { try MortgageTerms.save(db: db, terms(ids["property"]!)) }
        }
    }

    /// In a read transaction: a write would throw.
    private func load(_ today: Date, lastVisit: Date? = nil, viewer: AccessActor? = nil) throws -> DashboardReview {
        try db.read { db in try DashboardReview.load(db: db, today: today, lastVisit: lastVisit, viewer: viewer) }
    }

    // MARK: Sections present or not

    func testNoPropertyHouseholdHasNoPropertyOrMortgageSection() throws {
        let personId = try person("Person A")
        try db.write { db in
            var year = TaxYear(startYear: 2026, personId: personId)
            try year.insert(db)
        }
        let review = try load(Self.date(2026, 10, 20))
        XCTAssertNil(review.property)
        XCTAssertNil(review.mortgages)
        let tax = try XCTUnwrap(review.tax)
        XCTAssertEqual(tax.year, UKTaxYear(startYear: 2026))
        XCTAssertEqual(tax.people.map(\.name), ["Person A"])
        XCTAssertEqual(tax.people.first?.status, .preparing)
        XCTAssertNotNil(review.evidence)
        XCTAssertEqual(review.importsWaiting, 0)

        // A property without a tenancy or a mortgage: still no card.
        try db.write { db in
            var property = Property(name: "Property B", country: "PT")
            try Properties.save(db: db, &property)
        }
        let withProperty = try load(Self.date(2026, 10, 20))
        XCTAssertNil(withProperty.property)
        XCTAssertNil(withProperty.mortgages)
    }

    func testViewerWithoutAccessSeesNoSections() throws {
        try makeProperty()
        try mortgage(owed: 15_000_000)
        let personId = try person("Person A")
        try employed(personId)
        try waitingImport()
        let (admin, member) = try db.write { db -> (AccessActor, AccessActor) in
            var adminPerson = Person(name: "Synthetic Admin")
            try People.save(db: db, &adminPerson)
            var adminUser = AppUser(personId: adminPerson.id!, displayName: "Admin", isAdmin: true, createdAt: Self.date(2026, 10, 1))
            try adminUser.insert(db)
            var memberPerson = Person(name: "Synthetic Member")
            try People.save(db: db, &memberPerson)
            var memberUser = AppUser(personId: memberPerson.id!, displayName: "Member", isAdmin: false, createdAt: Self.date(2026, 10, 1))
            try memberUser.insert(db)
            return (try AccessActor.load(appUserId: adminUser.id!, db: db), try AccessActor.load(appUserId: memberUser.id!, db: db))
        }
        let today = Self.date(2026, 10, 20)
        let full = try load(today, viewer: admin)
        XCTAssertNotNil(full.tax)
        XCTAssertNotNil(full.property)
        XCTAssertNotNil(full.evidence)
        XCTAssertNotNil(full.mortgages)
        XCTAssertEqual(full, try load(today))

        try db.write { db in
            var areas: [AccessArea] = [.property, .documents]
            for personId in try Int64.fetchAll(db, sql: "SELECT id FROM person") {
                areas.append(.tax(personUuid: try SyncRecordStore.uuid(for: "person", localId: personId, db: db)))
            }
            for area in areas {
                try db.execute(sql: """
                    INSERT INTO memberPermission(appUserId, area, level) VALUES (?, ?, ?)
                    ON CONFLICT(appUserId, area) DO UPDATE SET level = excluded.level
                    """, arguments: [member.appUserId, area.storageKey, PermissionLevel.none.rawValue])
            }
        }
        let hidden = try load(today, viewer: member)
        XCTAssertNil(hidden.tax)
        XCTAssertNil(hidden.property)
        XCTAssertNil(hidden.evidence)
        XCTAssertNil(hidden.mortgages)
        XCTAssertEqual(hidden.importsWaiting, 1)
        XCTAssertEqual(hidden.attention.map(\.kind), [.importsWaiting])
    }

    // MARK: Tax

    func testMissingRulesGivesUnavailableNotZero() throws {
        let personId = try person("Person A")
        try db.write { db in
            var year = TaxYear(startYear: 2028, personId: personId)
            try year.insert(db)
        }
        let review = try load(Self.date(2028, 5, 1))
        let line = try XCTUnwrap(review.tax?.people.first)
        XCTAssertNil(line.estimateMinorUnits)
        let expected = try db.read { db in SelfAssessmentOverview.selfAssessment(db: db, startYear: 2028, personId: personId).1 }
        XCTAssertEqual(line.unavailableReason, expected)
        XCTAssertEqual(line.unavailableReason, "The UK tax rules for 2028/29 aren't in the app yet.")
        XCTAssertNil(review.tax?.nextPaymentOnAccount)
    }

    func testEstimateSignAndNextPayment() throws {
        let personId = try person("Person A")
        try employed(personId)

        // During 2025/26: its estimate, and the first payment on account for 2026/27 next.
        let during = try load(Self.date(2026, 3, 1))
        let result = try XCTUnwrap(try db.read { db in SelfAssessmentOverview.selfAssessment(db: db, startYear: 2025, personId: personId).0 })
        let line = try XCTUnwrap(during.tax?.people.first)
        XCTAssertEqual(line.estimateMinorUnits, result.calculation.balancingPayment)
        XCTAssertEqual(line.estimateMinorUnits, pounds(2_432))
        XCTAssertNil(line.unavailableReason)
        XCTAssertEqual(result.calculation.nextPaymentOnAccount, pounds(1_216))
        XCTAssertEqual(during.tax?.nextPaymentOnAccount,
                       .init(date: UKTaxYear(startYear: 2025).deadlines.onlineReturnAndBalancingPayment, amountMinorUnits: pounds(1_216),
                             label: "1st payment on account for 2026/27"))

        // In 2026/27 (no income): nothing due; the second payment on account from 2025/26 is next.
        let after = try load(Self.date(2027, 3, 1))
        XCTAssertEqual(after.tax?.year, UKTaxYear(startYear: 2026))
        XCTAssertEqual(after.tax?.people.first?.estimateMinorUnits, 0)
        XCTAssertEqual(after.tax?.nextPaymentOnAccount,
                       .init(date: UKTaxYear(startYear: 2025).deadlines.secondPaymentOnAccount, amountMinorUnits: pounds(1_216),
                             label: "2nd payment on account for 2026/27"))

        // A first payment on account already recorded with HMRC comes off; the second is still due in full.
        try db.write { db in
            var paid = HMRCPayment(personId: personId, startYear: 2026, date: Self.date(2026, 1, 20), amountMinorUnits: pounds(1_216), kind: .firstPaymentOnAccount)
            try paid.insert(db)
        }
        XCTAssertEqual(try load(Self.date(2026, 3, 1)).tax?.nextPaymentOnAccount,
                       .init(date: UKTaxYear(startYear: 2025).deadlines.secondPaymentOnAccount, amountMinorUnits: pounds(1_216),
                             label: "2nd payment on account for 2026/27"))
        try db.write { db in try db.execute(sql: "DELETE FROM hmrcPayment") }

        // After the last deadline: none.
        XCTAssertNil(try load(Self.date(2027, 8, 15)).tax?.nextPaymentOnAccount)

        // A refund is negative.
        try db.write { db in try db.execute(sql: "UPDATE employmentIncome SET taxDeductedMinorUnits = ?", arguments: [pounds(12_000)]) }
        XCTAssertEqual(try load(Self.date(2026, 3, 1)).tax?.people.first?.estimateMinorUnits, -pounds(568))
    }

    // MARK: Property

    func testChecklistProgressSkipsNotApplicable() throws {
        try makeProperty()
        try tenancy("roomB", "Room B", from: Self.date(2026, 10, 5))
        try db.write { db in
            var provider = UtilityProvider(propertyId: ids["property"]!, name: "Example Power", kind: .electricity,
                                           bankDescriptionPattern: "EXAMPLE POWER")
            try Recharges.saveProvider(db: db, &provider)
            var statement = RechargeStatement(tenancyId: ids["roomB"]!, month: Self.date(2026, 10, 1), totalMinorUnits: 4_000, status: .sent,
                                              sentAt: Self.date(2026, 10, 18))
            try statement.insert(db)
        }
        // October's power bill paid with no invoice yet: bills in to do, charges waiting; the statement sent.
        try movement(Self.date(2026, 10, 12), -5_000, "EXAMPLE POWER", category: "utilities")
        let today = Self.date(2026, 10, 20)
        let checklist = try db.read { db in try ThisMonthChecklist.build(db: db, tenancyId: ids["roomB"]!, today: today, trayCount: 0) }
        XCTAssertEqual(checklist.steps.map(\.state), [.notApplicable, .needsYou, .waiting, .done])
        let row = try XCTUnwrap(try load(today).property?.first { $0.tenancyId == ids["roomB"] })
        XCTAssertEqual(row.stepsDone, 1)
        XCTAssertEqual(row.stepsTotal, 3)
        XCTAssertEqual(row.statementStatus, "Sent")
    }

    func testTwoTenanciesTwoRows() throws {
        try makeProperty()
        try tenancy("roomB", "Room B", from: Self.date(2025, 1, 1))
        try db.write { db in
            var draft = RechargeStatement(tenancyId: ids["tenancy"]!, month: Self.date(2026, 10, 1), totalMinorUnits: 4_000, status: .draft)
            try draft.insert(db)
        }
        let review = try load(Self.date(2026, 10, 20))
        let rows = try XCTUnwrap(review.property)
        XCTAssertEqual(rows.map(\.tenancyName), ["Room A", "Room B"])
        XCTAssertEqual(rows.map(\.statementStatus), ["Drafted", "Not applicable"])
        let texts = rows.flatMap { [$0.tenancyName, $0.statementStatus] } + review.attention.map(\.text)
        XCTAssertFalse(texts.contains { $0.contains(Self.tenantName) }, "\(texts)")
        XCTAssertEqual(review.attention.first { $0.kind == .rentLate }?.text, "Rent not received for Room A, Room B")
    }

    func testRentLateAfterDueDayWithoutCredit() throws {
        try makeProperty()
        func rent(_ today: Date, _ key: String = "tenancy") throws -> DashboardReview.PropertyRow.Rent? {
            try load(today).property?.first { $0.tenancyId == ids[key] }?.rent
        }
        // Due on the 1st (the day it started); late only after the 10-day matching window, as the iPhone reads it.
        XCTAssertEqual(try rent(Self.date(2026, 10, 12)), .late)
        XCTAssertEqual(try rent(Self.date(2026, 10, 11)), .notDueYet)
        XCTAssertEqual(try rent(Self.date(2026, 10, 1)), .notDueYet)

        // The property's only tenancy: a rent credit in the month's cash flow counts.
        let credit = try movement(Self.date(2026, 10, 3), 100_000, "TRANSFER FROM TENANT", category: "rent")
        XCTAssertEqual(try rent(Self.date(2026, 10, 10)), .received)

        // Two tenancies: only a credit linked to the tenancy's receipt counts; Room B is due on the 15th.
        try tenancy("roomB", "Room B", from: Self.date(2025, 1, 15))
        XCTAssertEqual(try rent(Self.date(2026, 10, 12)), .late)
        XCTAssertEqual(try rent(Self.date(2026, 10, 12), "roomB"), .notDueYet)
        XCTAssertEqual(try rent(Self.date(2026, 10, 26), "roomB"), .late)
        try linkRent("tenancy", month: Self.date(2026, 10, 1), transactionId: credit)
        XCTAssertEqual(try rent(Self.date(2026, 10, 10)), .received)

        // Last month's linked credit came on the 3rd: next month it's due on the 3rd.
        XCTAssertEqual(try rent(Self.date(2026, 11, 2)), .notDueYet)
        XCTAssertEqual(try rent(Self.date(2026, 11, 4)), .notDueYet)
        XCTAssertEqual(try rent(Self.date(2026, 11, 14)), .late)

        // Ended before its rent day: not applicable.
        try db.write { db in try db.execute(sql: "UPDATE tenancy SET endDate = ? WHERE id = ?", arguments: [Self.date(2026, 11, 1), ids["roomB"]!]) }
        XCTAssertEqual(try rent(Self.date(2026, 11, 20), "roomB"), .notApplicable)
    }

    // MARK: Evidence

    func testEvidenceCountsTaxItemsOnly() throws {
        try makeProperty()
        try requirement("Repairs", category: "repairs")
        try requirement("Utilities", category: "utilities")
        try movement(Self.date(2026, 5, 2), -10_000, "REPAIR ONE", category: "repairs")
        try movement(Self.date(2026, 6, 2), -10_000, "REPAIR TWO", category: "repairs")
        let waived = try movement(Self.date(2026, 7, 2), -10_000, "REPAIR THREE", category: "repairs")
        try movement(Self.date(2026, 8, 10), -5_000, "EXAMPLE POWER", category: "utilities")
        let repairs = try db.read { db in try EvidenceRequirements.all(db: db).first { $0.name == "Repairs" }! }
        try db.write { db in try EvidenceRequirements.waive(db: db, requirementId: repairs.id!, target: .transaction(waived), note: "Lost") }

        let items = try db.read { db in try MissingEvidence.items(db: db, taxYear: UKTaxYear(startYear: 2026)) }
        XCTAssertEqual(items.filter(\.isForRecharges).count, 1)
        let evidence = try XCTUnwrap(try load(Self.date(2026, 10, 20)).evidence)
        XCTAssertEqual(evidence.taxYear, UKTaxYear(startYear: 2026))
        XCTAssertEqual(evidence.missingCount, 2)
    }

    func testWaitingForPaymentCount() throws {
        let today = Self.date(2026, 10, 20)
        try document(date: Self.date(2026, 10, 1), amount: 4_500)
        try document(date: Self.date(2026, 9, 15), amount: 7_000)
        let lapsed = try document(date: Self.date(2026, 3, 1), amount: 3_000)
        XCTAssertEqual(try db.read { db in try WaitingDocuments.state(db: db, documentId: lapsed, now: today) }, .lapsed)
        let evidence = try XCTUnwrap(try load(today).evidence)
        XCTAssertEqual(evidence.waitingForPayment, 2)
        XCTAssertNil(evidence.linkedSinceLastVisit)
    }

    func testLinkedSinceLastVisit() throws {
        try makeProperty()
        let document = try document(date: Self.date(2026, 10, 1), amount: 4_500)
        let debit = try movement(Self.date(2026, 10, 2), -4_500, "EXAMPLE POWER", category: "utilities")
        try db.write { db in
            try db.execute(sql: "INSERT INTO documentLink(documentId, entityType, entityId, createdAt) VALUES (?, ?, ?, ?)",
                           arguments: [document, EvidenceEntityType.transaction.rawValue, debit, Self.date(2026, 10, 10)])
            var recent = AutoLinkRecent(documentId: document, transactionId: debit, linkedAt: Self.date(2026, 10, 10))
            try recent.insert(db)
        }
        let today = Self.date(2026, 10, 20)
        XCTAssertEqual(try load(today).evidence?.linkedSinceLastVisit, 1)
        XCTAssertEqual(try load(today, lastVisit: Self.date(2026, 10, 5)).evidence?.linkedSinceLastVisit, 1)
        XCTAssertEqual(try load(today, lastVisit: Self.date(2026, 10, 15)).evidence?.linkedSinceLastVisit, nil)
        XCTAssertEqual(try load(today, lastVisit: Self.date(2026, 10, 5)).attention.first { $0.kind == .documentsWaiting }?.text,
                       "1 document linked automatically since your last visit")
    }

    // MARK: Mortgage

    func testMortgageMissingFieldsAreNil() throws {
        try makeProperty()
        try mortgage(owed: 15_000_000)
        let summary = try XCTUnwrap(try load(Self.date(2026, 10, 20)).mortgages?.first)
        XCTAssertEqual(summary.propertyName, "Property A")
        XCTAssertEqual(summary.owedMinorUnits, 15_000_000)
        XCTAssertEqual(summary.currency, .eur)
        XCTAssertNil(summary.ratePercent)
        XCTAssertNil(summary.nextDue)
        XCTAssertNil(summary.nextInstalmentMinorUnits)
        XCTAssertNil(summary.nextReview)

        // A fixed rate with its instalments: rate and next instalment, no review.
        try db.write { db in
            try MortgageTerms.save(db: db, PropertyMortgageTerms(propertyId: ids["property"]!, annualRatePercent: 3, rateIndex: .fixed,
                                                                 totalInstalments: 360, firstInstalmentDate: Self.date(2016, 11, 1)))
        }
        let fixed = try XCTUnwrap(try load(Self.date(2026, 10, 20)).mortgages?.first)
        XCTAssertEqual(fixed.ratePercent ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(fixed.nextDue, Self.date(2026, 11, 1))
        let status = try XCTUnwrap(try db.read { db in try MortgageRate.status(db: db, propertyId: ids["property"]!, today: Self.date(2026, 10, 20)) })
        XCTAssertEqual(fixed.nextInstalmentMinorUnits, status.nextInstalmentMinorUnits)
        XCTAssertNil(fixed.nextReview)
    }

    func testRepaidMortgageOmitted() throws {
        try makeProperty()
        try mortgage(owed: 0)
        XCTAssertNil(try load(Self.date(2026, 10, 20)).mortgages)
    }

    // MARK: Needs attention

    func testAttentionLines() throws {
        try makeProperty()
        // Nothing to flag: the rent is due today, nothing else waits.
        XCTAssertEqual(try load(Self.date(2026, 10, 1)).attention, [])

        let today = Self.date(2027, 6, 15)
        let personId = try person("Person A")
        try employed(personId)
        try requirement("Repairs", category: "repairs")
        try movement(Self.date(2027, 5, 2), -10_000, "REPAIR ONE", category: "repairs")
        try movement(Self.date(2027, 5, 9), -10_000, "REPAIR TWO", category: "repairs")
        try waitingImport()
        let review = try load(today)
        XCTAssertEqual(review.attention.map(\.kind), [.taxDeadline, .rentLate, .evidenceMissing, .importsWaiting])
        XCTAssertEqual(review.attention.map(\.text), ["Payment on account due 31 Jul 2027", "Rent not received for Room A",
                                                      "2 tax documents missing", "1 file waiting to import"])
        // More than 60 days before the deadline: not yet.
        XCTAssertFalse(try load(Self.date(2027, 5, 1)).attention.contains { $0.kind == .taxDeadline })
    }
}
