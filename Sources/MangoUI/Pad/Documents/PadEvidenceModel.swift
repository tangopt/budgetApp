import Foundation
import BudgetCore
import GRDB
import struct BudgetCore.Transaction

/// The iPad's Evidence (step 10, Task 14; replaces step 8's Missing evidence): the whole UK tax year's evidence grouped by
/// area (`TaxYearEvidence.areas`: utility bills left to Bills & recharges, only what the viewer may see), a tax-year
/// switch (last year and this one, this one first), and the selected item in the document panel with the library
/// document that could satisfy it. "Link this document" and "Link existing document" are `MissingEvidence.link`, through
/// the device writer in Documents with the document-link origin (`EvidenceLinkGuard` inside it, filed years checked);
/// "Mark not available" is the item's waiver, through the writer in Property (the waiver's own area). A refusal shows
/// under the item; nothing is saved. Reads again on each sync; no observation of its own.
@MainActor
public final class PadEvidenceModel: ObservableObject {
    /// The selected item's panel, as read: what is attached to its record and the library documents that could satisfy it.
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

    /// What one read gives: the year's areas and the kinds' names.
    public struct Snapshot: Equatable, Sendable {
        var areas: [EvidenceArea]
        var catalog: DocumentKindCatalog
        public static func == (a: Snapshot, b: Snapshot) -> Bool { a.areas == b.areas }
    }

    @Published public var year: UKTaxYear {
        didSet { if year != oldValue { Task { await reload() } } }
    }
    /// The switch's years: last year (the one being filed) and this one.
    public let years: [UKTaxYear]
    /// Missing items only (the default), or all of them.
    @Published public var missingOnly = true
    @Published public private(set) var areas: [EvidenceArea] = []
    @Published public private(set) var catalog = DocumentKindCatalog(customKinds: [])
    @Published public var selectedItemId: String? {
        didSet {
            guard selectedItemId != oldValue else { return }
            panel = nil
            openDocumentId = nil
            Task { await loadPanel() }
        }
    }
    @Published public private(set) var panel: Panel?
    /// A document the user opened from the panel (an attached one, another suggestion); nil shows the best suggestion.
    @Published public var openDocumentId: Int64?
    /// What the last link or waiver did ("Linked “…”."), for the item it was made on.
    @Published public private(set) var note: (itemId: String, text: String)?

    /// Documents' writes (the links).
    public let write: PadWriteModel
    /// Property's writes (the waivers: "Mark not available").
    public let propertyWrite: PadWriteModel
    private let dbQueue: any DatabaseReader
    private let today: () -> Date

    public init(write: PadWriteModel, propertyWrite: PadWriteModel, dbQueue: any DatabaseReader, today: @escaping () -> Date) {
        self.write = write
        self.propertyWrite = propertyWrite
        self.dbQueue = dbQueue
        self.today = today
        let current = UKTaxYear.containing(today())
        year = current
        years = [current.previous, current]
    }

    /// The row a refusal shows under: the item's.
    public nonisolated static func itemRow(_ itemId: String) -> String { "evidence-\(itemId)" }

    public var items: [EvidenceItem] { areas.flatMap(\.items) }
    public var selectedItem: EvidenceItem? { items.first { $0.id == selectedItemId } }

    /// The areas as shown: only missing items when `missingOnly` (the selected one stays).
    public var shownAreas: [EvidenceArea] {
        guard missingOnly else { return areas }
        return areas.map { area in
            var area = area
            area.items = area.items.filter { $0.state == .missing || $0.id == selectedItemId }
            return area
        }
    }

    public var progress: MissingEvidence.Progress { TaxYearEvidence.progress(areas) }

    /// Whether linking is offered: Edit on Documents (the viewer's areas already say whether she may link each item).
    public var canLink: Bool { write.canEdit }
    /// Whether "Mark not available" is offered: Edit on Documents and on Property (where waivers are kept).
    public var canMarkNotAvailable: Bool { write.canEdit && propertyWrite.canEdit }

    // MARK: Reading

    public func reload() async {
        await write.refresh()
        await propertyWrite.refresh()
        // Her own view; nothing while she isn't known (or can't be read), everything only for demo data.
        let scope = await write.readScope()
        guard let snapshot = await Self.read(dbQueue, year: year, scope: scope) else { return }
        apply(snapshot)
        await loadPanel()
    }

    /// The areas for `year` as `viewer` sees them (nil: everything).
    public nonisolated static func readNow(_ dbQueue: any DatabaseReader, year: UKTaxYear, viewer: AccessActor? = nil) -> Snapshot? {
        let scope: DeviceReadScope = viewer.map(DeviceReadScope.actor) ?? .everything
        return try? dbQueue.read { db in try snapshot(db, year: year, scope: scope) }
    }

    nonisolated static func read(_ dbQueue: any DatabaseReader, year: UKTaxYear, scope: DeviceReadScope) async -> Snapshot? {
        try? await dbQueue.read { db in try snapshot(db, year: year, scope: scope) }
    }

    nonisolated static func snapshot(_ db: Database, year: UKTaxYear, scope: DeviceReadScope) throws -> Snapshot {
        Snapshot(areas: try TaxYearEvidence.areas(db: db, taxYear: year, scope: scope), catalog: try DocumentKindCatalog.load(db: db))
    }

    /// Shows an already read snapshot (the snapshot routes' first frame).
    public func preload(_ snapshot: Snapshot, selecting itemId: String? = nil, panel: Panel? = nil) {
        apply(snapshot)
        selectedItemId = itemId
        self.panel = panel
    }

