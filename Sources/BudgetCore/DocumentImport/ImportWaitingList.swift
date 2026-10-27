import CryptoKit
import Foundation
import GRDB

/// A file kept for later (spec 2026-10-24 §1): Mango's own copy under the waiting folder
/// (`<sha256>/<original name>`), why it was set aside and what it was recognised as. Synced to the
/// household with its copy (the copy travels as a sealed file record, step "waiting files sync");
/// the text read, its status, the re-read signature and the suggestion stay on each device.
public struct ImportWaitingFile: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    /// Unique: one waiting row per file content.
    public var sha256: String
    public var originalFileName: String
    public var byteCount: Int64
    /// `"<sha256>/<originalFileName>"` under the waiting folder.
    public var storedRelativePath: String
    /// Local to this device: the text read (nil on a device that hasn't read the copy yet).
    public var text: String?
    /// Local to this device: `.unknown` until this device has read the copy.
    public var textStatus: DocumentTextStatus
    /// Why it was set aside ("Left out by you", "Not recognised", "Possibly a duplicate of …").
    public var reason: String
    /// What the review recognised it as, by name.
    public var recognisedAs: String
    /// Local to this device: "Now recognised as <kind>" when a re-read recognises it otherwise.
    public var suggestion: String?
    /// Local to this device: the recognisers' signature it was last read with (`ImportWaitingList.signature`).
    public var checkedSignature: String
    public var keptAt: Date
    /// The run that imported it (it leaves the list while that run stands).
    public var importedRunId: Int64?
    /// The app user who kept it (synced): a kept file is never shared, it lives in that person's private zone
    /// (`SyncZoneRouter` rule 10). Nil when no one was signed in.
    public var keptByAppUserId: Int64?

    public init(id: Int64? = nil, sha256: String, originalFileName: String, byteCount: Int64, storedRelativePath: String,
                text: String?, textStatus: DocumentTextStatus, reason: String, recognisedAs: String, suggestion: String? = nil,
                checkedSignature: String = "", keptAt: Date, importedRunId: Int64? = nil, keptByAppUserId: Int64? = nil) {
        self.id = id
        self.sha256 = sha256
        self.originalFileName = originalFileName
        self.byteCount = byteCount
        self.storedRelativePath = storedRelativePath
        self.text = text
        self.textStatus = textStatus
        self.reason = reason
        self.recognisedAs = recognisedAs
        self.suggestion = suggestion
        self.checkedSignature = checkedSignature
        self.keptAt = EvidenceLinks.wholeSeconds(keptAt)
        self.importedRunId = importedRunId
        self.keptByAppUserId = keptByAppUserId
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public static let databaseTableName = "importWaitingFile"
}

/// A file that couldn't be kept or copied, with why.
public struct ImportSetAsideFailure: Equatable, Sendable {
    public var fileName: String
    public var reason: String
    /// The file's hash (lowercase), which tells apart two files of one name; empty when not known.
    public var sha256: String

    public init(fileName: String, reason: String, sha256: String = "") {
        self.fileName = fileName
        self.reason = reason
        self.sha256 = sha256.lowercased()
    }
}

/// The waiting list (spec 2026-10-24 §1): keeping files for later in Mango's own copy, listing them,
/// re-reading them when the recognisers change, marking them imported, purging them 30 days after
/// a standing run. Keeping and discarding are ordinary edits (no import lease); the user's
/// originals are only ever read.
public struct ImportWaitingList: Sendable {
    /// `Application Support/Budget/Waiting`, beside the library.
    public static var defaultRoot: URL {
        EvidenceLibrary.defaultRoot.deletingLastPathComponent().appendingPathComponent("Waiting", isDirectory: true)
    }

    public let root: URL
    public let database: any DatabaseWriter
    /// Tests only: runs between a keep's copy and its row (where a pull's `removeCopies` can land).
    var afterPlacingForTesting: (@Sendable (String) -> Void)?

