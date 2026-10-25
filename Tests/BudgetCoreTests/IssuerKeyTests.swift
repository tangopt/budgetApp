import GRDB
import XCTest
@testable import BudgetCore
import TestSupport

final class IssuerKeyTests: XCTestCase {
    func testNIFAfterLabelIsTheKeyUnlessItIsOurs() {
        let text = "Demo Power, S.A.\nNIF: 503 504 564\nTotal 10,00"
        let key = IssuerKey.derive(text: text, fileName: "a.pdf", ownNIFs: [])
        XCTAssertEqual(key?.key, "nif:503504564")
        XCTAssertEqual(key?.label, "Demo Power, S.A.")
        let own = IssuerKey.derive(text: text, fileName: "a.pdf", ownNIFs: ["503504564"])
        XCTAssertEqual(own?.key, "line:DEMO POWER, S.A.")
    }

    func testInvalidNIFIsIgnored() {
        XCTAssertEqual(IssuerKey.derive(text: "Demo Power\nNIF 503504565", fileName: "a.pdf", ownNIFs: [])?.key, "line:DEMO POWER")
    }

    func testUKVATNumber() {
        XCTAssertEqual(IssuerKey.derive(text: "Demo Energy Ltd\nVAT Reg No GB 123 4567 89", fileName: "a.pdf", ownNIFs: [])?.key, "vat:123456789")
    }

    func testCompanyNumber() {
        XCTAssertEqual(IssuerKey.derive(text: "Demo Energy Ltd\nCompany registration number: 01234567", fileName: "a.pdf", ownNIFs: [])?.key, "crn:01234567")
    }

    func testGenericFirstLineIsNotAnIssuerKey() {
        let key = IssuerKey.derive(text: "FATURA\nDemo Power, S.A.\nTotal 10,00", fileName: "a.pdf", ownNIFs: [])
        XCTAssertEqual(key?.key, "line:DEMO POWER, S.A.")
        XCTAssertEqual(key?.label, "Demo Power, S.A.")
    }

    func testNoTextNoKey() {
        XCTAssertNil(IssuerKey.derive(text: nil, fileName: "a.pdf", ownNIFs: []))
        XCTAssertNil(IssuerKey.derive(text: "FATURA\n123", fileName: "a.pdf", ownNIFs: []))
    }

    func testRuleKeysAndActionsRoundTrip() throws {
        let issuer = IssuerKey(key: "nif:503504564", label: "Demo Power")
        XCTAssertEqual(ImportRuleKind.matchKey(issuer: issuer), "nif:503504564")
        let action = LinkAction(entity: nil, role: "invoice", descriptionKey: "DEMO")
        let data = try JSONEncoder().encode(action)
        XCTAssertEqual(try JSONDecoder().decode(LinkAction.self, from: data), action)
    }

    func testConsumerFinalAndZeroNIFsAreNeverIssuers() {
        XCTAssertEqual(IssuerKey.derive(text: "Demo Power\nNIF: 999999990", fileName: "a.pdf", ownNIFs: [])?.key, "line:DEMO POWER")
        XCTAssertEqual(IssuerKey.derive(text: "Demo Power\nNIF: 000000000", fileName: "a.pdf", ownNIFs: [])?.key, "line:DEMO POWER")
    }

    func testCustomerNIFIsSkippedAndFooterNIPCWins() {
        let text = "FATURA\nCliente: Ana Demo\nNIF: 503504564\nTotal 10,00\nDemo Power, S.A. NIPC 500000000"
        XCTAssertTrue(RentReceiptPDFs.isValidNIF("500000000"))
        XCTAssertEqual(IssuerKey.derive(text: text, fileName: "a.pdf", ownNIFs: [])?.key, "nif:500000000")
        // The label on the line before the NIF counts too.
        let block = "Adquirente\nNIF 503504564\nDemo Power, S.A.\nNIPC 500000000"
        XCTAssertEqual(IssuerKey.derive(text: block, fileName: "a.pdf", ownNIFs: [])?.key, "nif:500000000")
    }

