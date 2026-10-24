import Foundation
import GRDB

/// How far planning is: the files read (`completed` of `total`, `currentFile` the one just read),
/// then the passes over what they hold (`stage`), each with a count when it has one (`total` 0:
/// none — an indeterminate bar).
public struct ImportProgress: Equatable, Sendable {
    /// What planning is doing, in the order it does it.
    public enum Stage: Int, Comparable, Sendable {
        /// Reading the files (and asking the on-device model about what nothing recognised).
        case reading
        /// Staging the bank statements' rows.
        case statements
        /// The readers matching what the documents hold to the records.
        case matching
        /// The statements' checks and the duplicate pass.
        case duplicates
        /// The filed-year guard: `completed` of `total` items checked (0 of 0 while it takes the figures before).
        case filedYears

        public static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var completed: Int
    public var total: Int
    /// The file just read.
    public var currentFile: String?
    public var stage: Stage

    public init(completed: Int, total: Int, currentFile: String? = nil, stage: Stage = .reading) {
        self.completed = completed
        self.total = total
        self.currentFile = currentFile
        self.stage = stage
    }

    /// A pass after reading, with no count.
    public init(_ stage: Stage) {
        self.init(completed: 0, total: 0, stage: stage)
    }

    /// The line shown for a pass after reading (nil while reading the files).
    public var stageText: String? {
        switch stage {
        case .reading: return nil
        case .statements: return "Reading the statements’ transactions…"
        case .matching: return "Matching the documents to your records…"
        case .duplicates: return "Checking for duplicates…"
        case .filedYears: return total == 0 ? "Checking filed tax years…" : "Checking filed tax years (\(completed) of \(total))…"
        }
    }

    /// Whether this report is no earlier than `other` (a later stage, or as far or further in the
    /// same one): a report arriving after a later one is stale.
    public func isNotBefore(_ other: ImportProgress) -> Bool {
        stage != other.stage ? stage > other.stage : completed >= other.completed
    }
}

/// Set when planning is cancelled, for the passes that run inside one database access (which a
/// task's cancellation doesn't reach): they check it between items.
final class ImportCancellation: @unchecked Sendable {
    // @unchecked: `cancelled` is guarded by `lock`.
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }

    /// Throws `CancellationError` once cancelled.
    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}

/// Turns handed-in files into a reviewable `ImportPlan`, adds files to it and applies the
/// user's resolutions. Nothing is written, and the app's database queue is never held: every
/// pass runs on a private copy of the database (`ImportPlanningCopy`, taken at the start of a
/// plan and again when files are added, released by `discardPlanningCopy`), where every reader,
/// the duplicate pass and the filed-year guard run inside one write transaction that is always
/// rolled back (`ImportReader`). Edits made to the real database during the review are caught
/// when the plan is applied (`ImportApplier`: `.planOutdated` and the filed-return backstop).
///
/// Planning: collect (folders expanded) → copy the database → read the files off the main
/// actor, at most 4 at once, progress after each (load, detect, the reader's `prepare`) → what
/// nothing recognised asked of the on-device model (`ImportModelProposals`, at most 2 at once) → stage
/// the UK and BBVA statements (async, outside the transaction; several of one account in date order,
/// each later one treating the earlier ones' rows as already imported) → in the rolled-back
/// write: the readers, the learnt rules, the model's proposals, intent mismatches, `ImportDuplicates.annotate` over the whole plan,
/// `FiledYearGuard.annotate`. Progress goes on after the files are read: each pass's stage
/// (`ImportProgress.Stage`), the guard with its items' count. Cancelling the task stops it with
/// `CancellationError`, inside the rolled-back write too (between passes and the guard's items).
public struct ImportPipeline: @unchecked Sendable {
    // @unchecked: `EvidenceLibrary` and `CategorizationService` are classes with constant state
    // that aren't declared Sendable.
    private let dbQueue: DatabaseQueue
    /// Not used while planning (nothing is filed): kept for applying the plan (Task 13).
    private let library: EvidenceLibrary
    private let categorizationService: CategorizationService
    private let readers: [any ImportReader]?
    private let detector: ImportDetector?
    /// The on-device model asked about what nothing else recognises (`ImportModelProposals`); nil: never asked.
    private let modelReader: (any DocumentModelReading)?
    /// Each model call's deadline (tests shorten it).
    var modelTimeoutNanoseconds = ImportModelProposals.timeoutNanoseconds
    /// The plan's private copy of the database (shared by copies of this pipeline).
    private let session = ImportPlanningSession()
    /// Each file's issuer key and built-in recognition, for the rule fits (`ruleFits`, `applyRule`).
    let ruleFitCache = ImportRuleFitCache()

    /// Files read at once.
    static let concurrentLoads = 4

    public init(dbQueue: DatabaseQueue, library: EvidenceLibrary, categorizationService: CategorizationService,
                readers: [any ImportReader]? = nil, detector: ImportDetector? = nil, modelReader: (any DocumentModelReading)? = nil) {
        self.dbQueue = dbQueue
        self.modelReader = modelReader
        self.library = library
        self.categorizationService = categorizationService
        self.readers = readers
        self.detector = detector
    }

    // MARK: Planning

    public func plan(_ urls: [URL], intent: ImportIntent = .none, timings: ImportPlanTimings? = nil,
                     progress: @escaping @Sendable (ImportProgress) -> Void = { _ in }) async throws -> ImportPlan {
        try await plan(adding: urls, to: ImportPlan(items: []), intent: intent, timings: timings, progress: progress)
    }

    /// `plan` with the files read into `plan`: the duplicate pass runs over old and new items,
    /// so a file added again later is a duplicate. The planning copy is taken afresh.
    public func plan(adding urls: [URL], to plan: ImportPlan, intent: ImportIntent, timings: ImportPlanTimings? = nil,
                     progress: @escaping @Sendable (ImportProgress) -> Void = { _ in }) async throws -> ImportPlan {
        try await self.plan(adding: urls, to: plan, intent: intent, sources: [:], timings: timings, progress: progress)
    }

    /// `plan(adding:to:intent:)` with documents already in the library read too (a shortcut's
    /// `ImportShortcut.libraryDocumentIds`): each read from its stored file under its original
    /// name, so filing it on Confirm import returns that document (no second copy). Ids no
    /// longer in the library, and documents whose file is already in `plan`, are skipped.
    public func plan(adding urls: [URL], libraryDocuments documentIds: [Int64], to plan: ImportPlan, intent: ImportIntent,
                     timings: ImportPlanTimings? = nil, progress: @escaping @Sendable (ImportProgress) -> Void = { _ in }) async throws -> ImportPlan {
        // Ones already in the open review (brought before, or picked as a file) aren't read again.
        let inReview = Set(plan.items.filter { $0.parentId == nil }.map(\.file.sha256))
        let documents = try await dbQueue.read { db in try EvidenceDocument.filter(keys: documentIds).fetchAll(db) }
            .filter { !inReview.contains($0.sha256) }
        let byId = Dictionary(uniqueKeysWithValues: documents.compactMap { document in document.id.map { ($0, document) } })
        var names: [String: String] = [:]
        var all = urls
        for id in documentIds {
            guard let document = byId[id] else { continue }
            let url = library.fileURL(for: document)
            guard names[url.path] == nil else { continue }
            names[url.path] = document.originalFileName
            all.append(url)
        }
        return try await self.plan(adding: all, to: plan, intent: intent, sources: [:], names: names, timings: timings, progress: progress)
    }

    /// A source folder's new and changed files (`SourceFolderImport.inputs`) planned as
    /// `ImportShortcut.sourceFolder` (its entry point): read inside the folder's security scope,
    /// each file carrying the folder, its path there and its modification date (on the file and
    /// its placement), so Confirm import records the document on its scan record and
    /// acknowledges its change (`ImportApplier`). Inputs of other folders are left out; a file
    /// gone since the scan is an unreadable item ("Gone from the folder since the scan").
    /// Resolving the folder may refresh its stored bookmark and path (a write to the real
    /// database's `sourceFolder`, as any scan does) — the only write planning makes.
    /// `existing`: an open review the files join (as `plan(adding:)`: each item keeps its own intent).
    public func plan(folder: SourceFolder, scanner: SourceFolderScanner, inputs: [SourceFolderImport.Input],
                     to existing: ImportPlan = ImportPlan(items: []),
                     timings: ImportPlanTimings? = nil, progress: @escaping @Sendable (ImportProgress) -> Void = { _ in }) async throws -> ImportPlan {
        guard let folderId = folder.id else { throw SourceFolderError.folderNotFound }
        let intent = ImportShortcut.sourceFolder(folderId: folderId, name: folder.name).intent
        return try await scanner.withResolvedFolder(folder) { resolved in
            // Where the folder is now (its bookmark followed), not where the scan found it.
            var sources: [String: SourceFolderImport.Input] = [:]
            var urls: [URL] = []
            for var input in inputs where input.folderId == folderId {
                input.url = resolved.url.appendingPathComponent(input.relativePath)
                guard sources[input.url.path] == nil else { continue }
                sources[input.url.path] = input
                urls.append(input.url)
            }
            return try await self.plan(adding: urls, to: existing, intent: intent, sources: sources, timings: timings,
                                       progress: progress)
        }
    }

    /// `sources`: the source-folder files among `urls`, by path (their folder metadata).
    /// `names`: the library files among them, by path, with the name each was added under.
    private func plan(adding urls: [URL], to plan: ImportPlan, intent: ImportIntent, sources: [String: SourceFolderImport.Input],
                      names: [String: String] = [:],
                      timings: ImportPlanTimings?, progress: @escaping @Sendable (ImportProgress) -> Void) async throws -> ImportPlan {
        // A custom kind expected (Missing evidence ▸ Add) is named for the mismatch wording.
        var named = intent
        if case .customEvidence(let key)? = intent.expected {
            let pending = plan.pendingKinds
            named.expectedKindName = try await dbQueue.read { db in
                ImportKindNames(catalog: try DocumentKindCatalog.load(db: db), pending: pending)[key]?.name
            }
        }
        return try await planNamed(adding: urls, to: plan, intent: named, sources: sources, names: names, timings: timings, progress: progress)
    }

