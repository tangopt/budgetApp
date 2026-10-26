// App/Sync/RealSync.swift
import AppKit
import Combine
import Foundation
import GRDB
import os
import Security
import BudgetCore
import MangoSync

/// What this build is (step 6 Task 13): read from the process itself, never from the database or the environment.
enum MacBuild {
    #if DEBUG
    static let isDebug = true
    #else
    static let isDebug = false
    #endif

    /// Signed with the iCloud container entitlement for Mango's container (`CKContainer` traps without it).
    static func hasCloudKitEntitlement() -> Bool {
        guard let containers = entitlement("com.apple.developer.icloud-container-identifiers") as? [String] else { return false }
        return containers.contains(CloudKitTransport.containerIdentifier)
    }

    /// Signed for CloudKit's Production environment (`com.apple.developer.icloud-container-environment`; Release
    /// builds, see App/Mango.entitlements).
    static func isProduction() -> Bool {
        (entitlement("com.apple.developer.icloud-container-environment") as? String) == "Production"
    }

    private static func entitlement(_ name: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, name as CFString, nil)
    }

    /// Mango's own database: `Application Support/Budget/budget.sqlite` (what `AppEnvironment.load` opens without
    /// `BUDGET_DB_PATH`).
    static var appDatabasePath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Budget", isDirectory: true).appendingPathComponent("budget.sqlite").path
    }

    /// Whether the file this window actually opened is Mango's own (a copy anywhere else never syncs).
    static func isAppDatabase(openedPath: String?) -> Bool {
        SyncActivation.isAppDatabase(openedPath: openedPath, appDatabasePath: appDatabasePath)
    }

    static func isDemoDatabase(openedPath: String?) -> Bool {
        guard let openedPath else { return false }
        return DemoMarker.isDemoDatabase(atPath: TaxRegression.resolvedPath(openedPath))
    }
}

/// The real database's sync on the admin's Mac (step 6 Task 13): CloudKit's Production environment, sealed under the
/// real key scope (`CloudKitTransport.keyScope(demo: false)`), the signed-in user's zones, re-validating only on the
/// admin's Mac (`SyncTurnOn.macEngineRole`). It runs only when `SyncActivation.realDecision` allows: Mango's own
/// database (the file actually opened), never the demo, once "Turn on sync…" has begun the upload (the stage kept in that
/// database), in a build signed for Production (Debug only with `--sync-real-in-debug`). At every start the iCloud user
/// signed in on this Mac must be the one that turned sync on (`appUser.cloudKitUserRecordName`); otherwise nothing
/// syncs and Settings ▸ Sync says why. Publishes the status and the first upload's progress; once nothing waits to go
/// up, the stage becomes done. Hub jobs stay the admin's (unchanged).
@MainActor
final class RealSync: ObservableObject {
    @Published private(set) var status: SyncStatus = .off
    @Published private(set) var progress: SyncTurnOn.Progress?
    /// Why the real sync doesn't run although the upload began (nil when it runs, or before the turn-on).
    @Published private(set) var refusal: String?

    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    private let dbQueue: DatabaseQueue
    /// The file this window opened (nil: in memory).
    private let databasePath: String?
    private let evidenceRoot: URL
    private let session: SessionModel
    private(set) var scheduler: SyncScheduler?
    /// The app user the running engine was made for.
    private var engineUserId: Int64?
    private var statusTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var identityRetry: Task<Void, Never>?
    private var sessionWatch: AnyCancellable?
    /// The iCloud user matched the admin's in this launch.
    private var identityConfirmed = false
    private var starting = false

    /// One per database in this process: windows on the same database share it (`AppEnvironment.load`), so one engine
    /// syncs it.
    init(dbQueue: DatabaseQueue, databasePath: String?, evidenceRoot: URL, session: SessionModel) {
        self.dbQueue = dbQueue
        self.databasePath = databasePath
        self.evidenceRoot = evidenceRoot
        self.session = session
    }