    public init(root: URL = ImportWaitingList.defaultRoot, database: any DatabaseWriter) {
        self.root = root
        self.database = database
    }

    public struct KeepResult: Equatable, Sendable {
        /// The rows added (or listed again).
        public var kept: [ImportWaitingFile] = []
        /// Files already waiting, by name.
        public var alreadyWaiting: [String] = []
        public var failed: [ImportSetAsideFailure] = []
    }

    /// Where the row's copy is: `<root>/<sha256>/<originalFileName>`, derived from the hash and the
    /// name, never taken from the stored path (rows arrive by sync). Nil — no copy here — when the hash
    /// isn't 64 lowercase hex digits, the name isn't one plain path component, or the stored path says
    /// anything else.
    public func fileURL(_ file: ImportWaitingFile) -> URL? {
        guard let path = Self.storedPath(sha256: file.sha256, name: file.originalFileName), path == file.storedRelativePath else { return nil }
        return root.appendingPathComponent(file.sha256, isDirectory: true).appendingPathComponent(file.originalFileName)
    }

    /// The waiting row as a file to set aside again (Copy to a folder…): Mango's copy (nil: see `fileURL`).
    public func setAsideFile(_ file: ImportWaitingFile) -> SetAsideFile? {
        guard let url = fileURL(file) else { return nil }
        return SetAsideFile(url: url, fileName: file.originalFileName, sha256: file.sha256, byteCount: file.byteCount, text: file.text,
                            textStatus: file.textStatus, reason: file.reason, recognisedAs: file.recognisedAs)
    }

    // MARK: Keep

    /// Copies each file into the waiting folder (to a temporary name, checked against its hash, then
    /// moved into place) and only then adds its row: a file that can't be copied (moved or deleted
    /// after it was read, changed since) fails alone and leaves neither row nor copy. A file already
    /// waiting is `alreadyWaiting`; one imported by a run is listed again.
    public func keep(_ files: [SetAsideFile], now: Date) throws -> KeepResult {
        var result = KeepResult()
        var seen: Set<String> = []
        for file in files {
            guard seen.insert(file.sha256.lowercased()).inserted else { continue }
            guard case .placed(let sha, let path, let placed) = try prepare(file, result: &result) else { continue }
            let row: ImportWaitingFile
            do {
                row = try database.write { db in try Self.writeRow(db: db, file, sha256: sha, path: path, now: now) }
            } catch {
                undo(placed, sha256: sha, path: path)
                throw error
            }
            result.kept.append(row)
            finish(file, sha256: sha, path: path, result: &result)
        }
        return result
    }

    /// `keep` for one file whose row is written by `write` (the iPad's `DeviceWriter`, which checks the actor may
    /// edit Import): the copy is placed first, removed again when `write` throws.
    public func keep(_ file: SetAsideFile, now: Date,
                     writing write: (@escaping @Sendable (Database) throws -> ImportWaitingFile) async throws -> ImportWaitingFile) async throws -> KeepResult {
        var result = KeepResult()
        guard case .placed(let sha, let path, let placed) = try prepare(file, result: &result) else { return result }
        let row: ImportWaitingFile
        do {
            row = try await write { db in try Self.writeRow(db: db, file, sha256: sha, path: path, now: now) }
        } catch {
            undo(placed, sha256: sha, path: path)
            throw error
        }
        result.kept.append(row)
        finish(file, sha256: sha, path: path, result: &result)
        return result
    }

    /// What a keep does before its row: nothing (already waiting, or it failed: said in `result`), or its copy placed.
    private enum Prepared { case skipped, placed(sha: String, path: String, Placed) }