    private func planNamed(adding urls: [URL], to plan: ImportPlan, intent: ImportIntent, sources: [String: SourceFolderImport.Input],
                           names: [String: String],
                           timings: ImportPlanTimings?, progress: @escaping @Sendable (ImportProgress) -> Void) async throws -> ImportPlan {
        try await cancellable {
            try Task.checkCancellation()
            let collected = ImportFileCollector.collect(urls)
            // A source folder's file gone since the scan is still an item (unreadable), not dropped.
            let listed = Set(collected.files.map(\.path))
            let files = collected.files + urls.filter { sources[$0.path] != nil && !listed.contains($0.path) }
            let copy = try timings.measure(.copy) { try session.fresh(from: dbQueue) }
            let queue = copy.dbQueue
            let (providers, rules, ownNIFs, catalog) = try await queue.read { db in
                (try UtilityProvider.fetchAll(db), try ImportLearning.enabledRules(db: db), try IssuerKey.knownParties(db: db),
                 try DocumentKindCatalog.load(db: db))
            }
            let readers = self.readers ?? ImportReaders.defaultReaders(providers: providers)
            // Learnt kinds after the built-in recognisers (a given detector is used as it is).
            let detector = self.detector ?? ImportDetector(providers: providers, learnt: [ImportLearning.recogniser(rules: rules, ownNIFs: ownNIFs, catalog: catalog)])
            var loaded = try await load(files, sources: sources, names: names, detector: detector, readers: readers, timings: timings,
                                        progress: progress)
            try Task.checkCancellation()
            // The kind the shortcut declares for what nothing recognised: before the model (not asked about it).
            for i in loaded.indices where loaded[i].failure == nil {
                let file = loaded[i].file
                let read = !file.usedOCR && file.textStatus == .text
                    && file.text.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
                guard let declared = ImportDetector.declared(loaded[i].recognition, intent: intent, read: read,
                                                             kindNames: ImportKindNames(catalog: catalog, pending: plan.pendingKinds)) else { continue }
                loaded[i].recognition = declared
                loaded[i].file = readers.first { $0.handles(declared.kind) }?.prepare(loaded[i].file, recognition: declared) ?? loaded[i].file
            }
            // What nothing recognised, asked of the on-device model (outside the write, after the learnt rules).
            let outcomes = try await askModel(&loaded, cached: plan.state.modelGuesses, readers: readers, progress: progress)
            let entries = loaded
            try Task.checkCancellation()
            let now = Date()
            let context = try await queue.read { try ImportContext.load(db: $0, intent: intent, now: now).pending(plan.pendingKinds) }
            let stageStart = Date()
            if entries.contains(where: { Self.isStatement($0, readers: readers) }) { progress(ImportProgress(.statements)) }
            let contexts = Array(repeating: context, count: entries.count)
            let staged = try await stageStatements(entries, contexts: contexts, skipped: plan.state.skippedRows, readers: readers, queue: queue,
                                                   earlier: Self.batchRows(plan.items))
            timings?.add(.stage, Date().timeIntervalSince(stageStart))
            try Task.checkCancellation()
            let library = try timings.measure(.duplicates) { try copy.libraryIndex() }
            let existing = plan
            // The passes below run inside one database access: Cancel reaches them through `cancellation`.
            let cancellation = ImportCancellation()
            let planned = try await withTaskCancellationHandler { try await queue.write { db -> ImportPlan in
                var result = existing
                result.ignoredFiles += collected.ignored
                for (hash, outcome) in outcomes {
                    if case .guess(let guess) = outcome { result.state.modelGuesses[hash] = guess }
                }
                try db.inSavepoint {
                    progress(ImportProgress(.matching))
                    try cancellation.check()
                    let added = try timings.measure(.readers) {
                        try ImportLearning.apply(Self.propose(entries, staged: staged, contexts: contexts, readers: readers, db: db), db: db)
                            .map { Self.withModelOutcome($0, outcomes) }
                            .map { try Self.withTarget($0, intent: intent, db: db) }
                    }
                    for item in added {
                        result.state.intents[item.id] = intent
                        result.state.plannedIntents[item.id] = intent
                    }
                    result.items += added.map { Self.withIntentIssue($0, intent: intent) }
                    result = try Self.annotate(result, checking: existing.items.isEmpty ? nil : Set(added.map(\.id)), db: db,
                                               library: library, timings: timings, progress: progress, cancellation: cancellation)
                    return .rollback
                }
                return result
            } } onCancel: { cancellation.cancel() }
            // A statement added to an account that already has some in the review: the
            // account's statements are staged again together, in date order.
            let before = Set(existing.items.map(\.id))
            let accounts = Self.statementAccounts(existing.items)
                .intersection(Self.statementAccounts(planned.items.filter { !before.contains($0.id) }))
            return accounts.isEmpty ? planned : try await restage(planned, accounts: accounts)
        }
    }

    /// Releases the plan's copy of the database (the review was discarded or applied). The
    /// next resolution, if any, takes a new one.
    public func discardPlanningCopy() {
        session.discard()
    }

    /// Removes planning copies left behind by processes that ended without removing them (a
    /// crash, a force quit, builds before per-process folders): run at launch. Returns how many
    /// folders and files it removed.
    @discardableResult
    public static func removeStalePlanningCopies() -> Int {
        ImportPlanningCopy.removeStale()
    }

    /// The items filed as a saved custom kind merged or deleted since they were read (Confirm import
    /// refused them, `ImportApplier.checkKinds`), read again on a fresh copy of the database: a kind
    /// merged into another becomes that kind, to check ("<old> was merged into <new>: check it");
    /// a deleted one asks what the document is ("Its kind <old> no longer exists"). Nil when no
    /// item's kind changed.
    public func rereadingChangedKinds(_ plan: ImportPlan) async throws -> ImportPlan? {
        // No document filed as a saved custom kind: nothing to read again, and no fresh copy taken.
        guard plan.usesSavedCustomKinds else { return nil }
        let copy = try session.fresh(from: dbQueue)
        let changed = try await copy.dbQueue.read { db -> [(UUID, ImportRecognition)] in
            let catalog = try DocumentKindCatalog.load(db: db)
            var found: [(UUID, ImportRecognition)] = []
            for item in plan.items where item.parentId == nil {
                guard case .customEvidence(.saved(let id)) = item.recognition.kind, catalog.custom(id: id) == nil else { continue }
                let old = item.placement?.customKind?.name
                if let target = try CustomDocumentKinds.successor(of: id, db: db) {
                    let reason = "\(old ?? "Its kind") was merged into \(catalog.displayName(target)): check it"
                    found.append((item.id, ImportRecognition(kind: ImportResolutions.importKind(for: target, fileExtension: item.file.fileExtension),
                                                             confidence: .needsReview, reason: reason)))
                } else {
                    let reason = old.map { "Its kind \($0) no longer exists" } ?? "Its kind no longer exists"
                    found.append((item.id, ImportRecognition(kind: .unknown, confidence: .needsReview, reason: reason)))
                }
            }
            return found
        }
        guard !changed.isEmpty else { return nil }
        var result = plan
        for (itemId, recognition) in changed {
            guard var item = result.items.first(where: { $0.id == itemId }) else { continue }
            let drafts = item.ruleDrafts
            item.recognition = recognition
            result.state.chosenKinds.remove(itemId)
            result = try await reread(item, in: result, .acknowledge)
            // The corrections it still carries (not the kind that's gone).
            if let index = result.items.firstIndex(where: { $0.id == itemId }) {
                let reread = result.items[index]
                result.items[index].ruleDrafts = try await copy.dbQueue.read { db in try ImportLearning.carried(drafts, by: reread, db: db) }
            }
        }
        return result
    }

    /// The current planning copy's file (tests).
    var planningCopyPath: String? { session.currentPath }

    /// Every item checked again against the filed returns, on a fresh copy of the database:
    /// after the confirm-time backstop refused the batch (`ImportApplyError.filedYearChanged`),
    /// so the holds land on the items that cause it.
    public func recheckFiledYears(_ plan: ImportPlan) async throws -> ImportPlan {
        let copy = try session.fresh(from: dbQueue)
        return try await copy.dbQueue.write { db -> ImportPlan in
            var result = plan
            try db.inSavepoint {
                result.items = try FiledYearGuard.annotate(plan.items, db: db)
                return .rollback
            }
            return result
        }
    }

    // MARK: Searching transactions

    /// The review's transaction search (`ImportTransactionSearch`), on the plan's planning copy
    /// — the transactions a link change can name.
    public func searchTransactions(_ query: ImportTransactionQuery, limit: Int = ImportTransactionSearch.limit) async throws -> [ImportTransactionCandidate] {
        let copy = try session.current(from: dbQueue)
        return try await copy.dbQueue.read { db in try ImportTransactionSearch.search(db: db, query: query, limit: limit) }
    }

    /// The transactions `ids` as the peek shows them, on the planning copy.
    public func transactions(_ ids: [Int64]) async throws -> [ImportTransactionCandidate] {
        guard !ids.isEmpty else { return [] }
        let copy = try session.current(from: dbQueue)
        return try await copy.dbQueue.read { db in try ImportTransactionSearch.candidates(db: db, ids: ids) }
    }

    // MARK: Resolving

    /// The plan with the user's answer to one item (`ImportResolutions.apply`); `issueId`
    /// answers one issue of it. `.chooseKind` / `.chooseTarget` read the item again with its
    /// reader (`.chooseAccount`, `.saveProfile` too). Every change re-runs the duplicate pass over the plan and the filed-year guard
    /// on what changed, in a rolled-back write. Children (`parentId`) follow their parent in
    /// and out of the import.
    ///
    /// A correction that teaches (`ImportLearning.drafts`: a kind, an issuer's name, a link) leaves
    /// its rule drafts on the item, replacing the earlier ones of that kind (and the learnt rule
    /// of that kind it overrides no longer counts as used); they are learnt on Confirm import.
    /// A figure fixed by hand replaces that figure's position draft and learnt position; ticked
    /// ("Remember for this issuer") but not remembered (no issuer, a kind whose positions aren't
    /// learnt, not placeable on the page), the item says it is fixed for this document only.
    ///
    /// An answer the user gives on a document a rule from another document changed
    /// (`applyRule`) makes the change theirs: it is no longer undone on its own.
    public func resolve(_ plan: ImportPlan, itemId: UUID, issueId: String? = nil,
                        _ resolution: ImportResolution) async throws -> ImportPlan {
        var result = try await answering(plan, itemId: itemId, issueId: issueId, resolution)
        result.state.ruleChanges[itemId] = nil
        return result
    }

    /// The custom kinds as the planning copy holds them.
    private func kindCatalog() async throws -> DocumentKindCatalog {
        let copy = try session.current(from: dbQueue)
        return try await copy.dbQueue.read { db in try DocumentKindCatalog.load(db: db) }
    }

    /// "New kind…": `name` trimmed, refused when blank or when a built-in, a saved custom kind
    /// (`catalog`) or another of the plan's new kinds has it, ignoring case and accents.
    static func pendingKind(name: String, area: DocumentArea, catalog: DocumentKindCatalog, plan: ImportPlan) throws -> PendingDocumentKind {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(CustomDocumentKind.retiredMarker) else { throw ImportResolutionError.kindNameEmpty }
        let key = DocumentKindCatalog.key(trimmed)
        if let builtIn = DocumentKind.allCases.first(where: { DocumentKindCatalog.key($0.displayName) == key }) {
            throw ImportResolutionError.kindNameTaken(builtIn.displayName)
        }
        if let saved = catalog.custom(named: trimmed) { throw ImportResolutionError.kindNameTaken(saved.name) }
        if let other = plan.pendingKinds.first(where: { DocumentKindCatalog.key($0.name) == key }) {
            throw ImportResolutionError.kindNameTaken(other.name)
        }
        return PendingDocumentKind(name: trimmed, area: area)
    }

