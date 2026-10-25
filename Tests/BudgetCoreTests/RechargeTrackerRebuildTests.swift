import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Rebuilding a tenancy's recharges from the tracker plan: corrections, a duplicate deleted,
/// an invoice kept off the statements, statements rewritten or added (manual, rounding and
/// pending ones, a transfer without a rent receipt), the comparison, idempotence and the
/// refusals. Synthetic data only.
final class RechargeTrackerRebuildTests: XCTestCase {
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
            ids["A"] = a.id!
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            let p = property.id!
            ids["property"] = p
            _ = try Properties.setOwners(db: db, propertyId: p, [PropertyOwner(propertyId: p, personId: a.id!, shareBasisPoints: 10_000)])
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
            for (key, name, type) in [("rent", "Rental income", CategoryType.income), ("utilities", "Utilities", .expense)] {
                var category = Category(name: name, type: type, groupId: group.id)
                try category.insert(db)
                ids[key] = category.id!
            }
            try TaxExpenseTypeMap.seed(db: db, propertyId: p)
            try HMRCRates.set(db: db, startYear: 2024, currencyCode: "EUR", gbpPerUnit: 0.8, source: .manual)
            var tenancy = Tenancy(propertyId: p, referenceLabel: "Room Contract AB", contractNumber: "3001", startDate: Self.date(2024, 3, 15))
            try Tenancies.save(db: db, &tenancy)
            ids["tenancy"] = tenancy.id!
            for (number, month) in [("1", 5), ("2", 6), ("3", 7)] {
                var receipt = RentReceipt(tenancyId: tenancy.id!, receiptNumber: number, periodStart: Self.date(2024, month, 1),
                                          periodEnd: MonthRange.calendar.date(byAdding: DateComponents(month: 1, day: -1), to: Self.date(2024, month, 1))!,
                                          receiptDate: Self.date(2024, month, 2), amountMinorUnits: 100_000)
                try RentReceipts.save(db: db, &receipt)
            }
            var water = UtilityProvider(propertyId: p, name: "Example Water", kind: .water, bankDescriptionPattern: "EXAMPLE WTR",
                                        invoiceRules: UtilityInvoiceRules(textMarkers: ["EXAMPLE WATER"], amountLabels: ["VALOR TOTAL"]))
            try Recharges.saveProvider(db: db, &water)
            ids["water"] = water.id!
        }
        // The bank: a water debit, the rent transfers (May's and June's with a recharge part),
        // a refund, July's rent alone and its recharge on a separate transfer.
        ids["debit1"] = try transaction("utilities", Self.date(2024, 4, 25), -1_000, "SEPADD/EXAMPLE WTR")
        ids["may"] = try transaction("rent", Self.date(2024, 5, 2), 101_000, "TRF TENANT NAME")
        ids["june"] = try transaction("rent", Self.date(2024, 6, 3), 101_500, "TRF TENANT NAME")
        ids["refund"] = try transaction("utilities", Self.date(2024, 6, 10), 500, "EXAMPLE WTR REFUND")
        ids["july"] = try transaction("rent", Self.date(2024, 7, 2), 100_000, "TRF TENANT NAME")
        ids["separate"] = try transaction("rent", Self.date(2024, 7, 2), 2_470, "TRF TENANT NAME")
        // Invoices as first read: W1 misread (4,00 for 10,00), W2 a copy of it, W3 a credit
        // note read as a charge; W0 is the tenancy's first, never recharged.
        ids["W0"] = try invoice(nil, issued: Self.date(2024, 3, 20), amount: 600, period: (Self.date(2024, 2, 1), Self.date(2024, 3, 31)))
        ids["W1"] = try invoice(nil, issued: Self.date(2024, 4, 5), amount: 400)
        ids["W2"] = try db.write { db -> Int64 in
            var copy = UtilityInvoice(providerId: id("water"), issueDate: Self.date(2024, 4, 5), amountMinorUnits: 400)
            try copy.insert(db)  // as an older intake let it in
            return copy.id!
        }
        ids["W3"] = try invoice("C-1", issued: Self.date(2024, 5, 20), amount: 300)
        ids["W4"] = try invoice("W-4", issued: Self.date(2024, 5, 28), amount: 2_000)
        ids["W5"] = try invoice("W-5", issued: Self.date(2024, 6, 20), amount: 2_440)
        ids["W6"] = try invoice("W-6", issued: Self.date(2024, 7, 20), amount: 900)
        try db.write { db in
            _ = try RentReceiptMatching.match(db: db, propertyId: id("property"))
            // What the backfill made of it.
            _ = try RechargeBackfill.rebuildStatements(db: db, tenancyId: id("tenancy"), since: Self.date(2024, 1, 1))
        }
    }

    @discardableResult
    private func transaction(_ category: String?, _ date: Date, _ amount: Int, _ text: String) throws -> Int64 {
        try db.write { db in
            var transaction = Transaction(importBatchId: id("batch"), accountId: id("bank"), date: date, rawDescription: text,
                                          amountMinorUnits: amount, categoryId: category.flatMap { ids[$0] }, status: .confirmed,
                                          categorizedBy: .manual, fingerprint: UUID().uuidString)
            try transaction.insert(db)
            return transaction.id!
        }
    }

    private func invoice(_ number: String?, issued: Date, amount: Int, period: (Date, Date)? = nil) throws -> Int64 {
        try db.write { db in
            var invoice = UtilityInvoice(providerId: id("water"), invoiceNumber: number, periodStart: period?.0, periodEnd: period?.1,
                                         issueDate: issued, amountMinorUnits: amount)
            try Recharges.saveInvoice(db: db, &invoice)
            return invoice.id!
        }
    }

    private typealias R = RechargeTrackerRebuild

    private func line(_ invoice: String, _ amount: Int, tracker: Int? = nil) -> R.Line {
        R.Line(kind: .invoice, invoiceId: id(invoice), description: nil, amountMinorUnits: amount, note: nil, transactionId: nil, trackerRow: nil,
               trackerAmountMinorUnits: tracker ?? amount)
    }

    private func manual(_ kind: R.LineKind, _ description: String, _ amount: Int, transaction: Int64? = nil) -> R.Line {
        R.Line(kind: kind, invoiceId: nil, description: description, amountMinorUnits: amount, note: nil, transactionId: transaction, trackerRow: nil,
               trackerAmountMinorUnits: kind == .rounding ? nil : amount)
    }

    private func pay(_ key: String, _ day: String, _ amount: Int) -> R.Payment {
        R.Payment(transactionId: id(key), date: day, amountMinorUnits: amount, note: nil)
    }

    private var plan: R.Plan {
        R.Plan(
            tenancyId: id("tenancy"), mergePresetRules: ["Example Water": "Municipal water (SIMAR)"],
            invoiceCorrections: [
                R.InvoiceCorrection(invoiceId: id("W1"), newAmountMinorUnits: 1_000, oldAmountMinorUnits: 400, linkDebitTransactionId: id("debit1"),
                                    newIssueDate: nil, evidence: "misread"),
                R.InvoiceCorrection(invoiceId: id("W3"), newAmountMinorUnits: -500, oldAmountMinorUnits: 300, linkDebitTransactionId: id("refund"),
                                    newIssueDate: "2024-05-21", evidence: "a credit note")
            ],
            invoiceDeletions: [R.InvoiceDeletion(invoiceId: id("W2"), reason: "a copy of W1")],
            invoicesNotRecharged: [R.NotRecharged(invoiceId: id("W0"), reason: "not in the tracker")],
            statements: [
                R.Statement(month: "2024-04", status: .paid, sentAt: "2024-04-30", totalMinorUnits: 1_000, payments: [pay("may", "2024-05-02", 1_000)],
                            lines: [line("W1", 1_000)], note: nil),
                R.Statement(month: "2024-05", status: .paid, sentAt: "2024-05-31", totalMinorUnits: 1_500, payments: [pay("june", "2024-06-03", 1_500)],
                            lines: [line("W3", -500), line("W4", 2_000)], note: nil),
                R.Statement(month: "2024-06", status: .paid, sentAt: "2024-06-30", totalMinorUnits: 2_470,
                            payments: [pay("separate", "2024-07-02", 2_470)],
                            lines: [line("W5", 2_440), manual(.rounding, "Rounding: the transfer was €0.30 more", 30)], note: nil),
                R.Statement(month: "2024-07", status: .sent, sentAt: "2024-07-31", totalMinorUnits: 1_000, payments: [],
                            lines: [line("W6", 900), manual(.manual, "Repair call-out", 100, transaction: id("debit1"))], note: nil)
            ])
    }

    private func decoded(_ plan: R.Plan) throws -> R.Plan {
        try R.decodePlan(JSONEncoder().encode(plan))
    }

    func testThePlanIsCheckedBeforeAnythingIsWritten() throws {
        XCTAssertEqual(try decoded(plan), plan)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        var statements = try XCTUnwrap(json["statements"] as? [[String: Any]])
        statements[0]["extra"] = 1
        json["statements"] = statements
        json["generated"] = "2026-10-19"  // the audit's information is accepted
        XCTAssertThrowsError(try R.decodePlan(JSONSerialization.data(withJSONObject: json))) {
            XCTAssertEqual($0 as? R.RebuildError, .unknownKeys(["statements[0].extra"]))
        }
        var broken = plan
        broken.statements[0].totalMinorUnits = 999
        XCTAssertThrowsError(try decoded(broken)) {
            XCTAssertEqual($0 as? R.RebuildError, .inconsistentPlan("2024-04: lines don't add up to the total"))
        }
        broken = plan
        broken.statements[3].payments = [pay("july", "2024-07-02", 1_000)]
        XCTAssertThrowsError(try decoded(broken)) { XCTAssertEqual($0 as? R.RebuildError, .inconsistentPlan("2024-07: sent, but nothing is owed")) }
        broken = plan
        broken.statements.swapAt(0, 1)
        XCTAssertThrowsError(try decoded(broken))
        broken = plan
        broken.statements[1].lines.append(line("W1", 0))
        broken.statements[1].totalMinorUnits = 1_500
        XCTAssertThrowsError(try decoded(broken)) { XCTAssertEqual($0 as? R.RebuildError, .inconsistentPlan("invoice \(id("W1")) on two lines")) }
    }

    func testTheHistoryIsRebuiltAsPlannedAndOnlyOnce() throws {
        let outcome = try db.write { db in try R.apply(db: db, plan: try decoded(plan)) }
        XCTAssertEqual(outcome.count(.deleted), 1)
        XCTAssertEqual(outcome.actions.first { $0.subject == "invoice \(id("W1"))" }?.detail, "€4.00 → €10.00, paid by tx \(id("debit1"))")
        XCTAssertEqual(outcome.actions.first { $0.subject == "provider rules Example Water" }?.change, .changed)
        try db.read { db in
            XCTAssertNil(try UtilityInvoice.fetchOne(db, key: id("W2")))
            let w3 = try XCTUnwrap(try UtilityInvoice.fetchOne(db, key: id("W3")))
            XCTAssertEqual(w3.amountMinorUnits, -500)
            XCTAssertEqual(w3.issueDate, Self.date(2024, 5, 21))
            XCTAssertEqual(try UtilityProvider.fetchOne(db, key: id("water"))?.effectiveRules.amountLabels.first, "VALOR TOTAL")
            let statements = try RechargeStatement.filter(Column("tenancyId") == id("tenancy")).order(Column("month")).fetchAll(db)
            XCTAssertEqual(statements.map(\.totalMinorUnits), [1_000, 1_500, 2_470, 1_000])
            XCTAssertEqual(statements.map(\.status), [.paid, .paid, .paid, .sent])
            // The never-recharged invoice sits at zero on the first statement: it isn't pending.
            let april = try Recharges.lines(db: db, statementId: statements[0].id!)
            XCTAssertEqual(april.map(\.amountMinorUnits).sorted(), [0, 1_000])
            XCTAssertEqual(try Recharges.pendingLines(db: db, tenancyId: id("tenancy"), through: Self.date(2030, 1, 1)), [])
            let july = try Recharges.lines(db: db, statementId: statements[3].id!)
            XCTAssertEqual(july.first { $0.isManual }?.transactionId, id("debit1"))
            let june = try Recharges.lines(db: db, statementId: statements[2].id!)
            XCTAssertEqual(june.first { $0.isManual }?.isRounding, true)
            // Every month as the tracker and the transfers say; only the pending month is open.
            let checks = try R.compare(db: db, plan: plan)
            XCTAssertEqual(checks.map(\.matches), [true, true, true, true], "\(checks.map(\.problem))")
            XCTAssertEqual(checks.map(\.tenantPaidMinorUnits), [1_000, 1_500, 2_470, nil])
            XCTAssertEqual(try Recharges.paymentSuggestions(db: db, propertyId: id("property")).map(\.statement.id), [])
            XCTAssertEqual(try Recharges.creditRemainder(db: db, transactionId: id("separate")), 0)
        }
        // Idempotent.
        let again = try db.write { db in try R.apply(db: db, plan: try decoded(plan)) }
        XCTAssertEqual(again.actions.filter { $0.change != .unchanged }, [])
        XCTAssertEqual(again.before, again.after)
    }

    func testOneOffLinesAreKeptSoThePlanMustHaveThem() throws {
        let keyCopy = try db.write { db -> Int64 in
            let april = try XCTUnwrap(try RechargeStatement.filter(Column("month") == Self.date(2024, 4, 1)).fetchOne(db))
            try Recharges.resetStatement(db: db, statementId: april.id!)
            return try Recharges.saveManualLine(db: db, statementId: april.id!, description: "Key copy", amountMinorUnits: 250).id!
        }
        XCTAssertThrowsError(try db.write { db in try R.apply(db: db, plan: plan) }) {
            XCTAssertEqual($0 as? R.RebuildError, .oneOffLineNotInPlan("2024-04: Key copy €2.50"))
        }
        // In the plan, it's the same line (kept, not rewritten).
        var withIt = plan
        withIt.statements[0].lines.append(manual(.manual, "Key copy", 250))
        withIt.statements[0].totalMinorUnits = 1_250
        withIt.statements[0].status = .sent
        withIt.statements[0].payments = [pay("may", "2024-05-02", 1_000)]
        try db.write { db in _ = try R.apply(db: db, plan: try decoded(withIt)) }
        try db.read { db in
            XCTAssertNotNil(try RechargeLine.fetchOne(db, key: keyCopy))
            XCTAssertEqual(try R.compare(db: db, plan: withIt).map(\.matches), [false, true, true, true])
        }
    }

    func testContradictionsAreRefusedAndNothingIsWritten() throws {
        // An invoice changed since the audit.
        try db.write { db in
            try db.execute(sql: "UPDATE utilityInvoice SET amountMinorUnits = 450 WHERE id = ?", arguments: [id("W1")])
        }
        XCTAssertThrowsError(try db.write { db in try R.apply(db: db, plan: plan) }) {
            XCTAssertEqual($0 as? R.RebuildError, .invoiceChanged(id("W1"), found: 450))
        }
        try db.read { db in
            XCTAssertNotNil(try UtilityInvoice.fetchOne(db, key: id("W2")))
            XCTAssertEqual(try UtilityInvoice.fetchOne(db, key: id("W3"))?.amountMinorUnits, 300)
        }
        try db.write { db in
            try db.execute(sql: "UPDATE utilityInvoice SET amountMinorUnits = 400 WHERE id = ?", arguments: [id("W1")])
        }
        // A statement the plan doesn't have, before its last month.
        var missing = plan
        missing.statements.remove(at: 1)
        XCTAssertThrowsError(try db.write { db in try R.apply(db: db, plan: missing) }) {
            XCTAssertEqual($0 as? R.RebuildError, .statementNotInPlan("2024-05"))
        }
        // A credit dated otherwise than planned.
        var misdated = plan
        misdated.statements[0].payments[0].date = "2024-05-03"
        XCTAssertThrowsError(try db.write { db in try R.apply(db: db, plan: misdated) }) {
            XCTAssertEqual($0 as? R.RebuildError, .paymentDateDiffers(id("may"), found: "2024-05-02"))
        }
    }

    func testAFiledYearsAccountsMayNotChange() throws {
        // 2024/25 filed, but with netting stored for it: the recharges received (none linked
        // yet) would change it.
        try db.write { db in
            try db.execute(sql: "DELETE FROM rechargePayment")
            _ = try RechargeBackfill.markFiledYears(db: db, propertyId: id("property"), years: [2024])
            try RechargeNetting.set(db: db, startYear: 2024, mode: .netOfRecharges)
        }
        XCTAssertThrowsError(try db.write { db in try R.apply(db: db, plan: plan) }) {
            XCTAssertEqual($0 as? R.RebuildError, .filedYearChanged("2024/25 Person A"))
        }
        XCTAssertNotNil(try db.read { db in try UtilityInvoice.fetchOne(db, key: id("W2")) })
        // Without the stored mode the filed year leaves utilities out whatever the recharges.
        try db.write { db in try RechargeNetting.set(db: db, startYear: 2024, mode: nil) }
        let outcome = try db.write { db in try R.apply(db: db, plan: plan) }
        XCTAssertEqual(outcome.before.map(\.isFiled), [false, true])
        XCTAssertEqual(outcome.before, outcome.after)
    }
}
