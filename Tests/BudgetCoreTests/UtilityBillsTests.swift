import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// The utility bills tracker's stages (small batch item 1): one synthetic EUR property, a
/// tenancy from 1 January 2025, an electricity and a water provider.
final class UtilityBillsTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var ids: [String: Int64] = [:]

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
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
            ids["utilities"] = utilities.id!
            ids["rent"] = rent.id!
            try TaxExpenseTypeMap.seed(db: db, propertyId: p)
            var tenancy = Tenancy(propertyId: p, referenceLabel: "Room A", contractNumber: "1", startDate: Self.date(2025, 1, 1))
            try Tenancies.save(db: db, &tenancy)
            ids["tenancy"] = tenancy.id!
            var power = UtilityProvider(propertyId: p, name: "Example Power", kind: .electricity, bankDescriptionPattern: "EXAMPLE POWER")
            try Recharges.saveProvider(db: db, &power)
            var water = UtilityProvider(propertyId: p, name: "Example Water", kind: .water, bankDescriptionPattern: "EXAMPLE WATER")
            try Recharges.saveProvider(db: db, &water)
            ids["power"] = power.id!
            ids["water"] = water.id!
        }
    }

    @discardableResult
    private func transaction(_ date: Date, _ amount: Int, _ text: String, category: String? = "utilities") throws -> Int64 {
        try db.write { db in
            var t = Transaction(importBatchId: ids["batch"]!, accountId: ids["bank"]!, date: date, rawDescription: text, amountMinorUnits: amount,
                                categoryId: category.flatMap { ids[$0] }, status: .confirmed, categorizedBy: .manual, fingerprint: UUID().uuidString)
            try t.insert(db)
            return t.id!
        }
    }

    @discardableResult
    private func invoice(_ provider: String, issued: Date, amount: Int, paidBy: Int64? = nil) throws -> Int64 {
        try db.write { db in
            var invoice = UtilityInvoice(providerId: self.ids[provider]!, issueDate: issued, amountMinorUnits: amount, transactionId: paidBy)
            try Recharges.saveInvoice(db: db, &invoice)
            return invoice.id!
        }
    }

    private func read() throws -> UtilityBillsGrid {
        try db.read { try UtilityBills.read(db: $0, propertyId: ids["property"]!, tenancyId: ids["tenancy"]!) }
    }

    private func stages() throws -> [UtilityBillStage] { try read().bills.map(\.stage) }

    func testPaymentWithoutInvoiceIsMissing() throws {
        try transaction(Self.date(2025, 2, 5), -8_000, "EXAMPLE POWER DD")
        try transaction(Self.date(2025, 2, 6), -1_000, "Mystery utility")
        try transaction(Self.date(2025, 2, 7), -5_000, "Groceries", category: nil)
        let grid = try read()
        XCTAssertEqual(grid.bills.map(\.stage), [.missingInvoice, .missingInvoice])
        XCTAssertEqual(grid.rows.map(\.name), ["Example Power", "Other utilities"])
        XCTAssertEqual(grid.summaryText, "2 bills need invoices")
    }

    func testInvoiceStagesThroughToPaid() throws {
        // Invoice in, no payment.
        let id = try invoice("power", issued: Self.date(2025, 2, 1), amount: 8_000)
        XCTAssertEqual(try stages(), [.invoiceIn])
        // Linked to its payment: no longer a missing invoice.
        let debit = try transaction(Self.date(2025, 2, 5), -8_000, "EXAMPLE POWER DD")
        try db.write { db in
            var invoice = try UtilityInvoice.fetchOne(db, key: id)!
            invoice.transactionId = debit
            try Recharges.saveInvoice(db: db, &invoice)
        }
        XCTAssertEqual(try stages(), [.linkedToPayment])
        // In a draft statement: prep done.
        let statement = try db.write { try Recharges.draftStatement(db: $0, tenancyId: self.ids["tenancy"]!, month: Self.date(2025, 2, 1)) }
        XCTAssertEqual(try stages(), [.inRecharge])
        XCTAssertEqual(try read().summaryText, "1 ready to send")
        // Sent.
        try db.write { _ = try Recharges.markSent(db: $0, statementId: statement.id!, at: Self.date(2025, 3, 1)) }
        XCTAssertEqual(try stages(), [.sentToTenant])
        XCTAssertEqual(try read().summaryText, "1 waiting for the tenant")
        // Part paid stays sent, flagged.
        let credit1 = try transaction(Self.date(2025, 3, 5), 3_000, "TENANT", category: "rent")
        try db.write { _ = try Recharges.linkPayment(db: $0, statementId: statement.id!, transactionId: credit1, amountMinorUnits: 3_000) }
        var bill = try read().bills[0]
        XCTAssertEqual(bill.stage, .sentToTenant)
        XCTAssertTrue(bill.isPartiallyPaid)
        XCTAssertEqual(bill.tenantPaidMinorUnits, 3_000)
        // Fully paid: reconciled.
        let credit2 = try transaction(Self.date(2025, 3, 6), 5_000, "TENANT", category: "rent")
        try db.write { _ = try Recharges.linkPayment(db: $0, statementId: statement.id!, transactionId: credit2) }
        bill = try read().bills[0]
        XCTAssertEqual(bill.stage, .paidByTenant)
        XCTAssertFalse(bill.isPartiallyPaid)
        XCTAssertEqual(try read().summaryText, "All bills are settled")
    }

    func testLinkedPaymentIsNotAlsoMissing() throws {
        let debit = try transaction(Self.date(2025, 2, 5), -8_000, "EXAMPLE POWER DD")
        try invoice("power", issued: Self.date(2025, 2, 1), amount: 8_000, paidBy: debit)
        XCTAssertEqual(try stages(), [.linkedToPayment])
    }

    func testMultipleProvidersAndCellTakesLeastAdvanced() throws {
        let d1 = try transaction(Self.date(2025, 2, 5), -8_000, "EXAMPLE POWER DD")
        try invoice("power", issued: Self.date(2025, 2, 1), amount: 8_000, paidBy: d1)
        try invoice("water", issued: Self.date(2025, 2, 2), amount: 2_000)
        try transaction(Self.date(2025, 2, 20), -1_500, "EXAMPLE WATER DD")
        let grid = try read()
        XCTAssertEqual(grid.rows.map(\.name), ["Example Power", "Example Water"])
        let feb = Self.date(2025, 2, 1)
        XCTAssertEqual(grid.cell(row: grid.rows[0], month: feb)?.stage, .linkedToPayment)
        // Water: an invoice with no payment and a payment with no invoice in the same month.
        XCTAssertEqual(grid.cell(row: grid.rows[1], month: feb)?.bills.count, 2)
        XCTAssertEqual(grid.cell(row: grid.rows[1], month: feb)?.stage, .missingInvoice)
        XCTAssertNil(grid.cell(row: grid.rows[0], month: Self.date(2025, 3, 1)))
        XCTAssertEqual(grid.summaryText, "1 bill needs an invoice · 1 invoice waits for its payment · 1 bill to add to a recharge")
        XCTAssertEqual(grid.years, [2025])
    }

    func testBillsBeforeTheTenancyAreLeftOut() throws {
        try transaction(Self.date(2024, 11, 5), -8_000, "EXAMPLE POWER DD")
        XCTAssertTrue(try read().bills.isEmpty)
        XCTAssertEqual(try read().summaryText, "No utility bills yet")
    }
}
