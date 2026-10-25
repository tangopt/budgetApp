import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category
import TestSupport

/// Confirming a BBVA "EXTRATO GLOBAL" statement (`ImportEffects.perform(.bbvaStatement)`): the
/// current account's new rows, each instalment's loan leg and interest row, each subscription's
/// fund leg and the fund's Market movement, the accounts chosen in the review learnt — one
/// undoable run, simulated by the filed-year guard. Synthetic statements only.
final class BBVAStatementApplyTests: XCTestCase {
    private var manager: DatabaseManager!
    private var dbQueue: DatabaseQueue { manager.dbQueue }
    private var folder: URL!
    private var library: EvidenceLibrary!
    private var pipeline: ImportPipeline!
    private var applier: ImportApplier!
    private var bbvaId: Int64!
    private var loanId: Int64!
    private var fundId: Int64!
    private var interestId: Int64!

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("BBVAStatementApplyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        library = EvidenceLibrary(root: folder.appendingPathComponent("Library", isDirectory: true), database: dbQueue)
        pipeline = ImportPipeline(dbQueue: dbQueue, library: library, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        applier = ImportApplier(dbQueue: dbQueue, databasePath: nil, library: library)
    }

    override func tearDownWithError() throws {
        pipeline.discardPlanningCopy()
        try? FileManager.default.removeItem(at: folder)
    }

    /// BBVA (€2,500.00 on 31 Jan 2026), a loan owing `loanOwing` (default €10,500.00) and the
    /// fund at €1,000.00 — the mortgage named `loanName` (the default name is found by name) —
    /// and the "Mortgage interest" category.
    private func makeAccounts(loanOwing: Int = 1_050_000, loanName: String = BBVAFundMortgageImport.loanAccountName) throws {
        try dbQueue.write { db in
            bbvaId = try AccountEditing.add(db: db, name: BBVAHistoryImport.accountName, currency: .eur, kind: .cash, openingBalanceEntered: 250_000,
                                            asOf: day(2026, 1, 31)).id!
            loanId = try AccountEditing.add(db: db, name: loanName, currency: .eur, kind: .credit, openingBalanceEntered: loanOwing,
                                            asOf: day(2026, 1, 31), includeInNetWorth: false).id!
            fundId = try AccountEditing.add(db: db, name: BBVAFundMortgageImport.fundAccountName, currency: .eur, kind: .investment,
                                            openingBalanceEntered: 100_000, asOf: day(2026, 1, 31)).id!
            let costs = try CategoryGroups.create(db: db, name: "Flat costs", type: .expense)
            interestId = try Categories.create(db: db, name: BBVAFundMortgageImport.interestCategoryName, type: .expense, groupId: costs.id).id!
        }
    }

    // MARK: Synthetic statements

    /// February 2026: the mortgage instalment (receipt 40: capital €700.00, interest €112.53,
    /// leaving €9,800.00 owing), a fund subscription of €50.00 (fund closing €1,060.50) and a
    /// shop payment: 3 rows, closing €1,627.47.
    private func february(capital: String = "700,00", interest: String = "112,53", owing: String = "9.800,00") -> String {
        """
        EXTRATO GLOBAL
        PERÍODO DE 2026/02/01 A 2026/02/28
        ACTIVO
        DEPÓSITOS À ORDEM 1.627,47
        PRODUTOS DE POUPANÇA 1.060,50
        PASSIVO
        EMPRÉSTIMOS \(owing)
        Conta Nº: 000/123456789   EUR   CONTA BBVA
        Saldo inicial 2.500,00
        02/05 02/05 COBR. REC. TOT 000 00-000000-0 -812,53 1.687,47
        02/20 02/20 SUBSCRIÇÃO PERI         100,0000 -50,00 1.637,47
        02/27 02/27 PAGAMENTO LOJA EXEMPLO -10,00 1.627,47
        Saldo final 1.627,47
        Saldo disponivel 1.627,47
        Conta Nº: 000/222222222 EUR SAMPLE FUND
        Saldo inicial 10,000 100,0000 1.000,00
        02/18 02/20 SUBSCRIÇÃO PERIÓDICA 0,500 100,0000 50,00
        Saldo final 10,500 101,0000 1.060,50
        Conta Nº: 000/333333333 EUR HOME LOAN
        Capital em Dívida \(owing)
        COBRANÇAS EFECTUADAS
        Nº. Recibo: 40/480 Data Inicio Liquidação: 2026-01-05 Total recibo:             812,53
        Data Valor: 2026-02-05 Data Fim Liquidação: 2026-02-05
        T.A.N. : 1,200%  (EUR 3M     0,200% + SPREAD  1,000%)
        Data Oper. Capital Juros Comissões Juros de Mora Impostos Total EUR Total em atraso Capital em dívida
        2026-02-05           \(capital)       \(interest)         0,00             0,00         0,00           812,53             0,00       \(owing)
        """
    }

    /// March 2026 after `february()`: receipt 41 (capital €710.00, interest €102.53, leaving
    /// €9,090.00 owing) and nothing else; closing €814.94.
    private func march() -> String {
        """
        EXTRATO GLOBAL
        PERÍODO DE 2026/03/01 A 2026/03/31
        ACTIVO
        DEPÓSITOS À ORDEM 814,94
        PASSIVO
        EMPRÉSTIMOS 9.090,00
        Conta Nº: 000/123456789   EUR   CONTA BBVA
        Saldo inicial 1.627,47
        03/05 03/05 COBR. REC. TOT 000 00-000000-0 -812,53 814,94
        Saldo final 814,94
        Conta Nº: 000/333333333 EUR HOME LOAN
        Capital em Dívida 9.090,00
        COBRANÇAS EFECTUADAS
        Nº. Recibo: 41/480 Data Inicio Liquidação: 2026-02-05 Total recibo:             812,53
        Data Valor: 2026-03-05 Data Fim Liquidação: 2026-03-05
        Data Oper. Capital Juros Comissões Juros de Mora Impostos Total EUR Total em atraso Capital em dívida
        2026-03-05           710,00       102,53         0,00             0,00         0,00           812,53             0,00       9.090,00
        """
    }

    /// The first ten days of February only (a partial download): the instalment and its receipt.
    private func earlyFebruary() -> String {
        """
        EXTRATO GLOBAL
        PERÍODO DE 2026/02/01 A 2026/02/10
        ACTIVO
        DEPÓSITOS À ORDEM 1.687,47
        PASSIVO
        EMPRÉSTIMOS 9.800,00
        Conta Nº: 000/123456789   EUR   CONTA BBVA
        Saldo inicial 2.500,00
        02/05 02/05 COBR. REC. TOT 000 00-000000-0 -812,53 1.687,47
        Saldo final 1.687,47
        Conta Nº: 000/333333333 EUR HOME LOAN
        Capital em Dívida 9.800,00
        COBRANÇAS EFECTUADAS
        Nº. Recibo: 40/480 Data Inicio Liquidação: 2026-01-05 Total recibo:             812,53
        Data Valor: 2026-02-05 Data Fim Liquidação: 2026-02-05
        Data Oper. Capital Juros Comissões Juros de Mora Impostos Total EUR Total em atraso Capital em dívida
        2026-02-05           700,00       112,53         0,00             0,00         0,00           812,53             0,00       9.800,00
        """
    }

    private func fileYear() async throws {
        try await dbQueue.write { db in
            var person = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &person)
            var year = TaxYear(startYear: 2023, personId: person.id!, status: .filed)
            try year.insert(db)
        }
    }

