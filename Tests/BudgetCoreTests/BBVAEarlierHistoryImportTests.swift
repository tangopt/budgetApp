import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category

/// Earlier BBVA statements imported before the existing history (`BBVAStatementParser`,
/// `BBVAEarlierHistoryImport`): synthetic statements for November and December 2022 that meet
/// a database left as the 2023+ import leaves it.
final class BBVAEarlierHistoryImportTests: XCTestCase {
    private typealias Import = BBVAEarlierHistoryImport

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: Synthetic statements

    private let november = """
        Exmo. Senhor
        PERÍODO DE 2022/11/01 A 2022/11/30
        ACTIVO
        DEPÓSITOS À ORDEM 2.142,00
        PRODUTOS DE POUPANÇA 1.060,50
        PASSIVO
        EMPRÉSTIMOS 9.800,00
        Pág. 1/3 2022/12/02 Extrato 2022/11
        Conta Nº: 000/111111111   EUR   CONTA BBVA
        IBAN: PT00 0000 0000 0000 0000 0000 0
        Saldo inicial 1.000,00
        11/02 11/02 TRF TENANT ONE      1.500,00 2.500,00
        11/30 11/30 COBR. REC. TOT 000 00-000000-0 -300,00 2.200,00
        Pág. 2/3 2022/12/02 Extrato 2022/11
        Cont.
        11/30 11/30 SUBSCRIÇÃO PERI         100,0000 -50,00 2.150,00
        11/30 11/30 MANUTENCAO CONTA NOV 2022 -8,00 2.142,00
        Saldo final 2.142,00
        Saldo disponivel 2.142,00
        Conta Nº: 000/222222222 EUR SAMPLE FUND
        Saldo inicial 10,000 100,0000 1.000,00
        11/28 11/30 SUBSCRIÇÃO PERIÓDICA 0,500 100,0000 50,00
        Saldo final 10,500 101,0000 1.060,50
        Conta Nº: 000/333333333 EUR HOME LOAN
        Capital em Dívida 9.800,00
        COBRANÇAS EFECTUADAS
        Nº. Recibo: 10/480 Data Inicio Liquidação: 2022-10-31 Total recibo:             300,00
        Data Valor: 2022-11-30 Data Fim Liquidação: 2022-11-30
        T.A.N. : 1,200%  (EUR 3M     0,200% + SPREAD  1,000%)
        Data Oper. Capital Juros Comissões Juros de Mora Impostos Total EUR Total em atraso Capital em dívida
        2022-11-30           200,00       100,00         0,00             0,00         0,00           300,00             0,00       9.800,00
        """

    private let december = """
        PERÍODO DE 2022/12/01 A 2022/12/31
        DEPÓSITOS À ORDEM 3.042,00
        PRODUTOS DE POUPANÇA 1.089,00
        EMPRÉSTIMOS 9.800,00
        Conta Nº: 000/111111111   EUR   CONTA BBVA
        Saldo inicial 2.142,00
        12/05 12/05 Despesas Casa   221205EVN0001 -50,00 2.092,00
        12/20 12/20 TRF TENANT ONE      1.000,00 3.092,00
        12/30 12/30 SUBSCRIÇÃO PERI         100,0000 -50,00 3.042,00
        Saldo final 3.042,00
        Conta Nº: 000/222222222 EUR SAMPLE FUND
        Saldo inicial 10,500 100,5000 1.055,25
        12/28 12/30 SUBSCRIÇÃO PERIÓDICA 0,500 100,0000 50,00
        Saldo final 11,000 99,0000 1.089,00
        Conta Nº: 000/111111111  EUR  CONTA BBVA
        """

    private func statements() throws -> [BBVAStatementParser.Statement] {
        [try BBVAStatementParser.parse(november), try BBVAStatementParser.parse(december)]
    }