    var isRunning: Bool { scheduler != nil }

    /// `SyncActivation.realDecision` for this launch: the file opened, its stage, and the build.
    func decision(stage: SyncTurnOn.Stage) -> SyncActivation.Decision {
        let opened = databasePath
        return SyncActivation.realDecision(isAppDatabase: MacBuild.isAppDatabase(openedPath: opened),
                                           isDemoDatabase: MacBuild.isDemoDatabase(openedPath: opened), stage: stage,
                                           hasCloudKitEntitlement: MacBuild.hasCloudKitEntitlement(), isProduction: MacBuild.isProduction(),
                                           isDebug: MacBuild.isDebug, arguments: CommandLine.arguments)
    }

    /// At launch, and when the sheet has begun the upload: starts when allowed, after checking the iCloud user;
    /// the engine is made once someone is signed in (as them).
    func startIfAllowed() async {
        guard !SnapshotMode.isActive, scheduler == nil, !starting else { return }
        starting = true
        defer { starting = false }
        let stage: SyncTurnOn.Stage
        do {
            stage = try await dbQueue.read { db in try SyncTurnOn.stage(db: db) }
        } catch {
            Self.log.error("Real sync: the stage couldn't be read (\(String(describing: type(of: error)), privacy: .public))")
            return
        }
        await refreshProgress()
        let decision = decision(stage: stage)
        guard decision.allowed else {
            if stage >= .uploading { refusal = decision.reason }
            Self.log.info("Real sync is off: \(decision.reason ?? "refused", privacy: .public)")
            return
        }
        guard await confirmICloudUser() else { return }
        refusal = nil
        sessionWatch = session.$state.sink { [weak self] state in
            guard case .signedIn(let user) = state, let id = user.id else { return }
            Task { @MainActor [weak self] in await self?.startEngine(appUserId: id) }
        }
        if let id = session.currentAppUserId { await startEngine(appUserId: id) }
    }

