import XCTest
@testable import BudgetCore

final class EvidenceAnalyzerTests: XCTestCase {
    private func day(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: string)!
    }

    private func analyze(_ text: String, fileName: String = "document.pdf") -> EvidenceMetadata {
        EvidenceAnalyzer.analyze(text: text, textStatus: .text, fileName: fileName).metadata
    }

    func testMortgageNotice() {
        // BBVA's reading order: labels and values apart.
        let text = """
        AVISO DÉBITO PRESTAÇÃO
        CONTA EMPRÉSTIMO : CREDITO HABITAÇÃO 076 900000001
        2025-03-31
        TOTAL EUR:
        2025-03-31 DATA FIM LIQUIDAÇÃO :
        1.234,56
        DATA:
        0000001 112
        2025-03-14
        DATA VENC.:
        2025-02-28
        2010-05-01
        200.000,00
        1.000,00 EUR
        234,56 EUR
        """
        let metadata = analyze(text, fileName: "20250314 - Prestacao.pdf")
        XCTAssertEqual(metadata.kind, .mortgageNotice)
        XCTAssertEqual(metadata.amountMinorUnits, 123_456)
        XCTAssertEqual(metadata.currency, .eur)
        XCTAssertEqual(metadata.docDate, day("2025-03-14"))
        XCTAssertEqual(metadata.periodStart, day("2025-02-28"))
        XCTAssertEqual(metadata.periodEnd, day("2025-03-31"))
    }

    func testMortgagePeriodFromTheDatesAroundTheNotice() {
        // No "DATA FIM" label: the first date after the notice ends the period.
        let metadata = analyze("AVISO DÉBITO PRESTAÇÃO CREDITO HABITAÇÃO DATA: 2025-03-14 2025-03-31 2025-02-28 2010-05-01 2040-05-01 TOTAL EUR: 900,00")
        XCTAssertEqual(metadata.periodStart, day("2025-02-28"))
        XCTAssertEqual(metadata.periodEnd, day("2025-03-31"))
        XCTAssertEqual(metadata.docDate, day("2025-03-14"))
    }

    func testLabelSearchSurvivesCharactersThatChangeLengthWhenUppercased() {
        // "ﬁ" uppercases to "FI" (and "ß" to "SS"): label offsets must index the text itself.
        let filler = String(repeating: "Identiﬁcação ﬁscal ß ", count: 12)
        let metadata = analyze("Generali Seguros Fatura/Recibo \(filler) Total: 60,00 € Data de emissão: 2025-10-12 ﬁm")
        XCTAssertEqual(metadata.kind, .insuranceReceipt)
        XCTAssertEqual(metadata.amountMinorUnits, 6_000)
        XCTAssertEqual(metadata.docDate, day("2025-10-12"))
    }

    func testSkipsBirthAndExpiryDates() {
        let metadata = analyze("Payment complete Pay your Self Assessment Date of birth 01/02/1980 Data de validade 2030-01-01 Date 7 December 2021 Amount £100.00")
        XCTAssertEqual(metadata.docDate, day("2021-12-07"))
    }

    func testLettingAgentInvoiceIgnoresShareCapital() {
        let metadata = analyze("Exemplo - Mediação Imobiliária, Lda. Capital Social: 25.000,00 € Fatura FAC 2/1 Emitido em 2025-04-28 "
                               + "TOTAL LÍQUIDO 2 000,00 EUR TOTAL IVA 460,00 EUR TOTAL 2 460,00 EUR")
        XCTAssertEqual(metadata.kind, .lettingAgentFee)
        XCTAssertEqual(metadata.docDate, day("2025-04-28"))
        XCTAssertEqual(metadata.amountMinorUnits, 246_000)
    }

    func testInsuranceReceiptWithCoverPeriod() {
        let text = "Fatura/Recibo Seguro Multirrisco Generali Seguros Prémio comercial 50,00 € Período: 2025-11-15 00:00 a 2026-11-14 "
            + "Data de emissão: 2025-10-12 Imposto 4,50 € Total outras entidades 2,00 € Total: 60,00 €"
        let metadata = analyze(text)
        XCTAssertEqual(metadata.kind, .insuranceReceipt)
        XCTAssertEqual(metadata.amountMinorUnits, 6_000)
        XCTAssertEqual(metadata.docDate, day("2025-10-12"))
        XCTAssertEqual(metadata.periodStart, day("2025-11-15"))
        XCTAssertEqual(metadata.periodEnd, day("2026-11-14"))
    }

    func testIMINoticeAmountBeforeItsLabel() {
        let text = """
        IMPOSTO MUNICIPAL SOBRE IMÓVEIS
        ANO DE IMPOSTO
        DATA DE LIQUIDAÇÃO
        2016
        2017-03-03
        1a. PRESTAÇÃO
        Referência para pagamento
        111 016 000 000 003
        Importância a pagar
        Para efetuar o pagamento através da Internet selecione Pagamentos ao Estado.
        260,00
        Mês de pagamento
        """
        let metadata = analyze(text)
        XCTAssertEqual(metadata.kind, .imiNotice)
        XCTAssertEqual(metadata.amountMinorUnits, 26_000)
        XCTAssertEqual(metadata.docDate, day("2017-03-03"))
    }

    func testUKTaxYearDocuments() {
        let p60 = analyze("P60 End of Year Certificate Tax Year to 5 April 2024 Pay £100,000.00")
        XCTAssertEqual(p60.kind, .p60)
        XCTAssertEqual(p60.periodStart, day("2023-04-06"))
        XCTAssertEqual(p60.periodEnd, day("2024-04-05"))
        XCTAssertEqual(p60.docDate, day("2024-04-05"))
        XCTAssertNil(p60.amountMinorUnits, "a P60's figures are confirmed by the user")

        let sa302 = analyze("Calculation Result for 2023-24 Name: Example How we worked out your Income Tax")
        XCTAssertEqual(sa302.kind, .sa302)
        XCTAssertEqual(sa302.periodEnd, day("2024-04-05"))

        let payment = analyze("Pay your Self Assessment Payment complete Your payment reference is 1234567890K Date 7 December 2021 Amount £2,000.00")
        XCTAssertEqual(payment.kind, .hmrcPaymentProof)
        XCTAssertEqual(payment.docDate, day("2021-12-07"))
        XCTAssertEqual(payment.amountMinorUnits, 200_000)
        XCTAssertEqual(payment.currency, .gbp)
    }

    func testRentReceiptPeriod() {
        let metadata = analyze("Recibo de Renda Eletrónico N.º 12 Data de emissão: 2025-03-02 Período de renda: 2025-03-01 a 2025-03-31 "
                               + "Importância recebida: 1.500,00 €")
        XCTAssertEqual(metadata.kind, .rentReceipt)
        XCTAssertEqual(metadata.docDate, day("2025-03-02"))
        XCTAssertEqual(metadata.periodStart, day("2025-03-01"))
        XCTAssertEqual(metadata.periodEnd, day("2025-03-31"))
        XCTAssertEqual(metadata.amountMinorUnits, 150_000)
    }

    func testUtilityInvoiceWordPeriod() {
        let metadata = analyze("EDP Comercial Documento emitido a: 14 de novembro 2022 Período de faturação: 12 de setembro a 11 de novembro 2022 "
                               + "Quanto tenho a pagar? 130,00 €")
        XCTAssertEqual(metadata.kind, .utilityInvoice)
        XCTAssertEqual(metadata.docDate, day("2022-11-14"))
        XCTAssertEqual(metadata.periodStart, day("2022-09-12"))
        XCTAssertEqual(metadata.periodEnd, day("2022-11-11"))
        XCTAssertEqual(metadata.amountMinorUnits, 13_000)
    }

    func testFallsBackToFileNameWithoutText() {
        let analysis = EvidenceAnalyzer.analyze(text: nil, textStatus: .image, fileName: "20240716 - Prestacao.pdf")
        XCTAssertEqual(analysis.metadata.kind, .mortgageNotice)
        XCTAssertEqual(analysis.metadata.docDate, day("2024-07-16"))
        XCTAssertNil(analysis.metadata.amountMinorUnits)
        XCTAssertEqual(analysis.textStatus, .image)
    }

    func testAnalyzesGlyphPDFEndToEnd() {
        let url = EvidenceTestPDFs.glyphPDF(["Exmo(a). Senhor(a)", "DATA: 2023-05-08", "AVISO DE DÉBITO", "PAGAMENTOS AO ESTADO",
                                             "Referencia : 111122000000001", "MONTANTE PAGO : 250,00 EUROS"], name: "advice.pdf")
        let analysis = EvidenceAnalyzer.analyze(url)
        XCTAssertEqual(analysis.textStatus, .glyph)
        XCTAssertEqual(analysis.metadata.textStatus, .glyph)
        XCTAssertEqual(analysis.metadata.extractedText, analysis.extractedText)
        XCTAssertEqual(analysis.metadata.kind, .imiPayment)
        XCTAssertEqual(analysis.metadata.docDate, day("2023-05-08"))
        XCTAssertEqual(analysis.metadata.amountMinorUnits, 25_000)
        XCTAssertEqual(analysis.metadata.currency, .eur)
        XCTAssertTrue(analysis.extractedText?.contains("PAGAMENTOS AO ESTADO") == true)

        var document = EvidenceDocument(sha256: "abc", storedRelativePath: "ab/abc.pdf", originalFileName: "advice.pdf", byteCount: 1, addedAt: Date())
        analysis.apply(to: &document)
        XCTAssertEqual(document.kind, .imiPayment)
        XCTAssertEqual(document.textStatus, .glyph)
        XCTAssertEqual(document.amountMinorUnits, 25_000)
        XCTAssertEqual(document.extractedText, analysis.extractedText)
    }

    func testAnalyzesTextPDFEndToEnd() {
        let url = EvidenceTestPDFs.textPDF(["EXEMPLO CONTABILIDADE LDA", "Fatura-recibo FR 2025/3", "Data 2025-05-20",
                                            "Recebemos a quantia de 240,00 € (duzentos e quarenta euros)"], name: "FR 2025_3.pdf")
        let analysis = EvidenceAnalyzer.analyze(url)
        XCTAssertEqual(analysis.textStatus, .text)
        XCTAssertEqual(analysis.metadata.kind, .accountantInvoice)
        XCTAssertEqual(analysis.metadata.docDate, day("2025-05-20"))
        XCTAssertEqual(analysis.metadata.amountMinorUnits, 24_000)
        XCTAssertEqual(analysis.metadata.currency, .eur)
    }
}