    /// `resolve`, keeping a rule change's record (`applyRule` answers through it).
    private func answering(_ plan: ImportPlan, itemId: UUID, issueId: String? = nil,
                           _ resolution: ImportResolution) async throws -> ImportPlan {
        switch resolution {
        case .createKind(let name, let area):
            // A new kind is part of the plan (pending) until Confirm import; then chosen like any other.
            let catalog = try await kindCatalog()
            let pending = try Self.pendingKind(name: name, area: area, catalog: catalog, plan: plan)
            var withKind = plan
            withKind.pendingKinds.append(pending)
            return try await answering(withKind, itemId: itemId, issueId: issueId, .chooseCustomKind(.pending(pending.id)))
        case .chooseCustomKind(let key):
            // Only a kind the review knows: a saved one in use, or one of its own new kinds.
            let known: Bool
            switch key {
            case .pending(let id): known = plan.pendingKinds.contains { $0.id == id }
            case .saved(let id): known = try await kindCatalog().custom(id: id) != nil
            }
            guard known else { throw ImportResolutionError.notOffered(resolution) }
        case .markChecked(let target):
            guard issueId == nil else { throw ImportResolutionError.notOffered(resolution) }
            return try await check(plan, itemId: itemId, target, mark: true)
        case .unmarkChecked(let target):
            guard issueId == nil else { throw ImportResolutionError.notOffered(resolution) }
            return try await check(plan, itemId: itemId, target, mark: false)
        case .markAllChecked, .unmarkAllChecked:
            guard issueId == nil else { throw ImportResolutionError.notOffered(resolution) }
            return try await checkAll(plan, itemId: itemId, mark: resolution == .markAllChecked)
        default:
            break
        }
        let result = try await answer(plan, itemId: itemId, issueId: issueId, resolution)
        let replaced = ImportLearning.replacedKinds(by: resolution)
        let figure = ImportLearning.correctedFigure(resolution)
        let teaches = !replaced.isEmpty || figure != nil || resolution == .acceptModelReading
        guard let before = plan.items.first(where: { $0.id == itemId }), teaches || !before.ruleDrafts.isEmpty,
              let index = result.items.firstIndex(where: { $0.id == itemId }) else { return result }
        var item = result.items[index]
        var named = ImportResolutions.chosenTransactions(resolution)
        if case .chooseLink(let entity) = resolution, entity.type == .transaction { named.append(entity.id) }
        named += item.links.filter { $0.entity.type == .transaction && $0.confidence == .certain }.map(\.entity.id)
        let ids = named
        let linkRuleIds = Set((before.appliedRules + item.appliedRules).filter { $0.kind == .link }.map(\.ruleId))
        let figureRuleIds = Set((before.appliedRules + item.appliedRules).filter { $0.kind == .figurePosition }.map(\.ruleId))
        let copy = try session.current(from: dbQueue)
        let (issuer, descriptions, linkRules, figureRules, learning) = try await copy.dbQueue.read {
            db -> (IssuerKey?, [Int64: String], [Int64: LinkAction], [Int64: ImportFigureField], DraftContext) in
            let learning = try Self.draftContext(of: before, db: db)
            let issuer = learning.issuer
            var descriptions: [Int64: String] = [:]
            for transaction in try Transaction.fetchAll(db, keys: Set(ids)) {
                if let id = transaction.id { descriptions[id] = transaction.rawDescription }
            }
            var linkRules: [Int64: LinkAction] = [:]
            for rule in try ImportRule.fetchAll(db, keys: linkRuleIds) {
                if let id = rule.id, let action = ImportLearning.decode(LinkAction.self, rule.actionJSON) { linkRules[id] = action }
            }
            var figureRules: [Int64: ImportFigureField] = [:]
            for rule in try ImportRule.fetchAll(db, keys: figureRuleIds) {
                if let id = rule.id, let action = ImportLearning.decode(FigurePositionAction.self, rule.actionJSON) { figureRules[id] = action.field }
            }
            return (issuer, descriptions, linkRules, figureRules, learning)
        }
        func position(_ draft: ImportRuleDraft) -> ImportFigureField? {
            draft.kind == .figurePosition ? ImportLearning.decode(FigurePositionAction.self, draft.actionJSON)?.field : nil
        }
        // The earlier drafts the item still carries (a reread may have dropped their fact or link), then this answer's.
        // A link answer replaces the link drafts of its family only (a payment never the record link).
        let families = ImportLearning.replacedLinkFamilies(by: resolution, before: before, after: item)
        let kept = ImportLearning.namingReplaced(before.ruleDrafts.filter { draft in
            let replacedHere = draft.kind == .link ? ImportLearning.linkFamily(draft).map(families.contains) ?? true : replaced.contains(draft.kind)
            return !replacedHere && (figure == nil || position(draft) != figure)
                && ImportLearning.isCarried(draft, by: item, descriptions: descriptions)
        }, rules: learning.rules)
        if replaced.contains(.documentKind) || resolution == .acceptModelReading { item.notes.removeAll { $0 == ImportLearning.recognisesItselfNote } }
        // Accepting the model's reading drafts what an earlier correction may have drafted already: once.
        let drafted = ImportLearning.drafts(for: item, resolution: resolution, issuer: issuer, transactionDescriptions: descriptions)
        let added = ImportLearning.finishing(drafted, on: &item, recognisesItself: learning.recognisesItself, rules: learning.rules)
        item.ruleDrafts = kept + added.filter { !kept.contains($0) }
        if let figure {
            // Fixed by hand again: a ticked figure says why it isn't remembered, if it isn't.
            item.notes.removeAll(where: LearntFigures.fixedNotes.contains)
            if case .confirmFigureRemembering = resolution,
               let note = LearntFigures.notRememberedNote(item, field: figure, issuer: issuer, drafts: item.ruleDrafts) {
                item.notes.append(note)
            }
        }
        // A learnt rule of the kind the user answered is overridden: not used, and not applied again on a
        // reread — a learnt link only when its own link is gone (another link's change leaves it be).
        let finalItem = item
        func overrides(_ use: ImportRuleUse) -> Bool {
            if use.kind == .figurePosition { return figure != nil && figureRules[use.ruleId] == figure }
            guard replaced.contains(use.kind) else { return false }
            guard use.kind == .link, let action = linkRules[use.ruleId] else { return true }
            return !ImportLearning.carriesLink(action, item: finalItem, descriptions: descriptions)
        }
        let overridden = (before.appliedRules + item.appliedRules).filter(overrides).map(\.ruleId)
        item.appliedRules.removeAll(where: overrides)
        var updated = result
        updated.items[index] = item
        if !overridden.isEmpty { updated.state.declinedRules[itemId, default: []].formUnion(overridden) }
        return updated
    }

    /// A "Check it" ticked off (`mark`) or taken back (`ImportChecks`): the tick, and the rules it
    /// teaches (a model kind or issuer name), with what was there before kept in the plan's state;
    /// un-ticked, that comes back (the whole item when nothing else changed since). Either way the
    /// duplicate pass and the filed-year guard run again, as for every change.
    private func check(_ plan: ImportPlan, itemId: UUID, _ target: ImportCheckTarget, mark: Bool) async throws -> ImportPlan {
        guard let index = plan.items.firstIndex(where: { $0.id == itemId }) else { throw ImportResolutionError.itemNotFound(itemId) }
        let item = plan.items[index]
        var result = plan
        var pending: ImportCheckRecord?
        if mark {
            let ticked = try Self.tick(target, on: item, learning: try await draftContext(of: item))
            pending = ticked.record
            result.items[index] = ticked.item
        } else {
            guard let record = plan.state.checks[itemId]?[target], ImportChecks.isStillChecked(record, target, on: item) else {
                throw ImportResolutionError.notOffered(.unmarkChecked(target))
            }
            result.items[index] = ImportChecks.unmarked(record, target, on: item)
            result.state.checks[itemId]?[target] = nil
        }
        var annotated = try await annotating(result, itemId: itemId)
        if var record = pending, let after = annotated.items.first(where: { $0.id == itemId }) {
            // Taken back whole only while the item is as the tick (and its checks) left it.
            record.after = after
            annotated.state.checks[itemId, default: [:]][target] = record
        }
        return annotated
    }

    /// "Mark all as checked" (`mark`): every tickable check of the item ticked in turn, as single
    /// ticks are (drafts, effects), each with its own record; or those ticks taken back together —
    /// the whole item as it was when nothing changed since, else each tick still there, last first.
    private func checkAll(_ plan: ImportPlan, itemId: UUID, mark: Bool) async throws -> ImportPlan {
        guard let index = plan.items.firstIndex(where: { $0.id == itemId }) else { throw ImportResolutionError.itemNotFound(itemId) }
        let item = plan.items[index]
        var result = plan
        if mark {
            let targets = ImportChecks.tickable(item)
            guard targets.count >= 2 else { throw ImportResolutionError.notOffered(.markAllChecked) }
            let learning = try await draftContext(of: item)
            var current = item
            var records: [ImportCheckTarget: ImportCheckRecord] = [:]
            for target in targets {
                let ticked = try Self.tick(target, on: current, learning: learning)
                records[target] = ticked.record
                current = ticked.item
            }
            result.items[index] = current
            var annotated = try await annotating(result, itemId: itemId)
            if let after = annotated.items.first(where: { $0.id == itemId }) {
                annotated.state.checks[itemId, default: [:]].merge(records) { _, new in new }
                // Marked all again while an earlier mark-all still has ticks in place: one record,
                // so Undo all takes every tick back (the item as it was before the first).
                if let earlier = plan.state.checkAlls[itemId], plan.isMarkedAllChecked(itemId) {
                    annotated.state.checkAlls[itemId] = ImportCheckAllRecord(before: earlier.before, after: after,
                                                                             targets: earlier.targets + targets.filter { !earlier.targets.contains($0) })
                } else {
                    annotated.state.checkAlls[itemId] = ImportCheckAllRecord(before: item, after: after, targets: targets)
                }
            }
            return annotated
        }
        guard let all = plan.state.checkAlls[itemId], plan.isMarkedAllChecked(itemId) else {
            throw ImportResolutionError.notOffered(.unmarkAllChecked)
        }
        var restored = item
        if item == all.after {
            restored = all.before
        } else {
            for target in all.targets.reversed() {
                guard let record = plan.state.checks[itemId]?[target], ImportChecks.isStillChecked(record, target, on: restored) else { continue }
                restored = ImportChecks.unmarked(record, target, on: restored)
            }
        }
        result.items[index] = restored
        for target in all.targets { result.state.checks[itemId]?[target] = nil }
        result.state.checkAlls[itemId] = nil
        return try await annotating(result, itemId: itemId)
    }

    // MARK: Rules applied to the other documents

    /// Every document with drafts of its own (a correction made on it) and the other documents
    /// of the review its rules fit (`ImportRuleFits`), read on the planning copy.
    public func ruleFits(_ plan: ImportPlan) async throws -> [UUID: [ImportRuleFit]] {
        guard plan.items.contains(where: { !ImportRuleFits.drafts(of: $0, in: plan).isEmpty }) else { return [:] }
        let context = try await ruleFitContext(plan)
        return ImportRuleFits.allFits(in: plan, context: context)
    }

    /// The source's rules applied to the documents `itemIds` it fits now: on each, the changes
    /// worked out again on the current plan (a kind first: the document is read again, then
    /// what fits the new reading) and answered as the user would answer them (`resolve`'s path:
    /// drafts, the duplicate pass and the filed-year guard as for any answer). A change no longer
    /// offered is skipped. Each changed document keeps a record to undo it (`undoRuleChange`).
    /// Nothing is learnt: the drafts are learnt on Confirm import, as every correction's.
    public func applyRule(_ plan: ImportPlan, from sourceId: UUID, to itemIds: Set<UUID>) async throws -> ImportPlan {
        guard let source = plan.items.first(where: { $0.id == sourceId }) else { throw ImportResolutionError.itemNotFound(sourceId) }
        let sourceDrafts = ImportRuleFits.drafts(of: source, in: plan)
        let rules = ImportRuleFits.rules(sourceDrafts)
        var result = plan
        // Read once: inside the loop only the target's own issuer key and offered transactions change.
        var context = try await ruleFitContext(plan)
        for target in plan.items where itemIds.contains(target.id) && target.id != sourceId {
            let ids = Set([target.id] + result.items.filter { $0.parentId == target.id }.map(\.id))
            let before = result.items.filter { ids.contains($0.id) }
            let state = ImportItemStateSnapshot(result.state, ids: ids)
            var applied: [ImportRuleChange] = []
            var tried: Set<ImportRuleChange.Aspect> = []
            while true {
                guard let item = result.items.first(where: { $0.id == target.id }) else { break }
                context = try await ruleFitContext(result, refreshing: item, in: context)
                guard let change = ImportRuleFits.fit(of: item, rules: rules, plan: result, context: context)?
                        .changes.first(where: { !tried.contains($0.aspect) }) else { break }
                tried.insert(change.aspect)
                do {
                    result = try await answering(result, itemId: target.id, change.resolution)
                    applied.append(change)
                } catch ImportResolutionError.notOffered {
                    continue
                }
            }
            guard !applied.isEmpty, let after = result.items.first(where: { $0.id == target.id }) else { continue }
            let earlier = before.first { $0.id == target.id }?.ruleDrafts ?? []
            result.state.ruleChanges[target.id] = ImportRuleChangeRecord(
                sourceId: sourceId, sourceName: source.file.fileName, sourceDrafts: sourceDrafts, before: before, state: state, after: after,
                changes: applied, addedDrafts: after.ruleDrafts.filter { !earlier.contains($0) })
        }
        return result
    }