    /// February 2026 with no mortgage or fund: rent and two shop payments, closing €3,470.00.
    private func plainFebruary() -> String {
        """
        EXTRATO GLOBAL
        PERÍODO DE 2026/02/01 A 2026/02/28
        DEPÓSITOS À ORDEM 3.470,00
        Conta Nº: 000/123456789   EUR   CONTA BBVA
        Saldo inicial 2.500,00
        02/02 02/02 TRF TENANT ONE 1.000,00 3.500,00
        02/27 02/27 PAGAMENTO LOJA EXEMPLO -10,00 3.490,00
        02/28 02/28 PAGAMENTO LOJA DOIS -20,00 3.470,00
        Saldo final 3.470,00
        """
    }

    private func pdf(_ text: String, name: String) -> URL {
        EvidenceTestPDFs.textPDF(text.components(separatedBy: "\n"), name: name)
    }

    private func plan(_ text: String, name: String = "extrato-2026-02.pdf") async throws -> ImportPlan {
        pipeline.discardPlanningCopy()
        return try await pipeline.plan([pdf(text, name: name)])
    }

    private func statement(_ plan: ImportPlan) throws -> ImportItem {
        try XCTUnwrap(plan.items.first { $0.parentId == nil }, "\(plan.items.map(\.title))")
    }

    private func effect(_ item: ImportItem) throws -> BBVAStatementEffect {
        guard case .bbvaStatement(let effect) = item.effect else {
            XCTFail("not a BBVA statement effect: \(item.effect)")
            throw CancellationError()
        }
        return effect
    }

    private func rows(_ accountId: Int64) throws -> [Transaction] {
        try dbQueue.read { db in try Transaction.filter(Column("accountId") == accountId).order(Column("date"), Column("id")).fetchAll(db) }
    }

    private func balance(_ accountId: Int64, at date: Date) throws -> Int {
        try dbQueue.read { db in
            NetWorthCalculator.balance(accountId: accountId, at: BalanceUpdates.endOfDay(date),
                                       snapshots: try BalanceSnapshot.filter(Column("accountId") == accountId).fetchAll(db),
                                       transactions: try Transaction.filter(Column("accountId") == accountId).fetchAll(db))?.native ?? 0
        }
    }

    // MARK: Applying

