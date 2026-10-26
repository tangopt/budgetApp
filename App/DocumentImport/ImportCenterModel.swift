// App/DocumentImport/ImportCenterModel.swift
import AppKit
import Foundation
import BudgetCore
import GRDB
import UniformTypeIdentifiers

/// The Mac's document importer (one per database): a thin wrapper of BudgetCore's
/// `ImportSession`, which makes every decision — reading, answering, rule fits, Confirm import,
/// undo — and holds the review's state. This keeps what is the Mac's own: the open panel, the
/// session's lock when a panel closes, showing the Imports screen and its window, who is
/// signed in when Confirm import is pressed, and the planning copy released when the app quits.
///
/// The views read the session's state through this model. The session is `@Observable`, so
/// SwiftUI tracks those reads while drawing; `phase` is also republished (`$phase`) for
/// ContentView's Combine subscriber.
@MainActor
final class ImportCenterModel: ObservableObject {
    typealias Phase = ImportSession.Phase
    typealias Problem = ImportSession.Problem
    typealias AnswerProblem = ImportSession.AnswerProblem
    typealias RuleFitsReview = ImportSession.RuleFitsReview
    typealias PendingUndo = ImportSession.PendingUndo

    /// The importer's decisions and state.
    let session: ImportSession

    @Published private(set) var phase: Phase = .idle
    var plan: ImportPlan? { session.plan }
    /// The transactions the open plan links to or offers, as the preview's peek shows them.
    var linkedTransactions: [Int64: ImportTransactionCandidate] { session.linkedTransactions }
    /// The peeks the user opened, by transaction (kept while the review is open).
    var expandedPeeks: Set<Int64> {
        get { session.expandedPeeks }
        set { session.expandedPeeks = newValue }
    }
    /// The item whose "Link to a transaction…" search is open over its preview.
    var linkSearchItemId: UUID? {
        get { session.linkSearchItemId }
        set { session.linkSearchItemId = newValue }
    }
    /// The open plan's sections, rows and counts as the review shows them.
    var review: ImportReviewState? { session.review }
    /// The names a "which one?" question offers.
    var targetNames: ImportTargetNames { session.targetNames }
    /// The accounts by id: a statement's layout wizard and its account picker.
    var accounts: [Int64: Account] { session.accounts }
    /// A kind's name, a custom kind's included.
    func kindLabel(_ kind: ImportKind) -> String { session.kindLabel(kind) }
    /// The last answer refused beside its question.
    var answerProblem: AnswerProblem? {
        get { session.answerProblem }
        set { session.answerProblem = newValue }
    }
    var selectedItemId: UUID? {
        get { session.selectedItemId }
        set { session.selectedItemId = newValue }
    }
    var runs: [ImportRun] { session.runs }
    /// Each run's files (what became of each), by run.
    var runFiles: [Int64: [ImportRunFile]] { session.runFiles }
    /// Display names of the app users, for "Confirmed by <name>" in the history.
    var userNames: [Int64: String] { session.userNames }
    /// The run whose details the history shows beside it.
    var selectedRunId: Int64? {
        get { session.selectedRunId }
        set { session.selectedRunId = newValue }
    }
    /// Why the last Undo import… of a run was refused (what changed since).
    var undoRefusals: [Int64: [ImportUndoConflict]] { session.undoRefusals }
    var problem: Problem? {
        get { session.problem }
        set { session.problem = newValue }
    }
    /// A resolution is being worked out (the review shows it; further answers wait their turn).
    var isResolving: Bool { session.isResolving }
    /// Per document with a correction that drafts a rule, the other documents of the review the rule fits.
    var ruleFits: [UUID: [ImportRuleFit]] { session.ruleFits }
    /// The document whose rule's fits are open for review (the sheet).
    var ruleFitsReview: RuleFitsReview? {
        get { session.ruleFitsReview }
        set { session.ruleFitsReview = newValue }
    }
    /// An undo that would take back a rule other documents were changed by, waiting for the user.
    var pendingUndo: PendingUndo? {
        get { session.pendingUndo }
        set { session.pendingUndo = newValue }
    }
    /// How many library documents each library shortcut would bring (its "From library (N)").
    var libraryCounts: ImportLibraryCounts { session.libraryCounts }

