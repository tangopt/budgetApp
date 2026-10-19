// App/Documents/DocumentsViewModel.swift
import Foundation
import AppKit
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction
import GRDB

/// The Documents screen (spec 2026-10-16 §2–§3): the evidence library searched and filtered
/// (`EvidenceDocumentSearch`), the selected document with its links and the transactions it
/// may be evidence for (`EvidenceMatcher`), adding files, and editing details and links.
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
        didSet { overview = LibrarySummary(index.entries) }
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
    /// Files being added right now.
    @Published private(set) var addingCount = 0
    @Published var errorMessage: String?
    /// A note about the last add ("Already in the library: …").
    @Published var infoMessage: String?

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

    private func refreshSuggestions() {
        guard let document = selected, let catalog else { suggestions = []; return }
        let linked = Set(links.filter { $0.link.entityType == .transaction }.map(\.link.entityId))
        suggestions = EvidenceMatcher.suggestions(document: document, index: catalog.matcherIndex, limit: 8)
            .filter { !linked.contains($0.transactionId) }
    }

    /// The selected document's linked transaction ids (the picker marks them).
    var linkedTransactionIds: Set<Int64> {
        Set(links.filter { $0.link.entityType == .transaction }.map(\.link.entityId))
    }

    // MARK: Adding

    /// Copies the files into the library (analysing each), then selects the last one added
    /// so its suggested transactions show. Files already in the library are pointed out.
    func add(_ urls: [URL]) {
        let (files, folders) = EvidenceFiles.files(urls)
        errorMessage = nil
        infoMessage = EvidenceFiles.skippedMessage(folders)
        guard !files.isEmpty else { return }
        addingCount += files.count
        let library = library
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> (added: [EvidenceDocument], existing: [EvidenceDocument], failures: [String]) in
                var added: [EvidenceDocument] = [], existing: [EvidenceDocument] = [], failures: [String] = []
                for url in files {
                    do {
                        let result = try EvidenceFiles.withAccess(url) { try library.addAnalyzing(url) }
                        if result.isNew { added.append(result.document) } else { existing.append(result.document) }
                    } catch {
                        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                return (added, existing, failures)
            }.value
            addingCount -= files.count
            if !outcome.failures.isEmpty {
                errorMessage = "Couldn't add " + outcome.failures.joined(separator: "; ")
            }
            if !outcome.existing.isEmpty {
                let names = outcome.existing.map(\.displayName).joined(separator: ", ")
                infoMessage = [infoMessage, "Already in the library: \(names)"].compactMap { $0 }.joined(separator: " ")
            }
            // A filter could hide what was just added.
            if !filter.isDefault, !outcome.added.isEmpty { filter = EvidenceDocumentSearch.Filter() ; queryText = "" }
            reloadIndex(select: (outcome.added.last ?? outcome.existing.last)?.id)
        }
    }

    // MARK: Editing

    /// Saves the selected document's details; false (with the reason shown) when refused.
    @discardableResult
    func saveDetails(_ details: EvidenceDocumentDetails) -> Bool {
        guard let id = selected?.id else { return false }
        do {
            selected = try library.updateDetails(id, details)
            errorMessage = nil
            refreshSuggestions()
            refreshEntries(for: [id])
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func link(transactionId: Int64, role: String?) {
        guard let id = selected?.id else { return }
        write { try self.library.link(id, to: .transaction(transactionId), role: role) }
    }

    func unlink(_ row: LinkRow) {
        write { try self.library.unlink(row.link.documentId, from: row.link.entity) }
    }

    func setRole(_ role: String?, for row: LinkRow) {
        write { try self.library.setRole(role, documentId: row.link.documentId, entity: row.link.entity) }
    }

    /// Deletes the document and its copy (and its links).
    func remove(_ documentId: Int64) {
        do {
            try library.remove(documentId, force: true)
            if selectedId == documentId { selectedId = nil }
            refreshEntries(for: [documentId])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func write(_ body: () throws -> Void) {
        do {
            try body()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        loadLinks()
        refreshSuggestions()
        if let id = selected?.id { refreshEntries(for: [id]) }
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
        /// Scans and photos: no text to search or match.
        var imageOnly = 0
        /// Documents per kind, most first.
        var byKind: [(kind: DocumentKind, count: Int)] = []
        /// The newest-added documents not linked to anything yet.
        var recentUnlinked: [EvidenceDocumentSearch.Entry] = []

        init(_ entries: [EvidenceDocumentSearch.Entry], unlinkedShown: Int = 8) {
            total = entries.count
            linked = entries.filter { $0.linkCount > 0 }.count
            unlinked = total - linked
            imageOnly = entries.filter { $0.summary.textStatus == .image }.count
            var counts: [DocumentKind: Int] = [:]
            for entry in entries { counts[entry.summary.kind, default: 0] += 1 }
            byKind = counts.map { (kind: $0.key, count: $0.value) }
                .sorted { ($0.count, $1.kind.displayName) > ($1.count, $0.kind.displayName) }
            recentUnlinked = Array(entries.filter { $0.linkCount == 0 }.prefix(unlinkedShown))
        }

        static func == (lhs: LibrarySummary, rhs: LibrarySummary) -> Bool {
            lhs.total == rhs.total && lhs.linked == rhs.linked && lhs.imageOnly == rhs.imageOnly
                && lhs.byKind.map(\.kind) == rhs.byKind.map(\.kind) && lhs.byKind.map(\.count) == rhs.byKind.map(\.count)
                && lhs.recentUnlinked == rhs.recentUnlinked
        }
    }
}
