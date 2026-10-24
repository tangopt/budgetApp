import XCTest
@testable import BudgetCore

final class DocumentClassifierTests: XCTestCase {
    func testClassifiesByText() {
        let table: [(String, DocumentKind)] = [
            ("Empréstimos AVISO DÉBITO PRESTAÇÃO CONTA EMPRÉSTIMO : CREDITO HABITAÇÃO TOTAL EUR: 1.000,00", .mortgageNotice),
            ("AVISO DE DÉBITO SEGURO Nº APÓLICE PRÉMIO TOTAL BBVA SEGUROS,SOC. ANONIMA DE SEGUROS", .insuranceReceipt),
            ("Generali Seguros, S.A. clientes@tranquilidade.pt Fatura/Recibo Seguro Multirrisco Total: 50,00 € de acordo com as condições gerais", .insuranceReceipt),
            ("MAPFRE SEGUROS GERAIS Aviso de pagamento do prémio", .insuranceReceipt),
            ("Condições Gerais Seguro Multirriscos Habitação MAPFRE", .insurancePolicy),
            ("IMPOSTO MUNICIPAL SOBRE IMÓVEIS 1a. PRESTAÇÃO Referência para pagamento 111 016 000 000 001 "
                + "Para efetuar o pagamento selecione Pagamentos ao Estado", .imiNotice),
            ("AVISO DE DÉBITO CARREGAMENTO PAGAMENTOS AO ESTADO N.º DUC : Referencia : 111122000000001 MONTANTE PAGO : 100,00 EUROS", .imiPayment),
            ("Pagamentos - Estado - 104700000000001 Titular: A PERSON Montante: 900,00 EUR", .ptIRSPaymentProof),
            ("2ª VIA PARA PAGAMENTO DE NOTA DE COBRANÇA DE IRS Instruções: Pagamentos ao Estado; Importância a pagar 900,00", .ptIRSPaymentNote),
            ("Demonstração de Liquidação de IRS Período de Rendimentos 2023-01-01 a 2023-12-31", .ptIRSAssessment),
            ("MODELO 3 AUTORIDADE TRIBUTÁRIA DECLARAÇÃO DE RENDIMENTOS - IRS", .ptIRSDeclaration),
            ("Recibo nº 0042 Condomínio Edifício Exemplo Recebemos de v/ exa o pagamento dos seguintes valores", .condominioReceipt),
            ("Recibo de Renda Eletrónico N.º 12 Período de renda 2025-03-01 a 2025-03-31", .rentReceipt),
            ("EXEMPLO LDA Fatura-recibo FR 2025/1 Serviço de Assistência fiscal ref ao ano de 2025", .accountantInvoice),
            ("Invoice InvoiceDate 4Dec2024 ExampleTaxAdvisers Selfassessmenttaxreturn 2023/24 TOTALGBP 640.00", .accountantInvoice),
            ("Fatura-recibo FR 2025/2 Honorários Advogada", .legalInvoice),
            ("EDP Comercial - Comercialização de Energia, S.A. Quanto tenho a pagar? 46,54 €", .utilityInvoice),
            ("FATURA FT 0423/1 Consumo [kWh] Valor a Pagar: 25,00 €", .utilityInvoice),
            ("SIMAR Serviços Intermunicipalizados de Águas e Resíduos", .utilityInvoice),
            ("MENSAGENS PATRIMÓNIO CONSOLIDADO Moeda: EUR Exmo. Senhor A PERSON PERÍODO DE 2025/08/01 A 2025/08/31 CLIENTE Nº 1 "
                + "Seguro Vida BBVA Seguros prémio", .bankStatement),
            ("Conta à Ordem - Transferência - PT50 Tipo de Operação: Transferência a crédito SEPA Montante: 300,00 EUR", .bankTransferProof),
            ("P60 End of Year Certificate Tax Year to 5 April 2024 This is a printed copy of an eP60", .p60),
            ("P11D Expenses and benefits 2023 to 2024", .p11d),
            ("P45 Part 1A Details of employee leaving work", .p45),
            ("Calculation Result for 2023-24 How we have worked out your Income Tax", .sa302),
            ("Calculation result for the quiz", .other),
            ("P60 printed copy", .other),
            ("HM Revenue & Customs Tax Return for the year ended 5 April 2024. Tax calculation summary", .taxReturn),
            ("Payment complete Your payment reference is 1234567890K Tax Self Assessment Amount £2,000.00", .hmrcPaymentProof),
            ("Your tax code notice This is to tell you your tax code(s) for 6 April 2025 to 5 April 2026 tax calculation", .taxCodeNotice),
            ("HM Revenue & Customs Your Annual Tax Summary 2016-17 Dear MR P EXAMPLE This is how we worked out your tax", .hmrcLetter),
            ("Check details The information below will be sent to HM Revenue & Customs Register for Self Assessment", .hmrcLetter),
            ("Authorising your agent Please read the notes on the back before completing this authority", .hmrcLetter),
            ("Dear Mr Example Disclosure under the Worldwide Disclosure Facility Thank you for your offer", .hmrcLetter),
            ("HMRC: Tax years Tax year overview Tax year ending 05 Apr 2021 Description Amount", .hmrcLetter),
            ("HM Revenue & Customs Dear MR P EXAMPLE National Insurance number QQ 12 34 56 C Your tax account", .hmrcLetter),
            // An accountant's invoice for a disclosure, a cover letter and a return page keep their kinds.
            ("Example Tax Advisers Invoice Invoice Date 15 May 2021 Description Worldwide Disclosure Facility for tax years 2015/16 - 2019/20 Subtotal 1,000.00 TOTAL GBP 1,200.00", .accountantInvoice),
            ("Dear Mr Example, please find your Self Assessment return for HMRC attached. Kind regards, Example Tax Advisers", .other),
            ("Tax Return 2024 Unique Taxpayer Reference (UTR) 1234567890 Your personal details", .other),
            ("Something unrelated entirely", .other),
            ("Fatura-Recibo FR 2025/9 Serviços diversos", .other),
            ("EXTRATO COMBINADO Saldo anterior 1.000,00 Movimentos SEPADD/EDP COM -50,00 SEPADD/BBVASEG -100,00 COBR. REC. TOT PRESTACAO", .bankStatement),
            ("Comprovativo de transferência Tipo de Operação: Transferência a crédito SEPA Nome beneficiário: EDP Comercial Montante: 50,00 EUR", .bankTransferProof),
            ("Comprovativo de Pagamento Autoridade Tributária e Aduaneira Imposto Municipal sobre Imóveis Referência 111 000 000 000 001 Valor 250,00", .imiPayment),
            ("Recibo nº 0007 Condomínio Exemplo Recebemos o pagamento: quota 50,00 seguro multirriscos do edifício 10,00", .condominioReceipt),
            ("Pagamentos - Estado - 702000000000001 Credor: Estado Montante: 25,00 EUR", .courtFee),
            ("Documento Único de Cobrança IGFEJ Taxa de justiça", .courtFee),
            ("Exemplo - Mediação Imobiliária, Lda. Fatura FAC 2/1 Mediação de arrendamento TOTAL 2 400,00 EUR", .lettingAgentFee)
        ]
        for (text, kind) in table {
            XCTAssertEqual(DocumentClassifier.classify(text: text, fileName: "document.pdf"), kind, text)
        }
    }