    private func plan(accept: Bool = true, acceptYear: Int = 2022) -> Import.Plan {
        Import.Plan(
            batchName: "BBVA statements 2022-11 to 2022-12",
            rules: [Import.Rule(pattern: "TENANT ONE", kind: "rent_received"),
                    Import.Rule(pattern: "^COBR\\. REC\\. TOT", kind: "mortgage_instalment"),
                    Import.Rule(pattern: "^SUBSCRI", kind: "investment_subscription"),
                    Import.Rule(pattern: "^MANUTENCAO CONTA", kind: "bank_fees"),
                    Import.Rule(pattern: "^Despesas Casa", kind: "repairs")],
            depositSplits: [Import.DepositSplit(date: "2022-11-02", deposit: "500.00")],
            manualItems: [Import.ManualItemChange(startYear: 2022, expenseType: "financeCost", amount: "100.00",
                                                  replacedBy: [Import.Payment(date: "2022-11-30", amount: "100.00", onLoan: true)]),
                          Import.ManualItemChange(startYear: 2022, expenseType: "repairs", amount: "70.00",
                                                  replacedBy: [Import.Payment(date: "2022-12-05", amount: "50.00")], newAmount: "20.00", newLabel: "Paid elsewhere")],
            matchRentReceipts: true,
            acceptFiledChanges: accept ? [Import.AcceptedChange(startYear: acceptYear, field: "· notDeductible · ", reason: "information only")] : [],
            property: "Flat")
    }

