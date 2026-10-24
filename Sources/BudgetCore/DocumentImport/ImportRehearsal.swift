import Foundation
import GRDB

/// "Delete every imported document (not the statements) and import them again through the
/// importer", rehearsed on a copy (the `ImportRehearsal` tool): the source database is opened
/// read-only and copied with a backup into a temporary folder, the evidence library folder is
/// copied there too, and only the copies are opened for writing. Everything temporary is
/// deleted before it returns unless `keep`.
///
/// On the copy: the documents to delete are every document except the statements (kind Bank
/// statement, or filed by an import run as a statement whose rows were imported); each one's
/// stored file is exported under its original name; the tax figures and each document's kind,
/// date, amount and links are taken; the documents are deleted the way the app's Documents
/// screen deletes them (`EvidenceLibrary.remove(force:)`: the row, its links by cascade, the
/// stored copy; utility invoices', recharge lines' and source-folder records' references are
/// cleared by their foreign keys); then the exported files are planned by `ImportPipeline` (no
/// intent) and only the Ready items applied by `ImportApplier` (Needs you and Duplicates left
/// out). The report compares before and after.
public enum ImportRehearsal {
    public enum PathError: Error, Equatable, LocalizedError {
        case missing(String)
        case notAFolder(String)
        /// The app's own database or library without `--allow-app-data`.
        case appData(String)
        /// A report folder inside the app's data, or inside the library being rehearsed.
        case reportPlacement(String)

        public var errorDescription: String? {
            switch self {
            case .missing(let path): return "Nothing at \(path)"
            case .notAFolder(let path): return "\(path) is not a folder"
            case .appData(let path): return "Refusing the app's own data (\(path)): pass a copy, or --allow-app-data (it is only read and copied)."
            case .reportPlacement(let path): return "Refusing to write a report at \(path): not inside the app's data or the library."
            }
        }
    }

    /// A document left in place as a statement.
    public struct Excluded: Equatable, Sendable {
        public var name: String
        public var kind: DocumentKind
        public var reason: String
    }

    public struct Report: Sendable {
        /// The temporary folder (removed unless `keep`).
        public var workFolder: URL
        /// Documents chosen for deletion (all but the excluded).
        public var deleted: Int
        public var excluded: [Excluded]
        /// Ready, applied, and back in the library.
        public var cameBack: Int
        public var needsYou: Int
        public var duplicates: Int
        public var failed: Int
        /// Filed or paid figures that differ between before and after (must be empty).
        public var filedChanges: [FiledYearImpact]
        /// The markdown report.
        public var text: String
    }

