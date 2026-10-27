import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// The Recharges tab's year figures (user, 2026-10-27): recharged vs what the bank paid for the
/// bills on the same statements, by statement month. Synthetic fixtures for each artefact the
/// old figures showed: a bill netted with a credit, a line with no invoice linked to its debit,
/// a December debit on January's statement, and a rounding line (the only difference left).
final class RechargeYearFiguresTests: XCTestCase {
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
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            ids["property"] = property.id!
            var account = Account(name: "Bank A", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "bank.csv", importedAt: Date())
            try batch.insert(db)
            ids["bank"] = account.id!
            ids["batch"] = batch.id!
            var tenancy = Tenancy(propertyId: property.id!, referenceLabel: "Room Contract AB", contractNumber: "3001",
                                  startDate: Self.date(2024, 1, 1))
            try Tenancies.save(db: db, &tenancy)
            ids["tenancy"] = tenancy.id!
            for (key, name, kind) in [("water", "Example Water", UtilityKind.water), ("gas", "Example Gas", .gas)] {
                var provider = UtilityProvider(propertyId: property.id!, name: name, kind: kind)
                try Recharges.saveProvider(db: db, &provider)
                ids[key] = provider.id!
            }
        }
    }

    private func movement(_ date: Date, _ amount: Int) throws -> Int64 {
        try db.write { db in
            var transaction = Transaction(importBatchId: id("batch"), accountId: id("bank"), date: date, rawDescription: "UTILITY",
                                          amountMinorUnits: amount, categoryId: nil, status: .confirmed, categorizedBy: .manual,
                                          fingerprint: UUID().uuidString)
            try transaction.insert(db)
            return transaction.id!
        }
    }

    private func invoice(_ provider: String, issued: Date, amount: Int, debit: Int64?) throws -> Int64 {
        try db.write { db in
            var invoice = UtilityInvoice(providerId: id(provider), issueDate: issued, amountMinorUnits: amount, transactionId: debit)
            try Recharges.saveInvoice(db: db, &invoice)
            return invoice.id!
        }
    }

    /// A sent statement for the month with the lines as given; its total is their sum.
    @discardableResult
    private func statement(_ month: Date, _ lines: [RechargeLine]) throws -> Int64 {
        try db.write { db in
            var statement = RechargeStatement(tenancyId: id("tenancy"), month: month, totalMinorUnits: lines.reduce(0) { $0 + $1.amountMinorUnits },
                                              status: .sent, sentAt: month)
            try statement.insert(db)
            for var line in lines {
                line.statementId = statement.id!
                try line.insert(db)
            }
            return statement.id!
        }
    }

    private func line(invoice: Int64, _ amount: Int) -> RechargeLine {
        RechargeLine(statementId: 0, invoiceId: invoice, amountMinorUnits: amount)
    }

    private func manual(_ text: String, _ amount: Int, debit: Int64? = nil, rounding: Bool = false) -> RechargeLine {
        RechargeLine(statementId: 0, invoiceId: nil, lineDescription: text, amountMinorUnits: amount, isRounding: rounding, transactionId: debit)
    }

    private func figures(_ year: Int) throws -> RechargeYearFigures {
        try XCTUnwrap(try db.read { db in try Recharges.yearFigures(db: db, tenancyId: id("tenancy")) }[year])
    }

    func testABillNettedWithACreditCountsWhatTheBankPaid() throws {
        // The invoice charges 131.14; the provider netted a 126.75 restitution, so the bank paid 4.39.
        let debit = try movement(Self.date(2025, 3, 20), -439)
        let bill = try invoice("water", issued: Self.date(2025, 3, 1), amount: 13_114, debit: debit)
        try statement(Self.date(2025, 3, 1), [line(invoice: bill, 13_114), manual("Restitution", -12_675, debit: debit)])
        let year = try figures(2025)
        XCTAssertEqual(year.recharged, 439)
        XCTAssertEqual(year.billsPaid, 439)
        XCTAssertEqual(year.difference, 0)
        XCTAssertEqual(year.gaps, [])
    }

    func testALineWithNoInvoiceLinkedToItsDebitIsPaid() throws {
        let first = try movement(Self.date(2026, 2, 10), -4_288)
        let second = try movement(Self.date(2026, 3, 10), -3_868)
        try statement(Self.date(2026, 2, 1), [manual("Gas February", 4_288, debit: first)])
        try statement(Self.date(2026, 3, 1), [manual("Gas March", 3_868, debit: second)])
        let year = try figures(2026)
        XCTAssertEqual(year.statements, 2)
        XCTAssertEqual(year.recharged, 8_156)
        XCTAssertEqual(year.billsPaid, 8_156)
        XCTAssertEqual(year.difference, 0)
    }

    func testADecemberDebitOnJanuarysStatementCountsInJanuarysYear() throws {
        let debit = try movement(Self.date(2024, 12, 31), -2_500)
        let bill = try invoice("water", issued: Self.date(2024, 12, 12), amount: 2_500, debit: debit)
        try statement(Self.date(2025, 1, 1), [line(invoice: bill, 2_500)])
        let all = try db.read { db in try Recharges.yearFigures(db: db, tenancyId: id("tenancy")) }
        XCTAssertNil(all[2024])
        XCTAssertEqual(all[2025]?.billsPaid, 2_500)
        XCTAssertEqual(all[2025]?.difference, 0)
    }

    func testARoundingLineIsTheOnlyDifference() throws {
        let debit = try movement(Self.date(2026, 1, 15), -5_008)
        let bill = try invoice("gas", issued: Self.date(2025, 12, 20), amount: 5_008, debit: debit)
        let january = try statement(Self.date(2026, 1, 1), [line(invoice: bill, 5_008), manual("Rounding", -8, rounding: true)])
        let year = try figures(2026)
        XCTAssertEqual(year.recharged, 5_000)
        XCTAssertEqual(year.billsPaid, 5_008)
        XCTAssertEqual(year.difference, -8)
        XCTAssertEqual(year.gaps, [.init(statementId: january, month: Self.date(2026, 1, 1), reason: .rounding, amountMinorUnits: -8, lines: 1)])
    }

    func testAllArtefactsTogetherLeaveOnlyTheRounding() throws {
        // 2025: a December 2024 debit on January's statement, and a netted bill in March.
        let decDebit = try movement(Self.date(2024, 12, 31), -1_200)
        let decBill = try invoice("water", issued: Self.date(2024, 12, 10), amount: 1_200, debit: decDebit)
        try statement(Self.date(2025, 1, 1), [line(invoice: decBill, 1_200)])
        let netted = try movement(Self.date(2025, 3, 20), -439)
        let gross = try invoice("water", issued: Self.date(2025, 3, 1), amount: 13_114, debit: netted)
        try statement(Self.date(2025, 3, 1), [line(invoice: gross, 13_114), manual("Restitution", -12_675, debit: netted)])
        // 2026: gas lines without invoices, and the rounding.
        let gas = try movement(Self.date(2026, 1, 12), -4_288)
        let waterDebit = try movement(Self.date(2026, 1, 20), -1_008)
        let water = try invoice("water", issued: Self.date(2026, 1, 2), amount: 1_008, debit: waterDebit)
        try statement(Self.date(2026, 1, 1), [manual("Gas", 4_288, debit: gas), line(invoice: water, 1_008), manual("Rounding", -8, rounding: true)])
        XCTAssertEqual(try figures(2025).difference, 0)
        XCTAssertEqual(try figures(2025).gaps, [])
        let year = try figures(2026)
        XCTAssertEqual(year.difference, -8)
        XCTAssertEqual(year.gaps.map(\.reason), [.rounding])
    }

    func testLinesWithNoBankMovementAreNamed() throws {
        let bill = try invoice("water", issued: Self.date(2026, 4, 2), amount: 3_000, debit: nil)
        let april = try statement(Self.date(2026, 4, 1), [line(invoice: bill, 3_000), manual("Repair", 2_000)])
        let year = try figures(2026)
        XCTAssertEqual(year.billsPaid, 0)
        XCTAssertEqual(year.gaps, [.init(statementId: april, month: Self.date(2026, 4, 1), reason: .noPayment, amountMinorUnits: 5_000, lines: 1)])
    }

    func testDraftsAndProratedLines() throws {
        let debit = try movement(Self.date(2026, 5, 20), -6_000)
        let bill = try invoice("water", issued: Self.date(2026, 5, 1), amount: 6_000, debit: debit)
        // A prorated share takes the same share of the debit.
        try statement(Self.date(2026, 5, 1), [line(invoice: bill, 1_700)])
        try db.write { db in
            var draft = RechargeStatement(tenancyId: id("tenancy"), month: Self.date(2026, 6, 1), totalMinorUnits: 999)
            try draft.insert(db)
        }
        let year = try figures(2026)
        XCTAssertEqual(year.statements, 1)
        XCTAssertEqual(year.recharged, 1_700)
        XCTAssertEqual(year.billsPaid, 1_700)
    }
}