    /// The iCloud user signed in on this Mac against the admin's. Unknown (offline, no answer): asked again in a
    /// minute; different: never synced in this launch.
    private func confirmICloudUser() async -> Bool {
        guard !identityConfirmed else { return true }
        let signedIn = try? await CloudKitAccountStatus.userRecordName()
        let recorded = try? await dbQueue.read { db in try SyncTurnOn.adminICloudUser(db: db) }
        switch SyncTurnOn.iCloudUserCheck(signedIn: signedIn, recorded: recorded ?? nil) {
        case .matches:
            identityConfirmed = true
            return true
        case .different, .notRecordedYet:
            refusal = SyncTurnOnFlow.differentICloudUserAtLaunch
            Self.log.notice("Real sync is off: this Mac's iCloud user isn't the one that turned sync on")
            return false
        case .unknown:
            refusal = SyncTurnOnFlow.iCloudUserUnknown
            identityRetry?.cancel()
            identityRetry = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self?.startIfAllowed()
            }
            return false
        }
    }

    /// Makes the engine for `appUserId` (its zones; re-validating only if it is the admin) and its scheduler, then
    /// syncs. Again for another user signing in.
    private func startEngine(appUserId: Int64) async {
        guard identityConfirmed, engineUserId != appUserId else { return }
        if let running = scheduler {
            scheduler = nil
            statusTask?.cancel()
            await running.stop()
        }
        engineUserId = appUserId
        let made: (SyncTurnOn.MacEngineRole, String)
        do {
            made = try await dbQueue.write { db in
                let actor = try AccessActor.load(appUserId: appUserId, db: db)
                return (try SyncTurnOn.macEngineRole(signedIn: actor, db: db), try LocalSetting.macDeviceId(db))
            }
        } catch {
            engineUserId = nil
            Self.log.error("Real sync didn't start (\(String(describing: type(of: error)), privacy: .public))")
            return
        }
        let (role, deviceId) = made
        let engine = SyncEngineCore(db: dbQueue, transport: CloudKitTransport(),
                                    device: SyncDevice(id: deviceId, name: Host.current().localizedName ?? "Mac"),
                                    keyStore: KeychainSyncKeyStore(container: CloudKitTransport.keyScope(demo: false)),
                                    documents: SyncDocumentFiles(root: evidenceRoot, policy: .eager),
                                    viewer: role.viewer, revalidatesAccess: role.revalidatesAccess)
        let scheduler = SyncScheduler(engine: engine, db: dbQueue)
        self.scheduler = scheduler
        statusTask = Task { @MainActor [weak self] in
            for await status in await scheduler.statusStream() {
                guard let self else { return }
                self.status = status
                Self.log.info("Real sync status: \(Self.describe(status), privacy: .public)")
                await self.refreshProgress()
            }
        }
        watchProgress()
        await scheduler.start()
        Self.log.info("Real sync started (re-validating: \(role.revalidatesAccess, privacy: .public))")
        Task { await scheduler.requestSync(.launch) }
    }

    /// While the first upload runs: its progress every second and a half (the push is one status for its whole
    /// length), until done.
    private func watchProgress() {
        progressTask?.cancel()
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshProgress()
                if self.progress?.stage == .done { return }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    /// Reads the turn-on's progress; once uploading with nothing left waiting, the stage becomes done.
    func refreshProgress() async {
        do {
            var progress = try await dbQueue.read { db in try SyncTurnOn.progress(db: db) }
            if progress.stage == .uploading, scheduler != nil {
                let finished = try await dbQueue.write { db -> Bool in
                    do {
                        try SyncTurnOn.markDone(db: db, now: Date())
                        return true
                    } catch SyncTurnOn.TurnOnError.uploadNotFinished {
                        return false
                    }
                }
                if finished {
                    progress = try await dbQueue.read { db in try SyncTurnOn.progress(db: db) }
                    Self.log.notice("Real sync: the first upload is done (\(progress.total, privacy: .public) records)")
                }
            }
            if self.progress != progress { self.progress = progress }
        } catch {
            Self.log.error("Real sync: progress couldn't be read (\(String(describing: type(of: error)), privacy: .public))")
        }
    }

    /// Settings ▸ Sync's "Sync now": pulls then pushes; nil when sync isn't running or didn't finish.
    func syncNow() async -> SyncReport? {
        guard let scheduler else { return nil }
        do {
            let report = try await scheduler.syncNowAndWait()
            await refreshProgress()
            return report
        } catch {
            Self.log.error("Sync now didn't finish (\(String(describing: type(of: error)), privacy: .public))")
            return nil
        }
    }

    /// A status for the log: its kind and counts, never data.
    private static func describe(_ status: SyncStatus) -> String {
        switch status {
        case .failed(let reason): "failed (\(reason))"
        default: SyncStatusCopy.text(status, now: Date()).text
        }
    }
}

