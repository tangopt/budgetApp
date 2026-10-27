import Foundation
import GRDB
import os

/// What a confirmed import did, as counted for the run's summary.
public struct ImportRunSummary: Equatable, Sendable {
    public var runId: Int64
    /// Documents filed in the library (every applied item's file).
    public var filed: Int
    /// Of those, the ones linked to a record (a receipt, a transaction, a debit…).
    public var linked: Int
    /// Of those, the ones that recorded something (an invoice, an employment's figures, receipts).
    public var recorded: Int
    /// Bank rows added by the statements.
    public var transactions: Int
    public var duplicates: Int
    public var leftOut: Int
    public var backupPath: String?
    /// What the run didn't do and why ("Not learnt: different choices for …").
    public var notes: [String] = []
    /// The files it left unimported that can be set aside (kept for later, copied to a folder): not
    /// those already waiting, identical to a library document or read from the library.
    public var setAside: [SetAsideFile] = []
    /// The waiting documents the run's new transactions paid, linked automatically (`WaitingDocuments.run`), each
    /// with its own Undo in the summary.
    public var paymentLinks: [WaitingDocuments.Pair] = []

    public init(runId: Int64, filed: Int, linked: Int, recorded: Int, transactions: Int, duplicates: Int, leftOut: Int,
                backupPath: String?) {
        self.runId = runId
        self.filed = filed
        self.linked = linked
        self.recorded = recorded
        self.transactions = transactions
        self.duplicates = duplicates
        self.leftOut = leftOut
        self.backupPath = backupPath
    }

    /// "3 documents filed, 2 linked, 142 transactions, 1 document linked to its payment"; counts that are zero are left out
    /// (except the documents), duplicates and left-out files last; then the run's notes.
    public var text: String { text(paymentLinksUndone: 0) }

    /// `text` once `undone` of the payment links were taken back from the summary: "2 documents linked to their
    /// payments · 1 undone".
    public func text(paymentLinksUndone undone: Int) -> String {
        func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        var parts = [plural(filed, "document", "documents") + " filed"]
        if linked > 0 { parts.append("\(linked) linked") }
        if recorded > 0 { parts.append("\(recorded) recorded") }
        if transactions > 0 { parts.append(plural(transactions, "transaction", "transactions")) }
        if !paymentLinks.isEmpty {
            let linked = paymentLinks.count == 1 ? "1 document linked to its payment" : "\(paymentLinks.count) documents linked to their payments"
            parts.append(undone > 0 ? "\(linked) · \(undone) undone" : linked)
        }
        if duplicates > 0 { parts.append(plural(duplicates, "duplicate", "duplicates") + " skipped") }
        if leftOut > 0 { parts.append("\(leftOut) left out") }
        return ([parts.joined(separator: ", ")] + notes).joined(separator: ". ")
    }
}

public enum ImportApplyError: Error, Equatable {
    /// Something still needs the user (or nothing is ready, or an item can't be filed).
    case notConfirmable
    /// Applying the whole batch would change a filed or paid return: nothing was written.
    case filedYearChanged([FiledYearImpact])
    /// The plan's view of the database is out of date (what it links to or records against
    /// is gone, or a file changed since it was read): nothing was written; review again.
    case planOutdated(String)
}

/// Applies a confirmed `ImportPlan` as one undoable run, in one write transaction: the run row,
/// change capture (`ImportChangeCapture`, for `ImportUndo`), then for each Ready item its file
/// filed in the library (a file already there — a statement that still adds rows — gives that
/// document: no second copy, nothing for Undo to remove) and `ImportEffects.applyRecords` (the effect, its certain links and the
/// documents they replace unlinked — exactly what the filed-year guard simulated), and the
/// source folder's record of the file given its document; then the
/// follow-on matching once for every property the items touched (`ImportEffects.followOns`)
/// and the forecasts refreshed. Before anything is written the filed returns' figures are
/// taken; if the whole batch moved any of them, everything is rolled back
/// (`.filedYearChanged`). Every file gets an `ImportRunFile` (duplicates and left-out too).
/// On any failure the transaction rolls back and the copies placed in the library are removed.
/// A backup is taken first when the plan is large (`ImportBackup`).
public struct ImportApplier: Sendable {
    private let dbQueue: DatabaseQueue
    private let databasePath: String?
    private let library: EvidenceLibrary