    func testApplyAddsRowsLegsInterestAndMarketMovement() async throws {
        try makeAccounts()
        let plan = try await plan(february())
        let item = try statement(plan)
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        let summary = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(summary.transactions, 3)

        // BBVA: the statement's movements, closing at its balance.
        let current = try rows(bbvaId)
        XCTAssertEqual(current.map(\.amountMinorUnits), [-81_253, -5_000, -1_000])
        XCTAssertEqual(try balance(bbvaId, at: day(2026, 2, 28)), 162_747)
        let batch = try await dbQueue.read { db in try ImportBatch.fetchOne(db, key: current.first?.importBatchId ?? -1) }
        XCTAssertEqual(batch?.sourceFileName, "BBVA extrato 2026-02")
        XCTAssertEqual(batch?.importRunId, summary.runId)

        // The loan: the instalment's leg (+total) and its interest (−charges): owing €9,800.00.
        let loan = try rows(loanId)
        XCTAssertEqual(loan.map(\.amountMinorUnits), [81_253, -11_253])
        let interest = try XCTUnwrap(loan.first { $0.amountMinorUnits == -11_253 })
        XCTAssertEqual(interest.rawDescription, "Mortgage interest (instalment 40)")
        XCTAssertEqual(interest.categoryId, interestId)
        XCTAssertEqual(try balance(loanId, at: day(2026, 2, 28)), -980_000)
        // The instalment debit is a transfer to the loan.
        let links = try await dbQueue.read { db in try TransferLink.active.fetchAll(db) }
        XCTAssertTrue(links.contains { $0.outTransactionId == current.first?.id && loan.map(\.id).contains($0.inTransactionId) }, "\(links)")

        // The fund: the subscription's leg and the Market movement to the statement's value.
        let fund = try rows(fundId)
        XCTAssertEqual(fund.map(\.amountMinorUnits), [5_000, 1_050])
        XCTAssertEqual(try balance(fundId, at: day(2026, 2, 28)), 106_050)
        let market = try await dbQueue.read { db in try BuiltInCategories.category(db: db, role: .marketMovement) }
        XCTAssertEqual(fund.last?.categoryId, market.id)
        XCTAssertEqual(fund.last?.date, day(2026, 2, 28))
    }

    func testReimportingSameMonthAddsNothing() async throws {
        try makeAccounts()
        let first = try await plan(february())
        _ = try applier.apply(first, entryPoint: "Test")
        let counts = try [rows(bbvaId).count, rows(loanId).count, rows(fundId).count]

        let again = try await plan(february(), name: "extrato-2026-02 (1).pdf")
        let item = try statement(again)
        XCTAssertEqual(item.section, .duplicates, "\(item.needsYouReasons)")
        XCTAssertEqual(item.duplicate?.of, "Already imported: 3 rows")

        // Forced through perform with no new rows: no new loan or fund rows (the Market movement exists).
        var forced = try effect(try statement(first))
        forced.staged = []
        forced.instalments = []
        forced.fundPairs = []
        try await dbQueue.write { db in try ImportEffects.perform(db: db, .bbvaStatement(forced), documentId: nil, importRunId: nil) }
        XCTAssertEqual(try [rows(bbvaId).count, rows(loanId).count, rows(fundId).count], counts)
    }

    func testOverlappingStatementAddsOnlyMissingRows() async throws {
        try makeAccounts()
        let staged = try effect(try statement(try await plan(plainFebruary()))).staged
        XCTAssertEqual(staged.count, 3)
        // Two of its rows saved by an earlier download.
        try await dbQueue.write { db in
            _ = try ImportCoordinator.commit(db: db, accountId: self.bbvaId, sourceFileName: "earlier", staged: Array(staged.prefix(2)), decisions: [])
        }
        let plan = try await plan(plainFebruary(), name: "extrato-2026-02-again.pdf")
        let item = try statement(plan)
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertEqual(try effect(item).staged.count, 1)
        let summary = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(summary.transactions, 1)
        XCTAssertEqual(try rows(bbvaId).map(\.amountMinorUnits), [100_000, -1_000, -2_000])
        XCTAssertEqual(try balance(bbvaId, at: day(2026, 2, 28)), 347_000)
    }

    func testUndoRemovesLegsAndInterestToo() async throws {
        // The mortgage isn't found by name: chosen in the review, and learnt.
        try makeAccounts(loanName: "Home loan")
        var plan = try await plan(february())
        let item = try statement(plan)
        plan = try await pipeline.resolve(plan, itemId: item.id, .chooseAccount(.mortgage, loanId))
        let chosen = try statement(plan)
        XCTAssertEqual(chosen.section, .ready, "\(chosen.needsYouReasons)")
        let summary = try applier.apply(plan, entryPoint: "Test")
        let rules = try await dbQueue.read { db in try ImportRuleStore.all(db: db) }
        XCTAssertEqual(rules.map(\.matchKey), ["bbva-mortgage:000123456789"])
        XCTAssertEqual(rules.first?.actionJSON, "{\"accountId\":\(loanId!)}")
        XCTAssertEqual(try rows(loanId).count, 2)
        XCTAssertEqual(try rows(fundId).count, 2)

        _ = try ImportUndo.undo(dbQueue: dbQueue, library: library, runId: summary.runId)
        XCTAssertEqual(try rows(bbvaId).count, 0)
        XCTAssertEqual(try rows(loanId).count, 0, "the leg and the interest row go too")
        XCTAssertEqual(try rows(fundId).count, 0, "the leg and the Market movement go too")
        let left = try await dbQueue.read { db in (try ImportRule.fetchCount(db), try TransferLink.fetchCount(db)) }
        XCTAssertEqual(left.0, 0, "the learnt choice goes too")
        XCTAssertEqual(left.1, 0)
    }