/// The turn-on sheet's steps on the database (step 6 Task 13), each a write of its own and in this order: the backup
/// before anything else; the owners (only once backed up); then the keys (committed by themselves, so a quit leaves
/// them known as this turn-on's), then the upload's start. Each refuses out of order (`SyncTurnOn`).
enum TurnOnSteps {
    /// Step 1: the timestamped copy of the open database, beside it.
    static func backUp(_ dbQueue: DatabaseQueue) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try SyncTurnOn.backUp(queue: dbQueue, now: Date())
        }.value
    }

    /// Step 2: the ownership sheet's rows, saved as the signed-in admin, only after the backup; the stage follows.
    static func saveOwners(_ rows: [SharingSetup.Row], dbQueue: DatabaseQueue) async throws {
        try await dbQueue.writeAsSignedInUser { db, actor in
            let stage = try SyncTurnOn.stage(db: db)
            guard stage >= .backedUp else { throw SyncTurnOn.TurnOnError.wrongStage(stage) }
            try SharingSetup.save(rows, admin: actor, db: db, now: Date())
            try SyncTurnOn.markOwnershipConfirmed(db: db, now: Date())
        }
    }

    /// Owners saved before the backup (Settings ▸ Sharing): the stage follows once backed up. Local bookkeeping only.
    static func noteOwnersIfConfirmed(_ dbQueue: DatabaseQueue) async throws {
        try await dbQueue.write { db in
            guard try SyncTurnOn.stage(db: db) == .backedUp, try SharingSetup.isConfirmed(db: db) else { return }
            try SyncTurnOn.markOwnershipConfirmed(db: db, now: Date())
        }
    }

    /// Step 3, on the person's Start upload: the keys for the household and the admin's private zone in iCloud
    /// Keychain (real scope), then the upload's start as the admin with this Mac's iCloud user.
    static func beginUpload(_ dbQueue: DatabaseQueue, cloudKitUserRecordName: String) async throws {
        let keyStore = KeychainSyncKeyStore(container: CloudKitTransport.keyScope(demo: false))
        try await dbQueue.writeAsSignedInUser { db, actor in
            // Only the household's admin makes keys (their own private zone's, never another person's).
            guard actor.isAdmin, try AccessActor.admin(db: db).appUserId == actor.appUserId else { throw SyncTurnOn.TurnOnError.notAdmin }
            try SyncTurnOn.markOwnershipConfirmed(db: db, now: Date())
            try SyncTurnOn.prepareKeys(zones: try SyncTurnOn.turnOnZones(admin: actor, db: db), keyStore: keyStore, db: db, now: Date())
        }
        _ = try await dbQueue.writeAsSignedInUser { db, actor in
            try SyncTurnOn.beginUpload(admin: actor, cloudKitUserRecordName: cloudKitUserRecordName, db: db, now: Date())
        }
    }

    /// What the sheet's blockers need from the database, read only (nothing is written before the backup): the
    /// stage and progress, the owners, whether the signed-in user is the admin, the zones the turn-on makes keys for
    /// (the household alone while the admin's person has no sync identity yet: no key can name it), the turn-on's
    /// keys, and the admin's iCloud user.
    struct LocalFacts: Sendable {
        var progress: SyncTurnOn.Progress
        var ownershipConfirmed: Bool
        var isAdmin: Bool
        var zones: [String]
        var turnOnKeyIds: [String: String]
        var adminICloudUser: String?
    }

    static func localFacts(_ dbQueue: DatabaseQueue, signedInAppUserId: Int64?) async throws -> LocalFacts {
        try await dbQueue.read { db in
            let adminId = try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE isAdmin = 1 ORDER BY id LIMIT 1")
            let zones = (try? SyncTurnOn.turnOnZones(admin: try AccessActor.admin(db: db), db: db)) ?? [SyncZones.household]
            return LocalFacts(progress: try SyncTurnOn.progress(db: db), ownershipConfirmed: try SharingSetup.isConfirmed(db: db),
                              isAdmin: adminId != nil && adminId == signedInAppUserId, zones: zones,
                              turnOnKeyIds: try SyncTurnOn.turnOnKeyIds(db: db), adminICloudUser: try SyncTurnOn.adminICloudUser(db: db))
        }
    }

    /// The iCloud side of the blockers (only in a build signed for the container): the account, its user, and what
    /// the real key store and the server hold for each zone (`SyncTurnOn.keyFacts`, reads only). Throws when the
    /// server can't be asked.
    static func iCloudFacts(zones: [String]) async throws -> (available: Bool, recordName: String?, keys: [SyncTurnOn.ZoneKeyFacts]) {
        let available = await CloudKitAccountStatus.current() == .available
        guard available else { return (false, nil, []) }
        let recordName = try? await CloudKitAccountStatus.userRecordName()
        let keys = try await SyncTurnOn.keyFacts(zones: zones, keyStore: KeychainSyncKeyStore(container: CloudKitTransport.keyScope(demo: false)),
                                                 transport: CloudKitTransport())
        return (true, recordName, keys)
    }
}
