import GRDB
import Foundation

/// Utility invoice intake (plan phase 5 Task 2): files dropped or added, or already in the
/// evidence library (added by hand or from a source folder scan), are read with their
/// provider's rules (Vision OCR for image-only files), matched to the bank debit that paid
/// them, and — once the user confirms — recorded as `UtilityInvoice`s with the document
/// linked to the debit as its evidence (so the missing-evidence rule "one utility invoice per
/// utility debit" is met).
public enum UtilityInvoiceIntake {
    /// A proposed invoice for one document, for the user to check and complete.
    public struct Proposal: Equatable, Sendable {
        public var documentId: Int64?
        public var fileName: String
        public var reading: UtilityInvoiceReading
        /// The bank movement proposed as its payment (a debit, or a credit for a refund).
        public var transactionId: Int64?
        public var textStatus: DocumentTextStatus
        /// Whether the text came from OCR.
        public var usedOCR: Bool
        /// What to check before recording: a debit of the provider near the due date for
        /// another amount (the amount may be misread), or a copy of an invoice already recorded.
        public var warnings: [String] = []
        /// The recorded invoice this document is a copy of.
        public var duplicateOf: Int64?

        /// What the user still has to fill in before it can be recorded.
        public var missing: [String] {
            var missing: [String] = []
            if reading.providerId == nil { missing.append("provider") }
            if reading.issueDate == nil { missing.append("issue date") }
            if reading.amountMinorUnits == nil { missing.append("amount") }
            return missing
        }

        /// The invoice to record; `nil` while something is missing.
        public var invoice: UtilityInvoice? {
            guard let providerId = reading.providerId, let issueDate = reading.issueDate, let amount = reading.amountMinorUnits else { return nil }
            return UtilityInvoice(providerId: providerId, invoiceNumber: reading.invoiceNumber, periodStart: reading.periodStart,
                                  periodEnd: reading.periodEnd, issueDate: issueDate, amountMinorUnits: amount, documentId: documentId,
                                  transactionId: transactionId)
        }
    }

    // MARK: Reading

    /// A file's text: its text layer, else (image-only) OCR when `ocr` allows.
    public static func text(of url: URL, ocr: Bool = true) -> (text: String?, status: DocumentTextStatus, usedOCR: Bool) {
        let extraction = autoreleasepool { EvidenceTextExtractor.extract(from: url) }
        if extraction.text == nil, extraction.status == .image, ocr, let text = EvidenceOCR.text(of: url) {
            return (text, .image, true)
        }
        return (extraction.text, extraction.status, false)
    }

    /// Whether a document reads as one of the providers' invoices: classified a utility
    /// invoice, a provider's text markers, or (unclassified documents) a provider's file-name marker.
    public static func isUtilityInvoice(text: String?, fileName: String, kind: DocumentKind?, providers: [UtilityProvider]) -> Bool {
        if kind == .utilityInvoice { return true }
        if UtilityInvoiceReader.provider(text: text, fileName: "", providers: providers) != nil { return true }
        guard kind == nil || kind == .other else { return false }
        return UtilityInvoiceReader.provider(text: nil, fileName: fileName, providers: providers) != nil
    }

    /// Reads a document of the library: its stored text, else (image-only, never read) OCR of
    /// its file; the OCR text is stored on the document. Proposes the debit.
    public static func propose(document: EvidenceDocument, library: EvidenceLibrary, propertyId: Int64, ocr: Bool = true) throws -> Proposal {
        var text = document.extractedText
        var usedOCR = false
        if text == nil, ocr, document.textStatus == .image || document.textStatus == .unknown {
            let read = Self.text(of: library.fileURL(for: document), ocr: true)
            text = read.text
            usedOCR = read.usedOCR
            if let id = document.id, let found = read.text {
                try library.database.write { db in
                    try db.execute(sql: "UPDATE document SET extractedText = ?, textStatus = ? WHERE id = ?",
                                   arguments: [found, read.status.rawValue, id])
                }
            }
        }
        return try library.database.read { db in
            try propose(db: db, propertyId: propertyId, documentId: document.id, text: text, fileName: document.originalFileName,
                        textStatus: document.textStatus, usedOCR: usedOCR)
        }
    }

