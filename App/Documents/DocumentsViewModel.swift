// App/Documents/DocumentsViewModel.swift
import Foundation
import AppKit
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction
import GRDB

/// The Documents screen (spec 2026-10-16 §2–§3): the evidence library searched and filtered
/// (`EvidenceDocumentSearch`), the selected document with its links and the transactions it
/// may be evidence for (`EvidenceMatcher`), scanning a source folder for the importer, and editing details and links.
/// Owned by ContentView, so the search and filters last while the app runs.
@MainActor
final class DocumentsViewModel: ObservableObject {
    /// A record the selected document is linked to, described for the links list.
    struct LinkRow: Identifiable, Equatable {
        let link: DocumentLink
        let title: String
        let subtitle: String?
        /// For a transaction link (nil when it's another kind of record).
        let transaction: EvidenceTransactionInfo?

        var id: Int64 { link.id ?? -1 }
    }

    let dbQueue: DatabaseQueue
    let library: EvidenceLibrary

    @Published var filter = EvidenceDocumentSearch.Filter() {
        didSet { if filter != oldValue { refreshEntries() } }
    }
    /// What the search field holds; reaches `filter.text` after a short pause in typing.
    @Published var queryText = "" {
        didSet { if queryText != oldValue { scheduleQuery() } }
    }
    @Published private(set) var index = EvidenceDocumentSearch.Index(entries: []) {
        didSet { overview = LibrarySummary(index.entries, catalog: index.catalog) }
    }
    @Published private(set) var entries: [EvidenceDocumentSearch.Entry] = [] {
        didSet { sections = YearSection.sections(entries) }
    }
    /// The matching documents by the year they're dated in, for the list.
    @Published private(set) var sections: [YearSection] = []
    /// The whole library at a glance (whatever the filters show), for the overview.
    @Published private(set) var overview = LibrarySummary([])
    @Published var selectedId: Int64? {
        didSet { if selectedId != oldValue { loadSelection() } }
    }
    /// The selected document in full (its text included).
    @Published private(set) var selected: EvidenceDocument?
    @Published private(set) var links: [LinkRow] = []
    /// Transactions the selected document may be evidence for, best first, without the ones
    /// it's already linked to.
    @Published private(set) var suggestions: [EvidenceMatcher.Suggestion] = []
    /// Every transaction, for suggestions and the pickers; nil until loaded.
    @Published private(set) var catalog: TransactionCatalog?
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var sourceFolders: [SourceFolder] = []
    /// The source folder being scanned for Review a folder (its name).
    @Published private(set) var scanningFolder: String?
    @Published var errorMessage: String?
    /// A note about the last folder review ("Nothing new or changed in …").
    @Published var infoMessage: String?

    /// A link Mango made itself after a sync, shown with Undo.
    struct AutoLinkedRow: Identifiable, Equatable {
        let pair: WaitingDocuments.Pair
        let documentName: String
        let paymentText: String
        var id: String { pair.id }
    }
    @Published private(set) var autoLinked: [AutoLinkedRow] = []
    /// The recent automatic links (document, payment), newest first (`WaitingDocuments.recentAutoLinks`); nil shows no section.
    var recentAutoLinkSource: (@Sendable (Database) throws -> [WaitingDocuments.Pair])? = { db in
        try WaitingDocuments.recentAutoLinks(db: db).map(\.pair)
    }

    private var queryTask: Task<Void, Never>?
    private var indexGeneration = 0
    private var entriesGeneration = 0

    init(dbQueue: DatabaseQueue, library: EvidenceLibrary) {
        self.dbQueue = dbQueue
        self.library = library
    }

    var scanner: SourceFolderScanner { SourceFolderScanner(library: library) }

    /// Re-reads everything (on appear).
    func load() {
        do {
            let (accounts, folders) = try dbQueue.read { db in (try Account.fetchAll(db), try SourceFolder.order(Column("name")).fetchAll(db)) }
            self.accounts = accounts.sortedForDisplay()
            sourceFolders = folders
        } catch {
            errorMessage = "Couldn't load accounts: \(error.localizedDescription)"
        }
        reloadIndex()
        reloadCatalog()
    }

    func reloadCatalog() {
        let dbQueue = dbQueue
        Task {
            do {
                catalog = try await TransactionCatalog.load(dbQueue)
                refreshSuggestions()
                if selected != nil { loadLinks() }
            } catch {
                errorMessage = "Couldn't load transactions: \(error.localizedDescription)"
            }
        }
    }

