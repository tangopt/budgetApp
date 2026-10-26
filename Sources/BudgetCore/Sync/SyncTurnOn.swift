import Foundation
import GRDB
import os

/// Turning on sync for the real database, on the admin's Mac (sharing spec 2026-10-25 §10, sync spec §8): a
/// timestamped backup, then the ownership sheet confirmed (nothing goes up before every account has its owner and
/// level), then the zone keys made (the household's and the admin's private zone's, refused while any key or marker
/// from before exists), then the first upload — every record sealed under its zone's key and placed in its zone by the router,
/// checked by the guard on every save — then done. The Mac's sheet (Task 13) drives these stages and shows
/// `progress`; the engine does the upload itself, resumably: a halt (offline, a quit, a guard refusal) leaves what
/// wasn't acknowledged pending, and the next sync continues from there.
///
/// The stage lives in `syncState` (`turnOn.stage`, `turnOn.backupPath`, `turnOn.keyIds`, `turnOn.total`, …), local to
/// this Mac and never synced. It only moves forward. `SyncActivation.realDecision` lets the real database sync only once the stage is
/// `uploading` or `done`.
public enum SyncTurnOn {
    public enum Stage: String, Codable, Sendable, CaseIterable, Comparable {
        case notStarted, backedUp, ownershipConfirmed, keysReady, uploading, done

        var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