    func testTenantNIFInOwnNIFsIsSkipped() {
        let text = "Demo Power\nNIF 503504564\nNIPC 500000000"
        XCTAssertEqual(IssuerKey.derive(text: text, fileName: "a.pdf", ownNIFs: ["503504564"])?.key, "nif:500000000")
    }

    func testLabelIsNeverAFieldLabelLine() {
        let key = IssuerKey.derive(text: "Contribuinte: 503504564\nDemo Power, S.A.", fileName: "a.pdf", ownNIFs: [])
        XCTAssertEqual(key?.key, "nif:503504564")
        XCTAssertEqual(key?.label, "Demo Power, S.A.")
        let before = IssuerKey.derive(text: "Demo Power, S.A.\nData: 01/02/2026\nContribuinte: 503504564\nOther Company Ltd", fileName: "a.pdf", ownNIFs: [])
        XCTAssertEqual(before?.label, "Demo Power, S.A.")
    }

    func testGenericAndFieldLinesAreNotKeys() {
        XCTAssertEqual(IssuerKey.derive(text: "FATURA N.º 123\nPAGE 1 OF 2\nData: 01/02/2026\nDemo Power", fileName: "a.pdf", ownNIFs: [])?.key, "line:DEMO POWER")
    }

    func testNIFWindowStopsAtEndOfLine() {
        XCTAssertEqual(IssuerKey.derive(text: "Demo Power\nNIF:\n503504564", fileName: "a.pdf", ownNIFs: [])?.key, "line:DEMO POWER")
    }

    func testAccentAndLabelVariants() {
        XCTAssertEqual(IssuerKey.derive(text: "Demo\nN.º Contribuinte 503 504 564", fileName: "a.pdf", ownNIFs: [])?.key, "nif:503504564")
        XCTAssertEqual(IssuerKey.derive(text: "Demo\nNúmero de Contribuinte: 503504564", fileName: "a.pdf", ownNIFs: [])?.key, "nif:503504564")
        XCTAssertEqual(IssuerKey.derive(text: "Demo\nNIPC 503504564", fileName: "a.pdf", ownNIFs: [])?.key, "nif:503504564")
        XCTAssertEqual(IssuerKey.derive(text: "Demo\nDestinatário\nNIF 503504564\nNIPC 500000000", fileName: "a.pdf", ownNIFs: [])?.key, "nif:500000000")
    }

    func testLabelTruncatesTo40() {
        let long = "Demo Power and Light Distribution Company of Portugal"
        XCTAssertLessThanOrEqual(IssuerKey.derive(text: long + "\nNIF 503504564", fileName: "a.pdf", ownNIFs: [])!.label.count, 40)
    }

    func testTwoIssuersSharingAHeaderGetDifferentKeys() {
        let a = IssuerKey.derive(text: "FATURA\nNIF 503504564", fileName: "a.pdf", ownNIFs: [])
        let b = IssuerKey.derive(text: "FATURA\nNIF 500000000", fileName: "b.pdf", ownNIFs: [])
        XCTAssertNotEqual(a?.key, b?.key)
    }

    func testFigurePositionKeyNeedsAField() {
        let issuer = IssuerKey(key: "nif:503504564", label: "Demo")
        XCTAssertEqual(ImportRuleKind.figurePositionKey(issuer: issuer, field: .amount), "nif:503504564#amount")
    }

    func testKnownPartiesAreEveryPersonNIF() throws {
        let manager = try TestDatabase.migratedManager()
        let db = manager.dbQueue
        try db.write { d in
            var a = Person(name: "A Demo", ptNif: "503 504 564"); try a.insert(d)
            var b = Person(name: "B Demo"); try b.insert(d)
        }
        let parties = try db.read { try IssuerKey.knownParties(db: $0) }
        XCTAssertEqual(parties, ["503504564", "name:A DEMO", "name:B DEMO"], "every person's NIF, and every person's name")
    }

    func testNameSharingTheNIFLineIsTheLabel() {
        let text = "FATURA\nCliente: Ana Demo\nNIF: 503504564\nTotal 10,00\nDemo Power, S.A. NIPC 500000000"
        let key = IssuerKey.derive(text: text, fileName: "a.pdf", ownNIFs: [])
        XCTAssertEqual(key?.key, "nif:500000000")
        XCTAssertEqual(key?.label, "Demo Power, S.A.")
    }