    func testFallsBackToFileName() {
        let table: [(String, DocumentKind)] = [
            ("20240116 - Prestacao.pdf", .mortgageNotice),
            ("201802 - 201806-201812 - 20180627 - Seg MR BBVA.pdf", .insuranceReceipt),
            ("20160531 - Seg Vida BBVA.pdf", .insuranceReceipt),
            ("Fatura_Recibo_0001234567_20231014.pdf", .insuranceReceipt),
            ("IMI 2025 - 01.pdf", .imiNotice),
            ("20250508 - IMI 2024-01.pdf", .imiPayment),
            ("IMI_Comprovativo_202507.pdf", .imiPayment),
            ("Condominio 2023 01-06.pdf", .condominioReceipt),
            ("Accountancy fee-20250410-Contabilidade-€200.pdf", .accountantInvoice),
            ("Legal Fees-20250411-Advogada-€300.pdf", .legalInvoice),
            ("20250106 - Luz.pdf", .utilityInvoice),
            ("20250116 - Gás .pdf", .utilityInvoice),
            ("20250128 - Água .pdf", .utilityInvoice),
            ("P60_Example_2023-24.pdf", .p60),
            ("Example - P11D_2025.PDF", .p11d),
            ("Example - P45 -2025.pdf", .p45),
            ("IRS 2023 Declaracao Example.pdf", .ptIRSDeclaration),
            ("IRS 2023 Liquidacao Example.pdf", .ptIRSAssessment),
            ("IRS 2023 Pagamento Recibo Example.pdf", .ptIRSPaymentProof),
            ("IRS 2024 Nota Pagamento Example.pdf", .ptIRSPaymentNote),
            ("Example - SA 23.24 - Approval Doct - signed.pdf", .taxReturn),
            ("Any other expense-20250421-IGFEJ-DUC-€25.pdf", .courtFee),
            ("Letting fee-20250413-ERA-€2400.pdf", .lettingAgentFee),
            ("BBVApt-ContaOrdem-Transferencia-000000000000-20220101120000.pdf", .bankTransferProof),
            ("Recibo de Renda 2025-03.pdf", .rentReceipt),
            ("20210615 - UTR Letter.png", .hmrcLetter),
            ("SA1 - Register for Self-assessment - 2.pdf", .hmrcLetter),
            ("Example-64-8 form.pdf", .hmrcLetter),
            ("HMRC rates 2024.pdf", .other),
            ("HMRC exchange rate 2023.pdf", .other),
            // "RATE" only as a word: a letter named "separate" or "accurate" is still a letter.
            ("UTR letter - separate copy.pdf", .hmrcLetter),
            // An accountant's invoice for HMRC work is the invoice.
            ("HMRC WDF accountancy fee 2021.pdf", .accountantInvoice),
            ("Accountant invoice - SA1 registration.pdf", .accountantInvoice),
            ("IMG_3015.JPG", .other)
        ]
        for (name, kind) in table {
            XCTAssertEqual(DocumentClassifier.classify(text: nil, fileName: name), kind, name)
        }
    }

    func testTextRulesWinOverTheFileName() {
        // A condomínio payment made by bank transfer, filed as "recibo".
        XCTAssertEqual(DocumentClassifier.classify(text: "Conta à Ordem - Transferência Nome beneficiário: Condominio Exemplo Montante: 500,00 EUR",
                                                   fileName: "Condominio 2024-recibo.pdf"), .bankTransferProof)
        // Unreadable text (a font with shifted codes) falls back to the name.
        XCTAssertEqual(DocumentClassifier.classify(text: "$9&$3,7­26$/*8(,5 'HDFRUGRFRP", fileName: "20250128 - Água .pdf"), .utilityInvoice)
    }
}
