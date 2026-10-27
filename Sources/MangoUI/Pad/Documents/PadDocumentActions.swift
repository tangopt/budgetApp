import Foundation
import BudgetCore
import GRDB
import struct BudgetCore.Transaction

/// The iPad Documents detail's edits (step 8, Task 10): Link to… a transaction, Unlink, and Change kind…. Each is the
/// Mac's BudgetCore write, made through `PadWriteModel` in Documents (the device writer, filed years checked):
/// - Link and Unlink: `EvidenceLinks.link` / `.unlink`, inside `EvidenceLinkGuard.checked` for a transaction, with the
///   document-link origin. A refusal ("Links not changed: …") shows under the link (Unlink) or the document (Link).
/// - Change kind: `EvidenceLibrary.changeKind(db:)` (its own `EvidenceLinkGuard.checked` with
///   `detailsChangeFiledYear`), an edit. A refusal ("Details not saved: …") shows under the document's kind.
/// Nothing is offered while the user only views Documents; after a write the library and the links read again.
@MainActor
public final class PadDocumentActions: ObservableObject {
    public let documents: PadDocumentsModel
    public let write: PadWriteModel
    private let dbQueue: any DatabaseReader

    public init(documents: PadDocumentsModel, write: PadWriteModel, dbQueue: any DatabaseReader) {
        self.documents = documents
        self.write = write
        self.dbQueue = dbQueue
    }

    /// Where a refusal of Link to… or Change kind… shows: under the document.
    public nonisolated static func documentRow(_ documentId: Int64) -> String { "document-\(documentId)" }
    /// Where a refusal of Unlink shows: under the link.
    public nonisolated static func linkRow(_ linkId: Int64) -> String { "link-\(linkId)" }

    /// Whether the edits are offered.
    public var canEdit: Bool { write.canEdit }

    /// "Linked to 3 records — changing its kind affects all of them", before Change kind… on a document linked to
    /// more than one record (the kind is the document's, not the link's); nil otherwise.
    public nonisolated static func multiLinkWarning(_ count: Int) -> String? {
        count > 1 ? "Linked to \(count) records — changing its kind affects all of them" : nil
    }

    /// The warning for the selected document, from its links as read.
    public var kindWarning: String? { Self.multiLinkWarning(documents.links.count) }

    /// The transactions the Mac would suggest for `documentId` (`EvidenceMatcher.suggestions`), those already linked
    /// left out, best first.
    func linkChoices(for documentId: Int64) async -> [PadChoice] {
        let reader = dbQueue
        return (try? await reader.read { db -> [PadChoice] in
            guard let document = try EvidenceDocument.fetchOne(db, key: documentId) else { return [] }
            let index = EvidenceMatcher.Index(transactions: try Transaction.fetchAll(db), accounts: try Account.fetchAll(db),
                                              categories: try Category.fetchAll(db))
            let linked = try EvidenceLinks.links(db: db, for: documentId).filter { $0.entityType == .transaction }.map(\.entityId)
            let paid = index.linkedDebits(linked, currency: document.currency)
            let ids = EvidenceMatcher.suggestions(document: document, index: index, limit: 8, linkedDebits: paid)
                .map(\.transactionId).filter { !linked.contains($0) }
            let byId = Dictionary(try Transaction.filter(keys: ids).fetchAll(db).map { ($0.id!, $0) }, uniquingKeysWith: { a, _ in a })
            return ids.compactMap { byId[$0].map(PadChoice.transaction) }
        }) ?? []
    }

    /// Links the document to transaction `transactionId`: true when it saved.
    @discardableResult
    public func link(documentId: Int64, transactionId: Int64) async -> Bool {
        let entity = EvidenceEntity.transaction(transactionId)
        let saved = await write.perform(rowId: Self.documentRow(documentId), origin: .documentLink, edit: "Link document",
                                        scope: FiledYearEditCheck.Scope(transactionIds: [transactionId])) { db in
            try EvidenceLinkGuard.checked(db: db) { _ = try EvidenceLinks.link(db: db, documentId: documentId, to: entity) }
        }
        await reload(after: saved)
        return saved
    }

    /// Removes the link `line` of the document (the document stays in the library): true when it saved.
    @discardableResult
    public func unlink(documentId: Int64, _ line: PadDocumentsModel.LinkLine) async -> Bool {
        let entity = line.entity
        let scope = FiledYearEditCheck.Scope(transactionIds: entity.type == .transaction ? [entity.id] : [])
        let saved = await write.perform(rowId: Self.linkRow(line.id), origin: .documentLink, edit: "Unlink document", scope: scope) { db in
            guard entity.type == .transaction else { _ = try EvidenceLinks.unlink(db: db, documentId: documentId, from: entity); return }
            _ = try EvidenceLinkGuard.checked(db: db) { try EvidenceLinks.unlink(db: db, documentId: documentId, from: entity) }
        }
        await reload(after: saved)
        return saved
    }

    /// Files the document as `kind`, every other detail kept: true when it saved.
    @discardableResult
    public func changeKind(documentId: Int64, to kind: DocumentKindRef) async -> Bool {
        let linked = (try? await dbQueue.read { db in
            try EvidenceLinks.links(db: db, for: documentId).filter { $0.entityType == .transaction }.map(\.entityId)
        }) ?? []
        let saved = await write.perform(rowId: Self.documentRow(documentId), origin: .edit, edit: "Change kind",
                                        scope: FiledYearEditCheck.Scope(transactionIds: linked)) { db in
            _ = try EvidenceLibrary.changeKind(db: db, documentId: documentId, to: kind)
        }
        await reload(after: saved)
        return saved
    }

    private func reload(after saved: Bool) async {
        guard saved else { return }
        await documents.reload()
        await documents.loadLinks()
    }
}
