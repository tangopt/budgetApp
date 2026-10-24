import Foundation
import GRDB
import OSLog
import UIKit
import BudgetCore
import MangoSync
import MangoUI

/// Sync on the phone (plan step 4 Task 12): a `SyncScheduler` around a pull-only `SyncEngineCore` over CloudKit, and
/// what the screens show of it.
///
/// - **Whether it runs at all** is `SyncActivation`'s: in this step only a DEBUG `--sync-demo` launch on a demo
///   database (`BUDGET_DB_PATH`, honoured by simulator builds only, and the very database the phone opened) syncs;
///   the phone's own database (Application Support/Mango) never does. Otherwise the status stays `.off` and the
///   reason is logged.
/// - **Read-only:** the engine is made `readOnly`: it only pulls, never creates the zone (a missing one is "nothing
///   to download yet", the first download waiting for the Mac), never pushes, makes no key and takes no lease.
///   Documents aren't downloaded (`documents: nil`).
/// - **Keys:** iCloud Keychain under the demo scope for `--sync-demo` (`CloudKitTransport.keyScope`); the simulator
///   may be handed the demo key (`PhoneSyncDemoMode`).
/// - **Triggers:** `.launch` once the database is open, `.foreground` when the scene comes back, a cancel when it goes
///   to the background (the sync stops at its next operation), pull to refresh and Settings' "Sync now" await
///   `syncNowAndWait`.
/// - **iCloud account:** checked on launch and on each return to the foreground, only in a build signed for the
///   container (`PhoneEntitlements`; `CKContainer` traps otherwise).
@MainActor
final class PhoneSyncController: ObservableObject {
    @Published private(set) var status: SyncStatus = .off
    /// When this iPhone last synced (the offline banner's "showing data from").
    @Published private(set) var lastSync: Date?
    /// Before the first pull has landed (no change token yet), while sync runs here.
    @Published private(set) var isFirstDownload = false
    /// Records received by the pulls since launch (the first download's count).
    @Published private(set) var downloadedRecords = 0
    @Published private(set) var account: ICloudAccountState = .unknown
    /// Whether this iPhone holds the household key; nil while sync is off here.
    @Published private(set) var keyHeld: Bool?

    private static let log = Logger(subsystem: "ubberninja.mango.ios", category: "Sync")

    private var dbQueue: DatabaseQueue?
    private var scheduler: SyncScheduler?
    private var keyStore: (any SyncKeyStore)?
    private var statusTask: Task<Void, Never>?
    private var wentToBackground = false
    private var accountCheck: Task<Void, Never>?
    private var accountGeneration = 0
    private let canUseCloudKit = PhoneEntitlements.hasCloudKitContainer()

    /// Sync runs here (so "Sync now" means something).
    var isRunning: Bool { scheduler != nil }

    // MARK: Launch

    /// Called once the database is open: checks the iCloud account, then starts sync if this launch may.
    func attach(_ environment: PhoneEnvironment) async {
        guard dbQueue == nil else { return }
        dbQueue = environment.dbQueue
        checkAccount()
        if let refusal = Self.refusal(databasePath: environment.databasePath, canUseCloudKit: canUseCloudKit) {
            Self.log.info("Sync is off on this iPhone: \(refusal, privacy: .public)")
            return
        }
        let demo = PhoneSyncDemoMode.isRequested
        let keyStore = KeychainSyncKeyStore(container: CloudKitTransport.keyScope(demo: demo))
        if demo { PhoneSyncDemoMode.storeHandedOverKey(in: keyStore) }
        let dbQueue = environment.dbQueue
        let deviceId: String
        do {
            // A local setting: never synced, so the phone still has nothing pending.
            deviceId = try await dbQueue.write { db in try LocalSetting.phoneDeviceId(db) }
        } catch {
            Self.log.error("Sync is off: the device id couldn't be kept (\(String(describing: type(of: error)), privacy: .public))")
            return
        }
        let engine = SyncEngineCore(db: dbQueue, transport: CloudKitTransport(),
                                    device: SyncDevice(id: deviceId, name: UIDevice.current.name),
                                    keyStore: keyStore, documents: nil, readOnly: true)
        let scheduler = SyncScheduler(engine: engine, db: dbQueue)
        self.scheduler = scheduler
        self.keyStore = keyStore
        await scheduler.start()
        statusTask = Task { [weak self] in
            for await status in await scheduler.statusStream() {
                await self?.statusChanged(status)
            }
        }
        Task { await scheduler.requestSync(.launch) }
    }

    /// Why this launch can't sync, or nil: `SyncActivation`'s rules, and the database opened must be the one
    /// `BUDGET_DB_PATH` names (a device build ignores the variable and opens its own, which is refused here).
    nonisolated static func refusal(databasePath: String, canUseCloudKit: Bool,
                                    environment: [String: String] = ProcessInfo.processInfo.environment,
                                    arguments: [String] = CommandLine.arguments) -> String? {
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        let decision = SyncActivation.decision(databasePath: environment["BUDGET_DB_PATH"], arguments: arguments,
                                               isDebug: isDebug, hasCloudKitEntitlement: canUseCloudKit)
        guard decision.allowed else { return decision.reason ?? "refused" }
        guard let named = environment["BUDGET_DB_PATH"],
              TaxRegression.resolvedPath(named) == TaxRegression.resolvedPath(databasePath) else {
            return "\(SyncActivation.demoArgument): the database this iPhone opened isn't BUDGET_DB_PATH's."
        }
        return nil
    }

    // MARK: Scene

    /// The scene is active again: after a spell in the background, the account is checked and a sync asked for.
    func sceneBecameActive() {
        guard wentToBackground else { return }
        wentToBackground = false
        checkAccount()
        Task { await scheduler?.requestSync(.foreground) }
    }

    /// The scene went to the background: a running sync stops at its next operation (token and stamps unchanged).
    func sceneEnteredBackground() {
        wentToBackground = true
        guard let scheduler else { return }
        Task { await scheduler.cancel() }
    }

    // MARK: Asking

    /// Pull to refresh and Settings' "Sync now": asks for changes and waits for them. Failures show in the status.
    func syncNow() async {
        guard let scheduler else { return }
        do {
            _ = try await scheduler.syncNowAndWait()
        } catch {
            // The status says what happened (offline, waiting, stopped); a cancel or the server's wait is not news.
        }
    }

    // MARK: State

    private func statusChanged(_ status: SyncStatus) async {
        self.status = status
        guard let scheduler, let dbQueue else { return }
        lastSync = await scheduler.lastSync
        downloadedRecords = await scheduler.receivedRecords
        if let pulled = try? await dbQueue.read({ db in try SyncEngineCore.hasChangeToken(db: db) }) {
            isFirstDownload = !pulled
        }
        if case .syncing = status { return }
        if let keyStore {
            // A Keychain read, off the main actor.
            let held = await Task.detached { (try? keyStore.key(zone: SyncRecordStore.householdZone)) != nil }.value
            keyHeld = held
        }
    }

    /// Asks CloudKit for the account, one check at a time: a newer check cancels the older, whose answer is dropped
    /// (the latest wins).
    private func checkAccount() {
        guard canUseCloudKit else { return }
        accountCheck?.cancel()
        accountGeneration += 1
        let generation = accountGeneration
        accountCheck = Task { [weak self] in
            let status = await CloudKitAccountStatus.current()
            guard !Task.isCancelled, let self, self.accountGeneration == generation else { return }
            self.account = switch status {
            case .available: .available
            case .noAccount: .noAccount
            case .restricted: .restricted
            case .couldNotDetermine: .couldNotDetermine
            }
        }
    }
}