    /// The database as the 2023+ import leaves it: BBVA opening on 2023-01-01, the fund, loan and
    /// deposit opening on 2022-12-31, one 2023 row; a property with two filed 2022/23 manual items.
    private func makeDB() throws -> DatabaseManager {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in
            let bbva = try AccountEditing.add(db: db, name: "BBVA", currency: .eur, kind: .cash, openingBalanceEntered: 304_200, asOf: day(2023, 1, 1))
            let fund = try AccountEditing.add(db: db, name: "BBVA retirement fund", currency: .eur, kind: .investment, openingBalanceEntered: 108_900, asOf: day(2022, 12, 31))
            let loan = try AccountEditing.add(db: db, name: "BBVA mortgage", currency: .eur, kind: .credit, openingBalanceEntered: 980_000, asOf: day(2022, 12, 31), includeInNetWorth: false)
            let deposit = try AccountEditing.add(db: db, name: "Tenant deposit held", currency: .eur, kind: .credit, openingBalanceEntered: 50_000, asOf: day(2022, 12, 31))
            var batch = ImportBatch(accountId: bbva.id!, sourceFileName: "BBVA statements 2023", importedAt: day(2026, 10, 1))
            try batch.insert(db)
            var row = Transaction(importBatchId: batch.id!, accountId: bbva.id!, date: day(2023, 1, 2), rawDescription: "COBR. REC. TOT 000 00-000000-0",
                                  amountMinorUnits: -30_000, categoryId: nil, status: .pendingReview, categorizedBy: .none, fingerprint: "x")
            try row.insert(db)

            let group = try CategoryGroups.create(db: db, name: "Flat costs", type: .expense)
            for (name, type) in [("Rental income", CategoryType.income), ("Mortgage interest", .expense), ("Repairs", .expense), ("BBVA fees", .expense)] {
                _ = try Categories.create(db: db, name: name, type: type, groupId: group.id)
            }
            var a = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &a)
            var b = Person(name: "Person B", shortName: "B")
            try People.save(db: db, &b)
            var property = Property(name: "Flat", country: "PT")
            try Properties.save(db: db, &property)
            let p = property.id!
            _ = try Properties.setOwners(db: db, propertyId: p, [PropertyOwner(propertyId: p, personId: a.id!, shareBasisPoints: 5_000),
                                                                 PropertyOwner(propertyId: p, personId: b.id!, shareBasisPoints: 5_000)])
            try Properties.setAccount(db: db, propertyId: p, accountId: bbva.id!, role: .current)
            try Properties.setAccount(db: db, propertyId: p, accountId: loan.id!, role: .mortgage)
            try Properties.setAccount(db: db, propertyId: p, accountId: deposit.id!, role: .deposit)
            try Properties.addCategoryGroup(db: db, propertyId: p, categoryGroupId: group.id!)
            try TaxExpenseTypeMap.seed(db: db, propertyId: p)
            try TaxExpenseTypeMap.set(db: db, categoryId: try Category.filter(Column("name") == "BBVA fees").fetchOne(db)!.id!, expenseType: .notDeductible)
            try HMRCRates.set(db: db, startYear: 2022, currencyCode: "EUR", gbpPerUnit: 0.85, source: .manual)
            for person in [a, b] {
                var year = TaxYear(startYear: 2022, personId: person.id!, status: .filed)
                try TaxYears.save(db: db, &year)
            }
            var interest = TaxManualItem(startYear: 2022, personId: a.id!, propertyId: p, expenseType: .financeCost, label: "Interest before the history",
                                         amountMinorUnits: 10_000, currency: .eur, isWholeProperty: true)
            try TaxManualItems.save(db: db, &interest)
            var repairs = TaxManualItem(startYear: 2022, personId: a.id!, propertyId: p, expenseType: .repairs, label: "Repairs before the history",
                                        amountMinorUnits: 7_000, currency: .eur, isWholeProperty: true)
            try TaxManualItems.save(db: db, &repairs)
            var tenancy = Tenancy(propertyId: p, referenceLabel: "Contract One", contractNumber: "1", startDate: day(2022, 11, 1))
            try Tenancies.save(db: db, &tenancy)
            for (number, month) in [(1, 11), (2, 12)] {
                var receipt = RentReceipt(tenancyId: tenancy.id!, receiptNumber: "\(number)", periodStart: day(2022, month, 1),
                                          periodEnd: day(2022, month, month == 11 ? 30 : 31), receiptDate: day(2022, month, 1), amountMinorUnits: 100_000)
                try RentReceipts.save(db: db, &receipt)
            }
        }
        return manager
    }

    private func balance(_ db: Database, _ name: String, at date: Date? = nil) throws -> Int? {
        let id = try Account.filter(Column("name") == name).fetchOne(db)!.id!
        return NetWorthCalculator.balance(accountId: id, at: date, snapshots: try BalanceSnapshot.filter(Column("accountId") == id).fetchAll(db),
                                          transactions: try Transaction.filter(Column("accountId") == id).fetchAll(db))?.native
    }

    // MARK: Parser

    func testParsesStatementAccountsFundLoanAndSummary() throws {
        let statement = try BBVAStatementParser.parse(november)
        XCTAssertEqual(statement.label, "2022-11")
        XCTAssertEqual(statement.openingMinorUnits, 100_000)
        XCTAssertEqual(statement.closingMinorUnits, 214_200)
        XCTAssertEqual(statement.movements.map(\.amountMinorUnits), [150_000, -30_000, -5_000, -800])
        XCTAssertEqual(statement.movements[0].description, "TRF TENANT ONE")
        XCTAssertEqual(statement.movements[2].description, "SUBSCRIÇÃO PERI 100,0000")
        XCTAssertEqual(statement.movements[1].date, day(2022, 11, 30))
        XCTAssertTrue(statement.unreadLines.isEmpty)
        XCTAssertEqual(statement.fund?.openingMinorUnits, 100_000)
        XCTAssertEqual(statement.fund?.closingMinorUnits, 106_050)
        XCTAssertEqual(statement.fund?.closingUnits, Decimal(string: "10.5"))
        XCTAssertEqual(statement.fund?.movements.count, 1)
        XCTAssertEqual(statement.loanOutstandingMinorUnits, 980_000)
        XCTAssertEqual(statement.savingsMinorUnits, 106_050)
        XCTAssertEqual(statement.loanReceipts.count, 1)
        let receipt = try XCTUnwrap(statement.loanReceipts.first)
        XCTAssertEqual(receipt.number, 10)
        XCTAssertEqual(receipt.of, 480)
        XCTAssertEqual(receipt.valueDate, day(2022, 11, 30))
        XCTAssertEqual(receipt.operationDate, day(2022, 11, 30))
        XCTAssertEqual([receipt.capitalMinorUnits, receipt.interestMinorUnits, receipt.totalMinorUnits, receipt.outstandingAfterMinorUnits], [20_000, 10_000, 30_000, 980_000])
        XCTAssertEqual(receipt.tan, 1.2)
        // The second "CONTA BBVA" (a fee section) doesn't restart the account.
        XCTAssertEqual(try BBVAStatementParser.parse(december).movements.count, 3)
    }

    func testDecemberRowsInAJanuaryStatementBelongToTheYearBefore() throws {
        let text = """
            PERÍODO DE 2023/01/01 A 2023/01/31
            Conta Nº: 000/111111111   EUR   CONTA BBVA
            Saldo inicial 10,00
            01/02 12/31 COBR. REC. TOT 000 00-000000-0 -5,00 5,00
            Saldo final 5,00
            """
        let statement = try BBVAStatementParser.parse(text)
        XCTAssertEqual(statement.movements.first?.date, day(2023, 1, 2))
        XCTAssertEqual(statement.movements.first?.valueDate, day(2022, 12, 31))
        XCTAssertEqual(BBVAStatementParser.minorUnits("-1.234,56"), -123_456)
        XCTAssertNil(BBVAStatementParser.minorUnits("1,234"))
        XCTAssertThrowsError(try BBVAStatementParser.parse("nothing here"))
    }

    func testStatementChecksRefuseABrokenChain() throws {
        var broken = try statements()
        broken.swapAt(0, 1)
        XCTAssertThrowsError(try Import.checkStatements(broken))
        XCTAssertEqual(try Import.checkStatements(try statements()).count, 2)
    }

    func testClassificationOverridesAndUnknownKinds() throws {
        var plan = plan()
        plan.overrides = [Import.Override(date: "2022-12-05", amount: "-50.00", contains: "Despesas", category: "Other", note: "why")]
        let rows = try Import.classify(try statements(), plan: plan)
        XCTAssertEqual(rows.first { $0.movement.description.hasPrefix("Despesas") }?.target, .category("Other"))
        XCTAssertEqual(rows.first { $0.movement.description.hasPrefix("COBR") }?.target, .loanTransfer)
        XCTAssertEqual(rows.first { $0.movement.description.hasPrefix("SUBSCRI") }?.target, .fundTransfer)
        plan.overrides = [Import.Override(date: "2022-12-06", amount: "-50.00", kind: "repairs")]
        XCTAssertThrowsError(try Import.classify(try statements(), plan: plan))  // matches no row
        plan.overrides = []
        plan.rules.append(Import.Rule(pattern: ".", kind: "no_such_kind"))
        XCTAssertThrowsError(try Import.classify(try statements(), plan: plan))
    }

    // MARK: Apply

    func testImportsBeforeTheHistoryKeepingBalancesAndFiledFigures() throws {
        let manager = try makeDB()
        let report = try manager.dbQueue.write { db in try Import.apply(db: db, statements: try statements(), plan: plan()) }
        XCTAssertTrue(report.failures.isEmpty, report.verification.joined(separator: "\n"))
        try manager.dbQueue.read { db in
            // Month ends equal the statements; the history meets the existing openings.
            XCTAssertEqual(try balance(db, "BBVA", at: day(2022, 11, 30).addingTimeInterval(86_399)), 214_200)
            XCTAssertEqual(try balance(db, "BBVA", at: day(2022, 12, 31).addingTimeInterval(86_399)), 304_200)
            XCTAssertEqual(try balance(db, "BBVA retirement fund", at: day(2022, 11, 30).addingTimeInterval(86_399)), 106_050)
            XCTAssertEqual(try balance(db, "BBVA mortgage", at: day(2022, 11, 1)), -1_000_000)
            XCTAssertEqual(try balance(db, "BBVA mortgage", at: day(2022, 11, 30).addingTimeInterval(86_399)), -980_000)
            XCTAssertEqual(try balance(db, "Tenant deposit held", at: day(2022, 11, 30).addingTimeInterval(86_399)), -50_000)
            // Today's balances unchanged.
            XCTAssertEqual(try balance(db, "BBVA"), 304_200 - 30_000)
            XCTAssertEqual(try balance(db, "BBVA mortgage"), -980_000)
            // The interest row on the loan, the manual items replaced.
            let interest = try Category.filter(Column("name") == "Mortgage interest").fetchOne(db)!
            let rows = try Transaction.filter(Column("categoryId") == interest.id!).fetchAll(db)
            XCTAssertEqual(rows.map(\.amountMinorUnits), [-10_000])
            XCTAssertEqual(rows.first?.rawDescription, "Mortgage interest (instalment 10)")
            let items = try TaxManualItem.fetchAll(db)
            XCTAssertEqual(items.map(\.amountMinorUnits), [2_000])
            XCTAssertEqual(items.first?.label, "Paid elsewhere")
            // Rent: the split's rent part and December's credit pay the two receipts.
            XCTAssertEqual(try RentReceiptPayment.fetchCount(db), 2)
            XCTAssertEqual(try RentReceiptMatching.unmatchedReceipts(db: db, propertyId: try Property.fetchOne(db)!.id!).count, 0)
            // Legs linked: instalment, two subscriptions, the deposit part.
            XCTAssertEqual(try TransferLink.active.fetchCount(db), 4)
        }
        // The filed year: only the not-deductible information line moved (the bank fee).
        XCTAssertFalse(report.acceptedFiledChanges.isEmpty)
        XCTAssertTrue(report.acceptedFiledChanges.allSatisfy { $0.change.key.field.contains("notDeductible") })
        XCTAssertTrue(Import.text(report).contains("receipt 10 paid 2022-11-30"))

        // Running again writes nothing.
        XCTAssertThrowsError(try manager.dbQueue.write { db in try Import.apply(db: db, statements: try statements(), plan: plan()) }) { error in
            guard case Import.ImportError.alreadyApplied = error else { return XCTFail("\(error)") }
        }
    }

    func testRefusesWhenAFiledYearWouldChangeUnexplained() throws {
        let manager = try makeDB()
        XCTAssertThrowsError(try manager.dbQueue.write { db in try Import.apply(db: db, statements: try statements(), plan: plan(accept: false)) }) { error in
            guard case Import.ImportError.verificationFailed(let text) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(text.contains("FAIL filed and paid tax years"))
        }
        // Nothing kept.
        try manager.dbQueue.read { db in XCTAssertEqual(try Transaction.fetchCount(db), 1) }
    }

    func testAcceptanceIsScopedToItsYear() throws {
        let manager = try makeDB()
        XCTAssertThrowsError(try manager.dbQueue.write { db in try Import.apply(db: db, statements: try statements(), plan: plan(acceptYear: 2021)) }) { error in
            guard case Import.ImportError.verificationFailed = error else { return XCTFail("\(error)") }
        }
    }

    func testPaidYearsAreGuardedAndAFiledReturnFigureCanBeReached() throws {
        // 2022/23 paid instead of filed: still guarded.
        let manager = try makeDB()
        try manager.dbQueue.write { db in try db.execute(sql: "UPDATE taxYear SET status = 'paid'") }
        XCTAssertThrowsError(try manager.dbQueue.write { db in try Import.apply(db: db, statements: try statements(), plan: plan(accept: false)) })
        // A moving figure that lands on the filed return's passes without an acceptance.
        let probe = try makeDB()
        var named = plan(accept: false)
        let report = try? probe.dbQueue.write { db in try Import.apply(db: db, statements: try statements(), plan: plan()) }
        let moved = try XCTUnwrap(report?.taxChanges.filter { $0.key.startYear == 2022 })
        XCTAssertFalse(moved.isEmpty)
        named.filedReturns = ["Person A", "Person B"].map { person in
            Import.FiledReturn(startYear: 2022, person: person, source: "test", fields: Dictionary(uniqueKeysWithValues: moved.filter { $0.key.person == person }.compactMap { change in
                guard case .amount(let value)? = change.after else { return nil }
                return (change.key.field, (value < 0 ? "-" : "") + String(abs(value) / 100) + "." + String(format: "%02d", abs(value) % 100))
            }))
        }
        let fresh = try makeDB()
        try fresh.dbQueue.write { db in try db.execute(sql: "UPDATE taxYear SET status = 'paid'") }
        let landed = try fresh.dbQueue.write { db in try Import.apply(db: db, statements: try statements(), plan: named) }
        XCTAssertTrue(landed.unexplainedFiledChanges.isEmpty)
        XCTAssertTrue(landed.filedComparison.allSatisfy { $0.hasPrefix("MATCH") })
    }

    func testStrictPlanAndPairingChecks() throws {
        XCTAssertThrowsError(try Import.decodePlan(Data(#"{"batchName": "B", "rules": [], "overides": []}"#.utf8)))
        XCTAssertThrowsError(try Import.decodePlan(Data(#"{"batchName": "B", "rules": [{"pattern": "X", "kind": "other", "category": "Other"}]}"#.utf8)))
        XCTAssertThrowsError(try Import.decodePlan(Data(#"{"batchName": "B", "rules": [{"pattern": "X", "kind": "other", "typo": 1}]}"#.utf8)))
        XCTAssertNoThrow(try Import.decodePlan(Data(#"{"generated": "today", "note": "n", "batchName": "B", "rules": []}"#.utf8)))
        // A fund movement with no subscription debit near it.
        let shifted = november.replacingOccurrences(of: "11/28 11/30 SUBSCRIÇÃO PERIÓDICA", with: "11/10 11/10 SUBSCRIÇÃO PERIÓDICA")
        let manager = try makeDB()
        XCTAssertThrowsError(try manager.dbQueue.write { db in
            try Import.apply(db: db, statements: [try BBVAStatementParser.parse(shifted), try BBVAStatementParser.parse(december)], plan: plan())
        })
        // A receipt's credits must add up to it.
        var linked = plan()
        linked.rentReceiptLinks = [Import.RentReceiptLink(tenancy: "Contract One", receiptNumber: "2", amount: "1000.00",
                                                          credits: [Import.Payment(date: "2022-12-20", amount: "900.00")])]
        XCTAssertThrowsError(try makeDB().dbQueue.write { db in try Import.apply(db: db, statements: try statements(), plan: linked) })
        // Parser: a receipt header without its detail line.
        XCTAssertThrowsError(try BBVAStatementParser.parse(november.replacingOccurrences(of: "2022-11-30           200,00", with: "x")))
        XCTAssertThrowsError(try BBVAStatementParser.parse(november.replacingOccurrences(of: "EMPRÉSTIMOS 9.800,00", with: "")))
        XCTAssertThrowsError(try BBVAStatementParser.parse(november.replacingOccurrences(of: "Saldo final 10,500 101,0000 1.060,50", with: "")))
    }

    func testRechargesOfATenancyWithoutStatementsAndYearNotes() throws {
        var withRecharges = plan()
        withRecharges.recharges = [Import.RechargeEntry(tenancy: "Contract One", month: "2022-12", description: "Utilities recharged",
                                                        credits: [Import.Payment(date: "2022-12-20", amount: "1000.00")])]
        withRecharges.taxYearNotes = [Import.TaxYearNote(startYear: 2022, note: "Disclosed elsewhere")]
        let manager = try makeDB()
        let report = try manager.dbQueue.write { db in try Import.apply(db: db, statements: try statements(), plan: withRecharges) }
        XCTAssertEqual(report.recharges.count, 1)
        try manager.dbQueue.read { db in
            let statement = try XCTUnwrap(try RechargeStatement.fetchOne(db))
            XCTAssertEqual(statement.status, .paid)
            XCTAssertEqual(statement.totalMinorUnits, 100_000)
            // The credit is wholly a recharge: it pays no rent.
            XCTAssertEqual(try RentReceiptMatching.unmatchedReceipts(db: db, propertyId: try Property.fetchOne(db)!.id!).map(\.receiptNumber), ["2"])
            XCTAssertEqual(try TaxYear.fetchAll(db).map(\.notes), ["Disclosed elsewhere", "Disclosed elsewhere"])
        }
    }

    func testRefusesOverlapAndAMismatchedOpening() throws {
        let manager = try makeDB()
        try manager.dbQueue.write { db in
            let bbva = try Account.filter(Column("name") == "BBVA").fetchOne(db)!
            try ManualTransactions.add(db: db, accountId: bbva.id!, date: day(2022, 12, 20), description: "TRF TENANT ONE", amountMinorUnits: 100_000, categoryId: nil, note: nil)
        }
        XCTAssertThrowsError(try manager.dbQueue.write { db in try Import.apply(db: db, statements: try statements(), plan: plan()) }) { error in
            guard case Import.ImportError.overlap(let text) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(text.contains("1 identical"))
        }
        let other = try makeDB()
        try other.dbQueue.write { db in try db.execute(sql: "UPDATE balanceSnapshot SET balanceMinorUnits = 1 WHERE date = ?", arguments: [day(2023, 1, 1)]) }
        XCTAssertThrowsError(try other.dbQueue.write { db in try Import.apply(db: db, statements: try statements(), plan: plan()) })
    }

    func testPlanDecodesWithDefaults() throws {
        let json = #"{"batchName": "B", "rules": [{"pattern": "X", "kind": "other"}]}"#
        let plan = try Import.decodePlan(Data(json.utf8))
        XCTAssertEqual(plan.batchName, "B")
        XCTAssertTrue(plan.overrides.isEmpty && plan.manualItems.isEmpty && !plan.matchRentReceipts)
    }
}