    /// Reads `text` with the property's providers' rules and proposes the debit.
    public static func propose(db: Database, propertyId: Int64, documentId: Int64?, text: String?, fileName: String,
                               textStatus: DocumentTextStatus, usedOCR: Bool = false) throws -> Proposal {
        let providers = try Recharges.providers(db: db, propertyId: propertyId)
        let reading = UtilityInvoiceReader.read(text: text, fileName: fileName, providers: providers)
        var proposal = Proposal(documentId: documentId, fileName: fileName, reading: reading, transactionId: nil,
                                textStatus: textStatus, usedOCR: usedOCR)
        let provider = providers.first { $0.id == reading.providerId }
        if let amount = reading.amountMinorUnits, let issueDate = reading.issueDate {
            proposal.transactionId = try bestPayment(db: db, propertyId: propertyId, provider: provider, amountMinorUnits: amount,
                                                     issueDate: issueDate)?.id
            if proposal.transactionId == nil, let provider,
               let other = try debitsForAnotherAmount(db: db, propertyId: propertyId, provider: provider, amountMinorUnits: amount,
                                                      issueDate: issueDate, dueDate: reading.dueDate).first {
                proposal.warnings.append("\(provider.name) debited \(Money.format(abs(other.amountMinorUnits), currency: .eur)) on "
                    + "\(PropertyDates.isoDay(other.date)), not the \(Money.format(abs(amount), currency: .eur)) read: check the amount")
            }
        }
        if let invoice = proposal.invoice, let copy = try Recharges.duplicate(db: db, of: invoice) {
            proposal.duplicateOf = copy.id
            proposal.warnings.append("A copy of the invoice of \(PropertyDates.isoDay(copy.issueDate)) for "
                + "\(Money.format(copy.amountMinorUnits, currency: .eur)) already recorded")
        }
        return proposal
    }

    /// Days around the due date (else after the issue date: `daysBefore` before to
    /// `lateDebitWindow` after) a debit of the provider for another amount is looked for.
    public static let dueDateSlack = 10
    public static let lateDebitWindow = 45

    /// The provider's bank movements (its bank description; debits, or credits for a refund)
    /// near the invoice's due date — else from `daysBefore` before to `lateDebitWindow` after
    /// its issue date — not of the amount read and not another invoice's: a sign the amount
    /// was misread. Closest to the due (else issue) date first.
    public static func debitsForAnotherAmount(db: Database, propertyId: Int64, provider: UtilityProvider, amountMinorUnits: Int,
                                              issueDate: Date, dueDate: Date?, excludingInvoice invoiceId: Int64? = nil) throws -> [Transaction] {
        guard amountMinorUnits != 0, provider.bankDescriptionPattern != nil else { return [] }
        let accountIds = try Properties.accounts(db: db, propertyId: propertyId, role: .current).map(\.accountId)
        guard !accountIds.isEmpty else { return [] }
        let calendar = MonthRange.calendar
        let anchor = PropertyDates.day(dueDate ?? issueDate)
        let from = calendar.date(byAdding: .day, value: dueDate == nil ? -daysBefore : -dueDateSlack, to: anchor)!
        let to = calendar.date(byAdding: .day, value: (dueDate == nil ? lateDebitWindow : dueDateSlack) + 1, to: anchor)!
        let taken = Set(try Int64.fetchAll(db, sql: "SELECT transactionId FROM utilityInvoice WHERE transactionId IS NOT NULL AND id != ?",
                                           arguments: [invoiceId ?? -1]))
        let sign = amountMinorUnits > 0 ? "<" : ">"
        return try Transaction
            .filter(accountIds.contains(Column("accountId")) && Column("date") >= from && Column("date") < to
                    && Column("amountMinorUnits") != -amountMinorUnits)
            .filter(sql: "amountMinorUnits \(sign) 0")
            .fetchAll(db)
            .filter { !taken.contains($0.id!) && provider.matchesBankDescription($0.rawDescription) }
            .sorted { (abs(PropertyFinance.days(anchor, PropertyDates.day($0.date))), $0.id!) < (abs(PropertyFinance.days(anchor, PropertyDates.day($1.date))), $1.id!) }
    }

    // MARK: Matching the payment

    /// Days a payment may fall before / after the issue date (debits come with the due date).
    public static let daysBefore = 5
    public static let daysAfter = 60

    /// The property's bank movements that could have paid the invoice: the exact amount (a
    /// debit, or a credit for a refund) on its current accounts, dated `daysBefore` before to
    /// `daysAfter` after the issue date, not yet another invoice's. Best first: the provider's
    /// bank description, then a utility category, then the closest date.
    public static func paymentCandidates(db: Database, propertyId: Int64, provider: UtilityProvider?, amountMinorUnits: Int,
                                         issueDate: Date, excludingInvoice invoiceId: Int64? = nil) throws -> [Transaction] {
        guard amountMinorUnits != 0 else { return [] }
        let accountIds = try Properties.accounts(db: db, propertyId: propertyId, role: .current).map(\.accountId)
        guard !accountIds.isEmpty else { return [] }
        let calendar = MonthRange.calendar
        let day = PropertyDates.day(issueDate)
        let from = calendar.date(byAdding: .day, value: -daysBefore, to: day)!
        let to = calendar.date(byAdding: .day, value: daysAfter + 1, to: day)!
        let taken = Set(try Int64.fetchAll(db, sql: "SELECT transactionId FROM utilityInvoice WHERE transactionId IS NOT NULL AND id != ?",
                                           arguments: [invoiceId ?? -1]))
        let utilityCategories = try RechargeNetting.utilityCategoryIds(db: db, propertyId: propertyId)
        let candidates = try Transaction
            .filter(accountIds.contains(Column("accountId")) && Column("amountMinorUnits") == -amountMinorUnits
                    && Column("date") >= from && Column("date") < to)
            .fetchAll(db)
            .filter { !taken.contains($0.id!) }
        func rank(_ t: Transaction) -> (Int, Int, Int, Int64) {
            (provider?.matchesBankDescription(t.rawDescription) == true ? 0 : 1,
             utilityCategories.contains(t.categoryId ?? -1) ? 0 : 1,
             abs(PropertyFinance.days(day, PropertyDates.day(t.date))),
             t.id!)
        }
        return candidates.sorted { rank($0) < rank($1) }
    }

