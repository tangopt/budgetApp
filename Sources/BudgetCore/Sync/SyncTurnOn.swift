import Foundation
import GRDB
import os

/// Turning on sync for the real database, on the admin's Mac (sharing spec 2026-10-25 §10, sync spec §8): a
/// timestamped backup, then the ownership sheet confirmed (nothing goes up before every account has its owner and
/// level), then the first upload — every record sealed under its zone's key and placed in its zone by the router,
/// checked by the guard on every save — then done. The Mac's sheet (Task 13) drives these stages and shows
/// `progress`; the engine does the upload itself, resumably: a halt (offline, a quit, a guard refusal) leaves what
/// wasn't acknowledged pending, and the next sync continues from there.
///
/// The stage lives in `syncState` (`turnOn.stage`, `turnOn.backupPath`, `turnOn.total`), local to this Mac and never
/// synced. It only moves forward. `SyncActivation.realDecision` lets the real database sync only once the stage is
/// `uploading` or `done`.
public enum SyncTurnOn {
    public enum Stage: String, Codable, Sendable, CaseIterable, Comparable {
        case notStarted, backedUp, ownershipConfirmed, uploading, done

        var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

        public static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.order < rhs.order }
    }

    public struct Progress: Equatable, Sendable {
        public var stage: Stage
        /// The backup this flow made (its full path), once made.
        public var backupPath: String?
        /// Records queued for the first upload when it began (0 before).
        public var total: Int
        /// How many of them the server has taken: `total` − still pending (never below 0 nor above `total`).
        public var sent: Int

        public init(stage: Stage, backupPath: String?, total: Int, sent: Int) {
            self.stage = stage
            self.backupPath = backupPath
            self.total = total
            self.sent = sent
        }
    }

    /// Why sync can't be turned on now. Each has its copy (`text`).
    public enum Blocker: Equatable, Sendable {
        case notAdmin
        case wrongEnvironment
        case noEntitlement
        case demoDatabase
        case strayHouseholdKey
        case noICloudAccount
    }

    /// A stage asked for out of order, or a step refused (nothing is written then).
    public enum TurnOnError: Error, Equatable, LocalizedError {
        /// The step needs another stage first (or the flow is past it).
        case wrongStage(Stage)
        /// The ownership sheet isn't saved yet: nothing may go up before every account has its owner and level.
        case ownershipNotConfirmed
        /// Only the household's admin turns on sync.
        case notAdmin
        /// The admin's app user already belongs to another iCloud user.
        case differentICloudUser
        /// Records are still waiting to go up.
        case uploadNotFinished(remaining: Int)
        /// The backup copy doesn't open as a sound database.
        case backupUnreadable

        public var errorDescription: String? {
            switch self {
            case .wrongStage(let stage): return "Turning on sync can't do that at this step (\(stage.rawValue))."
            case .ownershipNotConfirmed: return "Save who owns each account first."
            case .notAdmin: return text(.notAdmin)
            case .differentICloudUser: return "This household's admin is signed in to a different iCloud account. Sign in to that account first."
            case .uploadNotFinished(let remaining): return "\(remaining) records are still waiting to go up."
            case .backupUnreadable: return "The backup couldn't be checked, so sync stays off. Try again."
            }
        }
    }

    public static let backupPrefix = "budget.sqlite.pre-sync-backup-"
    static let stageKey = "turnOn.stage"
    static let backupPathKey = "turnOn.backupPath"
    static let totalKey = "turnOn.total"
    private static let log = Logger(subsystem: "com.personal.budget", category: "SyncTurnOn")

    // MARK: Copy

    public static func text(_ blocker: Blocker) -> String {
        switch blocker {
        case .notAdmin: return "Only the household's admin can turn on sync."
        case .wrongEnvironment: return "This build syncs with iCloud's development environment, not your data's."
        case .noEntitlement: return "This build isn't signed for iCloud."
        case .demoDatabase: return "This is the demo database."
        case .strayHouseholdKey: return "iCloud Keychain already holds a household key from a test. Remove it before turning on sync."
        case .noICloudAccount: return "Sign in to iCloud in System Settings first."
        }
    }

    // MARK: Blockers

    /// Everything that stops the flow from starting, in a fixed order. `keyStoreHoldsHouseholdKey` and
    /// `serverHasHouseholdMarker` come from `keyFacts`: a household key held here while the server has no marker
    /// naming one is a leftover (a test's) that the first upload would otherwise adopt and seal everything with
    /// (`strayHouseholdKey`); the user removes it — the app never deletes a real key.
    public static func blockers(isAdmin: Bool, isProduction: Bool, hasEntitlement: Bool, isDemoDatabase: Bool,
                                keyStoreHoldsHouseholdKey: Bool, serverHasHouseholdMarker: Bool, iCloudAvailable: Bool) -> [Blocker] {
        var found: [Blocker] = []
        if !isAdmin { found.append(.notAdmin) }
        if !isProduction { found.append(.wrongEnvironment) }
        if !hasEntitlement { found.append(.noEntitlement) }
        if isDemoDatabase { found.append(.demoDatabase) }
        if keyStoreHoldsHouseholdKey, !serverHasHouseholdMarker { found.append(.strayHouseholdKey) }
        if !iCloudAvailable { found.append(.noICloudAccount) }
        return found
    }

    /// What `blockers` needs to know about the household key: whether `keyStore` holds any key for the household zone,
    /// and whether the server has the household's key marker (a missing zone: no marker). Reads only: never creates a
    /// zone, a key or a marker, never removes a key. Throws the transport's error when the server can't be asked.
    /// Only the household zone is checked: the admin's private zone is named after their person's random UUID, which
    /// no test outside this database has used, so no stray key can wait under it.
    public static func keyFacts(keyStore: any SyncKeyStore, transport: any SyncTransport) async throws
        -> (keyStoreHoldsHouseholdKey: Bool, serverHasHouseholdMarker: Bool) {
        let zone = SyncZones.household
        let holds = !(try keyStore.allKeys(zone: zone)).isEmpty
        let marker: SyncServerRecord?
        do {
            marker = try await transport.fetch(SyncZoneKeys.recordName(zone: zone), zone: zone)
        } catch SyncTransportError.zoneNotFound {
            marker = nil
        }
        return (holds, marker != nil)
    }

    // MARK: Engine role

    /// How the Mac's real engine is made for the signed-in user (step 6 Task 9 review M-3): its viewer is that user's
    /// person (household + their own private zone), and only the household's admin re-validates incoming changes.
    public struct MacEngineRole: Equatable, Sendable {
        public var viewer: SyncViewer
        public var revalidatesAccess: Bool
    }

    public static func macEngineRole(signedIn: AccessActor, db: Database) throws -> MacEngineRole {
        let personUuid = try SyncRecordStore.uuid(for: "person", localId: signedIn.personId, db: db)
        let adminId = try AccessActor.admin(db: db).appUserId
        let isTheAdmin = signedIn.isAdmin && adminId == signedIn.appUserId
        return MacEngineRole(viewer: SyncViewer(personUuid: personUuid), revalidatesAccess: isTheAdmin)
    }

    // MARK: Stages

    public static func stage(db: Database) throws -> Stage {
        guard try db.tableExists("syncState"),
              let data = try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [stageKey]),
              let raw = String(data: data, encoding: .utf8) else { return .notStarted }
        return Stage(rawValue: raw) ?? .notStarted
    }

    public static func progress(db: Database) throws -> Progress {
        let stage = try stage(db: db)
        let backupPath = try text(key: backupPathKey, db: db)
        let total = stage >= .uploading ? Int(try text(key: totalKey, db: db) ?? "") ?? 0 : 0
        let sent: Int
        switch stage {
        case .done: sent = total
        case .uploading: sent = min(total, max(0, total - (try pendingCount(db: db))))
        default: sent = 0
        }
        return Progress(stage: stage, backupPath: backupPath, total: total, sent: sent)
    }

    /// Step 1: a full copy of the open database beside it, `budget.sqlite.pre-sync-backup-yyyyMMdd-HHmmss` (local time,
    /// as `MigrationBackup`; a same-second one gets a suffix), written under a temporary name, checked to open as a
    /// sound database, then moved into place. Any failure throws with no backup left and the stage unchanged. Allowed
    /// until the upload begins (a fresh backup replaces the path recorded); the stage becomes at least `backedUp`.
    @discardableResult
    public static func backUp(manager: DatabaseManager, databasePath: String, now: Date,
                              writeBackup: MigrationBackup.BackupWriter = MigrationBackup.copyDatabase) throws -> URL {
        let current = try manager.dbQueue.read { db in try stage(db: db) }
        guard current < .uploading else { throw TurnOnError.wrongStage(current) }
        let fileManager = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = URL(fileURLWithPath: databasePath).deletingLastPathComponent()
        let base = backupPrefix + formatter.string(from: now)
        var target = directory.appendingPathComponent(base)
        var n = 2
        while fileManager.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("\(base)-\(n)")
            n += 1
        }
        let partial = target.appendingPathExtension("partial")
        func removePartial() {
            for suffix in ["", "-wal", "-shm", "-journal"] { try? fileManager.removeItem(atPath: partial.path + suffix) }
        }
        do {
            removePartial()
            try writeBackup(manager, partial)
            try check(backup: partial)
            try fileManager.moveItem(at: partial, to: target)
        } catch {
            removePartial()
            throw error
        }
        try manager.dbQueue.write { db in
            try setText(target.path, key: backupPathKey, db: db, now: now)
            try advance(to: .backedUp, db: db, now: now)
        }
        log.info("Pre-sync backup written: \(target.lastPathComponent, privacy: .public)")
        return target
    }

    /// Opens `url` read-only and runs SQLite's quick check: anything but "ok" is `backupUnreadable`.
    private static func check(backup url: URL) throws {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        defer { try? queue.close() }
        let result = try queue.read { db in try String.fetchOne(db, sql: "PRAGMA quick_check") }
        guard result == "ok" else { throw TurnOnError.backupUnreadable }
    }

    /// Step 2: the ownership sheet has been saved (`SharingSetup.isConfirmed`), after the backup. Refuses before the
    /// backup (`wrongStage`) and while ownership isn't confirmed; past this stage it changes nothing.
    public static func markOwnershipConfirmed(db: Database, now: Date) throws {
        let current = try stage(db: db)
        guard current >= .backedUp else { throw TurnOnError.wrongStage(current) }
        guard current == .backedUp else { return }
        guard try SharingSetup.isConfirmed(db: db) else { throw TurnOnError.ownershipNotConfirmed }
        try advance(to: .ownershipConfirmed, db: db, now: now)
    }

    /// Step 3, at stage `ownershipConfirmed` only, by the household's admin: records the admin's iCloud user on their
    /// app user (`cloudKitUserRecordName`, so the iPhone finds its viewer and private zone), gives every row its sync
    /// identity and queues it (`SyncRecordStore.backfill`, and any identity never uploaded that isn't queued), rebuilds
    /// the admin's summaries, turns sync on for imports (`SyncImportGate`), and stores how many records wait to go up.
    /// Returns that total. All in one savepoint: a refusal writes nothing. The engine then uploads; after a quit the stage is still `uploading` and the next
    /// sync continues with what is pending.
    @discardableResult
    public static func beginUpload(admin: AccessActor, cloudKitUserRecordName: String, db: Database, now: Date) throws -> Int {
        let current = try stage(db: db)
        guard current == .ownershipConfirmed else { throw TurnOnError.wrongStage(current) }
        let adminId = try AccessActor.admin(db: db).appUserId
        guard admin.isAdmin, adminId == admin.appUserId else { throw TurnOnError.notAdmin }
        guard try SharingSetup.isConfirmed(db: db) else { throw TurnOnError.ownershipNotConfirmed }
        var total = 0
        try db.inSavepoint {
            let held = try String.fetchOne(db, sql: "SELECT cloudKitUserRecordName FROM appUser WHERE id = ?", arguments: [admin.appUserId])
            if let held, held != cloudKitUserRecordName { throw TurnOnError.differentICloudUser }
            if held == nil {
                try ActorWrite.perform(admin, area: .householdSettings, db: db) {
                    try db.execute(sql: "UPDATE appUser SET cloudKitUserRecordName = ? WHERE id = ?",
                                   arguments: [cloudKitUserRecordName, admin.appUserId])
                }
            }
            try SyncRecordStore.backfill(db: db)
            try queueNeverUploaded(db: db)
            try AccountSummaryBuilder.rebuild(ownerPersonId: admin.personId, db: db, today: now)
            try SyncImportGate.setSyncOn(true, db: db, now: now)
            total = try pendingCount(db: db)
            try setText(String(total), key: totalKey, db: db, now: now)
            try advance(to: .uploading, db: db, now: now)
            return .commit
        }
        return total
    }

    /// Step 4: the first upload has finished (nothing pending). Refuses before the upload began and while records wait;
    /// once done it changes nothing.
    public static func markDone(db: Database, now: Date) throws {
        let current = try stage(db: db)
        guard current >= .uploading else { throw TurnOnError.wrongStage(current) }
        guard current == .uploading else { return }
        let remaining = try pendingCount(db: db)
        guard remaining == 0 else { throw TurnOnError.uploadNotFinished(remaining: remaining) }
        try advance(to: .done, db: db, now: now)
    }

    // MARK: Storage

    /// Every row that has a sync identity but has never been on the server (no stamp) and isn't waiting to go up is
    /// queued as an insert, so the first upload sends everything, whatever was queued or cleared before.
    static func queueNeverUploaded(db: Database) throws {
        for table in SyncSchema.tables {
            let base = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(revision), 0) FROM syncPending") ?? 0
            try db.execute(sql: """
                INSERT INTO syncPending(uuid, tableName, localId, kind, revision)
                SELECT s.uuid, s.tableName, s.localId, 'insert', ? + s.rowid FROM syncRecord s
                WHERE s.tableName = ? AND s.systemFields IS NULL
                AND EXISTS (SELECT 1 FROM \(SyncChangeTracker.quoted(table.name)) t WHERE t.\(SyncChangeTracker.quoted(table.localIdColumn)) = s.localId)
                ORDER BY s.rowid
                ON CONFLICT(uuid) DO NOTHING
                """, arguments: [base, table.name])
        }
    }

    static func pendingCount(db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncPending") ?? 0
    }

    /// The stage becomes `stage` only when that is further on: it never moves back.
    private static func advance(to stage: Stage, db: Database, now: Date) throws {
        guard try self.stage(db: db) < stage else { return }
        try setText(stage.rawValue, key: stageKey, db: db, now: now)
    }

    private static func text(key: String, db: Database) throws -> String? {
        guard try db.tableExists("syncState"),
              let data = try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [key]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func setText(_ value: String, key: String, db: Database, now: Date) throws {
        try SyncImportGate.setState(Data(value.utf8), key: key, db: db, now: now)
    }
}