    func testCustomerLineIsNeverTheLabel() {
        let key = IssuerKey.derive(text: "Cliente: Ana Demo\nTotal 5\nNIPC 500000000", fileName: "a.pdf", ownNIFs: [])
        XCTAssertEqual(key?.key, "nif:500000000")
        XCTAssertEqual(key?.label, "nif:500000000")
    }

    func testRealNamesStartingWithGenericWordsSurvive() {
        XCTAssertEqual(IssuerKey.derive(text: "Recibo Verde Lda\nTotal 5", fileName: "a.pdf", ownNIFs: [])?.key, "line:RECIBO VERDE LDA")
    }

    func testDottedNIFSpelling() {
        XCTAssertEqual(IssuerKey.derive(text: "Demo Power\nN.I.F. 503504564", fileName: "a.pdf", ownNIFs: [])?.key, "nif:503504564")
    }

    // MARK: Final review fixes

    func testTwoSuppliersWithTaxInvoiceHeadersDontShareAKey() {
        let a = IssuerKey.derive(text: "TAX INVOICE\nDemo Energy Ltd\nTotal 10.00", fileName: "a.pdf", ownNIFs: [])
        let b = IssuerKey.derive(text: "TAX INVOICE\nOther Water Ltd\nTotal 10.00", fileName: "b.pdf", ownNIFs: [])
        XCTAssertEqual(a?.key, "line:DEMO ENERGY LTD")
        XCTAssertEqual(b?.key, "line:OTHER WATER LTD")
        XCTAssertNotEqual(a?.key, b?.key)
    }

    func testDocumentTitleLinesAreNeverKeys() {
        for title in ["TAX INVOICE", "VAT INVOICE", "Invoice - Original", "FATURA SIMPLIFICADA", "Fatura-Recibo Duplicado", "2ª Via",
                      "Segunda Via", "Factura", "Order Confirmation", "P60 End of Year Certificate", "P45", "P11D",
                      "Statement of Account", "Extrato", "Receipt No. 12", "Triplicado", "Tax Invoice Page 1 of 2", "FATURA Nº 123", "Fatura nº FT 2024/12"] {
            XCTAssertNil(IssuerKey.derive(text: title + "\n123,45", fileName: "a.pdf", ownNIFs: []), title)
        }
        XCTAssertEqual(IssuerKey.derive(text: "Recibo Verde Lda", fileName: "a.pdf", ownNIFs: [])?.key, "line:RECIBO VERDE LDA")
        XCTAssertEqual(IssuerKey.derive(text: "Invoice Masters Ltd", fileName: "a.pdf", ownNIFs: [])?.key, "line:INVOICE MASTERS LTD")
    }

    func testARecipientNameFirstLineIsNotAKey() throws {
        let manager = try TestDatabase.migratedManager()
        let parties = try manager.dbQueue.write { d -> Set<String> in
            var person = Person(name: "Ana Demo"); try person.insert(d)
            return try IssuerKey.knownParties(db: d)
        }
        let text = "ANA DEMO\nDemo Power Lda\nRua Exemplo 1\nTotal 10,00"
        XCTAssertEqual(IssuerKey.derive(text: text, fileName: "a.pdf", ownNIFs: parties)?.key, "line:DEMO POWER LDA")
        XCTAssertEqual(IssuerKey.derive(text: "Exma. Sra. Ana Demo\nDemo Power Lda", fileName: "a.pdf", ownNIFs: parties)?.key, "line:DEMO POWER LDA")
        XCTAssertNil(IssuerKey.derive(text: "Ana Demo\nTotal 10,00", fileName: "a.pdf", ownNIFs: parties))
    }

    func testVATRegistrationNumberWithoutGB() {
        XCTAssertEqual(IssuerKey.derive(text: "Demo Energy Ltd\nVAT Reg No: 123 4567 89", fileName: "a.pdf", ownNIFs: [])?.key, "vat:123456789")
        XCTAssertEqual(IssuerKey.derive(text: "Demo Energy Ltd\nVAT Registration Number 123456789", fileName: "a.pdf", ownNIFs: [])?.key, "vat:123456789")
        XCTAssertEqual(IssuerKey.derive(text: "Demo Energy Ltd\nVAT Reg. No. GB123456789", fileName: "a.pdf", ownNIFs: [])?.key, "vat:123456789")
        XCTAssertEqual(IssuerKey.derive(text: "Demo Energy Ltd\nVAT Reg No: 123 4567 89", fileName: "a.pdf", ownNIFs: [])?.label, "Demo Energy Ltd")
    }

