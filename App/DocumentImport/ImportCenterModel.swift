// App/DocumentImport/ImportCenterModel.swift
import AppKit
import Foundation
import BudgetCore
import GRDB
import OSLog
import UniformTypeIdentifiers

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

    /// Why an answer to one question wasn't taken, shown beside that question (the item stays
    /// as it was): an "Import anyway" with a blank reason.
    struct AnswerProblem: Equatable {
        var itemId: UUID
        var issueId: String?
        var message: String
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var plan: ImportPlan? {
        // The review's sections are worked out once per plan, never while drawing.
        didSet {
            review = plan.map(ImportReviewState.init)
            loadLinkedTransactions()
            loadRuleFits()
            // The issuer keys of files no longer in the review go.
            let hashes = Set(plan?.items.map(\.file.sha256) ?? [])
            issuerKeys = issuerKeys.filter { hashes.contains($0.key) }
        }
    }
    /// The transactions the open plan links to or offers, as the preview's peek shows them,
    /// read off the main actor when a plan arrives (`loadLinkedTransactions`).
    @Published private(set) var linkedTransactions: [Int64: ImportTransactionCandidate] = [:]
    /// The peeks the user opened, by transaction (kept while the review is open).
    @Published var expandedPeeks: Set<Int64> = []
    /// The item whose "Link to a transaction…" search is open over its preview.
    @Published var linkSearchItemId: UUID?
    /// The open plan's sections, rows and counts as the review shows them.
    @Published private(set) var review: ImportReviewState?
    /// The names of the properties, people, accounts, tenancies and providers a "which one?"
    /// question offers, read when a review opens.
    @Published private(set) var targetNames = ImportTargetNames()
    /// The accounts by id, read with the target names: a statement's layout wizard and its
    /// account picker (bank region first).
    @Published private(set) var accounts: [Int64: Account] = [:]
    /// The last answer refused beside its question (`AnswerProblem`).
    @Published var answerProblem: AnswerProblem?
    @Published var selectedItemId: UUID?
    @Published private(set) var runs: [ImportRun] = []
    /// Each run's files (what became of each), by run.
    @Published private(set) var runFiles: [Int64: [ImportRunFile]] = [:]
    /// Display names of the app users, for "Confirmed by <name>" in the history.
    @Published private(set) var userNames: [Int64: String] = [:]
    /// The signed-in app user, read when Confirm is pressed (Task 6 wires it to the session); nil: nobody.
    private let currentAppUserId: () -> Int64?
    /// The run whose details the history shows beside it.
    @Published var selectedRunId: Int64?
    /// Why the last Undo import… of a run was refused (what changed since), shown with its
    /// details until dismissed or undone.
    @Published private(set) var undoRefusals: [Int64: [ImportUndoConflict]] = [:]
    @Published var problem: Problem?
    /// A resolution is being worked out (the review shows it; further answers wait their turn).
    @Published private(set) var isResolving = false
    /// Per document with a correction that drafts a rule, the other documents of the review the
    /// rule fits (`ImportPipeline.ruleFits`), worked out off the main actor when a plan arrives.
    @Published private(set) var ruleFits: [UUID: [ImportRuleFit]] = [:]
    /// The document whose rule's fits are open for review (the sheet).
    @Published var ruleFitsReview: RuleFitsReview?
    /// An undo that would take back a rule other documents were changed by, waiting for the
    /// user to say whether those changes go too.
    @Published var pendingUndo: PendingUndo?

    struct RuleFitsReview: Identifiable, Equatable {
        let sourceId: UUID
        var id: UUID { sourceId }
    }

    struct PendingUndo: Equatable {
        let itemId: UUID
        let resolution: ImportResolution
        /// How many other documents the rule changed.
        let others: Int
    }

    /// Shows the Imports screen (ContentView selects it); called when an import starts.
    var onShow: (() -> Void)?
    /// Brings the window whose Imports screen `onShow` selects to the front (ContentView's own).
    var onBringForward: (() -> Void)?
    /// An import was applied or undone: the screens showing what it changed re-read.
    var onDataChanged: (() -> Void)?
    /// Shows a learnt rule on the Rules page (Rules ▸ Import rules, the rule selected): "Show on Rules page".
    var onShowImportRule: ((Int64) -> Void)?
    /// The people's and tenants' NIFs, never an issuer's (`IssuerKey.knownParties`): read with the target names.
    /// Nil until first read: no issuer key is worked out before (a person's own NIF would key one).
    private var knownParties: Set<String>?
    /// The issuer keys worked out for the preview, by file hash.
    private var issuerKeys: [String: IssuerKey?] = [:]

    private let dbQueue: DatabaseQueue
    private let library: EvidenceLibrary
    /// How many library documents each library shortcut would bring (its "From library (N)").
    let libraryCounts: ImportLibraryCounts
    private let pipeline: ImportPipeline
    private let applier: ImportApplier
    #if SNAPSHOTS
    private let categorizationService: CategorizationService
    #endif
    private let logger = Logger(subsystem: "com.personal.budget", category: "DocumentImport")

    /// The reading in progress, cancelled by `cancelReading()` / `discard()`.
    private var readingTask: Task<Void, Never>?
    /// Bumped by every reading, so a cancelled one's late progress or result is ignored.
    private var readingGeneration = 0
    /// What the screen showed before the reading started: Cancel returns to it.
    private var phaseBeforeReading: Phase = .idle
    /// Files handed in while a reading or an apply was under way, read next.
    private var queued: [(work: Reading, entryPoint: String)] = []
    /// The entry point that opened the review, recorded with the run.
    private var reviewEntryPoint: String?
    /// The last queued resolution: the next one (and Confirm import) waits for it, so each
    /// works on the plan the previous one produced.
    private var resolutionChain: Task<Void, Never>?
    /// The rule fits being worked out (`loadRuleFits`), cancelled when a newer plan arrives.
    private var ruleFitsTask: Task<Void, Never>?
    /// Releases the planning copy when the app quits.
    private var terminationObserver: NSObjectProtocol?

    /// `modelReader`: the on-device model asked about what nothing else recognises (nil: never asked).
    init(dbQueue: DatabaseQueue, databasePath: String?, library: EvidenceLibrary, categorizationService: CategorizationService,
         modelReader: (any DocumentModelReading)?, currentAppUserId: @escaping () -> Int64? = { nil }) {
        self.dbQueue = dbQueue
        self.currentAppUserId = currentAppUserId
        self.library = library
        self.libraryCounts = ImportLibraryCounts(dbQueue: dbQueue)
        #if SNAPSHOTS
        self.categorizationService = categorizationService
        #endif
        self.pipeline = ImportPipeline(dbQueue: dbQueue, library: library, categorizationService: categorizationService,
                                       modelReader: modelReader)
        self.applier = ImportApplier(dbQueue: dbQueue, databasePath: databasePath, library: library)
        // The planning copy (a temporary file) never outlives the app.
        let pipeline = pipeline
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                                     queue: nil) { _ in pipeline.discardPlanningCopy() }
    }

    isolated deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    /// Whether a review is open (reading more files into it counts).
    var hasOpenReview: Bool { plan != nil }

    // MARK: Reading

    /// What a reading reads: files handed in with an intent (and library documents read again,
    /// `ImportShortcut.libraryDocumentIds`), or a source folder's scanned files.
    private enum Reading: Sendable {
        case files([URL], library: [Int64], ImportIntent)
        case folder(SourceFolder, [SourceFolderImport.Input])
    }

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

    /// The shortcut's library documents (`ImportShortcut.libraryDocumentIds`: Utility invoices…'s
    /// "From library") read into a new review or the open one (those already in it skipped).
    /// False when there are none.
    @discardableResult
    func startFromLibrary(_ shortcut: ImportShortcut) -> Bool {
        let ids: [Int64]
        do {
            ids = try dbQueue.read { db in try shortcut.libraryDocumentIds(db: db) }
        } catch {
            logger.error("Finding the library's documents for the import failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        guard !ids.isEmpty else { return false }
        onShow?()
        enqueue(.files([], library: ids, shortcut.intent), entryPoint: shortcut.entryPoint)
        return true
    }

    /// Reads `urls` (files and folders) into a new review, or into the open one
    /// (`plan(adding:)`), and shows the Imports screen. Files handed in while another reading
    /// or an apply is under way are read after it.
    func start(_ urls: [URL], intent: ImportIntent = .none, entryPoint: String) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        onShow?()
        enqueue(.files(files, library: [], intent), entryPoint: entryPoint)
    }

    /// Reads a source folder's new and changed files (`SourceFolderImport.inputs` of its scan)
    /// as `ImportShortcut.sourceFolder` — into a new review, or into the open one (each file
    /// keeping its own intent) — and shows the Imports screen. Read off the main actor inside
    /// the folder's security scope (`ImportPipeline.plan(folder:scanner:inputs:to:)`).
    func start(folder: SourceFolder, inputs: [SourceFolderImport.Input]) {
        guard let folderId = folder.id, !inputs.isEmpty else { return }
        onShow?()
        enqueue(.folder(folder, inputs), entryPoint: ImportShortcut.sourceFolder(folderId: folderId, name: folder.name).entryPoint)
    }

    /// Reads now, or after the reading or apply under way.
    private func enqueue(_ work: Reading, entryPoint: String) {
        switch phase {
        case .reading, .applying:
            queued.append((work, entryPoint))
            return
        default:
            break
        }
        read(work, entryPoint: entryPoint)
    }

    private func read(_ work: Reading, entryPoint: String) {
        phaseBeforeReading = phase
        problem = nil
        readingGeneration += 1
        let generation = readingGeneration
        phase = .reading(ImportProgress(completed: 0, total: 0))
        let pipeline = pipeline, scanner = SourceFolderScanner(library: library)
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
                    switch work {
                    case .files(let urls, let library, let intent):
                        if !library.isEmpty {
                            return try await pipeline.plan(adding: urls, libraryDocuments: library, to: existing ?? ImportPlan(items: []),
                                                           intent: intent, progress: progress)
                        }
                        if let existing {
                            return try await pipeline.plan(adding: urls, to: existing, intent: intent, progress: progress)
                        }
                        return try await pipeline.plan(urls, intent: intent, progress: progress)
                    case .folder(let folder, let inputs):
                        return try await pipeline.plan(folder: folder, scanner: scanner, inputs: inputs,
                                                       to: existing ?? ImportPlan(items: []), progress: progress)
                    }
                })
            } catch {
                result = .failure(error)
            }
            self?.readingFinished(result, generation: generation, entryPoint: entryPoint)
        }
    }

    private func readingProgressed(_ update: ImportProgress, generation: Int) {
        // Files finish out of order (several are read at once), reports arrive in tasks of their
        // own: the stage and its count only go forward.
        guard generation == readingGeneration, case .reading(let shown) = phase, update.isNotBefore(shown) else { return }
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
            // No review to plan against: its copy of the database goes.
            if plan == nil { pipeline.discardPlanningCopy() }
            phase = phaseBeforeReading
        case .failure(let error):
            logger.error("Reading the import failed: \(error.localizedDescription, privacy: .public)")
            let message = "Couldn't read the files: \(error.localizedDescription)"
            if plan != nil {
                phase = .review
                problem = Problem(title: message, lines: [])
            } else {
                pipeline.discardPlanningCopy()
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
        // No review to plan against: its copy of the database goes once the reading winds down
        // (a reading started meanwhile keeps the copy it makes).
        if plan == nil {
            let pipeline = pipeline, generation = readingGeneration
            let winding = readingTask
            Task { [weak self] in
                await winding?.value
                guard let self, self.plan == nil, self.readingGeneration == generation else { return }
                pipeline.discardPlanningCopy()
            }
        }
    }

    private func startQueued() {
        guard !queued.isEmpty else { return }
        switch phase {
        case .reading, .applying: return
        default: break
        }
        let next = queued.removeFirst()
        read(next.work, entryPoint: next.entryPoint)
    }

    // MARK: Reviewing

    /// Applies the user's answer to one item (`ImportPipeline.resolve`). Answers are worked out
    /// one after another, each on the plan the previous one produced.
    func resolve(_ itemId: UUID, _ resolution: ImportResolution) {
        resolve(itemId, issueId: nil, resolution)
    }

    /// `resolve` answering one issue of the item. Taking back a tick that drafted a rule the
    /// other documents were changed by (`ImportPlan.ruleChangesUndoneWith`) first asks whether
    /// to undo those changes too (`pendingUndo`).
    func resolve(_ itemId: UUID, issueId: String?, _ resolution: ImportResolution) {
        if issueId == nil, let plan, phase == .review {
            let others = plan.ruleChangesUndoneWith(resolution, on: itemId)
            if !others.isEmpty {
                pendingUndo = PendingUndo(itemId: itemId, resolution: resolution, others: others.count)
                return
            }
        }
        perform(itemId: itemId, issueId: issueId) { pipeline, plan in
            try await pipeline.resolve(plan, itemId: itemId, issueId: issueId, resolution)
        }
    }

    /// The undo `pendingUndo` asked about: with the changes its rule made on the other
    /// documents ("Undo all"), or the tick alone ("Keep them").
    func finishPendingUndo(alsoOthers: Bool) {
        guard let pending = pendingUndo else { return }
        pendingUndo = nil
        perform(itemId: pending.itemId, issueId: nil) { pipeline, plan in
            let undone = try await pipeline.resolve(plan, itemId: pending.itemId, pending.resolution)
            return alsoOthers ? try await pipeline.undoRuleChanges(undone, from: pending.itemId) : undone
        }
    }

    /// The other documents the item's rule fits, opened for review (`ruleFits`).
    func reviewRuleFits(_ sourceId: UUID) {
        guard ruleFits[sourceId]?.isEmpty == false else { return }
        ruleFitsReview = RuleFitsReview(sourceId: sourceId)
    }

    /// The source's rules applied to the ticked documents (`ImportPipeline.applyRule`).
    func applyRule(from sourceId: UUID, to itemIds: Set<UUID>) {
        ruleFitsReview = nil
        guard !itemIds.isEmpty else { return }
        // Worked out again for the plan the rule leaves.
        ruleFits[sourceId] = nil
        perform(itemId: sourceId, issueId: nil) { pipeline, plan in
            try await pipeline.applyRule(plan, from: sourceId, to: itemIds)
        }
    }

    /// The change a rule from another document made on the item, taken back.
    func undoRuleChange(_ itemId: UUID) {
        perform(itemId: itemId, issueId: nil) { pipeline, plan in
            try await pipeline.undoRuleChange(plan, itemId: itemId)
        }
    }

    /// Every change the item's rules made on the other documents, taken back.
    func undoRuleChanges(from sourceId: UUID) {
        perform(itemId: sourceId, issueId: nil) { pipeline, plan in
            try await pipeline.undoRuleChanges(plan, from: sourceId)
        }
    }

    /// Works out a change of the open plan off the main actor, after the ones queued before it,
    /// each on the plan the previous one produced.
    private func perform(itemId: UUID, issueId: String?,
                         _ change: @escaping @Sendable (ImportPipeline, ImportPlan) async throws -> ImportPlan) {
        // The review is read only while files are read into it or it is being applied (the
        // screen disables it): an answer given then is refused out loud, never dropped.
        guard phase == .review, plan != nil else {
            problem = Problem(title: "That answer wasn't applied: wait until the review is ready, then answer again", lines: [])
            return
        }
        let previous = resolutionChain
        let pipeline = pipeline
        isResolving = true
        answerProblem = nil
        let task = Task { [weak self] in
            await previous?.value
            // A reading or Confirm import started meanwhile waits for this answer; a discarded
            // review has no plan.
            guard let self, let current = self.plan else { return }
            let result = await Result.catching {
                try await DetachedWork.run(priority: .userInitiated) {
                    try await change(pipeline, current)
                }
            }
            // Discarded (or replaced by a new reading) meanwhile: the answer no longer applies.
            guard self.plan == current else { return }
            switch result {
            case .success(let resolved):
                self.plan = resolved
                self.problem = nil
                // A statement's row answered leaves Needs you for a line under its statement: the statement shows.
                if let id = self.selectedItemId, let row = resolved.items.first(where: { $0.id == id }), row.section != .needsYou,
                   let parentId = row.parentId, let parent = resolved.items.first(where: { $0.id == parentId }),
                   StatementChecks.isRowChild(row, of: parent) {
                    self.selectedItemId = parentId
                }
            case .failure(ImportResolutionError.reasonRequired):
                // Beside the question: the item stays in Needs you as it was.
                self.answerProblem = AnswerProblem(itemId: itemId, issueId: issueId, message: "Write why it is imported anyway first")
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
        // Whoever is signed in now, not whoever opened the review (the lock may have changed hands).
        let confirmedBy = currentAppUserId()
        phase = .applying
        problem = nil
        Task { [weak self] in
            await previous?.value
            guard let self, let plan = self.plan else { return }
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ImportRunSummary, Error> in
                Result { try applier.apply(plan, entryPoint: entryPoint, reasons: plan.resolutionReasons, confirmedBy: confirmedBy, now: now) }
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
            libraryCounts.invalidate()
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
        answerProblem = nil
        phase = .idle
    }

    /// Reads the transactions the plan names that aren't read yet (off the main actor, on the
    /// planning copy); forgets them when the review closes.
    private func loadLinkedTransactions() {
        guard let plan else {
            linkedTransactions = [:]
            expandedPeeks = []
            linkSearchItemId = nil
            return
        }
        let missing = Self.transactionIds(in: plan).filter { linkedTransactions[$0] == nil }
        guard !missing.isEmpty else { return }
        let pipeline = pipeline
        Task { [weak self] in
            do {
                let found = try await DetachedWork.run(priority: .userInitiated) { try await pipeline.transactions(missing) }
                guard let self, self.plan != nil else { return }
                for candidate in found { self.linkedTransactions[candidate.id] = candidate }
            } catch {
                self?.logger.error("Reading the import's linked transactions failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Works out which other documents the plan's corrections' rules fit (off the main actor, on
    /// the planning copy); a result for a plan replaced meanwhile is dropped.
    private func loadRuleFits() {
        guard let plan else {
            ruleFitsTask?.cancel()
            ruleFits = [:]
            ruleFitsReview = nil
            pendingUndo = nil
            return
        }
        guard plan.items.contains(where: { !$0.ruleDrafts.isEmpty }) else {
            ruleFitsTask?.cancel()
            ruleFits = [:]
            return
        }
        let pipeline = pipeline
        // Only the latest plan's fits matter: the run for the one before stops.
        ruleFitsTask?.cancel()
        ruleFitsTask = Task { [weak self] in
            do {
                let fits = try await DetachedWork.run(priority: .userInitiated) { try await pipeline.ruleFits(plan) }
                guard let self, !Task.isCancelled, self.plan == plan else { return }
                self.ruleFits = fits
            } catch is CancellationError {
                return
            } catch {
                self?.logger.error("Checking where the review's rules fit failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Every transaction the plan's items link to or a "which one?" offers.
    static func transactionIds(in plan: ImportPlan) -> [Int64] {
        var ids: [Int64] = []
        var seen = Set<Int64>()
        for item in plan.items {
            let offered = item.issues.flatMap { issue -> [EvidenceEntity] in
                if case .chooseLink(let candidates) = issue.kind { return candidates.map(\.entity) }
                return []
            }
            for entity in item.links.map(\.entity) + offered where entity.type == .transaction && seen.insert(entity.id).inserted {
                ids.append(entity.id)
            }
        }
        return ids
    }

    /// The review's transaction search (off the main actor, on the planning copy); the results
    /// are remembered for the peek.
    func searchTransactions(_ query: ImportTransactionQuery) async throws -> [ImportTransactionCandidate] {
        let pipeline = pipeline
        let found = try await DetachedWork.run(priority: .userInitiated) { try await pipeline.searchTransactions(query) }
        for candidate in found { linkedTransactions[candidate.id] = candidate }
        return found
    }

    /// The transactions `ids` as the peek shows them (read now when not read yet).
    func transactions(_ ids: [Int64]) async throws -> [ImportTransactionCandidate] {
        let missing = ids.filter { linkedTransactions[$0] == nil }
        if !missing.isEmpty {
            let pipeline = pipeline
            for candidate in try await DetachedWork.run(priority: .userInitiated, { try await pipeline.transactions(missing) }) {
                linkedTransactions[candidate.id] = candidate
            }
        }
        return ids.compactMap { linkedTransactions[$0] }
    }

    /// The item's issuer key (`IssuerKey.derive`, as the pipeline derives it): nil when it has none.
    func issuerKey(of item: ImportItem) -> IssuerKey? {
        // A statement has no issuer (`ImportResolutions.takesIssuerName`).
        guard let knownParties, ![.bankStatementCSV, .bankStatementPDF, .bbvaStatement].contains(item.recognition.kind) else { return nil }
        if let known = issuerKeys[item.file.sha256] { return known }
        let key = IssuerKey.derive(text: item.file.text, fileName: item.file.fileName, ownNIFs: knownParties)
        issuerKeys[item.file.sha256] = key
        return key
    }

    /// "Show on Rules page": the learnt rule on the Rules page.
    func showImportRule(_ id: Int64) {
        onShowImportRule?(id)
    }

    /// Re-reads the names a target question offers and the known parties (off the main actor).
    private func loadTargetNames() {
        let dbQueue = dbQueue
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(ImportTargetNames, [Account], Set<String>), Error> in
                Result { try dbQueue.read { db in (try ImportTargetNames.read(db), try Account.fetchAll(db), try IssuerKey.knownParties(db: db)) } }
            }.value
            switch result {
            case .success(let (names, accounts, parties)):
                if self?.knownParties != parties {
                    self?.knownParties = parties
                    self?.issuerKeys = [:]
                }
                self?.targetNames = names
                self?.accounts = Dictionary(accounts.compactMap { account in account.id.map { ($0, account) } }, uniquingKeysWith: { first, _ in first })
            case .failure(let error):
                self?.logger.error("Reading the import's target names failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    #if SNAPSHOTS
    /// `urls` read by the real pipeline (snapshot routes only: the demo's import samples);
    /// `modelReader` stands in for the on-device model (snapshot mode has none).
    func snapshotPlan(_ urls: [URL], intent: ImportIntent = .none, libraryDocuments: [Int64] = [],
                      modelReader: (any DocumentModelReading)? = nil) async throws -> ImportPlan {
        let pipeline = modelReader.map { ImportPipeline(dbQueue: dbQueue, library: library, categorizationService: categorizationService,
                                                        modelReader: $0) } ?? pipeline
        defer { if modelReader != nil { pipeline.discardPlanningCopy() } }
        return try await DetachedWork.run(priority: .userInitiated) {
            try await pipeline.plan(adding: urls, libraryDocuments: libraryDocuments, to: ImportPlan(items: []), intent: intent)
        }
    }

    /// The folder at `url` registered as a source folder, scanned, and its new and changed files
    /// planned as Scan Now hands them over (snapshot routes only: it writes the folder to the demo copy).
    func snapshotPlan(folder url: URL) async throws -> ImportPlan {
        let scanner = SourceFolderScanner(library: library), pipeline = pipeline
        return try await DetachedWork.run(priority: .userInitiated) {
            let folder = try scanner.register(url)
            let result = try scanner.scan(folder, options: .init(analyzeNewFiles: false))
            return try await pipeline.plan(folder: result.folder, scanner: scanner, inputs: SourceFolderImport.inputs(from: result))
        }
    }

    /// `plan` with one answer (snapshot routes only).
    func snapshotResolve(_ plan: ImportPlan, itemId: UUID, _ resolution: ImportResolution) async throws -> ImportPlan {
        let pipeline = pipeline
        return try await DetachedWork.run(priority: .userInitiated) { try await pipeline.resolve(plan, itemId: itemId, resolution) }
    }

    /// The other documents each correction's rule fits in `plan` (snapshot routes only).
    func snapshotRuleFits(_ plan: ImportPlan) async throws -> [UUID: [ImportRuleFit]] {
        let pipeline = pipeline
        return try await DetachedWork.run(priority: .userInitiated) { try await pipeline.ruleFits(plan) }
    }

    /// `plan` with the source's rules applied to `itemIds` (snapshot routes only).
    func snapshotApplyRule(_ plan: ImportPlan, from sourceId: UUID, to itemIds: Set<UUID>) async throws -> ImportPlan {
        let pipeline = pipeline
        return try await DetachedWork.run(priority: .userInitiated) { try await pipeline.applyRule(plan, from: sourceId, to: itemIds) }
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
        let summary = try await Task.detached(priority: .userInitiated) { try applier.apply(plan, entryPoint: entryPoint, reasons: plan.resolutionReasons, now: now) }.value
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
        let result = await Task.detached(priority: .userInitiated) { () -> Result<([ImportRun], [ImportRunFile], [Int64: String]), Error> in
            Result {
                try dbQueue.read { db in
                    (try ImportRun.order(Column("confirmedAt").desc, Column("id").desc).fetchAll(db),
                     try ImportRunFile.order(Column("runId"), Column("id")).fetchAll(db),
                     Dictionary(uniqueKeysWithValues: try AppUser.fetchAll(db).compactMap { user in user.id.map { ($0, user.displayName) } }))
                }
            }
        }.value
        switch result {
        case .success(let (runs, files, names)):
            self.runs = runs
            userNames = names
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
            libraryCounts.invalidate()
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
