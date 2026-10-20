import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category

/// BBVA Portugal "EXTRATO GLOBAL" statements in the document importer (`BBVAStatementReader`):
/// recognised, resolved to the current, mortgage and fund accounts, staged with rules only, the
/// instalments and fund subscriptions paired on the new rows, and every gap a Needs-you issue.
/// Synthetic statement text only (built as the earlier-history tests build theirs).
final class BBVAStatementReaderTests: XCTestCase {
    private var manager: DatabaseManager!
    private var dbQueue: DatabaseQueue { manager.dbQueue }
    private var bbvaId: Int64!
    private var rentId: Int64!

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
    }

    /// BBVA (opening €2,500.00 on 31 Jan 2026), and unless left out the BBVA mortgage and
    /// BBVA retirement fund (each with its transfer category); a "TENANT ONE" rule.
    private func makeAccounts(mortgage: Bool = true, fund: Bool = true, currentName: String = BBVAHistoryImport.accountName,
                              iban: String? = nil, accountNumber: String? = nil, loanNumber: String? = nil) throws {
        try dbQueue.write { db in
            let bbva = try AccountEditing.add(db: db, name: currentName, currency: .eur, kind: .cash, openingBalanceEntered: 250_000,
                                              asOf: day(2026, 1, 31))
            bbvaId = bbva.id!
            // Stored as is (a synthetic IBAN that no checksum validates).
            if let iban { try db.execute(sql: "UPDATE account SET iban = ? WHERE id = ?", arguments: [iban, bbvaId]) }
            if let accountNumber { try db.execute(sql: "UPDATE account SET accountNumber = ? WHERE id = ?", arguments: [accountNumber, bbvaId]) }
            if mortgage {
                let loan = try AccountEditing.add(db: db, name: BBVAFundMortgageImport.loanAccountName, currency: .eur, kind: .credit,
                                                  openingBalanceEntered: 1_050_000, asOf: day(2026, 1, 31), includeInNetWorth: false)
                if let loanNumber { try db.execute(sql: "UPDATE account SET accountNumber = ? WHERE id = ?", arguments: [loanNumber, loan.id!]) }
            }
            if fund {
                _ = try AccountEditing.add(db: db, name: BBVAFundMortgageImport.fundAccountName, currency: .eur, kind: .investment,
                                           openingBalanceEntered: 100_000, asOf: day(2026, 1, 31))
            }
            let group = try CategoryGroups.create(db: db, name: "Flat", type: .income)
            let rent = try Categories.create(db: db, name: "Rental income", type: .income, groupId: group.id)
            rentId = rent.id!
            let costs = try CategoryGroups.create(db: db, name: "Flat costs", type: .expense)
            _ = try Categories.create(db: db, name: BBVAFundMortgageImport.interestCategoryName, type: .expense, groupId: costs.id)
            var rule = Rule(matchPattern: "TENANT ONE", matchType: .contains, categoryId: rentId, priority: 10)
            try rule.insert(db)
        }
    }

    private func accountId(_ name: String) throws -> Int64 {
        try dbQueue.read { db in try XCTUnwrap(try Account.filter(Column("name") == name).fetchOne(db)?.id) }
    }

    // MARK: Synthetic statements

    /// February 2026: rent, the mortgage instalment, a fund subscription and a shop payment.
    /// `receipt`: with the COBRANÇAS EFECTUADAS receipt of the instalment; `instalmentAmount`
    /// the instalment row's amount ("-812,53").
    private func february(receipt: Bool = true, instalment: Bool = true, instalmentAmount: String = "-812,53",
                          extraLine: String? = nil, secondLoan: Bool = false) -> String {
        var lines = [
            "EXTRATO GLOBAL",
            "Exmo. Senhor",
            "PERÍODO DE 2026/02/01 A 2026/02/28",
            "ACTIVO",
            "DEPÓSITOS À ORDEM 2.627,47",
            "PRODUTOS DE POUPANÇA 1.060,50",
            "PASSIVO",
            "EMPRÉSTIMOS 9.800,00",
            "Pág. 1/2 2026/03/02 Extrato 2026/02",
            "Conta Nº: 000/123456789   EUR   CONTA BBVA",
            "IBAN: PT00 0000 0000 0000 0000 0000 0",
            "Saldo inicial 2.500,00",
            "02/02 02/02 TRF TENANT ONE      1.000,00 3.500,00",
        ]
        var balance = 350_000
        func money(_ cents: Int) -> String {
            let whole = abs(cents) / 100, fraction = abs(cents) % 100
            let grouped = whole >= 1000 ? "\(whole / 1000).\(String(format: "%03d", whole % 1000))" : "\(whole)"
            return (cents < 0 ? "-" : "") + grouped + "," + String(format: "%02d", fraction)
        }
        if instalment {
            let amount = BBVAStatementParser.minorUnits(instalmentAmount)!
            balance += amount
            lines.append("02/05 02/05 COBR. REC. TOT 000 00-000000-0 \(instalmentAmount) \(money(balance))")
        }
        if let extraLine { lines.append(extraLine) }
        if secondLoan {
            balance -= 10_000
            lines.append("02/10 02/10 COBR. REC. TOT 000 00-000000-9 -100,00 \(money(balance))")
        }
        balance -= 5_000
        lines.append("02/20 02/20 SUBSCRIÇÃO PERI         100,0000 -50,00 \(money(balance))")
        balance -= 1_000
        lines.append("02/27 02/27 PAGAMENTO LOJA EXEMPLO -10,00 \(money(balance))")
        lines += [
            "Saldo final \(money(balance))",
            "Saldo disponivel \(money(balance))",
            "Conta Nº: 000/222222222 EUR SAMPLE FUND",
            "Saldo inicial 10,000 100,0000 1.000,00",
            "02/18 02/20 SUBSCRIÇÃO PERIÓDICA 0,500 100,0000 50,00",
            "Saldo final 10,500 101,0000 1.060,50",
        ]
        if receipt {
            lines += [
                "Conta Nº: 000/333333333 EUR HOME LOAN",
                "Capital em Dívida 9.800,00",
                "COBRANÇAS EFECTUADAS",
                "Nº. Recibo: 40/480 Data Inicio Liquidação: 2026-01-05 Total recibo:             812,53",
                "Data Valor: 2026-02-05 Data Fim Liquidação: 2026-02-05",
                "T.A.N. : 1,200%  (EUR 3M     0,200% + SPREAD  1,000%)",
                "Data Oper. Capital Juros Comissões Juros de Mora Impostos Total EUR Total em atraso Capital em dívida",
                "2026-02-05           700,00       112,53         0,00             0,00         0,00           812,53             0,00       9.800,00",
            ]
        }
        if secondLoan {
            lines += [
                "Conta Nº: 000/444444444 EUR HOME LOAN TWO",
                "COBRANÇAS EFECTUADAS",
                "Nº. Recibo: 7/360 Data Inicio Liquidação: 2026-01-10 Total recibo:             100,00",
                "Data Valor: 2026-02-10 Data Fim Liquidação: 2026-02-10",
                "Data Oper. Capital Juros Comissões Juros de Mora Impostos Total EUR Total em atraso Capital em dívida",
                "2026-02-10            90,00        10,00         0,00             0,00         0,00           100,00             0,00       3.000,00",
            ]
        }
        return lines.joined(separator: "\n")
    }

    /// March 2026, opening at February's closing (€2,627.47 with the instalment): one shop payment.
    private func march(opening: String = "2.627,47") -> String {
        """
        EXTRATO GLOBAL
        PERÍODO DE 2026/03/01 A 2026/03/31
        DEPÓSITOS À ORDEM 2.617,47
        Conta Nº: 000/123456789   EUR   CONTA BBVA
        Saldo inicial \(opening)
        03/10 03/10 PAGAMENTO LOJA EXEMPLO -10,00 2.617,47
        Saldo final 2.617,47
        """
    }

    private func file(_ text: String, name: String = "extrato-2026-02.pdf", ocr: Bool = false) -> ImportFile {
        ImportFile(url: URL(fileURLWithPath: "/nonexistent/\(name)"), fileName: name, sha256: "sha-\(name)-\(text.hashValue)",
                   byteCount: Int64(text.utf8.count), fileExtension: "pdf", text: text, textStatus: .text, usedOCR: ocr)
    }

    private func coordinator() -> ImportCoordinator {
        let fake = FakeCategorizer()
        fake.stubbedSuggestion = CategorySuggestion(categoryName: "Eating Out", confidence: 0.95)
        return ImportCoordinator(dbQueue: dbQueue, categorizationService: CategorizationService(categorizer: fake))
    }

    private func context(_ intent: ImportIntent = .none) throws -> ImportContext {
        try dbQueue.read { db in try ImportContext.load(db: db, intent: intent, now: Date()) }
    }

    /// Detect → resolve → stage (rules only) → items, as the pipeline does.
    private func read(_ text: String, intent: ImportIntent = .none, ocr: Bool = false) async throws -> [ImportItem] {
        let file = file(text, ocr: ocr)
        let recognition = ImportDetector(providers: []).detect(file)
        XCTAssertEqual(recognition.kind, .bbvaStatement)
        let context = try context(intent)
        let resolution = try await dbQueue.read { db in try BBVAStatementReader.resolve(file: file, recognition: recognition, context: context, db: db) }
        guard case .resolved(let resolved) = resolution else {
            if case .unresolved(let item) = resolution { return [item] }
            return []
        }
        let staged = try await BBVAStatementReader.stage(resolved, coordinator: coordinator())
        return try await dbQueue.read { db in
            // Checked as the pipeline checks the review (`StatementChecks`), here alone.
            try StatementChecks.recheck(BBVAStatementReader.items(file: file, recognition: recognition, resolved: resolved, staged: staged,
                                                                  context: context, db: db), db: db)
        }
    }

    private func effect(_ item: ImportItem) throws -> BBVAStatementEffect {
        guard case .bbvaStatement(let effect) = item.effect else {
            XCTFail("not a BBVA statement effect: \(item.effect)")
            throw CancellationError()
        }
        return effect
    }

    private func statementIssues(_ item: ImportItem) -> [StatementIssue] {
        item.issues.compactMap { issue in
            if case .statement(let kind) = issue.kind { return kind }
            return nil
        }
    }

    // MARK: Recognition

    func testRecognisedFirstWithItsMonth() {
        let recognition = ImportDetector(providers: []).detect(file(february()))
        XCTAssertEqual(recognition, ImportRecognition(kind: .bbvaStatement, confidence: .certain, reason: "BBVA extrato global 2026-02"))
        // Accent-insensitive: a text layer that lost the accent still reads.
        let plain = file(february().replacingOccurrences(of: "PERÍODO", with: "PERIODO"))
        XCTAssertEqual(ImportDetector(providers: []).detect(plain).kind, .bbvaStatement)
        // Other bank statements are not BBVA's.
        let other = file("EXTRATO\nPERÍODO DE 2026/02/01 A 2026/02/28\nOutro Banco")
        XCTAssertNotEqual(ImportDetector(providers: []).detect(other).kind, .bbvaStatement)
    }

    func testDefaultReadersPutTheBBVAReaderBeforeTheUKOne() {
        let readers = ImportReaders.defaultReaders(providers: [])
        let bbva = readers.firstIndex { $0 is BBVAStatementReader }
        let uk = readers.firstIndex { $0 is UKStatementReader }
        XCTAssertNotNil(bbva)
        XCTAssertLessThan(bbva!, uk!)
        XCTAssertTrue(BBVAStatementReader().handles(.bbvaStatement))
        XCTAssertFalse(BBVAStatementReader().handles(.bankStatementPDF))
    }

    func testSignatureIsTheCurrentAccountDigits() throws {
        let key = try XCTUnwrap(StatementSignature.key(for: file(february()), kind: .bbvaStatement))
        XCTAssertEqual(key.key, "bbva:000123456789")
        XCTAssertEqual(key.label, "BBVA statement of account …6789")
    }

    // MARK: Reading

    func testStatementIsReadyWithRowsLegsAndClosing() async throws {
        try makeAccounts()
        let items = try await read(february())
        XCTAssertEqual(items.count, 1)
        let item = items[0]
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertEqual(item.title, "BBVA statement 2026-02")
        XCTAssertEqual(item.groupKey, BBVAStatementReader.groupKey)
        let effect = try effect(item)
        XCTAssertEqual(effect.staged.count, effect.statement.movements.count)
        XCTAssertEqual(effect.staged.count, 4)
        XCTAssertEqual(effect.instalments.count, 1)
        XCTAssertEqual(effect.fundPairs.count, 1)
        XCTAssertEqual(effect.currentAccountId, bbvaId)
        XCTAssertEqual(effect.loanAccountId, try accountId(BBVAFundMortgageImport.loanAccountName))
        XCTAssertEqual(effect.fundAccountId, try accountId(BBVAFundMortgageImport.fundAccountName))
        XCTAssertEqual(effect.closing, StatementClosing(date: day(2026, 2, 28), balanceMinorUnits: 262_747))
        XCTAssertEqual(effect.sourceFileName, "extrato-2026-02.pdf")
        XCTAssertTrue(effect.learnAccounts.isEmpty)
        // The legs point at the staged rows.
        XCTAssertEqual(effect.staged[effect.instalments[0].movementIndex].parsed.amountMinorUnits, -81_253)
        XCTAssertEqual(effect.staged[effect.fundPairs[0].movementIndex].parsed.amountMinorUnits, -5_000)
        XCTAssertTrue(ImportEffect.bbvaStatement(effect).mayChangeTaxFigures)

        func fact(_ field: ImportFigureField) -> ImportFactValue? { item.facts.first { $0.field == field }?.value }
        XCTAssertEqual(fact(.periodStart), .date(day(2026, 2, 1)))
        XCTAssertEqual(fact(.periodEnd), .date(day(2026, 2, 28)))
        XCTAssertEqual(fact(.openingBalance), .money(250_000, .eur))
        XCTAssertEqual(fact(.closingBalance), .money(262_747, .eur))
        XCTAssertEqual(fact(.rows), .text("4"))
        XCTAssertEqual(fact(.instalments), .text("1 instalment: interest €112.53, capital €700.00"))
        XCTAssertEqual(fact(.fund), .text("Fund: +€50.00, value €1,060.50"))
        XCTAssertTrue(item.facts.allSatisfy { $0.source == .textLayer && $0.confidence == .certain })
        XCTAssertEqual(Set(item.facts.map(\.field)).count, item.facts.count, "one fact per field")
        XCTAssertEqual(item.placement?.metadata.kind, .bankStatement)
        XCTAssertEqual(ImportPlan(items: items).readyGroups.first?.summary, "1 BBVA statement 2026-02 → 4 transactions")
    }

    func testRuleCategorisesAndOthersStayUncategorised() async throws {
        try makeAccounts()
        let effect = try effect(try await read(february())[0])
        func row(_ text: String) throws -> StagedTransaction {
            try XCTUnwrap(effect.staged.first { $0.parsed.rawDescription.contains(text) })
        }
        let loan = try accountId(BBVAFundMortgageImport.loanAccountName), fund = try accountId(BBVAFundMortgageImport.fundAccountName)
        let loanCategory = try await dbQueue.read { db in try TransferCategories.category(db: db, forAccountId: loan)?.id }
        let fundCategory = try await dbQueue.read { db in try TransferCategories.category(db: db, forAccountId: fund)?.id }
        XCTAssertEqual(try row("TENANT ONE").suggestedCategoryId, rentId)
        XCTAssertEqual(try row("TENANT ONE").source, .rule)
        XCTAssertEqual(try row("COBR. REC. TOT").suggestedCategoryId, loanCategory)
        XCTAssertEqual(try row("COBR. REC. TOT").source, .transfer)
        XCTAssertEqual(try row("SUBSCRIÇÃO").suggestedCategoryId, fundCategory)
        XCTAssertEqual(try row("SUBSCRIÇÃO").source, .transfer)
        XCTAssertNil(try row("LOJA EXEMPLO").suggestedCategoryId, "no history or model suggestion")
        XCTAssertEqual(try row("LOJA EXEMPLO").source, .none)
    }

    func testInstalmentWithoutReceiptIsAnIssue() async throws {
        try makeAccounts()
        let item = try await read(february(receipt: false))[0]
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertTrue(statementIssues(item).contains(.instalmentMismatch("Instalment of 05/02/2026 −€812.53 has no settled receipt on the statement")),
                      "\(item.issues)")
        XCTAssertEqual(try effect(item).instalments, [])
    }

    func testReceiptWithoutInstalmentDebitIsAnIssue() async throws {
        try makeAccounts()
        let item = try await read(february(instalment: false))[0]
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertTrue(statementIssues(item).contains(.instalmentMismatch("Receipt 40 (05/02/2026) has no instalment debit")), "\(item.issues)")
    }

    func testPositiveInstalmentLikeRowIsNeverPaired() async throws {
        try makeAccounts()
        // A reversal of the instalment: the receipt finds no debit, the credit no receipt.
        let item = try await read(february(instalmentAmount: "812,53"))[0]
        XCTAssertEqual(item.section, .needsYou)
        let issues = statementIssues(item)
        XCTAssertTrue(issues.contains(.instalmentMismatch("Instalment of 05/02/2026 €812.53 has no settled receipt on the statement")), "\(issues)")
        XCTAssertTrue(issues.contains(.instalmentMismatch("Receipt 40 (05/02/2026) has no instalment debit")), "\(issues)")
        XCTAssertEqual(try effect(item).instalments, [])
    }

    func testAccountFoundByIBANDigits() async throws {
        try makeAccounts(currentName: "Main PT", iban: "PT50 0019 0000 0012 3456 7894 7")
        let item = try await read(february())[0]
        XCTAssertEqual(try effect(item).currentAccountId, bbvaId)
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        let reference = try XCTUnwrap(item.facts.first { $0.field == .reference })
        XCTAssertEqual(reference.value, .text("Main PT"))
        XCTAssertEqual(reference.reason, "Account number matches Main PT")
    }

    func testAccountFoundByAccountNumberAndNeverWhenTwoMatch() async throws {
        try makeAccounts(currentName: "Main PT", accountNumber: "000/123456789")
        let first = try await read(february())[0]
        XCTAssertEqual(try effect(first).currentAccountId, bbvaId)
        try await dbQueue.write { db in
            let other = try AccountEditing.add(db: db, name: "Other PT", currency: .eur, kind: .cash, openingBalanceEntered: 0, asOf: self.day(2026, 1, 31))
            try db.execute(sql: "UPDATE account SET iban = ? WHERE id = ?", arguments: ["PT50 0035 0000 0012 3456 7894 1", other.id!])
        }
        let second = try await read(february())[0]
        XCTAssertEqual(statementIssues(second), [.unknownAccount], "two accounts match: never a guess")
    }

    func testLearntRuleWinsAndUnknownAccountIsNeedsYou() async throws {
        try makeAccounts(currentName: "Main PT")
        // No IBAN, no account named BBVA: unknown.
        let unknown = try await read(february())
        XCTAssertEqual(unknown.count, 1)
        XCTAssertEqual(statementIssues(unknown[0]), [.unknownAccount])
        XCTAssertTrue(unknown[0].issues[0].offers.contains(.chooseAccount(.current, bbvaId)), "\(unknown[0].issues[0].offers)")
        XCTAssertEqual(unknown[0].section, .needsYou)
        // A learnt rule for the signature names it.
        let id = bbvaId!
        try await dbQueue.write { db in
            _ = try ImportRuleStore.learn(db: db, kind: .statementAccount, key: "bbva:000123456789", matchLabel: "BBVA statement of account …6789",
                                          action: StatementAccountAction(accountId: id), actionLabel: "Account: Main PT", now: Date())
        }
        let item = try await read(february())[0]
        XCTAssertEqual(try effect(item).currentAccountId, bbvaId)
        XCTAssertEqual(item.recognition.reason, "Remembered: BBVA statement of account …6789 → Main PT")
        XCTAssertEqual(item.facts.first { $0.field == .reference }?.source, .learntRule)
    }

    func testChosenAccountsAreUsedAndLearnt() async throws {
        try makeAccounts(mortgage: false, currentName: "Main PT")
        let loan = try await dbQueue.write { db in
            try AccountEditing.add(db: db, name: "Home loan", currency: .eur, kind: .credit, openingBalanceEntered: 1_050_000,
                                   asOf: self.day(2026, 1, 31), includeInNetWorth: false).id!
        }
        let intent = ImportIntent(statementAccounts: [.current: bbvaId, .mortgage: loan])
        let item = try await read(february(), intent: intent)[0]
        let effect = try effect(item)
        XCTAssertEqual(effect.currentAccountId, bbvaId)
        XCTAssertEqual(effect.loanAccountId, loan)
        XCTAssertEqual(effect.learnAccounts, [.current: bbvaId, .mortgage: loan])
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
    }

    func testUnknownMortgageAccountAsksOnlyWhenThereAreReceipts() async throws {
        try makeAccounts(mortgage: false)
        let withReceipt = try await read(february())[0]
        XCTAssertTrue(statementIssues(withReceipt).contains(.unknownLinkedAccount(.mortgage)), "\(withReceipt.issues)")
        XCTAssertEqual(withReceipt.section, .needsYou)
        XCTAssertNil(try effect(withReceipt).loanAccountId)
        // No receipts (and no instalment): nothing to ask.
        let without = try await read(february(receipt: false, instalment: false))[0]
        XCTAssertFalse(statementIssues(without).contains(.unknownLinkedAccount(.mortgage)), "\(without.issues)")
        XCTAssertEqual(without.section, .ready, "\(without.needsYouReasons)")
    }

    func testMortgageFoundThroughThePropertyOfTheCurrentAccount() async throws {
        try makeAccounts(mortgage: false)
        let loan = try await dbQueue.write { db -> Int64 in
            let loan = try AccountEditing.add(db: db, name: "Home loan", currency: .eur, kind: .credit, openingBalanceEntered: 1_050_000,
                                              asOf: self.day(2026, 1, 31), includeInNetWorth: false)
            var property = Property(name: "Flat", country: "PT")
            try Properties.save(db: db, &property)
            _ = try Properties.setAccount(db: db, propertyId: property.id!, accountId: self.bbvaId, role: .current)
            _ = try Properties.setAccount(db: db, propertyId: property.id!, accountId: loan.id!, role: .mortgage)
            return loan.id!
        }
        let item = try await read(february())[0]
        XCTAssertEqual(try effect(item).loanAccountId, loan)
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
    }

    func testUnknownFundAccountAsksOnlyWhenThereIsAFund() async throws {
        try makeAccounts(fund: false)
        let item = try await read(february())[0]
        XCTAssertTrue(statementIssues(item).contains(.unknownLinkedAccount(.fund)), "\(item.issues)")
        let noFund = try await read(march(opening: "2.500,00"))[0]
        XCTAssertFalse(statementIssues(noFund).contains(.unknownLinkedAccount(.fund)), "\(noFund.issues)")
    }

    func testUnreadLinesNeedAcknowledging() async throws {
        try makeAccounts()
        let item = try await read(february(extraLine: "LINHA ESTRANHA SEM VALOR"))[0]
        XCTAssertTrue(statementIssues(item).contains(.unparsedLines(["LINHA ESTRANHA SEM VALOR"])), "\(item.issues)")
        XCTAssertEqual(item.issues.first { $0.id == "unparsedLines" }?.offers, [.acknowledge])
    }

    func testAlreadyImportedRowsAreCountedAndAllDuplicatesIsADuplicate() async throws {
        try makeAccounts()
        // Save the shop row of February as an earlier import did.
        let first = try effect(try await read(february())[0])
        let shop = try XCTUnwrap(first.staged.first { $0.parsed.rawDescription.contains("LOJA") })
        try await dbQueue.write { db in
            _ = try ImportCoordinator.commit(db: db, accountId: self.bbvaId, sourceFileName: "earlier", staged: [shop], decisions: [])
        }
        let items = try await read(february())
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(try effect(items[0]).staged.count, 3)
        XCTAssertEqual(items[1].parentId, items[0].id)
        XCTAssertEqual(items[1].duplicate, ImportDuplicate(level: .transactions, of: "Already imported: 1 row"))
        XCTAssertEqual(items[0].section, .ready, "\(items[0].needsYouReasons)")

        // Every row saved with its legs (as applying it does): the statement itself is a duplicate.
        try await saveWithLegs(first, except: [shop.fingerprint])
        // Its fund not valued yet on the period end: that market movement is still to add.
        let unvalued = try await read(february())
        XCTAssertNil(unvalued[0].duplicate, "the market movement is still to add")
        XCTAssertEqual(unvalued[0].section, .ready, "\(unvalued[0].needsYouReasons)")
        let fundId = try XCTUnwrap(first.fundAccountId)
        try await dbQueue.write { db in
            _ = try BBVAStatementLegs.marketMovement(db: db, fundAccountId: fundId, statement: first.statement, since: nil, openingMinorUnits: nil)
        }
        let again = try await read(february())
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(again[0].duplicate, ImportDuplicate(level: .transactions, of: "Already imported: 4 rows"))
        XCTAssertEqual(again[0].section, .duplicates, "\(again[0].needsYouReasons)")
    }

    /// The effect's rows saved, the instalment's loan leg and interest and the subscription's
    /// fund leg added (what Task 4's apply writes).
    private func saveWithLegs(_ effect: BBVAStatementEffect, except skipped: Set<String> = []) async throws {
        try await dbQueue.write { db in
            let rows = effect.staged.filter { !skipped.contains($0.fingerprint) }
            _ = try ImportCoordinator.commit(db: db, accountId: effect.currentAccountId, sourceFileName: "applied", staged: rows, decisions: [])
            let interest = try XCTUnwrap(try Category.filter(Column("name") == BBVAFundMortgageImport.interestCategoryName).fetchOne(db)?.id)
            func saved(_ index: Int) throws -> Int64 {
                try XCTUnwrap(try Transaction.filter(Column("accountId") == effect.currentAccountId && Column("fingerprint") == effect.staged[index].fingerprint).fetchOne(db)?.id)
            }
            for match in effect.instalments {
                try BBVAStatementLegs.addInstalment(db: db, instalmentRowId: try saved(match.movementIndex), receipt: match.receipt,
                                                    loanAccountId: effect.loanAccountId!, interestCategoryId: interest)
            }
            for pair in effect.fundPairs {
                try BBVAStatementLegs.addFundSubscription(db: db, subscriptionRowId: try saved(pair.movementIndex), fundAccountId: effect.fundAccountId!)
            }
        }
    }

    func testInstalmentImportedWithoutItsLegsIsNeedsYouEvenWhenEveryRowIsADuplicate() async throws {
        try makeAccounts()
        let first = try effect(try await read(february())[0])
        // Saved plainly (an old CSV import): no loan leg, no interest row, no fund leg.
        let plain = first.staged.map { StagedTransaction(parsed: $0.parsed, suggestedCategoryId: nil, source: .none, confidence: 0, fingerprint: $0.fingerprint) }
        try await dbQueue.write { db in
            _ = try ImportCoordinator.commit(db: db, accountId: self.bbvaId, sourceFileName: "old.csv", staged: plain, decisions: [])
        }
        let items = try await read(february())
        let item = items[0]
        XCTAssertNil(item.duplicate, "an instalment without its legs isn't done")
        XCTAssertEqual(item.section, .needsYou)
        let issues = statementIssues(item)
        XCTAssertTrue(issues.contains(.instalmentMismatch("Instalment of 05/02/2026 −€812.53 is already imported without its mortgage legs")), "\(issues)")
        XCTAssertTrue(issues.contains(.fundMismatch("Subscription of 20/02/2026 −€50.00 is already imported without its fund leg")), "\(issues)")
        XCTAssertEqual(items.last?.duplicate?.of, "Already imported: 4 rows")
    }

    func testReceiptsOfAnotherLoanContractAreNeverPaired() async throws {
        try makeAccounts(loanNumber: "000/333333333")
        let parsed = try BBVAStatementParser.parse(february(secondLoan: true))
        XCTAssertEqual(parsed.loanReceipts.map(\.contract), ["000/333333333", "000/444444444"])
        let item = try await read(february(secondLoan: true))[0]
        XCTAssertEqual(try effect(item).instalments.map(\.receipt.number), [40], "only the mortgage's own contract")
        let issues = statementIssues(item)
        XCTAssertTrue(issues.contains(.instalmentMismatch("Receipt 7 (10/02/2026) is of loan contract 000/444444444, not attributable to the mortgage")), "\(issues)")
        XCTAssertTrue(issues.contains(.instalmentMismatch("Instalment of 10/02/2026 −€100.00 has no settled receipt on the statement")), "\(issues)")
        XCTAssertEqual(item.section, .needsYou)
    }

    func testSeveralLoanContractsWithoutTheMortgageNumberPairNothing() async throws {
        try makeAccounts()
        let item = try await read(february(secondLoan: true))[0]
        XCTAssertEqual(try effect(item).instalments, [])
        let issues = statementIssues(item)
        XCTAssertTrue(issues.contains(.instalmentMismatch("Receipt 40 (05/02/2026) is of loan contract 000/333333333, not attributable to the mortgage")), "\(issues)")
        XCTAssertTrue(issues.contains(.instalmentMismatch("Receipt 7 (10/02/2026) is of loan contract 000/444444444, not attributable to the mortgage")), "\(issues)")
    }

    func testAccountChoicesAreOfferedAndOnlyThoseAreTaken() async throws {
        try makeAccounts(mortgage: false)
        let fund = try accountId(BBVAFundMortgageImport.fundAccountName)
        let loan = try await dbQueue.write { db in
            try AccountEditing.add(db: db, name: "Home loan", currency: .eur, kind: .credit, openingBalanceEntered: 1_050_000,
                                   asOf: self.day(2026, 1, 31), includeInNetWorth: false).id!
        }
        let item = try await read(february())[0]
        let issue = try XCTUnwrap(item.issues.first { $0.kind == .statement(.unknownLinkedAccount(.mortgage)) })
        XCTAssertTrue(issue.offers.contains(.chooseAccount(.mortgage, loan)))
        XCTAssertFalse(issue.offers.contains(.chooseAccount(.mortgage, bbvaId)), "not the statement's current account")
        XCTAssertFalse(issue.offers.contains(.chooseAccount(.mortgage, fund)), "not its fund")
        for refused in [ImportResolution.chooseAccount(.mortgage, 99_999), .chooseAccount(.mortgage, bbvaId), .chooseAccount(.mortgage, fund)] {
            XCTAssertThrowsError(try ImportResolutions.apply(refused, to: item)) { error in
                XCTAssertEqual(error as? ImportResolutionError, .notOffered(refused))
            }
        }
        XCTAssertNil(try ImportResolutions.apply(.chooseAccount(.mortgage, loan), to: item), "re-read with the chosen account")
        // A chosen role equal to another role's account is ignored.
        let clash = try await read(february(), intent: ImportIntent(statementAccounts: [.mortgage: bbvaId]))[0]
        XCTAssertNil(try effect(clash).loanAccountId)
    }

    func testTextRecognitionFactsNeedChecking() async throws {
        try makeAccounts()
        let recognition = ImportDetector(providers: []).detect(file(february(), ocr: true))
        XCTAssertEqual(recognition.kind, .bbvaStatement)
        XCTAssertEqual(recognition.confidence, .needsReview)
        let item = try await read(february(), ocr: true)[0]
        XCTAssertEqual(item.facts.first { $0.field == .closingBalance }?.source, .ocr)
        XCTAssertTrue(item.facts.filter { $0.field != .reference }.allSatisfy { $0.confidence == .needsReview })
        XCTAssertEqual(item.section, .needsYou)
    }

    func testNamedAccountWithOtherDetailsIsNotTaken() async throws {
        try makeAccounts(accountNumber: "000/999999999")
        let item = try await read(february())[0]
        XCTAssertEqual(statementIssues(item), [.unknownAccount])
    }

    func testUnparseableStatementCanBeFiledAsADocument() async throws {
        try makeAccounts()
        let items = try await read("EXTRATO GLOBAL BBVA\nPERÍODO DE garbled")
        let issue = try XCTUnwrap(items.first?.issues.first)
        XCTAssertTrue(issue.offers.contains(.chooseKind(.other)), "\(issue)")
    }

    func testEmptyDigitsGiveNoLearntKey() {
        let text = february().replacingOccurrences(of: "Conta Nº: 000/123456789   EUR   CONTA BBVA", with: "Conta Nº: ---   EUR   CONTA BBVA")
        XCTAssertNil(StatementSignature.key(for: file(text), kind: .bbvaStatement))
    }

    func testMortgageWithoutTransferCategoryIsAnIssue() async throws {
        try makeAccounts()
        let loan = try accountId(BBVAFundMortgageImport.loanAccountName)
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE category SET transferAccountId = NULL WHERE transferAccountId = ?", arguments: [loan])
        }
        let item = try await read(february())[0]
        XCTAssertTrue(item.issues.contains { $0.id == "noTransferCategory.mortgage" }, "\(item.issues)")
        XCTAssertEqual(item.section, .needsYou)
    }

    func testClosingMismatchIsNeedsYou() async throws {
        try makeAccounts()
        // March alone: the account would be at €2,490.00, the statement closes at €2,617.47.
        let item = try await read(march())[0]
        XCTAssertTrue(statementIssues(item).contains { if case .balanceMismatch = $0 { return true }; return false }, "\(item.issues)")
        XCTAssertEqual(item.section, .needsYou)
    }

    func testFundAlreadyValuedThatDayButOffIsAFundMismatch() async throws {
        try makeAccounts()
        let fund = try accountId(BBVAFundMortgageImport.fundAccountName)
        try await dbQueue.write { db in
            let market = try BuiltInCategories.category(db: db, role: .marketMovement)
            _ = try ManualTransactions.add(db: db, accountId: fund, date: self.day(2026, 2, 28), description: market.name, amountMinorUnits: 500,
                                           categoryId: market.id, note: nil, allowBuiltIn: true)
        }
        let item = try await read(february())[0]
        XCTAssertTrue(statementIssues(item).contains { if case .fundMismatch = $0 { return true }; return false }, "\(item.issues)")
        XCTAssertEqual(item.section, .needsYou)
    }

    // MARK: Through the pipeline

    private func pdf(_ text: String, name: String) throws -> URL {
        let url = EvidenceTestPDFs.textPDF(text.components(separatedBy: "\n"), name: name)
        return url
    }

    func testConsecutiveMonthsInOneBatchChainTheirBalances() async throws {
        try makeAccounts()
        let library = EvidenceLibrary(root: FileManager.default.temporaryDirectory.appendingPathComponent("BBVAReader-\(UUID().uuidString)"), database: dbQueue)
        let pipeline = ImportPipeline(dbQueue: dbQueue, library: library, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        // Handed in latest first: staged in date order all the same.
        let plan = try await pipeline.plan([try pdf(march(), name: "march.pdf"), try pdf(february(), name: "february.pdf")])
        let statements = plan.items.filter { $0.parentId == nil }
        XCTAssertEqual(statements.map(\.title), ["BBVA statement 2026-02", "BBVA statement 2026-03"], "\(plan.items.map { ($0.title, $0.needsYouReasons) })")
        for item in statements {
            XCTAssertEqual(item.section, .ready, "\(item.title): \(item.needsYouReasons)")
        }
        XCTAssertEqual(plan.readyGroups.first?.summary, "2 BBVA statements 2026-02–2026-03 → 5 transactions")
        pipeline.discardPlanningCopy()
    }

    func testChoosingTheMortgageInTheReviewReadsTheStatementAgain() async throws {
        try makeAccounts(mortgage: false)
        let loan = try await dbQueue.write { db in
            try AccountEditing.add(db: db, name: "Home loan", currency: .eur, kind: .credit, openingBalanceEntered: 1_050_000,
                                   asOf: self.day(2026, 1, 31), includeInNetWorth: false).id!
        }
        let library = EvidenceLibrary(root: FileManager.default.temporaryDirectory.appendingPathComponent("BBVAReader-\(UUID().uuidString)"), database: dbQueue)
        let pipeline = ImportPipeline(dbQueue: dbQueue, library: library, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        var plan = try await pipeline.plan([try pdf(february(), name: "february.pdf")])
        let item = try XCTUnwrap(plan.items.first { $0.parentId == nil })
        XCTAssertEqual(statementIssues(item), [.unknownLinkedAccount(.mortgage)])
        // Only the asked role takes a choice.
        do {
            _ = try await pipeline.resolve(plan, itemId: item.id, .chooseAccount(.fund, loan))
            XCTFail("a fund choice answers no question here")
        } catch let error as ImportResolutionError {
            XCTAssertEqual(error, .notOffered(.chooseAccount(.fund, loan)))
        }
        plan = try await pipeline.resolve(plan, itemId: item.id, .chooseAccount(.mortgage, loan))
        let reread = try XCTUnwrap(plan.items.first { $0.id == item.id })
        XCTAssertEqual(reread.section, .ready, "\(reread.needsYouReasons)")
        XCTAssertEqual(try effect(reread).loanAccountId, loan)
        XCTAssertEqual(try effect(reread).learnAccounts, [.mortgage: loan])
        pipeline.discardPlanningCopy()
    }

    // MARK: Chosen and remembered accounts against the printed Conta Nº (final review)

    /// Another current account, "Other PT", with no details.
    private func addOtherAccount() async throws -> Int64 {
        try await dbQueue.write { db in
            try AccountEditing.add(db: db, name: "Other PT", currency: .eur, kind: .cash, openingBalanceEntered: 0, asOf: self.day(2026, 1, 31)).id!
        }
    }

    func testAChosenAccountWhoseContaAnotherAccountHoldsIsAMismatch() async throws {
        try makeAccounts(currentName: "Main PT", accountNumber: "000/123456789")
        let other = try await addOtherAccount()
        for intent in [ImportIntent(statementAccounts: [.current: other]), ImportIntent(accountId: other)] {
            let item = try await read(february(), intent: intent)[0]
            XCTAssertEqual(try effect(item).currentAccountId, other)
            let issue = try XCTUnwrap(item.issues.first { $0.id == "accountMismatch" }, "\(item.issues.map(\.reason))")
            XCTAssertEqual(issue.reason, "This statement's Conta Nº is Main PT's, not Other PT's: choose its account or leave it out of this import")
            XCTAssertEqual(issue.offers.first, .chooseAccount(.current, bbvaId))
            XCTAssertEqual(item.section, .needsYou)
        }
        // The account holding it, chosen: no question.
        let chosen = try await read(february(), intent: ImportIntent(statementAccounts: [.current: bbvaId]))[0]
        XCTAssertFalse(chosen.issues.contains { $0.id == "accountMismatch" }, "\(chosen.issues.map(\.reason))")
    }

    func testAnIntentAccountThatIsGoneIsNotTaken() async throws {
        try makeAccounts(currentName: "Main PT", accountNumber: "000/123456789")
        let item = try await read(february(), intent: ImportIntent(accountId: 99_999))[0]
        XCTAssertEqual(try effect(item).currentAccountId, bbvaId)
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
    }

    func testPrintedDigitsWinOverALearntRulePointingElsewhere() async throws {
        try makeAccounts(currentName: "Main PT", accountNumber: "000/123456789")
        let other = try await addOtherAccount()
        try await dbQueue.write { db in
            _ = try ImportRuleStore.learn(db: db, kind: .statementAccount, key: "bbva:000123456789", matchLabel: "BBVA statement of account …6789",
                                          action: StatementAccountAction(accountId: other), actionLabel: "Account: Other PT", now: Date())
        }
        let item = try await read(february())[0]
        XCTAssertEqual(try effect(item).currentAccountId, bbvaId, "the printed digits win")
        let issue = try XCTUnwrap(item.issues.first { $0.id == "accountMismatch" }, "\(item.issues.map(\.reason))")
        XCTAssertEqual(issue.reason, "This statement's Conta Nº is Main PT's, but files like this were remembered for Other PT: "
                       + "confirm Main PT or choose its account")
        XCTAssertEqual(issue.offers.first, .chooseAccount(.current, bbvaId))
        XCTAssertEqual(item.section, .needsYou)
    }

    // MARK: Statement figures and scans (final review)

    func testStatementFiguresCannotBeConfirmedByHand() async throws {
        try makeAccounts()
        let item = try await read(february())[0]
        for resolution in [ImportResolution.confirmFigure(.openingBalance, .money(1, .eur)), .confirmFigure(.closingBalance, .money(1, .eur)),
                           .confirmFigure(.rows, .text("9")), .confirmFigure(.instalments, .text("x")), .confirmFigure(.fund, .text("x"))] {
            XCTAssertThrowsError(try ImportResolutions.apply(resolution, to: item)) { error in
                XCTAssertEqual(error as? ImportResolutionError, .notOffered(resolution))
            }
        }
    }

    func testAScannedStatementSaysWhyItCannotBeReady() async throws {
        try makeAccounts()
        let item = try await read(february(), ocr: true)[0]
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertTrue(item.needsYouReasons.contains(BBVAStatementReader.scannedReason), "\(item.needsYouReasons)")
    }
}