    /// The best candidate, when it is the provider's (bank description) or in a utility category.
    public static func bestPayment(db: Database, propertyId: Int64, provider: UtilityProvider?, amountMinorUnits: Int,
                                   issueDate: Date, excludingInvoice invoiceId: Int64? = nil) throws -> Transaction? {
        guard let best = try paymentCandidates(db: db, propertyId: propertyId, provider: provider, amountMinorUnits: amountMinorUnits,
                                               issueDate: issueDate, excludingInvoice: invoiceId).first else { return nil }
        let utilityCategories = try RechargeNetting.utilityCategoryIds(db: db, propertyId: propertyId)
        return provider?.matchesBankDescription(best.rawDescription) == true || utilityCategories.contains(best.categoryId ?? -1) ? best : nil
    }

    // MARK: Recording

    /// Saves the invoice (`Recharges.saveInvoice`) and makes its document the evidence of its
    /// payment: the document becomes a utility invoice (date, period, amount) linked to the
    /// payment's transaction; a link to a previous payment of this invoice is removed.
    public static func record(db: Database, _ invoice: inout UtilityInvoice) throws {
        let before = try invoice.id.flatMap { try UtilityInvoice.fetchOne(db, key: $0) }
        try Recharges.saveInvoice(db: db, &invoice)
        guard let documentId = invoice.documentId else { return }
        guard var document = try EvidenceDocument.fetchOne(db, key: documentId) else { throw RechargeError.documentNotFound }
        let currency = try UtilityProvider.fetchOne(db, key: invoice.providerId)
            .flatMap { try Property.fetchOne(db, key: $0.propertyId) }?.currency
        document.kind = .utilityInvoice
        document.docDate = invoice.issueDate
        document.periodStart = invoice.periodStart
        document.periodEnd = invoice.periodEnd
        document.amountMinorUnits = abs(invoice.amountMinorUnits)
        document.currency = currency ?? document.currency
        try document.update(db)
        // The previous document stops being the previous debit's evidence when either changes.
        if let old = before, let oldTransaction = old.transactionId, let oldDocument = old.documentId,
           oldTransaction != invoice.transactionId || oldDocument != documentId {
            _ = try EvidenceLinks.unlink(db: db, documentId: oldDocument, from: .transaction(oldTransaction))
        }
        if let transactionId = invoice.transactionId {
            try EvidenceLinks.link(db: db, documentId: documentId, to: .transaction(transactionId))
        }
    }

    /// The library's documents that read as the property's utility invoices and aren't
    /// recorded yet, oldest first: those a provider of the property recognises, and utility
    /// invoices recognised by none that aren't evidence of another account's transactions.
    public static func pendingDocuments(db: Database, propertyId: Int64) throws -> [EvidenceDocument] {
        let providers = try Recharges.providers(db: db, propertyId: propertyId)
        let recorded = Set(try Int64.fetchAll(db, sql: "SELECT documentId FROM utilityInvoice WHERE documentId IS NOT NULL"))
        // A copy of a recorded invoice (same text, another file) isn't pending either.
        let recordedTexts = Set(try String.fetchAll(db, sql: """
            SELECT document.extractedText FROM document JOIN utilityInvoice ON utilityInvoice.documentId = document.id
            WHERE document.extractedText IS NOT NULL
            """).map(EvidenceText.normalized).filter { !$0.isEmpty })
        let accountIds = Set(try Properties.accounts(db: db, propertyId: propertyId).map(\.accountId))
        let elsewhere = Set(try Int64.fetchAll(db, sql: """
            SELECT documentLink.documentId FROM documentLink JOIN transaction_ ON transaction_.id = documentLink.entityId
            WHERE documentLink.entityType = ?
            """ + (accountIds.isEmpty ? "" : " AND transaction_.accountId NOT IN (\(accountIds.map(String.init).joined(separator: ",")))"),
            arguments: [EvidenceEntityType.transaction.rawValue]))
        return try EvidenceDocument.order(Column("docDate") == nil, Column("docDate"), Column("id")).fetchAll(db).filter { document in
            guard !recorded.contains(document.id!) else { return false }
            if let text = document.extractedText.map(EvidenceText.normalized), recordedTexts.contains(text) { return false }
            let recognised = UtilityInvoiceReader.provider(text: document.extractedText, fileName: "", providers: providers) != nil
                || ((document.kind == .other) && UtilityInvoiceReader.provider(text: nil, fileName: document.originalFileName, providers: providers) != nil)
            if recognised { return true }
            return document.kind == .utilityInvoice && !elsewhere.contains(document.id!)
        }
    }
}
