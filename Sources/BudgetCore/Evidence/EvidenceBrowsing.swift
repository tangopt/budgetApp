import GRDB
import Foundation

// The Documents screen's and Edit transaction's reads and edits of the evidence library
// (spec 2026-10-16 §2–§3): editing a document's details, searching and
// filtering the library, and proposing documents for a transaction.

// MARK: - Editing a document's details

/// What the user can change about a document (the file itself never changes): kind, dates,
/// period, amount and currency, persons, note and canonical name.
public struct EvidenceDocumentDetails: Equatable, Sendable {
    public var kind: DocumentKind
    /// The custom kind, when `kind` is `.other` and the document is of one.
    public var customKindId: Int64?
    public var docDate: Date?
    public var periodStart: Date?
    public var periodEnd: Date?
    /// Sign-free; needs a `currency`.
    public var amountMinorUnits: Int?
    public var currency: Currency?
    public var persons: [String]
    public var note: String?
    public var canonicalName: String?

    public init(kind: DocumentKind = .other, docDate: Date? = nil, periodStart: Date? = nil, periodEnd: Date? = nil,
                amountMinorUnits: Int? = nil, currency: Currency? = nil, persons: [String] = [], note: String? = nil,
                canonicalName: String? = nil, customKindId: Int64? = nil) {
        self.kind = kind
        self.customKindId = customKindId
        self.docDate = docDate
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.amountMinorUnits = amountMinorUnits
        self.currency = currency
        self.persons = persons
        self.note = note
        self.canonicalName = canonicalName
    }

    public init(_ document: EvidenceDocument) {
        self.init(kind: document.kind, docDate: document.docDate, periodStart: document.periodStart, periodEnd: document.periodEnd,
                  amountMinorUnits: document.amountMinorUnits, currency: document.currency, persons: document.persons,
                  note: document.note, canonicalName: document.canonicalName, customKindId: document.customKindId)
    }

    public init(_ summary: EvidenceDocumentSummary) {
        self.init(kind: summary.kind, docDate: summary.docDate, periodStart: summary.periodStart, periodEnd: summary.periodEnd,
                  amountMinorUnits: summary.amountMinorUnits, currency: summary.currency, persons: summary.persons,
                  note: summary.note, canonicalName: summary.canonicalName, customKindId: summary.customKindId)
    }

    /// The kind, built-in or custom; setting it sets `kind` and `customKindId` together.
    public var kindRef: DocumentKindRef {
        // A built-in kind other than Other wins, as Save files it (`updateDetails`).
        get { kind == .other ? customKindId.map(DocumentKindRef.custom) ?? .builtIn(.other) : .builtIn(kind) }
        set {
            switch newValue {
            case .builtIn(let kind):
                self.kind = kind
                customKindId = nil
            case .custom(let id):
                kind = .other
                customKindId = id
            }
        }
    }