    /// A rule's change on the document taken back while it still holds: the document (and its
    /// children) and what the plan remembered about them as they were before, then the duplicate
    /// pass and the filed-year guard again.
    public func undoRuleChange(_ plan: ImportPlan, itemId: UUID) async throws -> ImportPlan {
        try await undoRuleChanges(plan, itemIds: [itemId])
    }

    /// Every change the source's rules made on other documents that can still be undone, taken back.
    public func undoRuleChanges(_ plan: ImportPlan, from sourceId: UUID) async throws -> ImportPlan {
        let ids = plan.ruleChangedItems(from: sourceId)
        guard !ids.isEmpty else { return plan }
        return try await undoRuleChanges(plan, itemIds: ids)
    }

    private func undoRuleChanges(_ plan: ImportPlan, itemIds: [UUID]) async throws -> ImportPlan {
        var result = plan
        var checking: Set<UUID> = []
        for itemId in itemIds {
            guard let record = result.state.ruleChanges[itemId], let item = result.items.first(where: { $0.id == itemId }),
                  ImportRuleFits.isStillApplied(record, on: item) else {
                throw ImportResolutionError.itemNotFound(itemId)
            }
            let current = Set([itemId] + result.items.filter { $0.parentId == itemId }.map(\.id))
            guard let at = result.items.firstIndex(where: { $0.id == itemId }) else { continue }
            var items = result.items
            items.removeAll { current.contains($0.id) && $0.id != itemId }
            let index = items.firstIndex { $0.id == itemId } ?? at
            items.replaceSubrange(index...index, with: record.before)
            result.items = items
            record.state.restore(into: &result.state, removing: current)
            result.state.ruleChanges[itemId] = nil
            checking.formUnion(record.before.map(\.id))
        }
        return try await annotating(result, checking: checking)
    }

    /// What `ImportRuleFits` needs from the planning copy: the documents' issuer keys, the ones a
    /// built-in recogniser reads (each file worked out once, `ruleFitCache`), and the merchant,
    /// amount and currency of the transactions the "which one?" questions offer.
    private func ruleFitContext(_ plan: ImportPlan) async throws -> ImportRuleFits.Context {
        try await ruleFitContext(plan.items.filter { $0.parentId == nil && !ImportResolutions.isStatement($0) }, into: ImportRuleFits.Context(),
                                 pending: plan.pendingKinds)
    }

    /// `context` with `item` (as an answer left it) worked out again.
    private func ruleFitContext(_ plan: ImportPlan, refreshing item: ImportItem, in context: ImportRuleFits.Context) async throws -> ImportRuleFits.Context {
        var context = context
        context.issuers[item.id] = nil
        context.recognisesItself.remove(item.id)
        return try await ruleFitContext(ImportResolutions.isStatement(item) ? [] : [item], into: context, pending: plan.pendingKinds)
    }

    private func ruleFitContext(_ items: [ImportItem], into start: ImportRuleFits.Context,
                                pending: [PendingDocumentKind]) async throws -> ImportRuleFits.Context {
        let copy = try session.current(from: dbQueue)
        let cache = ruleFitCache
        return try await copy.dbQueue.read { db in
            let own = try IssuerKey.knownParties(db: db)
            let providers = try UtilityProvider.fetchAll(db)
            var context = start
            context.kindNames = ImportKindNames(catalog: try DocumentKindCatalog.load(db: db), pending: pending)
            var offered: Set<Int64> = []
            for item in items {
                let entry = cache.entry(for: item.file, ownNIFs: own, providers: providers)
                if let issuer = entry.issuer { context.issuers[item.id] = issuer }
                if entry.recognisesItself { context.recognisesItself.insert(item.id) }
                for issue in item.issues {
                    guard case .chooseLink(let candidates) = issue.kind else { continue }
                    offered.formUnion(candidates.filter { $0.entity.type == .transaction && context.payments[$0.entity.id] == nil }.map(\.entity.id))
                }
            }
            var currencies: [Int64: Currency] = [:]
            for transaction in try Transaction.fetchAll(db, keys: offered) {
                guard let id = transaction.id else { continue }
                if currencies[transaction.accountId] == nil { currencies[transaction.accountId] = try Account.fetchOne(db, key: transaction.accountId)?.currency }
                context.payments[id] = .init(merchant: MerchantKey.make(transaction.rawDescription), amountMinorUnits: transaction.amountMinorUnits,
                                             currency: currencies[transaction.accountId])
            }
            return context
        }
    }

    /// `target` ticked off on `item`, with the rules it teaches and the record to take it back.
    private static func tick(_ target: ImportCheckTarget, on item: ImportItem, learning: DraftContext) throws -> (item: ImportItem, record: ImportCheckRecord) {
        var marked = try ImportChecks.marked(target, on: item)
        let drafts = ImportChecks.drafts(target, before: item, after: marked, issuer: learning.issuer)
        let added = ImportLearning.finishing(drafts, on: &marked, recognisesItself: learning.recognisesItself, rules: learning.rules)
            .filter { !marked.ruleDrafts.contains($0) }
        marked.ruleDrafts += added
        let record = ImportCheckRecord(before: item, after: marked,
                                       priorFact: { if case .figure(let field) = target { return item.facts.first { $0.field == field } }; return nil }(),
                                       priorRecognition: target == .recognition ? item.recognition : nil,
                                       removedIssues: item.issues.filter { !marked.issues.contains($0) }, addedDrafts: added)
        return (marked, record)
    }

    /// What finishing an item's drafts needs: its issuer key, every learnt rule (to name the one a
    /// draft replaces) and whether a built-in recogniser reads its file (no kind is learnt then).
    struct DraftContext: Sendable {
        var issuer: IssuerKey?
        var rules: [ImportRule]
        var recognisesItself: Bool
    }

    static func draftContext(of item: ImportItem, db: Database) throws -> DraftContext {
        DraftContext(issuer: IssuerKey.derive(text: item.file.text, fileName: item.file.fileName, ownNIFs: try IssuerKey.knownParties(db: db)),
                     rules: try ImportRuleStore.all(db: db),
                     recognisesItself: ImportDetector.recognisesItself(item.file, providers: try UtilityProvider.fetchAll(db)))
    }

    /// `draftContext(of:db:)` on the planning copy.
    private func draftContext(of item: ImportItem) async throws -> DraftContext {
        let copy = try session.current(from: dbQueue)
        return try await copy.dbQueue.read { db in try Self.draftContext(of: item, db: db) }
    }

    /// `plan` with the duplicate pass and the filed-year guard run again on the item, in a rolled-back write.
    private func annotating(_ plan: ImportPlan, itemId: UUID) async throws -> ImportPlan {
        try await annotating(plan, checking: [itemId])
    }

    private func annotating(_ plan: ImportPlan, checking: Set<UUID>) async throws -> ImportPlan {
        let copy = try session.current(from: dbQueue)
        let library = try copy.libraryIndex()
        return try await copy.dbQueue.write { db -> ImportPlan in
            var annotated = plan
            try db.inSavepoint {
                annotated = try Self.annotate(plan, checking: checking, db: db, library: library)
                return .rollback
            }
            return annotated
        }
    }

    private func answer(_ plan: ImportPlan, itemId: UUID, issueId: String?, _ resolution: ImportResolution) async throws -> ImportPlan {
        guard let index = plan.items.firstIndex(where: { $0.id == itemId }) else { throw ImportResolutionError.itemNotFound(itemId) }
        let item = plan.items[index]
        // A statement's row that looks already saved: kept or skipped (Leave out skips it, or keeps it again).
        if let (parent, fingerprint) = StatementChecks.row(of: item, in: plan.items), let accountId = StatementChecks.accountId(of: parent) {
            guard ([.leaveOut, .keepRow, .skipRow] as [ImportResolution]).contains(resolution), !ImportApplier.leftOutIds(plan).contains(parent.id) else {
                throw ImportResolutionError.notOffered(resolution)
            }
            let skipped = plan.state.skippedRows[accountId]?.contains(fingerprint) == true
            let answer = resolution == .leaveOut ? (skipped ? ImportResolution.keepRow : .skipRow) : resolution
            if answer == .skipRow, !skipped {
                // Asked, or kept before: skipped on every statement of the account from now on.
                var result = plan
                result.state.skippedRows[accountId, default: []].insert(fingerprint)
                result.state.settled[itemId] = nil
                return try await restage(result, accounts: [accountId])
            }
            if answer == .keepRow, skipped {
                var result = plan
                result.state.skippedRows[accountId]?.remove(fingerprint)
                result = try await restage(result, accounts: [accountId])
                // Back among the rows, asked again: this is the answer.
                guard result.items.contains(where: { $0.id == itemId && !$0.issues.isEmpty }) else { return result }
                return try await resolve(result, itemId: itemId, .keepRow)
            }
            guard answer == resolution else { throw ImportResolutionError.notOffered(resolution) }
        }
        // A child comes back only with its parent.
        if case .leaveOut = resolution, item.isLeftOut, let parentId = item.parentId,
           plan.items.contains(where: { $0.id == parentId && $0.isLeftOut }) {
            throw ImportResolutionError.notOffered(resolution)
        }
        var result = plan
        // What the answer names must exist in the planning copy: the transactions linked to,
        // a target the reader didn't offer.
        let named = ImportResolutions.chosenTransactions(resolution)
        var labels: [EvidenceEntity: String] = [:]
        if !named.isEmpty || Self.needsTargetCheck(resolution, item: item, issueId: issueId) {
            let copy = try session.current(from: dbQueue)
            labels = try await copy.dbQueue.read { db -> [EvidenceEntity: String] in
                if case .chooseTarget(let kind, let id) = resolution, try !Self.targetExists(db: db, kind, id) {
                    throw ImportResolutionError.notOffered(resolution)
                }
                var found: [EvidenceEntity: String] = [:]
                for id in named {
                    guard try Transaction.exists(db, key: id) else { throw ImportResolutionError.transactionNotFound(id) }
                    found[.transaction(id)] = try entityLabel(db: db, .transaction(id))
                }
                return found
            }
        }
        if var edited = try ImportResolutions.apply(resolution, to: item, issueId: issueId, transactions: labels) {
            // A link the answer added (a chosen candidate) replaces what the intent says, as read ones do.
            edited = Self.withReplacements(edited, intent: plan.state.intents[itemId] ?? .none)
            result.items[index] = edited
            let answered = item.issues.filter { issue in !edited.issues.contains(issue) && Self.isSettleable(issue) }
            if !answered.isEmpty { result.state.settled[itemId, default: []].formUnion(answered.map(Self.settleKey)) }
            var changed: Set<UUID> = [itemId]
            if case .leaveOut = resolution {
                for j in result.items.indices where result.items[j].parentId == itemId {
                    result.items[j].isLeftOut = edited.isLeftOut
                    changed.insert(result.items[j].id)
                }
            }
            // In or out of the import: the account's statements are staged again (the rows an
            // earlier one held now come with a later one, or go back to it).
            if case .leaveOut = resolution, item.parentId == nil, let accountId = StatementChecks.accountId(of: item) {
                return try await restage(result, accounts: [accountId], checking: changed)
            }
            let edits = result, checking = changed
            let copy = try session.current(from: dbQueue)
            let library = try copy.libraryIndex()
            return try await copy.dbQueue.write { db -> ImportPlan in
                var annotated = edits
                try db.inSavepoint {
                    annotated = try Self.annotate(edits, checking: checking, db: db, library: library)
                    return .rollback
                }
                return annotated
            }
        }
        return try await reread(item, in: plan, resolution)
    }