    private func prepare(_ file: SetAsideFile, result: inout KeepResult) throws -> Prepared {
        let sha = file.sha256.lowercased()
        let existing = try database.read { db in try Self.row(db: db, sha256: sha) }
        if let existing, try database.read({ db in try Self.isListed(db: db, existing) }) {
            result.alreadyWaiting.append(file.fileName)
            return .skipped
        }
        guard let path = Self.storedPath(sha256: sha, name: file.fileName) else {
            result.failed.append(ImportSetAsideFailure(fileName: file.fileName, reason: "Its name can't be used for Mango's copy", sha256: sha))
            return .skipped
        }
        let placed: Placed
        do {
            placed = try place(file, sha256: sha, path: path)
        } catch {
            result.failed.append(ImportSetAsideFailure(fileName: file.fileName, reason: Self.copyFailure(file, error), sha256: sha))
            return .skipped
        }
        afterPlacingForTesting?(sha)
        return .placed(sha: sha, path: path, placed)
    }

    /// The waiting row for `file`, in the caller's write: a row imported by a run that stands, set aside again, is listed again.
    static func writeRow(db: Database, _ file: SetAsideFile, sha256 sha: String, path: String, now: Date) throws -> ImportWaitingFile {
        if var row = try Self.row(db: db, sha256: sha) {
            // Imported by a run that stands, set aside again: listed again.
            row.originalFileName = file.fileName
            row.storedRelativePath = path
            row.reason = file.reason
            row.recognisedAs = file.recognisedAs
            row.keptAt = EvidenceLinks.wholeSeconds(now)
            row.importedRunId = nil
            row.keptByAppUserId = try Self.signedInAppUserId(db: db)
            if row.text == nil { row.text = file.text; row.textStatus = file.textStatus }
            try row.update(db)
            return row
        }
        var row = ImportWaitingFile(sha256: sha, originalFileName: file.fileName, byteCount: file.byteCount, storedRelativePath: path,
                                    text: file.text, textStatus: file.textStatus, reason: file.reason, recognisedAs: file.recognisedAs,
                                    keptAt: now, keptByAppUserId: try Self.signedInAppUserId(db: db))
        try row.insert(db)
        return row
    }

    /// No row: the copy placed for it goes too.
    private func undo(_ placed: Placed, sha256 sha: String, path: String) {
        switch placed {
        case .folder: try? FileManager.default.removeItem(at: root.appendingPathComponent(sha, isDirectory: true))
        case .file: try? FileManager.default.removeItem(at: root.appendingPathComponent(path))
        case .alreadyThere: break
        }
    }

    private func finish(_ file: SetAsideFile, sha256 sha: String, path: String, result: inout KeepResult) {
        // A pull that deleted this hash's row (dismissed on another device) between the copy and the row
        // removed the copy with it (`removeCopies` saw no row): placed again. From here on the row protects it.
        if !Self.isRegularFile(root.appendingPathComponent(path)) {
            do {
                _ = try place(file, sha256: sha, path: path)
            } catch {
                result.failed.append(ImportSetAsideFailure(fileName: file.fileName, reason: Self.copyFailure(file, error), sha256: sha))
            }
        }
        // Kept again under another name: the copy under the old name goes.
        Self.removeOtherFiles(in: root.appendingPathComponent(sha, isDirectory: true), keeping: file.fileName)
    }

    /// What `place` put there, to remove again if the row can't be written.
    private enum Placed { case alreadyThere, file, folder }

