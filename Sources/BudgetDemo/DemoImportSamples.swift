import Foundation
import GRDB
import BudgetCore

/// Fifteen synthetic files for the document importer, made from the demo database when it is built
/// (`MakeDemoDatabase` writes them to `ImportSamples` beside it) for the Imports snapshot routes
/// and for trying the importer by hand. Read by the real pipeline over the demo, they fill each
/// section of the review:
/// - Ready: the PDF of Tenancy 2's latest receipt (contract CT-0002), linked to its credit;
///   an insurance receipt of the latest condomínio debit without a document (its day and
///   amount), linked to it; a BBVA-format "extrato global" of Euro Current for the month after
///   its history (one mortgage instalment with its receipt, no fund), its balances matching;
///   Example Water's next invoice (a new number, the month after its latest), not paid yet.
/// - Duplicates skipped: a copy of the library's energy certificate (the same file); an
///   Example utility invoice re-issued later under a recorded invoice's number (the same document).
/// - Needs you: Person A's corrected P60 2024/25, pay £1,000 above the stored figure (possibly
///   a corrected version; the filed 2024/25 return holds it); `Letter.pdf`, with no wording any
///   reader knows; a UK bank CSV no account's saved profile reads (its account to choose, then
///   its columns to map).
/// - Import kinds (the last six): a repair bill, its receipt and the bank's debit advice, all of one
///   debit (Ready together, no duplicate alert); a stamp duty note linked to its debit; an invoice
///   paid in two instalments (asked: keep both links or none); `Fogo Limpo note.pdf`, a letter no
///   reader knows, to leave out and set aside.
/// Every name, number and figure is invented (the demo's own).
public enum DemoImportSamples {
    /// The file a samples folder holds, so it is only ever replaced by the demo.
    public static let markerFileName = ".budget-demo-import-samples"

    public enum SampleError: Error, LocalizedError {
        case missing(String)
        case notSamplesFolder(String)

        public var errorDescription: String? {
            switch self {
            case .missing(let what): return "The demo database has no \(what) to make an import sample from"
            case .notSamplesFolder(let path): return "\(path) holds files that aren't the demo's import samples: not replacing them"
            }
        }
    }

    /// Writes the fifteen samples into `folder` (replacing an earlier set there; refusing a folder
    /// that holds anything else), in the order above; returns their URLs.
    @discardableResult
    public static func write(into folder: URL, dbQueue: DatabaseQueue) throws -> [URL] {
        let manager = FileManager.default
        if manager.fileExists(atPath: folder.path) {
            let contents = try manager.contentsOfDirectory(atPath: folder.path)
            if !contents.isEmpty {
                guard contents.contains(markerFileName) else { throw SampleError.notSamplesFolder(folder.path) }
                for name in contents { try manager.removeItem(at: folder.appendingPathComponent(name)) }
            }
        }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Synthetic demo import samples (MakeDemoDatabase).\n".utf8).write(to: folder.appendingPathComponent(markerFileName))

        let samples = try dbQueue.read { db in
            [try rentReceipt(db), try insuranceReceipt(db), copyOfLibraryDocument(), try reissuedInvoice(db), try p60(db), letter(),
             try bbvaStatement(db), try ukStatementCSV(db), try nextInvoice(db),
             try repairBill(db), try repairReceipt(db), try repairDebitAdvice(db), try stampDutyNote(db), try instalmentInvoice(db), unknownNote()]
        }
        var urls: [URL] = []
        for (name, data) in samples {
            let url = folder.appendingPathComponent(name)
            try data.write(to: url)
            urls.append(url)
        }
        // The copy must be the library's file, byte for byte.
        let copyHash = try EvidenceLibrary.sha256(of: urls[2])
        guard try dbQueue.read({ db in try EvidenceDocument.filter(Column("sha256") == copyHash).fetchCount(db) }) == 1 else {
            throw SampleError.missing("\(DemoDatabase.energyCertificate.fileName) in the library")
        }
        return urls
    }

    /// `write(into:dbQueue:)` from the demo database at `databasePath` (opened read only).
    @discardableResult
    public static func write(into folder: URL, databasePath: String) throws -> [URL] {
        var configuration = Configuration()
        configuration.readonly = true
        let dbQueue = try ToolDatabase.open(path: databasePath, configuration: configuration)
        defer { try? dbQueue.close() }
        return try write(into: folder, dbQueue: dbQueue)
    }