    public init(dbQueue: DatabaseQueue, databasePath: String?, library: EvidenceLibrary) {
        self.dbQueue = dbQueue
        self.databasePath = databasePath
        self.library = library
    }

    /// `reasons`: the user's reason per item (by item id), kept with the run and on each file.
    /// `confirmedBy`: the app user signed in when Confirm was pressed (nil: a tool), kept with the run
    /// and on the rules it learns. The run writes as them (nil: the admin), and only with Edit on Import
    /// (`ActorWrite.perform`, origin `.import`): without it nothing is written (`AccessDenied`).
    public func apply(_ plan: ImportPlan, entryPoint: String, reasons: [UUID: String] = [:], confirmedBy appUserId: Int64? = nil,
                      now: Date = Date()) throws -> ImportRunSummary {
        guard plan.canConfirm else { throw ImportApplyError.notConfirmable }
        let applied = Self.appliedItems(plan)
        // A file that couldn't be read has no real hash: it is never filed.
        guard !applied.isEmpty, !applied.contains(where: ImportResolutions.isUnreadable) else { throw ImportApplyError.notConfirmable }
        // Checked before the backup too, so an outdated plan writes nothing at all.
        try dbQueue.read { db in
            // With sync on, one import is confirmed at a time per household (sync spec §5.2).
            try SyncImportGate.check(db: db, now: now)
            try Self.checkKinds(db: db, applied, pending: plan.pendingKinds)
            try Self.checkCurrent(db: db, applied)
        }

        let backupPath = try ImportBackup.backupIfNeeded(dbQueue: dbQueue, databasePath: databasePath, plan: plan, now: now)
        var placed: [URL] = []
        do {
            // Source folders' files are copied into the library inside their folders' security scopes.
            let folderIds = Array(Set(applied.compactMap { $0.parentId == nil ? $0.file.sourceFolderId : nil })).sorted()
            return try withSourceFolders(folderIds) { roots in
                try dbQueue.write { db in
                    do {
                        // Step 6: as whoever confirmed (nil: the admin, as a tool), with Import's permission and origin.
                        return try ActorWrite.perform(orAdmin: try ActorWrite.actor(appUserId: appUserId, db: db), area: .import, origin: .import, db: db) {
                            try applyAll(db: db, plan: plan, applied: applied, entryPoint: entryPoint, reasons: reasons, appUserId: appUserId,
                                         backupPath: backupPath, folderRoots: roots, now: now, placed: &placed)
                        }
                    } catch {
                        try? ImportChangeCapture.cancel(db: db)
                        throw error
                    }
                }
            }
        } catch {
            do {
                try library.removeOrphanedFiles(placedFiles: placed)
            } catch let cleanup {
                Self.log.error("Import rolled back; removing the \(placed.count) copies it placed failed: \(String(describing: cleanup), privacy: .public)")
            }
            throw error
        }
    }

    private static let log = Logger(subsystem: "com.personal.budget", category: "DocumentImport")

    /// Runs `body` inside the security scope of each source folder in `folderIds`, with where
    /// each folder is now (its bookmark followed). A folder no longer registered refuses the plan.
    private func withSourceFolders<T>(_ folderIds: [Int64], roots: [Int64: URL] = [:], _ body: ([Int64: URL]) throws -> T) throws -> T {
        guard let folderId = folderIds.first else { return try body(roots) }
        guard let folder = try dbQueue.read({ db in try SourceFolder.fetchOne(db, key: folderId) }) else {
            throw ImportApplyError.planOutdated("A source folder of these files is no longer registered")
        }
        let resolved: SourceFolderScanner.ResolvedFolder
        let stop: () -> Void
        do {
            (resolved, stop) = try SourceFolderScanner(library: library).access(folder)
        } catch SourceFolderError.unavailable {
            throw ImportApplyError.planOutdated("The folder \(folder.name) can't be found (\(folder.path)). Is its disk connected?")
        }
        defer { stop() }
        var roots = roots
        roots[folderId] = resolved.url
        return try withSourceFolders(Array(folderIds.dropFirst()), roots: roots, body)
    }

