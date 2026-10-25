import Foundation
import GRDB
import BudgetCore
import BudgetDemo

/// Databases for tests, copied from templates built once per test build (see `Templates`) instead of migrated (about 110 ms)
/// or filled with the demo (about 1.4 s) for every test. A copy (SQLite's backup API, under 1 ms) holds
/// everything the database file holds: tables, rows, indexes, the sync triggers, `sqlite_sequence`.
/// Each call returns an independent database opened by `DatabaseManager`, so with the same
/// connection settings as before (foreign keys, `recursive_triggers`); the templates are never handed out.
///
/// Tests about migrating itself (migration tests, the sync schema checks, the change tracker's pins)
/// still migrate a fresh `DatabaseManager`.
public enum TestDatabase {
    /// A migrated, empty database: in memory when `path` is nil, else written to `path` (which must not
    /// hold a database yet), for tests that reopen the file or open a second connection to it.
    public static func migratedManager(path: String? = nil) throws -> DatabaseManager {
        try refuseExisting(path)
        let manager = try DatabaseManager(path: path)
        try Templates.shared.migrated().backup(to: manager.dbQueue)
        return manager
    }

    /// The queue of `migratedManager()`.
    public static func migrated() throws -> DatabaseQueue {
        try migratedManager().dbQueue
    }

    /// A database holding the demo (`DemoDatabase.build` as of `DemoDatabase.defaultAsOf`), its evidence
    /// files copied to `evidenceRoot` and its set-aside file to `Waiting` beside it, as a fresh build
    /// would leave them. Without `evidenceRoot`, the database only.
    public static func demoManager(path: String? = nil, evidenceRoot: URL? = nil) throws -> DatabaseManager {
        try refuseExisting(path)
        let manager = try DatabaseManager(path: path)
        try fillDemo(manager.dbQueue, evidenceRoot: evidenceRoot)
        return manager
    }

    /// The queue of `demoManager()`, without evidence files.
    public static func demo() throws -> DatabaseQueue {
        try demoManager().dbQueue
    }

    /// In place of `DemoDatabase.build(dbQueue:evidenceRoot:)` on a just-migrated, empty `dbQueue`: replaces
    /// its contents with a copy of the demo template and copies the template's files as `demoManager` does.
    /// Refuses a database that already holds accounts or transactions, as the build does.
    public static func fillDemo(_ dbQueue: DatabaseQueue, evidenceRoot: URL?) throws {
        if try dbQueue.read({ db in try db.tableExists("account") }) {
            let holdsData = try dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT (SELECT COUNT(*) FROM account) + (SELECT COUNT(*) FROM transaction_)") ?? 0
            }
            guard holdsData == 0 else { throw DemoDatabase.DemoError.notEmpty }
        }
        let template = try Templates.shared.demo()
        try template.queue.backup(to: dbQueue)
        if let evidenceRoot {
            try copyContents(of: template.evidence, into: evidenceRoot)
            try copyContents(of: template.waiting, into: evidenceRoot.deletingLastPathComponent().appendingPathComponent("Waiting", isDirectory: true))
        }
    }

    public enum TestDatabaseError: Error {
        /// A copy is only ever written to a new file; reopening a file is the caller's `DatabaseManager(path:)`.
        case fileExists(String)
    }

    private static func refuseExisting(_ path: String?) throws {
        if let path, FileManager.default.fileExists(atPath: path) { throw TestDatabaseError.fileExists(path) }
    }

    /// Copies every item of `source` into `destination` (created when missing). Items are named by content
    /// (`<sha256>…`), so one already there is the same and is kept: `Waiting` beside an evidence folder in the
    /// temporary directory is shared by concurrent tests, as it was with a fresh build.
    private static func copyContents(of source: URL, into destination: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        guard files.fileExists(atPath: source.path) else { return }
        for name in try files.contentsOfDirectory(atPath: source.path) {
            let target = destination.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            if files.fileExists(atPath: target.path, isDirectory: &isFolder) {
                if isFolder.boolValue { try copyContents(of: source.appendingPathComponent(name), into: target) }
                continue
            }
            do {
                try files.copyItem(at: source.appendingPathComponent(name), to: target)
            } catch {
                if !files.fileExists(atPath: target.path) { throw error }
            }
        }
    }
}

/// The templates. `swift test --parallel` runs every test in a process of its own, so a template kept only
/// in memory would be rebuilt for every test: each is built once per test binary into a folder under the
/// temporary directory (keyed by the binary's path, size and modification time, so any rebuild starts afresh),
/// under a file lock so concurrent processes build it once, then read into memory once per process. The
/// files there are only ever read or copied from, never opened for writing by a test.
private final class Templates: @unchecked Sendable {
    static let shared = Templates()

    struct Demo {
        let queue: DatabaseQueue
        let evidence: URL
        let waiting: URL
    }

    private let lock = NSLock()
    private var migratedQueue: DatabaseQueue?
    private var demoTemplate: Demo?
    private let cache: URL