    private func apply(_ snapshot: Snapshot) {
        areas = snapshot.areas
        catalog = snapshot.catalog
        if let id = selectedItemId, !items.contains(where: { $0.id == id }) { selectedItemId = nil }
    }

    /// The selected item's panel.
    public func loadPanel() async {
        guard let item = selectedItem?.item else { panel = nil; return }
        let catalog = catalog
        let read = try? await dbQueue.read { db in try Self.panel(db, item: item, catalog: catalog) }
        guard selectedItemId == item.id else { return }
        panel = read
    }

    /// The panel for `item`, read now: what is attached to it, then the suggestions (the matcher's own for a transaction's).
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

    /// The document the panel shows for the selected item: the one opened, else the best suggestion while it is missing,
    /// else the first attached document. Nil: the item's own panel (nothing to show).
    public var panelDocumentId: Int64? {
        if let openDocumentId { return openDocumentId }
        guard let item = selectedItem, let panel, panel.itemId == item.id else { return nil }
        if item.state == .missing, let first = panel.suggestions.first { return first.id }
        return panel.attached.first?.id
    }

    public func suggestion(_ documentId: Int64) -> Suggestion? {
        guard panel?.itemId == selectedItemId else { return nil }
        return panel?.suggestions.first { $0.id == documentId }
    }

    public func attachedDocument(_ documentId: Int64) -> MissingEvidence.AttachedDocument? {
        guard panel?.itemId == selectedItemId else { return nil }
        return panel?.attached.first { $0.id == documentId }
    }

    // MARK: Search the library

    /// The library documents "Link existing document" offers for `item`: those of a kind its rule takes and not linked to it
    /// yet, the likeliest first (`MissingEvidence.candidates`), then the rest newest first.
    public func libraryChoices(for item: EvidenceItem) async -> [EvidenceDocumentSummary] {
        let item = item.item
        return (try? await dbQueue.read { db -> [EvidenceDocumentSummary] in
            let summaries = try EvidenceDocumentSummary.newestFirst.fetchAll(db)
            let linked = Set(MissingEvidence.attached(item, catalog: try DocumentKindCatalog.load(db: db)).map(\.id))
            let ranked = MissingEvidence.candidates(for: item, documents: summaries, excluding: linked, limit: summaries.count).map(\.documentId)
            let rank = Dictionary(ranked.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
            let accepted = summaries.enumerated().filter { !linked.contains($0.element.id) && item.requirement.accepts($0.element.kindRef) }
            return accepted.sorted { (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset) }
                .prefix(Self.choiceLimit).map(\.element)
        }) ?? []
    }

    nonisolated static let choiceLimit = 60

    // MARK: Writing

    /// Links `documentId` to `item`'s record, filling in what it needs to count (`MissingEvidence.link`): true when it saved.
    @discardableResult
    public func link(documentId: Int64, to item: EvidenceItem) async -> Bool {
        let target = item.item
        let scope = FiledYearEditCheck.Scope(transactionIds: target.target.entity.type == .transaction ? [target.target.entity.id] : [])
        let outcome = await write.saving(rowId: Self.itemRow(item.id), origin: .documentLink, edit: "Link document", scope: scope) { db in
            try MissingEvidence.link(db: db, documentId: documentId, to: target)
        }
        guard let outcome else { return false }
        note = (item.id, Self.describe(outcome))
        openDocumentId = nil
        await reload()
        return true
    }

    /// Marks `item` not available (its waiver): it counts as done. True when it saved.
    @discardableResult
    public func markNotAvailable(_ item: EvidenceItem) async -> Bool {
        guard write.canEdit, let requirementId = item.requirement.id else { return false }
        let target = item.item.target
        let saved = await propertyWrite.perform(rowId: Self.itemRow(item.id), origin: .edit, edit: "Mark not available", scope: .init()) { db in
            _ = try EvidenceRequirements.waive(db: db, requirementId: requirementId, target: target, reason: .notAvailable)
        }
        guard saved else { return false }
        note = (item.id, "Marked not available.")
        await reload()
        return true
    }

    /// The note for item `itemId`, if the last change was made on it.
    public func note(for itemId: String) -> String? { note?.itemId == itemId ? note?.text : nil }

    /// The refusal under item `itemId` (a link's or a waiver's).
    public func refusal(for itemId: String) -> String? {
        write.message(for: Self.itemRow(itemId)) ?? propertyWrite.message(for: Self.itemRow(itemId))
    }

    /// "Linked “…”.", what it set, and why it doesn't count yet if it doesn't.
    nonisolated static func describe(_ outcome: MissingEvidence.LinkOutcome) -> String {
        var text = "Linked “\(outcome.document.displayName)”."
        if !outcome.filled.isEmpty { text += " Set its \(outcome.filled.joined(separator: " and "))." }
        if let shortfall = outcome.shortfall { text += " It doesn't count for this item yet: \(shortfall)." }
        return text
    }

    // MARK: Open site

    /// The saved site "Open site" goes to for `item`: of its suggested kind, the one named like a part of its usual source
    /// ("HMRC / bank": HMRC's, else the bank's), else the first of that kind; nil when none of that kind is saved (the
    /// browser then opens on its strip, where "+ Add site" is).
    public static func site(for item: EvidenceItem, in sites: [SavedSite]) -> SavedSite? {
        guard let kind = item.suggestedSiteKind else { return nil }
        let ofKind = sites.filter { $0.kind == kind }
        func folded(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
        }
        for part in (item.source ?? "").split(separator: "/").map({ folded(String($0)) }) where !part.isEmpty {
            if let named = ofKind.first(where: { let site = folded($0.name); return site.contains(part) || part.contains(site) }) {
                return named
            }
        }
        return ofKind.first
    }
}