    func testRememberedAccountsAreMarkedUsedWhenApplied() async throws {
        // Neither the current account nor the mortgage is found by name: both remembered.
        try makeAccounts(loanName: "Home loan")
        let bbvaId = bbvaId!, loanId = loanId!
        try await dbQueue.write { db in
            var current = try Account.fetchOne(db, key: bbvaId)!
            current.name = "Main account"
            try current.update(db)
            for (key, id) in [("bbva:000123456789", bbvaId), ("bbva-mortgage:000123456789", loanId)] {
                try ImportRuleStore.learn(db: db, kind: .statementAccount, key: key, matchLabel: key,
                                          action: StatementAccountAction(accountId: id), actionLabel: "Account", now: Date())
            }
        }
        let plan = try await plan(february())
        let item = try statement(plan)
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertEqual(Set(try effect(item).rememberedRuleIds).count, 2)
        _ = try applier.apply(plan, entryPoint: "Test")
        let used = try await dbQueue.read { db in try ImportRuleStore.all(db: db).map(\.useCount) }
        XCTAssertEqual(used, [1, 1])
    }

    func testItemsOfOneAccountAreAppliedInPeriodOrder() async throws {
        try makeAccounts()
        let march = """
            EXTRATO GLOBAL
            PERÍODO DE 2026/03/01 A 2026/03/31
            DEPÓSITOS À ORDEM 1.617,47
            Conta Nº: 000/123456789   EUR   CONTA BBVA
            Saldo inicial 1.627,47
            03/10 03/10 PAGAMENTO LOJA EXEMPLO -10,00 1.617,47
            Saldo final 1.617,47
            """
        pipeline.discardPlanningCopy()
        let plan = try await pipeline.plan([pdf(march, name: "march.pdf"), pdf(february(), name: "february.pdf")])
        // The plan as handed in: March first.
        var reordered = plan
        reordered.items.sort { a, b in a.file.fileName == "march.pdf" && b.file.fileName != "march.pdf" }
        let applied = ImportApplier.appliedItems(reordered).map(\.title)
        XCTAssertEqual(applied, ["BBVA statement 2026-02", "BBVA statement 2026-03"])
        _ = try applier.apply(reordered, entryPoint: "Test")
        let batches = try await dbQueue.read { db in
            try ImportBatch.filter(Column("accountId") == self.bbvaId).order(Column("id")).fetchAll(db).map(\.sourceFileName)
        }
        XCTAssertEqual(batches, ["BBVA extrato 2026-02", "BBVA extrato 2026-03"])
    }

    // MARK: Mortgage balance

    func testMortgageBalanceOffIsNeedsYouRefusedAndHeldByTheGuard() async throws {
        // The loan owes €100.00 more than the statement's receipt leaves.
        try makeAccounts(loanOwing: 1_060_000)
        let plan = try await plan(february())
        let item = try statement(plan)
        // Seen in the review, with no year filed.
        XCTAssertEqual(item.section, .needsYou)
        let text = "Mortgage balance after BBVA statement 2026-02 would be −€9,900.00, the statement says −€9,800.00"
        XCTAssertTrue(item.issues.contains { $0.reason == text && $0.kind == .statement(.instalmentMismatch(text)) }, "\(item.issues.map(\.reason))")

        // The apply-time backstop names the statement; nothing is written.
        let backstop: Error? = await { () async -> Error? in
            do {
                try await dbQueue.write { db in try ImportEffects.perform(db: db, item.effect, documentId: nil, importRunId: nil) }
                return nil
            } catch { return error }
        }()
        guard case ImportApplyError.planOutdated(let reason)? = backstop else { return XCTFail("\(String(describing: backstop))") }
        XCTAssertTrue(reason.hasPrefix("BBVA mortgage balance after BBVA statement 2026-02"), reason)
        XCTAssertEqual(try rows(bbvaId).count, 0, "nothing written")

        // With a filed year, the guard simulates the confirmation: a hold with a readable reason.
        try await fileYear()
        let held = try await dbQueue.write { db in try FiledYearGuard.annotate([item], db: db) }[0]
        let issue = try XCTUnwrap(held.issues.first { $0.id == FiledYearGuard.checkFailedIssueId }, "\(held.issues)")
        XCTAssertTrue(issue.reason.hasPrefix("BBVA mortgage balance"), issue.reason)
        XCTAssertTrue(issue.reason.hasSuffix("leave it out of this import"), issue.reason)
        XCTAssertEqual(issue.offers, [.leaveOut])
        XCTAssertEqual(held.section, .needsYou)

        // The single-item check gives the same hold.
        try await dbQueue.write { db in
            XCTAssertThrowsError(try FiledYearGuard.impacts(db: db, item: item, filedYears: [2023])) { error in
                let hold = FiledYearGuard.holdIssue(for: error)
                XCTAssertEqual(hold.id, FiledYearGuard.checkFailedIssueId)
                XCTAssertTrue(hold.reason.hasPrefix("BBVA mortgage balance"), hold.reason)
                XCTAssertEqual(hold.offers, [.leaveOut])
            }
        }
    }