    private typealias Sample = (name: String, data: Data)

    private static func money(_ minorUnits: Int, _ currency: Currency = .eur) -> String { Money.format(minorUnits, currency: currency) }

    private static func day(_ date: Date) -> String { DemoDatabase.short(date) }

    // MARK: Ready

    /// Tenancy 2's latest receipt (no PDF in the demo yet), as the demo's receipts look.
    private static func rentReceipt(_ db: Database) throws -> Sample {
        guard let tenancy = try Tenancy.filter(Column("referenceLabel") == "Tenancy 2").fetchOne(db), let tenancyId = tenancy.id,
              let receipt = try RentReceipt.filter(Column("tenancyId") == tenancyId).order(Column("periodStart").desc).fetchOne(db) else {
            throw SampleError.missing("receipt of Tenancy 2")
        }
        let page = DemoDatabase.page(issuer: "Tax Authority portal", title: "Rent receipt \(receipt.receiptNumber)", lines: [
            ("Document", "Recibo de renda eletrónico"),
            ("Contract", tenancy.contractNumber ?? "CT-0002"),
            ("Tenant", tenancy.tenantName ?? "Tenant Two"),
            ("Period", "\(day(receipt.periodStart)) – \(day(receipt.periodEnd))"),
            ("Received", receipt.receiptDate.map(day) ?? day(receipt.periodStart)),
            ("Rent", money(receipt.amountMinorUnits))
        ])
        return ("Rent receipt \(receipt.receiptNumber).pdf", DemoPDF.data(page))
    }

    /// An insurance receipt of the latest condomínio debit on Euro Current that has no document
    /// (the building's insurance share, paid with the quota): its day and amount.
    private static func insuranceReceipt(_ db: Database) throws -> Sample {
        guard let debit = try Transaction.fetchOne(db, sql: """
            SELECT t.* FROM \(Transaction.databaseTableName) t
            JOIN \(Account.databaseTableName) a ON a.id = t.accountId JOIN \(Category.databaseTableName) c ON c.id = t.categoryId
            WHERE a.name = 'Euro Current' AND c.name = 'Condomínio' AND t.amountMinorUnits < 0
              AND NOT EXISTS (SELECT 1 FROM \(DocumentLink.databaseTableName) l WHERE l.entityType = ? AND l.entityId = t.id)
            ORDER BY t.date DESC, t.id DESC LIMIT 1
            """, arguments: [EvidenceEntityType.transaction.rawValue]) else {
            throw SampleError.missing("condomínio debit without a document")
        }
        let page = DemoDatabase.page(issuer: "Seguros Exemplo", title: "Insurance receipt — building policy", lines: [
            ("Policy", "BP-000456"),
            ("Cover", "Seguro multirriscos (building)"),
            ("Date", day(debit.date)),
            ("Premium paid", money(abs(debit.amountMinorUnits)))
        ])
        let (year, month) = MonthRange.components(of: debit.date)
        let name = String(format: "Insurance receipt %04d-%02d-%02d.pdf", year, month, DemoDatabase.calendar.component(.day, from: debit.date))
        return (name, DemoPDF.data(page))
    }

    // MARK: Duplicates

    /// The library's energy certificate, byte for byte (demo PDFs are deterministic).
    private static func copyOfLibraryDocument() -> Sample {
        let certificate = DemoDatabase.energyCertificate
        return ("Energy certificate (copy).pdf",
                DemoPDF.data(DemoDatabase.page(issuer: certificate.issuer, title: certificate.title, lines: certificate.lines)))
    }

    /// The latest recorded invoice with a document, issued again a month later under its number.
    private static func reissuedInvoice(_ db: Database) throws -> Sample {
        guard let invoice = try UtilityInvoice.filter(Column("documentId") != nil && Column("invoiceNumber") != nil)
                .order(Column("issueDate").desc, Column("id").desc).fetchOne(db),
              let provider = try UtilityProvider.fetchOne(db, key: invoice.providerId),
              let number = invoice.invoiceNumber else {
            throw SampleError.missing("utility invoice with a document")
        }
        let reissued = DemoDatabase.calendar.date(byAdding: .month, value: 1, to: invoice.issueDate) ?? invoice.issueDate
        let page = DemoDatabase.page(issuer: provider.name, title: "Invoice \(number)", lines: [
            ("Account", provider.accountReference ?? ""),
            ("Issued", day(reissued)),
            ("Period", [invoice.periodStart, invoice.periodEnd].compactMap { $0.map(day) }.joined(separator: " – ")),
            ("Amount due", money(invoice.amountMinorUnits)),
            ("Copy", "Re-issued at the customer's request")
        ])
        return ("\(provider.name) invoice \(number) reissued.pdf", DemoPDF.data(page))
    }

