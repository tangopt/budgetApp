import CoreGraphics
import CoreText
import Foundation
import GRDB

/// The tenant's recharge email as the iPad prepares it (step 10, Task 12): the Mac's draft (`RechargeEmail.draft`:
/// recipients, subject and text from the property's template), the statement as a PDF, and the bills' PDFs from the
/// document library, copied under their own names into one folder. Building it writes nothing to the database and sends
/// nothing: the person opens it in Mail (or shares it), sends it, then confirms "Mark as sent" (`markSent`).
///
/// What the email lacks is listed, never thrown: no recipient on the tenancy, an invoice line without its PDF in the
/// library (as the Mac's sheet warns), and a library file this device couldn't get (`unavailable`: the sheet refuses to
/// open the email until it can). The tenant's personal name appears only in the email's text, as on the Mac.
public struct RechargeEmailPackage: Equatable, Sendable {
    public struct Attachment: Equatable, Sendable {
        public var fileName: String
        public var url: URL

        public init(fileName: String, url: URL) {
            self.fileName = fileName
            self.url = url
        }
    }

    /// Where the bills' files come from: a document's local file (nil when this device doesn't have it), and the folder
    /// the statement PDF and the named copies go in (emptied and made again by `build`; the caller's to remove).
    public struct Library: Sendable {
        public var localFile: @Sendable (EvidenceDocument) -> URL?
        public var folder: URL

        public init(folder: URL, localFile: @escaping @Sendable (EvidenceDocument) -> URL?) {
            self.folder = folder
            self.localFile = localFile
        }
    }

    public var subject: String
    public var body: String
    public var to: [String]
    /// The statement PDF first, then the bills' PDFs in line order.
    public var attachments: [Attachment]
    /// What the email lacks, one plain sentence each.
    public var missing: [String]
    /// Library documents this device couldn't get (by name): the email isn't opened until they're here.
    public var unavailable: [String]

    public init(subject: String, body: String, to: [String], attachments: [Attachment], missing: [String], unavailable: [String] = []) {
        self.subject = subject
        self.body = body
        self.to = to
        self.attachments = attachments
        self.missing = missing
        self.unavailable = unavailable
    }

    /// Whether the email can be opened: every library file is here (a missing recipient or invoice PDF is the person's call).
    public var isReady: Bool { unavailable.isEmpty }

    static let noRecipient = "No email address on the tenancy: add the tenant's email to it, or type one in the message."
    static func noPDF(_ name: String) -> String { "\(name) has no PDF in the library: it won't be attached." }
    static func notHere(_ name: String) -> String { "\(name) isn't on this iPad yet: try again when you're online." }

    /// The documents the email attaches, in line order: what to get onto the device before `build`.
    public static func documents(db: Database, statementId: Int64) throws -> [EvidenceDocument] {
        var ids: [Int64] = []
        for id in try Recharges.lineDetails(db: db, statementId: statementId).compactMap(\.documentId) where !ids.contains(id) { ids.append(id) }
        let found = try EvidenceDocument.filter(keys: ids).fetchAll(db)
        return ids.compactMap { id in found.first { $0.id == id } }
    }

    /// The email for statement `statementId` in `language` (the property's template): the Mac's draft, the statement PDF
    /// written into `library.folder`, and the bills' PDFs copied there. Reads only.
    public static func build(db: Database, statementId: Int64, language: RechargeEmailLanguage, library: Library) throws -> RechargeEmailPackage {
        let draft = try RechargeEmail.draft(db: db, statementId: statementId, language: language)
        guard let statement = try RechargeStatement.fetchOne(db, key: statementId) else { throw RechargeError.statementNotFound }
        guard let tenancy = try Tenancy.fetchOne(db, key: statement.tenancyId),
              let property = try Property.fetchOne(db, key: tenancy.propertyId) else { throw RechargeError.tenancyNotFound }
        let details = try Recharges.lineDetails(db: db, statementId: statementId)
        let documents = try EvidenceDocument.filter(keys: draft.attachmentDocumentIds).fetchAll(db)

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: library.folder.path) { try fileManager.removeItem(at: library.folder) }
        try fileManager.createDirectory(at: library.folder, withIntermediateDirectories: true)
        var attachments: [Attachment] = []
        var missing: [String] = []
        var unavailable: [String] = []
        if draft.recipients.isEmpty { missing.append(noRecipient) }