    func testCustomerOrOwnVATNumbersAreNeverTheKey() {
        let customer = "Demo Energy Ltd\nCustomer VAT Number: 999999990\nVAT Reg No: 123 4567 89"
        XCTAssertEqual(IssuerKey.derive(text: customer, fileName: "a.pdf", ownNIFs: [])?.key, "vat:123456789")
        XCTAssertEqual(IssuerKey.derive(text: "Demo Energy Ltd\nCustomer VAT Number: 987 6543 21", fileName: "a.pdf", ownNIFs: [])?.key,
                       "line:DEMO ENERGY LTD", "a customer's number")
        XCTAssertEqual(IssuerKey.derive(text: "Demo Energy Ltd\nVAT Number: 999999990", fileName: "a.pdf", ownNIFs: [])?.key,
                       "line:DEMO ENERGY LTD", "an anonymous number")
        XCTAssertEqual(IssuerKey.derive(text: "Demo Energy Ltd\nVAT No: 987654321\nVAT Reg No 123456789", fileName: "a.pdf", ownNIFs: ["987654321"])?.key,
                       "vat:123456789", "our own number is skipped, the next one taken")
        XCTAssertEqual(IssuerKey.derive(text: "Demo Energy Ltd\nCustomer VAT: GB 987 6543 21\nVAT GB123456789", fileName: "a.pdf", ownNIFs: [])?.key,
                       "vat:123456789", "a customer's GB number is skipped too")
        XCTAssertEqual(IssuerKey.derive(text: "Demo Energy Ltd\nGB 987 6543 21", fileName: "a.pdf", ownNIFs: ["987654321"])?.key, "line:DEMO ENERGY LTD")
    }

    // MARK: Greetings, addressees and bank letters (rule-issuer)

    /// A bank's advice of a debit that names no creditor, in the layout of BBVA's "AVISO DÉBITO"
    /// letters: a greeting, closing boilerplate, the client's name and address, a movement
    /// description that is only a code and a reference. Invented values throughout.
    static let bareDebitAdvice = [
        "Exmo(a). Senhor(a)", "Com os nossos melhores cumprimentos Produzido por computador", "Não carece de assinatura", "O00000",
        "EXMO(S) SENHOR(ES):", "ANA DEMO", "1 DEMO ROAD", "AB1 2CD LONDON", "REINO UNIDO", "AVISO DÉBITO", "DATA: 2025-02-03",
        "NIB: 0000 0000 00000000000 00",
        "QUEIRA(M) NOTAR QUE, NESTA DATA, EFETUAMOS NA CONTA DE V.EXA(S),O SEGUINTE MOVIMENTO:",
        "Descrição do Movimento :", "AB/ /CODE1", "XYZ 1234567890123", "CONTA Nº: 000 000000000", "DATA VALOR: 2025-02-03",
        "10,00 TOTAL EUR:",
        "Banco Bilbao Vizcaya Argentaria S.A. - Sucursal em Portugal - Avenida Exemplo, 1, 1000-000 Lisboa - NIPC e CRC Lisboa 500 000 000",
    ]

    func testGreetingsAndClosingsAreNeverIssuers() {
        let greetings = ["Exmo(a). Senhor(a)", "Exmos. Senhores", "Ex.mo Sr. Cliente", "Ex.ma Senhora", "Exma. Sra.", "Caro cliente", "Cara Ana",
                         "Dear Sir/Madam", "Dear Ana", "Prezado Cliente", "EXMO(S) SENHOR(ES):", "Com os nossos melhores cumprimentos",
                         "Não carece de assinatura", "Yours sincerely"]
        for greeting in greetings {
            XCTAssertNil(IssuerKey.derive(text: greeting + "\n123,45", fileName: "a.pdf", ownNIFs: []), greeting)
            XCTAssertEqual(IssuerKey.derive(text: greeting + "\nDemo Power Lda\nTotal 10,00", fileName: "a.pdf", ownNIFs: [])?.key,
                           "line:DEMO POWER LDA", greeting)
        }
    }

