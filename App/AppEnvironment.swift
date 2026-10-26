// App/AppEnvironment.swift
import Foundation
import BudgetCore
import GRDB
import OSLog
import os

struct LaunchBackupError: LocalizedError {
    let underlying: Error
    var errorDescription: String? {
        "Mango couldn't back up your data before updating it, so it didn't update anything. \(underlying.localizedDescription)"
    }
}

/// Who the app's data writes are made as (step 6 Task 9): the user signed in now, kept by the session (`SessionModel`)
/// where any thread can read it.
enum SignedInActor {
    enum State: Equatable, Sendable {
        /// Sign-in isn't set up (no app users yet): nothing to check, nobody to stamp.
        case notSetUp
        /// Locked, or no session yet: the app writes nothing.
        case signedOut
        case signedIn(appUserId: Int64)
    }

    private static let current = OSAllocatedUnfairLock<State>(initialState: .signedOut)

    static var state: State {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }

    /// The signed-in app user's id; nil while locked or before sign-in is set up.
    static var appUserId: Int64? {
        if case .signedIn(let id) = state { return id }
        return nil
    }

    /// The actor a write made now is made as: the signed-in user; nil before sign-in is set up (nothing to check).
    /// Signed out, it throws (fix round 1 M-2: never stamped as the admin).
    static func actor(for state: State, db: Database) throws -> AccessActor? {
        switch state {
        case .signedIn(let id): return try AccessActor.load(appUserId: id, db: db)
        case .notSetUp: return nil
        case .signedOut: throw SignedOutWrite()
        }
    }

    static func actor(db: Database) throws -> AccessActor? { try actor(for: state, db: db) }

    /// Whose figures the screens show (`SharingViewer`): the signed-in user; everything before sign-in is set up.
    static func viewer(db: Database) throws -> SharingViewer {
        try SharingViewer.load(appUserId: appUserId, db: db)
    }

    /// The screens' actuals as the signed-in user sees them (`SharedActualsSource`).
    static func actuals(db: Database, today: Date) throws -> SharedActualsSource {
        SharedActualsSource(viewer: try viewer(db: db), today: today)
    }
}

/// A data write asked for while nobody is signed in: refused, nothing written.
struct SignedOutWrite: LocalizedError {
    var errorDescription: String? { "Sign in to change this." }
}

/// Every data write the app makes goes through these (`scripts/check-actor-writes.sh` keeps it so): it runs as the
/// signed-in user, only with Edit on `area` (else `AccessDenied` and nothing written), stamping them as the writer
/// and `origin` on what it changes (`ActorWrite.perform`).
extension DatabaseWriter {
    func write<T>(_ area: AccessArea, origin: WriteOrigin = .edit, _ body: (Database) throws -> T) throws -> T {
        let state = SignedInActor.state
        guard state != .signedOut else { throw SignedOutWrite() }
        return try write { db in
            try ActorWrite.perform(orAdmin: try SignedInActor.actor(for: state, db: db), area: area, origin: origin, db: db) { try body(db) }
        }
    }

    func write<T: Sendable>(_ area: AccessArea, origin: WriteOrigin = .edit,
                            _ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        let state = SignedInActor.state
        guard state != .signedOut else { throw SignedOutWrite() }
        return try await write { db in
            try ActorWrite.perform(orAdmin: try SignedInActor.actor(for: state, db: db), area: area, origin: origin, db: db) {
                try body(db)
            }
        }
    }

    /// A write whose rule is who you are, not an area (sharing: the ownership sheet is the admin's, a level its
    /// account owner's): BudgetCore checks the actor and stamps them (`SharingSetup.save`, `SharingLevels.set`).
    /// Refused while nobody is signed in, and before sign-in is set up (nobody to check).
    func writeAsSignedInUser<T: Sendable>(_ body: @escaping @Sendable (Database, AccessActor) throws -> T) async throws -> T {
        let state = SignedInActor.state
        guard case .signedIn = state else { throw SignedOutWrite() }
        return try await write { db in
            guard let actor = try SignedInActor.actor(for: state, db: db) else { throw SignedOutWrite() }
            return try body(db, actor)
        }
    }

