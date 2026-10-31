import Foundation
import GRDB

/// The files chosen in one go on the iPhone, reviewed one at a time: their order, what each turned out to be and what
/// came of it, and the totals the closing summary shows. A value type; the iPhone's import model drives it.
///
/// Each file's primary action acts on that file only; after it the review moves to the next file still waiting.
/// "Not now" leaves a file as "Not imported". Undo covers the statement rows this batch imported (never documents,
/// which are removed from their own page).
public struct PhoneImportBatch: Equatable, Sendable {
    /// What a file was recognised as (`PhoneImportBatch.kind(of:)`).
    public enum Kind: Equatable, Sendable {
        /// Bank PDF or CSV: the statement review.
        case statement
        /// An invoice, receipt, bill or other paper: Check & link.
        case document
        /// Not readable: the "Can't read this file" card.
        case cantRead
    }

    /// What came of a file.
    public enum Outcome: Equatable, Sendable {
        /// Waiting to be read, being read, or read and waiting for its review.
        case waiting
        /// Rows added to an account by one import run (`skipped`: rows already in Mango).
        case imported(accountId: Int64?, accountName: String?, rows: Int, skipped: Int, runId: Int64)
        /// Every row was in Mango already: nothing to import.
        case alreadyInMango(rows: Int)
        /// A document saved (and linked, when it found its payment or bill).
        case saved(documentId: Int64?, title: String, linked: Bool)
        /// The person chose "Not now".
        case notImported
        /// Not readable; the batch went on without it.
        case cantRead(reason: String)
    }

    public struct File: Equatable, Identifiable, Sendable {
        public var id: UUID
        public var name: String
        /// nil until the file has been read.
        public var kind: Kind?
        public var outcome: Outcome
        /// Why a file can't be read (shown on its card).
        public var problem: String?

        public init(id: UUID, name: String, kind: Kind? = nil, outcome: Outcome = .waiting, problem: String? = nil) {
            self.id = id
            self.name = name
            self.kind = kind
            self.outcome = outcome
            self.problem = problem
        }

        /// Still to be looked at in the review.
        public var needsReview: Bool { outcome == .waiting }
    }

    public private(set) var files: [File]
    /// The file the review shows.
    public private(set) var current: Int
    /// "20 of 27 added, import the rest next", when the picker gave more than the inbox takes.
    public var overflowNote: String?

    public init(files: [File], overflowNote: String? = nil) {
        self.files = files
        self.overflowNote = overflowNote
        current = files.firstIndex(where: \.needsReview) ?? 0
    }

    /// The batch an inbox intake makes: its files in the order they were offered, the unreadable ones already settled
    /// as cards.
    public init(_ intake: ImportInbox.Intake) {
        var files: [File] = []
        for entry in intake.entries {
            switch entry {
            case .file(let item): files.append(File(id: item.id, name: item.fileName))
            case .unsupported(let name, let reason): files.append(File(id: UUID(), name: name, kind: .cantRead, problem: reason))
            }
        }
        self.init(files: files, overflowNote: intake.overflowNote)
    }

    // MARK: Classification

    /// Where a read file goes: bank statements to the statement review, everything else the engine reads (utility
    /// bills, invoices, receipts, tenancy and tax papers, a photo of any of them) to Check & link.
    public static func kind(of proposal: CheckAndLinkProposal) -> Kind {
        switch proposal {
        case .statement: .statement
        case .utilityBill, .document: .document
        }
    }

    /// A photo is never a statement: its numbers can't be trusted (statements must be PDF, CSV or OFX).
    public static func kind(of proposal: CheckAndLinkProposal, fileExtension: String) -> Kind {
        let kind = kind(of: proposal)
        return kind == .statement && !["pdf", "csv", "ofx", "qfx"].contains(fileExtension.lowercased()) ? .cantRead : kind
    }

    // MARK: Order and position

    public var count: Int { files.count }
    public var currentFile: File? { files.indices.contains(current) ? files[current] : nil }
    /// "File 2 of 3" (VoiceOver reads the page dots as this).
    public var positionLabel: String { "File \(current + 1) of \(files.count)" }

    public func index(of id: UUID) -> Int? { files.firstIndex { $0.id == id } }

    public mutating func setKind(_ kind: Kind, for id: UUID, problem: String? = nil) {
        guard let index = index(of: id) else { return }
        files[index].kind = kind
        if let problem { files[index].problem = problem }
    }

    /// Records what came of a file, then moves to the next one still waiting (after it, else the first before it).
    /// False when no file is left: the batch is done.
    @discardableResult
    public mutating func finish(_ id: UUID, _ outcome: Outcome) -> Bool {
        guard let index = index(of: id) else { return !isFinished }
        files[index].outcome = outcome
        return advance(from: index)
    }