    /// "Ana, Bruno" → ["Ana", "Bruno"]: split on commas and semicolons, trimmed, blanks and
    /// repeats dropped.
    public static func persons(from text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

public enum EvidenceDetailsError: Error, Equatable, LocalizedError {
    case periodEndsBeforeStart
    case amountWithoutCurrency

    public var errorDescription: String? {
        switch self {
        case .periodEndsBeforeStart: return "The period ends before it starts."
        case .amountWithoutCurrency: return "Choose the amount's currency."
        }
    }
}

extension EvidenceLibrary {
    public func document(id: Int64) throws -> EvidenceDocument? {
        try database.read { db in try EvidenceDocument.fetchOne(db, key: id) }
    }

    /// Saves `details` on the document: the amount sign-free, persons trimmed, a blank note
    /// or name cleared. A period ending before it starts, or an amount without a currency, is
    /// refused.
    @discardableResult
    public func updateDetails(_ documentId: Int64, _ details: EvidenceDocumentDetails) throws -> EvidenceDocument {
        if let start = details.periodStart, let end = details.periodEnd, end < start { throw EvidenceDetailsError.periodEndsBeforeStart }
        if details.amountMinorUnits != nil, details.currency == nil { throw EvidenceDetailsError.amountWithoutCurrency }
        return try database.write { db in
            guard var document = try EvidenceDocument.fetchOne(db, key: documentId) else { throw EvidenceLibraryError.documentNotFound }
            document.kind = details.kind
            // A built-in kind chosen clears the custom one; a custom kind is filed as Other.
            document.customKindId = details.kind == .other ? details.customKindId : nil
            document.docDate = details.docDate
            document.periodStart = details.periodStart
            document.periodEnd = details.periodEnd
            document.amountMinorUnits = details.amountMinorUnits.map(abs)
            document.currency = details.amountMinorUnits == nil ? nil : details.currency
            document.persons = EvidenceDocumentDetails.persons(from: details.persons.joined(separator: ","))
            document.note = Transaction.normalizedNote(details.note)
            document.canonicalName = Transaction.normalizedNote(details.canonicalName)
            try document.update(db)
            return document
        }
    }

    /// Moves every link `fromDocumentId` has to `toDocumentId` (same records and roles), in
    /// one write — a new version of a changed file takes over what the old one stood for.
    /// Where `toDocumentId` already links to a record, its own link is kept. Returns how many
    /// links it gained.
    @discardableResult
    public func moveLinks(from fromDocumentId: Int64, to toDocumentId: Int64, now: Date = Date()) throws -> Int {
        guard fromDocumentId != toDocumentId else { return 0 }
        return try database.write { db in
            guard try EvidenceDocument.exists(db, key: fromDocumentId), try EvidenceDocument.exists(db, key: toDocumentId) else {
                throw EvidenceLibraryError.documentNotFound
            }
            try db.execute(sql: """
                INSERT OR IGNORE INTO documentLink (documentId, entityType, entityId, role, createdAt)
                SELECT ?, entityType, entityId, role, ? FROM documentLink WHERE documentId = ? ORDER BY id
                """, arguments: [toDocumentId, EvidenceLinks.wholeSeconds(now), fromDocumentId])
            let gained = db.changesCount
            try DocumentLink.filter(Column("documentId") == fromDocumentId).deleteAll(db)
            return gained
        }
    }
}

// MARK: - Searching the library

/// The Documents screen's list: every document with what its filters need, searched by name,
/// kind, note, persons and text, and filtered by kind, year, account, links and source folder.
public enum EvidenceDocumentSearch {
    public enum LinkState: String, CaseIterable, Sendable {
        case any, linked, unlinked
    }

    public struct Filter: Equatable, Sendable {
        /// Words that must all appear (case- and accent-insensitive), or an amount it states.
        public var text: String
        /// A built-in kind (`.other`: documents of no kind, not custom ones) or a custom kind.
        public var kind: DocumentKindRef?
        /// The year of the document's date (else its period's end), in UTC like every stored day.
        public var year: Int?
        /// Linked to a transaction in this account, or to the account itself.
        public var accountId: Int64?
        public var linkState: LinkState
        public var sourceFolderId: Int64?

        public init(text: String = "", kind: DocumentKindRef? = nil, year: Int? = nil, accountId: Int64? = nil,
                    linkState: LinkState = .any, sourceFolderId: Int64? = nil) {
            self.text = text
            self.kind = kind
            self.year = year
            self.accountId = accountId
            self.linkState = linkState
            self.sourceFolderId = sourceFolderId
        }

        public var isDefault: Bool { self == Filter() }
        /// Anything but the text is set.
        public var hasFilters: Bool { kind != nil || year != nil || accountId != nil || linkState != .any || sourceFolderId != nil }
    }

    public struct Entry: Identifiable, Equatable, Sendable {
        public let summary: EvidenceDocumentSummary
        /// Links to anything, and to transactions.
        public let linkCount: Int
        public let transactionLinkCount: Int
        /// The accounts of its linked transactions, and accounts it links to directly.
        public let accountIds: Set<Int64>
        public let year: Int?
        /// Name, file name, kind, note, persons, source path and text, folded.
        let haystack: String

        public var id: Int64 { summary.id }
    }

    public struct Index: Sendable {
        /// Newest added first.
        public let entries: [Entry]
        /// Names and areas of the kinds, custom ones included, as they were read.
        public let catalog: DocumentKindCatalog

        public init(entries: [Entry], catalog: DocumentKindCatalog = DocumentKindCatalog(customKinds: [])) {
            self.entries = entries
            self.catalog = catalog
        }

        /// Reads every document (the first `indexedTextLength` characters of its text) with its links.
        public init(db: Database) throws {
            catalog = try DocumentKindCatalog.load(db: db)
            entries = try EvidenceDocumentSearch.entries(db: db, ids: nil, catalog: catalog)
        }

        /// The index with `documentIds`' entries re-read (after an edit or a link change),
        /// keeping its order; a document that's gone is dropped, a new one goes first.
        public func updating(db: Database, documentIds: [Int64]) throws -> Index {
            guard !documentIds.isEmpty else { return self }
            let catalog = try DocumentKindCatalog.load(db: db)
            let fresh = try EvidenceDocumentSearch.entries(db: db, ids: documentIds, catalog: catalog)
            var byId = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let wanted = Set(documentIds)
            var updated: [Entry] = []
            for entry in entries {
                if wanted.contains(entry.id) {
                    if let replacement = byId.removeValue(forKey: entry.id) { updated.append(replacement) }
                } else {
                    updated.append(entry)
                }
            }
            return Index(entries: fresh.filter { byId[$0.id] != nil } + updated, catalog: catalog)
        }

        /// The years documents are dated in, latest first.
        public var years: [Int] {
            Set(entries.compactMap(\.year)).sorted(by: >)
        }

        /// The kinds present: built-ins in declaration order, then custom kinds by name.
        public var kinds: [DocumentKindRef] {
            let present = Set(entries.map(\.summary.kindRef))
            return DocumentKind.allCases.map(DocumentKindRef.builtIn).filter(present.contains)
                + catalog.customKinds.compactMap { $0.id.map(DocumentKindRef.custom) }.filter(present.contains)
        }
    }

    /// How much of a document's text search looks at (the start of a long statement is
    /// enough, and keeps the index small).
    public static let indexedTextLength = 20_000

    /// Entries for every document (`ids` nil) or for `ids`, newest added first.
    static func entries(db: Database, ids: [Int64]?, catalog: DocumentKindCatalog) throws -> [Entry] {
        let idList = ids.map { $0.map(String.init).joined(separator: ",") }
        let documentFilter = idList.map { " AND documentId IN (\($0))" } ?? ""
        let summaries = try (ids.map { EvidenceDocumentSummary.newestFirst.filter(keys: $0) } ?? EvidenceDocumentSummary.newestFirst).fetchAll(db)
        var texts: [Int64: String] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT id, substr(extractedText, 1, ?) FROM document WHERE extractedText IS NOT NULL\(idList.map { " AND id IN (\($0))" } ?? "")
            """, arguments: [indexedTextLength]) {
            texts[row[0]] = row[1]
        }
        var linkCounts: [Int64: Int] = [:], transactionCounts: [Int64: Int] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT documentId, entityType, COUNT(*) FROM documentLink WHERE 1\(documentFilter) GROUP BY documentId, entityType
            """) {
            let id: Int64 = row[0], type: String = row[1], count: Int = row[2]
            linkCounts[id, default: 0] += count
            if type == EvidenceEntityType.transaction.rawValue { transactionCounts[id, default: 0] += count }
        }
        var accounts: [Int64: Set<Int64>] = [:]
        let joinedFilter = idList.map { " AND l.documentId IN (\($0))" } ?? ""
        for row in try Row.fetchAll(db, sql: """
            SELECT l.documentId, t.accountId FROM documentLink l JOIN transaction_ t ON t.id = l.entityId
            WHERE l.entityType = ?\(joinedFilter)
            UNION SELECT documentId, entityId FROM documentLink WHERE entityType = ?\(documentFilter)
            """, arguments: [EvidenceEntityType.transaction.rawValue, EvidenceEntityType.account.rawValue]) {
            accounts[row[0], default: []].insert(row[1])
        }
        return summaries.map { summary in
            Entry(summary: summary, linkCount: linkCounts[summary.id] ?? 0, transactionLinkCount: transactionCounts[summary.id] ?? 0,
                  accountIds: accounts[summary.id] ?? [], year: year(of: summary),
                  haystack: haystack(summary, kindName: catalog.displayName(summary.kindRef), text: texts[summary.id]))
        }
    }

    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func year(of summary: EvidenceDocumentSummary) -> Int? {
        (summary.docDate ?? summary.periodEnd ?? summary.periodStart).map { utcCalendar.component(.year, from: $0) }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func haystack(_ summary: EvidenceDocumentSummary, kindName: String, text: String?) -> String {
        [summary.canonicalName ?? "", summary.originalFileName, kindName, summary.note ?? "",
         summary.persons.joined(separator: " "), summary.sourceRelativePath ?? "", text ?? ""]
            .map(fold).joined(separator: "\u{1}")
    }

    /// The entries matching `filter`, in the index's order (newest added first).
    public static func entries(_ index: Index, filter: Filter) -> [Entry] {
        let terms = filter.text.split(whereSeparator: \.isWhitespace).map { word in
            (folded: fold(String(word)), amount: TransactionSearch.amountToken(String(word)))
        }
        return index.entries.filter { entry in
            let summary = entry.summary
            if let kind = filter.kind, summary.kindRef != kind { return false }
            if let year = filter.year, entry.year != year { return false }
            if let accountId = filter.accountId, !entry.accountIds.contains(accountId) { return false }
            if let folderId = filter.sourceFolderId, summary.sourceFolderId != folderId { return false }
            switch filter.linkState {
            case .any: break
            case .linked: if entry.linkCount == 0 { return false }
            case .unlinked: if entry.linkCount > 0 { return false }
            }
            for term in terms {
                let amountMatches = term.amount != nil && summary.amountMinorUnits.map(abs) == term.amount
                if !amountMatches && !entry.haystack.contains(term.folded) { return false }
            }
            return true
        }
    }
}

// MARK: - Documents for a transaction

extension EvidenceMatcher {
    /// A document proposed for a transaction (Edit transaction's Link document…).
    public struct DocumentSuggestion: Equatable, Sendable {
        public var documentId: Int64
        public var score: Int
        public var reasons: [String]
        public var amountMatched: Bool
        public var dateInWindow: Bool
    }

    /// The documents that would propose `transactionId` (`suggestions` among the documents'
    /// own top candidates from `index`, every transaction considered), best first; documents
    /// already linked to it are left out.
    public static func documentSuggestions(for transactionId: Int64, documents: [EvidenceDocument], index: Index,
                                           excluding linkedDocumentIds: Set<Int64> = [], limit: Int = 10) -> [DocumentSuggestion] {
        let ranked: [(suggestion: DocumentSuggestion, date: Date)] = documents.compactMap { document in
            guard let documentId = document.id, !linkedDocumentIds.contains(documentId),
                  let match = suggestions(document: document, index: index, limit: 10).first(where: { $0.transactionId == transactionId })
            else { return nil }
            return (DocumentSuggestion(documentId: documentId, score: match.score, reasons: match.reasons,
                                       amountMatched: match.amountMatched, dateInWindow: match.dateInWindow),
                    document.docDate ?? document.addedAt)
        }
        return ranked.sorted { ($0.suggestion.score, $0.date, $0.suggestion.documentId) > ($1.suggestion.score, $1.date, $1.suggestion.documentId) }
            .prefix(limit).map(\.suggestion)
    }
}

// MARK: - Staged link changes

/// Documents to link to and unlink from one record, applied together (Edit transaction's
/// Save, inside the transaction's own write).
public struct EvidenceLinkChanges: Equatable, Sendable {
    /// In the order they were staged.
    public var link: [Int64]
    public var unlink: [Int64]

    public init(link: [Int64] = [], unlink: [Int64] = []) {
        self.link = link
        self.unlink = unlink
    }

    public var isEmpty: Bool { link.isEmpty && unlink.isEmpty }

    /// Unlinks, then links (a document that's gone is refused, rolling the write back).
    public func apply(db: Database, to entity: EvidenceEntity) throws {
        for documentId in unlink {
            try EvidenceLinks.unlink(db: db, documentId: documentId, from: entity)
        }
        for documentId in link {
            try EvidenceLinks.link(db: db, documentId: documentId, to: entity)
        }
    }
}

/// A record's documents while they're being edited: the saved links, plus links and unlinks
/// staged until Save. Staging the opposite of a staged change undoes it.
public struct EvidenceLinkStaging: Equatable, Sendable {
    /// Linked when editing began, in their order.
    public private(set) var saved: [Int64]
    public private(set) var pendingLinks: [Int64] = []
    public private(set) var pendingUnlinks: Set<Int64> = []

    public init(saved: [Int64]) {
        self.saved = saved
    }

    /// Stages a link (or undoes a staged unlink of a saved one); nothing if already linked.
    public mutating func stageLink(_ documentId: Int64) {
        if saved.contains(documentId) {
            pendingUnlinks.remove(documentId)
        } else if !pendingLinks.contains(documentId) {
            pendingLinks.append(documentId)
        }
    }

    /// Unlink, or Undo: a staged link is dropped; a saved link's unlink is staged or undone.
    public mutating func toggleUnlink(_ documentId: Int64) {
        if let index = pendingLinks.firstIndex(of: documentId) {
            pendingLinks.remove(at: index)
        } else if saved.contains(documentId) {
            if pendingUnlinks.contains(documentId) { pendingUnlinks.remove(documentId) } else { pendingUnlinks.insert(documentId) }
        }
    }

    /// Linked once Save applies the staged changes.
    public func isLinked(_ documentId: Int64) -> Bool {
        (saved.contains(documentId) && !pendingUnlinks.contains(documentId)) || pendingLinks.contains(documentId)
    }

    public func willUnlink(_ documentId: Int64) -> Bool { pendingUnlinks.contains(documentId) }
    public func willLink(_ documentId: Int64) -> Bool { pendingLinks.contains(documentId) }

    /// Saved first (unlinking ones included, to show Undo), then staged links.
    public var shownIds: [Int64] { saved + pendingLinks }

    public var hasChanges: Bool { !pendingLinks.isEmpty || !pendingUnlinks.isEmpty }

    public var changes: EvidenceLinkChanges {
        EvidenceLinkChanges(link: pendingLinks, unlink: saved.filter(pendingUnlinks.contains))
    }
}
