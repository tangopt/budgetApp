import Foundation
import SwiftUI
import BudgetCore
import GRDB

/// What the document panel lists under the thumbnail (step 10, Task 2), in the panel's order: Kind, From, Period,
/// Amount, Date, Linked to. A detail the document doesn't have is nil, never a "—" string. Days and periods come
/// unbreakable (`String.unbroken`), so no row wraps through a figure.
public struct DocumentPanelDetails: Equatable, Sendable {
    public var kind: String
    /// Who the document concerns, by name.
    public var from: String?
    public var period: String?
    /// The amount the document states (sign-free), in its own currency.
    public var amount: String?
    public var date: String?
    /// The records it is linked to, one title per line (`EvidenceLinkTitles`).
    public var linkedTo: String?
    /// Filed before its payment: the panel says it is waiting (the Mac's line); hidden otherwise.
    public var waiting: Bool

    /// The panel's quiet line for a waiting document (the Mac's wording).
    public static let waitingLine = "Waiting for its payment — Mango links it when the statement arrives"

    public init(kind: String, from: String? = nil, period: String? = nil, amount: String? = nil, date: String? = nil,
                linkedTo: String? = nil, waiting: Bool = false) {
        self.waiting = waiting
        self.kind = kind
        self.from = from
        self.period = period
        self.amount = amount
        self.date = date
        self.linkedTo = linkedTo
    }

    public struct Row: Equatable, Sendable {
        public var label: String
        public var value: String
        /// Whether the value is a figure (kept on one line) rather than a name that may wrap.
        public var isFigure: Bool
    }

    /// The rows the panel shows: Kind always, the others when present.
    public var rows: [Row] {
        var rows = [Row(label: "Kind", value: kind, isFigure: false)]
        if let from { rows.append(Row(label: "From", value: from, isFigure: false)) }
        if let period { rows.append(Row(label: "Period", value: period, isFigure: true)) }
        if let amount { rows.append(Row(label: "Amount", value: amount, isFigure: true)) }
        if let date { rows.append(Row(label: "Date", value: date, isFigure: true)) }
        if let linkedTo { rows.append(Row(label: "Linked to", value: linkedTo, isFigure: false)) }
        return rows
    }

    /// The panel's details for `documentId` (an unknown id throws `DocumentPanelError.notFound`).
    public static func load(db: Database, documentId: Int64) throws -> DocumentPanelDetails {
        guard let document = try EvidenceDocument.fetchOne(db, key: documentId) else { throw DocumentPanelError.notFound }
        let catalog = try DocumentKindCatalog.load(db: db)
        let period: String?
        switch (document.periodStart, document.periodEnd) {
        case (nil, nil): period = nil
        case let (start?, end?): period = "\(PhoneDateFormat.day(start)) – \(PhoneDateFormat.day(end))".unbroken
        case let (start?, nil): period = PhoneDateFormat.day(start).unbroken
        case let (nil, end?): period = PhoneDateFormat.day(end).unbroken
        }
        let titles = try EvidenceLinks.links(db: db, for: documentId).map { try EvidenceLinkTitles.line(db: db, entity: $0.entity).title }
        return DocumentPanelDetails(
            kind: catalog.displayName(of: document),
            from: document.persons.isEmpty ? nil : document.persons.joined(separator: ", "),
            period: period,
            amount: document.amountMinorUnits.map { Money.format($0, currency: document.currency ?? .eur) },
            date: document.docDate.map { PhoneDateFormat.day($0).unbroken },
            linkedTo: titles.isEmpty ? nil : titles.joined(separator: "\n"),
            waiting: try WaitingDocuments.state(db: db, documentId: documentId, now: Date()) == .waiting)
    }
}

/// A download that did not answer in time.
struct DocumentPanelTimeout: Error {}

/// Resumes a continuation once, whichever of the work and the timer answers first.
private final class DocumentPanelOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?

    init(_ continuation: CheckedContinuation<URL, Error>) { self.continuation = continuation }

    @discardableResult
    func finish(_ result: Result<URL, Error>) -> Bool {
        lock.lock()
        let taken = continuation
        continuation = nil
        lock.unlock()
        guard let taken else { return false }
        taken.resume(with: result)
        return true
    }
}

public enum DocumentPanelError: Error, Equatable, Sendable {
    case notFound
}

/// Where the document panel sits (step 10, Task 2). The panel is 380 pt wide whatever the screen; it stands beside the
/// content when the content keeps at least 420 pt, else it covers the content's trailing edge.
public enum DocumentPanelLayout {
    public enum Placement: Equatable, Sendable { case beside, overlay }

    public static let width: CGFloat = 380
    public static let minimumContentWidth: CGFloat = 420

    public static func panelWidth(containerWidth: CGFloat) -> CGFloat { width }