    func testConsecutiveMonthsWithInstalmentsAndAFiledYearAreBothReady() async throws {
        try makeAccounts()
        try await fileYear()
        pipeline.discardPlanningCopy()
        let plan = try await pipeline.plan([pdf(march(), name: "march.pdf"), pdf(february(), name: "february.pdf")])
        let statements = plan.items.filter { $0.parentId == nil }
        XCTAssertEqual(statements.count, 2)
        for item in statements { XCTAssertEqual(item.section, .ready, "\(item.title): \(item.needsYouReasons)") }
        _ = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(try balance(loanId, at: day(2026, 3, 31)), -909_000)
        XCTAssertEqual(try rows(loanId).filter { $0.rawDescription.hasPrefix("Mortgage interest") }.count, 2)
    }

    func testAMatchingCreditElsewhereNeitherBreaksConfirmNorTakesTheInstalment() async throws {
        try makeAccounts()
        let savings = try await dbQueue.write { db -> Int64 in
            let id = try AccountEditing.add(db: db, name: "Savings", currency: .eur, kind: .cash, openingBalanceEntered: 0, asOf: self.day(2026, 1, 31)).id!
            let parsed = ParsedTransaction(date: self.day(2026, 2, 6), rawDescription: "TRANSFER IN", amountMinorUnits: 81_253, balanceAfterMinorUnits: nil)
            let row = StagedTransaction(parsed: parsed, suggestedCategoryId: nil, source: .none, confidence: 0, fingerprint: "savings-credit")
            _ = try ImportCoordinator.commit(db: db, accountId: id, sourceFileName: "savings.csv", staged: [row], decisions: [])
            return id
        }
        let plan = try await plan(february())
        let item = try statement(plan)
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        let effect = try effect(item)
        let instalment = try XCTUnwrap(effect.instalments.first)
        XCTAssertNil(effect.staged[instalment.movementIndex].transfer, "a paired instalment is the loan's transfer, not another account's")
        _ = try applier.apply(plan, entryPoint: "Test")
        let debit = try XCTUnwrap(try rows(bbvaId).first)
        let credit = try XCTUnwrap(try rows(savings).first)
        let links = try await dbQueue.read { db in try TransferLink.active.fetchAll(db) }
        XCTAssertFalse(links.contains { $0.outTransactionId == debit.id && $0.inTransactionId == credit.id }, "\(links)")
        let legs = try rows(loanId).map(\.id)
        XCTAssertTrue(links.contains { $0.outTransactionId == debit.id && legs.contains($0.inTransactionId) }, "\(links)")
    }

    func testAReceiptWhoseDebitAnEarlierStatementOfTheBatchAddsIsNotMissing() async throws {
        try makeAccounts()
        pipeline.discardPlanningCopy()
        let plan = try await pipeline.plan([pdf(february(), name: "february.pdf"), pdf(earlyFebruary(), name: "early.pdf")])
        let statements = plan.items.filter { $0.parentId == nil }
        XCTAssertEqual(statements.count, 2)
        for item in statements {
            XCTAssertEqual(item.section, .ready, "\(item.title): \(item.needsYouReasons)")
        }
        _ = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(try rows(bbvaId).count, 3)
        XCTAssertEqual(try rows(loanId).count, 2)
        XCTAssertEqual(try balance(loanId, at: day(2026, 2, 28)), -980_000)
    }

    // MARK: Derived interest (the fund/mortgage tool's estimates)

    /// February saved as `BBVAFundMortgageImport` left it: the rows, the instalment a transfer to
    /// the loan with a "Mortgage interest (derived)" row of `derived`, the subscription's fund leg.
    private func saveFebruaryWithDerivedInterest(_ derived: Int, text: String? = nil) async throws {
        let staged = try effect(try statement(try await plan(text ?? february()))).staged
        try await dbQueue.write { db in
            _ = try ImportCoordinator.commit(db: db, accountId: self.bbvaId, sourceFileName: "BBVA history", staged: staged.map {
                StagedTransaction(parsed: $0.parsed, suggestedCategoryId: nil, source: .none, confidence: 0, fingerprint: $0.fingerprint)
            }, decisions: [])
            let saved = try Transaction.filter(Column("accountId") == self.bbvaId).order(Column("date")).fetchAll(db)
            let loanCategory = try XCTUnwrap(try TransferCategories.category(db: db, forAccountId: self.loanId)?.id)
            try TransactionEditing.setCategory(db: db, ids: [saved[0].id!], categoryId: loanCategory, remember: false)
            _ = try ManualTransactions.addOtherSide(db: db, transactionId: saved[0].id!, accountId: self.loanId)
            try ManualTransactions.add(db: db, accountId: self.loanId, date: self.day(2026, 2, 5), description: "Mortgage interest (derived)",
                                       amountMinorUnits: -derived, categoryId: self.interestId, note: "interest derived")
            let fundCategory = try XCTUnwrap(try TransferCategories.category(db: db, forAccountId: self.fundId)?.id)
            try TransactionEditing.setCategory(db: db, ids: [saved[1].id!], categoryId: fundCategory, remember: false)
            _ = try ManualTransactions.addOtherSide(db: db, transactionId: saved[1].id!, accountId: self.fundId)
        }
    }

