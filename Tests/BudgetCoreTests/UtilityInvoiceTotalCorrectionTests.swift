import XCTest
import GRDB
@testable import BudgetCore

/// The old municipal-water records that hold only the invoice's first summary line (the water
/// charge) instead of its total (`UtilityInvoiceTotalCorrection`), and the account-total rule
/// that flags only a balance other than the total (not an invoice whose "Valor da Fatura"
/// figure was printed away from its label).
/// Synthetic layouts only.
final class UtilityInvoiceTotalCorrectionTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var propertyId: Int64!
    private var waterId: Int64!

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private static func preset(_ name: String) -> UtilityInvoiceRules {
        UtilityInvoiceRules.presets.first { $0.name == name }!.rules
    }

    /// The water rules as stored after the user reordered the amount labels.
    private static let reorderedWaterRules = UtilityInvoiceRules(
        textMarkers: ["SIMAR"], fileNameMarkers: ["AGUA"], invoiceNumberPatterns: [UtilityInvoiceRules.atcud],
        periodLabels: ["LITROS (", "PERIODO DE CONSUMO"], amountLabels: ["VALOR TOTAL", "TOTAL", "VALOR DA FATURA"],
        refundLabels: ["VALOR A RECEBER", "VALOR A CREDITAR"], dueDateLabels: ["LIMITE DE PAGAMENTO DA FATURA:"])

    /// The oldest layout: the summary's figures right after the "€" heading, "Valor da Fatura"
    /// on the line after its label.
    static let figuresFirstLayout = """
        SIMAR services · FATURA nº 000000001
        DATA DE EMISSÃO: 2016.02.11
        Resumo da Fatura
        Período de faturação: 11.01.2016 a 10.02.2016 (30 DIAS)
        ÁGUA
        ÁGUAS RESIDUAIS
        RESÍDUOS SÓLIDOS
        IVA
        Nº Ident. Fiscal
        500000000
        €
        31.20
        27.45
        12.06
        1.83
        TOTAL 72.54
        Documentos
        Fatura nº 000000001
        2016.02.11
        72.54+
        Valor da Conta Cliente em 11.02.2016 72.54
        Sr. Cliente, o valor de 72.54€ será debitado na conta bancária
        QUANTIDADE VALOR UNITÁRIO VALOR TOTAL VALOR A PAGAR IVA%
        31.20
        5.00 m3 0.4422 2.21
        IVA( 6% x 30.50) 1.83
        Valor da Fatura
        72.54
        """

    /// The next layout: the line labels after the "€" heading, then their figures; here
    /// "Valor da Fatura" printed with its figure far away (as some of these PDFs extract).
    static let labelsFirstLayout = """
        SIMAR services · FATURA nº 000000002
        DATA DE EMISSÃO: 2019.03.14
        Nº Ident. Fiscal
        500000000
        AV EXEMPLO 1
        Resumo da Fatura
        Período de faturação: 13.02.2019 a 12.03.2019 (30 DIAS)
        €
        ÁGUA
        ÁGUAS RESIDUAIS
        IVA
        12.34
        17.66
        0.74
        TOTAL 30.74
        Documentos
        Fatura nº 000000002
        2019.03.14
        30.74+
        Valor da Conta Cliente em 14.03.2019 30.74
        Sr. Cliente, o valor de 30.74€ será debitado na conta bancária
        QUANTIDADE VALOR UNITÁRIO VALOR TOTAL VALOR A PAGAR IVA%
        12.34
        5.00 m3 0.4618 2.31
        Valor da Fatura
        LOJAS DE ATENDIMENTO
        Rua Exemplo, 1
        30.74
        """

    /// The compact layout: the documents row first, then "€", the issue date and
    /// the figures.
    static let compactLayout = """
        SIMAR services
        Resumo da Fatura
        Data limite de pagamento da fatura: 2021.07.05
        Documentos Valor Data limite de pagamento
        2021.06.15 7.43+ 2021.07.05
        €
        2021.06.15
        2.91
        0.07
        1.88
        IVA 0.31
        TOTAL 7.43
        Valor da Conta Cliente em 15.06.2021 7.43
        QUANTIDADE VALOR UNITÁRIO VALOR TOTAL VALOR A PAGAR IVA%
        2.91
        Valor da Fatura 7.43
        """

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try db.write { db in
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            propertyId = property.id!
            var water = UtilityProvider(propertyId: propertyId, name: "Municipal water (SIMAR)", kind: .water, bankDescriptionPattern: "SIMAR",
                                        invoiceRules: Self.reorderedWaterRules)
            try Recharges.saveProvider(db: db, &water)
            waterId = water.id!
        }
    }

    // MARK: Reading

    func testAValorDaFaturaLabelWithoutItsFigureAddsNoReviewNote() {
        for rules in [Self.preset("Municipal water (SIMAR)"), Self.reorderedWaterRules] {
            let reading = UtilityInvoiceReader.read(text: Self.labelsFirstLayout, fileName: "x.pdf", rules: rules)
            XCTAssertEqual(reading.amountMinorUnits, 3_074)
            XCTAssertNil(reading.accountTotalMinorUnits)
            XCTAssertNil(reading.amountReviewNote)
        }
        // A total that isn't the balance: the balance is kept apart, to be checked.
        let other = Self.labelsFirstLayout.replacingOccurrences(of: "TOTAL 30.74", with: "TOTAL 12.34")
        let reading = UtilityInvoiceReader.read(text: other, fileName: "x.pdf", rules: Self.reorderedWaterRules)
        XCTAssertEqual(reading.amountMinorUnits, 1_234)
        XCTAssertEqual(reading.accountTotalMinorUnits, 3_074)
        XCTAssertEqual(reading.amountReviewNote, UtilityInvoiceReader.amountReviewNote)
    }

    func testEveryLayoutReadsItsTotalAndFirstSummaryLine() {
        let cases: [(String, Int, Int)] = [
            (Self.figuresFirstLayout, 7_254, 3_120), (Self.labelsFirstLayout, 3_074, 1_234), (Self.compactLayout, 743, 291)
        ]
        for (text, total, first) in cases {
            for rules in [Self.preset("Municipal water (SIMAR)"), Self.reorderedWaterRules] {
                let summary = UtilityInvoiceTotalCorrection.summary(text: text, rules: rules)
                XCTAssertEqual(summary?.total, total)
                XCTAssertEqual(summary?.firstLine, first)
            }
        }
    }

    func testNoSummaryWhenTheReadingIsUncertainOrHasNoSummaryBlock() {
        // No "€" heading before the total: no first line to tell.
        let noHeading = Self.labelsFirstLayout.replacingOccurrences(of: "€\nÁGUA", with: "ÁGUA")
        XCTAssertNil(UtilityInvoiceTotalCorrection.summary(text: noHeading, rules: Self.reorderedWaterRules))
        // The amount read needs checking (the account balance differs from the total).
        let unchecked = Self.labelsFirstLayout.replacingOccurrences(of: "14.03.2019 30.74", with: "14.03.2019 50.00")
        XCTAssertNotNil(UtilityInvoiceReader.read(text: unchecked, fileName: "x.pdf", rules: Self.reorderedWaterRules).amountReviewNote)
        XCTAssertNil(UtilityInvoiceTotalCorrection.summary(text: unchecked, rules: Self.reorderedWaterRules))
        // A credit note is no total.
        XCTAssertNil(UtilityInvoiceTotalCorrection.summary(text: "SIMAR services € 1.00 VALOR A CREDITAR 9.99 TOTAL 9.99",
                                                           rules: Self.reorderedWaterRules))
    }

    // MARK: Planning and applying

    private func document(_ text: String) throws -> Int64 {
        try db.write { db in
            var document = EvidenceDocument(sha256: UUID().uuidString, storedRelativePath: "x/a.pdf", originalFileName: "a.pdf", byteCount: 1,
                                            kind: .other, addedAt: Date())
            document.extractedText = text
            try document.insert(db)
            return document.id!
        }
    }

    @discardableResult
    private func invoice(_ issue: Date, _ amount: Int, documentId: Int64?, transactionId: Int64? = nil) throws -> Int64 {
        try db.write { db in
            var invoice = UtilityInvoice(providerId: waterId, issueDate: issue, amountMinorUnits: amount, documentId: documentId,
                                         transactionId: transactionId)
            try invoice.insert(db)
            return invoice.id!
        }
    }

    func testOnlyRecordsHoldingTheFirstLineWithoutDebitOrRechargeAreCorrected() throws {
        let first = try invoice(Self.date(2016, 2, 11), 3_120, documentId: try document(Self.figuresFirstLayout))
        let second = try invoice(Self.date(2019, 3, 14), 1_234, documentId: try document(Self.labelsFirstLayout))
        let third = try invoice(Self.date(2021, 6, 15), 291, documentId: try document(Self.compactLayout))
        // Already the total; some other figure; no document; credit note.
        try invoice(Self.date(2020, 1, 20), 743, documentId: try document(Self.compactLayout))
        try invoice(Self.date(2020, 2, 20), 2_222, documentId: try document(Self.labelsFirstLayout))
        try invoice(Self.date(2020, 3, 20), 1_234, documentId: nil)
        try invoice(Self.date(2020, 4, 20), -1_234, documentId: try document(Self.labelsFirstLayout))
        // A debit linked, or on a recharge statement: left alone.
        let debited = try db.write { db -> Int64 in
            var account = Account(name: "Bank A", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "bank.csv", importedAt: Date())
            try batch.insert(db)
            var transaction = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Self.date(2020, 5, 28), rawDescription: "SIMAR",
                                          amountMinorUnits: -3_074, categoryId: nil, status: .confirmed, categorizedBy: .manual, fingerprint: "t1")
            try transaction.insert(db)
            return transaction.id!
        }
        try invoice(Self.date(2020, 5, 20), 1_234, documentId: try document(Self.labelsFirstLayout), transactionId: debited)
        let recharged = try invoice(Self.date(2020, 6, 20), 1_234, documentId: try document(Self.labelsFirstLayout))
        try db.write { db in
            try db.execute(sql: "INSERT INTO tenancy (propertyId, referenceLabel, startDate) VALUES (?, 'Tenancy A', ?)",
                           arguments: [propertyId, Self.date(2020, 1, 1)])
            try db.execute(sql: "INSERT INTO rechargeStatement (tenancyId, month) VALUES (?, ?)",
                           arguments: [db.lastInsertedRowID, Self.date(2020, 6, 1)])
            try db.execute(sql: "INSERT INTO rechargeLine (statementId, invoiceId, amountMinorUnits) VALUES (?, ?, 1234)",
                           arguments: [db.lastInsertedRowID, recharged])
        }

        let plan = try db.read { db in try UtilityInvoiceTotalCorrection.plan(db: db, providerId: waterId) }
        XCTAssertEqual(plan, [
            UtilityInvoiceTotalCorrection.Change(invoiceId: first, issueDate: Self.date(2016, 2, 11), oldMinorUnits: 3_120, newMinorUnits: 7_254),
            UtilityInvoiceTotalCorrection.Change(invoiceId: second, issueDate: Self.date(2019, 3, 14), oldMinorUnits: 1_234, newMinorUnits: 3_074),
            UtilityInvoiceTotalCorrection.Change(invoiceId: third, issueDate: Self.date(2021, 6, 15), oldMinorUnits: 291, newMinorUnits: 743)
        ])

        try db.write { db in try UtilityInvoiceTotalCorrection.apply(db: db, plan) }
        let amounts = try db.read { db in
            try [first, second, third].map { try UtilityInvoice.fetchOne(db, key: $0)!.amountMinorUnits }
        }
        XCTAssertEqual(amounts, [7_254, 3_074, 743])
        // Idempotent: nothing left to correct.
        XCTAssertEqual(try db.read { db in try UtilityInvoiceTotalCorrection.plan(db: db, providerId: waterId) }, [])
    }

    func testApplyingRefusesARecordChangedSincePlanning() throws {
        let id = try invoice(Self.date(2016, 2, 11), 3_120, documentId: try document(Self.figuresFirstLayout))
        let plan = try db.read { db in try UtilityInvoiceTotalCorrection.plan(db: db, providerId: waterId) }
        try db.write { db in try db.execute(sql: "UPDATE utilityInvoice SET amountMinorUnits = 1 WHERE id = ?", arguments: [id]) }
        XCTAssertThrowsError(try db.write { db in try UtilityInvoiceTotalCorrection.apply(db: db, plan) })
        XCTAssertEqual(try db.read { db in try UtilityInvoice.fetchOne(db, key: id)!.amountMinorUnits }, 1)
    }

    func testTheWaterProviderIsFoundByItsSimarMarker() throws {
        XCTAssertEqual(try db.read { db in try UtilityInvoiceTotalCorrection.simarProviderIds(db: db) }, [waterId])
    }
}