    /// Where the item's file is read from when filed: a source folder's file at its path in the
    /// folder as resolved now, any other where it was read.
    static func fileURL(of item: ImportItem, folderRoots: [Int64: URL]) -> URL {
        guard let folderId = item.file.sourceFolderId, let path = item.file.sourceRelativePath, let root = folderRoots[folderId] else {
            return item.file.url
        }
        return root.appendingPathComponent(path)
    }

    // MARK: Which items

    /// The Ready items to apply, in plan order (a statement before the child holding its
    /// already-imported rows) — except that the statements (UK and BBVA) of one account are
    /// applied in date order (`StatementChecks.order`: period start, then closing day), each with
    /// its children, in the places those statements hold: never
    /// left out (nor a child of a left-out item), duplicates or items with issues.
    static func appliedItems(_ plan: ImportPlan) -> [ImportItem] {
        let leftOut = leftOutIds(plan)
        let ready = plan.items.filter { $0.section == .ready && !leftOut.contains($0.id) }
        // Units: an item with the children that follow it (a child whose parent isn't applied stands alone).
        let readyIds = Set(ready.map(\.id))
        var units: [[ImportItem]] = []
        for item in ready {
            if let parent = item.parentId, readyIds.contains(parent), let index = units.lastIndex(where: { $0.first?.id == parent }) {
                units[index].append(item)
            } else {
                units.append([item])
            }
        }
        func account(_ unit: [ImportItem]) -> Int64? { unit.first.flatMap(StatementChecks.accountId) }
        let byAccount = Dictionary(grouping: units.indices.filter { account(units[$0]) != nil }) { account(units[$0])! }
        var ordered = units
        for slots in byAccount.values where slots.count > 1 {
            let sorted = slots.sorted { StatementChecks.order(units[$0][0], $0) < StatementChecks.order(units[$1][0], $1) }
            for (slot, source) in zip(slots, sorted) { ordered[slot] = units[source] }
        }
        return ordered.flatMap { $0 }
    }

    /// Items left out, with the children of left-out items.
    static func leftOutIds(_ plan: ImportPlan) -> Set<UUID> {
        let parents = Set(plan.items.filter(\.isLeftOut).map(\.id))
        return Set(plan.items.filter { $0.isLeftOut || $0.parentId.map(parents.contains) == true }.map(\.id))
    }

    // MARK: Outdated plan

    /// Refuses (`.notConfirmable`: the review is read again) when an applied item is filed as a
    /// saved custom kind that is gone or merged since it was read, or as a new kind the plan
    /// doesn't hold.
    static func checkKinds(db: Database, _ items: [ImportItem], pending: [PendingDocumentKind]) throws {
        let keys = items.compactMap { $0.recognition.kind.customKindKey }
        guard !keys.isEmpty else { return }
        let catalog = try DocumentKindCatalog.load(db: db)
        for key in keys {
            switch key {
            case .saved(let id): if catalog.custom(id: id) == nil { throw ImportApplyError.notConfirmable }
            case .pending(let id): if !pending.contains(where: { $0.id == id }) { throw ImportApplyError.notConfirmable }
            }
        }
    }