    private init() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("MangoTestTemplates", isDirectory: true)
        cache = base.appendingPathComponent(Templates.binaryKey(), isDirectory: true)
        // Held (shared) for the life of the process: another run's clean-up never removes a folder in use.
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let inUse = open(cache.appendingPathComponent(Templates.inUseLockName).path, O_CREAT | O_RDWR, 0o644)
        if inUse >= 0 { _ = flock(inUse, LOCK_SH) }
        Templates.removeStale(in: base, keeping: cache)
    }

    private static let inUseLockName = "in-use.lock"

    func migrated() throws -> DatabaseQueue {
        lock.lock()
        defer { lock.unlock() }
        return try migratedLocked()
    }

    func demo() throws -> Demo {
        lock.lock()
        defer { lock.unlock() }
        if let demoTemplate { return demoTemplate }
        let migrated = try migratedLocked()
        let folder = try built("demo") { staging in
            let manager = try DatabaseManager(path: staging.appendingPathComponent("db.sqlite").path)
            try migrated.backup(to: manager.dbQueue)
            // The set-aside letter goes to `Waiting` beside `Evidence`, as in any build.
            try DemoDatabase.build(dbQueue: manager.dbQueue, evidenceRoot: staging.appendingPathComponent("Evidence", isDirectory: true))
            try manager.dbQueue.close()
        }
        let demo = Demo(queue: try load(folder), evidence: folder.appendingPathComponent("Evidence", isDirectory: true),
                        waiting: folder.appendingPathComponent("Waiting", isDirectory: true))
        demoTemplate = demo
        return demo
    }

    private func migratedLocked() throws -> DatabaseQueue {
        if let migratedQueue { return migratedQueue }
        let folder = try built("migrated") { staging in
            let manager = try DatabaseManager(path: staging.appendingPathComponent("db.sqlite").path)
            try manager.migrate()
            // Synthetic data only: marked as the demo's, so sync treats it as one (an unmarked database is real data).
            try manager.dbQueue.write { db in try DemoMarker.mark(db) }
            try manager.dbQueue.close()
        }
        let queue = try load(folder)
        migratedQueue = queue
        return queue
    }

    /// The folder's `db.sqlite`, read into an in-memory database this process copies from.
    private func load(_ folder: URL) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.readonly = true
        let file = try DatabaseQueue(path: folder.appendingPathComponent("db.sqlite").path, configuration: configuration)
        let memory = try DatabaseQueue()
        try file.backup(to: memory)
        try file.close()
        return memory
    }

    /// `cache/name`, made by `build` (into a staging folder, then renamed) unless another process already made it.
    private func built(_ name: String, build: (URL) throws -> Void) throws -> URL {
        let files = FileManager.default
        let folder = cache.appendingPathComponent(name, isDirectory: true)
        let complete = folder.appendingPathComponent(".complete")
        if files.fileExists(atPath: complete.path) { return folder }
        try files.createDirectory(at: cache, withIntermediateDirectories: true)
        let descriptor = open(cache.appendingPathComponent("\(name).lock").path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileLocking) }
        defer { flock(descriptor, LOCK_UN) }
        if files.fileExists(atPath: complete.path) { return folder }
        // Staging folders left by a process that died mid-build (none can be live while this lock is held).
        for item in (try? files.contentsOfDirectory(atPath: cache.path)) ?? [] where item.hasPrefix("\(name)-staging-") {
            try? files.removeItem(at: cache.appendingPathComponent(item, isDirectory: true))
        }
        let staging = cache.appendingPathComponent("\(name)-staging-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try build(staging)
            try Data().write(to: staging.appendingPathComponent(".complete"))
            if files.fileExists(atPath: folder.path) { try files.removeItem(at: folder) }
            try files.moveItem(at: staging, to: folder)
        } catch {
            try? files.removeItem(at: staging)
            throw error
        }
        return folder
    }

    /// The test binary this code is linked into: its path, size and modification time, hashed.
    private static func binaryKey() -> String {
        var info = Dl_info()
        var text = "unknown-\(ProcessInfo.processInfo.processIdentifier)"
        if dladdr(#dsohandle, &info) != 0, let name = info.dli_fname {
            let path = String(cString: name)
            var status = stat()
            if stat(path, &status) == 0 {
                text = "\(path)|\(status.st_size)|\(status.st_mtimespec.tv_sec).\(status.st_mtimespec.tv_nsec)|\(status.st_ino)"
            }
        }
        // Today's UTC date too: templates are rebuilt daily, so nothing built from the clock goes stale.
        let utc = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: Date())
        text += "|\(utc.year!)-\(utc.month!)-\(utc.day!)"
        // FNV-1a: stable across processes (Swift's `Hasher` is seeded per process).
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }

    /// Template folders of earlier builds or days, left a day ago or more. A folder whose in-use lock another
    /// process holds is skipped: it is removed only while this process holds that lock exclusively.
    private static func removeStale(in base: URL, keeping current: URL) {
        let files = FileManager.default
        guard let items = try? files.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let dayAgo = Date().addingTimeInterval(-86_400)
        for item in items where item.lastPathComponent != current.lastPathComponent {
            guard let modified = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < dayAgo else { continue }
            let lock = open(item.appendingPathComponent(inUseLockName).path, O_CREAT | O_RDWR, 0o644)
            guard lock >= 0 else { continue }
            defer { close(lock) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { continue }  // in use
            try? files.removeItem(at: item)
        }
    }
}
