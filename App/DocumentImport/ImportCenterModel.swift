// App/DocumentImport/ImportCenterModel.swift
import Foundation
import BudgetCore
import GRDB
import OSLog

/// The one document importer's state for the app (one per database): files handed in from any
/// entry point (File ▸ Import…, the toolbar, a drop on the window, a screen's shortcut) are read
/// into an `ImportPlan`, reviewed on the Imports screen and applied as one undoable run.
/// Every BudgetCore call runs off the main actor (`Task.detached`); the plan is a value held
/// here, replaced only when a reading, a resolution or an apply completes — the review never
/// recomputes it while drawing.
@MainActor
final class ImportCenterModel: ObservableObject {
    enum Phase: Equatable {
        /// Nothing in progress (the screen shows the history).
        case idle
        /// Files being read (into the open review, if there is one).
        case reading(ImportProgress)
        /// A plan waiting for the user.
        case review
        /// Confirm import pressed: the plan is being applied.
        case applying
        /// The last confirmed import.
        case finished(ImportRunSummary)
        /// Reading failed with no review to return to.
        case failed(String)
    }

    /// Why the open review couldn't be confirmed or changed (a filed return would move, the
    /// plan is out of date, a resolution failed): shown over the review, which stays open so
    /// the user can leave items out.
    struct Problem: Equatable {
        var title: String
        var lines: [String]
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var plan: ImportPlan? {
        // The review's sections are worked out once per plan, never while drawing.
        didSet { review = plan.map(ImportReviewState.init) }
    }
    /// The open plan's sections, rows and counts as the review shows them.
    @Published private(set) var review: ImportReviewState?
    /// The names of the properties, people, accounts, tenancies and providers a "which one?"
    /// question offers, read when a review opens.
    @Published private(set) var targetNames = ImportTargetNames()
    @Published var selectedItemId: UUID?
    @Published private(set) var runs: [ImportRun] = []
    /// Each run's files (what became of each), by run.
    @Published private(set) var runFiles: [Int64: [ImportRunFile]] = [:]
    /// The run whose details the history shows beside it.
    @Published var selectedRunId: Int64?
    /// Why the last Undo import… of a run was refused (what changed since), shown with its
    /// details until dismissed or undone.
    @Published private(set) var undoRefusals: [Int64: [ImportUndoConflict]] = [:]
    @Published var problem: Problem?
    /// A resolution is being worked out (the review shows it; further answers wait their turn).
    @Published private(set) var isResolving = false

    /// Shows the Imports screen (ContentView selects it); called when an import starts.
    var onShow: (() -> Void)?
    /// An import was applied or undone: the screens showing what it changed re-read.
    var onDataChanged: (() -> Void)?

    private let dbQueue: DatabaseQueue
    private let library: EvidenceLibrary
    private let pipeline: ImportPipeline
    private let applier: ImportApplier
    private let logger = Logger(subsystem: "com.personal.budget", category: "DocumentImport")

    /// The reading in progress, cancelled by `cancelReading()` / `discard()`.
    private var readingTask: Task<Void, Never>?
    /// Bumped by every reading, so a cancelled one's late progress or result is ignored.
    private var readingGeneration = 0
    /// What the screen showed before the reading started: Cancel returns to it.
    private var phaseBeforeReading: Phase = .idle
    /// Files handed in while a reading or an apply was under way, read next.
    private var queued: [(urls: [URL], intent: ImportIntent, entryPoint: String)] = []
    /// The entry point that opened the review, recorded with the run.
    private var reviewEntryPoint: String?
    /// The last queued resolution: the next one (and Confirm import) waits for it, so each
    /// works on the plan the previous one produced.
    private var resolutionChain: Task<Void, Never>?

    init(dbQueue: DatabaseQueue, databasePath: String?, library: EvidenceLibrary, categorizationService: CategorizationService) {
        self.dbQueue = dbQueue
        self.library = library
        self.pipeline = ImportPipeline(dbQueue: dbQueue, library: library, categorizationService: categorizationService)
        self.applier = ImportApplier(dbQueue: dbQueue, databasePath: databasePath, library: library)
    }

    /// Whether a review is open (reading more files into it counts).
    var hasOpenReview: Bool { plan != nil }

    // MARK: Reading