    /// "Not now": the file stays out of the batch's totals and is listed as not imported.
    @discardableResult
    public mutating func skip(_ id: UUID) -> Bool { finish(id, .notImported) }

    /// A file that can't be read, acknowledged with "Next file".
    @discardableResult
    public mutating func acknowledgeUnreadable(_ id: UUID) -> Bool {
        let reason = files[index(of: id) ?? 0].problem ?? ImportInboxCopy.unreadable
        return finish(id, .cantRead(reason: reason))
    }

    /// The swipe to a page.
    public mutating func select(_ index: Int) {
        if files.indices.contains(index) { current = index }
    }

    @discardableResult
    private mutating func advance(from index: Int) -> Bool {
        let after = files.indices.filter { $0 > index }
        let before = files.indices.filter { $0 < index }
        guard let next = (after + before).first(where: { files[$0].needsReview }) else { return false }
        current = next
        return true
    }

    /// Every file settled.
    public var isFinished: Bool { !files.contains(where: \.needsReview) }

    // MARK: Totals and Undo

    public struct Totals: Equatable, Sendable {
        public var newRows = 0
        public var alreadyInMango = 0
        public var documentsSaved = 0
        public var documentsLinked = 0
        public var notImported = 0
        public var cantRead = 0
    }

    public var totals: Totals {
        var totals = Totals()
        for file in files {
            switch file.outcome {
            case .imported(_, _, let rows, let skipped, _):
                totals.newRows += rows
                totals.alreadyInMango += skipped
            case .alreadyInMango(let rows): totals.alreadyInMango += rows
            case .saved(_, _, let linked):
                totals.documentsSaved += 1
                if linked { totals.documentsLinked += 1 }
            case .notImported: totals.notImported += 1
            case .cantRead: totals.cantRead += 1
            case .waiting: break
            }
        }
        return totals
    }

    /// The import runs this batch made: Undo import covers exactly these statements' rows (documents are not in it).
    public var undoRunIds: [Int64] {
        files.compactMap { if case .imported(_, _, _, _, let runId) = $0.outcome { runId } else { nil } }
    }

    /// Marks the runs undone: their files drop out of the totals and Undo is spent.
    public mutating func markUndone(_ runIds: [Int64]) {
        for index in files.indices {
            if case .imported(_, _, _, _, let runId) = files[index].outcome, runIds.contains(runId) { files[index].outcome = .notImported }
        }
    }

    /// "Where it landed", one line per account (rows summed over its files), in the order the files were imported.
    public var accountsTouched: [(accountId: Int64?, name: String?, rows: Int)] {
        var lines: [(accountId: Int64?, name: String?, rows: Int)] = []
        for file in files {
            guard case .imported(let id, let name, let rows, _, _) = file.outcome else { continue }
            if let at = lines.firstIndex(where: { $0.accountId == id && $0.name == name }) {
                lines[at].rows += rows
            } else {
                lines.append((id, name, rows))
            }
        }
        return lines
    }

    public var documentsSaved: [(documentId: Int64?, title: String, linked: Bool)] {
        files.compactMap { if case .saved(let id, let title, let linked) = $0.outcome { (id, title, linked) } else { nil } }
    }

    /// Rows these runs added that no category holds yet ("Review 4 uncategorised").
    public static func uncategorisedRows(runIds: [Int64], db: Database) throws -> Int {
        guard !runIds.isEmpty else { return 0 }
        let marks = runIds.map { _ in "?" }.joined(separator: ",")
        return try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM transaction_ t JOIN importBatch b ON b.id = t.importBatchId
            WHERE b.importRunId IN (\(marks)) AND t.categoryId IS NULL
            """, arguments: StatementArguments(runIds)) ?? 0
    }
}

/// The closing summary's words.
public enum PhoneImportBatchCopy {
    public static let title = "Everything is in"
    public static func newRows(_ count: Int) -> String { "\(count) new \(count == 1 ? "row" : "rows")" }
    public static func alreadyIn(_ count: Int) -> String { "\(count) already in Mango" }
    public static func documentsLinked(_ count: Int) -> String { "\(count) \(count == 1 ? "document" : "documents") linked" }
    public static func documentsSaved(_ count: Int) -> String { "\(count) \(count == 1 ? "document" : "documents") saved" }
    public static func review(uncategorised count: Int) -> String { "Review \(count) uncategorised" }
    public static func undoNote(rows: Int) -> String {
        "Undo removes the \(rows) \(rows == 1 ? "row" : "rows"). Linked documents stay saved."
    }
    public static func allAlreadyIn(_ rows: Int) -> String { "All \(rows) \(rows == 1 ? "row is" : "rows are") already in Mango" }
    public static let doneWithFile = "Done with this file"
    public static func alreadySaved(as name: String) -> String { "Already saved as \(name)" }
}
