import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Tenant utility recharges (plan phase 5 Task 1): providers, invoices, monthly statements,
/// the rent + recharge split of tenant credits, and the netting of recharges against utilities
/// in the property view and the rental accounts. One synthetic EUR property owned 50/50, a
/// tenancy from 15 March 2024, HMRC rate 0.8 for 2024/25.
final class RechargeTests: XCTestCase {
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
            var a = Person(name: "Person A")
            try People.save(db: db, &a)
            var b = Person(name: "Person B")
            try People.save(db: db, &b)
            ids["A"] = a.id!
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
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "bank.csv", importedAt: Date())
            try batch.insert(db)
            ids["bank"] = account.id!
            ids["batch"] = batch.id!
            try Properties.setAccount(db: db, propertyId: p, accountId: account.id!, role: .current)
            var group = CategoryGroup(name: "Property A")
            try group.insert(db)
            try Properties.addCategoryGroup(db: db, propertyId: p, categoryGroupId: group.id!)
            for (key, name, type) in [("rent", "Rental income", CategoryType.income), ("utilities", "Utilities", .expense),
                                      ("repairs", "Repairs", .expense)] {
                var category = Category(name: name, type: type, groupId: group.id)
                try category.insert(db)
                ids[key] = category.id!
            }
            try TaxExpenseTypeMap.seed(db: db, propertyId: p)
            try HMRCRates.set(db: db, startYear: 2024, currencyCode: "EUR", gbpPerUnit: 0.8, source: .manual)

            var tenancy = Tenancy(propertyId: p, referenceLabel: "Room Contract AB", contractNumber: "3001", startDate: Self.date(2024, 3, 15))
            try Tenancies.save(db: db, &tenancy)
            ids["tenancy"] = tenancy.id!
            var receipt = RentReceipt(tenancyId: tenancy.id!, receiptNumber: "1", periodStart: Self.date(2024, 5, 1),
                                      periodEnd: Self.date(2024, 5, 31), receiptDate: Self.date(2024, 5, 2), amountMinorUnits: 100_000)
            try RentReceipts.save(db: db, &receipt)

            var power = UtilityProvider(propertyId: p, name: "Example Power", kind: .electricity, bankDescriptionPattern: "EXAMPLE POWER")
            try Recharges.saveProvider(db: db, &power)
            var water = UtilityProvider(propertyId: p, name: "Example Water", kind: .water)
            try Recharges.saveProvider(db: db, &water)
            ids["power"] = power.id!
            ids["water"] = water.id!
        }
    }

    @discardableResult
    private func transaction(_ category: String, _ date: Date, _ amount: Int, _ text: String = "TRANSFER") throws -> Int64 {
        try db.write { db in
            var transaction = Transaction(importBatchId: id("batch"), accountId: id("bank"), date: date, rawDescription: text,
                                          amountMinorUnits: amount, categoryId: ids[category], status: .confirmed, categorizedBy: .manual,
                                          fingerprint: UUID().uuidString)
            try transaction.insert(db)
            return transaction.id!
        }
    }

    @discardableResult
    private func invoice(_ provider: String, _ number: String, issued: Date, amount: Int, period: (Date, Date)? = nil,
                         debit: Int64? = nil) throws -> Int64 {
        try db.write { db in
            var invoice = UtilityInvoice(providerId: id(provider), invoiceNumber: number, periodStart: period?.0, periodEnd: period?.1,
                                         issueDate: issued, amountMinorUnits: amount, transactionId: debit)
            try Recharges.saveInvoice(db: db, &invoice)
            return invoice.id!
        }
    }

    /// April: the first electricity invoice (Feb–Mar, 17 of its 60 days in the tenancy) and a
    /// water invoice; May: a gas-free month with a water refund.
    private func seedInvoices() throws {
        let powerDebit = try transaction("utilities", Self.date(2024, 4, 8), -6_000, "EXAMPLE POWER")
        try invoice("power", "P-1", issued: Self.date(2024, 4, 3), amount: 6_000, period: (Self.date(2024, 2, 1), Self.date(2024, 3, 31)),
                    debit: powerDebit)
        let waterDebit = try transaction("utilities", Self.date(2024, 4, 25), -1_000, "EXAMPLE WATER")
        try invoice("water", "W-1", issued: Self.date(2024, 4, 20), amount: 1_000, debit: waterDebit)
        try invoice("water", "W-2", issued: Self.date(2024, 5, 20), amount: -500)
    }

    // MARK: Records

    func testProvidersAndInvoicesAreValidated() throws {
        try db.write { db in
            var blank = UtilityProvider(propertyId: id("property"), name: "  ", kind: .gas)
            XCTAssertThrowsError(try Recharges.saveProvider(db: db, &blank)) { XCTAssertEqual($0 as? RechargeError, .blankName) }
            var clash = UtilityProvider(propertyId: id("property"), name: "example power", kind: .gas)
            XCTAssertThrowsError(try Recharges.saveProvider(db: db, &clash)) { XCTAssertEqual($0 as? RechargeError, .duplicateName) }
            var halfPeriod = UtilityInvoice(providerId: id("power"), periodStart: Self.date(2024, 1, 1), issueDate: Self.date(2024, 2, 1),
                                            amountMinorUnits: 100)
            XCTAssertThrowsError(try Recharges.saveInvoice(db: db, &halfPeriod)) { XCTAssertEqual($0 as? RechargeError, .invalidPeriod) }
            var backwards = UtilityInvoice(providerId: id("power"), periodStart: Self.date(2024, 2, 1), periodEnd: Self.date(2024, 1, 1),
                                           issueDate: Self.date(2024, 2, 1), amountMinorUnits: 100)
            XCTAssertThrowsError(try Recharges.saveInvoice(db: db, &backwards)) { XCTAssertEqual($0 as? RechargeError, .invalidPeriod) }
            var first = UtilityInvoice(providerId: id("power"), invoiceNumber: " P-9 ", issueDate: Self.date(2024, 2, 1), amountMinorUnits: 100)
            try Recharges.saveInvoice(db: db, &first)
            XCTAssertEqual(first.invoiceNumber, "P-9")
            var again = UtilityInvoice(providerId: id("power"), invoiceNumber: "P-9", issueDate: Self.date(2024, 3, 1), amountMinorUnits: 100)
            XCTAssertThrowsError(try Recharges.saveInvoice(db: db, &again)) { XCTAssertEqual($0 as? RechargeError, .duplicateInvoiceNumber) }
            XCTAssertEqual(try Recharges.providers(db: db, propertyId: id("property")).map(\.name), ["Example Power", "Example Water"])
        }
    }

    // MARK: Statements

    func testMonthlyStatementTakesTheInvoicesSinceTheLastOne() throws {
        try seedInvoices()
        let april = try db.write { db in try Recharges.draftStatement(db: db, tenancyId: id("tenancy"), month: Self.date(2024, 4, 17)) }
        XCTAssertEqual(april.month, Self.date(2024, 4, 1))
        XCTAssertEqual(april.status, .draft)
        // 6,000 × 17/60 = 1,700 (15–31 March of 1 Feb – 31 Mar) + 1,000.
        XCTAssertEqual(april.totalMinorUnits, 2_700)
        let lines = try db.read { db in try Recharges.lines(db: db, statementId: april.id!) }
        XCTAssertEqual(lines.map(\.amountMinorUnits), [1_700, 1_000])
        XCTAssertEqual(lines.first?.note, "17 of 60 days in the tenancy")

        // Sent: fixed. An invoice arriving late (issued in April) goes on May's statement.
        try db.write { db in _ = try Recharges.markSent(db: db, statementId: april.id!, at: Self.date(2024, 4, 30)) }
        try invoice("water", "W-late", issued: Self.date(2024, 4, 28), amount: 300)
        let again = try db.write { db in try Recharges.draftStatement(db: db, tenancyId: id("tenancy"), month: Self.date(2024, 4, 1)) }
        XCTAssertEqual(again.totalMinorUnits, 2_700)
        XCTAssertEqual(again.status, .sent)
        let may = try db.write { db in try Recharges.draftStatement(db: db, tenancyId: id("tenancy"), month: Self.date(2024, 5, 1)) }
        XCTAssertEqual(may.totalMinorUnits, 300 - 500)
        XCTAssertThrowsError(try db.write { db in
            try Recharges.setLine(db: db, statementId: april.id!, invoiceId: try XCTUnwrap(lines.first?.invoiceId), amountMinorUnits: 100)
        }) { XCTAssertEqual($0 as? RechargeError, .statementNotDraft) }
    }

    func testRechargeDateIsTheDebitDateElseTheIssueDate() throws {
        let debit = try transaction("utilities", Self.date(2024, 5, 16), -2_000, "EXAMPLE POWER")
        try invoice("power", "P-2", issued: Self.date(2024, 4, 20), amount: 2_000, debit: debit)
        try invoice("water", "W-9", issued: Self.date(2024, 4, 22), amount: 300)
        let april = try db.read { db in try Recharges.pendingLines(db: db, tenancyId: id("tenancy"), through: Self.date(2024, 4, 30)) }
        XCTAssertEqual(april.map(\.rechargeDate), [Self.date(2024, 4, 22)])
        let may = try db.read { db in try Recharges.pendingLines(db: db, tenancyId: id("tenancy"), through: Self.date(2024, 5, 31)) }
        XCTAssertEqual(may.map(\.rechargeDate), [Self.date(2024, 4, 22), Self.date(2024, 5, 16)])
    }

    func testInvoicesOutsideTheTenancyAreLeftOut() throws {
        try invoice("power", "P-0", issued: Self.date(2024, 2, 5), amount: 4_000, period: (Self.date(2023, 12, 1), Self.date(2024, 1, 31)))
        try invoice("water", "W-0", issued: Self.date(2024, 3, 1), amount: 900)
        let pending = try db.read { db in try Recharges.pendingLines(db: db, tenancyId: id("tenancy"), through: Self.date(2024, 4, 30)) }
        XCTAssertEqual(pending, [])
    }

    func testLinesCannotRechargeMoreThanTheInvoice() throws {
        let invoiceId = try invoice("water", "W-1", issued: Self.date(2024, 4, 20), amount: 1_000)
        try db.write { db in
            let statement = try Recharges.draftStatement(db: db, tenancyId: id("tenancy"), month: Self.date(2024, 4, 1))
            XCTAssertThrowsError(try Recharges.setLine(db: db, statementId: statement.id!, invoiceId: invoiceId, amountMinorUnits: 1_001)) {
                XCTAssertEqual($0 as? RechargeError, .overRecharged)
            }
            try Recharges.setLine(db: db, statementId: statement.id!, invoiceId: invoiceId, amountMinorUnits: 400, note: "shared bill")
            XCTAssertEqual(try RechargeStatement.fetchOne(db, key: statement.id!)?.totalMinorUnits, 400)
            XCTAssertThrowsError(try Recharges.deleteInvoice(db: db, id: invoiceId)) { XCTAssertEqual($0 as? RechargeError, .invoiceOnStatement) }
            // Deleting the draft makes the invoice pending again.
            try Recharges.deleteStatement(db: db, id: statement.id!)
            XCTAssertEqual(try Recharges.pendingLines(db: db, tenancyId: id("tenancy"), through: Self.date(2024, 4, 30)).count, 1)
        }
    }

    // MARK: Payments

    /// The April statement (2,700) is sent; May's transfer is rent 1,000.00 + 27.00.
    private func payAprilWithMayRent() throws -> (statementId: Int64, creditId: Int64) {
        try seedInvoices()
        let statement = try db.write { db -> RechargeStatement in
            let statement = try Recharges.draftStatement(db: db, tenancyId: id("tenancy"), month: Self.date(2024, 4, 1))
            return try Recharges.markSent(db: db, statementId: statement.id!, at: Self.date(2024, 4, 30))
        }
        let credit = try transaction("rent", Self.date(2024, 5, 2), 102_700)
        try db.write { db in
            _ = try RentReceiptMatching.match(db: db, propertyId: id("property"))
            _ = try Recharges.matchPayments(db: db, propertyId: id("property"))
        }
        return (statement.id!, credit)
    }

    func testTheNextTenantCreditPaysTheStatement() throws {
        let (statementId, creditId) = try payAprilWithMayRent()
        try db.read { db in
            XCTAssertEqual(try RechargeStatement.fetchOne(db, key: statementId)?.status, .paid)
            XCTAssertEqual(try Recharges.outstanding(db: db, statementId: statementId), 0)
            XCTAssertEqual(try Recharges.creditRemainder(db: db, transactionId: creditId), 0)
            let received = try Recharges.received(db: db, propertyId: id("property"))
            XCTAssertEqual(received.map(\.payment.amountMinorUnits), [2_700])
            XCTAssertEqual(received.first?.payment.origin, .auto)
        }
        // Idempotent; unlinking goes back to sent; a manual link can't take more than the credit's remainder.
        try db.write { db in
            XCTAssertEqual(try Recharges.matchPayments(db: db, propertyId: id("property")), [])
            XCTAssertTrue(try Recharges.unlinkPayment(db: db, statementId: statementId, transactionId: creditId))
            XCTAssertEqual(try RechargeStatement.fetchOne(db, key: statementId)?.status, .sent)
            XCTAssertThrowsError(try Recharges.linkPayment(db: db, statementId: statementId, transactionId: creditId, amountMinorUnits: 2_701)) {
                XCTAssertEqual($0 as? RechargeError, .overAllocated)
            }
            try Recharges.linkPayment(db: db, statementId: statementId, transactionId: creditId, amountMinorUnits: 2_000)
            XCTAssertEqual(try RechargeStatement.fetchOne(db, key: statementId)?.status, .sent)
            XCTAssertThrowsError(try Recharges.reopen(db: db, statementId: statementId)) {
                XCTAssertEqual($0 as? RechargeError, .statementHasPayments)
            }
        }
    }

    func testDraftStatementsTakeNoPayments() throws {
        try seedInvoices()
        let credit = try transaction("rent", Self.date(2024, 5, 2), 2_700)
        try db.write { db in
            let statement = try Recharges.draftStatement(db: db, tenancyId: id("tenancy"), month: Self.date(2024, 4, 1))
            XCTAssertThrowsError(try Recharges.linkPayment(db: db, statementId: statement.id!, transactionId: credit)) {
                XCTAssertEqual($0 as? RechargeError, .statementNotSent)
            }
        }
    }

    // MARK: Property view

    func testPropertyFiguresNetRechargesAgainstUtilities() throws {
        _ = try payAprilWithMayRent()
        let totals = try db.read { db in
            try PropertyFinance.summary(db: db, propertyId: id("property"), period: .calendarYear(2024), today: Self.date(2025, 1, 10)).totals
        }
        XCTAssertEqual(totals.utilities.native, 7_000)
        XCTAssertEqual(totals.utilityRecharges.native, 2_700)
        XCTAssertEqual(totals.netUtilities.native, 4_300)
        XCTAssertEqual(totals.recharges.native, 2_700)
        XCTAssertEqual(totals.rentReceived.native, 100_000)
    }

    // MARK: Rental accounts

    private func accounts() throws -> RentalAccounts.Result {
        try db.read { db in try RentalAccounts.compute(db: db, taxYear: UKTaxYear(startYear: 2024), personId: id("A"), propertyId: id("property")) }
    }

    func testWithoutRechargesUtilitiesStayNotDeductibleWithAWarning() throws {
        try seedInvoices()
        let a = try accounts()
        XCTAssertEqual(a.line(.utilities)?.whole.native, 0)
        XCTAssertEqual(a.notDeductible.whole.native, 7_000)
        XCTAssertNil(a.utilityNetting.mode)
        XCTAssertEqual(a.utilityNetting.utilitiesPaid, 7_000)
        XCTAssertTrue(a.warnings.contains { $0.hasPrefix("No utility recharges received in 2024/25") }, "\(a.warnings)")
    }

    func testRechargesReceivedAreNettedAgainstUtilities() throws {
        let (_, creditId) = try payAprilWithMayRent()
        let a = try accounts()
        let line = try XCTUnwrap(a.line(.utilities))
        XCTAssertEqual(line.whole.native, 4_300)
        XCTAssertEqual(line.amount.native, 2_150)
        XCTAssertEqual(line.amount.gbp, 1_720)
        XCTAssertTrue(line.ruleExplanation.contains("Net of the utilities recharged"))
        let recharge = try XCTUnwrap(line.sources.first { $0.attributedMinorUnits < 0 })
        XCTAssertEqual(recharge.reference, .transaction(creditId))
        XCTAssertEqual(recharge.transactionId, creditId, "Show in Search opens the credit")
        XCTAssertEqual(recharge.attributedMinorUnits, -2_700)
        XCTAssertEqual(a.notDeductible.whole.native, 0)
        XCTAssertEqual(a.utilityNetting, RentalAccounts.UtilityNetting(mode: .netOfRecharges, isAutomatic: true, utilitiesPaid: 7_000,
                                                                       rechargesReceived: 2_700, rechargesApplied: 2_700, excess: 0))
        XCTAssertFalse(a.warnings.contains { $0.contains("recharges") }, "\(a.warnings)")
    }

    func testNettingNeverGoesBelowZero() throws {
        _ = try payAprilWithMayRent()
        // A further 10,000 recharged (e.g. last year's invoices) against only 7,000 paid.
        let extra = try invoice("power", "P-3", issued: Self.date(2024, 5, 3), amount: 10_000)
        let credit = try transaction("rent", Self.date(2024, 6, 3), 10_000)
        try db.write { db in
            let june = try Recharges.draftStatement(db: db, tenancyId: id("tenancy"), month: Self.date(2024, 5, 1))
            XCTAssertNotNil(try RechargeLine.filter(Column("invoiceId") == extra).fetchOne(db))
            try Recharges.markSent(db: db, statementId: june.id!, at: Self.date(2024, 6, 1))
            try Recharges.linkPayment(db: db, statementId: june.id!, transactionId: credit, amountMinorUnits: 9_500)
        }
        let rentOnly = try accountsWithoutRecharges()
        let a = try accounts()
        XCTAssertEqual(a.line(.utilities)?.whole.native, 0)
        XCTAssertEqual(a.utilityNetting.rechargesReceived, 12_200)
        XCTAssertEqual(a.utilityNetting.rechargesApplied, 7_000)
        XCTAssertEqual(a.utilityNetting.excess, 5_200)
        // The excess, 12,200 received − 7,000 paid, is rental income.
        let excess = try XCTUnwrap(a.income.sources.first { $0.description.hasPrefix("Recharges above utilities paid") })
        XCTAssertEqual(excess.reference, .transaction(credit))
        XCTAssertEqual(excess.transactionId, credit)
        XCTAssertEqual(excess.attributedMinorUnits, 5_200)
        XCTAssertTrue(excess.explanation.contains("the part above the utilities paid"))
        XCTAssertEqual(a.income.whole.native, rentOnly.income.whole.native + 5_200)
        XCTAssertTrue(a.warnings.contains { $0.hasPrefix("Recharges received in 2024/25 exceed the utilities paid") }, "\(a.warnings)")
    }

    /// The accounts with the recharge links set aside (then restored).
    private func accountsWithoutRecharges() throws -> RentalAccounts.Result {
        let saved = try db.read { db in try RechargePayment.fetchAll(db) }
        try db.write { db in try RechargePayment.deleteAll(db) }
        defer { try? db.write { db in for var payment in saved { try payment.insert(db) } } }
        return try accounts()
    }

    func testFiledYearsKeepUtilitiesNotDeductibleUnlessSet() throws {
        _ = try payAprilWithMayRent()
        try db.write { db in
            var year = try TaxYears.ensure(db: db, startYear: 2024, personId: id("A"))
            year.status = .filed
            try TaxYears.save(db: db, &year)
        }
        var a = try accounts()
        XCTAssertNil(a.utilityNetting.mode)
        XCTAssertTrue(a.utilityNetting.isAutomatic)
        XCTAssertEqual(a.notDeductible.whole.native, 7_000)
        XCTAssertEqual(a.line(.utilities)?.whole.native, 0)
        XCTAssertTrue(a.warnings.contains { $0.hasPrefix("2024/25 is filed: utilities stay on their own tax lines") }, "\(a.warnings)")
        XCTAssertFalse(a.warnings.contains { $0.hasPrefix("No utility recharges") })
        try db.write { db in try RechargeNetting.set(db: db, startYear: 2024, mode: .netOfRecharges) }
        a = try accounts()
        XCTAssertEqual(a.line(.utilities)?.whole.native, 4_300)
    }

    func testManualLinesCarryOneOffChargesAndRefunds() throws {
        try seedInvoices()
        try db.write { db in
            var document = EvidenceDocument(sha256: "refund", storedRelativePath: "re/refund.pdf", originalFileName: "Refund.pdf",
                                            byteCount: 1, kind: .other, addedAt: Date())
            try document.insert(db)
            let statement = try Recharges.draftStatement(db: db, tenancyId: id("tenancy"), month: Self.date(2024, 4, 1))
            XCTAssertThrowsError(try Recharges.saveManualLine(db: db, statementId: statement.id!, description: " ", amountMinorUnits: 10)) {
                XCTAssertEqual($0 as? RechargeError, .blankDescription)
            }
            let refund = try Recharges.saveManualLine(db: db, statementId: statement.id!, description: "Appliance refund",
                                                      amountMinorUnits: -20_298, documentId: document.id)
            XCTAssertTrue(refund.isManual)
            XCTAssertEqual(try RechargeStatement.fetchOne(db, key: statement.id!)?.totalMinorUnits, 2_700 - 20_298)
            let lines = try Recharges.lines(db: db, statementId: statement.id!)
            XCTAssertEqual(lines.last?.lineDescription, "Appliance refund")
            XCTAssertEqual(lines.last?.documentId, document.id)
            try Recharges.saveManualLine(db: db, statementId: statement.id!, lineId: refund.id, description: "Appliance refund",
                                         amountMinorUnits: -1_000)
            XCTAssertEqual(try RechargeStatement.fetchOne(db, key: statement.id!)?.totalMinorUnits, 1_700)
            XCTAssertTrue(try Recharges.removeLine(db: db, lineId: refund.id!))
            XCTAssertEqual(try RechargeStatement.fetchOne(db, key: statement.id!)?.totalMinorUnits, 2_700)
        }
    }

    func testOneCreditCanPayConsecutiveStatements() throws {
        try seedInvoices()
        let (april, may) = try db.write { db -> (Int64, Int64) in
            let april = try Recharges.draftStatement(db: db, tenancyId: id("tenancy"), month: Self.date(2024, 4, 1))
            try Recharges.markSent(db: db, statementId: april.id!, at: Self.date(2024, 4, 30))
            try Recharges.saveManualLine(db: db, statementId: try Recharges.draftStatement(db: db, tenancyId: id("tenancy"),
                                                                                            month: Self.date(2024, 5, 1)).id!,
                                         description: "Extra", amountMinorUnits: 1_000)
            let may = try XCTUnwrap(try Recharges.statements(db: db, tenancyId: id("tenancy")).first)
            try Recharges.markSent(db: db, statementId: may.id!, at: Self.date(2024, 5, 31))
            return (april.id!, may.id!)
        }
        // May's statement: −500 refund + 1,000 extra = 500. June's transfer pays both: 2,700 + 500.
        let credit = try transaction("rent", Self.date(2024, 6, 3), 3_200)
        let made = try db.write { db in try Recharges.matchPayments(db: db, propertyId: id("property")) }
        XCTAssertEqual(made.map(\.statementId), [april, may])
        XCTAssertEqual(made.map(\.amountMinorUnits), [2_700, 500])
        XCTAssertEqual(Set(made.map(\.transactionId)), [credit])
        // A rounded transfer stays for review.
        try db.write { db in
            for payment in made { try Recharges.unlinkPayment(db: db, statementId: payment.statementId, transactionId: credit) }
            try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = 3300 WHERE id = ?", arguments: [credit])
            XCTAssertEqual(try Recharges.matchPayments(db: db, propertyId: id("property")), [])
        }
    }

    func testAStoredModeOverridesTheData() throws {
        _ = try payAprilWithMayRent()
        try db.write { db in try RechargeNetting.set(db: db, startYear: 2024, mode: .notDeductible) }
        var a = try accounts()
        XCTAssertEqual(a.line(.utilities)?.whole.native, 0)
        XCTAssertEqual(a.notDeductible.whole.native, 7_000)
        XCTAssertEqual(a.utilityNetting.mode, .notDeductible)
        XCTAssertFalse(a.utilityNetting.isAutomatic)

        // Net for every year, no recharges: utilities fully deductible.
        try db.write { db in
            try RechargeNetting.set(db: db, startYear: 2024, mode: nil)
            try RechargeNetting.set(db: db, startYear: nil, mode: .netOfRecharges)
            try RechargePayment.deleteAll(db)
        }
        a = try accounts()
        XCTAssertEqual(a.line(.utilities)?.whole.native, 7_000)
        XCTAssertFalse(a.warnings.contains { $0.hasPrefix("No utility recharges") })
    }

    func testCategoriesTypedUtilitiesAreNettedToo() throws {
        _ = try payAprilWithMayRent()
        try db.write { db in try TaxExpenseTypeMap.set(db: db, categoryId: id("utilities"), expenseType: .utilities) }
        XCTAssertEqual(try accounts().line(.utilities)?.whole.native, 4_300)
        XCTAssertEqual(try db.read { db in try RechargeNetting.utilityCategoryIds(db: db, propertyId: id("property")) }, [id("utilities")])
    }

    func testNoRechargesWarningOnlyWhenUtilitiesAreLeftNotDeductible() throws {
        try seedInvoices()
        try db.write { db in try TaxExpenseTypeMap.set(db: db, categoryId: id("utilities"), expenseType: .utilities) }
        let a = try accounts()
        XCTAssertEqual(a.line(.utilities)?.whole.native, 7_000)
        XCTAssertFalse(a.warnings.contains { $0.hasPrefix("No utility recharges") }, "\(a.warnings)")
    }

    func testRentFromCreditsLeavesOutTheRechargePart() throws {
        _ = try payAprilWithMayRent()
        try db.write { db in try TaxAttributionRules.set(db: db, expenseType: .rentalIncome, startYear: nil, rule: .byDate) }
        let a = try accounts()
        let credit = try XCTUnwrap(a.income.sources.first)
        XCTAssertEqual(credit.attributedMinorUnits, 100_000)
        XCTAssertTrue(credit.explanation.contains("of utilities recharged"))
        XCTAssertEqual(a.income.whole.native, 100_000)
        XCTAssertEqual(a.line(.utilities)?.whole.native, 4_300)
    }

    // MARK: Integrity

    func testDeletingThePropertyRemovesItsRecharges() throws {
        _ = try payAprilWithMayRent()
        try db.write { db in
            XCTAssertTrue(try Properties.delete(db: db, id: id("property")))
            for table in ["utilityProvider", "utilityInvoice", "rechargeStatement", "rechargeLine", "rechargePayment"] {
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)"), 0, table)
            }
        }
    }

    func testRentMatchingLeavesRechargeLinksAlone() throws {
        try seedInvoices()
        let credit = try transaction("rent", Self.date(2024, 5, 2), 102_700)
        let receiptId = try db.write { db -> Int64 in
            let statement = try Recharges.draftStatement(db: db, tenancyId: id("tenancy"), month: Self.date(2024, 4, 1))
            try Recharges.markSent(db: db, statementId: statement.id!, at: Self.date(2024, 4, 30))
            try Recharges.linkPayment(db: db, statementId: statement.id!, transactionId: credit)
            _ = try RentReceiptMatching.match(db: db, propertyId: id("property"))
            return try XCTUnwrap(try RentReceipt.fetchOne(db)).id!
        }
        try db.write { db in
            let links = try RentReceiptMatching.payments(db: db, transactionId: credit)
            XCTAssertEqual(links.map(\.rentMinorUnits), [100_000])
            XCTAssertEqual(links.map(\.otherMinorUnits), [0])
            try RentReceiptMatching.unlink(db: db, receiptId: receiptId, transactionId: credit)
            XCTAssertThrowsError(try RentReceiptMatching.link(db: db, receiptId: receiptId, transactionId: credit, rentMinorUnits: 100_001)) {
                XCTAssertEqual($0 as? RentPaymentError, .overAllocated)
            }
        }
        // A credit taken wholly by recharges isn't an unmatched rent credit.
        let recharge = try transaction("rent", Self.date(2024, 6, 2), 300)
        try invoice("water", "W-3", issued: Self.date(2024, 5, 25), amount: 300)
        try db.write { db in
            let may = try Recharges.draftStatement(db: db, tenancyId: id("tenancy"), month: Self.date(2024, 5, 1))
            try Recharges.removeLine(db: db, statementId: may.id!, invoiceId: try XCTUnwrap(try UtilityInvoice.filter(Column("invoiceNumber") == "W-2").fetchOne(db)).id!)
            try Recharges.markSent(db: db, statementId: may.id!, at: Self.date(2024, 5, 31))
            try Recharges.linkPayment(db: db, statementId: may.id!, transactionId: recharge)
            XCTAssertFalse(try RentReceiptMatching.unmatchedCredits(db: db, propertyId: id("property")).contains { $0.id == recharge })
        }
    }

    func testStatementsSettleAndUnsettle() throws {
        let (statementId, creditId) = try payAprilWithMayRent()
        // Deleting the paying credit un-pays the statement.
        try db.write { db in
            _ = try Transaction.deleteOne(db, key: creditId)
            XCTAssertEqual(try RechargeStatement.fetchOne(db, key: statementId)?.status, .sent)
        }
        // A statement with nothing to pay (a refund) is settled when sent.
        try db.write { db in
            let may = try Recharges.draftStatement(db: db, tenancyId: id("tenancy"), month: Self.date(2024, 5, 1))
            XCTAssertEqual(may.totalMinorUnits, -500)
            XCTAssertEqual(try Recharges.markSent(db: db, statementId: may.id!, at: Self.date(2024, 5, 31)).status, .paid)
            // Months are drafted in order.
            XCTAssertThrowsError(try Recharges.draftStatement(db: db, tenancyId: id("tenancy"), month: Self.date(2024, 3, 1))) {
                XCTAssertEqual($0 as? RechargeError, .laterStatementExists)
            }
        }
    }

    func testInvoiceEditsFollowDraftsAndAreRefusedOnceSent() throws {
        let invoiceId = try invoice("water", "W-1", issued: Self.date(2024, 4, 20), amount: 1_000)
        try db.write { db in
            let statement = try Recharges.draftStatement(db: db, tenancyId: id("tenancy"), month: Self.date(2024, 4, 1))
            var invoice = try XCTUnwrap(try UtilityInvoice.fetchOne(db, key: invoiceId))
            invoice.amountMinorUnits = 1_200
            try Recharges.saveInvoice(db: db, &invoice)
            XCTAssertEqual(try RechargeStatement.fetchOne(db, key: statement.id!)?.totalMinorUnits, 1_200)
            try Recharges.markSent(db: db, statementId: statement.id!, at: Self.date(2024, 4, 30))
            invoice.amountMinorUnits = 1_300
            XCTAssertThrowsError(try Recharges.saveInvoice(db: db, &invoice)) { XCTAssertEqual($0 as? RechargeError, .invoiceOnSentStatement) }
            invoice.amountMinorUnits = 1_200
            invoice.notes = "checked"
            try Recharges.saveInvoice(db: db, &invoice)
        }
    }

    func testProrationRoundsCumulatively() throws {
        // 100 over 14–16 March: the tenancy (from the 15th) takes 2 of 3 days = 100 − 33.
        try invoice("power", "P-x", issued: Self.date(2024, 3, 20), amount: 100, period: (Self.date(2024, 3, 14), Self.date(2024, 3, 16)))
        let pending = try db.read { db in try Recharges.pendingLines(db: db, tenancyId: id("tenancy"), through: Self.date(2024, 3, 31)) }
        XCTAssertEqual(pending.map(\.amountMinorUnits), [67])
    }

    // MARK: Statement screen and email

    func testTheEmailDraftHasRecipientsSummaryAndAttachments() throws {
        try seedInvoices()
        let statementId = try db.write { db -> Int64 in
            var tenancy = try XCTUnwrap(try Tenancy.fetchOne(db, key: id("tenancy")))
            tenancy.tenantName = "Tenant B"
            tenancy.tenantEmail = " tenant@example.com, other@example.com "
            try Tenancies.save(db: db, &tenancy)
            var document = EvidenceDocument(sha256: "inv", storedRelativePath: "in/inv.pdf", originalFileName: "Invoice.pdf", byteCount: 1,
                                            kind: .utilityInvoice, addedAt: Date())
            try document.insert(db)
            try db.execute(sql: "UPDATE utilityInvoice SET documentId = ? WHERE invoiceNumber = 'W-1'", arguments: [document.id!])
            ids["doc"] = document.id!
            return try Recharges.draftStatement(db: db, tenancyId: id("tenancy"), month: Self.date(2024, 4, 1)).id!
        }
        let draft = try db.read { db in try RechargeEmail.draft(db: db, statementId: statementId, language: .portuguese) }
        XCTAssertEqual(draft.recipients, ["tenant@example.com", "other@example.com"])
        XCTAssertEqual(draft.subject, "Despesas de abril de 2024 — Property A")
        XCTAssertTrue(draft.body.hasPrefix("Olá Tenant B,"), draft.body)
        XCTAssertTrue(draft.body.contains("(água e luz)"), draft.body)
        XCTAssertTrue(draft.body.contains("• Luz (Example Power) — fatura de 03/04/2024, 01/02/2024 – 31/03/2024 (17 de 60 dias no contrato): 17,00"), draft.body)
        XCTAssertTrue(draft.body.contains("• Água (Example Water) — fatura de 20/04/2024: 10,00"), draft.body)
        XCTAssertTrue(draft.body.contains("Total a acrescentar à próxima transferência da renda: 27,00"), draft.body)
        XCTAssertEqual(draft.attachmentDocumentIds, [id("doc")])

        // An edited English template is kept per property and language.
        try db.write { db in
            var template = try RechargeEmail.template(db: db, propertyId: id("property"), language: .english)
            template.subject = "Bills {month}"
            try RechargeEmail.saveTemplate(db: db, &template)
        }
        let english = try db.read { db in try RechargeEmail.draft(db: db, statementId: statementId, language: .english) }
        XCTAssertEqual(english.subject, "Bills April 2024")
        XCTAssertTrue(english.body.contains("Electricity (Example Power) — invoice of 03/04/2024, 01/02/2024 – 31/03/2024 (17 of 60 days in the tenancy)"), english.body)
        XCTAssertTrue(english.body.contains("€27.00"), english.body)
    }

    func testThePreviewFromPendingLinesSaysWhatTheSavedStatementWill() throws {
        try seedInvoices()
        let april = Self.date(2024, 4, 1)
        // The statement sheet before anything is saved: the month's pending lines, as lines.
        let preview = try db.read { db -> RechargeEmail.Draft in
            let tenancy = try XCTUnwrap(try Tenancy.fetchOne(db, key: id("tenancy")))
            let property = try XCTUnwrap(try Property.fetchOne(db, key: id("property")))
            let pending = try Recharges.pendingLines(db: db, tenancyId: id("tenancy"), through: Self.date(2024, 4, 30))
            XCTAssertTrue(pending.contains { $0.daysInTenancy != nil }, "a prorated line")
            let details = try pending.map { line -> Recharges.LineDetail in
                var record = RechargeLine(statementId: 0, invoiceId: line.invoice.id!, amountMinorUnits: line.amountMinorUnits, note: line.note)
                record.daysInTenancy = line.daysInTenancy
                record.daysInPeriod = line.daysInPeriod
                return Recharges.LineDetail(line: record, invoice: line.invoice, provider: try UtilityProvider.fetchOne(db, key: line.invoice.providerId))
            }
            return RechargeEmail.draft(details: details, totalMinorUnits: pending.reduce(0) { $0 + $1.amountMinorUnits }, month: april,
                                       tenancy: tenancy, propertyName: property.name, currency: property.currency, language: .english,
                                       template: try RechargeEmail.template(db: db, propertyId: id("property"), language: .english))
        }
        // The same month once its statement is drafted with every pending line.
        let statementId = try db.write { db in try Recharges.draftStatement(db: db, tenancyId: id("tenancy"), month: april, addPending: true).id! }
        let saved = try db.read { db in try RechargeEmail.draft(db: db, statementId: statementId, language: .english) }
        XCTAssertEqual(preview, saved)
        XCTAssertTrue(saved.body.contains("(17 of 60 days in the tenancy)"), saved.body)
    }

    func testACappedPendingLineSaysTheSameInThePreviewAndTheSavedStatement() throws {
        // Feb–Mar electricity, 17 of its 60 days in the tenancy (17.00 of 60.00); another
        // tenancy's statement already recharged 50.00 of it, so 10.00 is left: the line is
        // capped, not the prorated share, and carries no proration days.
        let invoiceId = try invoice("power", "P-1", issued: Self.date(2024, 4, 3), amount: 6_000,
                                    period: (Self.date(2024, 2, 1), Self.date(2024, 3, 31)))
        let april = Self.date(2024, 4, 1)
        try db.write { db in
            var other = Tenancy(propertyId: id("property"), referenceLabel: "Other", startDate: Self.date(2024, 1, 1))
            try Tenancies.save(db: db, &other)
            let theirs = try Recharges.draftStatement(db: db, tenancyId: other.id!, month: april, addPending: false)
            try Recharges.setLine(db: db, statementId: theirs.id!, invoiceId: invoiceId, amountMinorUnits: 5_000)
        }
        // The statement sheet before anything is saved: the month's pending lines, as lines.
        let preview = try db.read { db -> RechargeEmail.Draft in
            let tenancy = try XCTUnwrap(try Tenancy.fetchOne(db, key: id("tenancy")))
            let property = try XCTUnwrap(try Property.fetchOne(db, key: id("property")))
            let pending = try Recharges.pendingLines(db: db, tenancyId: id("tenancy"), through: Self.date(2024, 4, 30))
            XCTAssertEqual(pending.map(\.amountMinorUnits), [1_000])
            XCTAssertEqual(pending.map(\.daysInTenancy), [nil])
            XCTAssertEqual(pending.map(\.daysInPeriod), [nil])
            XCTAssertEqual(pending.map(\.note), [nil], "no proration note on a capped line")
            let details = try pending.map { line -> Recharges.LineDetail in
                var record = RechargeLine(statementId: 0, invoiceId: line.invoice.id!, amountMinorUnits: line.amountMinorUnits, note: line.note)
                record.daysInTenancy = line.daysInTenancy
                record.daysInPeriod = line.daysInPeriod
                return Recharges.LineDetail(line: record, invoice: line.invoice, provider: try UtilityProvider.fetchOne(db, key: line.invoice.providerId))
            }
            return RechargeEmail.draft(details: details, totalMinorUnits: pending.reduce(0) { $0 + $1.amountMinorUnits }, month: april,
                                       tenancy: tenancy, propertyName: property.name, currency: property.currency, language: .english,
                                       template: try RechargeEmail.template(db: db, propertyId: id("property"), language: .english))
        }
        // The same month once its statement is drafted with every pending line.
        let statementId = try db.write { db in try Recharges.draftStatement(db: db, tenancyId: id("tenancy"), month: april, addPending: true).id! }
        let (saved, lines) = try db.read { db in
            (try RechargeEmail.draft(db: db, statementId: statementId, language: .english), try Recharges.lines(db: db, statementId: statementId))
        }
        XCTAssertEqual(lines.map(\.amountMinorUnits), [1_000])
        XCTAssertEqual(lines.map(\.daysInTenancy), [nil])
        XCTAssertEqual(lines.map(\.note), [nil])
        XCTAssertEqual(preview, saved)
        XCTAssertTrue(saved.body.contains("• Electricity (Example Power) — invoice of 03/04/2024, 01/02/2024 – 31/03/2024: €10.00"), saved.body)
        XCTAssertFalse(saved.body.contains("days in the tenancy"), saved.body)
        // Nor, in English, inside the Portuguese email.
        let portuguese = try db.read { db in try RechargeEmail.draft(db: db, statementId: statementId, language: .portuguese) }
        XCTAssertTrue(portuguese.body.contains("31/03/2024: 10,00"), portuguese.body)
        XCTAssertFalse(portuguese.body.contains("days in the tenancy") || portuguese.body.contains("dias no contrato"), portuguese.body)
    }

    func testAnInvoiceEditCappingADraftLineDropsItsProration() throws {
        // The draft takes the prorated share (17.00 of 60.00, 17 of 60 days); another
        // tenancy's draft takes the 43.00 left; the invoice is then corrected to 50.00: the
        // share would be 14.17, but only 7.00 is left, so the line is capped and no longer
        // the prorated share.
        let invoiceId = try invoice("power", "P-1", issued: Self.date(2024, 4, 3), amount: 6_000,
                                    period: (Self.date(2024, 2, 1), Self.date(2024, 3, 31)))
        let april = Self.date(2024, 4, 1)
        let statementId = try db.write { db in try Recharges.draftStatement(db: db, tenancyId: id("tenancy"), month: april).id! }
        var lines = try db.read { db in try Recharges.lines(db: db, statementId: statementId) }
        XCTAssertEqual(lines.map(\.amountMinorUnits), [1_700])
        XCTAssertEqual(lines.map(\.daysInTenancy), [17])
        XCTAssertEqual(lines.map(\.note), ["17 of 60 days in the tenancy"])
        try db.write { db in
            var other = Tenancy(propertyId: id("property"), referenceLabel: "Other", startDate: Self.date(2024, 1, 1))
            try Tenancies.save(db: db, &other)
            let theirs = try Recharges.draftStatement(db: db, tenancyId: other.id!, month: april, addPending: false)
            try Recharges.setLine(db: db, statementId: theirs.id!, invoiceId: invoiceId, amountMinorUnits: 4_300)
            var invoice = try XCTUnwrap(try UtilityInvoice.fetchOne(db, key: invoiceId))
            invoice.amountMinorUnits = 5_000
            try Recharges.saveInvoice(db: db, &invoice)
        }
        lines = try db.read { db in try Recharges.lines(db: db, statementId: statementId) }
        XCTAssertEqual(lines.map(\.amountMinorUnits), [700])
        XCTAssertEqual(lines.map(\.daysInTenancy), [nil])
        XCTAssertEqual(lines.map(\.daysInPeriod), [nil])
        XCTAssertEqual(lines.map(\.note), [nil])
        // The emails say the amount without a proration that isn't this line's.
        let (english, portuguese) = try db.read { db in
            (try RechargeEmail.draft(db: db, statementId: statementId, language: .english),
             try RechargeEmail.draft(db: db, statementId: statementId, language: .portuguese))
        }
        XCTAssertTrue(english.body.contains("• Electricity (Example Power) — invoice of 03/04/2024, 01/02/2024 – 31/03/2024: €7.00"), english.body)
        XCTAssertTrue(portuguese.body.contains("• Luz (Example Power) — fatura de 03/04/2024, 01/02/2024 – 31/03/2024: 7,00"), portuguese.body)
        XCTAssertFalse(english.body.contains("days in the tenancy"), english.body)
        XCTAssertFalse(portuguese.body.contains("days in the tenancy") || portuguese.body.contains("dias no contrato"), portuguese.body)
    }

    func testOverviewAndNextMonth() throws {
        _ = try payAprilWithMayRent()
        try db.read { db in
            let rows = try Recharges.overview(db: db, tenancyId: id("tenancy"))
            XCTAssertEqual(rows.map(\.statement.status), [.paid])
            XCTAssertEqual(rows.first?.outstandingMinorUnits, 0)
            XCTAssertEqual(rows.first?.payments.map(\.amountMinorUnits), [2_700])
            XCTAssertEqual(try Recharges.nextMonth(db: db, tenancyId: id("tenancy"), today: Self.date(2024, 9, 3)), Self.date(2024, 5, 1))
        }
    }

    func testRoundedTransfersAreSuggestions() throws {
        try seedInvoices()
        let statementId = try db.write { db -> Int64 in
            let statement = try Recharges.draftStatement(db: db, tenancyId: id("tenancy"), month: Self.date(2024, 4, 1))
            return try Recharges.markSent(db: db, statementId: statement.id!, at: Self.date(2024, 4, 30)).id!
        }
        let credit = try transaction("rent", Self.date(2024, 5, 2), 102_800)
        try db.write { db in
            _ = try RentReceiptMatching.match(db: db, propertyId: id("property"))
            XCTAssertEqual(try Recharges.matchPayments(db: db, propertyId: id("property")), [])
            let suggestions = try Recharges.paymentSuggestions(db: db, propertyId: id("property"))
            XCTAssertEqual(suggestions.map(\.transaction.id), [credit])
            XCTAssertEqual(suggestions.first?.amountMinorUnits, 2_700)
            XCTAssertEqual(suggestions.first?.differenceMinorUnits, 100)
            try Recharges.linkPayment(db: db, statementId: statementId, transactionId: credit, amountMinorUnits: 2_700)
            XCTAssertEqual(try Recharges.paymentSuggestions(db: db, propertyId: id("property")), [])
        }
    }

    func testAnInvoiceMovedToAnotherPropertysProviderLeavesTheDraft() throws {
        let invoiceId = try invoice("water", "W-1", issued: Self.date(2024, 4, 20), amount: 1_000)
        try db.write { db in
            let statement = try Recharges.draftStatement(db: db, tenancyId: id("tenancy"), month: Self.date(2024, 4, 1))
            var other = Property(name: "Property B", country: "PT")
            try Properties.save(db: db, &other)
            var provider = UtilityProvider(propertyId: other.id!, name: "Example Water", kind: .water)
            try Recharges.saveProvider(db: db, &provider)
            var invoice = try XCTUnwrap(try UtilityInvoice.fetchOne(db, key: invoiceId))
            invoice.providerId = provider.id!
            try Recharges.saveInvoice(db: db, &invoice)
            XCTAssertEqual(try Recharges.lines(db: db, statementId: statement.id!), [])
            XCTAssertEqual(try RechargeStatement.fetchOne(db, key: statement.id!)?.totalMinorUnits, 0)
        }
    }

    // MARK: Statement review fixes

    func testUnlinkingAnAutoMatchSticks() throws {
        let (statementId, creditId) = try payAprilWithMayRent()
        try db.write { db in
            XCTAssertTrue(try Recharges.unlinkPayment(db: db, statementId: statementId, transactionId: creditId))
            XCTAssertEqual(try Recharges.matchPayments(db: db, propertyId: id("property")), [])
            XCTAssertEqual(try Recharges.outstanding(db: db, statementId: statementId), 2_700)
            XCTAssertEqual(try Recharges.received(db: db, propertyId: id("property")), [])
            XCTAssertEqual(try Recharges.overview(db: db, tenancyId: id("tenancy")).first?.payments, [])
            // Not suggested again either; linking it by hand revives the link.
            XCTAssertEqual(try Recharges.paymentSuggestions(db: db, propertyId: id("property")), [])
            try Recharges.linkPayment(db: db, statementId: statementId, transactionId: creditId)
            XCTAssertEqual(try RechargeStatement.fetchOne(db, key: statementId)?.status, .paid)
            XCTAssertEqual(try Recharges.paymentSuggestions(db: db, propertyId: id("property")), [])
        }
    }

    func testTenantEmailsAreValidated() throws {
        try db.write { db in
            var tenancy = try XCTUnwrap(try Tenancy.fetchOne(db, key: id("tenancy")))
            tenancy.tenantEmail = "Tenant B <tenant@example.com>; other@example.com"
            try Tenancies.save(db: db, &tenancy)
            XCTAssertEqual(tenancy.tenantEmail, "tenant@example.com, other@example.com")
            XCTAssertEqual(Tenancies.emailAddresses(tenancy), ["tenant@example.com", "other@example.com"])
            tenancy.tenantEmail = "tenant at example"
            XCTAssertThrowsError(try Tenancies.save(db: db, &tenancy)) { XCTAssertEqual($0 as? PropertyError, .invalidEmail("tenant at example")) }
        }
    }

    func testRefundStatementsAndNamelessTenantsReadWell() throws {
        try invoice("water", "W-R", issued: Self.date(2024, 4, 20), amount: -500)
        let statementId = try db.write { db in try Recharges.draftStatement(db: db, tenancyId: id("tenancy"), month: Self.date(2024, 4, 1)).id! }
        let draft = try db.read { db in try RechargeEmail.draft(db: db, statementId: statementId, language: .portuguese) }
        XCTAssertTrue(draft.body.hasPrefix("Olá,"), draft.body)
        XCTAssertTrue(draft.body.contains("Valor a devolver (a descontar na próxima transferência da renda): 5,00"), draft.body)
        XCTAssertTrue(draft.body.contains("(água)"), draft.body)
    }

    func testDraftsCanStartEmptyAndPendingIsCapped() throws {
        let invoiceId = try invoice("water", "W-1", issued: Self.date(2024, 4, 20), amount: 1_000)
        try db.write { db in
            let empty = try Recharges.draftStatement(db: db, tenancyId: id("tenancy"), month: Self.date(2024, 4, 1), addPending: false)
            XCTAssertEqual(try Recharges.lines(db: db, statementId: empty.id!), [])
            // Another tenancy already took 600 of it: 400 pending here.
            var other = Tenancy(propertyId: id("property"), referenceLabel: "Other", startDate: Self.date(2024, 1, 1))
            try Tenancies.save(db: db, &other)
            let theirs = try Recharges.draftStatement(db: db, tenancyId: other.id!, month: Self.date(2024, 4, 1), addPending: false)
            try Recharges.setLine(db: db, statementId: theirs.id!, invoiceId: invoiceId, amountMinorUnits: 600)
            XCTAssertEqual(try Recharges.pendingLines(db: db, tenancyId: id("tenancy"), through: Self.date(2024, 4, 30)).map(\.amountMinorUnits), [400])
        }
    }

    func testManualLinesDontBreakPendingInvoices() throws {
        try seedInvoices()
        try db.write { db in
            let april = try Recharges.draftStatement(db: db, tenancyId: id("tenancy"), month: Self.date(2024, 4, 1))
            try Recharges.saveManualLine(db: db, statementId: april.id!, description: "One-off", amountMinorUnits: 100)
            XCTAssertEqual(try Recharges.pendingLines(db: db, tenancyId: id("tenancy"), through: Self.date(2024, 5, 31)).map(\.amountMinorUnits), [-500])
        }
    }


    // MARK: Audit fixes

    func testALateDebitDoesNotDateTheRecharge() throws {
        // Debited 58 days after it was issued: it's recharged by its issue date.
        let late = try transaction("utilities", Self.date(2024, 6, 14), -3_500, "EXAMPLE POWER")
        try invoice("power", "P-late", issued: Self.date(2024, 4, 17), amount: 3_500, debit: late)
        // Debited 31 days after: the debit dates it, as before.
        let usual = try transaction("utilities", Self.date(2024, 5, 18), -2_000, "EXAMPLE POWER")
        try invoice("power", "P-usual", issued: Self.date(2024, 4, 17), amount: 2_000, debit: usual)
        let april = try db.read { db in try Recharges.pendingLines(db: db, tenancyId: id("tenancy"), through: Self.date(2024, 4, 30)) }
        XCTAssertEqual(april.map(\.invoice.invoiceNumber), ["P-late"])
        XCTAssertEqual(april.map(\.rechargeDate), [Self.date(2024, 4, 17)])
        let may = try db.read { db in try Recharges.pendingLines(db: db, tenancyId: id("tenancy"), through: Self.date(2024, 5, 31)) }
        XCTAssertEqual(may.map(\.rechargeDate), [Self.date(2024, 4, 17), Self.date(2024, 5, 18)])
    }

    func testAResetKeepsOneOffLinesAndDropsRoundingAndPayments() throws {
        let (statementId, creditId) = try payAprilWithMayRent()
        let refund = try transaction("repairs", Self.date(2024, 4, 18), 500, "SHOP REFUND")
        try db.write { db in
            try Recharges.unlinkPayment(db: db, statementId: statementId, transactionId: creditId)
            try Recharges.reopen(db: db, statementId: statementId)
            let oneOff = try Recharges.saveManualLine(db: db, statementId: statementId, description: "Dishwasher refund", amountMinorUnits: -500,
                                                      transactionId: refund)
            XCTAssertEqual(oneOff.transactionId, refund)
            XCTAssertTrue(oneOff.isOneOff)
            let rounding = try Recharges.saveManualLine(db: db, statementId: statementId, description: "Rounding: the transfer was €0.01 more",
                                                        amountMinorUnits: 1, isRounding: true)
            XCTAssertFalse(rounding.isOneOff)
            XCTAssertThrowsError(try Recharges.saveManualLine(db: db, statementId: statementId, description: "X", amountMinorUnits: 1,
                                                              transactionId: 999_999)) {
                XCTAssertEqual($0 as? RechargeError, .transactionNotFound)
            }
            try Recharges.markSent(db: db, statementId: statementId, at: Self.date(2024, 4, 30))
            try Recharges.linkPayment(db: db, statementId: statementId, transactionId: creditId, amountMinorUnits: 1_000)

            let kept = try Recharges.resetStatement(db: db, statementId: statementId)
            XCTAssertEqual(kept.map(\.lineDescription), ["Dishwasher refund"])
            let statement = try XCTUnwrap(try RechargeStatement.fetchOne(db, key: statementId))
            XCTAssertEqual(statement.status, .draft)
            XCTAssertNil(statement.sentAt)
            XCTAssertEqual(statement.totalMinorUnits, -500)
            XCTAssertEqual(try RechargePayment.filter(Column("statementId") == statementId).fetchCount(db), 0)
            // The invoices are pending again.
            XCTAssertEqual(try Recharges.pendingLines(db: db, tenancyId: id("tenancy"), through: Self.date(2024, 4, 30)).count, 2)
        }
    }


    func testEditingAManualLineKeepsWhatIsntPassed() throws {
        try seedInvoices()
        let debit = try transaction("utilities", Self.date(2024, 4, 18), -700, "EXAMPLE POWER")
        try db.write { db in
            let statement = try Recharges.draftStatement(db: db, tenancyId: id("tenancy"), month: Self.date(2024, 4, 1))
            let rounding = try Recharges.saveManualLine(db: db, statementId: statement.id!, description: "Rounding: the transfer was €0.01 more",
                                                        amountMinorUnits: 1, note: "cents", isRounding: true)
            let linked = try Recharges.saveManualLine(db: db, statementId: statement.id!, description: "Invoice to come", amountMinorUnits: 700,
                                                      note: "from the portal", transactionId: debit)
            // As the statement sheet saves them: description and amount only.
            let editedRounding = try Recharges.saveManualLine(db: db, statementId: statement.id!, lineId: rounding.id, description: "Rounding",
                                                              amountMinorUnits: 2)
            XCTAssertTrue(editedRounding.isRounding)
            XCTAssertEqual(editedRounding.note, "cents")
            let editedLinked = try Recharges.saveManualLine(db: db, statementId: statement.id!, lineId: linked.id, description: "Invoice to come",
                                                            amountMinorUnits: 710)
            XCTAssertEqual(editedLinked.transactionId, debit)
            XCTAssertEqual(editedLinked.note, "from the portal")
            XCTAssertFalse(editedLinked.isRounding)
            XCTAssertEqual(try RechargeLine.fetchOne(db, key: linked.id!)?.transactionId, debit)
        }
    }
}