    /// Whether the answer is a target no question of the item offers (a correction): it must exist.
    private static func needsTargetCheck(_ resolution: ImportResolution, item: ImportItem, issueId: String?) -> Bool {
        guard case .chooseTarget = resolution else { return false }
        return !item.issues.contains { (issueId == nil || $0.id == issueId) && ImportResolutions.accepts($0, resolution) }
    }

    static func targetExists(db: Database, _ kind: ImportTargetKind, _ id: Int64) throws -> Bool {
        switch kind {
        case .property: return try Property.exists(db, key: id)
        case .person: return try Person.exists(db, key: id)
        case .account: return try Account.exists(db, key: id)
        case .tenancy: return try Tenancy.exists(db, key: id)
        case .provider: return try UtilityProvider.exists(db, key: id)
        case .invoice: return try UtilityInvoice.exists(db, key: id)
        }
    }

    /// The item read again after the user chose its kind or a target, keeping its id; its old
    /// children are replaced by the reader's.
    private func reread(_ item: ImportItem, in plan: ImportPlan, _ resolution: ImportResolution) async throws -> ImportPlan {
        var intent = plan.state.intents[item.id] ?? .none
        var recognition = item.recognition
        var result = plan
        var chosenTarget: (ImportTargetKind, Int64)?
        switch resolution {
        case .chooseKind(let kind):
            // Targets chosen in the review were for the old kind (a tenancy, a provider…): a
            // new kind is read with the planned intent only.
            intent = plan.state.plannedIntents[item.id] ?? .none
            recognition = ImportRecognition(kind: ImportResolutions.importKind(for: kind, fileExtension: item.file.fileExtension),
                                            confidence: .certain, reason: ImportResolutions.chosenReason)
            result.state.chosenKinds.insert(item.id)
        case .chooseCustomKind(let key):
            intent = plan.state.plannedIntents[item.id] ?? .none
            recognition = ImportRecognition(kind: .customEvidence(key), confidence: .certain, reason: ImportResolutions.chosenReason)
            result.state.chosenKinds.insert(item.id)
        case .chooseTarget(let kind, let id):
            chosenTarget = (kind, id)
            switch kind {
            case .property: intent.propertyId = id
            case .person: intent.personId = id
            case .account:
                intent.accountId = id
                // A statement's account chosen by the user: learnt for files like it on Confirm import.
                if [.bankStatementCSV, .bankStatementPDF].contains(recognition.kind) { intent.statementAccounts[.current] = id }
            case .tenancy:
                // A receipt the user added the file to stays its target (its reader never asks then).
                if intent.target?.entity.type != .rentReceipt { intent.target = ImportIntent.Target(entity: .tenancy(id)) }
            case .provider: intent.providerId = id
            case .invoice: intent.invoiceId = id
            }
        case .chooseAccount(let role, let id):
            intent.statementAccounts[role] = id
        case .saveProfile(var profile):
            // A new mapping: never another row's id.
            profile.id = nil
            intent.statementProfile = profile
        default:
            break
        }
        result.state.intents[item.id] = intent
        // What the duplicate pass raised is about the old reading; an acknowledged kind
        // mismatch still holds (the file and the intent are the same).
        let mismatchSettled = plan.state.settled[item.id]?.contains(Self.kindMismatchId) == true
        result.state.settled[item.id] = mismatchSettled ? [Self.kindMismatchId] : nil

        let copy = try session.current(from: dbQueue)
        let queue = copy.dbQueue
        let providers = try await queue.read { try UtilityProvider.fetchAll($0) }
        let readers = self.readers ?? ImportReaders.defaultReaders(providers: providers)
        var file = item.file
        if recognition.kind != item.recognition.kind { file.payrollExtraction = nil }
        let reader = readers.first { $0.handles(recognition.kind) }
        if let reader { file = reader.prepare(file, recognition: recognition) }
        let entries = [Entry(file: file, recognition: recognition, failure: ImportResolutions.isUnreadable(item) ? item : nil)]
        let now = Date()
        let declined = plan.state.declinedRules[item.id] ?? []
        let context = try await queue.read { [intent] in
            try ImportContext.load(db: $0, intent: intent, now: now).declining(declined).pending(plan.pendingKinds)
        }
        // The statements before it in the review are the earlier ones of the batch.
        let before = plan.items.firstIndex { $0.id == item.id }.map { Array(plan.items[..<$0]) } ?? []
        let staged = try await stageStatements(entries, contexts: [context], skipped: plan.state.skippedRows, readers: readers, queue: queue,
                                               earlier: Self.batchRows(before))
        let chosenKind = result.state.chosenKinds.contains(item.id) || mismatchSettled
        let start = result, target = chosenTarget, readIntent = intent
        let library = try copy.libraryIndex()
        let reread = try await queue.write { db -> ImportPlan in
            var plan = start
            try db.inSavepoint {
                var read = try ImportLearning.apply(Self.propose(entries, staged: staged, contexts: [context], readers: readers, db: db), db: db,
                                                    declined: plan.state.declinedRules[item.id] ?? [])
                    .map { try Self.withTarget($0, intent: readIntent, db: db) }
                guard let first = read.firstIndex(where: { $0.parentId == nil }) else { return .rollback }
                // What the model read, accepted or still to check, is kept (the model isn't asked again).
                read[first] = ImportModelProposals.carry(from: item, to: read[first])
                let newId = read[first].id
                for i in read.indices {
                    if i == first { read[i].id = item.id } else if read[i].parentId == newId { read[i].parentId = item.id }
                }
                var reread = read[first]
                if let (kind, id) = target {
                    // The user answered this question: the reader asking it again (e.g. the
                    // target differs from the file's own) is settled.
                    reread.issues.removeAll { issue in
                        if case .chooseTarget(let asked, let options) = issue.kind { return asked == kind && options.contains(id) }
                        return false
                    }
                }
                read[first] = chosenKind ? reread : Self.withIntentIssue(reread, intent: readIntent)
                let children = Set(plan.items.filter { $0.parentId == item.id }.map(\.id))
                guard let position = plan.items.firstIndex(where: { $0.id == item.id }) else { return .rollback }
                var items = plan.items
                items.removeAll { children.contains($0.id) }
                let at = items.firstIndex { $0.id == item.id } ?? position
                items.replaceSubrange(at...at, with: read)
                for child in read where child.parentId == item.id {
                    plan.state.intents[child.id] = readIntent
                    plan.state.plannedIntents[child.id] = plan.state.plannedIntents[item.id]
                }
                plan.items = items
                plan.state.batchDuplicates.subtract(children.union([item.id]))
                plan = try Self.annotate(plan, checking: Set(read.map(\.id)), db: db, library: library)
                return .rollback
            }
            return plan
        }
        // A statement read again: the other statements of its account — the one it was on and the
        // one it is on now — are staged again with it (rows it held, or now holds, move).
        let accounts = [StatementChecks.accountId(of: item), reread.items.first { $0.id == item.id }.flatMap(StatementChecks.accountId)]
            .compactMap { $0 }
        func others(_ items: [ImportItem], _ id: Int64) -> Int {
            items.filter { $0.parentId == nil && $0.id != item.id && StatementChecks.accountId(of: $0) == id }.count
        }
        let affected = Set(accounts.filter { others(plan.items, $0) > 0 || others(reread.items, $0) > 0 })
        return affected.isEmpty ? reread : try await restage(reread, accounts: affected)
    }

    /// The accounts of the plan's staged statements.
    static func statementAccounts(_ items: [ImportItem]) -> Set<Int64> {
        Set(items.filter { $0.parentId == nil }.compactMap(StatementChecks.accountId))
    }

    /// Every statement of `accounts` in the plan staged and read again together, in date order
    /// (`stageStatements`): each treats the rows of the earlier ones still in the import as
    /// already imported, without the rows the user skipped, with its own intent. Each keeps its
    /// id, place, Leave out and reason; its children are the new reading's. Then the batch
    /// checks run again (`annotate`), the filed-year guard on what changed and `checking`.
    private func restage(_ plan: ImportPlan, accounts: Set<Int64>, checking: Set<UUID> = []) async throws -> ImportPlan {
        let targets = plan.items.filter { $0.parentId == nil && StatementChecks.accountId(of: $0).map(accounts.contains) == true }
        let copy = try session.current(from: dbQueue)
        let queue = copy.dbQueue
        let providers = try await queue.read { try UtilityProvider.fetchAll($0) }
        let readers = self.readers ?? ImportReaders.defaultReaders(providers: providers)
        let leftOutIds = ImportApplier.leftOutIds(plan)
        let base = try await queue.read { db in try ImportContext.load(db: db, intent: .none, now: Date()) }
        var entries: [Entry] = [], contexts: [ImportContext] = [], leftOut: Set<Int> = []
        for (n, item) in targets.enumerated() {
            entries.append(Entry(file: item.file, recognition: item.recognition))
            var context = base
            context.intent = plan.state.intents[item.id] ?? .none
            contexts.append(context)
            if leftOutIds.contains(item.id) { leftOut.insert(n) }
        }
        let staged = try await stageStatements(entries, contexts: contexts, leftOut: leftOut, skipped: plan.state.skippedRows,
                                               readers: readers, queue: queue, earlier: [:])
        let library = try copy.libraryIndex()
        let start = plan, read = entries, readContexts = contexts
        return try await queue.write { db -> ImportPlan in
            var plan = start
            let entries = read, contexts = readContexts
            try db.inSavepoint {
                var changed = checking
                for (n, old) in targets.enumerated() {
                    guard let statement = staged[n] else { continue }
                    let intent = contexts[n].intent
                    var read = try ImportLearning.apply(Self.statementItems(entries[n], statement, context: contexts[n], db: db), db: db,
                                                        declined: plan.state.declinedRules[old.id] ?? [])
                        .map { try Self.withTarget($0, intent: intent, db: db) }
                    guard let first = read.firstIndex(where: { $0.parentId == nil }) else { continue }
                    let newId = read[first].id
                    for i in read.indices {
                        if i == first { read[i].id = old.id } else if read[i].parentId == newId { read[i].parentId = old.id }
                        read[i].isLeftOut = old.isLeftOut
                    }
                    read[first].resolutionNote = old.resolutionNote
                    // The drafts it still carries as read again.
                    read[first].ruleDrafts = try ImportLearning.carried(old.ruleDrafts, by: read[first], db: db)
                    if !plan.state.chosenKinds.contains(old.id) { read[first] = Self.withIntentIssue(read[first], intent: intent) }
                    let children = Set(plan.items.filter { $0.parentId == old.id }.map(\.id))
                    var items = plan.items
                    items.removeAll { children.contains($0.id) }
                    guard let at = items.firstIndex(where: { $0.id == old.id }) else { continue }
                    items.replaceSubrange(at...at, with: read)
                    for child in read where child.parentId == old.id {
                        plan.state.intents[child.id] = intent
                        plan.state.plannedIntents[child.id] = plan.state.plannedIntents[old.id]
                    }
                    plan.items = items
                    plan.state.batchDuplicates.subtract(children.union([old.id]))
                    changed.formUnion(read.map(\.id))
                }
                plan = try Self.annotate(plan, checking: changed, db: db, library: library)
                return .rollback
            }
            return plan
        }
    }

