import Foundation
import GRDB

// The Missing evidence screen's helpers (spec 2026-10-16 §7): the tax years it offers,
// searching and filtering the checklist, documents worth offering for an item, and what a
// document dropped on an item needs to count for it.

extension UKTaxYear {
    public var previous: UKTaxYear { UKTaxYear(startYear: startYear - 1) }
    public var next: UKTaxYear { UKTaxYear(startYear: startYear + 1) }

    /// The tax years from `earliest` through the one containing `now`, latest first (just
    /// the current one when `earliest` is later).
    public static func pickerYears(earliest: UKTaxYear, now: Date = Date()) -> [UKTaxYear] {
        let current = containing(now)
        let first = min(earliest, current)
        return (first.startYear...current.startYear).reversed().map(UKTaxYear.init(startYear:))
    }
}

extension MissingEvidence {
    /// `[firstDay, lastDay + 1 day)`: a custom range picked as whole UTC days, or `nil` when
    /// it ends before it starts.
    public static func period(from firstDay: Date, through lastDay: Date) -> DateInterval? {
        guard lastDay >= firstDay, let end = UKTaxYear.utcCalendar.date(byAdding: .day, value: 1, to: lastDay) else { return nil }
        return DateInterval(start: firstDay, end: end)
    }

    // MARK: Filtering

    /// The items to show: only missing ones when `missingOnly`, matching every word of
    /// `text` (case- and accent-insensitive) in the title, requirement, category, account,
    /// source, expected kinds, satisfying documents or waiver note — or an amount equal to the
    /// expected one. Order is kept.
    public static func filtered(_ items: [Item], missingOnly: Bool, text: String) -> [Item] {
        let terms = text.split(whereSeparator: \.isWhitespace).map { word in
            (folded: fold(String(word)), amount: TransactionSearch.amountToken(String(word)))
        }
        return items.filter { item in
            if missingOnly, item.isDone { return false }
            guard !terms.isEmpty else { return true }
            let haystack = haystack(item)
            return terms.allSatisfy { term in
                (term.amount != nil && item.expectedAmountMinorUnits == term.amount) || haystack.contains(term.folded)
            }
        }
    }

    private static func kindName(_ ref: DocumentKindRef, _ item: Item, _ catalog: DocumentKindCatalog?) -> String {
        if let index = item.expectedKindRefs.firstIndex(of: ref) { return item.expectedKindNames[index] }
        switch ref {
        case .builtIn(let kind): return kind.displayName
        case .custom: return catalog?.displayName(ref) ?? "a custom kind"
        }
    }

