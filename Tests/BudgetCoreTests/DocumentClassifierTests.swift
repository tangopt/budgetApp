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

    // MARK: Repair bills and stamp duty (synthetic texts)

    func testRepairBills() {
        XCTAssertEqual(DocumentClassifier.classify(text: "Canalizações Exemplo Lda\nFATURA-RECIBO FR 2026/15\nReparação de autoclismo\nMão de obra 40,00\nTotal 79,95 EUR", fileName: "doc.pdf"), .repairInvoice)
        XCTAssertEqual(DocumentClassifier.classify(text: "Demo Handyman Ltd\nINVOICE 12\nBoiler repair and maintenance\nTotal £120.00", fileName: "x.pdf"), .repairInvoice)
        XCTAssertEqual(DocumentClassifier.classify(text: "Exemplo Eletricistas Lda\nFatura FT 2026/3\nSubstituição de quadro elétrico\nTotal 150,00 EUR", fileName: "y.pdf"), .repairInvoice)
        XCTAssertEqual(DocumentClassifier.classify(text: "Fatura FT 2026/4\nDesentupimento de esgoto\nTotal 60,00 EUR", fileName: "z.pdf"), .repairInvoice)
        XCTAssertEqual(DocumentClassifier.classify(text: nil, fileName: "Fatura reparacao esquentador.pdf"), .repairInvoice)
        XCTAssertEqual(DocumentClassifier.classify(text: nil, fileName: "20260110 - Obras cozinha.pdf"), .repairInvoice)
        XCTAssertEqual(DocumentClassifier.classify(text: nil, fileName: "Canalizador_fatura.pdf"), .repairInvoice)
        XCTAssertEqual(DocumentClassifier.classify(text: nil, fileName: "Boiler repair invoice.pdf"), .repairInvoice)
    }

    func testRepairWordingInOtherIssuersKeepsTheirKinds() {
        // condomínio receipt for works, insurance receipt, bank fee "Manutenção de conta", utility invoice
        XCTAssertEqual(DocumentClassifier.classify(text: "Condomínio Rua Exemplo 1\nRecibo N 44\nQuota extra obras fachada", fileName: "a.pdf"), .condominioReceipt)
        XCTAssertEqual(DocumentClassifier.classify(text: "Extrato\nSaldo\nComissão manutenção de conta", fileName: "b.pdf"), .bankStatement)
        XCTAssertEqual(DocumentClassifier.classify(text: "Fatura-Recibo FR 2026/7\nComissão de manutenção de conta 5,00\nImposto do Selo 0,20", fileName: "c.pdf"), .other)
        XCTAssertEqual(DocumentClassifier.classify(text: "MAPFRE SEGUROS GERAIS\nFatura/Recibo\nSeguro Multirriscos: danos por água, reparação\nTotal 50,00 €", fileName: "d.pdf"), .insuranceReceipt)
        XCTAssertEqual(DocumentClassifier.classify(text: "EDP Comercial\nFatura FT 0423/1\nManutenção do contador\nValor a Pagar: 25,00 €", fileName: "e.pdf"), .utilityInvoice)
        XCTAssertEqual(DocumentClassifier.classify(text: "Exemplo Lda\nFatura-recibo FR 2026/2\nServiço de Assistência fiscal: obras dedutíveis", fileName: "f.pdf"), .accountantInvoice)
        XCTAssertEqual(DocumentClassifier.classify(text: "Fatura-recibo FR 2026/3\nHonorários Advogada: litígio sobre obras", fileName: "g.pdf"), .legalInvoice)
        XCTAssertEqual(DocumentClassifier.classify(text: "Comprovativo de transferência\nTipo de Operação: Transferência a crédito SEPA\nDescritivo: Fatura reparação\nMontante: 79,95 EUR", fileName: "h.pdf"), .bankTransferProof)
        // "OBRAS" as a word only ("sobras", "manobras").
        XCTAssertEqual(DocumentClassifier.classify(text: "Fatura FT 2026/5\nSobras de jantar\nTotal 12,00", fileName: "i.pdf"), .other)
        // File names: the other kinds' rules and bank words keep theirs.
        XCTAssertEqual(DocumentClassifier.classify(text: nil, fileName: "Condominio obras 2026.pdf"), .condominioReceipt)
        XCTAssertEqual(DocumentClassifier.classify(text: nil, fileName: "Seguro reparacao.pdf"), .insuranceReceipt)
        XCTAssertEqual(DocumentClassifier.classify(text: nil, fileName: "Transferencia obras.pdf"), .bankTransferProof)
        XCTAssertEqual(DocumentClassifier.classify(text: nil, fileName: "Extrato manutencao.pdf"), .bankStatement)
        XCTAssertEqual(DocumentClassifier.classify(text: nil, fileName: "Comissao manutencao de conta.pdf"), .other)
        XCTAssertEqual(DocumentClassifier.classify(text: nil, fileName: "Prestacao - Recibo 12:480.pdf"), .mortgageReceipt)
    }

    func testStampDuty() {
        XCTAssertEqual(DocumentClassifier.classify(text: "Autoridade Tributária e Aduaneira\nDOCUMENTO DE COBRANÇA\nImposto do Selo\nVerba 2 Arrendamento\nValor a pagar 95,00 €", fileName: "d.pdf"), .stampDuty)
        XCTAssertEqual(DocumentClassifier.classify(text: "COMPROVATIVO DE PAGAMENTO\nPortal das Finanças\nImposto do Selo\nValor 95,00", fileName: "e.pdf"), .stampDuty)
        XCTAssertEqual(DocumentClassifier.classify(text: "Pagamentos ao Estado\nImposto do Selo\n95,00 EUR", fileName: "f.pdf"), .stampDuty)
        XCTAssertEqual(DocumentClassifier.classify(text: "Nota de cobrança\nImposto Selo\nLiquidação n.º 2026 000001\nValor a pagar 30,00 €", fileName: "g.pdf"), .stampDuty)
        XCTAssertEqual(DocumentClassifier.classify(text: nil, fileName: "Imposto do Selo 2026.pdf"), .stampDuty)
        XCTAssertEqual(DocumentClassifier.classify(text: nil, fileName: "Stamp duty - lease.pdf"), .stampDuty)
        XCTAssertEqual(DocumentClassifier.classify(text: nil, fileName: "Selo_contrato_2026.pdf"), .stampDuty)
    }

    func testStampDutyLinesInLoanLettersAndAdvicesKeepTheirKinds() {
        XCTAssertEqual(DocumentClassifier.classify(text: "Aviso débito prestação\nEmpréstimo 0001\nJuros 300,00\nImposto do Selo 12,00", fileName: "g.pdf"), .mortgageNotice)
        XCTAssertEqual(DocumentClassifier.classify(text: "Recibo de empréstimo 193/480\nImposto do Selo 12,00", fileName: "h.pdf"), .mortgageReceipt)
        // With a settlement ("liquidação") line, as loan letters have.
        XCTAssertEqual(DocumentClassifier.classify(text: "Aviso de débito prestação\nCrédito habitação 0001\nData de liquidação 2026-01-31\nImposto do Selo s/ juros 12,00", fileName: "i.pdf"), .mortgageNotice)
        XCTAssertEqual(DocumentClassifier.classify(text: "Recibo de empréstimo 193/480\nLiquidação da prestação\nImposto do Selo 12,00", fileName: "j.pdf"), .mortgageReceipt)
        XCTAssertEqual(DocumentClassifier.classify(text: "Encargos com imóveis\nEmpréstimo 0001\nLiquidação de juros\nImposto do Selo 140,00", fileName: "k.pdf"), .mortgageInterestStatement)
        // A bank's fee advice lists stamp duty on its commission.
        XCTAssertEqual(DocumentClassifier.classify(text: "AVISO DE DÉBITO\nComissão de manutenção\nData de liquidação 2026-01-31\nImposto do Selo 0,20", fileName: "l.pdf"), .other)
        // IMI, IRS and statements that mention stamp duty keep theirs.
        XCTAssertEqual(DocumentClassifier.classify(text: "AVISO DE DÉBITO\nPAGAMENTOS AO ESTADO\nReferencia : 111122000000001\nImposto do Selo\nMONTANTE PAGO : 100,00 EUROS", fileName: "m.pdf"), .imiPayment)
        XCTAssertEqual(DocumentClassifier.classify(text: "NOTA DE COBRANÇA DE IRS\nImposto do Selo\nImportância a pagar 900,00", fileName: "n.pdf"), .ptIRSPaymentNote)
        XCTAssertEqual(DocumentClassifier.classify(text: "Movimentos da conta\nPagamentos ao Estado 95,00\nImposto do Selo 0,20\nExtrato\nSaldo final 1.000,00", fileName: "o.pdf"), .bankStatement)
        // Loan file names keep theirs.
        XCTAssertEqual(DocumentClassifier.classify(text: nil, fileName: "Prestacao imposto selo.pdf"), .mortgageNotice)
    }

    func testRulesVersionIsBumpedForTheNewKinds() {
        XCTAssertEqual(DocumentClassifier.rulesVersion, 2)
    }

    // MARK: Fix round 1: the review's probes (synthetic)

    private func check(_ table: [(String?, String, DocumentKind)], file: StaticString = #filePath, line: UInt = #line) {
        for (text, name, kind) in table {
            XCTAssertEqual(DocumentClassifier.classify(text: text, fileName: name), kind, text ?? name, file: file, line: line)
        }
    }

    func testStampDutyWordingInOtherIssuersDocumentsKeepsTheirKinds() {
        check([
            // Insurers itemise stamp duty on premiums.
            ("Fidelidade\nDocumento de Cobrança\nSeguro Multirriscos Habitação\nPrémio 200,00\nImposto do Selo 18,00\nINEM 2,00", "x.pdf", .insuranceReceipt),
            ("Ageas Portugal Companhia de Seguros\nAviso de pagamento\nPrémio Comercial 200,00\nImposto do Selo 18,00\nData de liquidação 2026-01-31", "x.pdf", .other),
            ("BBVA SEGUROS\nRecibo de prémio\nImposto do Selo 3,00\nLiquidação 2026-01-01", "x.pdf", .insuranceReceipt),
            // Loan letters without "empréstimo" or "prestação".
            ("Aviso de débito\nCrédito à habitação 0001\nJuros 300,00\nImposto do Selo 12,00\nData de liquidação 2026-01-31", "x.pdf", .other),
            ("Comunicação de liquidação\nMútuo hipotecário n.º 0001\nJuros 300,00\nImposto do Selo s/ juros 12,00", "x.pdf", .other),
            // IMT's note lists the deed's stamp duty.
            ("Autoridade Tributária e Aduaneira\nDocumento de cobrança\nIMT - Imposto Municipal sobre as Transmissões Onerosas de Imóveis\nImposto do Selo verba 1.1", "x.pdf", .other),
            ("Condomínio Rua Exemplo\nRecibo N 5\nQuota\nImposto do Selo 0,00\nLiquidação", "x.pdf", .condominioReceipt),
            ("RECIBO DE RENDA ELETRÓNICO\nImposto do Selo\nLiquidação", "x.pdf", .rentReceipt),
            // "Liquidação" without the tax authority: an accountant's service.
            ("Contabilidade Exemplo\nFatura FT 1\nLiquidação de Imposto do Selo (serviço)\nTotal 50,00", "x.pdf", .accountantInvoice),
            ("PAGAMENTOS AO ESTADO\nReferencia : 702000000000001\nImposto do Selo", "x.pdf", .courtFee),
            ("Nota de cobrança\nIMI 2025\nImposto do Selo\n", "x.pdf", .imiNotice),
            ("Nota de cobrança\nIRS 2025\nValor a pagar 900", "x.pdf", .ptIRSPaymentNote),
            // A state payment with only its reference: left to the file name.
            ("AVISO DE DÉBITO\nPAGAMENTOS AO ESTADO\nReferencia : 161200000000001\nMONTANTE PAGO : 95,00 EUROS", "x.pdf", .other),
            ("AVISO DE DÉBITO\nPAGAMENTOS AO ESTADO\nReferencia : 161200000000001\nMONTANTE PAGO : 95,00 EUROS", "Imposto selo.pdf", .stampDuty),
            // File names: IMI's and IRS's keep theirs.
            (nil, "IMI e Selo 2025.pdf", .imiNotice),
            (nil, "IRS selo nota.pdf", .ptIRSPaymentNote)
        ])
    }

    func testStampDutyRecall() {
        check([
            ("Autoridade Tributária\nDocumento de cobrança\nImposto de Selo\nValor 95,00", "x.pdf", .stampDuty),
            ("COMPROVATIVO DE PAGAMENTO\nImposto do Selo\nDUC 161200000000001", "x.pdf", .stampDuty),
            ("Portal das Finanças\nImposto do Selo\nLiquidação n.º 2026 1\nValor a pagar 95,00", "x.pdf", .stampDuty)
        ])
    }

    func testRepairWordingInBankDocumentsKeepsTheirKinds() {
        check([
            // A transfer that describes the bill is the transfer, never the bill.
            ("Transferência SEPA\nOrdenante: Exemplo\nDescritivo: Fatura FT 15 reparação\nMontante: 79,95 EUR", "x.pdf", .bankTransferProof),
            ("AVISO DE DÉBITO\nPAGAMENTOS - SERVIÇOS/COMPRAS\nEntidade: Canalizações Exemplo\nRecibo\nMontante 79,95", "x.pdf", .other),
            ("Statement of account\nInvoice\nmaintenance", "x.pdf", .other)
        ])
        // An invoice asking to be paid by transfer is still the invoice.
        XCTAssertEqual(DocumentClassifier.classify(text: "Canalizações Exemplo Lda\nFatura FT 2026/9\nReparação de autoclismo\nTotal 79,95 EUR\n"
                                                   + "Pagamento por transferência bancária para o IBAN PT50 0000 0000 0000 0000 0000 0", fileName: "x.pdf"), .repairInvoice)
    }

    func testRepairPrecision() {
        check([
            ("Clínica Dentária Dra. Ana Caldeira\nFatura-Recibo FR 1\nConsulta\nTotal 50,00", "x.pdf", .other),
            ("Oficina Auto Exemplo\nFatura FT 1\nReparação de viatura 00-AA-00\nTotal 300,00", "x.pdf", .other),
            ("Stand Exemplo\nFatura FT 2\nManutenção automóvel matrícula 00-AA-00\nTotal 150,00", "x.pdf", .other),
            ("Exemplo Software Lda\nFatura FT 1\nManutenção anual licença\nTotal 100,00", "x.pdf", .other),
            ("Exemplo Lda\nFatura FT 3\nManutenção de software\nTotal 100,00", "x.pdf", .other),
            ("Loja Exemplo\nFatura\nSubstituição de ecrã telemóvel\nTotal 100,00", "x.pdf", .other),
            ("Galeria\nFatura\nPintura a óleo\nTotal 400,00", "x.pdf", .other),
            ("Galeria Exemplo\nFatura FT 4\nPintura, obra de arte\nTotal 400,00", "x.pdf", .other),
            ("Exemplo Telecomunicações\nFatura FT 5\nInstalação de fibra e internet\nTotal 30,00", "x.pdf", .other),
            // Words that start like an invoice series aren't one; a deed's deposit receipt isn't a bill.
            ("Escritura\nFração 1\nRecibo de sinal\nInstalação de cozinha", "x.pdf", .other),
            ("Hotel France 2026\nArranjo floral", "x.pdf", .other),
            ("FTSE 100 newsletter\nAvaria do mercado", "x.pdf", .other),
            // A tow truck's or a garage's receipt is a car's.
            ("Reboques Exemplo\nRecibo\nAvaria na A1, reboque\nTotal 120,00", "x.pdf", .other),
            ("Oficina Exemplo\nFatura\nConserto do travão\nTotal 120,00", "x.pdf", .other),
            // A water heater or boiler named as the thing worked on.
            ("Exemplo Lda\nFatura FT 6\nRevisão da caldeira\nTotal 90,00", "x.pdf", .repairInvoice),
            ("Exemplo Lda\nFatura FT 7\nLimpeza do esquentador\nTotal 45,00", "x.pdf", .repairInvoice)
        ])
    }

    func testRepairRecall() {
        check([
            ("Exemplo Lda\nFatura FT 1\nConserto de estore\nTotal 80,00", "x.pdf", .repairInvoice),
            ("Exemplo Lda\nFatura-Recibo\nReparação de avaria máquina de lavar\nTotal 80,00", "x.pdf", .repairInvoice),
            ("Exemplo Lda\nFatura\nAvaria do estore\nTotal 80,00", "x.pdf", .repairInvoice),
            ("Exemplo Lda\nFatura\nInstalação de torneira\nTotal 80,00", "x.pdf", .repairInvoice),
            ("Serralharia Exemplo\nFatura\nArranjo de fechadura\nTotal 80,00", "x.pdf", .repairInvoice),
            ("Fatura FT 3\nObras de remodelação da casa de banho\nTotal 2.000,00", "x.pdf", .repairInvoice),
            ("Fatura FT 3\nServiço de canalizador\nTotal 60,00", "x.pdf", .repairInvoice),
            ("FT 2026/12\nReparação de autoclismo\nTotal 60,00", "x.pdf", .repairInvoice),
            ("FR A/7\nConserto de porta\nTotal 60,00", "x.pdf", .repairInvoice),
            ("Fatura simplificada FS 1\nManutenção caldeira\nTotal 60,00", "x.pdf", .repairInvoice),
            ("Exemplo Lettings Ltd\nInvoice 12\nProperty maintenance: boiler repair\nTotal £120", "x.pdf", .repairInvoice),
            (nil, "Fatura eletricista.pdf", .repairInvoice),
            (nil, "Electricista 2026.pdf", .repairInvoice),
            (nil, "canalizador.pdf", .repairInvoice),
            (nil, "Manutencao caldeira 2025.pdf", .repairInvoice),
            (nil, "Manutencao elevador condominio.pdf", .condominioReceipt),
            (nil, "Obras seguro.pdf", .insuranceReceipt),
            // A utility's name wins over the repair words.
            (nil, "EDP manutencao.pdf", .utilityInvoice),
            (nil, "Galp reparacao contador.pdf", .other)
        ])
    }

    func testRepairBillsAreImportedAndTheirTotalRead() {
        XCTAssertTrue(EvidenceInitialImport.relevantKinds.contains(.repairInvoice))
        // The total to pay, not the larger estimate before it.
        let text = "Canalizações Exemplo Lda\nFatura-Recibo FR 2026/15\nReparação de autoclismo\nOrçamento inicial 150,00 €\nTotal a pagar 79,95 €"
        XCTAssertEqual(EvidenceAnalyzer.amount(in: text, kind: .repairInvoice)?.minorUnits, 7_995)
    }
}
