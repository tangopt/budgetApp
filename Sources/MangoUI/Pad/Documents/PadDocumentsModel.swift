import Foundation
import BudgetCore
import GRDB

/// A document's file isn't on this iPad yet and nothing here can fetch it (the default `open`).
public struct PadDocumentNotOnDevice: Error, Equatable, Sendable {
    public init() {}
}

/// The iPad's Documents library (step 8, Task 9; read only): the household's documents grouped by kind, a search
/// field, an "All" / "Unlinked" filter, and one document's detail (kind, date, period, links) with its preview.
///
/// `open` gives the local file for a document's `storedRelativePath`, downloading it first when the iPad doesn't
/// have it yet. Task 5 wires `PhoneSyncController.openDocument` into it (`PhoneTabsModel.padDocuments.open`); until
/// then the default throws `PadDocumentNotOnDevice`, which the preview shows as "Not on this iPad yet".
@MainActor
public final class PadDocumentsModel: ObservableObject {
    public enum Filter: String, CaseIterable, Sendable { case all = "All", unlinked = "Unlinked" }

    public struct Group: Equatable, Identifiable, Sendable {
        public var title: String
        public var documents: [EvidenceDocumentSummary]
        public var id: String { title }
    }

    public struct LinkLine: Equatable, Identifiable, Sendable {
        public var id: Int64
        public var title: String
        public var subtitle: String?
    }

    public enum Preview: Equatable {
        case idle
        case downloading
        case ready(URL)
        case failed(String)
    }

    public static let downloadingCopy = "Downloading…"
    public static let failureCopy = "Couldn't download this document. Try again when you're online."
    public static let notOnDeviceCopy = "Not on this iPad yet"

    @Published public var filter: Filter = .all
    @Published public var query = ""
    @Published public private(set) var all: [EvidenceDocumentSummary] = []
    @Published public private(set) var unlinkedIds: Set<Int64> = []
    @Published public var selectedId: Int64? {
        didSet { if oldValue != selectedId { preview = .idle; links = []; Task { await loadLinks() } } }
    }
    @Published public private(set) var links: [LinkLine] = []
    @Published public private(set) var preview: Preview = .idle
    @Published public private(set) var catalog: DocumentKindCatalog

    /// The local file for a stored relative path; set by the app once sync can download on demand.
    public var open: @Sendable (String) async throws -> URL

    private let dbQueue: any DatabaseReader

    public init(dbQueue: any DatabaseReader, catalog: DocumentKindCatalog = DocumentKindCatalog(customKinds: []),
                open: @escaping @Sendable (String) async throws -> URL = { _ in throw PadDocumentNotOnDevice() }) {
        self.dbQueue = dbQueue
        self.catalog = catalog
        self.open = open
    }

    public var selected: EvidenceDocumentSummary? { all.first { $0.id == selectedId } }

    /// The documents the filter and search keep, grouped by kind title (titles A–Z; newest first inside).
    public var groups: [Group] {
        let words = query.split(whereSeparator: \.isWhitespace).map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let kept = all.filter { document in
            if filter == .unlinked, !unlinkedIds.contains(document.id) { return false }
            guard !words.isEmpty else { return true }
            let haystack = ([document.displayName, document.originalFileName, catalog.displayName(of: document)] + document.persons)
                .joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return words.allSatisfy { haystack.contains($0) }
        }
        return Dictionary(grouping: kept, by: { catalog.displayName(of: $0) })
            .map { Group(title: $0.key, documents: $0.value.sorted { ($0.docDate ?? $0.addedAt) > ($1.docDate ?? $1.addedAt) }) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func reload() async {
        let reader = dbQueue
        guard let read = try? await reader.read({ db -> ([EvidenceDocumentSummary], Set<Int64>, DocumentKindCatalog) in
            (try EvidenceDocumentSummary.newestFirst.fetchAll(db),
             Set(try Int64.fetchAll(db, sql: "SELECT id FROM document WHERE id NOT IN (SELECT documentId FROM documentLink)")),
             try DocumentKindCatalog.load(db: db))
        }) else { return }
        all = read.0
        unlinkedIds = read.1
        catalog = read.2
        if let selectedId, !all.contains(where: { $0.id == selectedId }) { self.selectedId = nil }
    }

    public struct Snapshot: Equatable, Sendable {
        var all: [EvidenceDocumentSummary]
        var unlinked: Set<Int64>
        var catalog: DocumentKindCatalog
        public static func == (a: Snapshot, b: Snapshot) -> Bool { a.all == b.all && a.unlinked == b.unlinked }
    }

    /// The same read, now (the snapshot routes' first frame).
    public nonisolated static func readNow(_ dbQueue: any DatabaseReader) -> Snapshot {
        (try? dbQueue.read { db in
            Snapshot(all: try EvidenceDocumentSummary.newestFirst.fetchAll(db),
                     unlinked: Set(try Int64.fetchAll(db, sql: "SELECT id FROM document WHERE id NOT IN (SELECT documentId FROM documentLink)")),
                     catalog: try DocumentKindCatalog.load(db: db))
        }) ?? Snapshot(all: [], unlinked: [], catalog: DocumentKindCatalog(customKinds: []))
    }

    /// Shows an already read snapshot, with its first document selected.
    public func preload(_ snapshot: Snapshot) {
        all = snapshot.all
        unlinkedIds = snapshot.unlinked
        catalog = snapshot.catalog
        selectedId = groups.first?.documents.first?.id
    }

    /// The selected document's links, titled as on the Mac.
    public func loadLinks() async {
        guard let id = selectedId else { links = []; return }
        let reader = dbQueue
        let lines = try? await reader.read { db in try Self.linkLines(db, documentId: id) }
        guard id == selectedId else { return }
        links = lines ?? []
    }

    nonisolated static func linkLines(_ db: Database, documentId: Int64) throws -> [LinkLine] {
        try EvidenceLinks.links(db: db, for: documentId).map { link in
            let kind = link.entityType.displayName
            switch link.entityType {
            case .property, .person, .tenancy, .rentReceipt:
                return LinkLine(id: link.id ?? 0, title: try PropertyEvidence.title(db: db, entity: link.entity) ?? "\(kind) no longer exists", subtitle: kind)
            case .taxYear, .taxManualItem, .employment, .employmentIncome, .hmrcPayment, .otherIncome, .pensionContribution, .taxPolicyReceipt:
                return LinkLine(id: link.id ?? 0, title: try TaxEvidence.title(db: db, entity: link.entity) ?? "\(kind) no longer exists", subtitle: kind)
            case .account:
                return LinkLine(id: link.id ?? 0, title: try Account.fetchOne(db, key: link.entityId)?.displayName ?? "Account no longer exists", subtitle: "Account")
            case .category:
                return LinkLine(id: link.id ?? 0, title: try Category.fetchOne(db, key: link.entityId)?.name ?? "Category no longer exists", subtitle: "Category")
            default:
                return LinkLine(id: link.id ?? 0, title: "\(kind) #\(link.entityId)", subtitle: nil)
            }
        }
    }

    /// Opens the selected document's file for Quick Look: "Downloading…", then the file, or the failure copy.
    public func openPreview() async {
        guard let document = selected else { return }
        preview = .downloading
        do {
            let url = try await open(document.storedRelativePath)
            guard selectedId == document.id else { return }
            preview = .ready(url)
        } catch is PadDocumentNotOnDevice {
            if selectedId == document.id { preview = .failed(Self.notOnDeviceCopy) }
        } catch {
            if selectedId == document.id { preview = .failed(Self.failureCopy) }
        }
    }

    public func closePreview() { if case .ready = preview { preview = .idle } }
}
