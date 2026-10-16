import XCTest
@testable import BudgetCore

final class EvidenceTextParsingTests: XCTestCase {
    private func day(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: string)!
    }

    func testDateFormats() {
        let table: [(String, String?)] = [
            ("Data de pagamento: 07/03/2025", "2025-03-07"),
            ("Emitido a 07-03-2025", "2025-03-07"),
            ("de 2022.11.28.", "2022-11-28"),
            ("DATA: 2024-01-16", "2024-01-16"),
            ("Documento gerado em: 2020/11/12 11:14", "2020-11-12"),
            ("Lisboa, 12 de outubro de 2025", "2025-10-12"),
            ("Documento emitido a: 14 de novembro 2022", "2022-11-14"),
            ("Data: 3 de março de 2024", "2024-03-03"),
            ("Débito a partir de 6 dez 2022", "2022-12-06"),
            ("Tax Year to 5 April 2025", "2025-04-05"),
            ("Date 7 December 2021", "2021-12-07"),
            ("InvoiceDate 4Dec2024", "2024-12-04"),
            ("Due 1 Sept 2024", "2024-09-01"),
            ("31/02/2025", nil),
            ("2024-13-01", nil),
            ("Ref 20240116123456", nil),
            ("1 de 314112022", nil),
            ("12 de setembro", nil)
        ]
        for (text, expected) in table {
            XCTAssertEqual(EvidenceDateParser.firstDate(in: text), expected.map(day), text)
        }
    }

    func testDatesInOrder() {
        let dates = EvidenceDateParser.dates(in: "Período 2016-05-18 / 2016-06-18, pago a 27 de maio de 2016").map(\.date)
        XCTAssertEqual(dates, [day("2016-05-18"), day("2016-06-18"), day("2016-05-27")])
    }

    func testFileNameDates() {
        XCTAssertEqual(EvidenceDateParser.fileNameDate("20240116 - Prestacao.pdf"), day("2024-01-16"))
        XCTAssertEqual(EvidenceDateParser.fileNameDate("BBVAmobilept-ContaOrdem-Transferencia-00000000000020250613130812.pdf"), day("2025-06-13"))
        XCTAssertEqual(EvidenceDateParser.fileNameDate("Fatura_Recibo_0001234567_20231014.pdf"), day("2023-10-14"))
        XCTAssertNil(EvidenceDateParser.fileNameDate("Factura Luz.pdf"))
    }

    func testAmountFormats() {
        let table: [(String, Int?, Currency?)] = [
            ("1.234,56 €", 123_456, .eur),
            ("€25,00", 2_500, .eur),
            ("MONTANTE PAGO : 250,00 EUROS", 25_000, .eur),
            ("EUR 180,00", 18_000, .eur),
            ("Montante: 300,00 EUR", 30_000, .eur),
            ("Amount £2,000.00", 200_000, .gbp),
            ("Pay £125,000.00", 12_500_000, .gbp),
            ("TOTALGBP 640.00", 64_000, .gbp),
            ("640.00 GBP", 64_000, .gbp),
            ("TOTAL EUR: 1.234,56", 123_456, nil),
            ("350.000,00", 35_000_000, nil),
            ("0,50", 50, nil),
            ("TAN 4,935", nil, nil),
            ("1.234.56", nil, nil),
            ("NIF 987654321", nil, nil),
            ("2024-01-16", nil, nil),
            ("Capital Social 182 000 000 €", nil, nil),
            ("12,34.5", nil, nil),
            ("1.234,56.7", nil, nil),
            ("VALOR SEGURO 30 000,00 €", 3_000_000, .eur),
            ("TOTAL 2 400,00 EUR", 240_000, .eur),
            ("€ 1 200,00", 120_000, .eur),
            ("12 148,00", 14_800, nil)
        ]
        for (text, minor, currency) in table {
            let found = EvidenceAmountParser.amount(text)
            XCTAssertEqual(found?.minorUnits, minor, text)
            XCTAssertEqual(found?.currency, currency, text)
        }
    }

    func testAmountsInOrder() {
        let amounts = EvidenceAmountParser.amounts(in: "Prémio comercial 50,00 € Imposto 4,50 € Total: 60,00 €").map(\.minorUnits)
        XCTAssertEqual(amounts, [5_000, 450, 6_000])
    }

    func testNormalizedText() {
        XCTAssertEqual(EvidenceText.normalized("Aviso  Débito\nPrestação"), "AVISO DEBITO PRESTACAO")
        XCTAssertEqual(EvidenceText.fold("Condomínio"), "Condominio")
    }
}
