import GRDB
import Foundation

/// One-off (`ReclassifyNewKinds`): before `DocumentKind.repairInvoice` and `.stampDuty` existed,
/// repair bills and stamp-duty notes were filed as `other`. Files each library document of kind
/// `other` that its text (or, without a telling text, its original file name) shows to be one of
/// them (`DocumentClassifier`) under that kind, with a canonical name of the new type; and, when
/// asked, narrows each evidence rule on a "Repairs" category that accepts any document (`[]`) to
/// the given kinds (the user chose `[.repairInvoice, .other]`, 2026-10-24). Documents of any other
/// kind are never touched; no transaction, figure or tax year is. Library files are stored by
/// content hash, so no file moves. Writes go through the records' saves, so the sync
/// change-tracking triggers record them.
public enum NewKindsReclassification {
    /// The kinds this pass files `other` documents under.
    public static let newKinds: Set<DocumentKind> = [.repairInvoice, .stampDuty]

    /// What marked a document as one of the new kinds.
    public enum Reason: String, Equatable, Sendable {
        case text, fileName
    }

    public struct DocumentChange: Equatable, Sendable {
        public var documentId: Int64
        public var originalFileName: String
        public var newKind: DocumentKind
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
        /// Something the plan didn't see appeared (a document or a rule to change).
        case planOutOfDate

        public var errorDescription: String? {
            switch self {
            case .documentChanged(let id): return "Document #\(id) changed since the plan was made: nothing written."
            case .requirementChanged(let id): return "Evidence rule #\(id) changed since the plan was made: nothing written."
            case .planOutOfDate: return "The database changed since the plan was made: nothing written. Run the dry run again."
            }
        }
    }

    /// The changes, by document id then rule id. Reads only. `repairsRuleKinds`: the kinds a
    /// "Repairs" rule accepting any document gets (nil: rules untouched).
    public static func plan(db: Database, repairsRuleKinds: [DocumentKind]?) throws -> Plan {
        var documents: [DocumentChange] = []
        for document in try EvidenceDocument.filter(Column("kind") == DocumentKind.other.rawValue).order(Column("id")).fetchAll(db) {
            guard let id = document.id, let change = change(for: document, id: id) else { continue }
            documents.append(change)
        }
        var requirements: [RequirementChange] = []
        if let repairsRuleKinds, !repairsRuleKinds.isEmpty {
            let repairCategories = try repairCategoryIds(db: db)
            for requirement in try EvidenceRequirement.order(Column("id")).fetchAll(db) {
                guard let id = requirement.id, requirement.kinds.isEmpty, requirement.customKindIds.isEmpty, isRepairs(requirement.scope, repairCategories) else { continue }
                requirements.append(RequirementChange(requirementId: id, name: requirement.name, oldKinds: requirement.kinds,
                                                      newKinds: repairsRuleKinds))
            }
        }
        return Plan(documents: documents, requirements: requirements)
    }

    /// Writes `plan` (call inside one write transaction): every record must still be as planned,
    /// else it throws and the caller's transaction rolls back.
    public static func apply(_ plan: Plan, db: Database) throws {
        for planned in plan.documents {
            guard var document = try EvidenceDocument.fetchOne(db, key: planned.documentId), document.kind == .other,
                  change(for: document, id: planned.documentId) == planned else { throw Failure.documentChanged(planned.documentId) }
            document.kind = planned.newKind
            document.canonicalName = planned.newCanonicalName
            try document.update(db)
        }
        let repairCategories = try repairCategoryIds(db: db)
        for planned in plan.requirements {
            guard var requirement = try EvidenceRequirement.fetchOne(db, key: planned.requirementId),
                  requirement.kinds == planned.oldKinds, requirement.customKindIds.isEmpty, isRepairs(requirement.scope, repairCategories)
            else { throw Failure.requirementChanged(planned.requirementId) }
            requirement.kinds = planned.newKinds
            try EvidenceRequirements.save(db: db, &requirement)
        }
    }

    /// `apply`, after checking that a plan made now is `plan` (nothing new appeared since the
    /// dry run either). Call inside one write transaction.
    public static func applyIfCurrent(_ plan: Plan, db: Database, repairsRuleKinds: [DocumentKind]?) throws {
        let current = try self.plan(db: db, repairsRuleKinds: repairsRuleKinds)
        guard current == plan else {
            // Name the record that changed when it's one the plan knew.
            for planned in plan.documents where !current.documents.contains(planned) { throw Failure.documentChanged(planned.documentId) }
            for planned in plan.requirements where !current.requirements.contains(planned) { throw Failure.requirementChanged(planned.requirementId) }
            throw Failure.planOutOfDate
        }
        try apply(plan, db: db)
    }

    /// An `other` document that is a repair bill or stamp duty: its text says so, or (text
    /// telling nothing) its file name.
    static func change(for document: EvidenceDocument, id: Int64) -> DocumentChange? {
        let byText = document.extractedText.map { DocumentClassifier.classify(text: $0, fileName: "") }
        let kind: DocumentKind
        let reason: Reason
        if let byText, newKinds.contains(byText) {
            kind = byText
            reason = .text
        } else if byText == nil || byText == .other {
            let byName = DocumentClassifier.classify(text: nil, fileName: document.originalFileName)
            guard newKinds.contains(byName) else { return nil }
            kind = byName
            reason = .fileName
        } else {
            return nil
        }
        return DocumentChange(documentId: id, originalFileName: document.originalFileName, newKind: kind,
                              oldCanonicalName: document.canonicalName, newCanonicalName: canonicalName(of: document, as: kind),
                              reason: reason)
    }

    /// The name under `kind`: a canonical name's date and what follows its type (detail, period,
    /// amount) kept, with the new area and type; else built from the document's date, period and amount.
    static func canonicalName(of document: EvidenceDocument, as kind: DocumentKind) -> String {
        let area = ImportNaming.area(of: kind), type = kind.displayName
        if let old = document.canonicalName {
            let parts = old.components(separatedBy: " - ")
            if parts.count >= 4, parts[0].range(of: #"^\d{4}(\d{2}){0,2}$"#, options: .regularExpression) != nil {
                return ([parts[0], area, type] + parts[3...]).joined(separator: " - ")
            }
        }
        let date = document.docDate ?? EvidenceDateParser.fileNameDate(document.originalFileName) ?? document.addedAt
        let period = document.periodStart.map { (start: $0, end: document.periodEnd ?? $0) }
        return EvidenceNaming.canonicalName(date: date, area: area, type: type, period: period,
                                            amountMinorUnits: document.amountMinorUnits, currency: document.currency)
    }

    /// The categories named like "Repairs" (case and accent-insensitive), as the default rules read them.
    static func repairCategoryIds(db: Database) throws -> Set<Int64> {
        Set(try Category.fetchAll(db).compactMap { category -> Int64? in
            let folded = category.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            return folded.contains("repair") ? category.id : nil
        })
    }

    /// A rule on a Repairs category's transactions (alone, or with only Repairs categories).
    static func isRepairs(_ scope: EvidenceRequirementScope, _ repairCategories: Set<Int64>) -> Bool {
        switch scope {
        case .transactionsInCategory(let categoryId): return repairCategories.contains(categoryId)
        case .transactionsMatching(let categoryIds, _, _): return !categoryIds.isEmpty && categoryIds.allSatisfy(repairCategories.contains)
        default: return false
        }
    }
}