    /// `~` expanded and the path standardised, so the guard sees what is opened.
    public static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    /// The database (a file), library (a folder) and report folder normalised, or the reason
    /// they are refused: the app's own database or library without `allowAppData`, a report
    /// folder inside the app's data or the library (ever). `isAppData` is the guard (tests
    /// pass a stand-in app folder, so they never need the real one to exist).
    @discardableResult
    public static func checkPaths(databasePath: String, libraryPath: String, outPath: String?,
                                  allowAppData: Bool,
                                  isAppData: (String) -> Bool = { TaxRegression.isAppData($0) }) throws -> (database: String, library: String, out: String?) {
        let fileManager = FileManager.default
        let database = normalized(databasePath)
        let library = normalized(libraryPath)
        var isFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: database, isDirectory: &isFolder) else { throw PathError.missing(database) }
        if isFolder.boolValue { throw PathError.missing(database) }
        guard fileManager.fileExists(atPath: library, isDirectory: &isFolder) else { throw PathError.missing(library) }
        guard isFolder.boolValue else { throw PathError.notAFolder(library) }
        if !allowAppData {
            for path in [database, library] where isAppData(path) { throw PathError.appData(path) }
        }
        var out: String?
        if let outPath {
            let path = normalized(outPath)
            let resolvedLibrary = URL(fileURLWithPath: library).resolvingSymlinksInPath().path.lowercased()
            let resolvedOut = URL(fileURLWithPath: path).resolvingSymlinksInPath().path.lowercased()
            if isAppData(path) || resolvedOut == resolvedLibrary || resolvedOut.hasPrefix(resolvedLibrary + "/") {
                throw PathError.reportPlacement(path)
            }
            out = path
        }
        return (database, library, out)
    }

    // MARK: Running

    /// One document chosen for deletion, as it was.
    struct Original {
        var id: Int64
        var sha256: String
        var name: String
        var kind: DocumentKind
        var docDate: Date?
        var amountMinorUnits: Int?
        var currency: Currency?
        var links: [LinkKey: String?]
        /// The exported file's name; nil when the stored file was missing (not deleted).
        var exportedName: String?
    }

    struct LinkKey: Hashable, Comparable {
        var type: EvidenceEntityType
        var id: Int64
        static func < (lhs: LinkKey, rhs: LinkKey) -> Bool { (lhs.type.rawValue, lhs.id) < (rhs.type.rawValue, rhs.id) }
    }

    enum Outcome {
        case cameBack
        case needsYou([String])
        case duplicate(String)
        case failed(String)
    }

    public static func run(databasePath: String, libraryPath: String, keep: Bool = false) async throws -> Report {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent("ImportRehearsal-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { if !keep { try? fileManager.removeItem(at: work) } }

        // The copies: only these are ever opened for writing.
        let copyPath = work.appendingPathComponent("copy.sqlite").path
        do {
            var readOnly = Configuration()
            readOnly.readonly = true
            let source = try DatabaseQueue(path: databasePath, configuration: readOnly)
            let target = try DatabaseQueue(path: copyPath)
            try source.backup(to: target)
            try source.close()
            try target.close()
        }
        let libraryRoot = work.appendingPathComponent("Library", isDirectory: true)
        try fileManager.copyItem(at: URL(fileURLWithPath: libraryPath, isDirectory: true), to: libraryRoot)
        let manager = try DatabaseManager(path: copyPath)
        try manager.migrate()
        let queue = manager.dbQueue
        defer { try? queue.close() }
        let library = EvidenceLibrary(root: libraryRoot, database: queue)

        // Which documents go, which stay; each one's file exported and its state taken.
        let reimport = work.appendingPathComponent("Reimport", isDirectory: true)
        try fileManager.createDirectory(at: reimport, withIntermediateDirectories: true)
        let (documentCount, excluded, originals, before, cleared) = try await queue.read { db in
            let documents = try EvidenceDocument.order(Column("id")).fetchAll(db)
            let statementRuns = Set(try Int64.fetchAll(db, sql: """
                SELECT DISTINCT documentId FROM importRunFile WHERE outcome = ? AND documentId IS NOT NULL
                """, arguments: [ImportFileOutcome.transactions.rawValue]))
            var excluded: [Excluded] = []
            var originals: [Original] = []
            var usedNames: Set<String> = []
            for document in documents {
                guard let id = document.id else { continue }
                if document.kind == .bankStatement {
                    excluded.append(Excluded(name: document.displayName, kind: document.kind, reason: "kind is Bank statement"))
                    continue
                }
                if statementRuns.contains(id) {
                    excluded.append(Excluded(name: document.displayName, kind: document.kind,
                                             reason: "an import run filed it as a statement (its rows were imported)"))
                    continue
                }
                var links: [LinkKey: String?] = [:]
                for link in try EvidenceLinks.links(db: db, for: id) { links[LinkKey(type: link.entityType, id: link.entityId)] = link.role }
                var original = Original(id: id, sha256: document.sha256, name: document.displayName, kind: document.kind,
                                        docDate: document.docDate, amountMinorUnits: document.amountMinorUnits,
                                        currency: document.currency, links: links, exportedName: nil)
                let stored = library.fileURL(for: document)
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: stored.path) {
                    let name = uniqueName(document.originalFileName, used: &usedNames)
                    try fileManager.copyItem(at: stored, to: reimport.appendingPathComponent(name))
                    original.exportedName = name
                }
                originals.append(original)
            }
            let ids = originals.filter { $0.exportedName != nil }.map(\.id)
            let cleared = try clearedReferences(db: db, ids: ids)
            return (documents.count, excluded, originals, try TaxFigures.snapshot(db: db), cleared)
        }

        // The delete, as the Documents screen does it.
        for original in originals where original.exportedName != nil {
            try library.remove(original.id, force: true, guardingFiledYears: false)
        }
        let afterDelete = try await queue.read { db in try FiledYearGuard.filedChanges(db: db, from: before) }

        // The re-import: planned with no intent, only Ready items applied.
        let pipeline = ImportPipeline(dbQueue: queue, library: library,
                                      categorizationService: CategorizationService(categorizer: ImportDryRun.NoSuggestions()))
        defer { pipeline.discardPlanningCopy() }
        var plan = try await pipeline.plan([reimport])
        let planned = plan
        var applyNote: String
        var heldAtConfirm: [UUID: [String]] = [:]
        leaveOutNeedsYou(&plan)
        var attempt = 0
        while true {
            guard plan.canConfirm else {
                applyNote = "Nothing applied: no Ready item"
                break
            }
            do {
                let summary = try ImportApplier(dbQueue: queue, databasePath: nil, library: library)
                    .apply(plan, entryPoint: "Rehearsal", reasons: plan.resolutionReasons)
                applyNote = "Applied: " + summary.text + (attempt > 0 ? " (after \(attempt) refusal\(attempt == 1 ? "" : "s") by the filed-return backstop)" : "")
                break
            } catch ImportApplyError.filedYearChanged(let impacts) where attempt < 5 {
                // As the review does: every item checked again, the held ones left out.
                attempt += 1
                plan = try await pipeline.recheckFiledYears(plan)
                for item in plan.items(in: .needsYou) { heldAtConfirm[item.id] = item.needsYouReasons }
                if plan.items(in: .needsYou).isEmpty {
                    applyNote = "Nothing applied: the filed-return backstop refused the batch and no item was held ("
                        + impacts.map(\.headline).joined(separator: "; ") + ")"
                    break
                }
                leaveOutNeedsYou(&plan)
            } catch {
                applyNote = "Nothing applied: \(error)"
                break
            }
        }
        let applied = applyNote.hasPrefix("Applied") ? Set(ImportApplier.appliedItems(plan).map(\.id)) : []

        // After.
        let (filedChanges, after, back) = try await queue.read { db in
            let after = try TaxFigures.snapshot(db: db, years: Array(Set(before.values.keys.map(\.startYear))))
            var back: [String: (document: EvidenceDocument, links: [LinkKey: String?])] = [:]
            for original in originals {
                guard let document = try EvidenceDocument.filter(Column("sha256") == original.sha256).fetchOne(db), let id = document.id else { continue }
                var links: [LinkKey: String?] = [:]
                for link in try EvidenceLinks.links(db: db, for: id) { links[LinkKey(type: link.entityType, id: link.entityId)] = link.role }
                back[original.sha256] = (document, links)
            }
            return (try FiledYearGuard.filedChanges(db: db, from: before), after, back)
        }

        // Each original's outcome, by its file's item.
        let items = Dictionary(planned.items.filter { $0.parentId == nil }.map { ($0.file.sha256, $0) }, uniquingKeysWith: { first, _ in first })
        var outcomes: [Int64: Outcome] = [:]
        for original in originals {
            guard let name = original.exportedName else {
                outcomes[original.id] = .failed("its stored file is missing from the library: not exported, not deleted")
                continue
            }
            guard let item = items[original.sha256] else {
                outcomes[original.id] = .failed(planned.ignoredFiles.contains(name) ? "the importer ignored the file" : "no item in the plan")
                continue
            }
            if let held = heldAtConfirm[item.id] {
                outcomes[original.id] = .needsYou(held)
                continue
            }
            switch item.section {
            case .needsYou: outcomes[original.id] = .needsYou(item.needsYouReasons)
            case .duplicates: outcomes[original.id] = .duplicate(item.duplicate?.of ?? "a duplicate")
            case .leftOut: outcomes[original.id] = .failed("left out by the importer")
            case .ready:
                if !applied.contains(item.id) {
                    outcomes[original.id] = .failed("Ready, but not applied (\(applyNote))")
                } else if back[original.sha256] == nil {
                    outcomes[original.id] = .failed("Ready and applied, but not in the library afterwards")
                } else {
                    outcomes[original.id] = .cameBack
                }
            }
        }

        let labels = try await queue.read { db -> [LinkKey: String] in
            var keys = Set(originals.flatMap(\.links.keys))
            for entry in back.values { keys.formUnion(entry.links.keys) }
            var labels: [LinkKey: String] = [:]
            for key in keys { labels[key] = try label(db: db, key) }
            return labels
        }

        var report = Report(workFolder: work, deleted: originals.count, excluded: excluded, cameBack: 0, needsYou: 0, duplicates: 0,
                            failed: 0, filedChanges: filedChanges, text: "")
        for outcome in outcomes.values {
            switch outcome {
            case .cameBack: report.cameBack += 1
            case .needsYou: report.needsYou += 1
            case .duplicate: report.duplicates += 1
            case .failed: report.failed += 1
            }
        }
        report.text = text(report: report, databasePath: databasePath, libraryPath: libraryPath, documentCount: documentCount,
                           originals: originals, outcomes: outcomes, back: back, labels: labels, before: before, after: after,
                           afterDelete: afterDelete, cleared: cleared, applyNote: applyNote, keep: keep)
        return report
    }

    /// Every Needs-you item left out (its children follow it out: `ImportApplier.leftOutIds`).
    static func leaveOutNeedsYou(_ plan: inout ImportPlan) {
        for index in plan.items.indices where plan.items[index].section == .needsYou {
            plan.items[index].isLeftOut = true
        }
    }

    /// `name`, or `"name (2).ext"` … when taken (case-insensitively); a slash becomes a dash.
    static func uniqueName(_ original: String, used: inout Set<String>) -> String {
        let clean = original.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let base = clean.isEmpty || clean.hasPrefix(".") ? "document\(clean)" : clean
        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        var candidate = base
        var n = 2
        while used.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            n += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    /// What the delete's foreign keys clear (set to null), and the run records it leaves
    /// pointing at a deleted id (no foreign key), counted before it runs.
    static func clearedReferences(db: Database, ids: [Int64]) throws -> [(String, Int)] {
        guard !ids.isEmpty else { return [] }
        let list = ids.map(String.init).joined(separator: ",")
        func count(_ sql: String) throws -> Int { try Int.fetchOne(db, sql: sql) ?? 0 }
        return [
            ("Utility invoices losing their document", try count("SELECT COUNT(*) FROM utilityInvoice WHERE documentId IN (\(list))")),
            ("Recharge lines losing their document", try count("SELECT COUNT(*) FROM rechargeLine WHERE documentId IN (\(list))")),
            ("Source-folder file records losing their document",
             try count("SELECT COUNT(*) FROM sourceFile WHERE documentId IN (\(list)) OR previousDocumentId IN (\(list))")),
            ("Import-run file records left naming a deleted document id (no foreign key)",
             try count("SELECT COUNT(*) FROM importRunFile WHERE documentId IN (\(list))")),
            ("Document links removed (cascade)", try count("SELECT COUNT(*) FROM documentLink WHERE documentId IN (\(list))")),
        ]
    }

    /// A linked record's label: a transaction's description and day (no amount), else its title.
    static func label(db: Database, _ key: LinkKey) throws -> String {
        let entity = EvidenceEntity(type: key.type, id: key.id)
        if key.type == .transaction, let transaction = try Transaction.fetchOne(db, key: key.id) {
            return "Transaction \(transaction.rawDescription) on \(PropertyDates.isoDay(transaction.date))"
        }
        return "\(key.type.displayName): " + ((try entityTitle(db: db, entity)) ?? "#\(key.id) (gone)")
    }

    // MARK: The report

    static func text(report: Report, databasePath: String, libraryPath: String, documentCount: Int, originals: [Original],
                     outcomes: [Int64: Outcome], back: [String: (document: EvidenceDocument, links: [LinkKey: String?])],
                     labels: [LinkKey: String], before: TaxFigures.Snapshot, after: TaxFigures.Snapshot,
                     afterDelete: [FiledYearImpact], cleared: [(String, Int)], applyNote: String, keep: Bool) -> String {
        func day(_ date: Date?) -> String { date.map(PropertyDates.isoDay) ?? "no date" }
        func money(_ amount: Int?, _ currency: Currency?) -> String {
            amount.map { Money.format($0, currency: currency ?? .eur) } ?? "no amount"
        }
        func impacts(_ list: [FiledYearImpact]) -> String {
            if list.isEmpty { return "- none\n" }
            var out = ""
            for impact in list {
                out += "- \(impact.headline)\n"
                for line in impact.explanation { out += "  - \(line)\n" }
            }
            return out
        }
        let notDeleted = originals.filter { $0.exportedName == nil }.count

        var out = "# Import rehearsal\n\n"
        out += "On a copy only: the source database and library were only read. "
        out += "Database: `\(databasePath)`. Library: `\(libraryPath)`.\n"
        out += "Re-import: `ImportPipeline` (no intent, no on-device model, no category suggestions); Needs-you items left out; "
        out += "only Ready items applied by `ImportApplier`.\n"
        if keep { out += "Working copy kept at `\(report.workFolder.path)`.\n" }

        out += "\n## Counts\n\n"
        out += "- Documents in the library: \(documentCount); excluded as statements: \(report.excluded.count)\n"
        out += "- Documents deleted: \(report.deleted - notDeleted)"
        out += notDeleted > 0 ? " (\(notDeleted) more chosen but not deleted: stored file missing; counted as failed)\n" : "\n"
        out += "- Came back (Ready, applied): \(report.cameBack)\n"
        out += "- Needs you: \(report.needsYou)\n"
        var reasons: [String: Int] = [:]
        for case .needsYou(let list) in outcomes.values { reasons[list.first ?? "no reason given", default: 0] += 1 }
        for (reason, count) in reasons.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) { out += "  - \(count) × \(reason)\n" }
        out += "- Duplicates: \(report.duplicates)\n"
        out += "- Failed: \(report.failed)\n"
        out += "- \(applyNote)\n"
        if !cleared.isEmpty {
            out += "- What the delete cleared:\n"
            for (what, count) in cleared { out += "  - \(what): \(count)\n" }
        }

        out += "\n## Excluded (statements)\n\n"
        if report.excluded.isEmpty { out += "- none\n" }
        for item in report.excluded { out += "- \(item.name) (\(item.kind.displayName)): \(item.reason)\n" }

        out += "\n## Filed returns\n\n"
        out += "After the re-import, against before the delete (must be empty):\n\n"
        out += impacts(report.filedChanges)
        out += "\nAfter the delete alone (before the re-import), for reference:\n\n"
        out += impacts(afterDelete)

        out += "\n## Other tax-figure differences\n\n"
        func isFiled(_ key: TaxFigures.Key) -> Bool {
            guard let status = before.statuses[key.startYear]?[key.person] else { return false }
            return status == .filed || status == .paid
        }
        let others = TaxFigures.changes(from: before, to: after).filter { !isFiled($0.key) }
        if others.isEmpty { out += "- none\n" }
        let grouped = Dictionary(grouping: others) { "\(UKTaxYear(startYear: $0.key.startYear).label) · \($0.key.person)" }
        for group in grouped.keys.sorted() {
            out += "- \(group)\n"
            for change in grouped[group]!.sorted(by: { $0.key < $1.key }) {
                out += "  - \(change.key.field): \(change.before?.description ?? "—") → \(change.after?.description ?? "—")\n"
            }
        }

        out += "\n## Documents that came back\n\n"
        var identical: [String] = []
        var differing: [String] = []
        for original in originals {
            guard case .cameBack? = outcomes[original.id], let now = back[original.sha256] else { continue }
            var lines: [String] = []
            if now.document.kind != original.kind { lines.append("kind: \(original.kind.displayName) → \(now.document.kind.displayName)") }
            if now.document.docDate != original.docDate { lines.append("date: \(day(original.docDate)) → \(day(now.document.docDate))") }
            if now.document.amountMinorUnits != original.amountMinorUnits || now.document.currency != original.currency {
                lines.append("amount: \(money(original.amountMinorUnits, original.currency)) → \(money(now.document.amountMinorUnits, now.document.currency))")
            }
            let missing = original.links.keys.filter { now.links[$0] == nil }.sorted()
            let extra = now.links.keys.filter { original.links[$0] == nil }.sorted()
            let roles = original.links.keys.filter { key in now.links[key].map { $0 != (original.links[key] ?? nil) } ?? false }.sorted()
            if !missing.isEmpty { lines.append("links missing: " + missing.map { labels[$0] ?? "?" }.joined(separator: "; ")) }
            if !extra.isEmpty { lines.append("links extra: " + extra.map { labels[$0] ?? "?" }.joined(separator: "; ")) }
            for key in roles {
                lines.append("link role changed: \(labels[key] ?? "?"): \((original.links[key] ?? nil) ?? "none") → \((now.links[key] ?? nil) ?? "none")")
            }
            if lines.isEmpty {
                identical.append(original.name)
            } else {
                differing.append("- \(original.name) (\(original.kind.displayName))\n" + lines.map { "  - \($0)\n" }.joined())
            }
        }
        out += "\(identical.count) the same (kind, date, amount and links); \(differing.count) different.\n\n"
        if !differing.isEmpty { out += "### Different\n\n" + differing.joined() + "\n" }
        if !identical.isEmpty { out += "### The same\n\n" + identical.map { "- \($0)\n" }.joined() }

        out += "\n## Documents that didn't come back\n\n"
        var none = true
        for original in originals {
            let why: String
            switch outcomes[original.id] {
            case .cameBack?: continue
            case .needsYou(let list)?: why = "Needs you: " + list.joined(separator: "; ")
            case .duplicate(let of)?: why = "Duplicate: \(of)"
            case .failed(let reason)?: why = "Failed: \(reason)"
            case nil: why = "Failed: no outcome"
            }
            none = false
            out += "- \(original.name) (\(original.kind.displayName), \(day(original.docDate)), \(original.links.count) link\(original.links.count == 1 ? "" : "s")): \(why)\n"
        }
        if none { out += "- none\n" }
        return out
    }
}
