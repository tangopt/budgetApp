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

    /// "3 documents filed, 2 linked, 142 transactions"; counts that are zero are left out
    /// (except the documents), duplicates and left-out files last; then the run's notes.
    public var text: String {
        func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        var parts = [plural(filed, "document", "documents") + " filed"]
        if linked > 0 { parts.append("\(linked) linked") }
        if recorded > 0 { parts.append("\(recorded) recorded") }
        if transactions > 0 { parts.append(plural(transactions, "transaction", "transactions")) }
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
    public func apply(_ plan: ImportPlan, entryPoint: String, reasons: [UUID: String] = [:], now: Date = Date()) throws -> ImportRunSummary {
        guard plan.canConfirm else { throw ImportApplyError.notConfirmable }
        let applied = Self.appliedItems(plan)
        // A file that couldn't be read has no real hash: it is never filed.
        guard !applied.isEmpty, !applied.contains(where: ImportResolutions.isUnreadable) else { throw ImportApplyError.notConfirmable }
        // Checked before the backup too, so an outdated plan writes nothing at all.
        try dbQueue.read { db in try Self.checkCurrent(db: db, applied) }

        let backupPath = try ImportBackup.backupIfNeeded(dbQueue: dbQueue, databasePath: databasePath, plan: plan, now: now)
        var placed: [URL] = []
        do {
            // Source folders' files are copied into the library inside their folders' security scopes.
            let folderIds = Array(Set(applied.compactMap { $0.parentId == nil ? $0.file.sourceFolderId : nil })).sorted()
            return try withSourceFolders(folderIds) { roots in
                try dbQueue.write { db in
                    do {
                        return try applyAll(db: db, plan: plan, applied: applied, entryPoint: entryPoint, reasons: reasons,
                                            backupPath: backupPath, folderRoots: roots, now: now, placed: &placed)
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

    private static let log = Logger(subsystem: "Budget", category: "Import")

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

    private func applyAll(db: Database, plan: ImportPlan, applied: [ImportItem], entryPoint: String, reasons: [UUID: String],
                       backupPath: String?, folderRoots: [Int64: URL], now: Date, placed: inout [URL]) throws -> ImportRunSummary {
        try Self.checkCurrent(db: db, applied)
        var run = ImportRun(confirmedAt: now, entryPoint: entryPoint, summary: "", backupPath: backupPath,
                            reasonsJSON: try Self.reasonsJSON(reasons))
        try run.insert(db)
        let runId = run.id!
        try ImportChangeCapture.begin(db: db)
        // The figures as stored, before any change (not after a matching baseline).
        let raw = try TaxFigures.snapshot(db: db)
        let folders = try SourceFolder.fetchAll(db)

        var documents: [UUID: Int64] = [:]
        var touched: Set<Int64>? = []
        for item in applied {
            let filing = Self.metadata(for: item, folders: folders)
            let documentId: Int64
            if let parentId = item.parentId, let parentDocument = documents[parentId] {
                // Part of a file already filed (a statement's child): the same document.
                documentId = parentDocument
            } else {
                let url = Self.fileURL(of: item, folderRoots: folderRoots)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw ImportApplyError.planOutdated("\(item.file.fileName) is no longer where it was read (\(url.path))")
                }
                let staged = try library.add(db: db, url, metadata: filing, analysis: nil, now: now)
                if let file = staged.placedFile { placed.append(file) }
                guard staged.result.document.sha256 == item.file.sha256 else {
                    throw ImportApplyError.planOutdated("\(item.file.fileName) changed since it was read")
                }
                guard let id = staged.result.document.id else { throw EvidenceLibraryError.documentNotFound }
                documentId = id
            }
            documents[item.id] = documentId
            if touched != nil, let more = try ImportEffects.touchedPropertyIds(db: db, item: item) {
                touched?.formUnion(more)
            } else {
                touched = nil
            }
            try ImportEffects.applyRecords(db: db, item: item, documentId: documentId, importRunId: runId)
            if let folderId = filing.sourceFolderId {
                try db.execute(sql: "UPDATE sourceFile SET documentId = ? WHERE folderId = ? AND sha256 = ? AND documentId IS NULL",
                               arguments: [documentId, folderId, item.file.sha256])
            }
        }
        try Self.recordSourceFiles(db: db, plan: plan, documents: documents)
        // What the review's corrections taught, and the learnt rules the items used: inside the run.
        // Items that taught different things about one issuer (and family) teach none of them.
        let (learnable, learningNotes) = ImportLearning.learnable(applied.flatMap(\.ruleDrafts))
        for draft in learnable {
            try ImportRuleStore.learn(db: db, kind: draft.kind, key: draft.key, matchLabel: draft.matchLabel,
                                      actionJSON: draft.actionJSON, actionLabel: draft.actionLabel, now: now)
        }
        let used = applied.flatMap { $0.appliedRules.map(\.ruleId) }
        if !used.isEmpty { try ImportRuleStore.markUsed(db: db, ids: used, now: now) }
        try ImportEffects.followOns(db: db, propertyIds: touched)
        try AutoForecastGenerator.refresh(db: db)

        // The confirm-time backstop: the batch as a whole (per-item checks aren't additive).
        let impacts = try FiledYearGuard.filedChanges(db: db, from: raw)
        guard impacts.isEmpty else { throw ImportApplyError.filedYearChanged(impacts) }

        var summary = ImportRunSummary(runId: runId, filed: 0, linked: 0, recorded: 0, transactions: 0, duplicates: 0, leftOut: 0,
                                       backupPath: backupPath)
        summary.notes = learningNotes
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
        run.summary = summary.text
        try run.update(db)
        return summary
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
