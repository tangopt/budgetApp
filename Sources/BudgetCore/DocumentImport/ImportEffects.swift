import Foundation
import GRDB

public enum ImportEffectsError: Error, Equatable {
    /// A linking effect (rent receipt PDF, transfer advice) was performed without its document.
    case documentRequired
    /// The effect names a record it doesn't carry (a rent receipt PDF without its receipt).
    case incompleteEffect(String)
}

/// The one place an item's effect is applied, inside the caller's write transaction, through the
/// existing guarded write paths. The importer applies Ready items with it, and the filed-year
/// guard performs it in a rolled-back savepoint (`documentId: nil`) to see what it would change.
public enum ImportEffects {
    /// What confirming the item writes besides filing its document, in the order the importer
    /// applies it: the effect (`perform`), then the item's certain proposed links the effect
    /// doesn't make itself, then the documents those certain links replace unlinked from their
    /// record (never the item's own document; never deleted). The importer calls it after filing the document (`documentId`); the
    /// filed-year guard calls it with a placeholder document, so it checks exactly what apply
    /// does. The batch's follow-on matching runs after all items (`followOns`).
    public static func applyRecords(db: Database, item: ImportItem, documentId: Int64?, importRunId: Int64?) throws {
        try perform(db: db, item.effect, documentId: documentId, importRunId: importRunId)
        for link in item.links where link.confidence == .certain && !link.madeByEffect {
            guard let documentId else { throw ImportEffectsError.documentRequired }
            try EvidenceLinks.link(db: db, documentId: documentId, to: link.entity, role: link.role)
        }
        for link in item.links where link.confidence == .certain {
            for replaced in link.replacing where replaced != documentId {
                _ = try EvidenceLinks.unlink(db: db, documentId: replaced, from: link.entity)
            }
        }
    }

    /// The properties whose matching follows the item (nil: all of them, e.g. after a statement
    /// or a link to a transaction).
    public static func touchedPropertyIds(db: Database, item: ImportItem) throws -> Set<Int64>? {
        if item.links.contains(where: { $0.entity.type == .transaction }) { return nil }
        switch item.effect {
        case .file, .none, .payrollForm: return []
        case .ukStatement, .transferAdvice: return nil
        case .rentReceiptsExport(let propertyId, _): return [propertyId]
        case .rentReceiptPDF(let planned): return planned.tenancy.map { [$0.propertyId] } ?? nil
        case .utilityInvoice(let invoice):
            return try UtilityProvider.fetchOne(db, key: invoice.providerId).map { [$0.propertyId] } ?? nil
        }
    }

    /// The matching that follows applied items: transfers (when `propertyIds` is nil), then for
    /// each property rent receipts to credits and utility recharges to payments, then receipt
    /// PDFs to the credits paying them, then the received-transfer advices already in the
    /// library to their credits (`.link` outcomes only, each property in turn, as
    /// `RentCreditEvidence.run` does). `propertyIds` nil means every property; empty, nothing.
    /// The importer runs it once after the batch's items; the filed-year guard runs the same.
    public static func followOns(db: Database, propertyIds: Set<Int64>?,
                                 adviceCache: RentCreditEvidence.AdviceCache = RentCreditEvidence.AdviceCache()) throws {
        if propertyIds == nil { _ = try TransferMatcher.match(db: db) }
        let ids = try propertyIds ?? Set(Property.fetchAll(db).compactMap(\.id))
        guard !ids.isEmpty else { return }
        for propertyId in ids.sorted() {
            try RentReceiptMatching.match(db: db, propertyId: propertyId)
            _ = try Recharges.matchPayments(db: db, propertyId: propertyId)
        }
        _ = try RentCreditEvidence.linkReceiptDocuments(db: db)
        var pending = try RentCreditEvidence.libraryAdvices(db: db, cache: adviceCache)
        for propertyId in ids.sorted() where !pending.isEmpty {
            let plan = try RentCreditEvidence.planAdvices(db: db, propertyId: propertyId, inputs: pending)
            _ = try RentCreditEvidence.linkLibraryAdvices(db: db, plan: plan)
            let done = Set(plan.filter { $0.outcome == .link || $0.outcome == .alreadyLinked }.map(\.input.sha256))
            pending.removeAll { done.contains($0.sha256) }
        }
    }

