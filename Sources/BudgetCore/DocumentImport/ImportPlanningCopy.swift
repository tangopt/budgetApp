import Foundation
import GRDB

/// A private copy of the app's database that the importer plans against (`ImportPipeline`):
/// the readers, the duplicate pass and the filed-year guard read and simulate on it, so the
/// app's own queue is never held while a plan is worked out. Taken with `backup(to:)` into a
/// temporary file, which is deleted when the copy is released. Nothing ever keeps a write on
/// it (every pass rolls back), so what is read from it once — the library's identity index —
/// holds for its lifetime.
///
/// The copies hold personal data, so none outlives its process: each process keeps its copies
/// in a folder of its own (`processFolder`), removed when the process exits normally (an
/// `atexit` handler: the app quitting, a test run ending); the folders of processes that ended
/// any other way (a crash, a force quit) are swept by `removeStale` — at launch and whenever a
/// copy is taken.
final class ImportPlanningCopy: @unchecked Sendable {
    // @unchecked: `index` is guarded by `lock`; the queue is GRDB's (serialised).
    let dbQueue: DatabaseQueue
    let path: String
    private let lock = NSLock()
    private var index: DocumentIdentityIndex?

    /// The folder holding every process's copies (in the temporary directory).
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("BudgetImportPlanning", isDirectory: true)
    }

    private static let processPrefix = "process-"

    /// This process's copies: `<folder>/process-<pid>`.
    static var processFolder: URL { processFolder(pid: getpid()) }

    static func processFolder(pid: pid_t) -> URL {
        folder.appendingPathComponent("\(processPrefix)\(pid)", isDirectory: true)
    }

    /// Registers the exit handler that removes this process's folder (once per process).
    private static let exitCleanup: Void = {
        atexit {
            // No captures (a C function pointer): the folder is worked out again here.
            try? FileManager.default.removeItem(at: ImportPlanningCopy.processFolder)
        }
    }()

    init(of source: DatabaseQueue) throws {
        _ = Self.exitCleanup
        try FileManager.default.createDirectory(at: Self.processFolder, withIntermediateDirectories: true)
        Self.removeStale()
        let path = Self.processFolder.appendingPathComponent("plan-\(UUID().uuidString).sqlite").path
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

    /// Copies left behind by processes that ended without removing them: the folders of
    /// processes no longer running, and copies at the top of `folder` (where builds before the
    /// per-process folders put them) not touched for `legacyAge`. Returns how many it removed.
    @discardableResult
    static func removeStale(now: Date = Date(), legacyAge: TimeInterval = 60 * 60) -> Int {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return 0 }
        var removed = 0
        for name in names {
            let url = folder.appendingPathComponent(name)
            if name.hasPrefix(processPrefix) {
                guard let pid = pid_t(name.dropFirst(processPrefix.count)), pid != getpid(), !isRunning(pid) else { continue }
                if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
            } else if name.hasPrefix("plan-") {
                guard let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                      now.timeIntervalSince(modified) > legacyAge else { continue }
                if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
            }
        }
        return removed
    }

    /// Whether process `pid` is running (one that can't be signalled — another user's — counts as running).
    static func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
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
