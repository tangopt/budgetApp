import Foundation
import SwiftUI
import BudgetCore
import GRDB
import os

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

/// A read or download that did not answer in time.
struct DocumentPanelTimeout: Error {}

/// Resumes a continuation once, whichever of the work and the timer answers first.
private final class DocumentPanelOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    @discardableResult
    func finish(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        let taken = continuation
        continuation = nil
        lock.unlock()
        guard let taken else { return false }
        taken.resume(with: result)
        return true
    }
}

/// The panel's stages in Console (subsystem ubberninja.mango, category "documents"): document ids and timings only.
private let documentsLog = Logger(subsystem: "ubberninja.mango", category: "documents")

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
///
/// `@Observable`, not `ObservableObject`: the views keep it in `@State`, which never subscribes to an
/// `ObservableObject`'s changes. Built that way (TestFlight 1036–1038) the panel drew its first frame (no title, no
/// details, "Downloading…") and never again, whatever the load did after.
@MainActor @Observable
public final class DocumentPanelModel {
    public enum File: Equatable {
        case loading
        case ready(URL)
        case failed(String)
    }

    public let documentId: Int64
    /// The document's name once read; until then the opening screen's own name for it (a receipt's "Receipt 50").
    public private(set) var title: String
    public private(set) var details: DocumentPanelDetails?
    public private(set) var file: File = .loading

    @ObservationIgnored private let source: DocumentPanelSource?
    /// How long a whole load (the database read, then the download) may take before the panel gives up and offers
    /// "Try again". The read waits behind any write on the database's queue (a sync run applying a pull), and the
    /// engine queues a download behind the sync run in progress: either can outlast the user's patience.
    @ObservationIgnored private let timeout: Duration
    /// The latest load; an older one that answers late changes nothing.
    @ObservationIgnored private var attempt = 0

    public init(documentId: Int64, source: DocumentPanelSource?, title: String = "", timeout: Duration = .seconds(60)) {
        self.documentId = documentId
        self.source = source
        self.title = title
        self.timeout = timeout
    }

    private typealias Read = (name: String, path: String, details: DocumentPanelDetails)

    nonisolated private static func read(_ db: Database, id: Int64) throws -> Read? {
        guard let summary = try EvidenceDocumentSummary.filter(Column("id") == id).fetchOne(db) else { return nil }
        return (summary.displayName, summary.storedRelativePath, try DocumentPanelDetails.load(db: db, documentId: id))
    }

    /// Reads everything now when the source has its files locally (the snapshot routes' first frame); false otherwise.
    @discardableResult
    public func loadNow() -> Bool {
        guard let source, let local = source.localFile else { return false }
        let id = documentId
        guard let read = try? source.dbQueue.read({ db in try Self.read(db, id: id) }) else { return false }
        title = read.name
        details = read.details
        file = local(read.path).map { .ready($0) } ?? .loading
        return true
    }

    /// Reads the details and fetches the file (nothing when the file is already here).
    public func load() async {
        if case .ready = file { return }
        await run()
    }

    /// Reads and fetches again (after a failure, or a load that never answered).
    public func retry() async {
        await run()
    }

    /// One load: always ends in `.ready` or `.failed` within `timeout`, whatever the database and the download do.
    private func run() async {
        attempt += 1
        let mine = attempt
        let id = documentId
        guard let source else {
            documentsLog.error("document \(id, privacy: .public): no document source here")
            file = .failed(PadDocumentsModel.notOnDeviceCopy)
            return
        }
        file = .loading
        let started = ContinuousClock.now
        let deadline = started.advanced(by: timeout)
        func elapsed() -> Int64 { (ContinuousClock.now - started).milliseconds }
        documentsLog.info("document \(id, privacy: .public) load \(mine, privacy: .public): reading")
        let read: Read?
        do {
            read = try await Self.answer(by: deadline) { try await source.dbQueue.read { db in try Self.read(db, id: id) } }
        } catch {
            guard mine == attempt else { return }
            documentsLog.error("document \(id, privacy: .public) load \(mine, privacy: .public): read \(error is DocumentPanelTimeout ? "timed out" : "failed", privacy: .public) after \(elapsed(), privacy: .public) ms")
            file = .failed(error is DocumentPanelTimeout ? PadDocumentsModel.timedOutCopy : PadDocumentsModel.failureCopy)
            return
        }
        guard mine == attempt else { return }
        guard let read else {
            documentsLog.error("document \(id, privacy: .public) load \(mine, privacy: .public): not in the database")
            file = .failed(PadDocumentsModel.failureCopy)
            return
        }
        title = read.name
        details = read.details
        documentsLog.info("document \(id, privacy: .public) load \(mine, privacy: .public): read in \(elapsed(), privacy: .public) ms; opening")
        let path = read.path
        do {
            let url = try await Self.answer(by: deadline) { try await source.open(path) }
            guard mine == attempt else { return }
            documentsLog.info("document \(id, privacy: .public) load \(mine, privacy: .public): ready in \(elapsed(), privacy: .public) ms")
            file = .ready(url)
        } catch {
            guard mine == attempt else { return }
            let copy: String
            switch error {
            case is PadDocumentNotOnDevice: copy = PadDocumentsModel.notOnDeviceCopy
            case is DocumentPanelTimeout: copy = PadDocumentsModel.timedOutCopy
            default: copy = PadDocumentsModel.failureCopy
            }
            documentsLog.error("document \(id, privacy: .public) load \(mine, privacy: .public): open failed (\(String(describing: type(of: error)), privacy: .public)) after \(elapsed(), privacy: .public) ms")
            file = .failed(copy)
        }
    }

    /// `work`'s answer, or `DocumentPanelTimeout` when it has not answered by `deadline`. The stalled work is
    /// cancelled, not waited for: a database read can't be cancelled and a queued download waits its turn, so only
    /// this race guarantees an answer.
    nonisolated static func answer<T: Sendable>(by deadline: ContinuousClock.Instant,
                                                _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = DocumentPanelOnce(continuation)
            let task = Task {
                do { once.finish(.success(try await work())) } catch { once.finish(.failure(error)) }
            }
            Task {
                try? await Task.sleep(until: deadline, clock: .continuous)
                if once.finish(.failure(DocumentPanelTimeout())) { task.cancel() }
            }
        }
    }
}

private extension Duration {
    var milliseconds: Int64 { components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000 }
}
