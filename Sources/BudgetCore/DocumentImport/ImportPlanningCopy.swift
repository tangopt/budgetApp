import Foundation
import GRDB

/// A private copy of the app's database that the importer plans against (`ImportPipeline`):
/// the readers, the duplicate pass and the filed-year guard read and simulate on it, so the
/// app's own queue is never held while a plan is worked out. Taken with `backup(to:)` into a
/// temporary file, which is deleted when the copy is released. Nothing ever keeps a write on
/// it (every pass rolls back), so what is read from it once — the library's identity index —
/// holds for its lifetime.
final class ImportPlanningCopy: @unchecked Sendable {
    // @unchecked: `index` is guarded by `lock`; the queue is GRDB's (serialised).
    let dbQueue: DatabaseQueue
    let path: String
    private let lock = NSLock()
    private var index: DocumentIdentityIndex?

    /// The folder holding the copies (in the process's temporary directory).
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("BudgetImportPlanning", isDirectory: true)
    }

    init(of source: DatabaseQueue) throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        Self.removeStale()
        let path = Self.folder.appendingPathComponent("plan-\(UUID().uuidString).sqlite").path
        self.path = path
        do {
            let queue = try DatabaseQueue(path: path)
            try source.backup(to: queue)
            dbQueue = queue
        } catch {
            Self.remove(path)
            throw error
        }
    }

    deinit {
        try? dbQueue.close()
        Self.remove(path)
    }

    /// Copies left behind by a process that ended without releasing them (older than a day).
    private static func removeStale(now: Date = Date()) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix("plan-") {
            let url = folder.appendingPathComponent(name)
            guard let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > 24 * 60 * 60 else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    private static func remove(_ path: String) {
        for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    /// The library's documents by identity (`DocumentIdentityIndex.load`), read once per copy.
    /// Read outside any pass's savepoint, so a reader's rolled-back changes never enter it.
    func libraryIndex() throws -> DocumentIdentityIndex {
        if let index = lock.withLock({ index }) { return index }
        let loaded = try dbQueue.read { db in try DocumentIdentityIndex.load(db: db) }
        lock.withLock { index = loaded }
        return loaded
    }
}

/// The pipeline's current planning copy: replaced at the start of every plan and when files are
/// added, released when the plan is discarded or applied (`ImportPipeline.discardPlanningCopy`).
/// A pass already under way keeps the copy it started with.
final class ImportPlanningSession: @unchecked Sendable {
    // @unchecked: `copy` is guarded by `lock`.
    private let lock = NSLock()
    private var copy: ImportPlanningCopy?

    /// A new copy of `source`, now the current one.
    func fresh(from source: DatabaseQueue) throws -> ImportPlanningCopy {
        let made = try ImportPlanningCopy(of: source)
        lock.withLock { copy = made }
        return made
    }

    /// The current copy, or a new one when there is none.
    func current(from source: DatabaseQueue) throws -> ImportPlanningCopy {
        if let held = lock.withLock({ copy }) { return held }
        return try fresh(from: source)
    }

    func discard() {
        lock.withLock { copy = nil }
    }

    /// The current copy's file (tests).
    var currentPath: String? { lock.withLock { copy?.path } }
}

/// How long each phase of a plan took (`ImportPipeline.plan(…, timings:)`; the dry-run tool).
/// Reading files runs several at once: load, detect and prepare are summed over the files.
public final class ImportPlanTimings: @unchecked Sendable {
    // @unchecked: `seconds` is guarded by `lock`.
    public enum Phase: String, CaseIterable, Sendable {
        case copy, load, detect, prepare, stage, readers, statementChecks, duplicates, guardCheck = "guard"
        /// Inside the filed-year guard (`guardCheck`): the baseline matching and figures, each
        /// item's records applied, its follow-on matching, the baseline's reads replayed after it
        /// (`TaxFiguresReads`), and the figures taken after it when they read differently.
        case guardBaseline, guardApply, guardFollowOns, guardReplay, guardSnapshot
    }

    private let lock = NSLock()
    private var seconds: [Phase: TimeInterval] = [:]
    private var counts: [Phase: Int] = [:]
    private var checks: [(what: String, seconds: TimeInterval)] = []

    public init() {}

    public func add(_ phase: Phase, _ interval: TimeInterval) {
        lock.withLock {
            seconds[phase, default: 0] += interval
            counts[phase, default: 0] += 1
        }
    }

    /// The phase's total so far (0 when it never ran).
    public func total(_ phase: Phase) -> TimeInterval { lock.withLock { seconds[phase] ?? 0 } }

    /// How many times the phase ran.
    public func count(_ phase: Phase) -> Int { lock.withLock { counts[phase] ?? 0 } }

    /// The guard's check of one item (`what`: its effect's kind) and how long it took.
    func addCheck(_ what: String, _ interval: TimeInterval) { lock.withLock { checks.append((what, interval)) } }

    /// The guard's item checks, slowest first.
    public var slowestChecks: [(what: String, seconds: TimeInterval)] { lock.withLock { checks.sorted { $0.seconds > $1.seconds } } }

    func measure<T>(_ phase: Phase, _ body: () throws -> T) rethrows -> T {
        let start = Date()
        defer { add(phase, Date().timeIntervalSince(start)) }
        return try body()
    }

    func measure<T>(_ phase: Phase, _ body: () async throws -> T) async rethrows -> T {
        let start = Date()
        defer { add(phase, Date().timeIntervalSince(start)) }
        return try await body()
    }
}

extension Optional where Wrapped == ImportPlanTimings {
    /// `body`, timed when there are timings.
    func measure<T>(_ phase: ImportPlanTimings.Phase, _ body: () throws -> T) rethrows -> T {
        guard let timings = self else { return try body() }
        return try timings.measure(phase, body)
    }
}