    // MARK: Reading files

    /// A file read and recognised (`failure`: it couldn't be read, and is its item).
    struct Entry: Sendable {
        var file: ImportFile
        var recognition: ImportRecognition
        var failure: ImportItem?
    }

    /// Each file loaded, detected and prepared by its reader, at most `concurrentLoads` at
    /// once, in the order given; progress after each.
    private func load(_ urls: [URL], sources: [String: SourceFolderImport.Input] = [:], names: [String: String] = [:], detector: ImportDetector,
                      readers: [any ImportReader], timings: ImportPlanTimings?,
                      progress: @Sendable (ImportProgress) -> Void) async throws -> [Entry] {
        progress(ImportProgress(completed: 0, total: urls.count))
        var entries = [Entry?](repeating: nil, count: urls.count)
        try await withThrowingTaskGroup(of: (Int, Entry).self) { group in
            var next = 0
            func start() {
                let index = next
                let url = urls[index]
                let source = sources[url.path], name = names[url.path]
                group.addTask {
                    try Task.checkCancellation()
                    return (index, Self.read(url, source: source, name: name, detector: detector, readers: readers, timings: timings))
                }
                next += 1
            }
            while next < min(Self.concurrentLoads, urls.count) { start() }
            var completed = 0
            while let (index, entry) = try await group.next() {
                entries[index] = entry
                completed += 1
                progress(ImportProgress(completed: completed, total: urls.count, currentFile: urls[index].lastPathComponent))
                try Task.checkCancellation()
                if next < urls.count { start() }
            }
        }
        return entries.compactMap { $0 }
    }

    /// Each entry nothing recognised (`ImportModelProposals.asks`) asked of the model — a file of
    /// the plan already asked, from its guess — at most `ImportModelProposals.concurrentCalls` at
    /// once, off the caller's actor, progress before each. A guessed kind becomes the entry's
    /// recognition (prepared again by its reader). Keyed by file hash; empty without a model.
    private func askModel(_ entries: inout [Entry], cached: [String: DocumentModelGuess], readers: [any ImportReader],
                          progress: @Sendable (ImportProgress) -> Void) async throws -> [String: ImportModelProposals.Outcome] {
        guard let modelReader else { return [:] }
        let asked = entries.indices.filter { entries[$0].failure == nil && ImportModelProposals.asks(entries[$0].file, entries[$0].recognition) }
        guard !asked.isEmpty else { return [:] }
        var outcomes: [String: ImportModelProposals.Outcome] = [:]
        var pending: [Int] = []
        for index in asked {
            let hash = entries[index].file.sha256
            if outcomes[hash] != nil { continue }
            if let guess = cached[hash] { outcomes[hash] = .guess(guess) } else { pending.append(index) }
        }
        if case .unavailable(let message) = modelReader.availability() {
            for index in pending { outcomes[entries[index].file.sha256] = .unavailable(message) }
        } else if !pending.isEmpty {
            let files = pending.map { entries[$0].file }
            let timeout = modelTimeoutNanoseconds
            let total = entries.count
            try await withThrowingTaskGroup(of: (String, ImportModelProposals.Outcome).self) { group in
                var next = 0
                func start() {
                    let file = files[next]
                    progress(ImportProgress(completed: total, total: total, currentFile: ImportModelProposals.progressText(file.fileName)))
                    group.addTask {
                        try Task.checkCancellation()
                        return (file.sha256, try await ImportModelProposals.ask(modelReader, file: file, timeoutNanoseconds: timeout))
                    }
                    next += 1
                }
                while next < min(ImportModelProposals.concurrentCalls, files.count) { start() }
                while let (hash, outcome) = try await group.next() {
                    outcomes[hash] = outcome
                    try Task.checkCancellation()
                    if next < files.count { start() }
                }
            }
            // Asked about every one: no file is being asked about any more.
            progress(ImportProgress(completed: total, total: total))
        }
        // A guessed kind: read as that kind (its reader prepares the file for it).
        for index in asked {
            guard case .guess(let guess)? = outcomes[entries[index].file.sha256],
                  let recognition = ImportModelProposals.recognition(for: guess, file: entries[index].file) else { continue }
            var file = entries[index].file
            if recognition.kind != entries[index].recognition.kind { file.payrollExtraction = nil }
            entries[index].file = readers.first { $0.handles(recognition.kind) }?.prepare(file, recognition: recognition) ?? file
            entries[index].recognition = recognition
        }
        return outcomes
    }

    /// A file the model was asked about, with what it said (`ImportModelProposals.apply`).
    private static func withModelOutcome(_ item: ImportItem, _ outcomes: [String: ImportModelProposals.Outcome]) -> ImportItem {
        guard item.parentId == nil, let outcome = outcomes[item.file.sha256] else { return item }
        return ImportModelProposals.apply(outcome, to: item)
    }

    /// `source`: the file is a source folder's (it carries the folder's metadata).
    /// `name`: the name a library file was added under (its stored file is named by its hash).
    private static func read(_ url: URL, source: SourceFolderImport.Input?, name: String? = nil, detector: ImportDetector,
                             readers: [any ImportReader], timings: ImportPlanTimings?) -> Entry {
        do {
            var file = try timings.measure(.load) { try ImportFile.load(url) }
            if let name, !name.isEmpty { file.fileName = name }
            if let source {
                file.sourceFolderId = source.folderId
                file.sourceRelativePath = source.relativePath
                file.sourceModifiedAt = source.modifiedAt
            }
            let recognition = timings.measure(.detect) { detector.detect(file) }
            let prepared = timings.measure(.prepare) {
                readers.first { $0.handles(recognition.kind) }?.prepare(file, recognition: recognition) ?? file
            }
            return Entry(file: prepared, recognition: recognition)
        } catch {
            // No hash to compare: a key no other file has.
            let file = ImportFile(url: url, fileName: url.lastPathComponent, sha256: ImportResolutions.unreadableHashPrefix + UUID().uuidString, byteCount: 0,
                                  fileExtension: url.pathExtension.lowercased(), text: nil, textStatus: .noText, usedOCR: false,
                                  sourceFolderId: source?.folderId, sourceRelativePath: source?.relativePath,
                                  sourceModifiedAt: source?.modifiedAt)
            let recognition = ImportRecognition(kind: .unknown, confidence: .needsReview, reason: "The file could not be read")
            let gone = source != nil && !FileManager.default.fileExists(atPath: url.path)
            let text = gone ? Self.goneFromFolder : "The file could not be read: \(error.localizedDescription)"
            let item = ImportItem(file: file, recognition: recognition, title: file.fileName, effect: .none,
                                  issues: [ImportIssue(id: ImportResolutions.unreadableIssueId, kind: .readerProblem(text), reason: text)],
                                  groupKey: "Other documents")
            return Entry(file: file, recognition: recognition, failure: item)
        }
    }

    /// The reason of a link a changed source-folder file takes from its previous version's document.
    public static let previousVersionReason = "Links of the previous version"

    /// A source folder's file deleted or moved between the scan and the review.
    static let goneFromFolder = "Gone from the folder since the scan"

    // MARK: Statements

    /// A statement resolved to an account and staged (or why staging failed).
    /// `@unchecked`: `StagedImport` is an immutable value not declared Sendable.
    struct StagedStatement: @unchecked Sendable {
        /// What it is read with: a UK statement's saved profile, or the BBVA statement parsed.
        enum Source: Sendable {
            case uk(ImportProfile)
            case bbva(BBVAStatementReader.Resolved)
        }

        var accountId: Int64
        var source: Source
        var staged: StagedImport?
        var failure: String?
        /// The account's rows the earlier statements of the batch add (already imported for
        /// this one; counted in its closing balance check).
        var batchRows: [StagedTransaction] = []
        /// Where its items go among the entries (statements of one account in date order).
        var position: Int?
        /// The rows the user skipped, taken out of `staged`.
        var skippedRows: [StagedTransaction] = []
        /// The rows the earlier statements of the account (in the import) skipped, among `batchRows`.
        var skippedEarlier: [StagedTransaction] = []
    }

    /// The rows each account's statements in `items` add (not left out), each fingerprint
    /// once, in order: the earlier statements of the batch for one staged after them.
    static func batchRows(_ items: [ImportItem]) -> [Int64: [StagedTransaction]] {
        let leftOut = ImportApplier.leftOutIds(ImportPlan(items: items))
        var rows: [Int64: [StagedTransaction]] = [:]
        var seen: [Int64: Set<String>] = [:]
        for item in items where !leftOut.contains(item.id) {
            let accountId: Int64, held: [StagedTransaction]
            switch item.effect {
            case .ukStatement(let effect): (accountId, held) = (effect.accountId, effect.staged)
            case .bbvaStatement(let effect): (accountId, held) = (effect.currentAccountId, effect.staged)
            default: continue
            }
            for row in held where seen[accountId, default: []].insert(row.fingerprint).inserted {
                rows[accountId, default: []].append(row)
            }
        }
        return rows
    }

    /// Each statement (UK or BBVA) its reader can resolve, staged with saved rules only, outside the
    /// write transaction; keyed by entry index. Unresolved statements are left to `propose`.
    /// `earlier`: per account, the rows of statements already in the plan. Several statements
    /// of one account are staged in date order (first row, then last), each treating the rows
    /// of the earlier ones as already imported, and placed in that order.
    /// `contexts`: each entry's (its intent); `leftOut`: entries whose rows no later one counts as
    /// imported; `skipped`: per account, the fingerprints of the rows the user skipped — taken out
    /// of every statement of the account, and held (a later statement counts them as handled).
    /// Whether the entry is read as a UK or BBVA statement (staged before the readers run).
    private static func isStatement(_ entry: Entry, readers: [any ImportReader]) -> Bool {
        guard entry.failure == nil else { return false }
        let reader = readers.first { $0.handles(entry.recognition.kind) }
        return reader is UKStatementReader || reader is BBVAStatementReader
    }