    func testDerivedInterestThatDiffersAsksToReplaceTheEstimate() async throws {
        // The estimate (interest €110.00) left €9,797.47 owing; the receipt's split leaves €9,800.00.
        try makeAccounts()
        try await saveFebruaryWithDerivedInterest(11_000)
        var plan = try await plan(february(), name: "extrato-2026-02 (2).pdf")
        let item = try statement(plan)
        XCTAssertNil(item.duplicate, "an estimate to replace isn't a duplicate")
        XCTAssertEqual(item.section, .needsYou)
        let text = "Instalment of 05/02/2026: the interest was estimated (€110.00); the statement's receipt says €112.53. Replace the estimate?"
        let issue = try XCTUnwrap(item.issues.first { $0.reason == text }, "\(item.issues.map(\.reason))")
        XCTAssertEqual(issue.kind, .statement(.instalmentMismatch(text)))
        XCTAssertEqual(issue.offers, [.acknowledge])
        XCTAssertFalse(item.issues.contains { $0.reason.contains("without its mortgage legs") }, "the derived row counts as the legs")

        plan = try await pipeline.resolve(plan, itemId: item.id, issueId: issue.id, .acknowledge)
        let acknowledged = try statement(plan)
        XCTAssertEqual(acknowledged.section, .ready, "\(acknowledged.needsYouReasons)")
        let before = try rows(loanId).count
        _ = try applier.apply(plan, entryPoint: "Test")
        let loan = try rows(loanId)
        XCTAssertEqual(loan.count, before, "replaced, not added")
        XCTAssertFalse(loan.contains { $0.rawDescription == "Mortgage interest (derived)" })
        let interest = try XCTUnwrap(loan.first { $0.rawDescription == "Mortgage interest (instalment 40)" })
        XCTAssertEqual(interest.amountMinorUnits, -11_253)
        XCTAssertEqual(interest.categoryId, interestId)
        XCTAssertTrue(interest.note?.contains("40") == true, interest.note ?? "")
        XCTAssertEqual(try balance(loanId, at: day(2026, 2, 28)), -980_000)
        XCTAssertEqual(try rows(bbvaId).count, 3, "no new current-account rows")

        // Undo puts the estimate back.
        let run = try await dbQueue.read { db in try XCTUnwrap(try ImportRun.order(Column("id").desc).fetchOne(db)?.id) }
        _ = try ImportUndo.undo(dbQueue: dbQueue, library: library, runId: run)
        let restored = try XCTUnwrap(try rows(loanId).first { $0.id == interest.id })
        XCTAssertEqual(restored.rawDescription, "Mortgage interest (derived)")
        XCTAssertEqual(restored.amountMinorUnits, -11_000)
        XCTAssertEqual(restored.note, "interest derived")
    }

    func testAReceiptWithoutChargesRemovesTheEstimate() async throws {
        // All capital: the receipt leaves €9,687.47 owing; the estimate said €110.00 of interest.
        try makeAccounts()
        try await saveFebruaryWithDerivedInterest(11_000, text: february(capital: "812,53", interest: "0,00", owing: "9.687,47"))
        var plan = try await plan(february(capital: "812,53", interest: "0,00", owing: "9.687,47"), name: "extrato-2026-02 (4).pdf")
        let item = try statement(plan)
        let text = "Instalment of 05/02/2026: the interest was estimated (€110.00); the statement's receipt says €0.00. Replace the estimate?"
        let issue = try XCTUnwrap(item.issues.first { $0.reason == text }, "\(item.issues.map(\.reason))")
        plan = try await pipeline.resolve(plan, itemId: item.id, issueId: issue.id, .acknowledge)
        let acknowledged = try statement(plan)
        XCTAssertEqual(acknowledged.section, .ready, "\(acknowledged.needsYouReasons)")
        _ = try applier.apply(plan, entryPoint: "Test")
        XCTAssertFalse(try rows(loanId).contains { $0.rawDescription.hasPrefix("Mortgage interest") })
        XCTAssertEqual(try balance(loanId, at: day(2026, 2, 28)), -968_747)
    }

    func testDerivedInterestThatMatchesCountsAsDone() async throws {
        try makeAccounts()
        try await saveFebruaryWithDerivedInterest(11_253)
        try await dbQueue.write { db in
            // The fund already valued at the statement's figure.
            _ = try BBVAStatementLegs.marketMovement(db: db, fundAccountId: self.fundId, statement: try BBVAStatementParser.parse(self.february()),
                                                     since: nil, openingMinorUnits: nil)
        }
        let item = try statement(try await plan(february(), name: "extrato-2026-02 (3).pdf"))
        XCTAssertEqual(item.section, .duplicates, "\(item.needsYouReasons)")
        XCTAssertEqual(item.duplicate?.of, "Already imported: 3 rows")
    }

    // MARK: Statements already in the library (final review)

    /// `url` filed in the library as a plain document (its rows not saved): its display name.
    private func fileInLibrary(_ url: URL) throws -> (id: Int64, name: String) {
        let document = try library.add(url, metadata: EvidenceMetadata(kind: .bankStatement)).document
        return (try XCTUnwrap(document.id), document.displayName)
    }

    private func documentCount() throws -> Int {
        try dbQueue.read { db in try EvidenceDocument.fetchCount(db) }
    }

