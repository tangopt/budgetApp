// App/Snapshots/ImportReviewDemo.swift
#if SNAPSHOTS
import Foundation
import BudgetCore
import GRDB

/// An invented review for the Imports routes (`imports-review_link`, `_kind`, `_statement`, `_figures`, `_left_out_rows`):
/// every section filled — a utility invoice with two possible debits, a P60 held by a filed
/// return, an unknown scan, a statement with unread lines and rows already imported, ready rent
/// receipts and an insurance receipt, a duplicate and a file left out. Nothing is read or saved;
/// every file shows the demo library's first rent receipt (for the thumbnail) under an invented name.
@MainActor
enum ImportReviewDemo {
    struct Demo {
        let plan: ImportPlan
        let invoiceId: UUID
        let heldId: UUID
        let scanId: UUID
        let statementId: UUID
        let figuresId: UUID
    }

    static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    static func make(_ context: SnapshotContext) -> Demo {
        let pdf: URL = (try? context.dbQueue.read { db in
            try EvidenceDocument.filter(Column("kind") == DocumentKind.rentReceipt.rawValue).order(Column("id")).fetchOne(db)
        }).flatMap { $0 }.map { context.library.fileURL(for: $0) } ?? URL(fileURLWithPath: "/nonexistent/receipt.pdf")

        func file(_ name: String, url: URL? = nil, ocr: Bool = false) -> ImportFile {
            ImportFile(url: url ?? pdf, fileName: name, sha256: UUID().uuidString, byteCount: 1,
                       fileExtension: (name as NSString).pathExtension.lowercased(), text: nil, textStatus: .text, usedOCR: ocr)
        }
        func fact(_ field: ImportFigureField, _ value: ImportFactValue, _ source: ImportFactSource = .textLayer,
                  _ reason: String = "Read from the text") -> ImportFact {
            ImportFact(field: field, value: value, source: source, confidence: .certain, reason: reason)
        }
        func certain(_ kind: ImportKind, _ reason: String) -> ImportRecognition {
            ImportRecognition(kind: kind, confidence: .certain, reason: reason)
        }

        let invoiceId = UUID()
        let invoice = ImportItem(
            id: invoiceId, file: file("EDP invoice FT 0451-43500.pdf", url: pdf),
            recognition: certain(.utilityInvoice, "EDP layout: provider name and invoice number on the first page"),
            title: "EDP invoice FT 0451/43500",
            facts: [fact(.amount, .money(4820, .eur)), fact(.docDate, .date(day(2026, 6, 1))),
                    fact(.periodStart, .date(day(2026, 5, 17))), fact(.periodEnd, .date(day(2026, 6, 16))),
                    fact(.invoiceNumber, .text("FT 0451/43500"))],
            placement: ImportPlacement(metadata: EvidenceMetadata(kind: .utilityInvoice, docDate: day(2026, 6, 1), amountMinorUnits: 4820, currency: .eur),
                                       canonicalName: "2026-06-01 Utility invoice EDP FT 0451-43500 €48.20.pdf"),
            links: [ProposedLink(entity: EvidenceEntity(type: .property, id: 1), label: "Flat 1", confidence: .certain, reasons: ["EDP is a provider of Flat 1"])],
            issues: [ImportIssue(id: "chooseLink", kind: .chooseLink([
                LinkCandidate(entity: .transaction(9001), label: "Debit 5 Jun 2026 · EDP COMERCIAL · €48.20", reasons: ["Same amount", "4 days after the invoice"]),
                LinkCandidate(entity: .transaction(9002), label: "Debit 6 Jun 2026 · EDP DD · €48.20", reasons: ["Same amount", "5 days after the invoice"])
            ]), reason: "2 debits of €48.20 could have paid it: which one?", offers: [.fileWithoutLink])],
            groupKey: "Utility invoices")

        let impact = FiledYearImpact(startYear: 2024, person: "Person A", isPaid: false,
                                     returnChanges: [.init(label: "SA102 Employment 1: Pay from this employment", before: "£41,760.00", after: "£43,010.00")],
                                     informationChanges: [], taxDifferenceMinorUnits: 50000,
                                     causes: ["P60 2024/25 from Acme Widgets Ltd"])
        let heldId = UUID()
        let held = ImportItem(
            id: heldId, file: file("P60 2024-25.pdf"), recognition: certain(.payrollForm(.p60), "“P60 End of Year Certificate” on the first page"),
            title: "P60 2024/25 · Acme Widgets Ltd",
            facts: [fact(.taxYear, .year(2024)), fact(.issuer, .text("Acme Widgets Ltd")),
                    fact(.pay, .money(4_301_000, .gbp), .ocr, "Read by text recognition"),
                    fact(.taxDeducted, .money(612_400, .gbp), .ocr, "Read by text recognition")],
            placement: ImportPlacement(metadata: EvidenceMetadata(kind: .p60), canonicalName: "2025-04-05 P60 Person A 2024-25.pdf"),
            issues: [ImportIssue(id: "filed-2024-Person A", kind: .filedYear(impact), reason: impact.headline, offers: [.leaveOut])],
            groupKey: "Payroll forms")

        // A P11D whose pay the user has confirmed ("You"), its tax still to check, and a link to check.
        let figuresId = UUID()
        let figures = ImportItem(
            id: figuresId, file: file("P11D 2025-26.pdf", ocr: true), recognition: certain(.payrollForm(.p11d), "“P11D” form layout"),
            title: "P11D 2025/26 · Acme Widgets Ltd",
            facts: [fact(.taxYear, .year(2025)), fact(.issuer, .text("Acme Widgets Ltd")),
                    ImportFact(field: .pay, value: .money(184_000, .gbp), source: .user, confidence: .certain, reason: "Checked by you"),
                    ImportFact(field: .taxDeducted, value: .money(36_800, .gbp), source: .ocr, confidence: .needsReview, reason: "Read by text recognition")],
            placement: ImportPlacement(metadata: EvidenceMetadata(kind: .p11d), canonicalName: "2026-07-06 P11D Person A 2025-26.pdf"),
            links: [ProposedLink(entity: EvidenceEntity(type: .employment, id: 1), label: "Employment · Acme Widgets Ltd",
                                 confidence: .needsReview, reasons: ["Same employer name"])],
            groupKey: "Payroll forms")

        let scanId = UUID()
        let scan = ImportItem(
            id: scanId, file: file("scan_0412.pdf", ocr: true),
            recognition: ImportRecognition(kind: .unknown, confidence: .needsReview, reason: "No known layout or wording recognised"),
            title: "scan_0412.pdf",
            facts: [ImportFact(field: .docDate, value: .date(day(2026, 4, 12)), source: .fileName, confidence: .needsReview, reason: "From the file name")],
            issues: [ImportIssue(id: "unknownKind", kind: .unknownKind(proposed: .insuranceReceipt), reason: "What is this document?")],
            groupKey: "Other documents")

        let statementId = UUID()
        let statementFile = file("Everyday Current May 2026.csv")
        let statement = ImportItem(
            id: statementId, file: statementFile, recognition: certain(.bankStatementCSV, "Matches the saved CSV profile of Everyday Current"),
            title: "Everyday Current · May 2026",
            facts: [fact(.periodStart, .date(day(2026, 5, 1))), fact(.periodEnd, .date(day(2026, 5, 31)))],
            issues: [ImportIssue(id: "unparsedLines", kind: .statement(.unparsedLines(["31/05/2026,PENDING CARD 4412,,", "Balance brought forward,,1204.56"])),
                                 reason: "2 lines of the statement couldn't be read: add them by hand after the import", offers: [.acknowledge])],
            groupKey: "Statements", notes: ["Closing balance checked: £2,318.40 on 31 May 2026"])
        let statementRows = ImportItem(
            file: statementFile, recognition: statement.recognition, title: "Everyday Current · May 2026: 3 rows already imported",
            effect: .none, duplicate: ImportDuplicate(level: .transactions, of: "3 rows already imported"),
            parentId: statementId, groupKey: "Statements")

        func receipt(_ number: Int, _ month: Int) -> ImportItem {
            ImportItem(file: file("Recibo \(number).pdf"), recognition: certain(.rentReceiptPDF, "Portal rent receipt layout"),
                       title: "Rent receipt nº \(number) · Tenancy 2",
                       facts: [fact(.receiptNumber, .text("\(number)")), fact(.amount, .money(85000, .eur)),
                               fact(.docDate, .date(day(2026, month, 1)))],
                       placement: ImportPlacement(metadata: EvidenceMetadata(kind: .rentReceipt), canonicalName: "2026-0\(month)-01 Rent receipt \(number).pdf"),
                       links: [ProposedLink(entity: EvidenceEntity(type: .rentReceipt, id: Int64(number)), label: "Receipt nº \(number)",
                                            confidence: .certain, reasons: ["Same receipt number and contract"])],
                       effect: .file, groupKey: "Rent receipts")
        }

        let insurance = ImportItem(
            file: file("Seguro casa 2025.pdf"), recognition: certain(.evidence(.insuranceReceipt), "Insurer's receipt wording"),
            title: "Insurance receipt · Flat 1 · 2025",
            facts: [fact(.amount, .money(21_650, .eur)), fact(.docDate, .date(day(2025, 3, 2)))],
            placement: ImportPlacement(metadata: EvidenceMetadata(kind: .insuranceReceipt), canonicalName: "2025-03-02 Insurance receipt Flat 1 €216.50.pdf"),
            links: [ProposedLink(entity: EvidenceEntity(type: .property, id: 1), label: "Flat 1", confidence: .certain, reasons: ["Policy address is Flat 1"])],
            informationChanges: [FiledYearImpact(startYear: 2024, person: "Person A", isPaid: false, returnChanges: [],
                                                 informationChanges: [.init(label: "Property costs · Insurance", before: "£0.00", after: "£183.40")],
                                                 taxDifferenceMinorUnits: 0, causes: [])],
            groupKey: "Other documents", notes: ["Not linked: no matching transaction yet"])

        let duplicate = ImportItem(
            file: file("EDP invoice FT 0451-41022.pdf"), recognition: certain(.utilityInvoice, "EDP layout"),
            title: "EDP invoice FT 0451/41022", effect: .none,
            duplicate: ImportDuplicate(level: .document, of: "Same document as EDP invoice FT 0451/41022 of 1 May 2026"),
            groupKey: "Utility invoices")

        let leftOut = ImportItem(
            file: file("Meeting notes.txt"), recognition: certain(.evidence(.other), "Plain text"),
            title: "Meeting notes", isLeftOut: true, groupKey: "Other documents")

        let plan = ImportPlan(items: [invoice, held, figures, scan, statement, statementRows, receipt(51, 5), receipt(52, 6),
                                      insurance, duplicate, leftOut],
                              ignoredFiles: [".DS_Store"])
        return Demo(plan: plan, invoiceId: invoiceId, heldId: heldId, scanId: scanId, statementId: statementId, figuresId: figuresId)
    }
}
#endif
