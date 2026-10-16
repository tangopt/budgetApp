import XCTest
@testable import BudgetCore
import struct BudgetCore.Category

final class EvidenceMatcherTests: XCTestCase {
    private let bbva = Account(id: 1, name: "BBVA", currency: .eur, kind: .cash, trackingMode: .imported, alias: "BBVA PT")
    private let euroCard = Account(id: 2, name: "Lloyds International Account (EUR)", currency: .eur, kind: .cash, trackingMode: .imported)
    private let pounds = Account(id: 3, name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
    private var accounts: [Account] { [bbva, euroCard, pounds] }

    private var categories: [Category] {
        [Category(id: 10, name: "Transfer: BBVA mortgage", type: .transfer), Category(id: 11, name: "Mortgage interest", type: .expense),
         Category(id: 12, name: "IMI", type: .expense), Category(id: 13, name: "PT tax", type: .expense),
         Category(id: 14, name: "Life insurance", type: .expense), Category(id: 15, name: "Rental income", type: .income),
         Category(id: 16, name: "Condomínio", type: .expense), Category(id: 17, name: "Groceries", type: .expense)]
    }

    private func day(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: string)!
    }

    private func transaction(_ id: Int64, _ date: String, _ amount: Int, _ description: String, account: Int64 = 1, category: Int64? = nil) -> Transaction {
        Transaction(id: id, importBatchId: 1, accountId: account, date: day(date), rawDescription: description, amountMinorUnits: amount,
                    categoryId: category, status: .confirmed, categorizedBy: .none, fingerprint: "\(id)")
    }

    private func document(_ kind: DocumentKind, date: String?, amount: Int?, currency: Currency? = .eur, period: (String, String)? = nil,
                          text: String? = nil) -> EvidenceDocument {
        EvidenceDocument(sha256: "x", storedRelativePath: "x/x.pdf", originalFileName: "x.pdf", byteCount: 1, kind: kind,
                         docDate: date.map(day), periodStart: period.map { day($0.0) }, periodEnd: period.map { day($0.1) },
                         amountMinorUnits: amount, currency: currency, extractedText: text, addedAt: Date())
    }

    private func ids(_ suggestions: [EvidenceMatcher.Suggestion]) -> [Int64] { suggestions.map(\.transactionId) }

    func testMortgageNoticeMatchesItsInstalmentByAmountAndValueDate() {
        // Issued mid-month; the period ends on the debit's value date.
        let notice = document(.mortgageNotice, date: "2024-01-16", amount: 123_456, period: ("2023-12-31", "2024-01-31"),
                              text: "CONTA EMPRÉSTIMO 076 900000001 TOTAL EUR: 1.234,56")
        let transactions = [
            transaction(1, "2024-01-31", -123_456, "COBR. REC. TOT 076 90-000000-1", category: 10),
            transaction(2, "2024-02-29", -123_456, "COBR. REC. TOT 076 90-000000-1", category: 10), // next month, same total
            transaction(3, "2024-01-31", -4_500, "COMPRA SUPERMERCADO", category: 17),
            transaction(4, "2024-01-30", 123_456, "TRANSFERENCIA RECEBIDA") // a credit: never a debit's evidence
        ]
        let suggestions = EvidenceMatcher.suggestions(document: notice, transactions: transactions, accounts: accounts, categories: categories)
        XCTAssertEqual(ids(suggestions), [1, 2])
        XCTAssertGreaterThan(suggestions[0].score, suggestions[1].score)
        XCTAssertTrue(suggestions[0].reasons.contains("Amount €1,234.56"))
        XCTAssertTrue(suggestions[0].reasons.contains("Same day"))
        XCTAssertTrue(suggestions[0].reasons.contains("Category Transfer: BBVA mortgage"))
        XCTAssertTrue(suggestions[0].reasons.contains("BBVA PT account"))
        XCTAssertEqual(EvidenceMatcher.confidentMatch(suggestions)?.transactionId, 1)
    }

    func testMortgageWindowIsThreeDays() {
        let notice = document(.mortgageNotice, date: "2022-12-15", amount: nil, period: ("2022-11-30", "2022-12-31"))
        let transactions = [
            transaction(1, "2023-01-02", -92_785, "COBR. REC. TOT 076", category: 10), // booked 2 days after the value date
            transaction(2, "2023-01-05", -92_785, "COBR. REC. TOT 076", category: 10) // 5 days: outside
        ]
        let suggestions = EvidenceMatcher.suggestions(document: notice, transactions: transactions, accounts: accounts, categories: categories)
        XCTAssertEqual(ids(suggestions), [1])
        XCTAssertTrue(suggestions[0].reasons.contains("2 days after"))
        XCTAssertNil(EvidenceMatcher.confidentMatch(suggestions), "no amount: not confident enough to link alone")
    }

