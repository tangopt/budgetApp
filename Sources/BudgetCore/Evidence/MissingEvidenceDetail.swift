import Foundation

// The Missing evidence side panel's reads (spec 2026-10-26): every document attached to an
// item's record with why it doesn't count when it doesn't, and the library documents that
// could satisfy it.

extension MissingEvidence {
    /// Why a document attached to an item's record doesn't count for it.
    public enum Shortfall: Equatable, Sendable {
        /// Its kind isn't one the rule accepts.
        case wrongKind
        /// A periodic item: it has no date or period to place it in the item's slot.
        case notInPeriod

        /// "not one of the kinds this needs".
        public var text: String {
            switch self {
            case .wrongKind: return "not one of the kinds this needs"
            case .notInPeriod: return "has no date or period in this one"
            }
        }
    }

    /// A document attached to the item's record: one that counts for it (`shortfall` nil), or
    /// one that doesn't and why.
    public struct AttachedDocument: Equatable, Identifiable, Sendable {
        public var document: EvidenceDocumentSummary
        /// Its kind's name, a custom kind's included.
        public var kindName: String
        public var shortfall: Shortfall?

        public var id: Int64 { document.id }
        public var counts: Bool { shortfall == nil }

        /// "Attached: Bank debit advice — not one of the kinds this needs"; nil when it counts.
        public var explanation: String? {
            shortfall.map { "Attached: \(kindName) — \($0.text)" }
        }
    }

    /// The documents attached to the item's record, the ones that count first (as the
    /// checklist lists them), then the others with why they don't (`Item.otherDocuments`).
    public static func attached(_ item: Item, catalog: DocumentKindCatalog) -> [AttachedDocument] {
        let counting = item.satisfyingDocuments.map {
            AttachedDocument(document: $0, kindName: kindName($0.kindRef, item, catalog), shortfall: nil)
        }
        let others = item.otherDocuments.map { document in
            AttachedDocument(document: document, kindName: kindName(document.kindRef, item, catalog),
                             shortfall: item.requirement.accepts(document.kindRef) ? .notInPeriod : .wrongKind)
        }
        return counting + others
    }

    /// Whether a linked document that doesn't count belongs on this item's list: every one for a
    /// transaction or a record; for a periodic item's slot, only those dated in it (or with no date
    /// at all) — the others are other slots' documents.
    static func isAttachedElsewhereNotHere(_ document: EvidenceDocumentSummary, slot: DateInterval?) -> Bool {
        guard let slot else { return false }
        if document.docDate == nil, document.periodStart == nil, document.periodEnd == nil { return false }
        return !covers(document, slot: slot)
    }

    /// The library documents that could satisfy the item, best first: the matcher's own for its
    /// transaction (`matched`: `EvidenceMatcher.documentSuggestions`) of a kind the rule takes,
    /// then the checklist's `candidates` (an expected kind, dated near it or in its slot, its
    /// amount sign-free) not already shown. `excluding` (already linked) is left out.
    public static func suggestions(for item: Item, summaries: [EvidenceDocumentSummary], matched: [EvidenceMatcher.DocumentSuggestion],
                                   excluding: Set<Int64> = [], limit: Int = 8) -> [Candidate] {
        let byId = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ranked = matched.filter { suggestion in
            !excluding.contains(suggestion.documentId) && (byId[suggestion.documentId].map { item.requirement.accepts($0.kindRef) } ?? false)
        }
        .map { Candidate(documentId: $0.documentId, score: $0.score, reasons: $0.reasons) }
        let shown = Set(ranked.map(\.documentId))
        let more = candidates(for: item, documents: summaries, excluding: excluding.union(shown), limit: limit)
        return Array((ranked + more).prefix(limit))
    }
}
