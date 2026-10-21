import XCTest
import GRDB
@testable import BudgetCore

/// BBVA's debit advices ("Pagamentos – Serviços/Compras", "Débito Direto"): recognised before
/// utility invoices, read from their (glyph-decoded) text, filed as bank debit advices and linked
/// to the one debit they announce. Synthetic data only: made-up names, references and amounts.
final class BBVADebitAdviceTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var accountId: Int64!
    private var batchId: Int64!
    private var created: [URL] = []

    /// A provider whose text marker the advice names (the creditor): the utility recogniser
    /// would claim the advice if it ran first.
    private static let provider = UtilityProvider(
        propertyId: 1, name: "Demo Water", kind: .water,
        invoiceRules: UtilityInvoiceRules(textMarkers: ["DEMO WATER"], fileNameMarkers: [], invoiceNumberPatterns: [],
                                          amountLabels: ["TOTAL A PAGAR"]))

    /// A services/purchases payment advice, labels and values as BBVA's decoded text has them
    /// (the amount alone on the line after its bare label, a fee beside it).
    static func serviceLines(date: String = "2024-03-04", amount: String = "45,67") -> [String] {
        ["Exmo(a). Senhor(a)", "DATA: \(date)", "PAGAMENTOS - SERVIÇOS/COMPRAS", "CLIENT ALPHA", "CONTA N : 076",
         "QUEIRA(M) NOTAR QUE, NESTA DATA, DEBITÁMOS NA CONTA DE V.EXA(S) O(S) SEGUINTE(S) MOVIMENTO(S):",
         "ENTIDADE: 21000", "REFERÊNCIA: 123 456 789", "DESCRITIVO: DEMO WATER CO",
         "MONTANTE:", amount, "COMISSÃO: 1,50", "IMPOSTO DO SELO: 0,06", "EUR", "BBVA"]
    }

    /// A SEPA direct-debit advice.
    static func directDebitLines(date: String = "05-03-2024", amount: String = "60,00") -> [String] {
        ["Exmo(a). Senhor(a)", "DÉBITO DIRETO", "DATA DO MOVIMENTO: \(date)", "CLIENT ALPHA",
         "INFORMAMOS QUE DEBITÁMOS NA CONTA DE V. EXA. O SEGUINTE DÉBITO:",
         "CREDOR: DEMO POWER SA", "ID CREDOR: PT00ZZZ000001", "AUTORIZAÇÃO: 77001234",
         "IMPORTÂNCIA: \(amount) EUR", "COMISSÃO: 0,00", "BBVA"]
    }

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try db.write { db in
            var account = Account(name: "Bank A", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            accountId = account.id!
            var batch = ImportBatch(accountId: accountId, sourceFileName: "bank.csv", importedAt: Date())
            try batch.insert(db)
            batchId = batch.id!
        }
    }

    override func tearDownWithError() throws {
        for url in created { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @discardableResult
    private func transaction(_ date: Date, _ amount: Int, _ text: String) throws -> Int64 {
        try db.write { db in
            var transaction = Transaction(importBatchId: batchId, accountId: accountId, date: date, rawDescription: text,
                                          amountMinorUnits: amount, categoryId: nil, status: .confirmed, categorizedBy: .manual,
                                          fingerprint: UUID().uuidString)
            try transaction.insert(db)
            return transaction.id!
        }
    }

    /// A decoded-text file (the glyph decoder's output is plain text).
    private func file(_ lines: [String], name: String = "advice.pdf") -> ImportFile {
        ImportFile(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)/\(name)"), fileName: name, sha256: UUID().uuidString,
                   byteCount: 1, fileExtension: "pdf", text: lines.joined(separator: "\n"), textStatus: .glyph, usedOCR: false)
    }

    private func propose(_ file: ImportFile, intent: ImportIntent = .none) throws -> ImportItem {
        let recognition = ImportDetector(providers: [Self.provider]).detect(file)
        let context = try db.read { try ImportContext.load(db: $0, intent: intent, now: Self.date(2024, 6, 1)) }
        let readers = ImportReaders.defaultReaders(providers: [Self.provider])
        let reader = try XCTUnwrap(readers.first { $0.handles(recognition.kind) })
        return try XCTUnwrap(try db.read { try reader.propose([(file, recognition)], context: context, db: $0) }.first)
    }

    // MARK: Parsing

    func testParsesAServicesPaymentAdvice() throws {
        let advice = try XCTUnwrap(BBVADebitAdvice.parse(Self.serviceLines().joined(separator: "\n")))
        XCTAssertEqual(advice.date, Self.date(2024, 3, 4))
        XCTAssertEqual(advice.amount, 4_567)
        XCTAssertEqual(advice.amounts, [4_567], "fees are never the debit's amount")
        XCTAssertEqual(advice.creditor, "DEMO WATER CO")
        XCTAssertEqual(advice.entity, "21000")
        XCTAssertEqual(advice.reference, "123 456 789")
    }

    func testParsesADirectDebitAdvice() throws {
        let advice = try XCTUnwrap(BBVADebitAdvice.parse(Self.directDebitLines().joined(separator: "\n")))
        XCTAssertEqual(advice.date, Self.date(2024, 3, 5))
        XCTAssertEqual(advice.amount, 6_000)
        XCTAssertEqual(advice.creditor, "DEMO POWER SA")
        XCTAssertEqual(advice.reference, "77001234")
    }

    func testOtherBankTextsAreNotDebitAdvices() {
        // A received transfer.
        XCTAssertNil(BBVADebitAdvice.parse(RentCreditEvidenceTests.adviceLines(date: "2024-01-02", amount: "1.234,56",
                                                                                reference: "0099REF0001").joined(separator: "\n")))
        // Each other document's wording on its own turns a debit advice into something else.
        let others = ["TRANSFERÊNCIA RECEBIDA", "PAGAMENTOS AO ESTADO", "PAGAMENTOS - ESTADO", "FATURA Nº FT 2024/12", "FATURA N.º 12",
                      "FACTURA NO 12", "FATURA-RECIBO", "NOTA DE CRÉDITO", "TOTAL A PAGAR", "VALOR A PAGAR", "QUANTO TENHO A PAGAR",
                      "RECIBO Nº 5", "APÓLICE 987", "AVISO DE COBRANÇA", "PATRIMÓNIO CONSOLIDADO", "AVISO DE DÉBITO PRESTAÇÃO",
                      "PRESTAÇÃO DO EMPRÉSTIMO", "PRESTAÇÃO CRÉDITO HABITAÇÃO"]
        XCTAssertNotNil(BBVADebitAdvice.parse(Self.serviceLines().joined(separator: "\n")))
        for other in others {
            XCTAssertNil(BBVADebitAdvice.parse((Self.serviceLines() + [other]).joined(separator: "\n")), other)
        }
        // A "prestação de serviços" is no mortgage.
        XCTAssertNotNil(BBVADebitAdvice.parse((Self.serviceLines() + ["PRESTAÇÃO DE SERVIÇOS"]).joined(separator: "\n")))
    }

    func testABareBBVAIsNotTheBanksAdviceWording() {
        let lines = Self.directDebitLines().filter { !$0.hasPrefix("INFORMAMOS") }
        XCTAssertNil(BBVADebitAdvice.parse(lines.joined(separator: "\n")))
    }

    func testUtilityInvoicePaidByBBVADirectDebitStaysAUtilityInvoice() {
        let invoice = ["DEMO WATER", "Fatura nº FT 2024/12", "Data: 2024-05-08", "Débito direto: será debitado na conta de V. Exa.",
                       "Banco: BBVA", "Total 45,67 €"]
        XCTAssertNil(BBVADebitAdvice.parse(invoice.joined(separator: "\n")))
        XCTAssertEqual(ImportDetector(providers: [Self.provider]).detect(file(invoice)).kind, .utilityInvoice)
    }

    func testBBVASegurosReceiptStaysAnInsuranceReceipt() {
        let receipt = ["BBVA SEGUROS", "RECIBO Nº 123456", "APÓLICE 987", "DÉBITO DIRETO", "DATA: 2024-04-01",
                       "PRÉMIO TOTAL 120,00", "DEBITÁMOS NA CONTA DE V. EXA."]
        XCTAssertNil(BBVADebitAdvice.parse(receipt.joined(separator: "\n")))
        XCTAssertEqual(ImportDetector(providers: [Self.provider]).detect(file(receipt)).kind, .evidence(.insuranceReceipt))
    }

    // MARK: Recognition

    func testDebitAdviceIsRecognisedBeforeUtilityInvoices() {
        let recognition = ImportDetector(providers: [Self.provider]).detect(file(Self.serviceLines()))
        XCTAssertEqual(recognition, ImportRecognition(kind: .evidence(.bankDebitAdvice), confidence: .certain,
                                                      reason: "BBVA debit advice of 2024-03-04"))
    }

    func testReceivedTransferAdviceStillGoesToTheTransferAdviceReader() throws {
        let lines = RentCreditEvidenceTests.adviceLines(date: "2024-01-02", amount: "1.234,56", reference: "0099REF0001")
        let recognition = ImportDetector(providers: [Self.provider]).detect(file(lines))
        XCTAssertEqual(recognition.kind, .transferAdvice)
        let reader = ImportReaders.defaultReaders(providers: [Self.provider]).first { $0.handles(recognition.kind) }
        XCTAssertTrue(reader is TransferAdviceReader)
    }

    func testDebitAdviceKindIsABankDocument() {
        XCTAssertEqual(DocumentKind.bankDebitAdvice.displayName, "Bank debit advice")
        XCTAssertEqual(ImportNaming.area(of: .bankDebitAdvice), "Bank")
    }

    // MARK: Reading and linking

    func testDirectDebitAdviceLinksToItsOnlyMatchingDebit() throws {
        let debit = try transaction(Self.date(2024, 3, 6), -6_000, "SEPADD/DEMO POWER 77001234")
        try transaction(Self.date(2024, 3, 6), -6_001, "SEPADD/DEMO POWER 77001234") // another amount
        try transaction(Self.date(2024, 3, 20), -6_000, "SEPADD/DEMO POWER 77001234") // beyond two days
        let item = try propose(file(Self.directDebitLines()))
        XCTAssertEqual(item.recognition.kind, .evidence(.bankDebitAdvice))
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertEqual(item.links.map(\.entity), [.transaction(debit)])
        XCTAssertEqual(item.links.first?.confidence, .certain)
        XCTAssertEqual(item.links.first?.madeByEffect, false)
        XCTAssertEqual(item.effect, .file)
        XCTAssertTrue(item.facts.contains { $0.field == .amount && $0.value == .money(6_000, .eur) }, "\(item.facts)")
        XCTAssertTrue(item.facts.contains { $0.field == .docDate && $0.value == .date(Self.date(2024, 3, 5)) }, "\(item.facts)")
        XCTAssertTrue(item.facts.contains { $0.field == .issuer && $0.value == .text("DEMO POWER SA") }, "\(item.facts)")
        XCTAssertEqual(item.placement?.metadata.kind, .bankDebitAdvice)
        // Never an invoice record.
        XCTAssertEqual(try db.read { try UtilityInvoice.fetchCount($0) }, 0)
    }

    func testServicesAdviceNamingAProviderIsNeverAnInvoice() throws {
        let debit = try transaction(Self.date(2024, 3, 4), -4_567, "PAG SERV 21000 DEMO WATER")
        let item = try propose(file(Self.serviceLines()))
        XCTAssertEqual(item.recognition.kind, .evidence(.bankDebitAdvice))
        XCTAssertEqual(item.effect, .file)
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertEqual(item.links.map(\.entity), [.transaction(debit)])
    }

    func testTwoEqualDebitsAskToChoose() throws {
        let first = try transaction(Self.date(2024, 3, 5), -6_000, "SEPADD/DEMO POWER 77001234")
        let second = try transaction(Self.date(2024, 3, 6), -6_000, "SEPADD/DEMO POWER 77001234")
        let item = try propose(file(Self.directDebitLines()))
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertEqual(item.links, [])
        let candidates = item.issues.compactMap { issue -> [LinkCandidate]? in
            if case .chooseLink(let candidates) = issue.kind { return candidates }
            return nil
        }.first
        XCTAssertEqual(Set(candidates?.map(\.entity) ?? []), [.transaction(first), .transaction(second)])
    }

    func testDebitWithoutTheCreditorNamedAsksToChoose() throws {
        let debit = try transaction(Self.date(2024, 3, 5), -6_000, "COMPRA 9999 OTHER SHOP")
        let item = try propose(file(Self.directDebitLines()))
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertEqual(item.links, [])
        let candidates = item.issues.compactMap { issue -> [LinkCandidate]? in
            if case .chooseLink(let candidates) = issue.kind { return candidates }
            return nil
        }.first
        XCTAssertEqual(candidates?.map(\.entity), [.transaction(debit)])
    }

    func testNoDebitYetIsFiledWithANote() throws {
        let item = try propose(file(Self.directDebitLines()))
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertEqual(item.links, [])
        XCTAssertEqual(item.notes, ["Not linked: no matching debit yet"])
    }

    func testACreditIsNeverTheDebit() throws {
        try transaction(Self.date(2024, 3, 5), 6_000, "DEMO POWER SA REFUND")
        let item = try propose(file(Self.directDebitLines()))
        XCTAssertEqual(item.links, [])
        XCTAssertEqual(item.notes, ["Not linked: no matching debit yet"])
    }

    func testTheClientsNameIsNeverTheCreditor() throws {
        let debit = try transaction(Self.date(2024, 3, 5), -6_000, "SEPADD CLIENT ALPHA 999")
        let item = try propose(file(Self.directDebitLines()))
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertEqual(item.links, [])
        let candidates = item.issues.compactMap { issue -> [LinkCandidate]? in
            if case .chooseLink(let candidates) = issue.kind { return candidates }
            return nil
        }.first
        XCTAssertEqual(candidates?.map(\.entity), [.transaction(debit)])
    }

    func testOnlyBBVAAccountsWhenOneIsKnown() throws {
        try transaction(Self.date(2024, 3, 5), -6_000, "SEPADD/DEMO POWER 77001234") // on Bank A
        let bbva = try db.write { db -> Int64 in
            var account = Account(name: "BBVA", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            return account.id!
        }
        let debit = try db.write { db -> Int64 in
            var transaction = Transaction(importBatchId: batchId, accountId: bbva, date: Self.date(2024, 3, 5),
                                          rawDescription: "SEPADD/DEMO POWER 77001234", amountMinorUnits: -6_000, categoryId: nil,
                                          status: .confirmed, categorizedBy: .manual, fingerprint: UUID().uuidString)
            try transaction.insert(db)
            return transaction.id!
        }
        let item = try propose(file(Self.directDebitLines()))
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertEqual(item.links.map(\.entity), [.transaction(debit)])
    }

    // MARK: The bank's short form of the creditor, the mandate reference

    /// A SEPA direct-debit order advice as BBVA's decoded text has it: the creditor alone on the
    /// line after "AVISO DE DÉBITO", a creditor identifier, the transaction reference first and
    /// the mandate ("NÚMERO AUTORIZAÇÃO") further down. `movement` is the statement's description
    /// of the debit, when the advice repeats it.
    static func sepaOrderLines(creditor: String = "DEMO WATERWORKS SA", authorisation: String? = "55500011122000",
                               movement: String? = nil, date: String = "2024-03-05", amount: String = "30,00") -> [String] {
        ["Exmo(a). Senhor(a)", "DATA: \(date)", "ORDEM DE DEBITO DIRECTO SEPA", "CLIENT ALPHA", "CONTA N  : 076",
         "QUEIRA(M) NOTAR QUE, NESTA DATA, EFECTUÁMOS NA CONTA DE V.EXA(S) O(S) SEGUINTE(S) MOVIMENTO(S):",
         "AVISO DE DÉBITO", creditor, "IVA 23,00 % : 0,00 EUR", "IDENTIFICAÇÃO CREDOR   : PT00ZZZ000002",
         "NOME ÚLTIMO CREDOR :", "REFERÊNCIA TRANSAÇÃO   : 000111222333"]
            + (movement.map { ["REFERÊNCIA MOVIMENTO   : \($0)"] } ?? [])
            + (authorisation.map { ["NÚMERO AUTORIZAÇÃO : \($0)"] } ?? [])
            + ["MONTANTE : \(amount) EUR DATA OPERAÇÃO : \(date)   DATA VALOR : \(date)", "DESPESAS EXPEDIENTE : 0,00 EUR"]
    }

    private func chooseCandidates(_ item: ImportItem) -> [EvidenceEntity]? {
        item.issues.compactMap { issue -> [LinkCandidate]? in
            if case .chooseLink(let candidates) = issue.kind { return candidates }
            return nil
        }.first?.map(\.entity)
    }

    func testParsesTheCreditorOfASEPAOrderAdvice() throws {
        let advice = try XCTUnwrap(BBVADebitAdvice.parse(Self.sepaOrderLines().joined(separator: "\n")))
        XCTAssertEqual(advice.creditor, "DEMO WATERWORKS SA")
        XCTAssertEqual(advice.amount, 3_000)
        XCTAssertEqual(advice.date, Self.date(2024, 3, 5))
    }

    func testDebitNamingTheCreditorInShortFormLinksWithCertainty() throws {
        let debit = try transaction(Self.date(2024, 3, 5), -3_000, "SEPADD/DEMOWAT ADC/99988877766")
        let item = try propose(file(Self.sepaOrderLines(authorisation: nil)))
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertEqual(item.links.map(\.entity), [.transaction(debit)])
        XCTAssertEqual(item.links.first?.confidence, .certain)
        XCTAssertEqual(BBVADebitAdvice.namedWord("SEPADD/DEMOWAT ADC/99988877766",
                                                 in: try XCTUnwrap(BBVADebitAdvice.parse(Self.sepaOrderLines(authorisation: nil).joined(separator: "\n")))),
                       "DEMOWAT")
        // The advice's creditor shorter than the description's: a prefix the other way.
        let short = try XCTUnwrap(BBVADebitAdvice.parse(Self.sepaOrderLines(creditor: "DEMOW", authorisation: nil).joined(separator: "\n")))
        XCTAssertEqual(BBVADebitAdvice.namedWord("DD DEMOWATERWORKS 0042", in: short), "DEMOWATERWORKS")
    }

    func testDebitCarryingTheMandateReferenceLinksWithCertainty() throws {
        // The bank's short form names nothing of the creditor's name; the mandate is in the advice.
        let debit = try transaction(Self.date(2024, 3, 6), -3_000, "SEPADD/XYZ CUR ADC/55500011122")
        let item = try propose(file(Self.sepaOrderLines(creditor: "OTHER NAME (CURR)")))
        XCTAssertEqual(item.section, .ready, "\(item.needsYouReasons)")
        XCTAssertEqual(item.links.map(\.entity), [.transaction(debit)])
        XCTAssertEqual(item.links.first?.confidence, .certain)
        // A mandate with a letter in front, as the advice's authorisation carries it.
        let lettered = try XCTUnwrap(BBVADebitAdvice.parse(Self.sepaOrderLines(creditor: "OTHER NAME", authorisation: "P123456789012")
            .joined(separator: "\n")))
        XCTAssertEqual(BBVADebitAdvice.namedWord("SEPADD/XYZ ADC/P1234567890", in: lettered), "P1234567890")
    }

    func testShortCreditorPrefixesAndReferencesNameNothing() throws {
        let advice = try XCTUnwrap(BBVADebitAdvice.parse(Self.sepaOrderLines(creditor: "DEMOWATERWORKS", authorisation: "1234567000")
            .joined(separator: "\n")))
        XCTAssertNil(BBVADebitAdvice.namedWord("SEPADD/DEMO ADC/99988877766", in: advice), "four letters in common")
        XCTAssertNil(BBVADebitAdvice.namedWord("SEPADD/XYZ ADC/1234567", in: advice), "seven digits")
        let debit = try transaction(Self.date(2024, 3, 5), -3_000, "SEPADD/DEMO ADC/99988877766")
        let item = try propose(file(Self.sepaOrderLines(creditor: "DEMOWATERWORKS", authorisation: nil)))
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertEqual(item.links, [])
        XCTAssertEqual(chooseCandidates(item), [.transaction(debit)])
    }

    func testTwoNamedDebitsStillAskToChoose() throws {
        let first = try transaction(Self.date(2024, 3, 5), -3_000, "SEPADD/DEMOWAT ADC/55500011122")
        let second = try transaction(Self.date(2024, 3, 6), -3_000, "SEPADD/DEMOWAT ADC/55500011122")
        let item = try propose(file(Self.sepaOrderLines()))
        XCTAssertEqual(item.section, .needsYou)
        XCTAssertEqual(item.links, [])
        XCTAssertEqual(Set(chooseCandidates(item) ?? []), [.transaction(first), .transaction(second)])
        XCTAssertTrue(item.needsYouReasons.contains { $0.contains("2 debits fit") }, "\(item.needsYouReasons)")
    }

    // MARK: Follow-on

    /// A debit advice filed in the library with `text`, no link.
    private func libraryAdvice(_ lines: [String]) throws -> Int64 {
        try db.write { db in
            var document = EvidenceDocument(sha256: UUID().uuidString, storedRelativePath: "x/y.pdf", originalFileName: "advice.pdf",
                                            byteCount: 1, kind: .bankDebitAdvice, textStatus: .glyph,
                                            extractedText: lines.joined(separator: "\n"), addedAt: Date())
            try document.insert(db)
            return document.id!
        }
    }

    private func transactionLinks(_ documentId: Int64) throws -> [EvidenceEntity] {
        try db.read { db in try EvidenceLinks.links(db: db, for: documentId).map(\.entity).filter { $0.type == .transaction } }
    }

    func testFollowOnLinksALibraryAdviceToItsOnlyDebitAndLeavesAmbiguousOnes() throws {
        let one = try libraryAdvice(Self.directDebitLines())
        let two = try libraryAdvice(Self.serviceLines())
        let debit = try transaction(Self.date(2024, 3, 5), -6_000, "SEPADD/DEMO POWER 77001234")
        try transaction(Self.date(2024, 3, 4), -4_567, "PAG SERV 21000 DEMO WATER")
        try transaction(Self.date(2024, 3, 5), -4_567, "PAG SERV 21000 DEMO WATER")
        let cache = RentCreditEvidence.AdviceCache()
        try db.write { db in
            try ImportEffects.followOns(db: db, propertyIds: [], adviceCache: cache)
            try ImportEffects.followOns(db: db, propertyIds: [], adviceCache: cache)
        }
        XCTAssertEqual(try transactionLinks(one), [.transaction(debit)])
        XCTAssertEqual(try transactionLinks(two), [], "two debits fit: the user picks")
        XCTAssertEqual(cache.debitAdvices.parses, 2, "each advice read once per pass")
    }

    func testUnreadableDebitAdviceFallsBackToTheEvidenceReader() throws {
        let unread = file(["Nothing readable here at all, just words"])
        let reader = BBVADebitAdviceReader()
        let context = try db.read { try ImportContext.load(db: $0, intent: .none, now: Self.date(2024, 6, 1)) }
        let recognition = ImportRecognition(kind: .evidence(.bankDebitAdvice), confidence: .certain, reason: "learnt")
        let item = try XCTUnwrap(try db.read { try reader.propose([(unread, recognition)], context: context, db: $0) }.first)
        XCTAssertEqual(item.recognition.kind, .evidence(.bankDebitAdvice))
        XCTAssertEqual(item.links, [])
    }
}

/// A debit advice imported in the same batch as the statement that holds its debit: filed
/// unlinked (the debit isn't saved yet), then linked by the follow-on matching on Confirm import;
/// Undo removes the link with the rest of the run. Synthetic data only.
final class BBVADebitAdviceBatchTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var folder: URL!
    private var library: EvidenceLibrary!
    private var accountId: Int64!

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        accountId = try db.write { db -> Int64 in
            try CategorySeeder.seedDefaults(db)
            var account = Account(name: "BBVA", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            return account.id!
        }
        _ = try ImportProfileStore(dbQueue: db).save(ImportProfile(accountId: accountId, format: .csv, csvDelimiter: ",", csvDateColumnIndex: 0,
                                                                   csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2,
                                                                   csvBalanceColumnIndex: 3, csvDateFormat: "dd/MM/yyyy"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("BBVADebitAdviceBatchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        library = EvidenceLibrary(root: folder.appendingPathComponent("Library", isDirectory: true), database: db)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A synchronous read (the async test would pick GRDB's async overload).
    private func read<T>(_ body: (Database) throws -> T) throws -> T {
        try db.read(body)
    }

    func testAdviceAndItsStatementInOneBatchAreLinkedOnConfirmAndUndone() async throws {
        let drop = folder.appendingPathComponent("Drop", isDirectory: true)
        try FileManager.default.createDirectory(at: drop, withIntermediateDirectories: true)
        let csv = drop.appendingPathComponent("statement.csv")
        try Data("Date,Description,Amount,Balance\n04/03/2024,SHOP A,-1.00,-1.00\n05/03/2024,SEPADD/DEMO POWER 77001234,-60.00,-61.00\n".utf8)
            .write(to: csv)
        let advice = EvidenceTestPDFs.textPDF(BBVADebitAdviceTests.directDebitLines(), name: "advice.pdf")
        defer { try? FileManager.default.removeItem(at: advice.deletingLastPathComponent()) }

        let pipeline = ImportPipeline(dbQueue: db, library: library, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        let plan = try await pipeline.plan([csv, advice], intent: ImportIntent(accountId: accountId))
        let item = try XCTUnwrap(plan.items.first { $0.file.fileName == "advice.pdf" })
        XCTAssertEqual(item.recognition.kind, .evidence(.bankDebitAdvice))
        XCTAssertEqual(item.links, [])
        XCTAssertTrue(plan.canConfirm, "\(plan.items.map { ($0.title, $0.needsYouReasons) })")

        let summary = try ImportApplier(dbQueue: db, databasePath: nil, library: library).apply(plan, entryPoint: "Test")
        let (documentId, debitId) = try read { db -> (Int64?, Int64?) in
            (try Int64.fetchOne(db, sql: "SELECT id FROM document WHERE kind = ?", arguments: [DocumentKind.bankDebitAdvice.rawValue]),
             try Int64.fetchOne(db, sql: "SELECT id FROM transaction_ WHERE rawDescription LIKE 'SEPADD%'"))
        }
        let document = try XCTUnwrap(documentId), debit = try XCTUnwrap(debitId)
        let links = { try self.read { db in try EvidenceLinks.links(db: db, for: document).map(\.entity) } }
        XCTAssertEqual(try links(), [.transaction(debit)])

        _ = try ImportUndo.undo(dbQueue: db, library: library, runId: summary.runId)
        XCTAssertEqual(try read { db in try DocumentLink.filter(Column("documentId") == document).fetchCount(db) }, 0)
        XCTAssertEqual(try read { db in try Transaction.filter(Column("id") == debit).fetchCount(db) }, 0)
    }
}