    func testAmountMustBeInTheTransactionsCurrency() {
        let receipt = document(.accountantInvoice, date: "2024-12-04", amount: 64_000, currency: .gbp)
        let transactions = [
            transaction(1, "2024-12-05", -64_000, "CARD PAYMENT TO EXAMPLE TAX", account: 3),
            transaction(2, "2024-12-05", -64_000, "CONTABILISTA", account: 2) // €640.00, not £640.00
        ]
        let suggestions = EvidenceMatcher.suggestions(document: receipt, transactions: transactions, accounts: accounts, categories: categories)
        XCTAssertEqual(ids(suggestions), [1])
        XCTAssertTrue(suggestions[0].reasons.contains("Amount £640.00"))
    }

    func testIMIPaymentSameDayAndReference() {
        let proof = document(.imiPayment, date: "2023-05-08", amount: 25_000, text: "PAGAMENTOS AO ESTADO Referencia : 111122000000193 MONTANTE PAGO : 250,00")
        let transactions = [
            transaction(1, "2023-05-08", -25_000, "PG PAGEST 111122000000193", category: 12),
            transaction(2, "2023-08-10", -25_000, "PG PAGEST 111822000000293", category: 12), // the next instalment
            transaction(3, "2023-05-10", -25_000, "PG PAGEST 999", category: 12) // two days later: outside the window, amount only
        ]
        let suggestions = EvidenceMatcher.suggestions(document: proof, transactions: transactions, accounts: accounts, categories: categories)
        XCTAssertEqual(ids(suggestions), [1, 3])
        XCTAssertTrue(suggestions[0].reasons.contains("Reference 111122000000193"))
        XCTAssertFalse(suggestions[1].reasons.contains("Same day"))
        XCTAssertEqual(EvidenceMatcher.confidentMatch(suggestions)?.transactionId, 1)
    }

    func testEqualCandidatesStayAmbiguous() {
        // Two people's IRS paid the same day for the same amount; the proof names neither reference.
        let proof = document(.ptIRSPaymentProof, date: "2023-08-10", amount: 150_000)
        let transactions = [
            transaction(1, "2023-08-10", -150_000, "PG PAGEST 104700000000480", category: 13),
            transaction(2, "2023-08-10", -150_000, "PG PAGEST 104300000000482", category: 13)
        ]
        let suggestions = EvidenceMatcher.suggestions(document: proof, transactions: transactions, accounts: accounts, categories: categories)
        XCTAssertEqual(suggestions.count, 2)
        XCTAssertEqual(suggestions[0].score, suggestions[1].score)
        XCTAssertNil(EvidenceMatcher.confidentMatch(suggestions))

        // With the reference in the document, one wins.
        var named = proof
        named.extractedText = "Pagamentos - Estado - 104300000000482 Montante: 1.500,00 EUR"
        let resolved = EvidenceMatcher.suggestions(document: named, transactions: transactions, accounts: accounts, categories: categories)
        XCTAssertEqual(EvidenceMatcher.confidentMatch(resolved)?.transactionId, 2)
    }

    func testInsuranceReceiptTenDayWindow() {
        let receipt = document(.insuranceReceipt, date: "2024-04-23", amount: 12_000)
        let transactions = [
            transaction(1, "2024-05-02", -12_000, "SEPADD/BBVASEG ADC/000", category: 14), // 9 days after
            transaction(2, "2024-06-15", -12_000, "SEPADD/BBVASEG ADC/000", category: 14) // 53 days: beyond the grace
        ]
        let suggestions = EvidenceMatcher.suggestions(document: receipt, transactions: transactions, accounts: accounts, categories: categories)
        XCTAssertEqual(ids(suggestions), [1])
        XCTAssertTrue(suggestions[0].reasons.contains("9 days after"))
        XCTAssertTrue(suggestions[0].reasons.contains("Description mentions BBVASEG"))
    }

    func testRentReceiptMatchesTheCreditInItsRentMonth() {
        let receipt = document(.rentReceipt, date: "2025-03-05", amount: 230_000, period: ("2025-03-01", "2025-03-31"))
        let transactions = [
            transaction(1, "2025-03-03", 230_000, "TRF 0123456 TENANT", category: 15),
            transaction(2, "2025-02-03", 230_000, "TRF 0123456 TENANT", category: 15), // February's rent
            transaction(3, "2025-03-03", -230_000, "SOMETHING ELSE") // a debit
        ]
        let suggestions = EvidenceMatcher.suggestions(document: receipt, transactions: transactions, accounts: accounts, categories: categories)
        XCTAssertEqual(ids(suggestions), [1, 2])
        XCTAssertGreaterThan(suggestions[0].score, suggestions[1].score)
        XCTAssertTrue(suggestions[0].reasons.contains("Category Rental income"))
        XCTAssertEqual(EvidenceMatcher.confidentMatch(suggestions)?.transactionId, 1)
    }