        let statementName = RechargeStatementPDF.fileName(month: statement.month, language: language)
        let statementURL = library.folder.appendingPathComponent(statementName)
        try RechargeStatementPDF.data(details: details, totalMinorUnits: statement.totalMinorUnits, month: statement.month,
                                      propertyName: property.name, currency: property.currency, language: language)
            .write(to: statementURL, options: .atomic)
        attachments.append(Attachment(fileName: statementName, url: statementURL))

        for detail in details where detail.invoice != nil && detail.documentId == nil {
            missing.append(noPDF(lineName(detail, language: .english)))
        }
        for documentId in draft.attachmentDocumentIds {
            guard let document = documents.first(where: { $0.id == documentId }) else { continue }
            guard let source = library.localFile(document), fileManager.fileExists(atPath: source.path) else {
                missing.append(notHere(document.displayName))
                unavailable.append(document.displayName)
                continue
            }
            let target = RechargeEmail.attachmentTarget(for: document, in: library.folder)
            try fileManager.copyItem(at: source, to: target)
            attachments.append(Attachment(fileName: target.lastPathComponent, url: target))
        }
        return RechargeEmailPackage(subject: draft.subject, body: draft.body, to: draft.recipients, attachments: attachments,
                                    missing: missing, unavailable: unavailable)
    }

    /// "Electricity (Example Power) invoice of 05/03/2023", else a manual line's description.
    static func lineName(_ detail: Recharges.LineDetail, language: RechargeEmailLanguage) -> String {
        guard let provider = detail.provider, let invoice = detail.invoice else { return detail.line.lineDescription ?? "A line" }
        let of = language == .portuguese ? "fatura de" : "invoice of"
        return "\(RechargeEmail.kindName(provider.kind, language: language)) (\(provider.name)) \(of) \(RechargeEmail.day(invoice.issueDate))"
    }

    /// The statement is sent, as the Mac's Mark sent does (`Recharges.markSent`, the day given): only after the person
    /// confirmed. Through the device writer, so a member without Edit on Property, a filed year the statement's bank
    /// movements fall in, or a statement no longer a draft is refused and nothing is written.
    public static func markSent(statementId: Int64, writer: DeviceWriter, at day: Date) async throws {
        let paid = try await writer.reader.read { db -> [Int64] in
            let lines = try Recharges.lineDetails(db: db, statementId: statementId)
            let payments = try Int64.fetchAll(db, sql: "SELECT transactionId FROM rechargePayment WHERE statementId = ?",
                                              arguments: [statementId])
            return lines.compactMap { $0.invoice?.transactionId } + lines.compactMap(\.line.transactionId) + payments
        }
        _ = try await writer.writeCheckingFiledYears(.property, origin: .edit, edit: markSentEdit,
                                                     scope: FiledYearEditCheck.Scope(transactionIds: paid)) { db in
            try Recharges.markSent(db: db, statementId: statementId, at: day)
        }
    }

    /// The name a filed-year question gives Mark as sent (the Bills & recharges screen's).
    public static let markSentEdit = "Mark sent"
}

/// Where the Prepare email sheet is (step 10, Task 12): the preview; the message open in Mail or the share sheet; asking
/// the person to confirm "Mark as sent"; sent. Nothing marks the statement sent by itself: only `confirm()` from
/// `.confirming` asks for the write, and the composer reaching `.sent` only asks the question.
public struct RechargeEmailFlow: Equatable, Sendable {
    /// How the composer finished (Mail's own result; the share sheet's mapped onto it).
    public enum Outcome: Equatable, Sendable { case sent, saved, cancelled, failed }

    public enum Stage: Equatable, Sendable {
        case preview
        case composing
        /// "Mark as sent?" is asked.
        case confirming
        /// The person confirmed: the write is under way.
        case marking
        case markedSent
    }