    /// Reads `urls` (files and folders) into a new review, or into the open one
    /// (`plan(adding:)`), and shows the Imports screen. Files handed in while another reading
    /// or an apply is under way are read after it.
    func start(_ urls: [URL], intent: ImportIntent = .none, entryPoint: String) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        onShow?()
        switch phase {
        case .reading, .applying:
            queued.append((files, intent, entryPoint))
            return
        default:
            break
        }
        read(files, intent: intent, entryPoint: entryPoint)
    }

    private func read(_ urls: [URL], intent: ImportIntent, entryPoint: String) {
        phaseBeforeReading = phase
        problem = nil
        readingGeneration += 1
        let generation = readingGeneration
        phase = .reading(ImportProgress(completed: 0, total: 0))
        let pipeline = pipeline
        let pendingResolutions = resolutionChain
        // Held only while the reading runs.
        let progress: @Sendable (ImportProgress) -> Void = { update in
            Task { @MainActor in self.readingProgressed(update, generation: generation) }
        }
        // A cancelled reading winds down first (it stops at its next file), so two readings
        // never run at once.
        let previousReading = readingTask
        readingTask = Task { [weak self] in
            await previousReading?.value
            // Read into the plan the answers given so far produced.
            await pendingResolutions?.value
            let result: Result<ImportPlan, Error>
            do {
                try Task.checkCancellation()
                let existing = self?.plan
                // Cancelling this task (Cancel, Discard) cancels the detached planning too.
                result = .success(try await DetachedWork.run(priority: .userInitiated) {
                    if let existing {
                        return try await pipeline.plan(adding: urls, to: existing, intent: intent, progress: progress)
                    }
                    return try await pipeline.plan(urls, intent: intent, progress: progress)
                })
            } catch {
                result = .failure(error)
            }
            self?.readingFinished(result, generation: generation, entryPoint: entryPoint)
        }
    }

    private func readingProgressed(_ update: ImportProgress, generation: Int) {
        // Files finish out of order (several are read at once): the count only goes up.
        guard generation == readingGeneration, case .reading(let shown) = phase, update.completed >= shown.completed else { return }
        phase = .reading(update)
    }

    private func readingFinished(_ result: Result<ImportPlan, Error>, generation: Int, entryPoint: String) {
        guard generation == readingGeneration else { return }
        readingTask = nil
        switch result {
        case .success(let read):
            if plan == nil { reviewEntryPoint = entryPoint }
            plan = read
            loadTargetNames()
            phase = .review
            if selectedItemId == nil || !read.items.contains(where: { $0.id == selectedItemId }) {
                selectedItemId = read.items(in: .needsYou).first?.id ?? read.items.first?.id
            }
        case .failure(let error) where error is CancellationError:
            phase = phaseBeforeReading
        case .failure(let error):
            logger.error("Reading the import failed: \(error.localizedDescription, privacy: .public)")
            let message = "Couldn't read the files: \(error.localizedDescription)"
            if plan != nil {
                phase = .review
                problem = Problem(title: message, lines: [])
            } else {
                phase = .failed(message)
            }
        }
        startQueued()
    }

    /// Stops the reading in progress and returns to what was on show before it (the open
    /// review is kept as it was).
    func cancelReading() {
        guard case .reading = phase else { return }
        readingGeneration += 1
        // Kept (not cleared) so the next reading waits for it to wind down.
        readingTask?.cancel()
        queued.removeAll()
        phase = phaseBeforeReading
    }

    private func startQueued() {
        guard !queued.isEmpty else { return }
        switch phase {
        case .reading, .applying: return
        default: break
        }
        let next = queued.removeFirst()
        read(next.urls, intent: next.intent, entryPoint: next.entryPoint)
    }

    // MARK: Reviewing

    /// Applies the user's answer to one item (`ImportPipeline.resolve`). Answers are worked out
    /// one after another, each on the plan the previous one produced.
    func resolve(_ itemId: UUID, _ resolution: ImportResolution) {
        resolve(itemId, issueId: nil, resolution)
    }