    func testTheAddresseeBlockNeverKeysTheIssuer() {
        let parties: Set<String> = ["name:ANA DEMO"]
        // The client's name, address and number under the greeting; the issuer's name further down.
        let text = ["EXMO. SENHOR(A)", "ANA DEMO", "1 DEMO ROAD", "AB1 2CD LONDON REINO UNIDO", "LISBOA", "1000-001 LISBOA", "PORTUGAL",
                    "N.º Contribuinte 503504564", "Demo Seguros SA", "Total 10,00"].joined(separator: "\n")
        XCTAssertEqual(IssuerKey.derive(text: text, fileName: "a.pdf", ownNIFs: parties)?.key, "line:DEMO SEGUROS SA",
                       "the client's number under the address is not the issuer's")
        // A greeting with no known name: the address under it is still the addressee's.
        let unnamed = ["Dear Sir/Madam", "Flat 2", "1 Demo Road", "Demo Energy Ltd"].joined(separator: "\n")
        XCTAssertEqual(IssuerKey.derive(text: unnamed, fileName: "a.pdf", ownNIFs: [])?.key, "line:DEMO ENERGY LTD")
    }

    func testCodesAndFieldLabelsAreNotNames() {
        for line in ["IT#ENC:A(BEVI", "ABCD(EFGH", "Apólice Grupo / Contrato", "Período do Recibo 01-01-2026", "Assunto: Seguro"] {
            XCTAssertNil(IssuerKey.derive(text: line + "\n10,00", fileName: "a.pdf", ownNIFs: []), line)
        }
        XCTAssertEqual(IssuerKey.derive(text: "Demo (Portugal) Lda", fileName: "a.pdf", ownNIFs: [])?.key, "line:DEMO (PORTUGAL) LDA")
    }

    func testANIFBesideALoanOrAccountNumberIsTheClients() {
        let text = "Demo Notice\nNIF: 503504564\nEmpréstimo: 000111222333\nDemo Power Lda NIPC 500000000"
        XCTAssertEqual(IssuerKey.derive(text: text, fileName: "a.pdf", ownNIFs: [])?.key, "nif:500000000")
    }

    func testABankLettersIssuerIsTheCreditorItNamesElseNone() {
        XCTAssertTrue(IssuerKey.isBankLetter(Self.bareDebitAdvice.joined(separator: "\n")))
        XCTAssertNil(IssuerKey.derive(text: Self.bareDebitAdvice.joined(separator: "\n"), fileName: "a.pdf", ownNIFs: []),
                     "a debit advice naming no creditor has no issuer: not the greeting, the bank's number or the client's")
        let sepa = BBVADebitAdviceTests.sepaOrderLines(creditor: "DEMO SEGUROS SA").joined(separator: "\n")
        let key = IssuerKey.derive(text: sepa, fileName: "a.pdf", ownNIFs: [])
        XCTAssertEqual(key?.key, "creditor:DEMO SEGUROS SA")
        XCTAssertEqual(key?.label, "Demo Seguros Sa")
        // A creditor that is only a code, or the bank itself: none.
        XCTAssertNil(IssuerKey.derive(text: BBVADebitAdviceTests.sepaOrderLines(creditor: "XY 12").joined(separator: "\n"), fileName: "a.pdf", ownNIFs: []))
        XCTAssertNil(IssuerKey.derive(text: BBVADebitAdviceTests.sepaOrderLines(creditor: "BANCO DEMO SA").joined(separator: "\n"), fileName: "a.pdf", ownNIFs: []))
        // A bank's notice (its letterhead, no movement wording): none either.
        let notice = ["Assunto: Seguro associado ao seu crédito", "NIF: 503504564", "Exmo(a). Senhor(a),",
                      "Informamos que o Banco Bilbao Vizcaya Argentaria, S.A. – Sucursal em Portugal (BBVA) procedeu ao pagamento."]
        XCTAssertNil(IssuerKey.derive(text: notice.joined(separator: "\n"), fileName: "a.pdf", ownNIFs: []))
        // A receipt naming the bank as where it is paid is not the bank's letter.
        let receipt = ["Demo Seguros SA", "NIPC 500000000", "LOCAL DE COBRANÇA", "BANCO BILBAO VIZCAYA ARGE (PORTUGAL), SA", "Total 10,00"]
        XCTAssertFalse(IssuerKey.isBankLetter(receipt.joined(separator: "\n")))
        XCTAssertEqual(IssuerKey.derive(text: receipt.joined(separator: "\n"), fileName: "a.pdf", ownNIFs: [])?.key, "nif:500000000")
    }