    private static func haystack(_ item: Item) -> String {
        var parts = [item.title, item.requirement.name, item.categoryName ?? "", item.accountName ?? "", item.sourceName]
        parts += item.expectedKindNames
        parts += item.satisfyingDocuments.map(\.displayName)
        parts.append(item.waiver?.note ?? "")
        return parts.map(fold).joined(separator: "\u{1}")
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // MARK: Candidates

    /// A library document offered for an item (Link existing…).
    public struct Candidate: Equatable, Sendable {
        public var documentId: Int64
        public var score: Int
        public var reasons: [String]

        public init(documentId: Int64, score: Int, reasons: [String]) {
            self.documentId = documentId
            self.score = score
            self.reasons = reasons
        }
    }

    /// Library documents that may be the evidence an item needs, best first: of an expected
    /// kind (any kind when it accepts any), and — for an item with a date, slot or amount —
    /// dated near it, covering its slot or stating its amount. `excluding` (already linked)
    /// is left out.
    public static func candidates(for item: Item, documents: [EvidenceDocumentSummary], excluding: Set<Int64> = [],
                                  limit: Int = 8) -> [Candidate] {
        let calendar = UKTaxYear.utcCalendar
        let kindScore = item.expectedKindRefs.isEmpty ? 0 : 20
        let hasAnchor = item.expectedDate != nil || item.expectedPeriod != nil || item.expectedAmountMinorUnits != nil
        let ranked: [(candidate: Candidate, date: Date)] = documents.compactMap { document in
            guard !excluding.contains(document.id), item.requirement.accepts(document.kindRef) else { return nil }
            var score = kindScore, reasons: [String] = []
            if kindScore > 0 {
                let ref = document.kindRef
                reasons.append(item.expectedKindRefs.firstIndex(of: ref).map { item.expectedKindNames[$0] } ?? document.kind.displayName)
            }
            if let slot = item.expectedPeriod, covers(document, slot: slot) {
                score += 100
                reasons.append(document.periodStart != nil ? "Covers the period" : "Dated in the period")
            }
            if let expected = item.expectedDate {
                if let date = document.docDate {
                    let days = abs(calendar.dateComponents([.day], from: expected, to: date).day ?? .max)
                    if days <= 45 {
                        score += 60 - days
                        reasons.append(days == 0 ? "Same day" : "\(days) day\(days == 1 ? "" : "s") apart")
                    }
                } else if let start = document.periodStart, expected >= start,
                          expected < calendar.date(byAdding: .day, value: 1, to: max(document.periodEnd ?? start, start))! {
                    score += 50
                    reasons.append("Its period covers the date")
                }
            }
            if let amount = item.expectedAmountMinorUnits, document.amountMinorUnits.map(abs) == amount,
               item.currency == nil || document.currency == nil || item.currency == document.currency {
                score += 80
                reasons.append("Same amount")
            }
            guard hasAnchor ? score > kindScore : kindScore > 0 else { return nil }
            return (Candidate(documentId: document.id, score: score, reasons: reasons), document.docDate ?? document.addedAt)
        }
        return ranked.sorted { ($0.candidate.score, $0.date, $0.candidate.documentId) > ($1.candidate.score, $1.date, $1.candidate.documentId) }
            .prefix(limit).map(\.candidate)
    }

    // MARK: Dropped documents

    /// A document's details completed so it counts for `item` once linked, and what was
    /// filled in: a document of unknown kind (`other`, no custom kind) gets the item's first
    /// expected kind, built-in or custom;
    /// one with no date or period, dropped on a periodic item, gets the slot as its period.
    /// Anything the document already states is kept.
    public static func filledIn(_ details: EvidenceDocumentDetails, for item: Item) -> (details: EvidenceDocumentDetails, filled: [String]) {
        var details = details, filled: [String] = []
        if !item.requirement.accepts(details.kindRef), details.kindRef == .builtIn(.other), let kind = item.expectedKindRefs.first {
            details.kindRef = kind
            filled.append("kind \(item.expectedKindNames.first ?? DocumentKind.other.displayName)")
        }
        if let slot = item.expectedPeriod, details.docDate == nil, details.periodStart == nil, details.periodEnd == nil {
            details.periodStart = slot.start
            details.periodEnd = UKTaxYear.utcCalendar.date(byAdding: .day, value: -1, to: slot.end) ?? slot.start
            filled.append("period \(day(slot.start)) to \(day(details.periodEnd!))")
        }
        return (details, filled)
    }

    /// Why a document with `details`, linked to the item's record, still wouldn't count for
    /// it, or `nil` when it would: the wrong kind, or (periodic items) dated outside the slot.
    /// A custom kind is named from `catalog` (else "a custom kind" unless the item names it).
    public static func shortfall(of details: EvidenceDocumentDetails, for item: Item, catalog: DocumentKindCatalog? = nil) -> String? {
        if !item.requirement.accepts(details.kindRef) {
            let needs = item.expectedKindNames.joined(separator: " or ")
            return "it's filed as \(kindName(details.kindRef, item, catalog)) and this needs \(needs)"
        }
        if let slot = item.expectedPeriod,
           !covers(periodStart: details.periodStart, periodEnd: details.periodEnd, docDate: details.docDate, slot: slot) {
            let last = UKTaxYear.utcCalendar.date(byAdding: .day, value: -1, to: slot.end) ?? slot.start
            return "its date isn't in \(day(slot.start)) to \(day(last))"
        }
        return nil
    }

    /// What linking a document to an item did.
    public struct LinkOutcome: Sendable {
        /// The document as saved (its filled-in details included).
        public var document: EvidenceDocument
        /// What `filledIn` set on it.
        public var filled: [String]
        /// Why it still doesn't count for the item, if it doesn't.
        public var shortfall: String?
    }

    /// Links a document to the item's record and fills in what it needs to count
    /// (`filledIn`), in the caller's one write.
    /// On a transaction, a link (with what it fills in) that would move a filed or paid return is
    /// refused (`EvidenceLinkGuard`).
    public static func link(db: Database, documentId: Int64, to item: Item) throws -> LinkOutcome {
        guard item.target.entity.type == .transaction else { return try linking(db: db, documentId: documentId, to: item) }
        return try EvidenceLinkGuard.checked(db: db) { try linking(db: db, documentId: documentId, to: item) }
    }

    private static func linking(db: Database, documentId: Int64, to item: Item) throws -> LinkOutcome {
        try EvidenceLinks.link(db: db, documentId: documentId, to: item.target.entity)
        guard var document = try EvidenceDocument.fetchOne(db, key: documentId) else { throw EvidenceLibraryError.documentNotFound }
        let (details, filled) = filledIn(EvidenceDocumentDetails(document), for: item)
        if !filled.isEmpty {
            document.kind = details.kind
            document.customKindId = details.kind == .other ? details.customKindId : nil
            document.periodStart = details.periodStart
            document.periodEnd = details.periodEnd
            try document.update(db)
        }
        return LinkOutcome(document: document, filled: filled, shortfall: shortfall(of: details, for: item, catalog: try DocumentKindCatalog.load(db: db)))
    }
}