    /// The review's new kinds the applied items use, saved (inside the run, so Undo removes them):
    /// a kind of the same name saved meanwhile (on another device) is that kind, never a second one.
    /// `notes`: a line for each such kind spelt otherwise or in another area than the review showed.
    static func savePendingKinds(db: Database, _ items: [ImportItem], pending: [PendingDocumentKind], now: Date) throws
        -> (saved: [UUID: Int64], notes: [String]) {
        var used: [UUID] = []
        for item in items {
            if case .customEvidence(.pending(let id)) = item.recognition.kind, !used.contains(id) { used.append(id) }
        }
        var saved: [UUID: Int64] = [:]
        var notes: [String] = []
        guard !used.isEmpty else { return (saved, notes) }
        // Read once; the kinds saved here are told apart by name (no two pending kinds share one).
        let catalog = try DocumentKindCatalog.load(db: db)
        for id in used {
            guard let kind = pending.first(where: { $0.id == id }) else { throw ImportApplyError.notConfirmable }
            if let existing = catalog.custom(named: kind.name), let existingId = existing.id {
                saved[id] = existingId
                // Spelt otherwise or in another area than the review showed: the summary says so.
                if existing.name != kind.name || existing.area != kind.area {
                    notes.append("\(kind.name) (\(kind.area.libraryArea)) was filed under the kind \u{201C}\(existing.name)\u{201D} (\(existing.area.libraryArea)), saved meanwhile")
                }
            } else {
                guard let newId = try CustomDocumentKinds.create(db: db, name: kind.name, area: kind.area, now: now).id else {
                    throw ImportApplyError.notConfirmable
                }
                saved[id] = newId
            }
        }
        return (saved, notes)
    }

    /// The canonical name of an item filed as the custom kind `kind`, from its facts and the kind's
    /// current name and area.
    static func canonicalName(of item: ImportItem, as kind: CustomDocumentKind) -> String? {
        guard let id = kind.id else { return item.placement?.canonicalName }
        let custom = ImportCustomKind(key: .saved(id), name: kind.name, area: kind.area)
        return ImportNaming.placement(kind: .customEvidence(.saved(id)), facts: item.facts, file: item.file,
                                      persons: item.placement?.metadata.persons ?? [], customKind: custom).canonicalName
    }

    /// Refuses (`.planOutdated`) when a record an applied item writes to or links to no longer
    /// exists: each certain link's record; the export's property; the receipt PDF's receipt and
    /// tenancy; the advice's credits; the invoice's provider and debit; the payroll form's
    /// person; the statement's account and the manual entries its rows replace. (The file's
    /// content is checked as it is filed: a file changed since it was read is refused too.)
    static func checkCurrent(db: Database, _ items: [ImportItem]) throws {
        func require(_ exists: Bool, _ item: ImportItem, _ what: String) throws {
            if !exists { throw ImportApplyError.planOutdated("\(item.title): \(what) no longer exists") }
        }
        for item in items {
            for link in item.links where link.confidence == .certain {
                try require(EvidenceLinks.entityExists(db: db, link.entity), item, link.label)
            }
            switch item.effect {
            case .file, .none:
                break
            case .rentReceiptsExport(let propertyId, _):
                try require(Property.exists(db, key: propertyId), item, "Its property")
            case .rentReceiptPDF(let planned):
                if let id = planned.receipt?.id { try require(RentReceipt.exists(db, key: id), item, "Its receipt") }
                if let id = planned.tenancy?.id { try require(Tenancy.exists(db, key: id), item, "Its tenancy") }
            case .transferAdvice(let planned):
                for credit in planned.credits {
                    if let id = credit.id { try require(Transaction.exists(db, key: id), item, "Its credit") }
                }
            case .utilityInvoice(let invoice):
                try require(UtilityProvider.exists(db, key: invoice.providerId), item, "Its provider")
                if let id = invoice.transactionId { try require(Transaction.exists(db, key: id), item, "Its debit") }
            case .attachToInvoice(let invoiceId):
                try require(UtilityInvoice.exists(db, key: invoiceId), item, "The recorded invoice it is attached to")
            case .payrollForm(let confirmed):
                try require(Person.exists(db, key: confirmed.personId), item, "Its person")
            case .ukStatement(let statement):
                try require(Account.exists(db, key: statement.accountId), item, "Its account")
                for row in statement.staged {
                    if let id = row.replacesManual?.transactionId {
                        try require(Transaction.exists(db, key: id), item, "The manual entry it replaces")
                    }
                }
            case .bbvaStatement(let statement):
                try require(Account.exists(db, key: statement.currentAccountId), item, "Its account")
                if let id = statement.loanAccountId { try require(Account.exists(db, key: id), item, "Its mortgage account") }
                if let id = statement.fundAccountId { try require(Account.exists(db, key: id), item, "Its fund account") }
                for row in statement.staged {
                    if let id = row.replacesManual?.transactionId {
                        try require(Transaction.exists(db, key: id), item, "The manual entry it replaces")
                    }
                }
                for estimate in statement.estimates {
                    try require(Transaction.exists(db, key: estimate.transactionId), item, "The estimated interest it replaces")
                }
            }
        }
    }