    /// Example Water's next invoice: the month after its latest recorded one (same amount, the
    /// next number), issued after every debit, so it is recorded with no debit to link yet.
    private static func nextInvoice(_ db: Database) throws -> Sample {
        guard let provider = try UtilityProvider.filter(Column("name") == "Example Water").fetchOne(db), let providerId = provider.id,
              let latest = try UtilityInvoice.filter(Column("providerId") == providerId)
                .order(Column("issueDate").desc, Column("id").desc).fetchOne(db),
              let start = latest.periodStart, let end = latest.periodEnd else {
            throw SampleError.missing("Example Water invoice")
        }
        let calendar = DemoDatabase.calendar
        func next(_ date: Date) -> Date { calendar.date(byAdding: .month, value: 1, to: date) ?? date }
        let year = MonthRange.components(of: next(latest.issueDate)).year
        let number = "\(provider.accountReference?.prefix(2) ?? "EW")-\(year)-0901"
        let page = DemoDatabase.page(issuer: provider.name, title: "Invoice \(number)", lines: [
            ("Account", provider.accountReference ?? ""),
            ("Issued", day(next(latest.issueDate))),
            // From the day after the latest invoice's period.
            ("Period", "\(day(calendar.date(byAdding: .day, value: 1, to: end) ?? start)) – \(day(next(end)))"),
            ("Amount due", money(latest.amountMinorUnits)),
            ("Direct debit", "On the 20th")
        ])
        return ("\(provider.name) invoice \(number).pdf", DemoPDF.data(page))
    }

    // MARK: Import kinds

    /// The sample repair debit (`DemoDatabase.Builder.sampleRepairDebit`) as stored.
    private static func debit(_ db: Database, _ description: String, _ date: Date? = nil) throws -> Transaction {
        var request = Transaction.filter(Column("rawDescription") == description)
        if let date { request = request.filter(Column("date") == date) }
        guard let found = try request.order(Column("date")).fetchOne(db) else { throw SampleError.missing("debit \(description)") }
        return found
    }

    /// `1.234,56` as a Portuguese bill writes an amount.
    private static func pt(_ minorUnits: Int) -> String { String(format: "%d,%02d", abs(minorUnits) / 100, abs(minorUnits) % 100) }

    private static func slashDate(_ date: Date) -> String {
        let (year, month) = MonthRange.components(of: date)
        return String(format: "%02d/%02d/%04d", DemoDatabase.calendar.component(.day, from: date), month, year)
    }

    private static let plumber = "Exemplo Serviços Lda"

    /// The plumber's fatura-recibo for the sample repair debit.
    private static func repairBill(_ db: Database) throws -> Sample {
        let sample = try debit(db, DemoDatabase.Builder.sampleRepairDebit.description)
        let page = DemoDatabase.page(issuer: plumber, title: "Fatura-recibo FR 2026/31", lines: [
            ("NIF", "503504564"),
            ("Data", slashDate(sample.date)),
            ("Reparação", "Substituição de torneira e sifão"),
            ("Total", "\(pt(sample.amountMinorUnits)) EUR")
        ])
        return ("Exemplo Serviços FR 2026-31.pdf", DemoPDF.data(page))
    }

    /// The same plumber's receipt for that payment.
    private static func repairReceipt(_ db: Database) throws -> Sample {
        let sample = try debit(db, DemoDatabase.Builder.sampleRepairDebit.description)
        let page = DemoDatabase.page(issuer: plumber, title: "Recibo RC 2026/22", lines: [
            ("NIF", "503504564"),
            ("Data", slashDate(sample.date)),
            ("Recebemos", "\(pt(sample.amountMinorUnits)) EUR"),
            ("Referente a", "Fatura FR 2026/31"),
            ("Pago por", "Transferência bancária")
        ])
        return ("Exemplo Serviços RC 2026-22.pdf", DemoPDF.data(page))
    }

