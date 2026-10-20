import Foundation
import GRDB
import BudgetCore

/// Six synthetic files for the document importer, made from the demo database when it is built
/// (`MakeDemoDatabase` writes them to `ImportSamples` beside it) for the Imports snapshot routes
/// and for trying the importer by hand. Read by the real pipeline over the demo, they fill each
/// section of the review:
/// - Ready: the PDF of Tenancy 2's latest receipt (contract CT-0002), linked to its credit;
///   an insurance receipt of the latest condomínio debit without a document (its day and
///   amount), linked to it.
/// - Duplicates skipped: a copy of the library's energy certificate (the same file); an
///   Example utility invoice re-issued later under a recorded invoice's number (the same document).
/// - Needs you: Person A's corrected P60 2024/25, pay £1,000 above the stored figure (possibly
///   a corrected version; the filed 2024/25 return holds it); `Letter.pdf`, with no wording any
///   reader knows.
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

    /// Writes the six samples into `folder` (replacing an earlier set there; refusing a folder
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
            [try rentReceipt(db), try insuranceReceipt(db), copyOfLibraryDocument(), try reissuedInvoice(db), try p60(db), letter()]
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
        let dbQueue = try DatabaseQueue(path: databasePath, configuration: configuration)
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