    /// Performs `effect`. `documentId` is the item's document in the library (nil when only
    /// looking at the effect's figures); `importRunId` stamps a statement's import batch.
    ///
    /// - `.rentReceiptsExport`: `RentReceiptImport.run` (which reruns the property's matching).
    /// - `.rentReceiptPDF`: links the document to its receipt (role "Receipt"); no matching.
    /// - `.transferAdvice`: links the document to each credit (`RentCreditEvidence.adviceRole`)
    ///   and gives it the credit's amount when it has none, as `RentCreditEvidence.applyAdvices` does.
    /// - `.utilityInvoice`: `UtilityInvoiceIntake.record` with the document (proposed without one).
    /// - `.payrollForm`: `PayrollFormImport.apply` with the document.
    /// - `.ukStatement`: the account's empty details filled, then the rows committed (with the
    ///   rows shared with a left-out earlier statement, `statementRows`); with no
    ///   rows (all duplicates) only the closing balance is checked — never an empty batch. A
    ///   balance adjustment added then isn't stamped with `importRunId` (it has no batch of its
    ///   own); the run's change log records it.
    /// - `.file`, `.none`: nothing.
    /// The rows a statement adds: its own, then those it shares with an earlier statement of
    /// the import that no saved row has (that statement was left out).
    static func statementRows(db: Database, _ statement: UKStatementEffect) throws -> [StagedTransaction] {
        guard !statement.batchOverlap.isEmpty else { return statement.staged }
        let saved = Set(try String.fetchAll(db, sql: "SELECT fingerprint FROM transaction_ WHERE accountId = ?", arguments: [statement.accountId]))
        let own = Set(statement.staged.map(\.fingerprint))
        return statement.staged + statement.batchOverlap.filter { !saved.contains($0.fingerprint) && !own.contains($0.fingerprint) }
    }

    public static func perform(db: Database, _ effect: ImportEffect, documentId: Int64?, importRunId: Int64?) throws {
        switch effect {
        case .file, .none:
            return
        case .rentReceiptsExport(let propertyId, let rows):
            try RentReceiptImport.run(db: db, propertyId: propertyId, rows: rows)
        case .rentReceiptPDF(let planned):
            guard planned.outcome == .link else { throw ImportEffectsError.incompleteEffect("Rent receipt PDF not planned to link") }
            guard let documentId else { throw ImportEffectsError.documentRequired }
            guard let receiptId = planned.receipt?.id else { throw ImportEffectsError.incompleteEffect("Rent receipt PDF without its receipt") }
            try EvidenceLinks.link(db: db, documentId: documentId, to: .rentReceipt(receiptId), role: "Receipt")
        case .transferAdvice(let planned):
            guard planned.outcome == .link else { throw ImportEffectsError.incompleteEffect("Transfer advice not planned to link") }
            guard let documentId else { throw ImportEffectsError.documentRequired }
            guard !planned.credits.isEmpty else { throw ImportEffectsError.incompleteEffect("Transfer advice without its credit") }
            _ = try RentCreditEvidence.linkAdvice(db: db, documentId: documentId, credits: planned.credits)
        case .utilityInvoice(var invoice):
            if let documentId { invoice.documentId = documentId }
            try UtilityInvoiceIntake.record(db: db, &invoice)
        case .payrollForm(let confirmed):
            try PayrollFormImport.apply(db: db, confirmed, documentId: documentId)
        case .ukStatement(let statement):
            if let fill = statement.accountFill {
                try StatementAccountCheck.fill(db: db, accountId: statement.accountId, with: fill)
            }
            let rows = try statementRows(db: db, statement)
            if rows.isEmpty {
                if let finish = statement.statement {
                    _ = try ImportCoordinator.finishStatementOnly(db: db, accountId: statement.accountId,
                                                                  sourceFileName: statement.sourceFileName, statement: finish)
                }
            } else {
                try ImportCoordinator.commit(db: db, accountId: statement.accountId, sourceFileName: statement.sourceFileName,
                                             staged: rows, decisions: UKStatementEffect.decisions(for: rows), statement: statement.statement,
                                             importRunId: importRunId)
            }
        }
    }
}