    public static func placement(containerWidth: CGFloat) -> Placement {
        containerWidth - width >= minimumContentWidth ? .beside : .overlay
    }

    /// The width the screen's own content keeps with the panel open.
    public static func contentWidth(containerWidth: CGFloat) -> CGFloat {
        placement(containerWidth: containerWidth) == .beside ? containerWidth - width : containerWidth
    }
}

/// Where the panel and the full view find a document: the database to describe it from and the hook that gives its
/// local file (downloading it first when it isn't on the iPad yet). Set once above the screens
/// (`.environment(\.documentPanelSource, …)`).
public struct DocumentPanelSource: Sendable {
    public var dbQueue: any DatabaseReader
    public var open: @Sendable (String) async throws -> URL
    /// A file already on this iPad, found without waiting (the snapshot routes' first frame); nil in the app.
    public var localFile: (@Sendable (String) -> URL?)?

    public init(dbQueue: any DatabaseReader, open: @escaping @Sendable (String) async throws -> URL,
                localFile: (@Sendable (String) -> URL?)? = nil) {
        self.dbQueue = dbQueue
        self.open = open
        self.localFile = localFile
    }
}

extension EnvironmentValues {
    @Entry public var documentPanelSource: DocumentPanelSource?
}

/// One document in the panel and the full view: its title and details, and its file as it arrives.
@MainActor
public final class DocumentPanelModel: ObservableObject {
    public enum File: Equatable {
        case loading
        case ready(URL)
        case failed(String)
    }

    public let documentId: Int64
    @Published public private(set) var title = ""
    @Published public private(set) var details: DocumentPanelDetails?
    @Published public private(set) var file: File = .loading

    private let source: DocumentPanelSource?
    /// How long a download may take before the panel gives up and offers "Try again". The engine queues a download
    /// behind any sync run in progress, and a stalled fetch never answers: without this the panel showed
    /// "Downloading…" for ever.
    private let timeout: Duration

    public init(documentId: Int64, source: DocumentPanelSource?, timeout: Duration = .seconds(60)) {
        self.documentId = documentId
        self.source = source
        self.timeout = timeout
    }

    /// Reads everything now when the source has its files locally (the snapshot routes' first frame); false otherwise.
    @discardableResult
    public func loadNow() -> Bool {
        guard let source, let local = source.localFile else { return false }
        let id = documentId
        guard let (name, path, details) = try? source.dbQueue.read({ db -> (String, String, DocumentPanelDetails)? in
            guard let summary = try EvidenceDocumentSummary.filter(Column("id") == id).fetchOne(db) else { return nil }
            return (summary.displayName, summary.storedRelativePath, try DocumentPanelDetails.load(db: db, documentId: id))
        }) else { return false }
        title = name
        self.details = details
        file = local(path).map { .ready($0) } ?? .loading
        return true
    }

    /// Reads the details and fetches the file.
    public func load() async {
        if case .ready = file { return }
        guard let source else { file = .failed(PadDocumentsModel.notOnDeviceCopy); return }
        let id = documentId
        let read = try? await source.dbQueue.read { db -> (String, String, DocumentPanelDetails)? in
            guard let summary = try EvidenceDocumentSummary.filter(Column("id") == id).fetchOne(db) else { return nil }
            return (summary.displayName, summary.storedRelativePath, try DocumentPanelDetails.load(db: db, documentId: id))
        }
        guard let (name, path, details) = read ?? nil else { file = .failed(PadDocumentsModel.failureCopy); return }
        title = name
        self.details = details
        await fetch(path: path)
    }

    /// Fetches the file again (after a failure).
    public func retry() async {
        guard let source else { return }
        let id = documentId
        guard let path = try? await source.dbQueue.read({ db in
            try EvidenceDocumentSummary.filter(Column("id") == id).fetchOne(db)?.storedRelativePath
        }) else { return }
        await fetch(path: path)
    }

    private func fetch(path: String) async {
        guard let source else { return }
        file = .loading
        do {
            file = .ready(try await Self.open(path, from: source, timeout: timeout))
        } catch is PadDocumentNotOnDevice {
            file = .failed(PadDocumentsModel.notOnDeviceCopy)
        } catch is DocumentPanelTimeout {
            file = .failed(PadDocumentsModel.timedOutCopy)
        } catch {
            file = .failed(PadDocumentsModel.failureCopy)
        }
    }

    /// `source.open(path)`, or `DocumentPanelTimeout` when it has not answered within `timeout` (the stalled work is
    /// cancelled, not waited for).
    nonisolated static func open(_ path: String, from source: DocumentPanelSource, timeout: Duration) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let once = DocumentPanelOnce(continuation)
            let work = Task {
                do { once.finish(.success(try await source.open(path))) } catch { once.finish(.failure(error)) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if once.finish(.failure(DocumentPanelTimeout())) { work.cancel() }
            }
        }
    }
}