    private func stageStatements(_ entries: [Entry], contexts: [ImportContext], leftOut: Set<Int> = [], skipped: [Int64: Set<String>] = [:],
                                 readers: [any ImportReader], queue: DatabaseQueue,
                                 earlier: [Int64: [StagedTransaction]]) async throws -> [Int: StagedStatement] {
        let statements = entries.indices.filter { Self.isStatement(entries[$0], readers: readers) }
        guard !statements.isEmpty else { return [:] }
        let resolved = try await queue.read { db -> [Int: (accountId: Int64, source: StagedStatement.Source)] in
            var found: [Int: (accountId: Int64, source: StagedStatement.Source)] = [:]
            for index in statements {
                let file = entries[index].file, recognition = entries[index].recognition, context = contexts[index]
                if readers.first(where: { $0.handles(recognition.kind) }) is BBVAStatementReader {
                    if case .resolved(let statement) = try BBVAStatementReader.resolve(file: file, recognition: recognition, context: context, db: db) {
                        found[index] = (statement.currentAccountId, .bbva(statement))
                    }
                } else if case .resolved(let accountId, let profile) = try UKStatementReader.resolve(file: file, recognition: recognition,
                                                                                                   context: context, db: db) {
                    found[index] = (accountId, .uk(profile))
                }
            }
            return found
        }
        let coordinator = ImportCoordinator(dbQueue: queue, categorizationService: categorizationService)
        func stage(_ index: Int, _ statement: inout StagedStatement, after rows: [StagedTransaction]) async throws {
            try Task.checkCancellation()
            statement.batchRows = rows
            do {
                var result: StagedImport
                switch statement.source {
                case .uk(let profile):
                    result = try await UKStatementReader.stage(file: entries[index].file, recognition: entries[index].recognition,
                                                               accountId: statement.accountId, profile: profile,
                                                               coordinator: coordinator, alreadyStaged: rows)
                case .bbva(let resolved):
                    result = try await BBVAStatementReader.stage(resolved, coordinator: coordinator, alreadyStaged: rows)
                }
                statement.skippedRows = []
                if let skip = skipped[statement.accountId], !skip.isEmpty {
                    statement.skippedRows = result.staged.filter { skip.contains($0.fingerprint) }
                    result = StagedImport(staged: result.staged.filter { !skip.contains($0.fingerprint) }, duplicates: result.duplicates,
                                          unparsedLines: result.unparsedLines, statementBalances: result.statementBalances,
                                          skippedRowCount: result.skippedRowCount, batchDuplicates: result.batchDuplicates,
                                          duplicateFingerprints: result.duplicateFingerprints)
                }
                statement.staged = result
                statement.failure = nil
            } catch {
                if Task.isCancelled { throw CancellationError() }
                statement.staged = nil
                statement.failure = "The statement could not be read: \(error.localizedDescription)"
            }
        }
        var staged: [Int: StagedStatement] = [:]
        for index in statements {
            guard let (accountId, source) = resolved[index] else { continue }
            var statement = StagedStatement(accountId: accountId, source: source)
            try await stage(index, &statement, after: earlier[accountId] ?? [])
            staged[index] = statement
        }
        // Several statements of one account: again in date order, each after the earlier ones.
        let byAccount = Dictionary(grouping: staged.keys.sorted()) { staged[$0]!.accountId }
        for accountId in byAccount.keys.sorted() {
            guard let indices = byAccount[accountId], indices.count > 1 else { continue }
            func key(_ index: Int) -> (Date, Date, Int) {
                guard let statement = staged[index], let result = statement.staged else { return StatementChecks.orderKey([], index) }
                return StatementChecks.orderKey((result.staged + statement.skippedRows).map(\.parsed.date) + result.duplicates.map(\.date), index)
            }
            let ordered = indices.sorted { key($0) < key($1) }
            var held = earlier[accountId] ?? []
            var fingerprints = Set(held.map(\.fingerprint))
            var heldSkipped: [StagedTransaction] = []
            for (rank, index) in ordered.enumerated() {
                guard var statement = staged[index] else { continue }
                statement.position = indices[rank]
                // The first was already staged after the plan's own statements alone.
                if rank > 0 {
                    try await stage(index, &statement, after: held)
                    statement.skippedEarlier = heldSkipped
                }
                // A statement left out holds nothing: the later ones add its rows.
                // Its skipped rows are held too: handled, never added by a later one.
                if !leftOut.contains(index) {
                    for row in (statement.staged?.staged ?? []) + statement.skippedRows where fingerprints.insert(row.fingerprint).inserted {
                        held.append(row)
                    }
                    heldSkipped += statement.skippedRows
                }
                staged[index] = statement
            }
        }
        return staged
    }

    // MARK: In the rolled-back write

    /// Every entry's items, in file order: each kind by the first reader handling it (all its
    /// files at once), staged statements by `UKStatementReader.items` / `BBVAStatementReader.items`.
    private static func propose(_ entries: [Entry], staged: [Int: StagedStatement], contexts: [ImportContext],
                                readers: [any ImportReader], db: Database) throws -> [ImportItem] {
        var byIndex: [Int: [ImportItem]] = [:]
        var order: [URL: Int] = [:]
        var batches: [Int: [Int]] = [:]
        for (index, entry) in entries.enumerated() {
            if order[entry.file.url] == nil { order[entry.file.url] = index }
            if let failure = entry.failure {
                byIndex[index] = [failure]
            } else if let statement = staged[index] {
                byIndex[statement.position ?? index] = try statementItems(entry, statement, context: contexts[index], db: db)
            } else if let reader = readers.firstIndex(where: { $0.handles(entry.recognition.kind) }) {
                batches[reader, default: []].append(index)
            } else {
                let text = "No reader for a \(entry.recognition.kind.displayName)"
                byIndex[index] = [ImportItem(file: entry.file, recognition: entry.recognition, title: entry.file.fileName,
                                             issues: [ImportIssue(id: "readerProblem", kind: .readerProblem(text), reason: text)],
                                             groupKey: "Other documents")]
            }
        }
        var proposed: [ImportItem] = []
        for reader in batches.keys.sorted() {
            try Task.checkCancellation()
            let indices = batches[reader] ?? []
            let files = indices.map { (file: entries[$0].file, recognition: entries[$0].recognition) }
            proposed += try readers[reader].propose(files, context: contexts[indices[0]], db: db)
        }
        // Back in the order the files were handed in (a reader's children stay after their parent).
        let last = entries.count
        let ranked = proposed.enumerated().map { (rank: order[$0.element.file.url] ?? last, position: $0.offset, item: $0.element) }
        for entry in ranked.sorted(by: { ($0.rank, $0.position) < ($1.rank, $1.position) }) {
            byIndex[entry.rank, default: []].append(entry.item)
        }
        return byIndex.keys.sorted().flatMap { byIndex[$0] ?? [] }
    }

    /// A staged statement's items (`UKStatementReader.items` / `BBVAStatementReader.items`), its
    /// skipped rows on its effect; or why it couldn't be staged.
    private static func statementItems(_ entry: Entry, _ statement: StagedStatement, context: ImportContext, db: Database) throws -> [ImportItem] {
        var items: [ImportItem]
        switch (statement.staged, statement.source) {
        case (let result?, .uk(let profile)):
            items = try UKStatementReader.items(file: entry.file, recognition: entry.recognition, accountId: statement.accountId,
                                                profile: profile, staged: result, context: context, db: db,
                                                skipped: statement.skippedRows)
        case (let result?, .bbva(let resolved)):
            items = try BBVAStatementReader.items(file: entry.file, recognition: entry.recognition, resolved: resolved,
                                                  staged: result, context: context, db: db, batchRows: statement.batchRows,
                                                  skipped: statement.skippedRows + statement.skippedEarlier)
        case (nil, let source):
            let text = statement.failure ?? "The statement could not be read"
            let groupKey: String
            if case .bbva = source { groupKey = BBVAStatementReader.groupKey } else { groupKey = UKStatementReader.groupKey }
            return [ImportItem(file: entry.file, recognition: entry.recognition, title: entry.file.fileName, effect: .none,
                               issues: [ImportIssue(id: "readerProblem", kind: .readerProblem(text), reason: text)],
                               groupKey: groupKey)]
        }
        if !statement.skippedRows.isEmpty, let first = items.firstIndex(where: { $0.parentId == nil }) {
            // Its rows are there, only skipped.
            items[first].issues.removeAll { $0.id == "noTransactions" }
            switch items[first].effect {
            case .ukStatement(var effect):
                effect.skipped = statement.skippedRows
                items[first].effect = .ukStatement(effect)
            case .bbvaStatement(var effect):
                effect.skipped = statement.skippedRows
                items[first].effect = .bbvaStatement(effect)
            default:
                break
            }
        }
        return items
    }

    /// The item with the intent's target linked (certain, `ImportIntent.targetReason`, made by
    /// the importer); a link the reader made to it becomes certain and carries the reason too.
    /// Then `withReplacements`. No new link
    /// for a statement's rows, a file the shortcut's type contradicts (`kindMismatch`), nor a rent
    /// receipt PDF added to a receipt or tenancy: its reader links the receipt it matched, and
    /// only when it is the target (`RentReceiptPDFReader`; a tenancy is the one chosen for its
    /// contract number). A target that no longer exists is a problem the user settles.
    static func withTarget(_ item: ImportItem, intent: ImportIntent, db: Database) throws -> ImportItem {
        guard let target = intent.target else { return item }
        var item = item
        let readerLinks = item.recognition.kind == .rentReceiptPDF && [.rentReceipt, .tenancy].contains(target.entity.type)
        if item.parentId == nil, ImportDetector.intentIssue(item.recognition, intent: intent) == nil,
           let index = item.links.firstIndex(where: { $0.entity == target.entity }) {
            // The reader linked it too: certain, with the user's reason (the receipt its PDF matched).
            let label = try entityTitle(db: db, target.entity) ?? item.links[index].label
            let reason = intent.targetReason(label: label)
            if item.links[index].confidence != .certain {
                item.links[index].confidence = .certain
                if let role = target.role { item.links[index].role = role }
            }
            if !item.links[index].reasons.contains(reason) { item.links[index].reasons.append(reason) }
        } else if item.parentId == nil, !readerLinks, ImportDetector.intentIssue(item.recognition, intent: intent) == nil {
            if let label = try entityTitle(db: db, target.entity) {
                item.links.append(ProposedLink(entity: target.entity, role: target.role, label: label, confidence: .certain,
                                               reasons: [intent.targetReason(label: label)]))
            } else {
                let text = "The \(target.entity.type.displayName.lowercased()) you added it to no longer exists"
                if !item.issues.contains(where: { $0.reason == text }) {
                    item.issues.append(ImportIssue(id: "targetGone", kind: .readerProblem(text), reason: text, offers: [.fileWithoutLink]))
                }
            }
        }
        if item.parentId == nil, intent.expected == .rentReceiptPDF, target.entity.type == .rentReceipt,
           item.recognition.kind == .evidence(.rentReceipt) {
            item = try withReceiptAgreement(item, receiptId: target.entity.id, db: db)
        }
        return withReplacements(withIntentPeriod(item, intent: intent), intent: intent)
    }

    /// A document filed for a record that asks for a period (`ImportIntent.period`) with no
    /// period facts of its own: the record's period (certain, from the shortcut), its placement
    /// named again with it. Not for a file the shortcut's type contradicts.
    static func withIntentPeriod(_ item: ImportItem, intent: ImportIntent) -> ImportItem {
        guard let period = intent.period, item.parentId == nil, item.placement != nil,
              ImportDetector.intentIssue(item.recognition, intent: intent) == nil,
              !item.facts.contains(where: { $0.field == .periodStart || $0.field == .periodEnd }) else { return item }
        var item = item
        let last = UKTaxYear.utcCalendar.date(byAdding: .day, value: -1, to: period.end) ?? period.start
        let reason = "The period " + (intent.entryPoint.map { "\($0) asks for" } ?? "the record asks for")
        item.facts.append(ImportFact(field: .periodStart, value: .date(period.start), source: .intent, confidence: .certain, reason: reason))
        item.facts.append(ImportFact(field: .periodEnd, value: .date(max(last, period.start)), source: .intent, confidence: .certain, reason: reason))
        item.placement = ImportNaming.placement(kind: item.recognition.kind, facts: item.facts, file: item.file,
                                                persons: item.placement?.metadata.persons ?? [],
                                                customKind: item.placement?.customKind)
        return item
    }