    /// `resolve` answering one issue of the item.
    func resolve(_ itemId: UUID, issueId: String?, _ resolution: ImportResolution) {
        // The review is read only while files are read into it or it is being applied (the
        // screen disables it): an answer given then is refused out loud, never dropped.
        guard phase == .review, plan != nil else {
            problem = Problem(title: "That answer wasn't applied: wait until the review is ready, then answer again", lines: [])
            return
        }
        let previous = resolutionChain
        let pipeline = pipeline
        isResolving = true
        let task = Task { [weak self] in
            await previous?.value
            // A reading or Confirm import started meanwhile waits for this answer; a discarded
            // review has no plan.
            guard let self, let current = self.plan else { return }
            let result = await Result.catching {
                try await DetachedWork.run(priority: .userInitiated) {
                    try await pipeline.resolve(current, itemId: itemId, issueId: issueId, resolution)
                }
            }
            // Discarded (or replaced by a new reading) meanwhile: the answer no longer applies.
            guard self.plan == current else { return }
            switch result {
            case .success(let resolved):
                self.plan = resolved
                self.problem = nil
            case .failure(let error):
                self.logger.error("Resolving an import item failed: \(error.localizedDescription, privacy: .public)")
                self.problem = Problem(title: "Couldn't apply that answer: \(error.localizedDescription)", lines: [])
            }
        }
        resolutionChain = task
        Task { [weak self] in
            await task.value
            guard let self, self.resolutionChain == task else { return }
            self.resolutionChain = nil
            self.isResolving = false
        }
    }