    /// `signedInActor()` off the main thread: the signed-in user's actor (its writer UUID made if new); nil before
    /// sign-in is set up; throws `SignedOutWrite` while nobody is signed in.
    func loadSignedInActor() async throws -> AccessActor? {
        let state = SignedInActor.state
        guard state != .signedOut else { throw SignedOutWrite() }
        return try await write { db in try SignedInActor.actor(for: state, db: db) }
    }

    /// The signed-in user's actor, for BudgetCore entry points that write by themselves (`EvidenceLibrary.link`);
    /// throws `SignedOutWrite` when nobody is signed in.
    func signedInActor() throws -> AccessActor? {
        let state = SignedInActor.state
        guard state != .signedOut else { throw SignedOutWrite() }
        return try write { db in try SignedInActor.actor(for: state, db: db) }
    }
}

@MainActor
final class AppEnvironment: ObservableObject {
    let dbQueue: DatabaseQueue
    /// The database file (nil for an in-memory one): the document importer backs it up
    /// before a large import.
    let databasePath: String?
    /// Where the evidence library keeps its copies: beside the database.
    let evidenceRoot: URL
    /// Set once, right after launch, only if the fetched rate actually differs from the
    /// last saved one at 2 decimal places. `AccountsView` displays and dismisses it.
    @Published var exchangeRateBanner: String?
    /// What Settings ▸ Sync shows. `.off` unless a DEBUG `--sync-demo` launch on the demo database runs the
    /// scheduler (`SyncDemoMode`): the real database never syncs in this build (`SyncActivation`).
    @Published var syncStatus: SyncStatus = .off
    /// The last sync's report in that demo (Settings ▸ Sync's counts); nil until one has finished.
    @Published var syncLastReport: SyncReport?
    /// The demo's scheduler; nil whenever sync is off.
    var syncScheduler: SyncScheduler?
    /// HMRC's average rates the ended tax years lack, fetched in the background (after
    /// launch, and whenever the Tax years screen appears).
    let hmrcRateAutoFetch: HMRCRateAutoFetch
    /// The Euribor monthly averages the mortgages follow, fetched in the background (after
    /// launch, and whenever a property page opens).
    let interestIndexAutoFetch: InterestIndexAutoFetch
    /// The one document importer (File ▸ Import…, the toolbar, a drop on the window, the
    /// Imports screen), made when first used.
    /// Apple's on-device model is asked about documents nothing else recognises; never in
    /// snapshot mode (its routes pass their own stand-in).
    /// Who is signed in, shared by every window (the Settings scene reaches it through `Current.shared`).
    let session: SessionModel
    lazy var importCenter: ImportCenterModel = ImportCenterModel(
        dbQueue: dbQueue, databasePath: databasePath, library: evidenceLibrary,
        categorizationService: CategorizationService(categorizer: OnDeviceCategorizer.systemDefault()),
        modelReader: SnapshotMode.isActive ? nil : FoundationModelsDocumentReader(),
        // Read when Confirm import is pressed: whoever is signed in then (auth spec §6).
        currentAppUserId: { [weak self] in self?.session.currentAppUserId })

    private init(dbQueue: DatabaseQueue, databasePath: String?, evidenceRoot: URL, auth: LaunchAuth, session existing: SessionModel?) {
        self.dbQueue = dbQueue
        self.databasePath = databasePath
        self.evidenceRoot = evidenceRoot
        // A second window on the same database shares the first one's session: one sign-in for every window.
        // The snapshot build never touches the Keychain or the app's own preferences.
        self.session = existing ?? (SnapshotMode.isActive
            ? SessionModel(dbQueue: dbQueue, isSetUp: auth.isSetUp,
                           biometrics: BiometricUnlock.snapshot(scope: auth.databaseId, defaults: SnapshotMode.defaults),
                           defaults: SnapshotMode.defaults, snapshotUser: auth.snapshotUser)
            : SessionModel(dbQueue: dbQueue, isSetUp: auth.isSetUp, biometrics: BiometricUnlock.make(scope: auth.databaseId)))
        self.hmrcRateAutoFetch = HMRCRateAutoFetch(dbQueue: dbQueue)
        self.interestIndexAutoFetch = InterestIndexAutoFetch(dbQueue: dbQueue)

        // The snapshot harness never touches the network (and renders from its own data);
        // `HMRCRateAutoFetch.run` refuses in that mode too (the Tax years screen calls it).
        guard !SnapshotMode.isActive else { return }
        Task { [weak self] in
            await self?.refreshExchangeRate()
            self?.hmrcRateAutoFetch.run()
            self?.interestIndexAutoFetch.run()
        }
    }

