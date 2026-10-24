// App/Snapshots/ImportReviewDemo.swift
#if SNAPSHOTS
import Foundation
import BudgetCore
import GRDB
import struct BudgetCore.Transaction

/// An invented review for the Imports routes (`imports-review_link`, `_kind`, `_unread_lines`, `_figures`, `_left_out_rows`,
/// `_peek`, `_link_search`, `_balance`, `_row`, `_learnt`):
/// every section filled — a utility invoice with two possible debits, a P60 held by a filed
/// return, an unknown scan, a statement with unread lines and rows already imported, a statement
/// whose closing doesn't match with a row that looks already saved and one skipped, ready rent
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
        /// The Ready insurance receipt, linked to a demo transaction (`linkedTransactionId`).
        let insuranceId: UUID
        let linkedTransactionId: Int64?
        /// The statement whose closing doesn't match, and its row to keep or skip.
        let checkedId: UUID
        let rowId: UUID
        /// A receipt read with learnt rules, a date to check (with "Remember for this issuer") and what it will remember.
        let learntId: UUID
        /// A repair bill two debits of one merchant add up to: "Keep both links" or "File without a link".
        let instalmentsId: UUID
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

        // A statement whose closing doesn't match: a row that looks like a saved one, one skipped.
        func staged(_ day: Int, _ description: String, _ amount: Int) -> StagedTransaction {
            StagedTransaction(parsed: ParsedTransaction(date: ImportReviewDemo.day(2026, 6, day), rawDescription: description, amountMinorUnits: amount),
                              suggestedCategoryId: nil, source: .none, confidence: 0, fingerprint: "demo-\(day)-\(description)")
        }
        let checkedId = UUID()
        let checkedFile = file("Rainy Day Saver June 2026.csv")
        let checkedRows = [staged(3, "TRANSFER FROM CURRENT", 25_000), staged(12, "CARD PAYMENT CORNER GROCER", -1_840)]
        let skippedRow = staged(18, "INTEREST PAID", 412)
        var checkedEffect = UKStatementEffect(accountId: context.accountId("Rainy Day Saver") ?? 2, sourceFileName: checkedFile.fileName, staged: checkedRows,
                                              statement: StatementFinish(closing: StatementClosing(date: day(2026, 6, 30), balanceMinorUnits: 623_572),
                                                                         addAdjustment: false),
                                              accountFill: nil, skipped: [skippedRow])
        checkedEffect.certainDuplicates = ["demo-1", "demo-2", "demo-5", "demo-9"]
        let mismatch = StatementMismatch(date: day(2026, 6, 30), statementMinorUnits: 623_572, computedMinorUnits: 623_160)
        let checked = ImportItem(
            id: checkedId, file: checkedFile, recognition: certain(.bankStatementCSV, "Matches the saved CSV profile of Rainy Day Saver"),
            title: "Rainy Day Saver statement 1 Jun 2026–30 Jun 2026",
            facts: [fact(.reference, .text("Rainy Day Saver")), fact(.periodStart, .date(day(2026, 6, 1))), fact(.periodEnd, .date(day(2026, 6, 30)))],
            effect: .ukStatement(checkedEffect),
            issues: [ImportIssue(id: "balance-2-2026-06-30", kind: .statement(.balanceMismatch(mismatch)),
                                 reason: "The statement closes at £6,235.72 on 30 Jun 2026, but Rainy Day Saver would be at £6,231.60: "
                                    + "import it anyway with a reason, or leave it out of this import"),
                     ImportIssue(id: StatementChecks.rowsIssueId, kind: .readerProblem("Some rows look already saved: keep or skip each"),
                                 reason: "Some rows look already saved: keep or skip each")],
            groupKey: "Bank statements")
        let rowId = UUID()
        let row = ImportItem(
            id: rowId, file: checkedFile, recognition: checked.recognition, title: "12 Jun 2026 CARD PAYMENT CORNER GROCER £18.40",
            effect: .none,
            issues: [ImportIssue(id: StatementChecks.possibleDuplicateIssueId,
                                 kind: .statement(.possibleDuplicate(existingTransactionId: 1, existingLabel: "CORNER GROCER (11 Jun 2026, -£18.40)")),
                                 reason: "Looks like “CORNER GROCER” of 11 Jun 2026 already saved", offers: [.keepRow, .skipRow])],
            parentId: checkedId, groupKey: "Bank statements")
        var skipped = ImportItem(file: checkedFile, recognition: checked.recognition, title: "18 Jun 2026 INTEREST PAID £4.12",
                                 effect: .none, parentId: checkedId, groupKey: "Bank statements")
        skipped.duplicate = ImportDuplicate(level: .transactions, of: StatementChecks.skippedNote)

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

        // A debit of the demo database the insurance receipt is linked to (its peek, the search).
        let debit: (transaction: Transaction, currency: Currency)? = (try? context.dbQueue.read { db -> (Transaction, Currency)? in
            guard let transaction = try Transaction.filter(Column("amountMinorUnits") < 0).order(Column("date").desc, Column("id").desc).fetchOne(db)
            else { return nil }
            return (transaction, try Account.fetchOne(db, key: transaction.accountId)?.currency ?? .gbp)
        }) ?? nil
        let insuranceId = UUID()
        let insuranceAmount = debit.map { abs($0.transaction.amountMinorUnits) } ?? 21_650
        let insuranceDate = debit.map { PayCalendar.utcDay(sameDayAs: $0.transaction.date, in: TimeZone(identifier: "UTC")!) } ?? day(2025, 3, 2)
        let insuranceCurrency = debit?.currency ?? .eur
        let insuranceLinks = [ProposedLink(entity: EvidenceEntity(type: .property, id: 1), label: "Flat 1", confidence: .certain, reasons: ["Policy address is Flat 1"])]
            + (debit.flatMap { found in found.transaction.id.map { id in
                [ProposedLink(entity: .transaction(id), label: found.transaction.rawDescription, confidence: .certain,
                              reasons: ["Booked on the receipt's day for exactly its amount"])]
            } } ?? [])
        let insurance = ImportItem(
            id: insuranceId,
            file: file("Seguro casa 2025.pdf"), recognition: certain(.evidence(.insuranceReceipt), "Insurer's receipt wording"),
            title: "Insurance receipt · Flat 1 · 2025",
            facts: [fact(.amount, .money(insuranceAmount, insuranceCurrency)), fact(.docDate, .date(insuranceDate))],
            placement: ImportPlacement(metadata: EvidenceMetadata(kind: .insuranceReceipt), canonicalName: "\(ISO8601DateFormatter.string(from: insuranceDate, timeZone: TimeZone(identifier: "UTC")!, formatOptions: .withFullDate)) Insurance receipt Flat 1 \(Money.format(insuranceAmount, currency: insuranceCurrency)).pdf"),
            links: insuranceLinks,
            informationChanges: [FiledYearImpact(startYear: 2024, person: "Person A", isPaid: false, returnChanges: [],
                                                 informationChanges: [.init(label: "Property costs · Insurance", before: "£0.00", after: "£183.40")],
                                                 taxDifferenceMinorUnits: 0, causes: [])],
            groupKey: "Other documents")

        let duplicate = ImportItem(
            file: file("EDP invoice FT 0451-41022.pdf"), recognition: certain(.utilityInvoice, "EDP layout"),
            title: "EDP invoice FT 0451/41022", effect: .none,
            duplicate: ImportDuplicate(level: .document, of: "Duplicate of EDP invoice FT 0451/41022 of 1 May 2026: the same utility invoice, invoice number FT 0451/41022"),
            groupKey: "Utility invoices")

        let leftOut = ImportItem(
            file: file("Meeting notes.txt"), recognition: certain(.evidence(.other), "Plain text"),
            title: "Meeting notes", isLeftOut: true, groupKey: "Other documents")

        // Read with the issuer's learnt rules (its kind, name and where its amount sits), its date
        // to check, a figure fixed for this document only, and a link the user chose to remember.
        let learntId = UUID()
        var learntFile = file("Seguro casa 2026.pdf")
        learntFile.text = "Example Seguros, S.A. NIF 503504564\nRecibo de seguro\nValor a pagar: 42,10 €"
        var learntRecognition = certain(.evidence(.insuranceReceipt), "Learnt: Example Seguros, S.A. → Insurance receipt")
        learntRecognition.ruleId = 1
        var learnt = ImportItem(
            id: learntId, file: learntFile, recognition: learntRecognition,
            title: "Insurance receipt · Example Seguros · 2026",
            facts: [fact(.issuer, .text("Example Seguros"), .learntRule, "Learnt: Example Seguros, S.A. is named Example Seguros"),
                    fact(.amount, .money(4210, .eur), .learntRule, "Learnt position: after “Valor a pagar”"),
                    ImportFact(field: .docDate, value: .date(day(2026, 3, 5)), source: .ocr, confidence: .needsReview, reason: "Read by text recognition")],
            placement: ImportPlacement(metadata: EvidenceMetadata(kind: .insuranceReceipt, docDate: day(2026, 3, 5), amountMinorUnits: 4210, currency: .eur),
                                       canonicalName: "2026-03-05 Insurance receipt Example Seguros €42.10.pdf"),
            issues: [ImportIssue(id: "confirmFigure.docDate", kind: .confirmFigure(.docDate), reason: "Date read by text recognition: check it")],
            groupKey: "Other documents", notes: [LearntFigures.notPlacedNote])
        learnt.appliedRules = [
            ImportRuleUse(ruleId: 1, kind: .documentKind, label: "Learnt: Example Seguros, S.A. → Insurance receipt"),
            ImportRuleUse(ruleId: 2, kind: .issuer, label: "Learnt: Example Seguros, S.A. is named Example Seguros"),
            ImportRuleUse(ruleId: 3, kind: .figurePosition, label: "Learnt position: after “Valor a pagar”")
        ]
        learnt.ruleDrafts = [ImportRuleDraft(kind: .link, key: "nif:503504564#transaction", matchLabel: "Example Seguros, S.A.",
                                             actionJSON: "{\"descriptionKey\":\"EXAMPLE SEGUROS\"}", actionLabel: "Paid by “EXAMPLE SEGUROS”",
                                             replaces: "Paid by “EXAMPLE INSURANCE”")]

        // A plumber's bill paid in two instalments: both links proposed, asked (never certain on their own).
        let instalmentsId = UUID()
        let instalmentsReason = "Paid in 2 instalments: €40.00 + €39.95"
        let instalments = ImportItem(
            id: instalmentsId, file: file("Fatura canalizador.pdf"), recognition: certain(.evidence(.repairInvoice), "Repair bill wording"),
            title: "Repair bill of 2026-03-05",
            facts: [fact(.amount, .money(7_995, .eur)), fact(.docDate, .date(day(2026, 3, 5)))],
            placement: ImportPlacement(metadata: EvidenceMetadata(kind: .repairInvoice, docDate: day(2026, 3, 5), amountMinorUnits: 7_995, currency: .eur),
                                       canonicalName: "20260305 - Property - Repair bill - Canalizacoes Exemplo"),
            links: [ProposedLink(entity: .transaction(9_001), label: "PAG CANALIZACOES EXEMPLO · 5 Mar 2026 · −€40.00", confidence: .needsReview,
                                 reasons: [instalmentsReason]),
                    ProposedLink(entity: .transaction(9_002), label: "PAG CANALIZACOES EXEMPLO · 25 Mar 2026 · −€39.95", confidence: .needsReview,
                                 reasons: [instalmentsReason])],
            issues: [ImportIssue(id: EvidenceDocumentReader.instalmentsIssueId, kind: .readerProblem(instalmentsReason), reason: instalmentsReason,
                                 offers: [.acknowledge, .fileWithoutLink])],
            groupKey: "Repair bill documents")

        let plan = ImportPlan(items: [invoice, held, figures, scan, learnt, instalments, statement, statementRows, checked, row, skipped, receipt(51, 5),
                                      receipt(52, 6), insurance, duplicate, leftOut],
                              ignoredFiles: [".DS_Store"])
        return Demo(plan: plan, invoiceId: invoiceId, heldId: heldId, scanId: scanId, statementId: statementId, figuresId: figuresId,
                    insuranceId: insuranceId, linkedTransactionId: debit?.transaction.id, checkedId: checkedId, rowId: rowId,
                    learntId: learntId, instalmentsId: instalmentsId)
    }
}

/// The on-device model's stand-in for the snapshot routes (snapshot mode never asks the real one):
/// a fixed guess for the demo's `Letter.pdf`, nothing for other files; or unavailable, with the
/// message a Mac with Apple Intelligence turned off gives.
struct SnapshotModelReader: DocumentModelReading {
    var isAvailable = true

    static let offMessage = "On-device model unavailable: Apple Intelligence is turned off"

    func availability() -> DocumentModelAvailability { isAvailable ? .available : .unavailable(Self.offMessage) }

    func read(text: String, fileName: String, kinds: [DocumentKind]) async throws -> DocumentModelGuess? {
        guard isAvailable else { throw DocumentModelReadError.unavailable(Self.offMessage) }
        guard fileName == "Letter.pdf" else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return DocumentModelGuess(kind: .condominioReceipt, issuer: "Residents' Association",
                                  docDate: calendar.date(from: DateComponents(year: 2026, month: 9, day: 14)), reference: "Stairwell lights")
    }
}
#endif