    func testNeighbouringPeriodsEqualAmountIsNotConfident() {
        // March's instalment is missing (not imported yet); April's has the same total.
        let notice = document(.mortgageNotice, date: "2025-03-14", amount: 100_000, period: ("2025-02-28", "2025-03-31"),
                              text: "CONTA EMPRÉSTIMO 076 900000001 TOTAL EUR: 1.000,00")
        let transactions = [
            transaction(1, "2025-04-30", -100_000, "COBR. REC. TOT 076 90-000000-1", category: 10),
            transaction(2, "2024-11-30", -100_000, "COBR. REC. TOT 076 90-000000-1", category: 10) // the loan number again
        ]
        let suggestions = EvidenceMatcher.suggestions(document: notice, transactions: transactions, accounts: accounts, categories: categories)
        XCTAssertEqual(ids(suggestions), [1])
        XCTAssertTrue(suggestions[0].amountMatched)
        XCTAssertFalse(suggestions[0].dateInWindow)
        XCTAssertFalse(suggestions[0].referenceMatched, "the loan number is on every instalment")
        XCTAssertNil(EvidenceMatcher.confidentMatch(suggestions))

        // Same for a rent receipt whose month's credit is missing.
        let receipt = document(.rentReceipt, date: "2025-03-05", amount: 200_000, period: ("2025-03-01", "2025-03-31"))
        let april = [transaction(3, "2025-04-02", 200_000, "TRF TENANT", category: 15)]
        XCTAssertNil(EvidenceMatcher.confidentMatch(EvidenceMatcher.suggestions(document: receipt, transactions: april, accounts: accounts, categories: categories)))
    }

    func testUniqueReferenceMakesAnOutOfWindowAmountConfident() {
        let proof = document(.imiPayment, date: "2025-05-08", amount: 25_000, text: "PAGAMENTOS AO ESTADO Referencia : 111000000000001")
        let transactions = [transaction(1, "2025-05-12", -25_000, "PG PAGEST 111000000000001", category: 12)]
        let suggestions = EvidenceMatcher.suggestions(document: proof, transactions: transactions, accounts: accounts, categories: categories)
        XCTAssertEqual(suggestions.first?.dateInWindow, false)
        XCTAssertEqual(suggestions.first?.referenceMatched, true)
        XCTAssertEqual(EvidenceMatcher.confidentMatch(suggestions)?.transactionId, 1)
    }

    func testAssessmentRefundMatchesACredit() {
        let assessment = document(.ptIRSAssessment, date: "2025-06-01", amount: 40_000)
        let transactions = [transaction(1, "2025-06-20", 40_000, "TRF AUTORIDADE TRIBUTARIA REEMBOLSO IRS", category: 13)]
        let suggestions = EvidenceMatcher.suggestions(document: assessment, transactions: transactions, accounts: accounts, categories: categories)
        XCTAssertEqual(EvidenceMatcher.confidentMatch(suggestions)?.transactionId, 1)
    }

    func testPreparedIndexGivesTheSameSuggestions() {
        let proof = document(.condominioReceipt, date: "2025-03-05", amount: 30_000)
        let transactions = (1...200).map { number in
            transaction(Int64(number), "2025-0\(number % 9 + 1)-0\(number % 9 + 1)", number % 3 == 0 ? -30_000 : -1_000, "Condominio \(number)", category: 16)
        }
        let index = EvidenceMatcher.Index(transactions: transactions, accounts: accounts, categories: categories)
        XCTAssertEqual(EvidenceMatcher.suggestions(document: proof, index: index),
                       EvidenceMatcher.suggestions(document: proof, transactions: transactions, accounts: accounts, categories: categories))
        XCTAssertFalse(EvidenceMatcher.suggestions(document: proof, index: index).isEmpty)
    }

    func testHintsWithoutAmountOrDateAreNotEnough() {
        let notice = document(.condominioReceipt, date: nil, amount: nil)
        let transactions = [transaction(1, "2023-03-06", -30_000, "Condominio 250305EVN0001", category: 16)]
        XCTAssertEqual(EvidenceMatcher.suggestions(document: notice, transactions: transactions, accounts: accounts, categories: categories), [])

        // An amount alone (no date) still suggests.
        let dated = document(.condominioReceipt, date: nil, amount: 30_000)
        XCTAssertEqual(ids(EvidenceMatcher.suggestions(document: dated, transactions: transactions, accounts: accounts, categories: categories)), [1])
    }

    func testPaymentReferences() {
        XCTAssertEqual(EvidenceMatcher.paymentReferences(in: "Referência 104 700 000 000 284 e conta 076 200000000 NIF 123456789 1.234,56"),
                       ["104700000000284", "200000000", "123456789"])
    }

    func testLimit() {
        let proof = document(.bankTransferProof, date: "2025-06-13", amount: 10_000)
        let transactions = (1...20).map { transaction(Int64($0), "2025-06-13", -10_000, "TRANSFER \($0)") }
        let suggestions = EvidenceMatcher.suggestions(document: proof, transactions: transactions, accounts: accounts, categories: categories, limit: 5)
        XCTAssertEqual(ids(suggestions), [1, 2, 3, 4, 5], "equal scores and distances: by id")
        XCTAssertNil(EvidenceMatcher.confidentMatch(suggestions))
    }
}
