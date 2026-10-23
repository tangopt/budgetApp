import GRDB
import Foundation

/// One-off (`ReclassifyMortgageReceipts`): before `DocumentKind.mortgageReceipt` existed, the
/// bank's instalment receipts were filed as mortgage notices. Files each library document of
/// kind `mortgageNotice` that its text (or, without a telling text, its original file name)
/// shows to be a receipt (`DocumentClassifier`) under `mortgageReceipt`, with the receipt's
/// canonical name; and lets every evidence rule that accepts a notice accept a receipt too.
/// Library files are stored by content hash, so no file moves. Writes go through the records'
/// saves, so the sync change-tracking triggers record them.
public enum MortgageReceiptReclassification {
    /// What marked a document as a receipt.
    public enum Reason: String, Equatable, Sendable {
        case text, fileName
    }

    public struct DocumentChange: Equatable, Sendable {
        public var documentId: Int64
        public var originalFileName: String
        public var oldCanonicalName: String?
        public var newCanonicalName: String
        public var reason: Reason
    }

    public struct RequirementChange: Equatable, Sendable {
        public var requirementId: Int64
        public var name: String
        public var oldKinds: [DocumentKind]
        public var newKinds: [DocumentKind]
    }

    public struct Plan: Equatable, Sendable {
        public var documents: [DocumentChange]
        public var requirements: [RequirementChange]

        public var isEmpty: Bool { documents.isEmpty && requirements.isEmpty }
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case documentChanged(Int64)
        case requirementChanged(Int64)

        public var errorDescription: String? {
            switch self {
            case .documentChanged(let id): return "Document #\(id) changed since the plan was made: nothing written."
            case .requirementChanged(let id): return "Evidence rule #\(id) changed since the plan was made: nothing written."
            }
        }
    }

    /// The changes, by document id then rule id. Reads only.
    public static func plan(db: Database) throws -> Plan {
        var documents: [DocumentChange] = []
        for document in try EvidenceDocument.filter(Column("kind") == DocumentKind.mortgageNotice.rawValue).order(Column("id")).fetchAll(db) {
            guard let id = document.id, let change = change(for: document, id: id) else { continue }
            documents.append(change)
        }
        var requirements: [RequirementChange] = []
        for requirement in try EvidenceRequirement.order(Column("id")).fetchAll(db) {
            guard let id = requirement.id, let kinds = widened(requirement.kinds) else { continue }
            requirements.append(RequirementChange(requirementId: id, name: requirement.name, oldKinds: requirement.kinds, newKinds: kinds))
        }
        return Plan(documents: documents, requirements: requirements)
    }

    /// Writes `plan` (call inside one write transaction): every record must still be as planned,
    /// else it throws and the caller's transaction rolls back.
    public static func apply(db: Database, _ plan: Plan) throws {
        for planned in plan.documents {
            guard var document = try EvidenceDocument.fetchOne(db, key: planned.documentId), document.kind == .mortgageNotice,
                  change(for: document, id: planned.documentId) == planned else { throw Failure.documentChanged(planned.documentId) }
            document.kind = .mortgageReceipt
            document.canonicalName = planned.newCanonicalName
            try document.update(db)
        }
        for planned in plan.requirements {
            guard var requirement = try EvidenceRequirement.fetchOne(db, key: planned.requirementId),
                  requirement.kinds == planned.oldKinds else { throw Failure.requirementChanged(planned.requirementId) }
            requirement.kinds = planned.newKinds
            try EvidenceRequirements.save(db: db, &requirement)
        }
    }

    /// A notice that is a receipt: its text says so, or (text telling nothing) its file name.
    static func change(for document: EvidenceDocument, id: Int64) -> DocumentChange? {
        let byText = document.extractedText.map { DocumentClassifier.classify(text: $0, fileName: "") }
        let reason: Reason
        if byText == .mortgageReceipt {
            reason = .text
        } else if byText == nil || byText == .other,
                  DocumentClassifier.classify(text: nil, fileName: document.originalFileName) == .mortgageReceipt {
            reason = .fileName
        } else {
            return nil
        }
        let date = document.docDate ?? EvidenceDateParser.fileNameDate(document.originalFileName) ?? document.addedAt
        let instalment = MortgageReceipt.instalment(text: document.extractedText, fileName: document.originalFileName)
        let name = MortgageReceipt.canonicalName(date: date, instalment: instalment, amountMinorUnits: document.amountMinorUnits,
                                                 currency: document.currency)
        return DocumentChange(documentId: id, originalFileName: document.originalFileName, oldCanonicalName: document.canonicalName,
                              newCanonicalName: name, reason: reason)
    }

    /// `kinds` with a receipt beside each notice, or nil when nothing changes.
    static func widened(_ kinds: [DocumentKind]) -> [DocumentKind]? {
        guard let notice = kinds.firstIndex(of: .mortgageNotice), !kinds.contains(.mortgageReceipt) else { return nil }
        var result = kinds
        result.insert(.mortgageReceipt, at: notice + 1)
        return result
    }
}