    /// The files kept for later, newest first (Waiting for later).
    var waiting: [ImportWaitingFile] { session.waiting }
    /// Whether the waiting file is in the open review (its copy is read there: not to discard meanwhile).
    func isInOpenReview(_ file: ImportWaitingFile) -> Bool { session.isInOpenReview(file) }
    /// The files the finished run left unimported, once per run (`ImportSession.takeSetAsideOffer`).
    func takeSetAsideOffer() -> [SetAsideFile] { session.takeSetAsideOffer() }
    /// The open review's files that can be set aside before it is discarded.
    func setAsideCandidates() -> [SetAsideFile] { session.setAsideCandidates() }

    /// The signed-in app user, read when Confirm is pressed; nil: nobody.
    private let currentAppUserId: () -> Int64?

    /// Shows the Imports screen (ContentView selects it); called when an import starts.
    var onShow: (() -> Void)?
    /// Brings the window whose Imports screen `onShow` selects to the front (ContentView's own).
    var onBringForward: (() -> Void)?
    /// An import was applied or undone: the screens showing what it changed re-read.
    var onDataChanged: (@MainActor () -> Void)? {
        get { session.onDataChanged }
        set { session.onDataChanged = newValue }
    }
    /// Shows a learnt rule on the Rules page (Rules ▸ Import rules, the rule selected): "Show on Rules page".
    var onShowImportRule: ((Int64) -> Void)?

    #if SNAPSHOTS
    private let dbQueue: DatabaseQueue
    private let library: EvidenceLibrary
    private let categorizationService: CategorizationService
    #endif
    /// Releases the planning copy when the app quits.
    private var terminationObserver: NSObjectProtocol?

