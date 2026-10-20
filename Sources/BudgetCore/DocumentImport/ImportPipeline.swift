import Foundation
import GRDB

public struct ImportProgress: Equatable, Sendable {
    public var completed: Int
    public var total: Int
    /// The file just read.
    public var currentFile: String?

    public init(completed: Int, total: Int, currentFile: String? = nil) {
        self.completed = completed
        self.total = total
        self.currentFile = currentFile
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
/// actor, at most 4 at once, progress after each (load, detect, the reader's `prepare`) → stage
/// the UK statements (async, outside the transaction; several of one account in date order,
/// each later one treating the earlier ones' rows as already imported) → in the rolled-back
/// write: the readers, intent mismatches, `ImportDuplicates.annotate` over the whole plan,
/// `FiledYearGuard.annotate`. Cancelling the task stops it with `CancellationError`.
public struct ImportPipeline: @unchecked Sendable {
    // @unchecked: `EvidenceLibrary` and `CategorizationService` are classes with constant state
    // that aren't declared Sendable.
    private let dbQueue: DatabaseQueue
    /// Not used while planning (nothing is filed): kept for applying the plan (Task 13).
    private let library: EvidenceLibrary
    private let categorizationService: CategorizationService
    private let readers: [any ImportReader]?
    private let detector: ImportDetector?
    /// The plan's private copy of the database (shared by copies of this pipeline).
    private let session = ImportPlanningSession()

    /// Files read at once.
    static let concurrentLoads = 4

    public init(dbQueue: DatabaseQueue, library: EvidenceLibrary, categorizationService: CategorizationService,
                readers: [any ImportReader]? = nil, detector: ImportDetector? = nil) {
        self.dbQueue = dbQueue
        self.library = library
        self.categorizationService = categorizationService
        self.readers = readers
        self.detector = detector
    }

    // MARK: Planning

    public func plan(_ urls: [URL], intent: ImportIntent = .none, timings: ImportPlanTimings? = nil,
                     progress: @Sendable (ImportProgress) -> Void = { _ in }) async throws -> ImportPlan {
        try await plan(adding: urls, to: ImportPlan(items: []), intent: intent, timings: timings, progress: progress)
    }

    /// `plan` with the files read into `plan`: the duplicate pass runs over old and new items,
    /// so a file added again later is a duplicate. The planning copy is taken afresh.
    public func plan(adding urls: [URL], to plan: ImportPlan, intent: ImportIntent, timings: ImportPlanTimings? = nil,
                     progress: @Sendable (ImportProgress) -> Void = { _ in }) async throws -> ImportPlan {
        try await cancellable {
            try Task.checkCancellation()
            let collected = ImportFileCollector.collect(urls)
            let copy = try timings.measure(.copy) { try session.fresh(from: dbQueue) }
            let queue = copy.dbQueue
            let providers = try await queue.read { try UtilityProvider.fetchAll($0) }
            let readers = self.readers ?? ImportReaders.defaultReaders(providers: providers)
            let detector = self.detector ?? ImportDetector(providers: providers)
            let entries = try await load(collected.files, detector: detector, readers: readers, timings: timings, progress: progress)
            try Task.checkCancellation()
            let now = Date()
            let context = try await queue.read { try ImportContext.load(db: $0, intent: intent, now: now) }
            let stageStart = Date()
            let staged = try await stageStatements(entries, context: context, readers: readers, queue: queue,
                                                   earlier: Self.batchRows(plan.items))
            timings?.add(.stage, Date().timeIntervalSince(stageStart))
            try Task.checkCancellation()
            let library = try timings.measure(.duplicates) { try copy.libraryIndex() }
            let existing = plan
            return try await queue.write { db -> ImportPlan in
                var result = existing
                result.ignoredFiles += collected.ignored
                try db.inSavepoint {
                    let added = try timings.measure(.readers) {
                        try Self.propose(entries, staged: staged, context: context, readers: readers, db: db)
                            .map { Self.withReplacements($0, intent: intent) }
                    }
                    for item in added {
                        result.state.intents[item.id] = intent
                        result.state.plannedIntents[item.id] = intent
                    }
                    result.items += added.map { Self.withIntentIssue($0, intent: intent) }
                    result = try Self.annotate(result, checking: existing.items.isEmpty ? nil : Set(added.map(\.id)), db: db,
                                               library: library, timings: timings)
                    return .rollback
                }
                return result
            }
        }
    }

    /// Releases the plan's copy of the database (the review was discarded or applied). The
    /// next resolution, if any, takes a new one.
    public func discardPlanningCopy() {
        session.discard()
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

    // MARK: Resolving

    /// The plan with the user's answer to one item (`ImportResolutions.apply`); `issueId`
    /// answers one issue of it. `.chooseKind` / `.chooseTarget` read the item again with its
    /// reader. Every change re-runs the duplicate pass over the plan and the filed-year guard
    /// on what changed, in a rolled-back write. Children (`parentId`) follow their parent in
    /// and out of the import.
    public func resolve(_ plan: ImportPlan, itemId: UUID, issueId: String? = nil,
                        _ resolution: ImportResolution) async throws -> ImportPlan {
        guard let index = plan.items.firstIndex(where: { $0.id == itemId }) else { throw ImportResolutionError.itemNotFound(itemId) }
        let item = plan.items[index]
        // A child comes back only with its parent.
        if case .leaveOut = resolution, item.isLeftOut, let parentId = item.parentId,
           plan.items.contains(where: { $0.id == parentId && $0.isLeftOut }) {
            throw ImportResolutionError.notOffered(resolution)
        }
        var result = plan
        if var edited = try ImportResolutions.apply(resolution, to: item, issueId: issueId) {
            // A link the answer added (a chosen candidate) replaces what the intent says, as read ones do.
            edited = Self.withReplacements(edited, intent: plan.state.intents[itemId] ?? .none)
            result.items[index] = edited
            let answered = item.issues.filter { issue in !edited.issues.contains(issue) && Self.isSettleable(issue.id) }
            if !answered.isEmpty { result.state.settled[itemId, default: []].formUnion(answered.map(Self.settleKey)) }
            var changed: Set<UUID> = [itemId]
            if case .leaveOut = resolution {
                for j in result.items.indices where result.items[j].parentId == itemId {
                    result.items[j].isLeftOut = edited.isLeftOut
                    changed.insert(result.items[j].id)
                }
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
        case .chooseTarget(let kind, let id):
            chosenTarget = (kind, id)
            switch kind {
            case .property: intent.propertyId = id
            case .person: intent.personId = id
            case .account: intent.accountId = id
            case .tenancy: intent.target = ImportIntent.Target(entity: .tenancy(id))
            case .provider: intent.providerId = id
            }
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
        let context = try await queue.read { [intent] in try ImportContext.load(db: $0, intent: intent, now: now) }
        // The statements before it in the review are the earlier ones of the batch.
        let before = plan.items.firstIndex { $0.id == item.id }.map { Array(plan.items[..<$0]) } ?? []
        let staged = try await stageStatements(entries, context: context, readers: readers, queue: queue, earlier: Self.batchRows(before))
        let chosenKind = result.state.chosenKinds.contains(item.id) || mismatchSettled
        let start = result, target = chosenTarget, readIntent = intent
        let library = try copy.libraryIndex()
        return try await queue.write { db -> ImportPlan in
            var plan = start
            try db.inSavepoint {
                var read = try Self.propose(entries, staged: staged, context: context, readers: readers, db: db)
                    .map { Self.withReplacements($0, intent: readIntent) }
                guard let first = read.firstIndex(where: { $0.parentId == nil }) else { return .rollback }
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
    private func load(_ urls: [URL], detector: ImportDetector, readers: [any ImportReader], timings: ImportPlanTimings?,
                      progress: @Sendable (ImportProgress) -> Void) async throws -> [Entry] {
        progress(ImportProgress(completed: 0, total: urls.count))
        var entries = [Entry?](repeating: nil, count: urls.count)
        try await withThrowingTaskGroup(of: (Int, Entry).self) { group in
            var next = 0
            func start() {
                let index = next
                let url = urls[index]
                group.addTask {
                    try Task.checkCancellation()
                    return (index, Self.read(url, detector: detector, readers: readers, timings: timings))
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

    private static func read(_ url: URL, detector: ImportDetector, readers: [any ImportReader], timings: ImportPlanTimings?) -> Entry {
        do {
            let file = try timings.measure(.load) { try ImportFile.load(url) }
            let recognition = timings.measure(.detect) { detector.detect(file) }
            let prepared = timings.measure(.prepare) {
                readers.first { $0.handles(recognition.kind) }?.prepare(file, recognition: recognition) ?? file
            }
            return Entry(file: prepared, recognition: recognition)
        } catch {
            // No hash to compare: a key no other file has.
            let file = ImportFile(url: url, fileName: url.lastPathComponent, sha256: ImportResolutions.unreadableHashPrefix + UUID().uuidString, byteCount: 0,
                                  fileExtension: url.pathExtension.lowercased(), text: nil, textStatus: .noText, usedOCR: false)
            let recognition = ImportRecognition(kind: .unknown, confidence: .needsReview, reason: "The file could not be read")
            let text = "The file could not be read: \(error.localizedDescription)"
            let item = ImportItem(file: file, recognition: recognition, title: file.fileName, effect: .none,
                                  issues: [ImportIssue(id: ImportResolutions.unreadableIssueId, kind: .readerProblem(text), reason: text)],
                                  groupKey: "Other documents")
            return Entry(file: file, recognition: recognition, failure: item)
        }
    }

    // MARK: Statements

    /// A UK statement resolved to an account and staged (or why staging failed).
    /// `@unchecked`: `StagedImport` is an immutable value not declared Sendable.
    struct StagedStatement: @unchecked Sendable {
        var accountId: Int64
        var profile: ImportProfile
        var staged: StagedImport?
        var failure: String?
        /// The account's rows the earlier statements of the batch add (already imported for
        /// this one; counted in its closing balance check).
        var batchRows: [StagedTransaction] = []
        /// Where its items go among the entries (statements of one account in date order).
        var position: Int?
    }

    /// The rows each account's statements in `items` add (not left out), each fingerprint
    /// once, in order: the earlier statements of the batch for one staged after them.
    static func batchRows(_ items: [ImportItem]) -> [Int64: [StagedTransaction]] {
        let leftOut = ImportApplier.leftOutIds(ImportPlan(items: items))
        var rows: [Int64: [StagedTransaction]] = [:]
        var seen: [Int64: Set<String>] = [:]
        for item in items where !leftOut.contains(item.id) {
            guard case .ukStatement(let effect) = item.effect else { continue }
            for row in effect.staged + effect.batchOverlap where seen[effect.accountId, default: []].insert(row.fingerprint).inserted {
                rows[effect.accountId, default: []].append(row)
            }
        }
        return rows
    }

    /// Each UK statement the reader can resolve, staged with saved rules only, outside the
    /// write transaction; keyed by entry index. Unresolved statements are left to `propose`.
    /// `earlier`: per account, the rows of statements already in the plan. Several statements
    /// of one account are staged in date order (first row, then last), each treating the rows
    /// of the earlier ones as already imported, and placed in that order.
    private func stageStatements(_ entries: [Entry], context: ImportContext, readers: [any ImportReader], queue: DatabaseQueue,
                                 earlier: [Int64: [StagedTransaction]]) async throws -> [Int: StagedStatement] {
        let statements = entries.indices.filter { index in
            entries[index].failure == nil && readers.first { $0.handles(entries[index].recognition.kind) } is UKStatementReader
        }
        guard !statements.isEmpty else { return [:] }
        let resolved = try await queue.read { db -> [Int: (accountId: Int64, profile: ImportProfile)] in
            var found: [Int: (accountId: Int64, profile: ImportProfile)] = [:]
            for index in statements {
                if case .resolved(let accountId, let profile) = try UKStatementReader.resolve(file: entries[index].file, recognition: entries[index].recognition,
                                                                                            context: context, db: db) {
                    found[index] = (accountId, profile)
                }
            }
            return found
        }
        let coordinator = ImportCoordinator(dbQueue: queue, categorizationService: categorizationService)
        func stage(_ index: Int, _ statement: inout StagedStatement, after rows: [StagedTransaction]) async throws {
            try Task.checkCancellation()
            statement.batchRows = rows
            do {
                statement.staged = try await UKStatementReader.stage(file: entries[index].file, recognition: entries[index].recognition,
                                                                     accountId: statement.accountId, profile: statement.profile,
                                                                     coordinator: coordinator, alreadyStaged: rows)
                statement.failure = nil
            } catch {
                if Task.isCancelled { throw CancellationError() }
                statement.staged = nil
                statement.failure = "The statement could not be read: \(error.localizedDescription)"
            }
        }
        var staged: [Int: StagedStatement] = [:]
        for index in statements {
            guard let (accountId, profile) = resolved[index] else { continue }
            var statement = StagedStatement(accountId: accountId, profile: profile)
            try await stage(index, &statement, after: earlier[accountId] ?? [])
            staged[index] = statement
        }
        // Several statements of one account: again in date order, each after the earlier ones.
        let byAccount = Dictionary(grouping: staged.keys.sorted()) { staged[$0]!.accountId }
        for accountId in byAccount.keys.sorted() {
            guard let indices = byAccount[accountId], indices.count > 1 else { continue }
            func period(_ index: Int) -> (Date, Date) {
                guard let result = staged[index]?.staged else { return (.distantFuture, .distantFuture) }
                let dates = (result.staged.map(\.parsed) + result.duplicates).map(\.date)
                return (dates.min() ?? .distantFuture, dates.max() ?? .distantFuture)
            }
            let ordered = indices.sorted { (period($0).0, period($0).1, $0) < (period($1).0, period($1).1, $1) }
            var held = earlier[accountId] ?? []
            var fingerprints = Set(held.map(\.fingerprint))
            for (rank, index) in ordered.enumerated() {
                guard var statement = staged[index] else { continue }
                statement.position = indices[rank]
                // The first was already staged after the plan's own statements alone.
                if rank > 0 { try await stage(index, &statement, after: held) }
                for row in statement.staged?.staged ?? [] where fingerprints.insert(row.fingerprint).inserted { held.append(row) }
                staged[index] = statement
            }
        }
        return staged
    }

    // MARK: In the rolled-back write

    /// Every entry's items, in file order: each kind by the first reader handling it (all its
    /// files at once), staged statements by `UKStatementReader.items`.
    private static func propose(_ entries: [Entry], staged: [Int: StagedStatement], context: ImportContext,
                                readers: [any ImportReader], db: Database) throws -> [ImportItem] {
        var byIndex: [Int: [ImportItem]] = [:]
        var order: [URL: Int] = [:]
        var batches: [Int: [Int]] = [:]
        for (index, entry) in entries.enumerated() {
            if order[entry.file.url] == nil { order[entry.file.url] = index }
            if let failure = entry.failure {
                byIndex[index] = [failure]
            } else if let statement = staged[index] {
                let slot = statement.position ?? index
                if let result = statement.staged {
                    byIndex[slot] = try UKStatementReader.items(file: entry.file, recognition: entry.recognition, accountId: statement.accountId,
                                                                profile: statement.profile, staged: result, context: context, db: db,
                                                                batchRows: statement.batchRows)
                } else {
                    let text = statement.failure ?? "The statement could not be read"
                    byIndex[slot] = [ImportItem(file: entry.file, recognition: entry.recognition, title: entry.file.fileName, effect: .none,
                                                 issues: [ImportIssue(id: "readerProblem", kind: .readerProblem(text), reason: text)],
                                                 groupKey: UKStatementReader.groupKey)]
                }
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
            let files = (batches[reader] ?? []).map { (file: entries[$0].file, recognition: entries[$0].recognition) }
            proposed += try readers[reader].propose(files, context: context, db: db)
        }
        // Back in the order the files were handed in (a reader's children stay after their parent).
        let last = entries.count
        let ranked = proposed.enumerated().map { (rank: order[$0.element.file.url] ?? last, position: $0.offset, item: $0.element) }
        for entry in ranked.sorted(by: { ($0.rank, $0.position) < ($1.rank, $1.position) }) {
            byIndex[entry.rank, default: []].append(entry.item)
        }
        return byIndex.keys.sorted().flatMap { byIndex[$0] ?? [] }
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

    /// The item with a kind mismatch issue when the user said what the files are and this is
    /// something else.
    private static func withIntentIssue(_ item: ImportItem, intent: ImportIntent) -> ImportItem {
        guard item.parentId == nil, let issue = ImportDetector.intentIssue(item.recognition, intent: intent),
              !item.issues.contains(where: { $0.id == issue.id }) else { return item }
        var item = item
        item.issues.append(issue)
        return item
    }

    // MARK: Batch checks

    /// Ids of the issues the duplicate pass raises.
    static func isDuplicatePassIssue(_ id: String) -> Bool {
        id == "possibleDuplicate" || id == ImportDuplicates.correctedVersionIssueId
            || id.hasPrefix("sharedTransaction.") || id.hasPrefix("transactionHasDocument.")
    }

    static let kindMismatchId = "kindMismatch"

    /// Issues raised again on every pass (duplicate pass, intent mismatch), whose answer is kept.
    static func isSettleable(_ id: String) -> Bool { isDuplicatePassIssue(id) || id == kindMismatchId }

    /// What the user settled: the issue id, and for a possible duplicate or corrected version
    /// also which document it matched and how (another match asks again).
    static func settleKey(_ issue: ImportIssue) -> String {
        issue.id == "possibleDuplicate" || issue.id == ImportDuplicates.correctedVersionIssueId ? "\(issue.id)|\(issue.reason)" : issue.id
    }

    /// The duplicate pass re-run over the whole plan (its earlier marks removed, what the user
    /// settled kept settled), then the filed-year guard on `checking` and on every item the
    /// pass changed (nil: every item).
    /// `library`: the library's identity index read from the same database (else read now).
    static func annotate(_ plan: ImportPlan, checking: Set<UUID>?, db: Database, library: DocumentIdentityIndex? = nil,
                         timings: ImportPlanTimings? = nil) throws -> ImportPlan {
        var result = plan
        let previous = plan.items
        let stripped = previous.map { strip($0, batchDuplicate: plan.state.batchDuplicates.contains($0.id)) }
        var items = try timings.measure(.duplicates) { try ImportDuplicates.annotate(stripped, db: db, library: library) }
        result.state.batchDuplicates = Set(items.indices.filter { stripped[$0].duplicate == nil && items[$0].duplicate != nil }.map { items[$0].id })
        for i in items.indices {
            guard let settled = plan.state.settled[items[i].id], !settled.isEmpty else { continue }
            let answered = items[i].issues.filter { settled.contains(settleKey($0)) }
            items[i].issues.removeAll { settled.contains(settleKey($0)) }
            restoreLinks(&items[i], for: answered)
        }
        // Only what changed is guarded again (each item's check is independent of the others);
        // the confirm-time backstop (Task 13) re-checks the whole batch against the filed returns.
        let check = items.indices.filter { i in
            if let checking, !checking.contains(items[i].id) {
                return withoutGuard(items[i]) != withoutGuard(previous[i])
            }
            return true
        }
        if !check.isEmpty {
            let guarded = try timings.measure(.guardCheck) { try FiledYearGuard.annotate(check.map { items[$0] }, db: db) }
            for (offset, i) in check.enumerated() { items[i] = guarded[offset] }
        }
        result.items = items
        return result
    }

    /// The item without the duplicate pass's marks: its issues, its duplicate mark (when the
    /// pass, not the reader, made it) and the links a shared-transaction claim made unsure.
    private static func strip(_ item: ImportItem, batchDuplicate: Bool) -> ImportItem {
        var item = item
        if batchDuplicate { item.duplicate = nil }
        let raised = item.issues.filter { isDuplicatePassIssue($0.id) }
        item.issues.removeAll { isDuplicatePassIssue($0.id) }
        restoreLinks(&item, for: raised)
        return item
    }

    /// A shared-transaction claim made the item's certain link to that transaction unsure:
    /// with the claim gone (or settled) it is certain again.
    private static func restoreLinks(_ item: inout ImportItem, for issues: [ImportIssue]) {
        for issue in issues where issue.id.hasPrefix("sharedTransaction.") {
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
