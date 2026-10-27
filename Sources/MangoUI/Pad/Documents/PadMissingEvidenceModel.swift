import Foundation
import BudgetCore
import GRDB
import struct BudgetCore.Transaction

/// The iPad's Missing evidence (step 8, Task 10): the Mac's checklist for a UK tax year (`MissingEvidence.checklist`),
/// grouped by usual source, and a side panel for the selected item with the documents attached to its record
/// (`MissingEvidence.attached`, why each doesn't count when it doesn't) and the library documents that could satisfy it
/// (`MissingEvidence.suggestions`, the Mac's matcher included). "Link" is `MissingEvidence.link`, through the device
/// writer in Documents with the document-link origin (`EvidenceLinkGuard` inside it, filed years checked). Waivers and
/// rules stay on the Mac: nothing here edits them.
@MainActor
public final class PadMissingEvidenceModel: ObservableObject {
    /// The selected item's side panel, as read.
    public struct Panel: Equatable, Sendable {
        public var itemId: String
        public var attached: [MissingEvidence.AttachedDocument]
        public var suggestions: [Suggestion]
    }

    /// A library document that could satisfy the item, and why it was suggested.
    public struct Suggestion: Equatable, Identifiable, Sendable {
        public var document: EvidenceDocumentSummary
        public var kindName: String
        public var reasons: [String]
        public var id: Int64 { document.id }
    }

    /// What one read gives: the year's items and the kinds' names.
    public struct Snapshot: Equatable, Sendable {
        var items: [MissingEvidence.Item]
        var catalog: DocumentKindCatalog
        var years: [UKTaxYear]
        public static func == (a: Snapshot, b: Snapshot) -> Bool { a.items == b.items && a.years == b.years }
    }

    @Published public var year: UKTaxYear {
        didSet { if year != oldValue { Task { await reload() } } }
    }
    @Published public var missingOnly = false
    @Published public private(set) var years: [UKTaxYear]
    @Published public private(set) var items: [MissingEvidence.Item] = []
    @Published public private(set) var catalog = DocumentKindCatalog(customKinds: [])
    @Published public var selectedItemId: String? {
        didSet { if selectedItemId != oldValue { panel = nil; Task { await loadPanel() } } }
    }
    @Published public private(set) var panel: Panel?
    /// What the last link did ("Linked “…”."), for the item it was made on.
    @Published public private(set) var note: (itemId: String, text: String)?

    public let write: PadWriteModel
    private let dbQueue: any DatabaseReader
    private let today: () -> Date

    public init(write: PadWriteModel, dbQueue: any DatabaseReader, today: @escaping () -> Date) {
        self.write = write
        self.dbQueue = dbQueue
        self.today = today
        let current = UKTaxYear.containing(today())
        year = current
        years = [current]
    }

    /// The row a link's refusal shows under: the item's.
    public nonisolated static func itemRow(_ itemId: String) -> String { "item-\(itemId)" }

    public var selectedItem: MissingEvidence.Item? { items.first { $0.id == selectedItemId } }

    /// The checklist by source, only missing items when `missingOnly` (the selected one stays).
    public var groups: [MissingEvidence.SourceGroup] {
        MissingEvidence.bySource(MissingEvidence.filtered(items, missingOnly: missingOnly, text: "", keeping: selectedItemId))
    }

    public var progress: MissingEvidence.Progress { MissingEvidence.progress(items) }

    /// Whether Link is offered (Edit on Documents).
    public var canLink: Bool { write.canEdit }

    // MARK: Reading

    public func reload() async {
        let snapshot = await Self.read(dbQueue, year: year, today: today())
        guard let snapshot else { return }
        apply(snapshot)
        await loadPanel()
    }

    /// The checklist for `year`, with the years offered (2023/24 or the first transaction's, through today's).
    public nonisolated static func readNow(_ dbQueue: any DatabaseReader, year: UKTaxYear, today: Date) -> Snapshot? {
        try? dbQueue.read { db in try snapshot(db, year: year, today: today) }
    }

    nonisolated static func read(_ dbQueue: any DatabaseReader, year: UKTaxYear, today: Date) async -> Snapshot? {
        try? await dbQueue.read { db in try snapshot(db, year: year, today: today) }
    }