    /// Re-reads the library off the main thread, then selects `select` if given.
    func reloadIndex(select: Int64? = nil) {
        indexGeneration += 1
        let generation = indexGeneration
        let dbQueue = dbQueue
        Task {
            do {
                let index = try await Task.detached(priority: .userInitiated) {
                    try dbQueue.read { db in try EvidenceDocumentSearch.Index(db: db) }
                }.value
                guard generation == indexGeneration else { return }
                self.index = index
                refreshEntries()
                loadAutoLinked()
                if let select {
                    // Re-read even when it's already selected (its details may have changed).
                    if selectedId == select { loadSelection() } else { selectedId = select }
                } else if let id = selectedId, !index.entries.contains(where: { $0.id == id }) {
                    selectedId = nil
                }
            } catch {
                errorMessage = "Couldn't load documents: \(error.localizedDescription)"
            }
        }
    }

    /// Filters off the main thread; a newer filter or index wins.
    private func refreshEntries() {
        entriesGeneration += 1
        let generation = entriesGeneration, index = index, filter = filter
        Task {
            let entries = await Task.detached(priority: .userInitiated) { EvidenceDocumentSearch.entries(index, filter: filter) }.value
            guard generation == entriesGeneration else { return }
            self.entries = entries
        }
    }

    /// Re-reads only `documentIds`' entries (after an edit or a link change) — the rest of
    /// the index, text included, is kept.
    private func refreshEntries(for documentIds: [Int64]) {
        do {
            let current = index
            index = try dbQueue.read { db in try current.updating(db: db, documentIds: documentIds) }
            refreshEntries()
        } catch {
            reloadIndex()
        }
    }