    // MARK: The write

    private func applyAll(db: Database, plan: ImportPlan, applied: [ImportItem], entryPoint: String, reasons: [UUID: String], appUserId: Int64?,
                       backupPath: String?, folderRoots: [Int64: URL], now: Date, placed: inout [URL]) throws -> ImportRunSummary {
        try Self.checkKinds(db: db, applied, pending: plan.pendingKinds)
        try Self.checkCurrent(db: db, applied)
        try SyncImportGate.require(db: db, now: now)
        // Everything the run writes from here on is one sync batch (sync spec §5.2).
        let syncMark = try SyncBatch.mark(db: db)
        var run = ImportRun(confirmedAt: now, entryPoint: entryPoint, summary: "", backupPath: backupPath,
                            reasonsJSON: try Self.reasonsJSON(reasons), appUserId: appUserId)
        try run.insert(db)
        let runId = run.id!
        try ImportChangeCapture.begin(db: db)
        // The figures as stored, before any change (not after a matching baseline).
        let raw = try TaxFigures.snapshot(db: db)
        let folders = try SourceFolder.fetchAll(db)
        // The review's new kinds first, so the documents can be filed under them.
        let (newKinds, kindNotes) = try Self.savePendingKinds(db: db, applied, pending: plan.pendingKinds, now: now)
        // The custom kinds as they are now: documents are named after the kind's current name and
        // area (renamed during the review, or a kind of the same name saved meanwhile).
        let kindsNow = try DocumentKindCatalog.load(db: db)

        // The last transaction before the run: the waiting documents are matched only when it adds some.
        let lastTransaction = try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM \(Transaction.databaseTableName)") ?? 0
        var documents: [UUID: Int64] = [:]
        var touched: Set<Int64>? = []
        for item in applied {
            let filing = Self.filing(for: item, folders: folders, newKinds: newKinds, kindsNow: kindsNow)
            let documentId: Int64
            if let parentId = item.parentId, let parentDocument = documents[parentId] {
                // Part of a file already filed (a statement's child): the same document.
                documentId = parentDocument
            } else {
                documentId = try Self.fileDocument(db: db, item: item, url: Self.fileURL(of: item, folderRoots: folderRoots), filing: filing,
                                                   library: library, now: now, placed: &placed)
            }
            documents[item.id] = documentId
            if touched != nil, let more = try ImportEffects.touchedPropertyIds(db: db, item: item) {
                touched?.formUnion(more)
            } else {
                touched = nil
            }
            try ImportEffects.applyRecords(db: db, item: item, documentId: documentId, importRunId: runId, confirmedBy: appUserId)
            if let folderId = filing.sourceFolderId {
                try db.execute(sql: "UPDATE sourceFile SET documentId = ? WHERE folderId = ? AND sha256 = ? AND documentId IS NULL",
                               arguments: [documentId, folderId, item.file.sha256])
            }
        }
        try Self.recordSourceFiles(db: db, plan: plan, documents: documents)
        // What the review's corrections taught, and the learnt rules the items used: inside the run.
        // Items that taught different things about one issuer (and family) teach none of them.
        let drafts = applied.flatMap(\.ruleDrafts).compactMap { draft -> ImportRuleDraft? in
            var resolved = draft
            if let pending = draft.pendingKindId {
                // A new kind's rule names the id it was saved with.
                guard let id = newKinds[pending], let json = ImportLearning.encode(DocumentKindAction(kind: .other, customKindId: id)) else { return nil }
                resolved.actionJSON = json
                resolved.pendingKindId = nil
            }
            // Labelled with the kind's name as it is now.
            if resolved.kind == .documentKind, let id = ImportLearning.decode(DocumentKindAction.self, resolved.actionJSON)?.customKindId,
               let kind = kindsNow.custom(id: id) {
                resolved.actionLabel = "Kind: \(kind.name)"
            }
            return resolved
        }
        let (learnable, learningNotes) = ImportLearning.learnable(drafts)
        for draft in learnable {
            try ImportRuleStore.learn(db: db, kind: draft.kind, key: draft.key, matchLabel: draft.matchLabel,
                                      actionJSON: draft.actionJSON, actionLabel: draft.actionLabel, now: now, by: appUserId)
        }
        let used = applied.flatMap { $0.appliedRules.map(\.ruleId) }
        if !used.isEmpty { try ImportRuleStore.markUsed(db: db, ids: used, now: now) }
        try ImportEffects.followOns(db: db, propertyIds: touched)
        // Documents first, statements later: the waiting documents the new rows paid are linked, each in its own
        // filed-year-guarded savepoint (a refused one stays a suggestion), captured with the run so its Undo
        // takes them back too.
        let added = Set(try Int64.fetchAll(db, sql: "SELECT id FROM \(Transaction.databaseTableName) WHERE id > ?", arguments: [lastTransaction]))
        let paymentLinks = try added.isEmpty ? [] : WaitingDocuments.run(db: db, newTransactions: added, now: now).linked
        try AutoForecastGenerator.refresh(db: db)

        // The confirm-time backstop: the batch as a whole (per-item checks aren't additive).
        let impacts = try FiledYearGuard.filedChanges(db: db, from: raw)
        guard impacts.isEmpty else { throw ImportApplyError.filedYearChanged(impacts) }

        var summary = ImportRunSummary(runId: runId, filed: 0, linked: 0, recorded: 0, transactions: 0, duplicates: 0, leftOut: 0,
                                       backupPath: backupPath)
        summary.notes = kindNotes + learningNotes
        summary.paymentLinks = paymentLinks
        let leftOut = Self.leftOutIds(plan)
        let byId = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.id, $0) })
        summary.filed = Set(documents.values).count
        for item in plan.items {
            var file = ImportRunFile(runId: runId, fileName: item.file.fileName, sha256: item.file.sha256, outcome: .filed, detail: "")
            if leftOut.contains(item.id) {
                file.outcome = .leftOut
                file.detail = reasons[item.id] ?? "Left out of this import"
                summary.leftOut += 1
            } else if let duplicate = item.duplicate {
                file.outcome = .duplicate
                file.detail = duplicate.of
                file.documentId = duplicate.existingDocumentId
                summary.duplicates += 1
            } else if let documentId = documents[item.id], let parent = item.parentId.flatMap({ byId[$0] }), documents[parent.id] != nil {
                // Part of its parent's file: the parent's outcome, counted once (with the parent).
                file.documentId = documentId
                file.outcome = Self.outcome(parent).0
                file.detail = "Part of \(parent.title)"
            } else if let documentId = documents[item.id] {
                file.documentId = documentId
                (file.outcome, file.detail) = Self.outcome(item)
                switch file.outcome {
                case .linked: summary.linked += 1
                case .recorded: summary.recorded += 1
                case .transactions:
                    if case .ukStatement(let statement) = item.effect { summary.transactions += statement.staged.count }
                    if case .bbvaStatement(let statement) = item.effect { summary.transactions += statement.staged.count }
                default: break
                }
            } else {
                // Not ready (can't happen once the plan is confirmable): recorded as left out.
                file.outcome = .leftOut
                file.detail = "Not applied"
                summary.leftOut += 1
            }
            try file.insert(db)
        }
        _ = try ImportChangeCapture.finish(db: db, runId: runId)
        // After the capture: Undo leaves the mark, and a run undone lists its waiting files again
        // (`ImportWaitingList.waiting`). Inside the run's sync batch.
        try ImportWaitingList.markImported(db: db, runId: runId, sha256s: Set(applied.filter { documents[$0.id] != nil }.map(\.file.sha256)))
        let waiting = try ImportWaitingList.waitingHashes(db: db)
        let libraryPath = library.root.standardizedFileURL.path + "/"
        summary.setAside = ImportSetAside.candidates(plan, discarding: false, names: ImportKindNames(catalog: kindsNow, pending: plan.pendingKinds))
            .filter { !waiting.contains($0.sha256.lowercased()) && !$0.url.standardizedFileURL.path.hasPrefix(libraryPath) }
        run.summary = summary.text
        try run.update(db)
        try SyncBatch.open(runId: runId, since: syncMark, db: db)
        return summary
    }

    /// The library metadata an applied item is filed with (`metadata`), a custom kind's as it is
    /// now: a saved one's id, a new one's as saved in the run (`newKinds`), named after its current
    /// name and area (`kindsNow`). Shared with the iPad's check-and-link (`CheckAndLink.save`).
    static func filing(for item: ImportItem, folders: [SourceFolder], newKinds: [UUID: Int64], kindsNow: DocumentKindCatalog) -> EvidenceMetadata {
        var filing = metadata(for: item, folders: folders)
        if case .customEvidence(let key) = item.recognition.kind {
            filing.kind = .other
            switch key {
            case .saved(let id): filing.customKindId = id
            case .pending(let id): filing.customKindId = newKinds[id]
            }
            if let id = filing.customKindId, let kind = kindsNow.custom(id: id) {
                filing.canonicalName = canonicalName(of: item, as: kind)
            }
        }
        return filing
    }

    /// The item's file at `url` filed in the library inside the caller's write (`EvidenceLibrary.add(db:…)`;
    /// the copy it places is appended to `placed`, for the caller to remove if the write rolls back): its
    /// document's id. A file gone, or changed since it was read (another hash), refuses (`.planOutdated`).
    /// Shared with the iPad's check-and-link (`CheckAndLink.save`).
    static func fileDocument(db: Database, item: ImportItem, url: URL, filing: EvidenceMetadata, library: EvidenceLibrary, now: Date,
                             placed: inout [URL]) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ImportApplyError.planOutdated("\(item.file.fileName) is no longer where it was read (\(url.path))")
        }
        let staged = try library.add(db: db, url, metadata: filing, analysis: nil, now: now)
        if let file = staged.placedFile { placed.append(file) }
        guard staged.result.document.sha256 == item.file.sha256 else {
            throw ImportApplyError.planOutdated("\(item.file.fileName) changed since it was read")
        }
        guard let id = staged.result.document.id else { throw EvidenceLibraryError.documentNotFound }
        return id
    }

    /// The source folders' files of the plan (`ImportFile.sourceFolderId`), now that the user
    /// has seen them: each scan record still holding the content read gets the document it was
    /// filed as or duplicates (left-out files get none), and its pending change is acknowledged —
    /// filed, duplicate and left-out files alike. Inside the run, so Undo restores both.
    static func recordSourceFiles(db: Database, plan: ImportPlan, documents: [UUID: Int64]) throws {
        let leftOut = leftOutIds(plan)
        var seen: Set<String> = []
        for item in plan.items where item.parentId == nil {
            guard let folderId = item.file.sourceFolderId, let path = item.file.sourceRelativePath,
                  seen.insert("\(folderId)/\(path)").inserted else { continue }
            // Only while the record is of the content the review read (not changed again since).
            guard let record = try SourceFile.filter(Column("folderId") == folderId && Column("relativePath") == path).fetchOne(db),
                  record.sha256 == item.file.sha256 else { continue }
            // A duplicate: the library document it copies, or the document its original in this batch was filed as.
            let documentId = leftOut.contains(item.id) ? nil
                : documents[item.id] ?? item.duplicate?.existingDocumentId ?? item.duplicate?.originalItemId.flatMap { documents[$0] }
            if let documentId, record.documentId == nil {
                try SourceFile.filter(key: record.id).updateAll(db, Column("documentId").set(to: documentId))
            }
            if record.hasPendingChange {
                try SourceFolderScanner.acknowledgeChange(db: db, folderId: folderId, relativePath: path)
            }
        }
    }

    /// The library metadata the item is filed with: its placement, its name, its text, and the
    /// source folder holding the file (the deepest one, links resolved) when it came from one.
    static func metadata(for item: ImportItem, folders: [SourceFolder]) -> EvidenceMetadata {
        var metadata = item.placement?.metadata ?? EvidenceMetadata(kind: .other)
        if metadata.canonicalName == nil { metadata.canonicalName = item.placement?.canonicalName }
        if metadata.textStatus == .unknown {
            metadata.textStatus = item.file.textStatus
            metadata.extractedText = metadata.extractedText ?? item.file.text
        }
        if metadata.sourceFolderId == nil, !folders.isEmpty {
            let path = TaxRegression.resolvedPath(item.file.url.path)
            let folder = folders.map { (folder: $0, root: TaxRegression.resolvedPath($0.path)) }
                .filter { path.hasPrefix($0.root + "/") }
                .max { $0.root.count < $1.root.count }
            if let folder {
                metadata.sourceFolderId = folder.folder.id
                metadata.sourceRelativePath = String(path.dropFirst(folder.root.count + 1))
                metadata.sourceModifiedAt = metadata.sourceModifiedAt ?? item.file.sourceModifiedAt
            }
        }
        return metadata
    }

    /// An applied item's outcome and its line: a statement's rows, else a link, else a record,
    /// else just filed.
    static func outcome(_ item: ImportItem) -> (ImportFileOutcome, String) {
        let linked = item.links.filter { $0.confidence == .certain }.map(\.label)
        func linkedLine() -> String { "Linked to " + (linked.isEmpty ? "its record" : linked.joined(separator: ", ")) }
        switch item.effect {
        case .ukStatement(let statement):
            let n = statement.staged.count
            return (.transactions, "\(n) transaction\(n == 1 ? "" : "s")")
        case .bbvaStatement(let statement):
            let n = statement.staged.count
            return (.transactions, "\(n) transaction\(n == 1 ? "" : "s")")
        case .rentReceiptPDF, .transferAdvice:
            return (.linked, linkedLine())
        case .utilityInvoice(let invoice):
            return invoice.transactionId != nil || !linked.isEmpty ? (.linked, linkedLine()) : (.recorded, "Recorded: \(item.title)")
        case .attachToInvoice:
            return (.linked, UtilityInvoiceImportReader.attachedNote)
        case .rentReceiptsExport, .payrollForm:
            return (.recorded, "Recorded: \(item.title)")
        case .file, .none:
            let name = item.placement?.canonicalName ?? item.file.fileName
            return linked.isEmpty ? (.filed, "Filed as \(name)") : (.linked, linkedLine())
        }
    }

    /// `{"<item id>": "<reason>"}`.
    static func reasonsJSON(_ reasons: [UUID: String]) throws -> String? {
        guard !reasons.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let byId = Dictionary(uniqueKeysWithValues: reasons.map { ($0.key.uuidString, $0.value) })
        return String(data: try encoder.encode(byId), encoding: .utf8)
    }
}