    func testAFiledStatementWithItsRowsUnsavedIsProcessedWithTheNextMonth() async throws {
        try makeAccounts()
        let februaryURL = pdf(february(), name: "february.pdf")
        let filed = try fileInLibrary(februaryURL)
        pipeline.discardPlanningCopy()
        let plan = try await pipeline.plan([februaryURL, pdf(march(), name: "march.pdf")])
        let feb = try XCTUnwrap(plan.items.first { $0.file.fileName == "february.pdf" && $0.parentId == nil })
        let mar = try XCTUnwrap(plan.items.first { $0.file.fileName == "march.pdf" && $0.parentId == nil })
        // February's rows and legs are its own: it is processed, not a duplicate.
        XCTAssertNil(feb.duplicate, "a filed statement whose rows aren't saved isn't a duplicate")
        XCTAssertEqual(feb.section, .ready, "\(feb.needsYouReasons)")
        XCTAssertTrue(feb.notes.contains("Document already in the library as \(filed.name)"), "\(feb.notes)")
        XCTAssertEqual(try effect(feb).staged.count, 3)
        XCTAssertEqual(try effect(feb).instalments.count, 1)
        XCTAssertEqual(mar.section, .ready, "\(mar.needsYouReasons)")
        XCTAssertEqual(ImportApplier.appliedItems(plan).filter { $0.parentId == nil }.map(\.title),
                       ["BBVA statement 2026-02", "BBVA statement 2026-03"])

        let summary = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(summary.transactions, 4)
        XCTAssertEqual(try rows(bbvaId).count, 4)
        XCTAssertEqual(try balance(bbvaId, at: day(2026, 3, 31)), 81_494)
        XCTAssertEqual(try rows(loanId).filter { $0.rawDescription.hasPrefix("Mortgage interest") }.count, 2)
        XCTAssertEqual(try balance(loanId, at: day(2026, 3, 31)), -909_000)
        // The library's document re-used: no second copy, February's file recorded against it.
        XCTAssertEqual(try documentCount(), 2)
        let februaryDocument = try await dbQueue.read { db in
            try ImportRunFile.filter(Column("runId") == summary.runId && Column("fileName") == "february.pdf").fetchOne(db)?.documentId
        }
        XCTAssertEqual(februaryDocument, filed.id)
        // Undo takes back what the run added, never the document that was already filed.
        _ = try ImportUndo.undo(dbQueue: dbQueue, library: library, runId: summary.runId)
        XCTAssertEqual(try rows(bbvaId).count, 0)
        let left = try await dbQueue.read { db in try EvidenceDocument.fetchAll(db).compactMap(\.id) }
        XCTAssertEqual(left, [filed.id])
    }

    func testAFiledStatementWhoseRowsAreAllSavedIsStillADuplicate() async throws {
        try makeAccounts()
        let url = pdf(february(), name: "february-filed.pdf")
        _ = try applier.apply(try await pipeline.plan([url]), entryPoint: "Test")
        pipeline.discardPlanningCopy()
        let again = try statement(try await pipeline.plan([url]))
        XCTAssertEqual(again.section, .duplicates, "\(again.needsYouReasons)")
    }

    func testAFiledStatementWithADerivedEstimateOffersToReplaceIt() async throws {
        try makeAccounts()
        try await saveFebruaryWithDerivedInterest(11_000)
        let url = pdf(february(), name: "filed-extrato.pdf")
        let filed = try fileInLibrary(url)
        pipeline.discardPlanningCopy()
        var plan = try await pipeline.plan([url])
        let item = try statement(plan)
        XCTAssertNil(item.duplicate, "an estimate to replace isn't a duplicate, filed or not")
        XCTAssertTrue(item.notes.contains("Document already in the library as \(filed.name)"), "\(item.notes)")
        let issue = try XCTUnwrap(item.issues.first { $0.id.hasPrefix("instalmentMismatch.estimate.") }, "\(item.issues.map(\.reason))")
        XCTAssertTrue(issue.reason.hasSuffix("Replace the estimate?"), issue.reason)
        plan = try await pipeline.resolve(plan, itemId: item.id, issueId: issue.id, .acknowledge)
        let acknowledged = try statement(plan)
        XCTAssertEqual(acknowledged.section, .ready, "\(acknowledged.needsYouReasons)")
        let documents = try documentCount()
        _ = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(try documentCount(), documents, "no second copy")
        XCTAssertTrue(try rows(loanId).contains { $0.rawDescription == "Mortgage interest (instalment 40)" && $0.amountMinorUnits == -11_253 })
    }

    func testAnAllImportedStatementWithoutItsMarketMovementAddsJustThat() async throws {
        try makeAccounts()
        _ = try applier.apply(try await plan(february()), entryPoint: "Test")
        // The fund's valuation on the period end removed (an older import never made it).
        let fundId = fundId!
        try await dbQueue.write { db in
            let market = try BuiltInCategories.category(db: db, role: .marketMovement)
            try db.execute(sql: "DELETE FROM transaction_ WHERE accountId = ? AND categoryId = ?", arguments: [fundId, market.id])
        }
        let counts = try [rows(bbvaId).count, rows(loanId).count]
        let plan = try await plan(february(), name: "extrato-2026-02 (again).pdf")
        let item = try statement(plan)
        XCTAssertNil(item.duplicate, "its market movement is still to add")
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertTrue(try effect(item).staged.isEmpty)
        _ = try applier.apply(plan, entryPoint: "Test")
        XCTAssertEqual(try [rows(bbvaId).count, rows(loanId).count], counts)
        XCTAssertEqual(try balance(fundId, at: day(2026, 2, 28)), 106_050)
        XCTAssertEqual(try rows(fundId).count, 2)
    }