    func testABanksLetterheadIsNotASpecificIssuer() {
        XCTAssertTrue(IssuerKey.isBankLetterhead(IssuerKey(key: "nif:500000000", label: "Banco Bilbao Vizcaya Argentaria S.A. - S")))
        XCTAssertTrue(IssuerKey.isBankLetterhead(IssuerKey(key: "line:DEMO BANK PLC", label: "Demo Bank Plc")))
        XCTAssertTrue(IssuerKey.isBankLetterhead(IssuerKey(key: "line:BBVA", label: "Bbva")))
        XCTAssertFalse(IssuerKey.isBankLetterhead(IssuerKey(key: "nif:500000000", label: "BBVA Seguros")), "an insurer of the bank's group")
        XCTAssertFalse(IssuerKey.isBankLetterhead(IssuerKey(key: "nif:503504564", label: "Demo Power")))
        XCTAssertFalse(IssuerKey.isBankLetterhead(IssuerKey(key: "creditor:DEMO SEGUROS SA", label: "Demo Seguros Sa")))
    }

    func testABanksLetterheadInAReceiptsBodyIsNotTheBanksLetter() {
        let letterhead = "Banco Bilbao Vizcaya Argentaria S.A. - Sucursal em Portugal - Avenida Exemplo, 1, 1000-000 Lisboa"
        // An insurer's receipt that names the bank as its mediator in the body.
        let receipt = ["Demo Seguros SA", "NIPC 500000000", "Recibo 123", "Prémio 10,00", "Mediador:", letterhead,
                       "Período 01-01-2026 a 31-12-2026", "Objeto seguro", "Ramo Casa", "Total 10,00", "Processado por programa certificado"]
        XCTAssertFalse(IssuerKey.isBankLetter(receipt.joined(separator: "\n")))
        XCTAssertEqual(IssuerKey.derive(text: receipt.joined(separator: "\n"), fileName: "a.pdf", ownNIFs: [])?.key, "nif:500000000")
        // The bank's own letter: its letterhead heads or closes it, or stands beside its greeting.
        XCTAssertTrue(IssuerKey.isBankLetter(([letterhead] + receipt.dropFirst(2)).joined(separator: "\n")))
        XCTAssertTrue(IssuerKey.isBankLetter((receipt.dropFirst(2) + [letterhead]).joined(separator: "\n")))
        let notice = ["Assunto: Seguro", "NIF: 503504564", "Exmo(a). Senhor(a),", "Linha 1", "Linha 2", "Linha 3",
                      "O " + letterhead + " informa.", "Linha 4", "Linha 5", "Linha 6", "Linha 7", "Linha 8"]
        XCTAssertTrue(IssuerKey.isBankLetter(notice.joined(separator: "\n")))
    }

    func testACompanyLineUnderTheAddresseeIsNoAddress() {
        let parties: Set<String> = ["name:ANA DEMO"]
        for company in ["DEMO SEGUROS", "DEMO, S.A.", "DEMO (PORTUGAL) LDA", "SEGURADORA"] {
            let text = ["ANA DEMO", "1 DEMO ROAD", company, "Total 10,00"].joined(separator: "\n")
            XCTAssertNotNil(IssuerKey.derive(text: text, fileName: "a.pdf", ownNIFs: parties), company)
        }
        XCTAssertNil(IssuerKey.derive(text: "ANA DEMO\n1 DEMO ROAD\nLISBOA\nPORTUGAL\nTotal 10,00", fileName: "a.pdf", ownNIFs: parties))
    }
}