    /// Opens, migrates and seeds the database off the main thread so the window can show
    /// `LaunchView` straight away instead of blocking launch. Throws on any setup failure;
    /// `LaunchView` shows the error instead of crashing.
    /// How many times `load()` has run in this process: once per main window. The lock overlay must not
    /// make a window load twice (the snapshot route `auth-launch_loads_once` checks it).
    private(set) static var loadCount = 0

    static func load() async throws -> AppEnvironment {
        loadCount += 1
        Logger(subsystem: "com.personal.budget", category: "Launch").info("Loading the environment (load #\(loadCount, privacy: .public))")
        if loadCount == 1 {
            // Planning copies of the database (personal data) left by a crash or a force quit go.
            Task.detached(priority: .utility) {
                let removed = ImportPipeline.removeStalePlanningCopies()
                if removed > 0 {
                    Logger(subsystem: "com.personal.budget", category: "Launch").notice("Removed \(removed, privacy: .public) stale import planning copies")
                }
            }
        }
        let (dbQueue, dbPath, auth) = try await Task.detached(priority: .userInitiated) {
            let dbPath: String
            if let override = ProcessInfo.processInfo.environment["BUDGET_DB_PATH"], !override.isEmpty {
                // Lets the app run against a copy of the database for safe manual testing.
                dbPath = override
            } else {
                let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Budget", isDirectory: true)
                try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
                dbPath = appSupport.appendingPathComponent("budget.sqlite").path
            }

            let manager = try DatabaseManager(path: dbPath)
            // A copy first, so no migration ever runs on the only copy. If it can't be made,
            // launch stops here with the database untouched.
            do {
                try MigrationBackup.backUpThenMigrate(manager: manager, databasePath: dbPath, now: Date())
            } catch {
                throw LaunchBackupError(underlying: error)
            }
            // Launch upkeep is a hub job: the admin's (nothing to check before sign-in is set up).
            try manager.dbQueue.write { db in
                try ActorWrite.perform(orAdmin: nil, area: .rulesAndCategories, origin: .system, db: db) { try CategorySeeder.seedDefaults(db) }
            }
            // Gives every account its transfer category (spec 2026-10-14 §4), then links
            // transfers between accounts already imported, filing their legs under those
            // (idempotent; spec §6). A failure only leaves them as they were until the next
            // import or launch — never blocks launch.
            do {
                _ = try manager.dbQueue.write { db in
                    try ActorWrite.perform(orAdmin: nil, area: .budgetAndAccounts, origin: .system, db: db) {
                        try TransferCategories.ensure(db: db)
                        return try TransferMatcher.match(db: db, today: AppClock.now)
                    }
                }
            } catch {
                Logger(subsystem: "com.personal.budget", category: "Transfers").error("Transfer matching at launch failed: \(error.localizedDescription, privacy: .public)")
            }
            let auth = try manager.dbQueue.write { db in
                LaunchAuth(isSetUp: try AppUserStore.isSetUp(db), databaseId: try LocalSetting.databaseId(db),
                           snapshotUser: SnapshotMode.isActive ? try LaunchAuth.snapshotUser(db) : nil)
            }
            return (manager.dbQueue, dbPath, auth)
        }.value
        // `Evidence` next to the database: `Application Support/Budget/Evidence` normally, and
        // beside a `BUDGET_DB_PATH` copy when testing against one.
        let evidenceRoot = URL(fileURLWithPath: dbPath).deletingLastPathComponent().appendingPathComponent("Evidence", isDirectory: true)
        let existing = Current.shared.environment.flatMap { $0.databasePath == dbPath ? $0.session : nil }
        let environment = AppEnvironment(dbQueue: dbQueue, databasePath: dbPath, evidenceRoot: evidenceRoot, auth: auth, session: existing)
        AppEnvironment.Current.shared.environment = environment
        // Every transaction's paperclip count, kept current from here on.
        TransactionDocumentCounts.shared.start(dbQueue: dbQueue)
        #if DEBUG
        SyncDemoMode.start(environment)
        #endif
        return environment
    }