    public private(set) var stage: Stage = .preview
    /// What the last outcome means for the person, under the preview.
    public private(set) var note: String?

    public init() {}

    public static let sentNote = "Mail sent it. Mark the statement as sent?"
    public static let savedNote = "Saved, not sent yet. Mark the statement as sent once it has gone."
    public static let cancelledNote = "Not sent. The statement stays a draft."
    public static let failedNote = "The message couldn't be sent. The statement stays a draft."

    /// The message is opened.
    public mutating func open() {
        guard stage == .preview else { return }
        stage = .composing
        note = nil
    }

    /// The composer closed: sent asks to mark it; saved, cancelled and failed go back to the preview, still a draft.
    public mutating func finished(_ outcome: Outcome) {
        guard stage == .composing else { return }
        switch outcome {
        case .sent:
            stage = .confirming
            note = Self.sentNote
        case .saved:
            stage = .preview
            note = Self.savedNote
        case .cancelled:
            stage = .preview
            note = Self.cancelledNote
        case .failed:
            stage = .preview
            note = Self.failedNote
        }
    }

    /// The person asks to mark it sent from the preview (she sent it some other way): the question is asked.
    public mutating func askToMarkSent() {
        guard stage == .preview else { return }
        stage = .confirming
    }

    /// The person confirmed: true when the write should run now.
    public mutating func confirm() -> Bool {
        guard stage == .confirming else { return false }
        stage = .marking
        return true
    }

    /// "Not now": back to the preview, still a draft.
    public mutating func decline() {
        guard stage == .confirming else { return }
        stage = .preview
    }

    /// The write's result: saved, else back to the preview, still a draft (the refusal shows there).
    public mutating func marked(saved: Bool) {
        guard stage == .marking else { return }
        stage = saved ? .markedSent : .preview
    }
}

/// The statement as a one-page PDF for the email (step 10, Task 12): its month and property, one row per line (what,
/// invoice date and period, a prorated line's days) with its amount, and the total, in the email's language. No names
/// of people. CoreGraphics and CoreText only (macOS and iOS).
public enum RechargeStatementPDF {
    /// "Extrato de despesas - outubro de 2026.pdf" / "Utilities statement - October 2026.pdf".
    public static func fileName(month: Date, language: RechargeEmailLanguage) -> String {
        let title = language == .portuguese ? "Extrato de despesas" : "Utilities statement"
        return "\(title) - \(RechargeEmail.monthName(month, language: language)).pdf".replacingOccurrences(of: "/", with: "-")
    }

    public static func data(details: [Recharges.LineDetail], totalMinorUnits total: Int, month: Date, propertyName: String,
                            currency: Currency, language: RechargeEmailLanguage) -> Data {
        var writer = RentalAccountsPDF.PageWriter()
        let title = language == .portuguese ? "Extrato de despesas" : "Utilities statement"
        writer.text("\(title) — \(RechargeEmail.monthName(month, language: language))", size: 16, bold: true)
        writer.text(propertyName, size: 11)
        writer.space(12)
        let columns: [CGFloat] = [0, 400]
        writer.row([language == .portuguese ? "Despesa" : "Charge", language == .portuguese ? "Valor" : "Amount"], at: columns, size: 10, bold: true)
        for detail in details {
            var label = RechargeEmailPackage.lineName(detail, language: language)
            if let start = detail.invoice?.periodStart, let end = detail.invoice?.periodEnd {
                label += ", \(RechargeEmail.day(start)) – \(RechargeEmail.day(end))"
            }
            if let note = RechargeEmail.note(detail.line, language: language) { label += " (\(note))" }
            writer.row([label, RechargeEmail.money(detail.line.amountMinorUnits, currency: currency, language: language)], at: columns, size: 10)
        }
        writer.space(8)
        writer.row([RechargeEmail.totalLabel(total, language: language), RechargeEmail.money(abs(total), currency: currency, language: language)],
                   at: columns, size: 11, bold: true)
        return writer.finish()
    }
}