    /// Applies the review as one undoable run. If it can't be applied (a filed return would
    /// move, the plan is out of date) nothing is written and the review stays open with why.
    func confirm() {
        guard phase == .review, plan != nil else { return }
        let previous = resolutionChain
        let applier = applier
        let pipeline = pipeline
        let entryPoint = reviewEntryPoint ?? "Import"
        let now = AppClock.now
        phase = .applying
        problem = nil
        Task { [weak self] in
            await previous?.value
            guard let self, let plan = self.plan else { return }
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ImportRunSummary, Error> in
                Result { try applier.apply(plan, entryPoint: entryPoint, now: now) }
            }.value
            // The batch would move a filed return: every item is checked again so the holds
            // land on the items that cause it.
            var rechecked: ImportPlan?
            if case .failure(ImportApplyError.filedYearChanged(_)) = result {
                do {
                    rechecked = try await DetachedWork.run(priority: .userInitiated) { try await pipeline.recheckFiledYears(plan) }
                } catch {
                    self.logger.error("Checking the import's items against the filed returns failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            self.applyFinished(result, rechecked: rechecked)
        }
    }

    private func applyFinished(_ result: Result<ImportRunSummary, Error>, rechecked: ImportPlan? = nil) {
        switch result {
        case .success(let summary):
            pipeline.discardPlanningCopy()
            plan = nil
            selectedItemId = nil
            reviewEntryPoint = nil
            phase = .finished(summary)
            selectedRunId = summary.runId
            loadRuns()
            onDataChanged?()
        case .failure(let error):
            phase = .review
            if let rechecked {
                plan = rechecked
                if let held = rechecked.items.first(where: \.isHeldByFiledYear) { selectedItemId = held.id }
            }
            problem = Self.problem(for: error, held: rechecked?.items.filter(\.isHeldByFiledYear).map(\.title) ?? [])
            if case ImportApplyError.notConfirmable = error {} else {
                logger.error("Applying the import failed: \(String(describing: error), privacy: .public)")
            }
        }
        startQueued()
    }

    /// What the review says when Confirm import fails; `held`: the items the filed-year check
    /// now holds in Needs you (named first).
    static func problem(for error: Error, held: [String] = []) -> Problem {
        switch error {
        case ImportApplyError.notConfirmable:
            return Problem(title: "Settle everything in Needs you first", lines: [])
        case ImportApplyError.filedYearChanged(let impacts):
            let names = held.isEmpty ? [] : ["Held in Needs you: \(held.joined(separator: ", "))"]
            let lines = names + impacts.flatMap { [$0.headline] + $0.explanation }
            return Problem(title: "Nothing was imported: this import would change a filed return. Leave out the items that cause it.",
                           lines: lines)
        case ImportApplyError.planOutdated(let reason):
            return Problem(title: "Nothing was imported: the review is out of date. Leave the item out or import its file again.",
                           lines: [reason])
        default:
            return Problem(title: "Nothing was imported: \(error.localizedDescription)", lines: [])
        }
    }

    /// Closes the review (or the reading, or the last result) without writing anything.
    func discard() {
        // An apply under way finishes (it is one transaction); its result then shows.
        guard phase != .applying else { return }
        readingGeneration += 1
        // Kept (not cleared) so the next reading waits for it to wind down.
        readingTask?.cancel()
        queued.removeAll()
        plan = nil
        pipeline.discardPlanningCopy()
        selectedItemId = nil
        reviewEntryPoint = nil
        problem = nil
        phase = .idle
    }

    /// Re-reads the names a target question offers (off the main actor).
    private func loadTargetNames() {
        let dbQueue = dbQueue
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ImportTargetNames, Error> in
                Result { try dbQueue.read { db in try ImportTargetNames.read(db) } }
            }.value
            switch result {
            case .success(let names): self?.targetNames = names
            case .failure(let error):
                self?.logger.error("Reading the import's target names failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    #if SNAPSHOTS
    /// `urls` read by the real pipeline (snapshot routes only: the demo's import samples).
    func snapshotPlan(_ urls: [URL]) async throws -> ImportPlan {
        let pipeline = pipeline
        return try await DetachedWork.run(priority: .userInitiated) { try await pipeline.plan(urls) }
    }

    /// `plan` with every Needs-you item left out (snapshot routes only).
    func snapshotLeavingOutNeedsYou(_ plan: ImportPlan) async throws -> ImportPlan {
        let pipeline = pipeline
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
        let applier = applier
        let now = AppClock.now
        let summary = try await Task.detached(priority: .userInitiated) { try applier.apply(plan, entryPoint: entryPoint, now: now) }.value
        pipeline.discardPlanningCopy()
        self.plan = nil
        selectedItemId = nil
        reviewEntryPoint = nil
        phase = .finished(summary)
        await reloadRuns()
        selectedRunId = summary.runId
    }

    /// Changes one row the demo samples' run added (a note on a document it filed), then asks
    /// to undo the run, which is refused (snapshot routes only: it writes to the demo copy).
    func snapshotRefusedUndo() async throws {
        guard let run = runs.first(where: { $0.entryPoint == "Demo samples" && $0.undoneAt == nil }), let runId = run.id else {
            throw SnapshotMissing("The demo samples' import run")
        }
        let changed = try await dbQueue.write { db -> Bool in
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
        self.plan = plan
        reviewEntryPoint = "Snapshot"
        selectedItemId = itemId
        phase = .review
        loadTargetNames()
    }
    #endif

    // MARK: History

    /// Re-reads the import history, newest first, with each run's files.
    func loadRuns() {
        Task { [weak self] in await self?.reloadRuns() }
    }

    /// `loadRuns`, finished when the history is read.
    func reloadRuns() async {
        let dbQueue = dbQueue
        let result = await Task.detached(priority: .userInitiated) { () -> Result<([ImportRun], [ImportRunFile]), Error> in
            Result {
                try dbQueue.read { db in
                    (try ImportRun.order(Column("confirmedAt").desc, Column("id").desc).fetchAll(db),
                     try ImportRunFile.order(Column("runId"), Column("id")).fetchAll(db))
                }
            }
        }.value
        switch result {
        case .success(let (runs, files)):
            self.runs = runs
            runFiles = Dictionary(grouping: files, by: \.runId)
            if let selected = selectedRunId, !runs.contains(where: { $0.id == selected }) { selectedRunId = nil }
        case .failure(let error):
            logger.error("Reading the import history failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Undoes a confirmed run. Returns why it can't be undone now (nothing was changed), or
    /// nothing when it was undone; throws when the run is gone or already undone.
    func undo(_ runId: Int64) async throws -> [ImportUndoConflict] {
        let dbQueue = dbQueue
        let library = library
        let now = AppClock.now
        let result = await Task.detached(priority: .userInitiated) { () -> Result<ImportUndoResult, Error> in
            Result { try ImportUndo.undo(dbQueue: dbQueue, library: library, runId: runId, now: now) }
        }.value
        switch result {
        case .success:
            undoRefusals[runId] = nil
            loadRuns()
            onDataChanged?()
            return []
        case .failure(ImportUndoError.refused(let conflicts)):
            undoRefusals[runId] = conflicts
            return conflicts
        case .failure(let error):
            throw error
        }
    }
}

extension ImportCenterModel {
    /// Hides why a run's undo was refused.
    func dismissUndoRefusal(_ runId: Int64) {
        undoRefusals[runId] = nil
    }
}

private extension Result where Failure == Error {
    /// `Result(catching:)` for an async body.
    static func catching(_ body: () async throws -> Success) async -> Result<Success, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}