        public static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.order < rhs.order }
    }

    public struct Progress: Equatable, Sendable {
        public var stage: Stage
        /// The backup this flow made (its full path), once made.
        public var backupPath: String?
        /// Records queued for the first upload when it began (0 before).
        public var total: Int
        /// How many of them the server holds (counted by their server stamps, so edits and new records during the
        /// upload never make it go back; at most `total`).
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
        /// The window opened a copy of the database (`BUDGET_DB_PATH`), not Mango's own (`SyncActivation.isAppDatabase`).
        case notAppDatabase
        case wrongEnvironment
        case noEntitlement
        case demoDatabase
        case strayHouseholdKey
        case strayPrivateKey
        /// A zone's key marker is already on the server: sync was turned on before; never merged into silently.
        case syncedBefore
        case noICloudAccount
        /// The household's admin already names another iCloud user than the one this Mac is signed in to.
        case differentICloudUser
    }

    /// The signed-in iCloud user against the one the admin's app user names (`cloudKitUserRecordName`, written when
    /// the upload began), checked at every launch with real sync on (`iCloudUserCheck`).
    public enum ICloudUserCheck: Equatable, Sendable {
        case matches
        /// The admin's app user names no iCloud user yet (before the upload began).
        case notRecordedYet
        /// This Mac is signed in to another iCloud user: never synced as them.
        case different
        /// CloudKit couldn't say who is signed in (offline, no account): asked again later.
        case unknown
    }

    public static func iCloudUserCheck(signedIn: String?, recorded: String?) -> ICloudUserCheck {
        guard let signedIn, !signedIn.isEmpty else { return .unknown }
        guard let recorded, !recorded.isEmpty else { return .notRecordedYet }
        return signedIn == recorded ? .matches : .different
    }

    /// The iCloud user the household's admin names (nil: none yet).
    public static func adminICloudUser(db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT cloudKitUserRecordName FROM appUser WHERE isAdmin = 1 ORDER BY id LIMIT 1")
    }

    /// What the key store holds for a zone and what the server's key marker says (`keyFacts`).
    public struct ZoneKeyFacts: Equatable, Sendable {
        public var zone: String
        /// Ids of every key held here for the zone.
        public var heldKeyIds: Set<String>
        public var serverHasMarker: Bool
        /// The key id the server's marker names (nil: no marker, or one that can't be read).
        public var serverMarkerKeyId: String?

        public init(zone: String, heldKeyIds: Set<String>, serverHasMarker: Bool, serverMarkerKeyId: String?) {
            self.zone = zone
            self.heldKeyIds = heldKeyIds
            self.serverHasMarker = serverHasMarker
            self.serverMarkerKeyId = serverMarkerKeyId
        }
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
        /// The backup copy's row counts differ from the database's in this many tables.
        case backupIncomplete(tables: Int)
        /// The database isn't a file (an in-memory one): there is nowhere beside it for the backup.
        case notAFileDatabase
        /// A blocker stops the step (the keys: a stray key, a marker from before).
        case blocked(Blocker)

        public var errorDescription: String? {
            switch self {
            case .wrongStage(let stage): return "Turning on sync can't do that at this step (\(stage.rawValue))."
            case .ownershipNotConfirmed: return "Save who owns each account first."
            case .notAdmin: return text(.notAdmin)
            case .differentICloudUser: return "This household's admin is signed in to a different iCloud account. Sign in to that account first."
            case .uploadNotFinished(let remaining): return "\(remaining) records are still waiting to go up."
            case .backupUnreadable: return "The backup couldn't be checked, so sync stays off. Try again."
            case .backupIncomplete: return "The backup doesn't hold everything the database does, so sync stays off. Try again."
            case .notAFileDatabase: return "This database isn't a file, so it can't be backed up."
            case .blocked(let blocker): return text(blocker)
            }
        }
    }

    public static let backupPrefix = "budget.sqlite.pre-sync-backup-"
    static let stageKey = "turnOn.stage"
    static let backupPathKey = "turnOn.backupPath"
    static let totalKey = "turnOn.total"
    static let keyIdsKey = "turnOn.keyIds"
    /// The highest `syncRecord` rowid when the upload began, and how many of those rows had a server stamp then.
    static let snapshotRowidKey = "turnOn.snapshotRowid"
    static let stampedBeforeKey = "turnOn.stampedBefore"
    private static let log = Logger(subsystem: "com.personal.budget", category: "SyncTurnOn")

    // MARK: Copy

    public static func text(_ blocker: Blocker) -> String {
        switch blocker {
        case .notAdmin: return "Only the household's admin can turn on sync."
        case .notAppDatabase: return "This window opened a copy of your data, not Mango's own database."
        case .wrongEnvironment: return "This build syncs with iCloud's development environment, not your data's."
        case .noEntitlement: return "This build isn't signed for iCloud."
        case .demoDatabase: return "This is the demo database."
        case .strayHouseholdKey: return "iCloud Keychain already holds a household key from a test. Remove it before turning on sync."
        case .strayPrivateKey: return "iCloud Keychain already holds a key for your private data from a test. Remove it before turning on sync."
        case .syncedBefore: return "Sync was turned on before from another Mac or an earlier attempt."
        case .noICloudAccount: return "Sign in to iCloud in System Settings first."
        case .differentICloudUser: return TurnOnError.differentICloudUser.errorDescription ?? ""
        }
    }

    // MARK: Blockers

    /// Everything that stops the flow, in a fixed order. `keys` come from `keyFacts` for `turnOnZones` (the household
    /// and the admin's private zone); `turnOnKeyIds` are the keys this turn-on made (`turnOnKeyIds(db:)`).
    /// - Before the turn-on made its keys (stage below `keysReady`), any key held for a zone is a leftover (a test's,
    ///   or a copy of this database tested with sync) that the first upload would otherwise adopt and seal with
    ///   (`strayHouseholdKey`, `strayPrivateKey`), and any marker on the server means sync was turned on before
    ///   (`syncedBefore`): never merged into silently. The user removes a stray key; the app never deletes a real one.
    /// - From `keysReady` on, the turn-on's own keys (and markers naming them) are never in the way; any other key or
    ///   marker still is.
    /// `isAppDatabase`: the window opened Mango's own database (a copy never turns on sync). `iCloudUser`: the
    /// signed-in iCloud user against the admin's (`.different` blocks; `.unknown` doesn't, `beginUpload` checks again).
    public static func blockers(isAdmin: Bool, isAppDatabase: Bool, isProduction: Bool, hasEntitlement: Bool, isDemoDatabase: Bool,
                                iCloudAvailable: Bool, iCloudUser: ICloudUserCheck, stage: Stage, turnOnKeyIds: [String: String],
                                keys: [ZoneKeyFacts]) -> [Blocker] {
        var found: [Blocker] = []
        func add(_ blocker: Blocker) { if !found.contains(blocker) { found.append(blocker) } }
        if !isAdmin { add(.notAdmin) }
        if !isAppDatabase { add(.notAppDatabase) }
        if !isProduction { add(.wrongEnvironment) }
        if !hasEntitlement { add(.noEntitlement) }
        if isDemoDatabase { add(.demoDatabase) }
        var strays: [Blocker] = []
        var syncedBefore = false
        for facts in keys {
            let ours = stage >= .keysReady ? turnOnKeyIds[facts.zone] : nil
            if !facts.heldKeyIds.subtracting(ours.map { [$0] } ?? []).isEmpty {
                strays.append(facts.zone == SyncZones.household ? .strayHouseholdKey : .strayPrivateKey)
            }
            if facts.serverHasMarker, ours == nil || facts.serverMarkerKeyId != ours { syncedBefore = true }
        }
        for blocker in [Blocker.strayHouseholdKey, .strayPrivateKey] where strays.contains(blocker) { add(blocker) }
        if syncedBefore { add(.syncedBefore) }
        if !iCloudAvailable { add(.noICloudAccount) }
        if iCloudUser == .different { add(.differentICloudUser) }
        return found
    }

    /// The zones the turn-on makes keys for: the household and `admin`'s private zone.
    public static func turnOnZones(admin: AccessActor, db: Database) throws -> [String] {
        let personUuid = try SyncRecordStore.uuid(for: "person", localId: admin.personId, db: db)
        return [SyncZones.household, SyncZones.privateZone(personUuid: personUuid)]
    }

    /// What `blockers` needs about each of `zones`: the key ids `keyStore` holds, and the server's key marker (a
    /// missing zone: no marker). Reads only: never creates a zone, a key or a marker, never removes a key. Throws the
    /// transport's error when the server can't be asked.
    public static func keyFacts(zones: [String], keyStore: any SyncKeyStore, transport: any SyncTransport) async throws -> [ZoneKeyFacts] {
        var facts: [ZoneKeyFacts] = []
        for zone in zones {
            let held = Set(try keyStore.allKeys(zone: zone).keys)
            let marker: SyncServerRecord?
            do {
                marker = try await transport.fetch(SyncZoneKeys.recordName(zone: zone), zone: zone)
            } catch SyncTransportError.zoneNotFound {
                marker = nil
            }
            facts.append(ZoneKeyFacts(zone: zone, heldKeyIds: held, serverHasMarker: marker != nil,
                                      serverMarkerKeyId: marker.flatMap { try? SyncZoneKeys.marker(from: $0.wire).keyId }))
        }
        return facts
    }

    /// The key this turn-on made for each zone, by zone.
    public static func turnOnKeyIds(db: Database) throws -> [String: String] {
        guard let json = try text(key: keyIdsKey, db: db) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))) ?? [:]
    }

    /// Step 3, at stage `ownershipConfirmed` (again at `keysReady`: nothing new): a new key for each of `zones`
    /// (`turnOnZones`) in `keyStore`, its id recorded first (so a quit in between leaves the key known as this
    /// turn-on's). A zone whose key store already holds a key that isn't this turn-on's is refused
    /// (`blocked(.strayHouseholdKey / .strayPrivateKey)`) and nothing is made; no key is ever removed. The engine then
    /// seals with these keys and publishes their markers. The stage becomes `keysReady`.
    public static func prepareKeys(zones: [String], keyStore: any SyncKeyStore, db: Database, now: Date) throws {
        let current = try stage(db: db)
        guard current == .ownershipConfirmed || current == .keysReady else { throw TurnOnError.wrongStage(current) }
        var ids = try turnOnKeyIds(db: db)
        for zone in zones {
            let held = Set(try keyStore.allKeys(zone: zone).keys)
            if !held.isEmpty, held != Set([ids[zone]].compactMap { $0 }) {
                throw TurnOnError.blocked(zone == SyncZones.household ? .strayHouseholdKey : .strayPrivateKey)
            }
        }
        for zone in zones where try keyStore.allKeys(zone: zone).isEmpty {
            let key = DocumentCrypto.newZoneKey()
            ids[zone] = DocumentCrypto.zoneKeyId(key)
            let json = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
            try setText(json, key: keyIdsKey, db: db, now: now)
            try keyStore.store(key, zone: zone)
        }
        try advance(to: .keysReady, db: db, now: now)
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
        case .uploading: sent = min(total, max(0, try stampedSinceSnapshot(db: db)))
        default: sent = 0
        }
        return Progress(stage: stage, backupPath: backupPath, total: total, sent: sent)
    }

    /// Step 1: a full copy of the database `manager` opened, beside its file,
    /// `budget.sqlite.pre-sync-backup-yyyyMMdd-HHmmss` (local time, as `MigrationBackup`; a same-second one gets a
    /// suffix), written under a temporary name, checked (SQLite's quick check, and every table's row count equal to the
    /// database's), then moved into place. Any failure throws with no backup left and the stage unchanged. Allowed
    /// until the upload begins (a fresh backup replaces the path recorded); the stage becomes at least `backedUp`.
    @discardableResult
    public static func backUp(manager: DatabaseManager, now: Date,
                              writeBackup: @escaping MigrationBackup.BackupWriter = MigrationBackup.copyDatabase) throws -> URL {
        try backUp(queue: manager.dbQueue, now: now) { partial in try writeBackup(manager, partial) }
    }

    /// `backUp(manager:…)` for the app's open queue (the Mac's sheet): the same copy, check and stage; `writeBackup`
    /// writes the copy to the temporary path it is given (by default SQLite's backup API from `queue`).
    @discardableResult
    public static func backUp(queue: DatabaseQueue, now: Date, writeBackup: ((URL) throws -> Void)? = nil) throws -> URL {
        let writeBackup = writeBackup ?? { partial in
            let destination = try DatabaseQueue(path: partial.path)
            try queue.backup(to: destination)
            try destination.close()
        }
        let current = try queue.read { db in try stage(db: db) }
        guard current < .uploading else { throw TurnOnError.wrongStage(current) }
        let databasePath = queue.path
        guard databasePath.hasPrefix("/") else { throw TurnOnError.notAFileDatabase }
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
            try writeBackup(partial)
            try check(backup: partial, against: queue)
            try fileManager.moveItem(at: partial, to: target)
        } catch {
            removePartial()
            throw error
        }
        try queue.write { db in
            try setText(target.path, key: backupPathKey, db: db, now: now)
            try advance(to: .backedUp, db: db, now: now)
        }
        log.info("Pre-sync backup written: \(target.lastPathComponent, privacy: .public)")
        return target
    }

    /// Opens `url` read-only and runs SQLite's quick check (anything but "ok" is `backupUnreadable`), then compares
    /// every table's row count with `source`'s (`backupIncomplete` with how many differ).
    private static func check(backup url: URL, against source: DatabaseQueue) throws {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        defer { try? queue.close() }
        let result = try queue.read { db in try String.fetchOne(db, sql: "PRAGMA quick_check") }
        guard result == "ok" else { throw TurnOnError.backupUnreadable }
        let counts = { (db: Database) throws -> [String: Int] in
            var counts: [String: Int] = [:]
            for table in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'") {
                counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(SyncChangeTracker.quoted(table))") ?? 0
            }
            return counts
        }
        let expected = try source.read(counts)
        let found = try queue.read(counts)
        let differing = Set(expected.keys).union(found.keys).filter { expected[$0] != found[$0] }.count
        guard differing == 0 else { throw TurnOnError.backupIncomplete(tables: differing) }
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

    /// Step 4, at stage `keysReady` only, by the household's admin: records the admin's iCloud user on their
    /// app user (`cloudKitUserRecordName`, so the iPhone finds its viewer and private zone), gives every row its sync
    /// identity and queues it (`SyncRecordStore.backfill`, and any identity never uploaded that isn't queued), rebuilds
    /// the admin's summaries, turns sync on for imports (`SyncImportGate`), and stores how many records wait to go up.
    /// Returns that total. All in one savepoint: a refusal writes nothing. The engine then uploads; after a quit the stage is still `uploading` and the next
    /// sync continues with what is pending.
    @discardableResult
    public static func beginUpload(admin: AccessActor, cloudKitUserRecordName: String, db: Database, now: Date) throws -> Int {
        let current = try stage(db: db)
        guard current == .keysReady else { throw TurnOnError.wrongStage(current) }
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
            total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncPending WHERE kind <> 'delete'") ?? 0
            let snapshot = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(rowid), 0) FROM syncRecord") ?? 0
            let stamped = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncRecord WHERE systemFields IS NOT NULL") ?? 0
            try setText(String(total), key: totalKey, db: db, now: now)
            try setText(String(snapshot), key: snapshotRowidKey, db: db, now: now)
            try setText(String(stamped), key: stampedBeforeKey, db: db, now: now)
            try advance(to: .uploading, db: db, now: now)
            return .commit
        }
        return total
    }

    /// Whether `markDone` would move the stage on now: uploading, nothing waiting to go up. Reads only.
    public static func isUploadFinished(db: Database) throws -> Bool {
        try stage(db: db) == .uploading && pendingCount(db: db) == 0
    }

    /// Step 5: the first upload has finished (nothing pending). Refuses before the upload began and while records wait;
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

    /// Rows that were there when the upload began and have a server stamp now, less those that had one then. A stamp
    /// stays through later edits, so this never goes back while the zones stay (a zone the server lost clears its
    /// stamps and its records go up again).
    private static func stampedSinceSnapshot(db: Database) throws -> Int {
        let snapshot = Int64(try text(key: snapshotRowidKey, db: db) ?? "") ?? 0
        let before = Int(try text(key: stampedBeforeKey, db: db) ?? "") ?? 0
        let now = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncRecord WHERE rowid <= ? AND systemFields IS NOT NULL",
                                   arguments: [snapshot]) ?? 0
        return now - before
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