    /// Typing waits ~150 ms for a pause before searching; clearing applies at once.
    private func scheduleQuery() {
        queryTask?.cancel()
        let text = queryText
        guard !text.isEmpty else {
            filter.text = ""
            return
        }
        queryTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            filter.text = text
        }
    }

    func resetFilters() {
        filter = EvidenceDocumentSearch.Filter(text: filter.text)
    }

    /// Brings a library document up selected (another screen's Show in Documents), clearing
    /// the search and filters first when they hide it.
    func reveal(_ id: Int64) {
        if !entries.contains(where: { $0.id == id }), !filter.isDefault || !queryText.isEmpty {
            queryText = ""
            filter = EvidenceDocumentSearch.Filter()
        }
        selectedId = id
    }

    // MARK: Selection

    /// A library document in full, read now (the list's context menu acts on any row).
    func document(_ id: Int64) -> EvidenceDocument? {
        if let selected, selected.id == id { return selected }
        return try? library.document(id: id)
    }

    /// A kind's name, a custom kind's included (as the library was last read).
    func kindName(_ ref: DocumentKindRef) -> String { index.catalog.displayName(ref) }

    func entry(_ id: Int64?) -> EvidenceDocumentSearch.Entry? {
        guard let id else { return nil }
        return index.entries.first { $0.id == id }
    }

    private func loadSelection() {
        guard let id = selectedId else {
            selected = nil
            links = []
            suggestions = []
            return
        }
        do {
            selected = try library.document(id: id)
        } catch {
            errorMessage = "Couldn't read the document: \(error.localizedDescription)"
            selected = nil
        }
        loadLinks()
        refreshSuggestions()
    }

    private func loadLinks() {
        guard let id = selected?.id else { links = []; return }
        do {
            let catalog = catalog
            links = try dbQueue.read { db in
                let links = try EvidenceLinks.links(db: db, for: id)
                return try links.map { link in try Self.row(link, db: db, catalog: catalog) }
            }
        } catch {
            errorMessage = "Couldn't read the document's links: \(error.localizedDescription)"
        }
    }

    /// Describes a link's record: a transaction by description, date, account and amount;
    /// an account or category by name; anything else by its kind.
    private static func row(_ link: DocumentLink, db: Database, catalog: TransactionCatalog?) throws -> LinkRow {
        switch link.entityType {
        case .transaction:
            var info = catalog?.info(link.entityId)
            if info == nil, let transaction = try Transaction.fetchOne(db, key: link.entityId) {
                let account = try Account.fetchOne(db, key: transaction.accountId)
                let category = try transaction.categoryId.flatMap { try Category.fetchOne(db, key: $0) }
                info = EvidenceTransactionInfo(transaction: transaction, accountName: account?.displayName ?? "",
                                               currency: account?.currency ?? .gbp, categoryName: category?.name)
            }
            guard let info else { return LinkRow(link: link, title: "Transaction no longer exists", subtitle: nil, transaction: nil) }
            return LinkRow(link: link, title: info.transaction.rawDescription,
                           subtitle: "\(info.transaction.date.formatted(date: .abbreviated, time: .omitted)) · \(info.accountName)",
                           transaction: info)
        case .account:
            let name = try Account.fetchOne(db, key: link.entityId)?.displayName ?? "Account no longer exists"
            return LinkRow(link: link, title: name, subtitle: "Account", transaction: nil)
        case .category:
            let name = try Category.fetchOne(db, key: link.entityId)?.name ?? "Category no longer exists"
            return LinkRow(link: link, title: name, subtitle: "Category", transaction: nil)
        case .property, .person, .tenancy, .rentReceipt:
            let kind = link.entityType.displayName
            let title = try PropertyEvidence.title(db: db, entity: link.entity) ?? "\(kind) no longer exists"
            return LinkRow(link: link, title: title, subtitle: kind, transaction: nil)
        case .taxYear, .taxManualItem, .employment, .employmentIncome, .hmrcPayment, .otherIncome, .pensionContribution, .taxPolicyReceipt:
            let kind = link.entityType.displayName
            let title = try TaxEvidence.title(db: db, entity: link.entity) ?? "\(kind) no longer exists"
            return LinkRow(link: link, title: title, subtitle: kind, transaction: nil)
        case .other:
            return LinkRow(link: link, title: "\(link.entityType.displayName) #\(link.entityId)", subtitle: nil, transaction: nil)
        }
    }

    private func loadAutoLinked() {
        guard let source = recentAutoLinkSource else { autoLinked = []; return }
        autoLinked = ((try? dbQueue.read { db -> [AutoLinkedRow] in
            try source(db).prefix(8).compactMap { pair in
                guard let document = try EvidenceDocument.fetchOne(db, key: pair.documentId),
                      let transaction = try Transaction.fetchOne(db, key: pair.transactionId) else { return nil }
                return AutoLinkedRow(pair: pair, documentName: document.displayName,
                                     paymentText: "\(DocumentFormat.day(transaction.date)) \(transaction.rawDescription)")
            }
        }) ?? [])
    }

    /// Takes an automatic link back (the guarded unlink, remembered so it is not made again).
    func undoAutoLink(_ pair: WaitingDocuments.Pair) {
        let dbQueue = dbQueue, now = AppClock.now
        Task {
            guard let result = await guarded({ try dbQueue.write(.documents, origin: .documentLink) { db in try WaitingDocuments.undo(db: db, pair, now: now) } }) else { return }
            errorMessage = result.failure?.localizedDescription
            loadAutoLinked()
            reloadIndex(select: selectedId)
        }
    }

    /// The person has seen the automatic links: no longer listed (the links stay).
    func dismissAutoLinks(_ pairs: [WaitingDocuments.Pair]) {
        let dbQueue = dbQueue
        Task {
            guard let result = await guarded({ try dbQueue.write(.documents, origin: .documentLink) { db in
                try WaitingDocuments.dismissRecentAutoLinks(db: db, pairs)
            } }) else { return }
            errorMessage = result.failure?.localizedDescription
            loadAutoLinked()
        }
    }

    /// Whether the selected document waits for its payment (read with the index).
    var selectedWaitingState: WaitingDocuments.State {
        guard let id = selected?.id else { return .notApplicable }
        return index.entries.first { $0.id == id }?.waitingState ?? .notApplicable
    }

    private var suggestionsGeneration = 0

    private func refreshSuggestions() {
        guard let document = selected, let catalog else { suggestions = []; return }
        let linkedIds = links.filter { $0.link.entityType == .transaction }.map(\.link.entityId)
        let linked = Set(linkedIds)
        // A part-paid document proposes a debit of its rest.
        let paid = catalog.matcherIndex.linkedDebits(linkedIds, currency: document.currency)
        suggestions = EvidenceMatcher.suggestions(document: document, index: catalog.matcherIndex, limit: 8, linkedDebits: paid)
            .filter { !linked.contains($0.transactionId) }
        // A waiting document's candidates leave out the pairs the user undid (and agree with the automatic linking).
        guard selectedWaitingState == .waiting, let documentId = document.id else { return }
        suggestionsGeneration += 1
        let generation = suggestionsGeneration, dbQueue = dbQueue
        Task {
            let found = try? await Task.detached(priority: .userInitiated) {
                try dbQueue.read { db in try WaitingDocuments.suggestions(db: db, documentId: documentId) }
            }.value
            guard generation == suggestionsGeneration, selected?.id == documentId, let found else { return }
            suggestions = found
        }
    }

    /// The selected document's linked transaction ids (the picker marks them).
    var linkedTransactionIds: Set<Int64> {
        Set(links.filter { $0.link.entityType == .transaction }.map(\.link.entityId))
    }

    // MARK: Source folders

    /// Scans `folder` (counts only, off the main thread) for Review a folder: its new and
    /// changed files for the importer, or nil when the scan failed (the error shown).
    func scanForImport(_ folder: SourceFolder) async -> [SourceFolderImport.Input]? {
        guard scanningFolder == nil else { return nil }
        scanningFolder = folder.name
        errorMessage = nil
        infoMessage = nil
        let scanner = scanner
        let outcome = await Task.detached(priority: .userInitiated) {
            Result { try scanner.scan(folder, options: .init(analyzeNewFiles: false)) }
        }.value
        scanningFolder = nil
        load()
        switch outcome {
        case .success(let result):
            return SourceFolderImport.inputs(from: result)
        case .failure(let error):
            errorMessage = "Couldn't scan \(folder.name): \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Editing

    /// A guarded edit (a linked document's details, a link, an unlink, a delete) is checking the filed
    /// returns off the main thread: "Checking filed returns…" shows and the screen waits for it.
    @Published private(set) var isCheckingFiledYears = false

    /// `body` off the main thread with `isCheckingFiledYears` on; nil (nothing run) while another runs.
    private func guarded<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async -> Result<T, Error>? {
        guard !isCheckingFiledYears else { return nil }
        isCheckingFiledYears = true
        defer { isCheckingFiledYears = false }
        return await Task.detached(priority: .userInitiated) { Result { try body() } }.value
    }

    /// Saves the selected document's details, off the main thread (a linked document's are checked against the
    /// filed returns, `EvidenceLibrary.updateDetails`); `saved` gets the stored document, and a refusal shows.
    func saveDetails(_ details: EvidenceDocumentDetails, saved: @escaping (EvidenceDocument) -> Void = { _ in }) {
        guard let id = selected?.id else { return }
        let library = library
        Task {
            guard let result = await guarded({ try library.updateDetails(id, details) }) else { return }
            switch result {
            case .success(let document):
                errorMessage = nil
                refreshSuggestions()
                refreshEntries(for: [id])
                // Another document selected meanwhile: its inspector keeps its own draft.
                if selectedId == id {
                    selected = document
                    saved(document)
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    func link(transactionId: Int64, role: String?) {
        guard let id = selected?.id else { return }
        let library = library
        write { _ = try library.link(id, to: .transaction(transactionId), role: role, actor: try library.database.signedInActor()) }
    }

    func unlink(_ row: LinkRow) {
        let library = library, documentId = row.link.documentId, entity = row.link.entity
        write { _ = try library.unlink(documentId, from: entity, actor: try library.database.signedInActor()) }
    }

    func setRole(_ role: String?, for row: LinkRow) {
        let library = library, documentId = row.link.documentId, entity = row.link.entity
        write { _ = try library.setRole(role, documentId: documentId, entity: entity, actor: try library.database.signedInActor()) }
    }

    /// Deletes the document and its copy (and its links), off the main thread (its links are checked).
    func remove(_ documentId: Int64) {
        let library = library
        Task {
            guard let result = await guarded({ try library.remove(documentId, force: true) }) else { return }
            switch result {
            case .success:
                errorMessage = nil
                if selectedId == documentId { selectedId = nil }
                refreshEntries(for: [documentId])
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    /// A link change, off the main thread through `guarded`; the links and suggestions are read again after.
    private func write(_ body: @escaping @Sendable () throws -> Void) {
        Task {
            guard let result = await guarded(body) else { return }
            errorMessage = result.failure?.localizedDescription
            loadLinks()
            refreshSuggestions()
            if let id = selected?.id { refreshEntries(for: [id]) }
        }
    }

    // MARK: Kinds

    /// The custom kinds with their document counts, read off the main thread (the Kinds sheet).
    func loadKinds() async -> Result<[CustomKindRow], Error> {
        let dbQueue = dbQueue
        return await Task.detached(priority: .userInitiated) {
            Result { try dbQueue.read { db in try CustomDocumentKinds.rows(db: db) } }
        }.value
    }

    /// Applies the Kinds sheet's staged edits in one write, off the main thread; the library is read
    /// again after (names, kinds and filters change). Returns what changed, or the refusal (a taken
    /// name, a kind gone, a filed year that would move: nothing is written).
    func saveKinds(_ edits: [KindEdit]) async -> Result<KindSaveResult, Error> {
        let dbQueue = dbQueue, now = AppClock.now
        let result = await Task.detached(priority: .userInitiated) {
            Result { try dbQueue.write(.documents) { db in try CustomDocumentKinds.save(db: db, edits: edits, now: now) } }
        }.value
        if case .success = result {
            // A kind merged away can't stay the filter.
            let merged = Set(edits.compactMap { edit -> Int64? in
                if case .merge = edit.change { return edit.kindId }
                return nil
            })
            if case .custom(let id)? = filter.kind, merged.contains(id) { filter.kind = nil }
            reloadIndex(select: selectedId)
        }
        return result
    }

    // MARK: Files

    func fileURL(_ document: EvidenceDocument) -> URL { library.fileURL(for: document) }

    func open(_ document: EvidenceDocument) {
        NSWorkspace.shared.open(library.fileURL(for: document))
    }

    func showInFinder(_ document: EvidenceDocument) {
        NSWorkspace.shared.activateFileViewerSelecting([library.fileURL(for: document)])
    }

    func sourceFolder(_ id: Int64?) -> SourceFolder? {
        guard let id else { return nil }
        return sourceFolders.first { $0.id == id }
    }
}

// MARK: - Presentation

extension DocumentsViewModel {
    /// The documents dated in one year (`Entry.year`: the document's date, else its period's),
    /// latest first; undated ones in a section of their own, last.
    struct YearSection: Identifiable, Equatable {
        let year: Int?
        let entries: [EvidenceDocumentSearch.Entry]

        var id: Int { year ?? Int.min }
        var title: String { year.map(String.init) ?? "No date" }

        /// `entries` by year, latest first; within a year by date, latest first (the index's
        /// order — newest added first — between documents of the same day).
        static func sections(_ entries: [EvidenceDocumentSearch.Entry]) -> [YearSection] {
            var order: [Int?] = []
            var grouped: [Int?: [(offset: Int, entry: EvidenceDocumentSearch.Entry)]] = [:]
            for (offset, entry) in entries.enumerated() {
                if grouped[entry.year] == nil { order.append(entry.year) }
                grouped[entry.year, default: []].append((offset, entry))
            }
            func day(_ entry: EvidenceDocumentSearch.Entry) -> Date {
                let summary = entry.summary
                return summary.docDate ?? summary.periodEnd ?? summary.periodStart ?? .distantPast
            }
            return order
                .sorted { ($0 ?? Int.min) > ($1 ?? Int.min) }
                .map { year in
                    let rows = (grouped[year] ?? []).sorted { a, b in
                        let (dayA, dayB) = (day(a.entry), day(b.entry))
                        return dayA != dayB ? dayA > dayB : a.offset < b.offset
                    }
                    return YearSection(year: year, entries: rows.map(\.entry))
                }
        }
    }

    /// The library's figures for the overview shown while nothing is selected.
    struct LibrarySummary: Equatable {
        var total = 0
        var linked = 0
        var unlinked = 0
        /// Filed before their payment (not counted as not linked): the statement will link them.
        var waiting = 0
        /// Scans and photos: no text to search or match.
        var imageOnly = 0
        /// Documents per kind (custom kinds by their own name), most first.
        var byKind: [(kind: DocumentKindRef, name: String, count: Int)] = []
        /// The newest-added documents not linked to anything yet.
        var recentUnlinked: [EvidenceDocumentSearch.Entry] = []

        init(_ entries: [EvidenceDocumentSearch.Entry], catalog: DocumentKindCatalog = DocumentKindCatalog(customKinds: []),
             unlinkedShown: Int = 8) {
            total = entries.count
            linked = entries.filter { $0.linkCount > 0 }.count
            waiting = entries.filter { $0.waitingState == .waiting && $0.linkCount == 0 }.count
            unlinked = total - linked - waiting
            imageOnly = entries.filter { $0.summary.textStatus == .image }.count
            var counts: [DocumentKindRef: Int] = [:]
            for entry in entries { counts[entry.summary.kindRef, default: 0] += 1 }
            byKind = counts.map { (kind: $0.key, name: catalog.displayName($0.key), count: $0.value) }
                .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
            recentUnlinked = Array(EvidenceDocumentSearch.notLinkedYet(entries).prefix(unlinkedShown))
        }

        static func == (lhs: LibrarySummary, rhs: LibrarySummary) -> Bool {
            lhs.total == rhs.total && lhs.linked == rhs.linked && lhs.waiting == rhs.waiting && lhs.unlinked == rhs.unlinked && lhs.imageOnly == rhs.imageOnly
                && lhs.byKind.map(\.kind) == rhs.byKind.map(\.kind) && lhs.byKind.map(\.name) == rhs.byKind.map(\.name)
                && lhs.byKind.map(\.count) == rhs.byKind.map(\.count)
                && lhs.recentUnlinked == rhs.recentUnlinked
        }
    }
}