    /// A rent receipt that isn't the portal's PDF, added to a receipt (Receipt ▸ Add/Replace
    /// PDF…): read by text recognition, its kind is to check; when its period (or, without one,
    /// its date) or its amount disagrees with the receipt, the link to the receipt is to check,
    /// saying what differs ("This receipt's amount differs from receipt nº 1").
    static func withReceiptAgreement(_ item: ImportItem, receiptId: Int64, db: Database) throws -> ImportItem {
        var item = item
        if item.file.usedOCR, item.recognition.confidence == .certain {
            item.recognition.confidence = .needsReview
            item.recognition.reason = "Read by text recognition: check it's a rent receipt"
        }
        guard let receipt = try RentReceipt.fetchOne(db, key: receiptId),
              let index = item.links.firstIndex(where: { $0.entity == .rentReceipt(receiptId) }) else { return item }
        let calendar = MonthRange.calendar
        func date(_ field: ImportFigureField) -> Date? {
            for fact in item.facts where fact.field == field { if case .date(let day) = fact.value { return day } }
            return nil
        }
        var differs: [String] = []
        let start = date(.periodStart), end = date(.periodEnd)
        if start != nil || end != nil {
            if let start, !calendar.isDate(start, inSameDayAs: receipt.periodStart) { differs.append("period") }
            else if let end, !calendar.isDate(end, inSameDayAs: receipt.periodEnd) { differs.append("period") }
        } else if let day = date(.docDate) {
            // Issued within a month of the rent period.
            let from = calendar.date(byAdding: .month, value: -1, to: receipt.periodStart) ?? receipt.periodStart
            let to = calendar.date(byAdding: .month, value: 1, to: receipt.periodEnd) ?? receipt.periodEnd
            if day < calendar.startOfDay(for: from) || day > to.addingTimeInterval(86_399) { differs.append("date") }
        }
        let amounts = item.facts.compactMap { fact -> Int? in
            guard fact.field == .amount, case .money(let minor, _) = fact.value else { return nil }
            return abs(minor)
        }
        if let amount = amounts.first, ![receipt.amountMinorUnits, receipt.amountReceivedMinorUnits].contains(amount) {
            differs.append("amount")
        }
        guard !differs.isEmpty else { return item }
        let what = differs.joined(separator: " and ")
        let reason = "This receipt's \(what) \(differs.count == 1 ? "differs" : "differ") from receipt nº \(receipt.receiptNumber)"
        item.links[index].confidence = .needsReview
        if !item.links[index].reasons.contains(reason) { item.links[index].reasons.insert(reason, at: 0) }
        return item
    }

    /// The item's links to the intent's target carry the documents the intent replaces there
    /// (`ProposedLink.replacing`), so the filed-year guard and the importer both unlink them.
    static func withReplacements(_ item: ImportItem, intent: ImportIntent) -> ImportItem {
        guard let target = intent.target, !target.replacing.isEmpty else { return item }
        var item = item
        for i in item.links.indices where item.links[i].entity == target.entity {
            item.links[i].replacing = target.replacing
        }
        return item
    }

    /// A changed source-folder file whose previous version was filed (`SourceFile.previousDocumentId`
    /// of its scan record, still holding the content read): the new document takes the previous
    /// one's links — certain, `previousVersionReason`, same role — and replaces the previous
    /// document there (`ProposedLink.replacing`: unlinked by `ImportEffects.applyRecords`, so the
    /// filed-year guard simulates it; the previous document stays in the library). A link the
    /// reader made to the same record keeps its confidence and gains the reason and the
    /// replacement. Noted "New version of <name>", once: links the user removed since stay
    /// removed. Not for a duplicate (the same document again), a left-out item or a statement's row.
    static func withPreviousVersion(_ item: ImportItem, db: Database) throws -> ImportItem {
        guard item.parentId == nil, item.duplicate == nil, !item.isLeftOut,
              let folderId = item.file.sourceFolderId, let path = item.file.sourceRelativePath,
              let record = try SourceFile.filter(Column("folderId") == folderId && Column("relativePath") == path).fetchOne(db),
              record.sha256 == item.file.sha256, record.hasPendingChange, let previousId = record.previousDocumentId,
              let previous = try EvidenceDocument.fetchOne(db, key: previousId) else { return item }
        let note = "New version of \(previous.displayName)"
        guard !item.notes.contains(note) else { return item }
        var item = item
        item.notes.append(note)
        for link in try DocumentLink.filter(Column("documentId") == previousId).order(Column("id")).fetchAll(db)
        where try EvidenceLinks.entityExists(db: db, link.entity) {
            if let index = item.links.firstIndex(where: { $0.entity == link.entity }) {
                if !item.links[index].reasons.contains(previousVersionReason) { item.links[index].reasons.append(previousVersionReason) }
                if !item.links[index].replacing.contains(previousId) { item.links[index].replacing.append(previousId) }
            } else {
                item.links.append(ProposedLink(entity: link.entity, role: link.role, label: try entityLabel(db: db, link.entity),
                                               confidence: .certain, reasons: [previousVersionReason], replacing: [previousId]))
            }
        }
        return item
    }

    /// The item with a kind mismatch issue when the user said what the files are and this is
    /// something else.
    private static func withIntentIssue(_ item: ImportItem, intent: ImportIntent) -> ImportItem {
        guard item.parentId == nil, let issue = ImportDetector.intentIssue(item.recognition, intent: intent, foundName: item.kindName),
              !item.issues.contains(where: { $0.id == issue.id }) else { return item }
        var item = item
        item.issues.append(issue)
        return item
    }

    // MARK: Batch checks

    /// Ids of the issues the duplicate pass raises.
    static func isDuplicatePassIssue(_ id: String) -> Bool {
        id == "possibleDuplicate" || id == ImportDuplicates.correctedVersionIssueId
            || id.hasPrefix(ImportDuplicates.sameKindOnTransactionPrefix) || id.hasPrefix(ImportDuplicates.checkLinkPrefix)
            || id.hasPrefix(ImportDuplicates.tenancyHasContractPrefix)
    }

    static let kindMismatchId = "kindMismatch"

    /// Issues raised again on every pass (duplicate pass, intent mismatch), whose answer is kept.
    static func isSettleable(_ id: String) -> Bool { isDuplicatePassIssue(id) || id == kindMismatchId }

    /// `isSettleable`, or a statement's question (a closing balance, a possible duplicate row,
    /// unread lines…): raised again whenever its statements are checked or staged again.
    static func isSettleable(_ issue: ImportIssue) -> Bool { isSettleable(issue.id) || isStatementIssue(issue) }

    private static func isStatementIssue(_ issue: ImportIssue) -> Bool {
        if case .statement = issue.kind { return true }
        return false
    }

    /// What the user settled: the issue id, and for a possible duplicate, a corrected version or
    /// a statement's question also what it says (another match or another figure asks again).
    static func settleKey(_ issue: ImportIssue) -> String {
        issue.id == "possibleDuplicate" || issue.id == ImportDuplicates.correctedVersionIssueId || isStatementIssue(issue)
            ? "\(issue.id)|\(issue.reason)" : issue.id
    }

    /// The duplicate pass re-run over the whole plan (its earlier marks removed, what the user
    /// settled kept settled), then the filed-year guard on `checking` and on every item the
    /// pass changed (nil: every item).
    /// `library`: the library's identity index read from the same database (else read now).
    /// `progress` and `cancellation`: as planning reports and stops the passes (none: not reported, run to the end).
    static func annotate(_ plan: ImportPlan, checking: Set<UUID>?, db: Database, library: DocumentIdentityIndex? = nil,
                         timings: ImportPlanTimings? = nil, progress: (ImportProgress) -> Void = { _ in },
                         cancellation: ImportCancellation? = nil) throws -> ImportPlan {
        var result = plan
        let previous = plan.items
        progress(ImportProgress(.duplicates))
        try cancellation?.check()
        // The statements' checks across the batch (balances, possible duplicate rows, mortgages),
        // before the guard simulates them.
        let stripped = try timings.measure(.statementChecks) {
            try StatementChecks.recheck(previous.map { strip($0, batchDuplicate: plan.state.batchDuplicates.contains($0.id)) }, db: db)
        }
        var items = try timings.measure(.duplicates) {
            try ImportDuplicates.annotate(stripped, db: db, library: library, pendingKinds: plan.pendingKinds)
        }
        result.state.batchDuplicates = Set(items.indices.filter { stripped[$0].duplicate == nil && items[$0].duplicate != nil }.map { items[$0].id })
        // An "import anyway" answers its mismatch only while it lasts: a statement whose balance
        // now matches (or is left out) asks again for a reason the next time it doesn't.
        for item in stripped where item.parentId == nil && StatementChecks.accountId(of: item) != nil
            && !item.issues.contains(where: StatementChecks.isBalanceIssue) {
            guard let keys = result.state.settled[item.id] else { continue }
            let kept = keys.filter { !$0.hasPrefix(StatementChecks.balanceIssuePrefix) }
            result.state.settled[item.id] = kept.isEmpty ? nil : kept
        }
        for i in items.indices {
            guard let settled = result.state.settled[items[i].id], !settled.isEmpty else { continue }
            let answered = items[i].issues.filter { settled.contains(settleKey($0)) }
            items[i].issues.removeAll { settled.contains(settleKey($0)) }
            restoreLinks(&items[i], for: answered)
        }
        // A statement waits while one of its rows does (those answered no longer do).
        items = StatementChecks.holdParents(items)
        // Only what changed is guarded again (each item's check is independent of the others);
        // the confirm-time backstop (Task 13) re-checks the whole batch against the filed returns.
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let check = items.indices.filter { i in
            if let checking, !checking.contains(items[i].id), let earlier = before[items[i].id] {
                return withoutGuard(items[i]) != withoutGuard(earlier)
            }
            return true
        }
        if !check.isEmpty {
            try cancellation?.check()
            let guarded = try timings.measure(.guardCheck) {
                try FiledYearGuard.annotate(check.map { items[$0] }, db: db, timings: timings,
                                            progress: { progress(ImportProgress(completed: $0, total: $1, stage: .filedYears)) },
                                            checkCancellation: { try cancellation?.check() }, onSnapshot: {})
            }
            for (offset, i) in check.enumerated() { items[i] = guarded[offset] }
        }
        result.items = items
        return result
    }

    /// The item without the duplicate pass's marks: its issues, its duplicate mark (when the
    /// pass, not the reader, made it) and the links a "check the link" question made unsure.
    private static func strip(_ item: ImportItem, batchDuplicate: Bool) -> ImportItem {
        var item = item
        if batchDuplicate { item.duplicate = nil }
        let raised = item.issues.filter { isDuplicatePassIssue($0.id) }
        item.issues.removeAll { isDuplicatePassIssue($0.id) }
        restoreLinks(&item, for: raised)
        return item
    }

    /// A "check the link" question made the item's certain link to that transaction unsure:
    /// with the question gone (or settled) it is certain again.
    private static func restoreLinks(_ item: inout ImportItem, for issues: [ImportIssue]) {
        for issue in issues where issue.id.hasPrefix(ImportDuplicates.checkLinkPrefix) {
            guard case .chooseLink(let candidates) = issue.kind else { continue }
            let entities = Set(candidates.map(\.entity))
            for l in item.links.indices where entities.contains(item.links[l].entity) { item.links[l].confidence = .certain }
        }
    }

    private static func withoutGuard(_ item: ImportItem) -> ImportItem {
        var item = item
        item.issues.removeAll { issue in
            if case .filedYear = issue.kind { return true }
            return issue.id == FiledYearGuard.checkFailedIssueId
        }
        item.informationChanges = []
        return item
    }

    // MARK: Cancellation

    /// `body`, any error after the task was cancelled reported as `CancellationError`.
    private func cancellable<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            if Task.isCancelled, !(error is CancellationError) { throw CancellationError() }
            throw error
        }
    }
}