    /// The bank's advice of that debit, laid out as BBVA prints a services payment.
    private static func repairDebitAdvice(_ db: Database) throws -> Sample {
        let sample = try debit(db, DemoDatabase.Builder.sampleRepairDebit.description)
        let (year, month) = MonthRange.components(of: sample.date)
        let lines = ["Exmo(a). Senhor(a)", String(format: "DATA: %04d-%02d-%02d", year, month, DemoDatabase.calendar.component(.day, from: sample.date)),
                     "PAGAMENTOS - SERVIÇOS/COMPRAS", "CLIENT ALPHA", "CONTA N : 000",
                     "QUEIRA(M) NOTAR QUE, NESTA DATA, DEBITÁMOS NA CONTA DE V.EXA(S) O(S) SEGUINTE(S) MOVIMENTO(S):",
                     "ENTIDADE: 21000", "REFERÊNCIA: 123 456 789", "DESCRITIVO: \(sample.rawDescription)",
                     "MONTANTE:", pt(sample.amountMinorUnits), "COMISSÃO: 0,00", "EUR", "BBVA"]
        typealias P = DemoPDF.Placed
        let placed = lines.enumerated().map { index, line in P(line, 20, 800 - Double(index) * 16, size: 9, bold: index == 2) }
        return (String(format: "BBVA aviso de débito %04d-%02d-%02d.pdf", year, month, DemoDatabase.calendar.component(.day, from: sample.date)),
                DemoPDF.data(placed: placed))
    }

    /// A tax authority's nota de cobrança of stamp duty, for the sample stamp duty debit.
    private static func stampDutyNote(_ db: Database) throws -> Sample {
        let sample = try debit(db, DemoDatabase.Builder.sampleStampDutyDebit.description)
        let page = DemoDatabase.page(issuer: "Autoridade Tributária (demo)", title: "Nota de cobrança", lines: [
            ("Tributo", "Imposto do Selo"),
            ("Data", slashDate(sample.date)),
            ("Referência", "000 111 222 333"),
            ("Valor a pagar", "\(pt(sample.amountMinorUnits)) EUR")
        ])
        return ("Nota de cobrança Imposto do Selo.pdf", DemoPDF.data(page))
    }

    /// An invoice for the two sample instalment debits together.
    private static func instalmentInvoice(_ db: Database) throws -> Sample {
        let pair = DemoDatabase.Builder.sampleInstalmentDebits
        let first = try debit(db, pair.description, pair.first)
        let total = pair.each * 2
        let page = DemoDatabase.page(issuer: "Carpintaria Exemplo Lda", title: "Fatura FT 2026/57", lines: [
            ("NIF", "503504564"),
            ("Data", slashDate(first.date)),
            ("Trabalhos", "Reparação de portas e janelas"),
            ("Total", "\(pt(total)) EUR"),
            ("Pagamento", "Em duas prestações")
        ])
        return ("Carpintaria Exemplo FT 2026-57.pdf", DemoPDF.data(page))
    }

    /// A note none of the readers knows, to leave out and set aside.
    private static func unknownNote() -> Sample {
        let page = DemoDatabase.page(issuer: "Fogo Limpo Lda", title: "A note about the chimney", lines: [
            ("Subject", "Sweep and inspection"),
            ("Message", "We can visit in the spring."),
            ("From", "The office")
        ])
        return ("Fogo Limpo note.pdf", DemoPDF.data(page))
    }

    // MARK: Needs you