    /// `modelReader`: the on-device model asked about what nothing else recognises (nil: never asked).
    init(dbQueue: DatabaseQueue, databasePath: String?, library: EvidenceLibrary, categorizationService: CategorizationService,
         modelReader: (any DocumentModelReading)?, currentAppUserId: @escaping () -> Int64? = { nil }) {
        self.currentAppUserId = currentAppUserId
        #if SNAPSHOTS
        self.dbQueue = dbQueue
        self.library = library
        self.categorizationService = categorizationService
        #endif
        self.session = ImportSession(dbQueue: dbQueue, databasePath: databasePath, library: library,
                                     categorizationService: categorizationService, modelReader: modelReader,
                                     now: { AppClock.now })
        session.onPhaseChange = { [weak self] phase in self?.phase = phase }
        // The planning copy (a temporary file) never outlives the app.
        let pipeline = session.pipeline
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                                     queue: nil) { _ in pipeline.discardPlanningCopy() }
    }

    isolated deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    /// Whether a review is open (reading more files into it counts).
    var hasOpenReview: Bool { session.hasOpenReview }

    // MARK: Reading

    /// Reads `urls` for a screen's import shortcut: its intent and entry point reach the run.
    func start(_ urls: [URL], shortcut: ImportShortcut) {
        start(urls, intent: shortcut.intent, entryPoint: shortcut.entryPoint)
    }

    /// The one open panel every import entry uses: returns the chosen URLs, or nil when cancelled.
    static func chooseURLs(types: [UTType] = [], multiple: Bool, folders: Bool, message: String) -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = folders
        panel.allowsMultipleSelection = multiple
        if !types.isEmpty { panel.allowedContentTypes = types }
        panel.prompt = "Import"
        panel.message = message
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return nil }
        // Mango locked while the panel was open (the lock cancels it, but a choice may have just landed).
        guard SessionModel.appCanActOnData else { return nil }
        return panel.urls
    }

    /// Asks for files with the shortcut's open panel (its file types, one or several), then reads
    /// them. False when the panel was cancelled (nothing is read).
    @discardableResult
    func pickFiles(for shortcut: ImportShortcut) -> Bool {
        guard let urls = Self.chooseURLs(types: shortcut.allowedContentTypes.compactMap { UTType($0) },
                                         multiple: shortcut.allowsMultiple, folders: shortcut.allowsFolders,
                                         message: "Nothing is saved until you confirm the import.") else { return false }
        start(urls, shortcut: shortcut)
        return true
    }

    /// The shortcut's library documents read into a new review or the open one
    /// (`ImportSession.startFromLibrary`), the Imports screen shown. False when there are none.
    @discardableResult
    func startFromLibrary(_ shortcut: ImportShortcut) -> Bool {
        guard session.startFromLibrary(shortcut) else { return false }
        onShow?()
        return true
    }

    /// Reads `urls` (files and folders) into a new review, or into the open one, and shows the
    /// Imports screen (`ImportSession.start`).
    func start(_ urls: [URL], intent: ImportIntent = .none, entryPoint: String) {
        if session.start(urls, intent: intent, entryPoint: entryPoint) { onShow?() }
    }

    /// Reads a source folder's new and changed files and shows the Imports screen
    /// (`ImportSession.start(folder:inputs:)`).
    func start(folder: SourceFolder, inputs: [SourceFolderImport.Input]) {
        if session.start(folder: folder, inputs: inputs) { onShow?() }
    }

    /// Stops the reading in progress and returns to what was on show before it.
    func cancelReading() {
        session.cancelReading()
    }

    // MARK: Reviewing

    /// Applies the user's answer to one item (`ImportSession.resolve`).
    func resolve(_ itemId: UUID, _ resolution: ImportResolution) {
        session.resolve(itemId, resolution)
    }

    /// `resolve` answering one issue of the item (`ImportSession.resolve(_:issueId:_:)`).
    func resolve(_ itemId: UUID, issueId: String?, _ resolution: ImportResolution) {
        session.resolve(itemId, issueId: issueId, resolution)
    }

    /// The undo `pendingUndo` asked about: "Undo all" or "Keep them".
    func finishPendingUndo(alsoOthers: Bool) {
        session.finishPendingUndo(alsoOthers: alsoOthers)
    }

    /// The other documents the item's rule fits, opened for review (`ruleFits`).
    func reviewRuleFits(_ sourceId: UUID) {
        session.reviewRuleFits(sourceId)
    }

    /// The source's rules applied to the ticked documents.
    func applyRule(from sourceId: UUID, to itemIds: Set<UUID>) {
        session.applyRule(from: sourceId, to: itemIds)
    }

    /// The change a rule from another document made on the item, taken back.
    func undoRuleChange(_ itemId: UUID) {
        session.undoRuleChange(itemId)
    }

    /// Every change the item's rules made on the other documents, taken back.
    func undoRuleChanges(from sourceId: UUID) {
        session.undoRuleChanges(from: sourceId)
    }

    /// Applies the review as one undoable run, confirmed by whoever is signed in now — not
    /// whoever opened the review (the lock may have changed hands).
    func confirm() {
        session.confirm(confirmedBy: currentAppUserId())
    }

    /// What the review says when Confirm import fails (`ImportSession.problem(for:held:)`).
    static func problem(for error: Error, held: [String] = []) -> Problem {
        ImportSession.problem(for: error, held: held)
    }

    /// Closes the review (or the reading, or the last result) without writing anything.
    func discard() {
        session.discard()
    }

    /// Every transaction the plan's items link to or a "which one?" offers.
    static func transactionIds(in plan: ImportPlan) -> [Int64] {
        ImportSession.transactionIds(in: plan)
    }

    /// The review's transaction search; the results are remembered for the peek.
    func searchTransactions(_ query: ImportTransactionQuery) async throws -> [ImportTransactionCandidate] {
        try await session.searchTransactions(query)
    }

    /// The transactions `ids` as the peek shows them (read now when not read yet).
    func transactions(_ ids: [Int64]) async throws -> [ImportTransactionCandidate] {
        try await session.transactions(ids)
    }

    /// The item's issuer key (`IssuerKey.derive`, as the pipeline derives it): nil when it has none.
    func issuerKey(of item: ImportItem) -> IssuerKey? {
        session.issuerKey(of: item)
    }

    /// "Show on Rules page": the learnt rule on the Rules page.
    func showImportRule(_ id: Int64) {
        onShowImportRule?(id)
    }

    #if SNAPSHOTS
    /// `urls` read by the real pipeline (snapshot routes only: the demo's import samples);
    /// `modelReader` stands in for the on-device model (snapshot mode has none).
    func snapshotPlan(_ urls: [URL], intent: ImportIntent = .none, libraryDocuments: [Int64] = [],
                      modelReader: (any DocumentModelReading)? = nil) async throws -> ImportPlan {
        let pipeline = modelReader.map { ImportPipeline(dbQueue: dbQueue, library: library, categorizationService: categorizationService,
                                                        modelReader: $0) } ?? session.pipeline
        defer { if modelReader != nil { pipeline.discardPlanningCopy() } }
        return try await DetachedWork.run(priority: .userInitiated) {
            try await pipeline.plan(adding: urls, libraryDocuments: libraryDocuments, to: ImportPlan(items: []), intent: intent)
        }
    }

    /// The folder at `url` registered as a source folder, scanned, and its new and changed files
    /// planned as Scan Now hands them over (snapshot routes only: it writes the folder to the demo copy).
    func snapshotPlan(folder url: URL) async throws -> ImportPlan {
        let scanner = SourceFolderScanner(library: library), pipeline = session.pipeline
        return try await DetachedWork.run(priority: .userInitiated) {
            let folder = try scanner.register(url)
            let result = try scanner.scan(folder, options: .init(analyzeNewFiles: false))
            return try await pipeline.plan(folder: result.folder, scanner: scanner, inputs: SourceFolderImport.inputs(from: result))
        }
    }

    /// `plan` with one answer (snapshot routes only).
    func snapshotResolve(_ plan: ImportPlan, itemId: UUID, _ resolution: ImportResolution) async throws -> ImportPlan {
        let pipeline = session.pipeline
        return try await DetachedWork.run(priority: .userInitiated) { try await pipeline.resolve(plan, itemId: itemId, resolution) }
    }

    /// The other documents each correction's rule fits in `plan` (snapshot routes only).
    func snapshotRuleFits(_ plan: ImportPlan) async throws -> [UUID: [ImportRuleFit]] {
        let pipeline = session.pipeline
        return try await DetachedWork.run(priority: .userInitiated) { try await pipeline.ruleFits(plan) }
    }

    /// `plan` with the source's rules applied to `itemIds` (snapshot routes only).
    func snapshotApplyRule(_ plan: ImportPlan, from sourceId: UUID, to itemIds: Set<UUID>) async throws -> ImportPlan {
        let pipeline = session.pipeline
        return try await DetachedWork.run(priority: .userInitiated) { try await pipeline.applyRule(plan, from: sourceId, to: itemIds) }
    }

    /// `plan` with every Needs-you item left out (snapshot routes only).
    func snapshotLeavingOutNeedsYou(_ plan: ImportPlan) async throws -> ImportPlan {
        let pipeline = session.pipeline
        var result = plan
        for item in plan.items(in: .needsYou) {
            let current = result
            result = try await DetachedWork.run(priority: .userInitiated) { try await pipeline.resolve(current, itemId: item.id, .leaveOut) }
        }
        return result
    }

    /// Applies `plan` as Confirm import does and shows the history with the new run selected
    /// (snapshot routes only: it writes to the demo copy).
    func snapshotApply(_ plan: ImportPlan, entryPoint: String) async throws {
        try await session.applyShowingHistory(plan, entryPoint: entryPoint)
    }

    /// Changes one row the demo samples' run added (a note on a document it filed), then asks
    /// to undo the run, which is refused (snapshot routes only: it writes to the demo copy).
    func snapshotRefusedUndo() async throws {
        guard let run = runs.first(where: { $0.entryPoint == "Demo samples" && $0.undoneAt == nil }), let runId = run.id else {
            throw SnapshotMissing("The demo samples' import run")
        }
        let changed = try await dbQueue.write(.documents) { db -> Bool in
            guard let documentId = try Int64.fetchOne(db, sql: """
                SELECT rowId FROM \(ImportChange.databaseTableName) WHERE runId = ? AND tableName = ? AND operation = ? ORDER BY seq LIMIT 1
                """, arguments: [runId, EvidenceDocument.databaseTableName, ImportChangeOperation.insert.rawValue]) else { return false }
            try db.execute(sql: "UPDATE \(EvidenceDocument.databaseTableName) SET note = ? WHERE id = ?",
                           arguments: ["Checked by hand", documentId])
            return db.changesCount > 0
        }
        guard changed else { throw SnapshotMissing("A document the demo samples' run filed") }
        guard try await !undo(runId).isEmpty else { throw SnapshotMissing("A refusal of the demo samples' undo") }
        selectedRunId = runId
    }

    /// Opens `plan` as the review (snapshot routes only: an invented plan).
    func showSnapshotPlan(_ plan: ImportPlan, selecting itemId: UUID?) {
        session.show(plan, entryPoint: "Snapshot", selecting: itemId)
    }
    #endif

    // MARK: Set aside and the waiting list

    /// Re-reads the waiting list (purged, re-read when the recognisers changed). Call on opening the
    /// Imports screen and after a kind is saved; Confirm import, Undo, keeping and discarding do it themselves.
    func refreshWaiting() {
        session.refreshWaiting()
    }

    /// Keeps `files` for later in Mango's own copy (off the main actor). Throws when the list can't be written;
    /// files that can't be kept are in the result's `failed`.
    func keepForLater(_ files: [SetAsideFile]) async throws -> ImportWaitingList.KeepResult {
        try await session.keep(files)
    }

    /// Asks for a folder (Mango's open panel), nil when cancelled.
    static func chooseFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Copy here"
        panel.message = message
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // Mango locked while the panel was open (the lock cancels it, but a choice may have just landed).
        guard SessionModel.appCanActOnData else { return nil }
        return url
    }

    /// Copies `files` to a folder the user chooses (the original when it still exists, else Mango's copy);
    /// nil when the panel was cancelled. The copying runs off the main actor; nothing is overwritten.
    func copyToFolder(_ files: [SetAsideFile]) async -> SetAsideCopyOutcome? {
        guard let folder = Self.chooseFolder(message: files.count == 1 ? "Choose where to copy the file." : "Choose where to copy the files.")
        else { return nil }
        let list = session.waitingList, waiting = session.waiting
        let wanted = Set(files.map { $0.sha256.lowercased() })
        // Only the files being copied are looked up, off the main actor.
        let result = await Task.detached(priority: .userInitiated) {
            let copies = Dictionary(waiting.filter { wanted.contains($0.sha256) }.compactMap { row in list.fileURL(row).map { (row.sha256, $0) } },
                                    uniquingKeysWith: { first, _ in first })
            return ImportSetAside.copy(files, waitingCopy: { copies[$0.lowercased()] }, to: folder)
        }.value
        return SetAsideCopyOutcome(folder: folder, copied: result.copied.count, failed: result.failed)
    }

    /// `copyToFolder` for a waiting file (Mango's copy); an outcome with a failure when its copy isn't here.
    func copyToFolder(_ file: ImportWaitingFile) async -> SetAsideCopyOutcome? {
        guard let setAside = session.waitingList.setAsideFile(file) else {
            return SetAsideCopyOutcome(folder: nil, copied: 0, failed: [ImportSetAsideFailure(fileName: file.originalFileName, reason: "Mango's copy isn't here")])
        }
        return await copyToFolder([setAside])
    }

    /// Removes the waiting files `ids` and Mango's copies (the user confirmed).
    func discardWaiting(_ ids: [Int64]) async throws {
        try await session.discardWaiting(ids)
    }

    /// Reads the waiting files `ids` into a review (`ImportSession.importWaiting`); false when none of them is here.
    @discardableResult
    func importWaiting(_ ids: [Int64]) -> Bool {
        guard session.importWaiting(ids) else { return false }
        onShow?()
        return true
    }

    // MARK: History

    /// Re-reads the import history, newest first, with each run's files.
    func loadRuns() {
        session.loadRuns()
        session.refreshWaiting()
    }

    /// `loadRuns`, finished when the history is read.
    func reloadRuns() async {
        await session.reloadRuns()
    }

    /// Undoes a confirmed run. Returns why it can't be undone now (nothing was changed), or
    /// nothing when it was undone; throws when the run is gone or already undone.
    func undo(_ runId: Int64) async throws -> [ImportUndoConflict] {
        // As the signed-in user (step 6: Edit on Import).
        try await session.undo(runId, undoneBy: currentAppUserId())
    }
}

extension ImportCenterModel {
    /// Hides why a run's undo was refused.
    func dismissUndoRefusal(_ runId: Int64) {
        session.dismissUndoRefusal(runId)
    }
}

/// What copying files to a folder did: how many were copied, and the files that couldn't be, with why.
struct SetAsideCopyOutcome: Equatable {
    /// The folder copied to.
    var folder: URL?
    var copied: Int
    var failed: [ImportSetAsideFailure]
}
