import CloudKit
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
/// - **Whether it runs at all** is `SyncActivation.phoneDecision`'s (step 6): demo data never syncs; a DEBUG
///   `--sync-demo` launch keeps step 4's rules (a demo database named by `BUDGET_DB_PATH`, honoured by simulator
///   builds only, and the very database the phone opened); otherwise the phone's own database (Application
///   Support/Mango) syncs in a Release build signed for the container (TestFlight). Refused: the status stays `.off`
///   and the reason is logged.
/// - **Zones** (step 6): the household, then the private zone of the person this iPhone's iCloud user is
///   (`CloudKitAccountStatus.userRecordName` → `SyncViewer.forCloudKitUser`), once the household pull has brought
///   that app user here: the engine is then made again with the viewer and syncs once more. Never another person's
///   private zone. The screens read through the same iCloud user (`viewerRecordName`, `PhoneViewer.iCloudUser`).
/// - **Read-only:** the engine is made `readOnly`: it only pulls, never creates the zone (a missing one is "nothing
///   to download yet", the first download waiting for the Mac), never pushes, makes no key and takes no lease.
///   Documents aren't downloaded (`documents: nil`).
/// - **Keys:** iCloud Keychain under the demo scope for `--sync-demo` (`CloudKitTransport.keyScope`); the simulator
///   may be handed the demo key (`PhoneSyncDemoMode`).
/// - **Triggers:** `.launch` once the database is open, `.foreground` when the scene comes back, a cancel when it goes
///   to the background (the sync stops at its next operation), pull to refresh and Settings' "Sync now" await
///   `syncNowAndWait`.
/// - **Demo data** ("Try with demo data", `PhoneDemoData`): sync is off entirely: nothing is attached, no account
///   check, no key store, no CloudKit; `enterDemo()` stops a running scheduler first. `refusal` refuses demo data
///   too (`PhoneDemoMode.syncRefusal`), so a demo database is never pulled into or mistaken for the household's.
/// - **iCloud account:** checked on launch and on each return to the foreground, only in a build signed for the
///   container (`PhoneEntitlements`; `CKContainer` traps otherwise).
/// - **iCloud user change** (step 7a): the transport keeps the iCloud user it first read, so on `CKAccountChanged` the
///   engine stops and is made again (a new transport) only once the new user's record name is read. Each record name
///   read goes through `SyncAccountSwitch.apply`: a known, different user drops the private zones' data here (local
///   only); an undetermined one (no account, offline, a blip) drops nothing and keeps sync stopped until it is known.
/// - **Removed from the household** (`SyncScheduler.leftHousehold`, a member device): the household's data and key go
///   from this device, the membership is forgotten, and `householdNotice` says so.
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
    /// This iPhone's iCloud user's record name, once read (the viewer: `PhoneViewer.iCloudUser`); nil before, without
    /// an account, or in a build that can't ask.
    @Published private(set) var viewerRecordName: String?
    /// Shown once this device was found no longer in the household (its data removed here).
    @Published private(set) var householdNotice: String?

    /// Moved into `HouseholdCopy.removedNotice` in Task 7.
    static let removedNotice = "You're no longer in this household. Its data was removed from this device."

    private static let log = Logger(subsystem: "ubberninja.mango.ios", category: "Sync")

    private var dbQueue: DatabaseQueue?
    private var scheduler: SyncScheduler?
    private var keyStore: (any SyncKeyStore)?
    private var deviceId: String?
    /// The viewer the running engine was made with: `.none` (household only) until the household names it.
    private var engineViewer: SyncViewer = .none
    /// A check for the viewer's private zone is under way (one at a time).
    private var followingViewer = false
    /// A read of the iCloud user's record name is under way.
    private var readingRecordName = false
    /// Counts `startEngine` calls (and demo data going on): only the latest makes a scheduler.
    private var engineGeneration = 0
    private var statusTask: Task<Void, Never>?
    private var wentToBackground = false
    private var accountCheck: Task<Void, Never>?
    private var accountGeneration = 0
    /// The iCloud user changed and the engine is stopped until the new user's record name is read.
    private var awaitingICloudUser = false
    /// Counts iCloud user changes: a record name read before the latest change is dropped.
    private var identityGeneration = 0
    private var accountWatch: NSObjectProtocol?
    /// The household's data is being dropped here (one at a time).
    private var leavingHousehold = false
    private let canUseCloudKit = PhoneEntitlements.hasCloudKitContainer()
    /// Demo data is shown: nothing here touches CloudKit or the Keychain.
    private var isDemo = PhoneDemoData.isOn

    /// Sync runs here (so "Sync now" means something).
    var isRunning: Bool { scheduler != nil }

    // MARK: Launch

    /// Called once the database is open: checks the iCloud account, then starts sync if this launch may.
    func attach(_ environment: PhoneEnvironment) async {
        guard dbQueue == nil, !environment.isDemo, !isDemo else { return }
        dbQueue = environment.dbQueue
        checkAccount()
        if let refusal = Self.refusal(databasePath: environment.databasePath, canUseCloudKit: canUseCloudKit,
                                      demoModeOn: PhoneDemoData.isOn) {
            Self.log.info("Sync is off on this iPhone: \(refusal, privacy: .public)")
            return
        }
        let demo = PhoneSyncDemoMode.isRequested
        let keyStore = KeychainSyncKeyStore(container: CloudKitTransport.keyScope(demo: demo))
        if demo { PhoneSyncDemoMode.storeHandedOverKey(in: keyStore) }
        let dbQueue = environment.dbQueue
        do {
            // A local setting: never synced, so the phone still has nothing pending.
            deviceId = try await dbQueue.write { db in try LocalSetting.phoneDeviceId(db) }
        } catch {
            Self.log.error("Sync is off: the device id couldn't be kept (\(String(describing: type(of: error)), privacy: .public))")
            return
        }
        self.keyStore = keyStore
        if canUseCloudKit, accountWatch == nil {
            accountWatch = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.iCloudAccountChanged() }
            }
        }
        // The household's zone starts at once; this iPhone's iCloud user is read beside it (and again on a later
        // idle sync or a return to the foreground until it is known), and its private zone joins once named.
        await startEngine(viewer: .none)
        readViewerRecordName()
    }

    /// Asks CloudKit for this iPhone's iCloud user's record name, one ask at a time, until it is known; then checks it
    /// against the user this device's data was synced for, and follows the viewer if the household already names it.
    /// No account, or no answer: the household's data only for now (or, after an account change, no sync yet).
    private func readViewerRecordName() {
        guard viewerRecordName == nil, !readingRecordName, scheduler != nil || awaitingICloudUser, !isDemo else { return }
        readingRecordName = true
        let generation = identityGeneration
        Task { [weak self] in
            let recordName = try? await CloudKitAccountStatus.userRecordName()
            guard let self, generation == self.identityGeneration else { return }
            self.readingRecordName = false
            guard let recordName, !self.isDemo, self.keyStore != nil else { return }
            await self.iCloudUserRead(recordName, generation: generation)
        }
    }

    /// This iPhone's iCloud user is `recordName`: `SyncAccountSwitch.apply` (a different user than the data's drops the
    /// private zones here, with the engine stopped so nothing pulls into them meanwhile), then the engine runs again
    /// for it when it was stopped, and follows the viewer.
    private func iCloudUserRead(_ recordName: String, generation: Int) async {
        guard let dbQueue else { return }
        let stored = (try? await dbQueue.read { db in try SyncAccountSwitch.stored(db: db) }) ?? nil
        let switching = stored != nil && stored != recordName
        if switching { await stopEngine() }
        guard generation == identityGeneration else { return }
        do {
            let action = try await dbQueue.write { db in try SyncAccountSwitch.apply(current: recordName, db: db) }
            if action == .dropPrivate {
                // Its keys stay in the Keychain: they are the signed-in user's iCloud Keychain now, and removing one
                // there would remove it from that user's other devices too. Without the data they open nothing here.
                Self.log.notice("Sync: this iPhone's iCloud user changed; the previous user's private data was removed from it")
            }
        } catch {
            Self.log.error("Sync: the iCloud user couldn't be checked (\(String(describing: type(of: error)), privacy: .public)); sync waits")
            if switching { awaitingICloudUser = true }
            return
        }
        guard generation == identityGeneration, !isDemo else { return }
        viewerRecordName = recordName
        if switching || awaitingICloudUser || scheduler == nil {
            awaitingICloudUser = false
            await startEngine(viewer: .none)
        }
        await followViewer()
    }

    /// The iCloud account changed (`CKAccountChanged`): sync stops, and starts again (with a new transport) once the
    /// signed-in user's record name is read and checked. Nothing is dropped until then.
    private func iCloudAccountChanged() async {
        guard dbQueue != nil, keyStore != nil, !isDemo else { return }
        Self.log.notice("Sync: the iCloud account changed; waiting for the signed-in user")
        identityGeneration += 1
        readingRecordName = false
        awaitingICloudUser = true
        viewerRecordName = nil
        await stopEngine()
        checkAccount()
        readViewerRecordName()
    }

    /// Stops the running scheduler (if any): nothing more is pulled until `startEngine`.
    private func stopEngine() async {
        engineGeneration += 1
        statusTask?.cancel()
        statusTask = nil
        engineViewer = .none
        if let running = scheduler {
            scheduler = nil
            await running.stop()
        }
    }

    /// Makes the read-only engine for `viewer`'s zones and its scheduler (stopping one already running), then asks
    /// for a sync. One at a time: a newer call (or demo data going on) supersedes one still stopping the old
    /// scheduler, so no scheduler is ever left running unowned.
    private func startEngine(viewer: SyncViewer) async {
        guard let dbQueue, let keyStore, let deviceId, !isDemo else { return }
        engineGeneration += 1
        let mine = engineGeneration
        statusTask?.cancel()
        statusTask = nil
        if let running = scheduler {
            scheduler = nil
            await running.stop()
        }
        guard mine == engineGeneration, !isDemo else { return }
        engineViewer = viewer
        // A member device (step 7a) reaches the household in its owner's zone through its shared database; every other
        // zone, and every zone of the admin's devices, is in its own private database. A new transport each time: it
        // keeps the iCloud user it first reads.
        let owner = (try? await dbQueue.read { db in try SyncHouseholdMembership.current(db: db) }) ?? nil
        guard mine == engineGeneration, !isDemo else { return }
        let transport: any SyncTransport
        if let owner {
            let container = CKContainer(identifier: CloudKitTransport.containerIdentifier)
            transport = SyncZoneSplitTransport(household: CloudKitTransport(database: container.sharedCloudDatabase, zoneOwnerName: owner),
                                               others: CloudKitTransport())
        } else {
            transport = CloudKitTransport()
        }
        let engine = SyncEngineCore(db: dbQueue, transport: transport,
                                    device: SyncDevice(id: deviceId, name: UIDevice.current.name),
                                    keyStore: keyStore, documents: nil, readOnly: true, viewer: viewer,
                                    householdIsShared: owner != nil)
        let scheduler = SyncScheduler(engine: engine, db: dbQueue)
        self.scheduler = scheduler
        await scheduler.start()
        // Superseded while starting: the newer call has taken this scheduler off and stops it.
        guard mine == engineGeneration, self.scheduler === scheduler else { return }
        statusTask = Task { [weak self] in
            for await status in await scheduler.statusStream() {
                await self?.statusChanged(status)
            }
        }
        Task { await scheduler.requestSync(.launch) }
    }

    /// Follows the viewer (`followViewerIfNamed`), one check at a time.
    private func followViewer() async {
        guard !followingViewer else { return }
        followingViewer = true
        await followViewerIfNamed()
        followingViewer = false
    }

    /// After a pull: if the household has now named this iPhone's iCloud user, the engine is made again with its
    /// private zone (household, then the viewer's own).
    private func followViewerIfNamed() async {
        guard engineViewer == .none, let recordName = viewerRecordName, let dbQueue, !isDemo else { return }
        guard let viewer = try? await dbQueue.read({ db in try SyncViewer.forCloudKitUser(recordName: recordName, db: db) }),
              viewer != .none else { return }
        Self.log.info("Sync: this iPhone's person is known; its private zone joins the household's")
        await startEngine(viewer: viewer)
    }

    /// Why this launch can't sync, or nil: `SyncActivation`'s rules, and the database opened must be the one
    /// `BUDGET_DB_PATH` names (a device build ignores the variable and opens its own, which is refused here).
    nonisolated static func refusal(databasePath: String, canUseCloudKit: Bool, demoModeOn: Bool,
                                    environment: [String: String] = ProcessInfo.processInfo.environment,
                                    arguments: [String] = CommandLine.arguments) -> String? {
        let isSyncDemoLaunch = arguments.contains(SyncActivation.demoArgument)
        // Demo data never syncs, whatever else holds.
        let demoRefusal = PhoneDemoMode.syncRefusal(databasePath: databasePath, demoModeOn: demoModeOn, isSyncDemoLaunch: isSyncDemoLaunch)
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        let decision = SyncActivation.phoneDecision(isDemoData: demoRefusal != nil, isSyncDemoLaunch: isSyncDemoLaunch,
                                                    hasCloudKitEntitlement: canUseCloudKit, isDebug: isDebug,
                                                    databasePath: environment["BUDGET_DB_PATH"])
        if let demoRefusal { return demoRefusal }
        guard decision.allowed else { return decision.reason ?? "refused" }
        if isSyncDemoLaunch {
            guard let named = environment["BUDGET_DB_PATH"],
                  TaxRegression.resolvedPath(named) == TaxRegression.resolvedPath(databasePath) else {
                return "\(SyncActivation.demoArgument): the database this iPhone opened isn't BUDGET_DB_PATH's."
            }
        }
        return nil
    }

    // MARK: Demo data

    /// Demo data goes on: a running sync stops, and everything sync showed is cleared. Nothing reaches CloudKit or
    /// the Keychain until `leaveDemo()`.
    func enterDemo() async {
        isDemo = true
        engineGeneration += 1
        accountCheck?.cancel()
        accountCheck = nil
        accountGeneration += 1
        statusTask?.cancel()
        statusTask = nil
        let running = scheduler
        scheduler = nil
        if let running { await running.stop() }
        keyStore = nil
        deviceId = nil
        engineViewer = .none
        viewerRecordName = nil
        awaitingICloudUser = false
        identityGeneration += 1
        readingRecordName = false
        householdNotice = nil
        dbQueue = nil
        status = .off
        lastSync = nil
        isFirstDownload = false
        downloadedRecords = 0
        keyHeld = nil
        account = .unknown
    }

    /// Demo data was left: the next `attach` (the phone's own database) may sync again.
    func leaveDemo() {
        isDemo = false
    }

    // MARK: Scene

    /// The scene is active again: after a spell in the background, the account is checked and a sync asked for.
    func sceneBecameActive() {
        guard wentToBackground else { return }
        wentToBackground = false
        guard !isDemo else { return }
        checkAccount()
        readViewerRecordName()
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
        guard !isDemo else { return }
        self.status = status
        guard let scheduler, let dbQueue else { return }
        lastSync = await scheduler.lastSync
        downloadedRecords = await scheduler.receivedRecords
        if let pulled = try? await dbQueue.read({ db in try SyncEngineCore.hasChangeToken(db: db) }) {
            isFirstDownload = !pulled
        }
        if case .syncing = status { return }
        if await scheduler.leftHousehold {
            // Not inside the status loop: stopping the engine ends that loop.
            Task { [weak self] in await self?.householdLeft() }
            return
        }
        if case .idle = status, engineViewer == .none {
            if viewerRecordName == nil {
                readViewerRecordName()
            } else {
                // Not inside the status loop: making the engine again ends that loop.
                Task { [weak self] in await self?.followViewer() }
            }
        }
        if let keyStore {
            // A Keychain read, off the main actor.
            let held = await Task.detached { (try? keyStore.key(zone: SyncRecordStore.householdZone)) != nil }.value
            keyHeld = held
        }
    }

    /// This device is no longer in the household it reached through its shared database: sync stops, the household's
    /// data is dropped here and the membership forgotten (one transaction, local only), its key leaves the Keychain,
    /// the notice shows, and the engine starts again over this device's own zones.
    private func householdLeft() async {
        guard !leavingHousehold, let dbQueue, let keyStore, !isDemo else { return }
        leavingHousehold = true
        defer { leavingHousehold = false }
        await stopEngine()
        do {
            let dropped = try await dbQueue.write { db in try SyncHouseholdMembership.left(db: db) }
            Self.log.notice("Sync: no longer in the household; \(dropped, privacy: .public) records removed from this iPhone")
        } catch {
            Self.log.error("Sync: the household's data couldn't be removed (\(String(describing: type(of: error)), privacy: .public))")
            return
        }
        if let keychain = keyStore as? KeychainSyncKeyStore {
            let zone = SyncZones.household
            await Task.detached {
                for keyId in ((try? keychain.allKeys(zone: zone)) ?? [:]).keys {
                    _ = try? keychain.remove(keyId: keyId, zone: zone)
                }
            }.value
        }
        householdNotice = Self.removedNotice
        await startEngine(viewer: .none)
    }

    /// The notice was read.
    func dismissHouseholdNotice() {
        householdNotice = nil
    }

    /// Asks CloudKit for the account, one check at a time: a newer check cancels the older, whose answer is dropped
    /// (the latest wins).
    private func checkAccount() {
        guard canUseCloudKit, !isDemo else { return }
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
