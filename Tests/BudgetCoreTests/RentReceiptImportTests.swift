import XCTest
import GRDB
@testable import BudgetCore

/// The Portal das Finanças rent-receipts export (spec 2026-10-16 §6.1): parsing, importing
/// into tenancies and receipts, and matching receipts to the bank credits that paid them.
/// Synthetic exports and names only.
final class RentReceiptImportTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var propertyId: Int64!

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        propertyId = try db.write { db in
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            return property.id!
        }
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    static let header = ["Referência", "Nº de Contrato", "Nº de Recibo", "Locador", "Locatário", "Data de Início", "Data de Fim",
                         "Data de Rec.", "Valor (€)", "Retenção IRS (€)", "Importância recebida (€)", "Imóvel", "Estado"]

    /// A receipt row as the portal writes it: dates as text, numbers as number cells.
    struct ExportRow {
        var reference = "Room Contract AB"
        var contract = "1001"
        var receipt: String
        var tenant = "Tenant B"
        var start: String
        var end: String
        var received: String? = nil
        var amount = "1100"
        var withholding = "0"
        var status = "Emitido"
    }

    static func export(_ rows: [ExportRow]) -> Data {
        let cells: [[XLSXTestWriter.Cell]] = [header.map { .text($0) }] + rows.map { row in
            [.text(row.reference), .number(row.contract), .number(row.receipt), .empty, .text(row.tenant), .text(row.start), .text(row.end),
             row.received.map { .text($0) } ?? .empty, .number(row.amount), .number(row.withholding),
             .number(String((Decimal(string: row.amount)! - Decimal(string: row.withholding)!).description)),
             .text("Cidade - Fração X"), .text(row.status)]
        }
        return XLSXTestWriter.workbook(sheetName: "ListaRecibos", rows: cells)
    }

    private func month(_ contract: String, _ receipt: String, _ y: Int, _ m: Int, amount: String = "1100", status: String = "Emitido",
                       received: Bool = true) -> ExportRow {
        let (start, _) = MonthRange.of(year: y, month: m)
        let last = MonthRange.calendar.date(byAdding: .day, value: -1, to: MonthRange.calendar.date(byAdding: .month, value: 1, to: start)!)!
        func iso(_ d: Date) -> String {
            let c = MonthRange.calendar.dateComponents([.year, .month, .day], from: d)
            return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        }
        return ExportRow(contract: contract, receipt: receipt, start: iso(start), end: iso(last),
                         received: received ? String(format: "%04d-%02d-03", y, m) : nil, amount: amount, status: status)
    }

    private func importRows(_ rows: [ExportRow]) throws -> RentReceiptImport.Report {
        let parsed = try RentReceiptsExport.parse(xlsx: Self.export(rows))
        return try db.write { db in try RentReceiptImport.run(db: db, propertyId: propertyId, rows: parsed) }
    }

    // MARK: Parsing

    func testParsesThePortalLayout() throws {
        let rows = try RentReceiptsExport.parse(xlsx: Self.export([
            ExportRow(receipt: "1", start: "2025-01-01", end: "2025-01-31", received: "2024-12-30", amount: "777.77", withholding: "194.44"),
            ExportRow(receipt: "2", start: "2025-02-01", end: "2025-02-28", received: nil, status: "Anulado")
        ]))
        XCTAssertEqual(rows.count, 2)
        let first = rows[0]
        XCTAssertEqual(first.rowNumber, 2)
        XCTAssertEqual(first.reference, "Room Contract AB")
        XCTAssertEqual(first.contractNumber, "1001")
        XCTAssertEqual(first.receiptNumber, "1")
        XCTAssertNil(first.landlord)
        XCTAssertEqual(first.tenant, "Tenant B")
        XCTAssertEqual(first.periodStart, Self.date(2025, 1, 1))
        XCTAssertEqual(first.periodEnd, Self.date(2025, 1, 31))
        XCTAssertEqual(first.receiptDate, Self.date(2024, 12, 30))
        XCTAssertEqual(first.amountMinorUnits, 77_777)
        XCTAssertEqual(first.withholdingMinorUnits, 19_444)
        XCTAssertEqual(first.amountReceivedMinorUnits, 58_333)
        XCTAssertEqual(first.property, "Cidade - Fração X")
        XCTAssertEqual(first.status, .issued)
        XCTAssertNil(rows[1].receiptDate)
        XCTAssertEqual(rows[1].status, .cancelled)
    }

    func testValueFormats() {
        XCTAssertEqual(RentReceiptsExport.parseAmount("123.4"), 12_340)
        XCTAssertEqual(RentReceiptsExport.parseAmount("1.100,00 €"), 110_000)
        XCTAssertEqual(RentReceiptsExport.parseAmount("777.7699999999999"), 77_777)
        XCTAssertNil(RentReceiptsExport.parseAmount("12abc"))
        XCTAssertEqual(RentReceiptsExport.parseDate("31/01/2025"), Self.date(2025, 1, 31))
        XCTAssertEqual(RentReceiptsExport.parseDate("2025-01-31 00:00:00"), Self.date(2025, 1, 31))
        XCTAssertEqual(RentReceiptsExport.parseDate("45658"), Self.date(2025, 1, 1))
        XCTAssertNil(RentReceiptsExport.parseDate("2025-02-30"))
        XCTAssertEqual(RentReceiptsExport.normalisedHeader("Nº de Contrato"), "nodecontrato")
        XCTAssertEqual(RentReceiptsExport.normalisedHeader("Retenção IRS (€)"), "retencaoirs")
        XCTAssertEqual(RentReceiptsExport.numberText("50.0"), "50")
    }

    func testParseErrors() throws {
        let noHeader = XLSXTestWriter.workbook(rows: [[.text("Something else")]])
        XCTAssertThrowsError(try RentReceiptsExport.parse(xlsx: noHeader)) {
            guard case .missingColumns = $0 as? RentReceiptsExport.ExportError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try RentReceiptsExport.parse(xlsx: Self.export([ExportRow(receipt: "1", start: "2025-01-01", end: "x")]))) {
            XCTAssertEqual($0 as? RentReceiptsExport.ExportError, .badValue(row: 2, column: "Data de Fim", value: "x"))
        }
        XCTAssertThrowsError(try RentReceiptsExport.parse(xlsx: Self.export([ExportRow(receipt: "1", start: "2025-01-01", end: "2025-01-31", status: "Pendente")]))) {
            XCTAssertEqual($0 as? RentReceiptsExport.ExportError, .badValue(row: 2, column: "Estado", value: "Pendente"))
        }
        let duplicate = ExportRow(receipt: "1", start: "2025-01-01", end: "2025-01-31")
        XCTAssertThrowsError(try RentReceiptsExport.parse(xlsx: Self.export([duplicate, duplicate]))) {
            XCTAssertEqual($0 as? RentReceiptsExport.ExportError, .duplicateReceipt(row: 3, contractNumber: "1001", receiptNumber: "1"))
        }
    }

    func testTitleRowsAboveTheHeaderAndBlankRowsAreSkipped() throws {
        var cells: [[XLSXTestWriter.Cell]] = [[.text("Lista de recibos")], []]
        cells.append(Self.header.map { .text($0) })
        cells.append([.text("R"), .number("7"), .number("1"), .empty, .empty, .text("01/03/2025"), .text("31/03/2025"), .empty,
                      .number("100"), .empty, .empty, .empty, .text("Emitido")])
        cells.append([])
        let rows = try RentReceiptsExport.parse(xlsx: XLSXTestWriter.workbook(rows: cells))
        XCTAssertEqual(rows.map(\.receiptNumber), ["1"])
        XCTAssertEqual(rows[0].rowNumber, 4)
        XCTAssertEqual(rows[0].amountReceivedMinorUnits, 10_000)
    }

    // MARK: Import

    func testImportCreatesTenanciesAndReceiptsAndIsIdempotent() throws {
        let rows = [
            month("2001", "1", 2020, 1, amount: "1850"), month("2001", "2", 2020, 2, amount: "1850"),
            month("3001", "1", 2023, 3), month("3001", "2", 2023, 4), month("3001", "3", 2023, 5, status: "Anulado", received: false)
        ]
        let report = try importRows(rows)
        XCTAssertEqual(report.createdTenancies, ["2001", "3001"])
        XCTAssertEqual(report.createdReceipts, 5)
        XCTAssertEqual(report.cancelledReceipts, 1)
        XCTAssertEqual(report.propertyDescriptions, ["Cidade - Fração X"])
        try db.read { db in
            let tenancies = try Tenancies.all(db: db, propertyId: propertyId)
            XCTAssertEqual(tenancies.map(\.contractNumber), ["2001", "3001"])
            XCTAssertEqual(tenancies.map(\.referenceLabel), ["Room Contract AB", "Room Contract AB"])
            XCTAssertEqual(tenancies.map(\.tenantName), ["Tenant B", "Tenant B"])
            XCTAssertEqual(tenancies.map(\.startDate), [Self.date(2020, 1, 1), Self.date(2023, 3, 1)])
            // The earlier tenancy is followed by another: it ends with its last period. The latest stays open.
            XCTAssertEqual(tenancies.map(\.endDate), [Self.date(2020, 2, 29), nil])
            let receipts = try RentReceipts.receipts(db: db, tenancyId: tenancies[1].id!, includeCancelled: true)
            XCTAssertEqual(receipts.map(\.status), [.issued, .issued, .cancelled])
            XCTAssertNil(receipts[2].receiptDate)
        }

        let again = try importRows(rows)
        XCTAssertEqual(again.createdTenancies, [])
        XCTAssertEqual(again.updatedTenancies, [])
        XCTAssertEqual(again.createdReceipts, 0)
        XCTAssertEqual(again.updatedReceipts, 0)
        XCTAssertEqual(again.unchangedReceipts, 5)
        XCTAssertEqual(again.cancelledReceipts, 0)
        XCTAssertEqual(try db.read { db in try RentReceipt.fetchCount(db) }, 5)
    }

    func testReimportUpdatesStatusAndMergesIntoAnExistingTenancy() throws {
        let tenancyId = try db.write { db -> Int64 in
            var tenancy = Tenancy(propertyId: propertyId, referenceLabel: "My label", contractNumber: "3001", startDate: Self.date(2023, 4, 1),
                                  depositMonths: 2)
            try Tenancies.save(db: db, &tenancy)
            return tenancy.id!
        }
        let first = try importRows([month("3001", "1", 2023, 3), month("3001", "2", 2023, 4)])
        XCTAssertEqual(first.createdTenancies, [])
        XCTAssertEqual(first.updatedTenancies, ["3001"])
        try db.read { db in
            let tenancy = try Tenancy.fetchOne(db, key: tenancyId)!
            XCTAssertEqual(tenancy.referenceLabel, "My label") // the user's label stays
            XCTAssertEqual(tenancy.tenantName, "Tenant B") // a blank tenant is filled
            XCTAssertEqual(tenancy.startDate, Self.date(2023, 3, 1)) // receipts start earlier
            XCTAssertEqual(tenancy.depositMonths, 2)
        }

        // A credit paid receipt 2; the portal then cancels it and the export drops receipt 1.
        let credit = try addCredit(Self.date(2023, 4, 3), 110_000)
        try db.write { db in
            try Properties.setAccount(db: db, propertyId: propertyId, accountId: try currentAccount(db), role: .current)
            try RentReceiptMatching.match(db: db, propertyId: propertyId)
            XCTAssertEqual(try RentReceiptMatching.payments(db: db, transactionId: credit).count, 1)
        }
        let second = try importRows([month("3001", "2", 2023, 4, status: "Anulado")])
        XCTAssertEqual(second.updatedReceipts, 1)
        XCTAssertEqual(second.cancelledReceipts, 1)
        XCTAssertEqual(second.removedPaymentLinks, 1)
        XCTAssertEqual(second.missingFromExport.map(\.receiptNumber), ["1"])
        try db.read { db in
            XCTAssertEqual(try RentReceipts.receipts(db: db, tenancyId: tenancyId, includeCancelled: true).map(\.status), [.issued, .cancelled])
            XCTAssertEqual(try RentReceiptMatching.payments(db: db, transactionId: credit), [])
        }
    }

    func testPreviewWritesNothing() throws {
        let parsed = try RentReceiptsExport.parse(xlsx: Self.export([month("3001", "1", 2023, 3)]))
        let report = try db.write { db in try RentReceiptImport.preview(db: db, propertyId: propertyId, rows: parsed) }
        XCTAssertEqual(report.createdTenancies, ["3001"])
        XCTAssertEqual(report.createdReceipts, 1)
        try db.read { db in
            XCTAssertEqual(try Tenancy.fetchCount(db), 0)
            XCTAssertEqual(try RentReceipt.fetchCount(db), 0)
        }
    }

    // MARK: Matching

    private var accountId: Int64?
    private var rentCategoryId: Int64?

    private func currentAccount(_ db: Database) throws -> Int64 {
        if let accountId { return accountId }
        var account = Account(name: "Bank A", currency: .eur, kind: .cash, trackingMode: .imported)
        try account.insert(db)
        var batch = ImportBatch(accountId: account.id!, sourceFileName: "bank.xlsx", importedAt: Date())
        try batch.insert(db)
        var group = CategoryGroup(name: "Property A")
        try group.insert(db)
        var rent = Category(name: "Rental income", type: .income, groupId: group.id)
        try rent.insert(db)
        var cost = Category(name: "Utilities", type: .expense, groupId: group.id)
        try cost.insert(db)
        try Properties.addCategoryGroup(db: db, propertyId: propertyId, categoryGroupId: group.id!)
        accountId = account.id
        rentCategoryId = rent.id
        return account.id!
    }

    @discardableResult
    private func addCredit(_ date: Date, _ amount: Int, rent: Bool = true) throws -> Int64 {
        try db.write { db in
            let account = try currentAccount(db)
            let batch = try ImportBatch.filter(Column("accountId") == account).fetchOne(db)!
            var transaction = Transaction(importBatchId: batch.id!, accountId: account, date: date, rawDescription: "Transfer from tenant",
                                          amountMinorUnits: amount, categoryId: rent ? rentCategoryId : nil, status: .confirmed,
                                          categorizedBy: .manual, fingerprint: UUID().uuidString)
            try transaction.insert(db)
            return transaction.id!
        }
    }

    private func receiptId(_ contract: String, _ number: String) throws -> Int64 {
        try db.read { db in
            let tenancy = try Tenancies.tenancy(db: db, propertyId: propertyId, contractNumber: contract)!
            return try RentReceipts.receipt(db: db, tenancyId: tenancy.id!, receiptNumber: number)!.id!
        }
    }

    private func match() throws -> RentReceiptMatching.Result {
        try db.write { db in
            try Properties.setAccount(db: db, propertyId: propertyId, accountId: try currentAccount(db), role: .current)
            return try RentReceiptMatching.match(db: db, propertyId: propertyId)
        }
    }

    private func links(_ receipt: Int64) throws -> [[Int]] {
        try db.read { db in
            try RentReceiptMatching.payments(db: db, receiptId: receipt).map { [Int($0.transactionId), $0.rentMinorUnits, $0.otherMinorUnits] }
        }
    }

    func testMatchingPassesAndUnmatchedListsBothWays() throws {
        _ = try importRows([
            month("3001", "1", 2025, 1), // exact credit
            month("3001", "2", 2025, 2), month("3001", "3", 2025, 3), // one advance credit for both
            month("3001", "4", 2025, 4), // a larger credit: rent + recharge
            month("3001", "5", 2025, 5), // paid in two transfers
            month("3001", "6", 2025, 6), // nothing paid
            month("3001", "7", 2025, 7, status: "Anulado") // cancelled: never matched
        ])
        let january = try addCredit(Self.date(2025, 1, 2), 110_000)
        let advance = try addCredit(Self.date(2025, 1, 25), 220_000)
        let recharge = try addCredit(Self.date(2025, 4, 4), 121_234)
        let partA = try addCredit(Self.date(2025, 5, 2), 70_000)
        let partB = try addCredit(Self.date(2025, 5, 9), 40_000)
        let stray = try addCredit(Self.date(2025, 9, 1), 110_000) // outside every window
        try addCredit(Self.date(2025, 6, 1), 110_000, rent: false) // not a rent credit (uncategorised)

        let result = try match()
        XCTAssertEqual(try links(try receiptId("3001", "1")), [[Int(january), 110_000, 0]])
        XCTAssertEqual(try links(try receiptId("3001", "2")), [[Int(advance), 110_000, 0]])
        XCTAssertEqual(try links(try receiptId("3001", "3")), [[Int(advance), 110_000, 0]])
        XCTAssertEqual(try links(try receiptId("3001", "4")), [[Int(recharge), 110_000, 11_234]])
        XCTAssertEqual(try links(try receiptId("3001", "5")), [[Int(partA), 70_000, 0], [Int(partB), 40_000, 0]])
        XCTAssertEqual(result.created.count, 6)
        XCTAssertEqual(result.unmatchedReceipts.map(\.receiptNumber), ["6"])
        XCTAssertEqual(result.unmatchedCredits.map(\.id), [stray])

        // Idempotent.
        let again = try match()
        XCTAssertEqual(again.created, [])
        XCTAssertEqual(again.unmatchedReceipts.map(\.receiptNumber), ["6"])
    }

    func testTheClosestCreditWinsAndTheReceiptDateWidensTheWindow() throws {
        // Paid late: the portal's receipt date is 20 days after the period month.
        var late = month("3001", "1", 2025, 1)
        late.received = "2025-02-20"
        _ = try importRows([late, month("3001", "2", 2025, 2)])
        let lateCredit = try addCredit(Self.date(2025, 2, 21), 110_000)
        let februaryCredit = try addCredit(Self.date(2025, 2, 3), 110_000)
        _ = try match()
        XCTAssertEqual(try links(try receiptId("3001", "1")), [[Int(lateCredit), 110_000, 0]])
        XCTAssertEqual(try links(try receiptId("3001", "2")), [[Int(februaryCredit), 110_000, 0]])
    }

    func testDismissedAutoLinksStayUnmadeAndManualLinksValidate() throws {
        _ = try importRows([month("3001", "1", 2025, 1)])
        let credit = try addCredit(Self.date(2025, 1, 2), 110_000)
        let other = try addCredit(Self.date(2025, 1, 5), 50_000)
        _ = try match()
        let receipt = try receiptId("3001", "1")
        try db.write { db in
            XCTAssertTrue(try RentReceiptMatching.unlink(db: db, receiptId: receipt, transactionId: credit))
            XCTAssertFalse(try RentReceiptMatching.unlink(db: db, receiptId: receipt, transactionId: credit))
        }
        let rematch = try match()
        XCTAssertEqual(rematch.created, []) // the dismissed pair isn't remade, and 500 alone doesn't cover it
        XCTAssertEqual(rematch.unmatchedReceipts.map(\.id), [receipt])

        try db.write { db in
            // By hand: the rest of the receipt defaults to what's left of the credit.
            let manual = try RentReceiptMatching.link(db: db, receiptId: receipt, transactionId: other)
            XCTAssertEqual([manual.rentMinorUnits, manual.otherMinorUnits], [50_000, 0])
            XCTAssertEqual(manual.origin, .manual)
            XCTAssertThrowsError(try RentReceiptMatching.link(db: db, receiptId: receipt, transactionId: other, rentMinorUnits: 40_000,
                                                              otherMinorUnits: 20_000)) {
                XCTAssertEqual($0 as? RentPaymentError, .overAllocated)
            }
            // Re-linking the dismissed pair revives it as manual, covering the rest.
            let revived = try RentReceiptMatching.link(db: db, receiptId: receipt, transactionId: credit)
            XCTAssertEqual([revived.rentMinorUnits, revived.otherMinorUnits], [60_000, 0])
            XCTAssertEqual(revived.origin, .manual)
            XCTAssertEqual(try RentReceiptMatching.unmatchedReceipts(db: db, propertyId: propertyId), [])
            // Manual links are deleted on unlink.
            XCTAssertTrue(try RentReceiptMatching.unlink(db: db, receiptId: receipt, transactionId: other))
            XCTAssertEqual(try RentReceiptPayment.filter(Column("transactionId") == other).fetchCount(db), 0)
            XCTAssertThrowsError(try RentReceiptMatching.link(db: db, receiptId: 999, transactionId: other)) {
                XCTAssertEqual($0 as? RentPaymentError, .receiptNotFound)
            }
        }
    }

    func testLinksGoWithTheirTransactionOrReceipt() throws {
        _ = try importRows([month("3001", "1", 2025, 1), month("3001", "2", 2025, 2)])
        let january = try addCredit(Self.date(2025, 1, 2), 110_000)
        _ = try addCredit(Self.date(2025, 2, 2), 110_000)
        _ = try match()
        try db.write { db in
            XCTAssertEqual(try RentReceiptPayment.fetchCount(db), 2)
            _ = try Transaction.deleteOne(db, key: january)
            XCTAssertEqual(try RentReceiptPayment.fetchCount(db), 1)
            _ = try RentReceipts.delete(db: db, id: try RentReceipts.receipt(db: db, tenancyId: try Tenancy.fetchOne(db)!.id!, receiptNumber: "2")!.id!)
            XCTAssertEqual(try RentReceiptPayment.fetchCount(db), 0)
        }
    }

    // MARK: Review fixes

    func testAdvanceRunsMustBeBackToBackAndStopAtAPaidReceipt() throws {
        // Feb and Apr with no March receipt: not a run.
        _ = try importRows([month("3001", "2", 2025, 2), month("3001", "4", 2025, 4)])
        let gapCredit = try addCredit(Self.date(2025, 2, 1), 220_000)
        var result = try match()
        XCTAssertEqual(result.created, [])
        XCTAssertEqual(result.unmatchedCredits.map(\.id), [gapCredit])

        // Jan–Mar back to back but February already paid: Jan + Mar is not a run either.
        _ = try importRows([month("4001", "1", 2026, 1), month("4001", "2", 2026, 2), month("4001", "3", 2026, 3)])
        let february = try addCredit(Self.date(2026, 2, 3), 110_000)
        let twoMonths = try addCredit(Self.date(2026, 1, 2), 220_000)
        result = try match()
        XCTAssertEqual(try links(try receiptId("4001", "2")), [[Int(february), 110_000, 0]])
        XCTAssertEqual(try links(try receiptId("4001", "1")), [])
        XCTAssertTrue(result.unmatchedCredits.map(\.id).contains(twoMonths))
    }

    func testALargerCreditsExcessIsCapped() throws {
        _ = try importRows([month("3001", "1", 2025, 1)])
        let big = try addCredit(Self.date(2025, 1, 2), 170_000) // 600 over 1,100: more than half
        let result = try match()
        XCTAssertEqual(result.created, [])
        XCTAssertEqual(result.unmatchedCredits.map(\.id), [big])
        try db.write { db in
            let wider = try RentReceiptMatching.match(db: db, propertyId: propertyId, options: .init(maxOtherFraction: 0.6))
            XCTAssertEqual(wider.created.map { [$0.rentMinorUnits, $0.otherMinorUnits] }, [[110_000, 60_000]])
        }
    }

    func testOnlyCreditsInThePropertysCurrencyCount() throws {
        _ = try importRows([month("3001", "1", 2025, 1)])
        _ = try addCredit(Self.date(2025, 1, 2), 110_000)
        try db.write { db in
            _ = try currentAccount(db)
            var pounds = Account(name: "Bank B", currency: .gbp, kind: .cash, trackingMode: .imported)
            try pounds.insert(db)
            var batch = ImportBatch(accountId: pounds.id!, sourceFileName: "b.csv", importedAt: Date())
            try batch.insert(db)
            var credit = Transaction(importBatchId: batch.id!, accountId: pounds.id!, date: Self.date(2025, 1, 2), rawDescription: "Rent",
                                     amountMinorUnits: 110_000, categoryId: rentCategoryId, status: .confirmed, categorizedBy: .manual,
                                     fingerprint: UUID().uuidString)
            try credit.insert(db)
            try Properties.setAccount(db: db, propertyId: propertyId, accountId: pounds.id!, role: .current)
            try Properties.setAccount(db: db, propertyId: propertyId, accountId: try currentAccount(db), role: .current)
            XCTAssertEqual(try RentReceiptMatching.candidateCredits(db: db, propertyId: propertyId).map(\.accountId), [try currentAccount(db)])
        }
    }

    func testReimportWithANewAmountRemakesAutoLinksAndExtendsTheEnd() throws {
        _ = try importRows([month("2001", "1", 2020, 1), month("3001", "2", 2023, 4, amount: "1000")])
        let credit = try addCredit(Self.date(2023, 4, 3), 110_000)
        _ = try match() // 1,100 against 1,000: matched with 100 other
        let november = try receiptId("3001", "2")
        XCTAssertEqual(try links(november), [[Int(credit), 100_000, 10_000]])

        // The portal corrected April to 1,100, and contract 2001 got a later receipt.
        let report = try importRows([month("2001", "1", 2020, 1), month("2001", "2", 2020, 2), month("3001", "2", 2023, 4)])
        XCTAssertEqual(report.removedPaymentLinks, 1)
        XCTAssertEqual(report.rematchedPaymentLinks, 1)
        XCTAssertEqual(try links(november), [[Int(credit), 110_000, 0]])
        XCTAssertTrue(report.updatedTenancies.contains("2001"))
        try db.read { db in
            XCTAssertEqual(try Tenancies.tenancy(db: db, propertyId: propertyId, contractNumber: "2001")?.endDate, Self.date(2020, 2, 29))
        }
    }

    func testManualLinksRejectCancelledReceiptsAndOverpayingTheReceipt() throws {
        _ = try importRows([month("3001", "1", 2025, 1), month("3001", "2", 2025, 2, status: "Anulado")])
        let credit = try addCredit(Self.date(2025, 1, 2), 150_000)
        let (january, cancelled) = (try receiptId("3001", "1"), try receiptId("3001", "2"))
        try db.write { db in
            XCTAssertThrowsError(try RentReceiptMatching.link(db: db, receiptId: cancelled, transactionId: credit)) {
                XCTAssertEqual($0 as? RentPaymentError, .receiptCancelled)
            }
            XCTAssertThrowsError(try RentReceiptMatching.link(db: db, receiptId: january, transactionId: credit,
                                                              rentMinorUnits: 120_000)) {
                XCTAssertEqual($0 as? RentPaymentError, .exceedsReceipt)
            }
            let ok = try RentReceiptMatching.link(db: db, receiptId: january, transactionId: credit, otherMinorUnits: 40_000)
            XCTAssertEqual([ok.rentMinorUnits, ok.otherMinorUnits], [110_000, 40_000])
        }
    }

    func testALowerAmountClampsManualLinks() throws {
        _ = try importRows([month("3001", "1", 2025, 1)])
        let credit = try addCredit(Self.date(2025, 1, 2), 110_000)
        let receipt = try receiptId("3001", "1")
        try db.write { db in _ = try RentReceiptMatching.link(db: db, receiptId: receipt, transactionId: credit) }
        let report = try importRows([month("3001", "1", 2025, 1, amount: "1000")])
        XCTAssertEqual(report.clampedManualLinks, 1)
        XCTAssertEqual(try links(receipt), [[Int(credit), 100_000, 10_000]])
    }

    func testRematchUsesTheCallersOptions() throws {
        _ = try importRows([month("3001", "1", 2025, 1, amount: "1000")])
        let credit = try addCredit(Self.date(2025, 1, 2), 160_000) // 600 over 1,000: more than half
        XCTAssertEqual(try match().created, [])
        let parsed = try RentReceiptsExport.parse(xlsx: Self.export([month("3001", "1", 2025, 1, amount: "1000")]))
        func reimport(_ fraction: Double) throws -> RentReceiptImport.Report {
            try db.write { db in
                // As if an earlier export said 900 and the credit was auto-linked to it.
                var receipt = try RentReceipt.fetchOne(db)!
                receipt.amountReceivedMinorUnits = 90_000
                try receipt.update(db)
                _ = try RentReceiptPayment.deleteAll(db)
                var auto = RentReceiptPayment(rentReceiptId: receipt.id!, transactionId: credit, rentMinorUnits: 90_000,
                                              otherMinorUnits: 70_000, origin: .auto)
                try auto.insert(db)
                return try RentReceiptImport.run(db: db, propertyId: propertyId, rows: parsed, matchOptions: .init(maxOtherFraction: fraction))
            }
        }
        let strict = try reimport(0.5)
        XCTAssertEqual(strict.removedPaymentLinks, 1)
        XCTAssertEqual(strict.rematchedPaymentLinks, 0)
        XCTAssertEqual(try reimport(0.6).rematchedPaymentLinks, 1)
    }

    func testCancellingAReceiptRemovesItsManualLinksToo() throws {
        _ = try importRows([month("3001", "1", 2025, 1)])
        let credit = try addCredit(Self.date(2025, 1, 2), 110_000)
        let receipt = try receiptId("3001", "1")
        try db.write { db in _ = try RentReceiptMatching.link(db: db, receiptId: receipt, transactionId: credit) }
        let report = try importRows([month("3001", "1", 2025, 1, status: "Anulado")])
        XCTAssertEqual(report.cancelledReceipts, 1)
        XCTAssertEqual(report.removedPaymentLinks, 1)
        XCTAssertEqual(try links(receipt), [])
    }
}