    /// Person A's P60 2024/25 from the stored employer with pay £1,000 above the stored figure
    /// (a corrected P60, not a copy), in a payroll provider's layout.
    private static func p60(_ db: Database) throws -> Sample {
        let startYear = 2024
        guard let person = try Person.filter(Column("name") == DemoDatabase.personA).fetchOne(db), let personId = person.id,
              let employment = try Employment.filter(Column("personId") == personId && Column("startYear") == startYear).fetchOne(db),
              let employmentId = employment.id,
              let income = try EmploymentIncome.filter(Column("employmentId") == employmentId).fetchOne(db) else {
            throw SampleError.missing("P60 figures of \(DemoDatabase.personA) for 2024/25")
        }
        func pounds(_ minorUnits: Int) -> String { String(format: "%d.%02d", minorUnits / 100, minorUnits % 100) }
        let pay = pounds(income.payMinorUnits + 100_000), tax = pounds(income.taxDeductedMinorUnits)
        let employer = employment.employerName
        let reference = (employment.payeReference ?? "").replacingOccurrences(of: "/", with: " / ")
        typealias P = DemoPDF.Placed
        let items: [P] = [
            P("P60 End of Year Certificate", 20, 810, size: 12, bold: true),
            P("Tax year to 5 April", 20, 790), P("\(startYear + 1)", 120, 790),
            P("Employee's Details", 220, 790),
            P("National Insurance number", 220, 760), P(person.ukNino ?? "", 220, 745),
            P("Pay and Income Tax details", 220, 700),
            P("Pay", 380, 680), P("Tax deducted", 470, 680),
            P("In previous", 220, 660), P("employment(s)", 220, 650), P("0.00", 395, 655), P("0.00", 495, 655),
            P("In this", 220, 625), P("employment", 220, 615), P(pay, 380, 620), P(tax, 480, 620),
            P("Total for year", 220, 590), P(pay, 380, 590), P(tax, 480, 590),
            P("Final tax code", 360, 560), P(income.taxCode ?? "1257L", 450, 560),
            P("Your employer's full name and address", 300, 300),
            P(employer, 300, 285), P("1 Example Street", 300, 273), P("London", 300, 261),
            P("Employer PAYE reference", 20, 240), P(reference, 20, 225)
        ]
        return ("P60 \(startYear)-\(String((startYear + 1) % 100)) \(employment.employerName).pdf", DemoPDF.data(placed: items))
    }

    /// A UK bank's CSV export for the month after the demo's history, with no account details:
    /// no account's saved profile reads it (the demo has none).
    private static func ukStatementCSV(_ db: Database) throws -> Sample {
        let (year, month) = try nextMonth(db, account: "Everyday Current")
        func on(_ day: Int) -> String { String(format: "%02d/%02d/%04d", day, month, year) }
        let rows = [
            "Date,Description,Amount,Balance",
            "\(on(3)),GREENLEAF MARKET,-42.18,2357.82",
            "\(on(5)),CITY TRANSIT,-2.85,2354.97",
            "\(on(9)),BEAN THERE COFFEE,-3.60,2351.37",
            "\(on(14)),STREAMFLIX,-10.99,2340.38",
            "\(on(25)),SALARY EXAMPLE EMPLOYER,3125.00,5465.38"
        ]
        return ("Demo Bank export \(String(format: "%04d-%02d", year, month)).csv", Data((rows.joined(separator: "\n") + "\n").utf8))
    }

    /// The month after `account`'s last transaction, as (year, month).
    private static func nextMonth(_ db: Database, account name: String) throws -> (Int, Int) {
        guard let account = try Account.filter(Column("name") == name).fetchOne(db), let accountId = account.id,
              let last = try Transaction.filter(Column("accountId") == accountId).order(Column("date").desc).fetchOne(db) else {
            throw SampleError.missing("transaction on \(name)")
        }
        let (year, month) = MonthRange.components(of: last.date)
        return month == 12 ? (year + 1, 1) : (year, month + 1)
    }