    nonisolated static func snapshot(_ db: Database, year: UKTaxYear, today: Date) throws -> Snapshot {
        let earliest = try Date.fetchOne(db, sql: "SELECT MIN(date) FROM transaction_")
        let first = min(UKTaxYear(startYear: 2023), earliest.map(UKTaxYear.containing) ?? UKTaxYear(startYear: 2023))
        return Snapshot(items: try MissingEvidence.checklist(db: db, period: year.interval), catalog: try DocumentKindCatalog.load(db: db),
                        years: UKTaxYear.pickerYears(earliest: first, now: today))
    }

    /// Shows an already read snapshot (the snapshot routes' first frame).
    public func preload(_ snapshot: Snapshot, selecting itemId: String? = nil, panel: Panel? = nil) {
        apply(snapshot)
        selectedItemId = itemId
        self.panel = panel
    }

    private func apply(_ snapshot: Snapshot) {
        items = snapshot.items
        catalog = snapshot.catalog
        years = snapshot.years
        if let id = selectedItemId, !items.contains(where: { $0.id == id }) { selectedItemId = nil }
    }

    /// The selected item's panel: its attached documents and the suggestions.
    public func loadPanel() async {
        guard let item = selectedItem else { panel = nil; return }
        let catalog = catalog
        let read = try? await dbQueue.read { db in try Self.panel(db, item: item, catalog: catalog) }
        guard selectedItemId == item.id else { return }
        panel = read
    }

    /// The panel for `item`, read now (the Mac's reads: `attached`, then `suggestions` with the matcher's own for a
    /// transaction's item).
    public nonisolated static func panel(_ db: Database, item: MissingEvidence.Item, catalog: DocumentKindCatalog) throws -> Panel {
        let attached = MissingEvidence.attached(item, catalog: catalog)
        let linked = Set(attached.map(\.id))
        let summaries = try EvidenceDocumentSummary.newestFirst.fetchAll(db)
        var matched: [EvidenceMatcher.DocumentSuggestion] = []
        if item.target.entity.type == .transaction {
            let index = EvidenceMatcher.Index(transactions: try Transaction.fetchAll(db), accounts: try Account.fetchAll(db),
                                              categories: try Category.fetchAll(db))
            matched = EvidenceMatcher.documentSuggestions(for: item.target.entity.id, documents: try EvidenceDocument.fetchAll(db), index: index,
                                                          excluding: linked, linkedDebits: try EvidenceMatcher.linkedDebits(db: db), limit: 8)
        }
        let byId = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let suggestions = MissingEvidence.suggestions(for: item, summaries: summaries, matched: matched, excluding: linked, limit: 6)
            .compactMap { candidate in
                byId[candidate.documentId].map { Suggestion(document: $0, kindName: catalog.displayName(of: $0), reasons: candidate.reasons) }
            }
        return Panel(itemId: item.id, attached: attached, suggestions: suggestions)
    }

    // MARK: Linking

    /// Links `documentId` to `item`'s record, filling in what it needs to count (`MissingEvidence.link`): true when it
    /// saved. A refusal shows under the item; what the link did shows as its note.
    @discardableResult
    public func link(documentId: Int64, to item: MissingEvidence.Item) async -> Bool {
        let scope = FiledYearEditCheck.Scope(transactionIds: item.target.entity.type == .transaction ? [item.target.entity.id] : [])
        let outcome = await write.saving(rowId: Self.itemRow(item.id), origin: .documentLink, edit: "Link document", scope: scope) { db in
            try MissingEvidence.link(db: db, documentId: documentId, to: item)
        }
        guard let outcome else { return false }
        note = (item.id, Self.describe(outcome))
        await reload()
        return true
    }

    /// The note for item `itemId`, if the last link was made on it.
    public func note(for itemId: String) -> String? { note?.itemId == itemId ? note?.text : nil }

    /// "Linked “…”.", what it set, and why it doesn't count yet if it doesn't (the Mac's words, without its pointers
    /// to Documents' editors, which the iPad doesn't have).
    nonisolated static func describe(_ outcome: MissingEvidence.LinkOutcome) -> String {
        var text = "Linked “\(outcome.document.displayName)”."
        if !outcome.filled.isEmpty { text += " Set its \(outcome.filled.joined(separator: " and "))." }
        if let shortfall = outcome.shortfall { text += " It doesn't count for this item yet: \(shortfall)." }
        return text
    }
}