    /// What the session needs from the database at launch, read with the migration off the main thread.
    private struct LaunchAuth: Sendable {
        let isSetUp: Bool
        /// Scopes this Mac's Touch ID enrolment to this database.
        let databaseId: String
        let snapshotUser: AppUser?

        /// The demo database's first app user who can sign in, else its admin (`DemoSharing`'s, with no password),
        /// else a stand-in for its first person (snapshot build only).
        static func snapshotUser(_ db: Database) throws -> AppUser? {
            if let user = try AppUserStore.signInCandidates(db).first { return user }
            if let admin = try AppUser.filter(Column("isAdmin") == true).order(Column("id")).fetchOne(db) { return admin }
            guard let person = try Person.order(Column("id")).fetchOne(db), let personId = person.id else { return nil }
            return AppUser(personId: personId, displayName: person.name, isAdmin: true, createdAt: AppClock.now)
        }
    }

    /// A data write as the signed-in user (`DatabaseWriter.write(_:origin:_:)`).
    func write<T: Sendable>(_ area: AccessArea, origin: WriteOrigin = .edit,
                            _ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await dbQueue.write(area, origin: origin, body)
    }

    /// Sync runs in this window's database (only a DEBUG `--sync-demo` launch on the demo database).
    var isSyncRunning: Bool { syncScheduler != nil }

    /// Settings ▸ Sync's "Sync now": pulls then pushes through the scheduler and keeps the report. Nothing when
    /// sync is off.
    func syncNow() async {
        guard let scheduler = syncScheduler else { return }
        do {
            syncLastReport = try await scheduler.syncNowAndWait()
        } catch {
            Logger(subsystem: "com.personal.budget", category: "Sync")
                .error("Sync now didn't finish (\(String(describing: type(of: error)), privacy: .public))")
        }
    }

    /// The most recently loaded environment, for scenes without a main window of their own
    /// (Settings ▸ Evidence). `nil` until the main window has opened the database.
    final class Current: ObservableObject {
        static let shared = Current()
        @Published var environment: AppEnvironment?
    }

    /// The evidence library next to the database (`Application Support/Budget/Evidence`).
    var evidenceLibrary: EvidenceLibrary {
        EvidenceLibrary(root: evidenceRoot, database: dbQueue)
    }

    /// Never blocks launch (it's kicked off from `init` as a detached `Task`) and never
    /// throws outward — any failure (offline, bad response) just leaves the last saved
    /// rate in place, silently, exactly as if this never ran.
    private func refreshExchangeRate() async {
        let source = FrankfurterExchangeRateSource()
        guard let fetchedRate = await source.fetchEURToGBPRate() else { return }
        do {
            let (previousRate, accounts, snapshots, transactions) = try await dbQueue.read { db -> (ExchangeRateSetting, [Account], [BalanceSnapshot], [Transaction]) in
                (try ExchangeRateSetting.currentOrDefault(db: db), try Account.fetchAll(db), try BalanceSnapshot.fetchAll(db), try Transaction.fetchAll(db))
            }
            guard ExchangeRateFetcher.hasChanged(fetchedRate: fetchedRate, previousRate: previousRate.eurToGbpRate) else { return }

            let newRate = ExchangeRateSetting(eurToGbpRate: fetchedRate, updatedAt: AppClock.now)
            let impact = ExchangeRateFetcher.netWorthImpact(accounts: accounts, snapshots: snapshots, transactions: transactions, oldRate: previousRate, newRate: newRate)

            // A hub job (no one asked for it): the admin's, whoever is signed in.
            try await dbQueue.write { db in
                try ActorWrite.perform(orAdmin: nil, area: .householdSettings, origin: .system, db: db) {
                    var setting = newRate
                    try setting.insert(db)
                }
            }

            let sign = impact >= 0 ? "+" : ""
            exchangeRateBanner = "EUR rate updated to \(String(format: "%.2f", fetchedRate)) (was \(String(format: "%.2f", previousRate.eurToGbpRate))) — net worth changed by \(sign)\(Money.format(impact, currency: .gbp))."
        } catch {
            // Swallowed on purpose — same "fall back silently" contract as a failed fetch.
        }
    }
}
