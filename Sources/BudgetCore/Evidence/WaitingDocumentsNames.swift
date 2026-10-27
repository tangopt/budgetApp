import Foundation
import GRDB

extension WaitingDocuments {
    /// How an automatic link is listed (the import summary's "N documents linked to their payments", each with
    /// Undo): the document by its name, the payment by its link title ("5 Mar 2023 · DEMO PWR DD 123 · −€100.00",
    /// `EvidenceLinkTitles`). A document or transaction gone since is named so, never by its id.
    public static func describe(db: Database, _ pair: Pair) throws -> (document: String, payment: String) {
        let document = try EvidenceDocument.fetchOne(db, key: pair.documentId)?.displayName ?? "Document no longer exists"
        let payment = try EvidenceLinkTitles.line(db: db, entity: EvidenceEntity(type: .transaction, id: pair.transactionId)).title
        return (document, payment)
    }
}