    func testAnAllImportedStatementWhoseClosingDisagreesIsNeedsYou() async throws {
        try makeAccounts()
        _ = try applier.apply(try await plan(february()), entryPoint: "Test")
        // A row added by hand since: the saved data no longer closes at the statement's balance.
        let bbvaId = bbvaId!
        try await dbQueue.write { db in
            _ = try ManualTransactions.add(db: db, accountId: bbvaId, date: self.day(2026, 2, 10), description: "CASH", amountMinorUnits: -500,
                                           categoryId: nil, note: nil)
        }
        var plan = try await plan(february(), name: "extrato-2026-02 (check).pdf")
        let item = try statement(plan)
        XCTAssertNil(item.duplicate, "a closing that disagrees with the saved data is asked")
        XCTAssertEqual(item.section, .needsYou)
        let issue = try XCTUnwrap(item.issues.first { if case .statement(.balanceMismatch) = $0.kind { return true }; return false },
                                  "\(item.issues.map(\.reason))")
        guard case .statement(.balanceMismatch(let mismatch)) = issue.kind else { return XCTFail() }
        XCTAssertEqual(mismatch.statementMinorUnits - mismatch.computedMinorUnits, 500)
        plan = try await pipeline.resolve(plan, itemId: item.id, .importAnyway(reason: "The cash row is mine"))
        XCTAssertEqual(try statement(plan).section, .ready)
    }

    func testFiledYearCausesNameTheInterestRows() async throws {
        try makeAccounts()
        let item = try statement(try await plan(february()))
        let causes = try await dbQueue.read { db in try FiledYearGuard.causes(db: db, item: item) }
        XCTAssertTrue(causes.contains("2026-02-05 Mortgage interest (instalment 40) -€112.53"), "\(causes)")
    }

    // MARK: Final review, round 2

    func testAFullyImportedStatementWithUnreadLinesIsADuplicate() async throws {
        try makeAccounts()
        let text = february().replacingOccurrences(of: "02/20 02/20 SUBSCRIÇÃO PERI", with: "LINHA ESTRANHA SEM VALOR\n02/20 02/20 SUBSCRIÇÃO PERI")
        let url = pdf(text, name: "unread.pdf")
        pipeline.discardPlanningCopy()
        var plan = try await pipeline.plan([url])
        let first = try statement(plan)
        let unread = try XCTUnwrap(first.issues.first { $0.id == "unparsedLines" }, "\(first.issues.map(\.reason))")
        plan = try await pipeline.resolve(plan, itemId: first.id, issueId: unread.id, .acknowledge)
        _ = try applier.apply(plan, entryPoint: "Test")
        // Dropped again (the same file, in the library now): its unread lines are only a question.
        pipeline.discardPlanningCopy()
        let again = try statement(try await pipeline.plan([url]))
        XCTAssertEqual(again.section, .duplicates, "\(again.needsYouReasons)")
    }

    func testTwoCopiesOfAFiledStatementAreProcessedOnce() async throws {
        try makeAccounts()
        try await saveFebruaryWithDerivedInterest(11_000)
        let url = pdf(february(), name: "twice.pdf")
        let filed = try fileInLibrary(url)
        let copy = folder.appendingPathComponent("twice copy.pdf")
        try FileManager.default.copyItem(at: url, to: copy)
        pipeline.discardPlanningCopy()
        var plan = try await pipeline.plan([url, copy])
        let statements = plan.items.filter { $0.parentId == nil }
        XCTAssertEqual(statements.count, 2)
        let processed = try XCTUnwrap(statements.first { $0.duplicate == nil }, "\(statements.map { $0.duplicate?.of ?? "-" })")
        XCTAssertEqual(statements.filter { $0.duplicate == nil }.count, 1, "\(statements.map { $0.duplicate?.of ?? "-" })")
        XCTAssertEqual(statements.first { $0.duplicate != nil }?.duplicate?.of, "Identical file: already in the library as \(filed.name)")
        let issue = try XCTUnwrap(processed.issues.first { $0.id.hasPrefix("instalmentMismatch.estimate.") }, "\(processed.issues.map(\.reason))")
        plan = try await pipeline.resolve(plan, itemId: processed.id, issueId: issue.id, .acknowledge)
        _ = try applier.apply(plan, entryPoint: "Test")
        let loan = try rows(loanId)
        XCTAssertEqual(loan.filter { $0.rawDescription == "Mortgage interest (instalment 40)" }.count, 1)
        XCTAssertFalse(loan.contains { $0.rawDescription == "Mortgage interest (derived)" })
        XCTAssertEqual(try documentCount(), 1)
    }
}