    /// Copies `file` (a symlink's target, never the link) to `path` under the root; a copy already
    /// there with the right content is kept.
    private func place(_ file: SetAsideFile, sha256 sha: String, path: String) throws -> Placed {
        let manager = FileManager.default
        let destination = root.appendingPathComponent(path)
        let folder = destination.deletingLastPathComponent()
        guard Self.isOwnFolder(folder, root: root) else { throw KeepFailure.linkedFolder }
        if Self.isRegularFile(destination), (try? EvidenceLibrary.sha256(of: destination)) == sha { return .alreadyThere }
        let created = !manager.fileExists(atPath: folder.path)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".\(UUID().uuidString).partial")
        do {
            try manager.copyItem(at: file.url.resolvingSymlinksInPath(), to: temporary)
            guard try EvidenceLibrary.sha256(of: temporary) == sha else { throw KeepFailure.changed }
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.moveItem(at: temporary, to: destination)
        } catch {
            try? manager.removeItem(at: temporary)
            if created { try? manager.removeItem(at: folder) }
            throw error
        }
        return created ? .folder : .file
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular
    }

    /// Removes every file of a copy folder but `name` (and other keeps' partial copies, hidden). Also
    /// after a sync download places a copy kept again elsewhere under another name.
    static func removeOtherFiles(in folder: URL, keeping name: String) {
        // Never through a symbolic link (or anything but a real folder): its target's files aren't Mango's.
        guard (try? FileManager.default.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType) == .typeDirectory else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for other in names where other != name && !other.hasPrefix(".") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(other))
        }
    }

    private enum KeepFailure: Error { case changed, linkedFolder }

    private static func copyFailure(_ file: SetAsideFile, _ error: Error) -> String {
        if case KeepFailure.changed = error { return "It changed since it was read: import it again" }
        if case KeepFailure.linkedFolder = error { return "Mango's folder for it is a link to somewhere else: not copied" }
        if !FileManager.default.fileExists(atPath: file.url.path) { return "It is no longer where it was read: it was moved or deleted" }
        return "Couldn't copy it: \(error.localizedDescription)"
    }

    /// Whether `folder` (a hash folder under `root`) is Mango's own: absent (to be created), or a real folder,
    /// not a symbolic link, that resolves inside `root`.
    /// The app user signed in on this connection (`syncWriter`), by local id; nil when no one is.
    static func signedInAppUserId(db: Database) throws -> Int64? {
        guard try db.tableExists("syncWriter") else { return nil }
        return try Int64.fetchOne(db, sql: """
            SELECT s.localId FROM syncWriter w JOIN syncRecord s ON s.tableName = 'appUser' AND s.uuid = w.appUserUuid
            WHERE w.id = 1
            """)
    }

    static func isOwnFolder(_ folder: URL, root: URL) -> Bool {
        let manager = FileManager.default
        if let type = (try? manager.attributesOfItem(atPath: folder.path))?[.type] as? FileAttributeType, type != .typeDirectory { return false }
        let resolvedRoot = resolvedPath(root)
        let resolved = resolvedPath(folder)
        return resolved.hasPrefix(resolvedRoot + "/")
    }

    /// The path with its symbolic links resolved, also when its last components don't exist yet:
    /// the deepest existing ancestor is resolved and the rest appended. (`resolvingSymlinksInPath`
    /// leaves a missing path as it is — `/private/tmp/x` for `/tmp/x` — so a folder not made yet
    /// would never sit under an existing root beneath `/tmp` or `/var`.)
    private static func resolvedPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in rest { resolved.appendPathComponent(component) }
        return resolved.path
    }

    /// `"<sha256>/<name>"`, or nil when the name isn't one plain path component.
    static func storedPath(sha256: String, name: String) -> String? {
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."), !name.contains("/"), !name.contains("\0"),
              name.utf8.count <= 255,
              sha256.count == 64, sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return "\(sha256)/\(name)"
    }

    // MARK: List

    /// The files waiting: not imported, or imported by a run since undone, and not in the library (its
    /// bytes reached it another way); newest first.
    public func waiting() throws -> [ImportWaitingFile] {
        try database.read { db in try Self.waiting(db: db) }
    }

    static func waiting(db: Database) throws -> [ImportWaitingFile] {
        try ImportWaitingFile.fetchAll(db, sql: """
            SELECT w.* FROM importWaitingFile w LEFT JOIN importRun r ON r.id = w.importedRunId
            WHERE (w.importedRunId IS NULL OR r.id IS NULL OR r.undoneAt IS NOT NULL)
              AND NOT EXISTS (SELECT 1 FROM document d WHERE d.sha256 = w.sha256)
            ORDER BY w.keptAt DESC, w.id DESC
            """)
    }

    private static func row(db: Database, sha256: String) throws -> ImportWaitingFile? {
        try ImportWaitingFile.filter(Column("sha256") == sha256).fetchOne(db)
    }

    private static func isListed(db: Database, _ row: ImportWaitingFile) throws -> Bool {
        try waiting(db: db).contains { $0.id == row.id }
    }

    // MARK: Discard

    /// Removes the rows and Mango's copies (never the user's originals).
    public func discard(_ ids: [Int64]) throws {
        let removed = try database.write { db -> [ImportWaitingFile] in
            let rows = try ImportWaitingFile.filter(keys: ids).fetchAll(db)
            _ = try ImportWaitingFile.deleteAll(db, keys: ids)
            return rows
        }
        removeCopies(removed)
    }

    /// Removes the copy folders of rows deleted: only a folder named by a well-formed hash (rows can
    /// arrive by sync), and never one whose hash has a row again (kept meanwhile).
    func removeCopies(_ rows: [ImportWaitingFile]) {
        removeCopies(sha256s: rows.map(\.sha256))
    }

    /// `removeCopies` by hash: also for rows a sync deleted here (`SyncEngineCore`).
    func removeCopies(sha256s: [String]) {
        for sha in Set(sha256s) where Self.storedPath(sha256: sha, name: "x") != nil {
            let keptAgain = (try? database.read { db in try ImportWaitingFile.filter(Column("sha256") == sha).fetchCount(db) > 0 }) ?? true
            guard !keptAgain else { continue }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(sha, isDirectory: true))
        }
    }

    // MARK: Suggested again

    /// What the recognisers are: the classifier's rules version, the custom kinds (`id:name:area`, by
    /// id) and the enabled `documentKind`/`issuer` learnt rules (`id:matchKey:actionJSON`, by id),
    /// hashed. A waiting file is read again whenever it differs from the one it was read with.
    public static func signature(db: Database) throws -> String {
        var lines = ["rules:\(DocumentClassifier.rulesVersion)"]
        for kind in try CustomDocumentKind.order(Column("id")).fetchAll(db) {
            lines.append("kind:\(kind.id ?? 0):\(kind.name):\(kind.area.rawValue)")
        }
        let rules = try ImportRule
            .filter(Column("isEnabled") == true)
            .filter([ImportRuleKind.documentKind, .issuer].map(\.rawValue).contains(Column("kind")))
            .order(Column("id"))
            .fetchAll(db)
        for rule in rules {
            lines.append("rule:\(rule.id ?? 0):\(rule.matchKey):\(rule.actionJSON)")
        }
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Reads again the waiting files last read with another signature: each as an `ImportFile` of its
    /// copy with its stored text — or, when this device has none yet (a row that arrived by sync), the
    /// copy read now (`ImportFile.load`) and its text stored; a row whose copy hasn't arrived waits.
    /// A recognition other than Unknown or Other named otherwise than `recognisedAs` suggests it
    /// ("Now recognised as <name>"); any other clears the suggestion. The signature is stored either
    /// way. Returns the rows newly suggested. `kindName`: a kind's name (a custom kind's from the catalog).
    @discardableResult
    public func recheck(recognise: (ImportFile) -> ImportRecognition, kindName: (ImportKind) -> String = { $0.displayName },
                        signature: String) throws -> [Int64] {
        let stale = try waiting().filter { $0.checkedSignature != signature }
        var updated: [ImportWaitingFile] = []
        var suggested: [Int64] = []
        for var row in stale {
            guard let id = row.id else { continue }
            // A row whose stored path isn't its own has no copy here: never read.
            guard let url = fileURL(row) else { continue }
            if row.textStatus == .unknown {
                guard FileManager.default.fileExists(atPath: url.path), let read = try? ImportFile.load(url) else { continue }
                row.text = read.text
                row.textStatus = read.textStatus
            }
            let file = ImportFile(url: url, fileName: row.originalFileName, sha256: row.sha256, byteCount: row.byteCount,
                                  fileExtension: (row.originalFileName as NSString).pathExtension.lowercased(), text: row.text,
                                  textStatus: row.textStatus, usedOCR: false)
            let recognition = recognise(file)
            let name = kindName(recognition.kind)
            let suggestion: String?
            switch recognition.kind {
            case .unknown, .evidence(.other): suggestion = nil
            default: suggestion = name == row.recognisedAs ? nil : "Now recognised as \(name)"
            }
            if let suggestion, suggestion != row.suggestion { suggested.append(id) }
            row.suggestion = suggestion
            row.checkedSignature = signature
            updated.append(row)
        }
        guard !updated.isEmpty else { return [] }
        try database.write { db in
            for row in updated {
                // Only the device's own columns: a row changed or discarded meanwhile keeps the rest.
                guard let id = row.id else { continue }
                try db.execute(sql: """
                    UPDATE importWaitingFile SET text = ?, textStatus = ?, suggestion = ?, checkedSignature = ? WHERE id = ?
                    """, arguments: [row.text, row.textStatus.rawValue, row.suggestion, row.checkedSignature, id])
            }
        }
        return suggested
    }

    // MARK: Imported, purged

    /// Inside Confirm import's transaction: the waiting files whose content the run filed, linked or
    /// recorded are marked imported by it (they leave the list while it stands).
    public static func markImported(db: Database, runId: Int64, sha256s: Set<String>) throws {
        guard !sha256s.isEmpty else { return }
        try ImportWaitingFile
            .filter(sha256s.map { $0.lowercased() }.contains(Column("sha256")))
            .updateAll(db, Column("importedRunId").set(to: runId))
    }

    /// The hashes of the files waiting now.
    static func waitingHashes(db: Database) throws -> Set<String> {
        Set(try waiting(db: db).map(\.sha256))
    }

    /// Removes the rows (and copies) imported by a run that still stands and was confirmed at least
    /// `olderThanDays` days before `now`, and those whose bytes reached the library that long ago
    /// another way. Returns how many went.
    @discardableResult
    public func purgeImported(now: Date, olderThanDays: Int = 30) throws -> Int {
        let cutoff = now.addingTimeInterval(-Double(olderThanDays) * 86_400)
        let removed = try database.write { db -> [ImportWaitingFile] in
            let rows = try ImportWaitingFile.fetchAll(db, sql: """
                SELECT w.* FROM importWaitingFile w JOIN importRun r ON r.id = w.importedRunId
                WHERE r.undoneAt IS NULL AND r.confirmedAt <= ?
                UNION
                SELECT w.* FROM importWaitingFile w
                WHERE EXISTS (SELECT 1 FROM document d WHERE d.sha256 = w.sha256 AND d.addedAt <= ?)
                """, arguments: [cutoff, cutoff])
            _ = try ImportWaitingFile.deleteAll(db, keys: rows.compactMap(\.id))
            return rows
        }
        removeCopies(removed)
        return removed.count
    }
}

func registerImportWaitingFileMigration(_ migrator: inout DatabaseMigrator) {
    // Only adds a table.
    migrator.registerMigration("createImportWaitingFile") { db in
        try db.create(table: "importWaitingFile") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("sha256", .text).notNull().unique()
            t.column("originalFileName", .text).notNull()
            t.column("byteCount", .integer).notNull()
            t.column("storedRelativePath", .text).notNull()
            // Local to each device: a row arriving by sync takes these defaults.
            t.column("text", .text)
            t.column("textStatus", .text).notNull().defaults(to: DocumentTextStatus.unknown.rawValue)
            t.column("reason", .text).notNull()
            t.column("recognisedAs", .text).notNull()
            t.column("suggestion", .text)
            t.column("checkedSignature", .text).notNull().defaults(to: "")
            t.column("keptAt", .datetime).notNull()
            t.column("importedRunId", .integer).references("importRun", onDelete: .setNull)
        }
        try db.create(index: "importWaitingFile_importedRunId", on: "importWaitingFile", columns: ["importedRunId"])
    }
}