final class EvidenceAnalyzerSumTotalTests: XCTestCase {
    private func analyze(_ text: String) -> EvidenceMetadata {
        EvidenceAnalyzer.analyze(text: text, textStatus: .text, fileName: "document.pdf").metadata
    }

    func testTotalSplitFromItsLabelIsTheSumOfThePartsAbove() {
        let text = """
        Generali Seguros Fatura/Recibo Seguro Multirrisco
        PRÉMIO COMERCIAL 355,73 €
        SELO (*) 32,02 €
        Prémio (Preço) total a pagar 13,69 €
        401,44 €
        Data de emissão: 2025-10-12
        """
        let metadata = analyze(text)
        XCTAssertEqual(metadata.kind, .insuranceReceipt)
        XCTAssertEqual(metadata.amountMinorUnits, 40_144)
        XCTAssertEqual(metadata.note, "Total: the sum of the amounts above it")
    }

    func testNoSumMatchTakesTheLargestOfTheCompetingAmounts() {
        let text = "Fatura/Recibo Seguro Generali Seguros\nPrémio comercial 50,00 €\nTotal a pagar 4,00 €\n60,00 €\nData de emissão: 2025-10-12"
        let metadata = analyze(text)
        XCTAssertEqual(metadata.amountMinorUnits, 6_000)
        XCTAssertEqual(metadata.note, "Total: the largest amount after the total label")
    }