    /// A BBVA Portugal "extrato global" of Euro Current for the month after its history, laid out
    /// as BBVA prints it: the mortgage instalment on the 2nd (the demo's instalment and interest,
    /// the Property Mortgage's capital owed after it), a shop payment and the maintenance fee; no
    /// savings product. Its opening is Euro Current's balance then, so its closing matches.
    private static func bbvaStatement(_ db: Database) throws -> Sample {
        guard let current = try Account.filter(Column("name") == "Euro Current").fetchOne(db), let currentId = current.id,
              let loan = try Account.filter(Column("name") == "Property Mortgage").fetchOne(db), let loanId = loan.id,
              let instalment = try Transaction.filter(Column("accountId") == currentId && Column("rawDescription") == "LOAN INSTALMENT")
                .order(Column("date").desc).fetchOne(db),
              let interest = try Transaction.filter(Column("accountId") == loanId && Column("rawDescription") == "LOAN INTEREST")
                .order(Column("date").desc).fetchOne(db) else {
            throw SampleError.missing("mortgage instalment on Euro Current")
        }
        let (year, month) = try nextMonth(db, account: "Euro Current")
        let calendar = DemoDatabase.calendar
        let start = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
        let days = calendar.range(of: .day, in: .month, for: start)!.count
        let receiptDay = calendar.date(from: DateComponents(year: year, month: month, day: 2))!
        func balance(_ accountId: Int64, before day: Date) throws -> Int {
            NetWorthCalculator.balance(accountId: accountId, at: day.addingTimeInterval(-1),
                                       snapshots: try BalanceSnapshot.filter(Column("accountId") == accountId).fetchAll(db),
                                       transactions: try Transaction.filter(Column("accountId") == accountId).fetchAll(db))?.native ?? 0
        }
        let opening = try balance(currentId, before: start)
        let total = -instalment.amountMinorUnits, charges = -interest.amountMinorUnits, capital = total - charges
        let owedAfter = -(try balance(loanId, before: receiptDay)) - capital

        func pt(_ cents: Int) -> String {
            let whole = abs(cents) / 100, fraction = abs(cents) % 100
            var digits = String(whole), grouped = ""
            while digits.count > 3 {
                grouped = "." + digits.suffix(3) + grouped
                digits = String(digits.dropLast(3))
            }
            return (cents < 0 ? "-" : "") + digits + grouped + "," + String(format: "%02d", fraction)
        }
        func md(_ day: Int) -> String { String(format: "%02d/%02d", month, day) }
        func iso(_ day: Int, monthOffset: Int = 0) -> String {
            let date = calendar.date(byAdding: .month, value: monthOffset, to: calendar.date(from: DateComponents(year: year, month: month, day: day))!)!
            let (y, m) = MonthRange.components(of: date)
            return String(format: "%04d-%02d-%02d", y, m, calendar.component(.day, from: date))
        }
        var running = opening
        func movement(_ day: Int, _ description: String, _ amount: Int) -> String {
            running += amount
            return "\(md(day)) \(md(day)) \(description) \(pt(amount)) \(pt(running))"
        }
        let period = String(format: "%04d/%02d/01 A %04d/%02d/%02d", year, month, year, month, days)
        let label = String(format: "%04d/%02d", year, month)
        var lines = [
            "EXTRATO GLOBAL",
            "PERÍODO DE \(period)",
            "ACTIVO",
            "PASSIVO",
            "EMPRÉSTIMOS \(pt(owedAfter))",
            "Pág. 1/1 Extrato \(label)",
            // The account core Euro Current's (synthetic) IBAN holds.
            "Conta Nº: 000/000000000   EUR   CONTA BBVA",
            "Saldo inicial \(pt(opening))",
            movement(2, "COBR. REC. TOT 000 00-000000-0", -total),
            movement(12, "PAGAMENTO LOJA EXEMPLO", -2_340),
            movement(days - 2, "COMISSAO MANUTENCAO CONTA", -416)
        ]
        lines.insert("DEPÓSITOS À ORDEM \(pt(running))", at: 3)
        lines += [
            "Saldo final \(pt(running))",
            "Saldo disponivel \(pt(running))",
            "Conta Nº: 000/333333333 EUR HOME LOAN",
            "Capital em Dívida \(pt(owedAfter))",
            "COBRANÇAS EFECTUADAS",
            "Nº. Recibo: 37/360 Data Inicio Liquidação: \(iso(2, monthOffset: -1)) Total recibo: \(pt(total))",
            "Data Valor: \(iso(2)) Data Fim Liquidação: \(iso(2))",
            "Data Oper. Capital Juros Comissões Juros de Mora Impostos Total EUR Total em atraso Capital em dívida",
            "\(iso(2)) \(pt(capital)) \(pt(charges)) 0,00 0,00 0,00 \(pt(total)) 0,00 \(pt(owedAfter))"
        ]
        typealias P = DemoPDF.Placed
        let placed = lines.enumerated().map { index, line in P(line, 20, 800 - Double(index) * 16, size: 8, bold: index == 0) }
        return (String(format: "BBVA extrato %04d-%02d.pdf", year, month), DemoPDF.data(placed: placed))
    }

    /// A letter none of the readers knows.
    private static func letter() -> Sample {
        let page = DemoDatabase.page(issuer: "Residents' Association", title: "A note to neighbours", lines: [
            ("Subject", "Stairwell lights"),
            ("Message", "The lights will be looked at next week."),
            ("From", "The committee")
        ])
        return ("Letter.pdf", DemoPDF.data(page))
    }
}