    func testSameLineAmountsKeepTheFirst() {
        let text = "Fatura/Recibo Seguro Generali Seguros\nPrémio comercial 50,00 €\nTotal a pagar 4,00 € 60,00 €\nData de emissão: 2025-10-12"
        XCTAssertEqual(analyze(text).amountMinorUnits, 400)
    }

    func testAmountBeyondTwoLinesAfterTheLabelIsIgnored() {
        let text = "Fatura/Recibo Seguro Generali Seguros\nPrémio comercial 50,00 €\nTotal a pagar 4,00 €\nobservações\nreferência\n60,00 €"
        XCTAssertEqual(analyze(text).amountMinorUnits, 400)
    }

    func testBroadLabelKeepsTheFirstAmountEvenWhenALargerFollows() {
        let text = "Recibo de Renda Eletrónico N.º 12 Data de emissão: 2025-03-02\nValor da renda 750,00 €\nCaução 1.500,00 €"
        let metadata = analyze(text)
        XCTAssertEqual(metadata.kind, .rentReceipt)
        XCTAssertEqual(metadata.amountMinorUnits, 75_000)
    }

    func testCandidateRepeatingOneAmountAboveIsNotASum() {
        let text = "Fatura/Recibo Seguro Generali Seguros\nPrémio comercial 50,00 €\nTotal a pagar 4,00 €\n50,00 €"
        // 50,00 repeats the single amount above; it is no sum, so the largest-of-total fallback decides.
        XCTAssertNotEqual(analyze(text).note, "Total: the sum of the amounts above it")
    }

    func testSingleAmountAfterTheLabelIsUnchanged() {
        let text = "Fatura/Recibo Seguro Generali Seguros\nPrémio comercial 50,00 €\nTotal a pagar\n60,00 €\nData de emissão: 2025-10-12"
        let metadata = analyze(text)
        XCTAssertEqual(metadata.amountMinorUnits, 6_000)
        XCTAssertNil(metadata.note)
    }
}
