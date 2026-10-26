import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 6 Task 13: what the Mac's "Turn on sync…" sheet and Settings ▸ Sync show at each stage (`SyncTurnOnFlow`), and
/// the facts the app feeds it: the opened database is Mango's own (`SyncActivation.isAppDatabase`), the signed-in
/// iCloud user against the admin's (`SyncTurnOn.iCloudUserCheck`), the Mac's device id, the backup of the open queue.
final class SyncTurnOnFlowTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SyncTurnOnFlowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func facts(_ stage: SyncTurnOn.Stage, confirmed: Bool = false, blockers: [SyncTurnOn.Blocker] = [], checked: Bool = true,
                       sent: Int = 0, total: Int = 0, status: SyncStatus = .off, refusal: String? = nil,
                       work: SyncTurnOnFlow.Work = .none) -> SyncTurnOnFlow.Facts {
        let path = stage >= .backedUp ? "/synthetic/Budget/budget.sqlite.pre-sync-backup-20261026-101500" : nil
        return SyncTurnOnFlow.Facts(progress: SyncTurnOn.Progress(stage: stage, backupPath: path, total: total, sent: sent),
                                    ownershipConfirmed: confirmed, blockers: blockers, checked: checked, syncStatus: status,
                                    syncRefusal: refusal, work: work)
    }

    /// Before anything: only Back up; owners and the upload wait; blockers listed with their copy.
    func testBeforeTheBackupOnlyBackUpIsOpen() {
        let screen = SyncTurnOnFlow.screen(facts(.notStarted, blockers: [.strayHouseholdKey, .noICloudAccount]))
        XCTAssertEqual(screen.blockerLines, [SyncTurnOn.text(.strayHouseholdKey), "Sign in to iCloud in System Settings first."])
        XCTAssertEqual(screen.backUp, .current)
        XCTAssertEqual(screen.backUpButton, "Back up now")
        XCTAssertTrue(screen.canBackUp)
        XCTAssertEqual(screen.backupLine, SyncTurnOnFlow.backUpExplanation)
        XCTAssertEqual(screen.ownership, .waiting)
        XCTAssertFalse(screen.canSetOwners, "the backup comes before any write, the owners included")
        XCTAssertEqual(screen.ownershipLine, "After the backup.")
        XCTAssertEqual(screen.upload, .waiting)
        XCTAssertTrue(screen.showsStartUpload)
        XCTAssertFalse(screen.canStartUpload)
    }

    /// A copy, the demo or a member never back up or set owners from here.
    func testNothingIsWrittenForACopyTheDemoOrAMember() {
        for blocker in [SyncTurnOn.Blocker.notAdmin, .notAppDatabase, .demoDatabase] {
            let screen = SyncTurnOnFlow.screen(facts(.backedUp, blockers: [blocker]))
            XCTAssertFalse(screen.canBackUp, "\(blocker)")
            XCTAssertFalse(screen.canSetOwners, "\(blocker)")
            XCTAssertFalse(screen.canStartUpload, "\(blocker)")
        }
    }

    func testAfterTheBackupTheOwnersAreNext() {
        let screen = SyncTurnOnFlow.screen(facts(.backedUp))
        XCTAssertEqual(screen.backUp, .done)
        XCTAssertEqual(screen.backupLine, "Backed up: budget.sqlite.pre-sync-backup-20261026-101500")
        XCTAssertEqual(screen.backUpButton, "Back up again")
        XCTAssertEqual(screen.ownership, .current)
        XCTAssertTrue(screen.canSetOwners)
        XCTAssertEqual(screen.upload, .waiting)
        XCTAssertEqual(screen.uploadLine, "After the owners are set.")
        XCTAssertFalse(screen.canStartUpload)
    }

    /// Owners saved, nothing blocks: Start upload is the only way the upload starts; any blocker, an unanswered check
    /// or work under way keeps it disabled.
    func testStartUploadOnlyWhenNothingBlocks() {
        for stage in [SyncTurnOn.Stage.backedUp, .ownershipConfirmed, .keysReady] {
            let ready = SyncTurnOnFlow.screen(facts(stage, confirmed: true))
            XCTAssertEqual(ready.ownership, .done)
            XCTAssertEqual(ready.ownershipLine, "Done")
            XCTAssertFalse(ready.canSetOwners)
            XCTAssertEqual(ready.upload, .current)
            XCTAssertTrue(ready.canStartUpload, "\(stage)")
            XCTAssertEqual(ready.uploadLine, "Nothing goes to iCloud until you press Start upload.")
        }
        XCTAssertFalse(SyncTurnOnFlow.screen(facts(.ownershipConfirmed, confirmed: true, blockers: [.strayPrivateKey])).canStartUpload)
        let unchecked = SyncTurnOnFlow.screen(facts(.ownershipConfirmed, confirmed: true, checked: false))
        XCTAssertFalse(unchecked.canStartUpload)
        XCTAssertTrue(unchecked.showsCheckAgain, "iCloud didn't answer: Check again")
        XCTAssertFalse(SyncTurnOnFlow.screen(facts(.ownershipConfirmed, confirmed: true, checked: false, work: .checking)).showsCheckAgain)
        XCTAssertFalse(SyncTurnOnFlow.screen(facts(.ownershipConfirmed, confirmed: true)).showsCheckAgain)
        let starting = SyncTurnOnFlow.screen(facts(.keysReady, confirmed: true, work: .starting))
        XCTAssertFalse(starting.canStartUpload)
        XCTAssertFalse(starting.canBackUp)
        XCTAssertEqual(starting.uploadLine, "Starting the upload…")
        // Owners confirmed before the backup (Settings ▸ Sharing): the backup still comes first.
        let early = SyncTurnOnFlow.screen(facts(.notStarted, confirmed: true))
        XCTAssertEqual(early.ownership, .waiting)
        XCTAssertFalse(early.canStartUpload)
    }

    /// Uploading: the counts, "paused" while offline, the refusal when sync can't run; no Start, no backup, no
    /// blockers; then done.
    func testUploadingShowsProgressPausedAndDone() {
        let uploading = SyncTurnOnFlow.screen(facts(.uploading, confirmed: true, blockers: [.strayHouseholdKey], sent: 1_200, total: 3_006,
                                                    status: .syncing(.pushing)))
        XCTAssertEqual(uploading.uploadLine, "Uploading 1200 of 3006 records")
        XCTAssertEqual(uploading.uploadTone, .neutral)
        XCTAssertEqual(uploading.fraction ?? 0, 1_200.0 / 3_006.0, accuracy: 1e-9)
        XCTAssertFalse(uploading.showsStartUpload)
        XCTAssertFalse(uploading.canStartUpload)
        XCTAssertFalse(uploading.canBackUp)
        XCTAssertNil(uploading.backUpButton)
        XCTAssertEqual(uploading.blockerLines, [])
        XCTAssertEqual(uploading.ownership, .done)

        let paused = SyncTurnOnFlow.screen(facts(.uploading, confirmed: true, sent: 10, total: 20, status: .offline(since: Date(), retryAt: nil)))
        XCTAssertEqual(paused.uploadLine, "Upload paused — it continues where it stopped.")
        XCTAssertEqual(paused.uploadTone, .amber)

        let refused = SyncTurnOnFlow.screen(facts(.uploading, confirmed: true, sent: 10, total: 20, refusal: SyncTurnOnFlow.differentICloudUserAtLaunch))
        XCTAssertEqual(refused.uploadLine, SyncTurnOnFlow.differentICloudUserAtLaunch)
        XCTAssertEqual(refused.uploadTone, .amber)

        let done = SyncTurnOnFlow.screen(facts(.done, confirmed: true, sent: 20, total: 20, status: .idle(lastSync: Date())))
        XCTAssertEqual(done.upload, .done)
        XCTAssertEqual(done.uploadLine, "Your data is in iCloud.")
        XCTAssertNil(done.fraction)
        XCTAssertFalse(done.showsStartUpload)
    }

    /// Settings ▸ Sync offers the sheet with no blocker or only ones the person can clear, and always once the upload began.
    func testSettingsOffersTurnOnOnlyForFixableBlockers() {
        XCTAssertTrue(SyncTurnOnFlow.offersTurnOn(stage: .notStarted, blockers: []))
        XCTAssertTrue(SyncTurnOnFlow.offersTurnOn(stage: .notStarted, blockers: [.strayHouseholdKey, .strayPrivateKey, .noICloudAccount,
                                                                                 .differentICloudUser]))
        for blocker in [SyncTurnOn.Blocker.notAdmin, .notAppDatabase, .wrongEnvironment, .noEntitlement, .demoDatabase, .syncedBefore] {
            XCTAssertFalse(SyncTurnOnFlow.offersTurnOn(stage: .backedUp, blockers: [.noICloudAccount, blocker]), "\(blocker)")
        }
        XCTAssertTrue(SyncTurnOnFlow.offersTurnOn(stage: .uploading, blockers: [.wrongEnvironment]))
    }

    /// The signed-in iCloud user against the admin's: only the same one syncs.
    func testICloudUserCheck() throws {
        XCTAssertEqual(SyncTurnOn.iCloudUserCheck(signedIn: "_a", recorded: "_a"), .matches)
        XCTAssertEqual(SyncTurnOn.iCloudUserCheck(signedIn: "_b", recorded: "_a"), .different)
        XCTAssertEqual(SyncTurnOn.iCloudUserCheck(signedIn: "_a", recorded: nil), .notRecordedYet)
        XCTAssertEqual(SyncTurnOn.iCloudUserCheck(signedIn: "_a", recorded: ""), .notRecordedYet)
        XCTAssertEqual(SyncTurnOn.iCloudUserCheck(signedIn: nil, recorded: "_a"), .unknown)
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            _ = try SharingFixture.build(db)
            XCTAssertNil(try SyncTurnOn.adminICloudUser(db: db))
            try db.execute(sql: "UPDATE appUser SET cloudKitUserRecordName = '_admin' WHERE isAdmin = 1")
            XCTAssertEqual(try SyncTurnOn.adminICloudUser(db: db), "_admin")
        }
    }

    /// Only the very file Mango opens as its own is the app's database: a copy elsewhere, or beside it under another
    /// name, isn't; a symbolic link to it is.
    func testOnlyTheAppsOwnFileIsTheAppDatabase() throws {
        let app = folder.appendingPathComponent("Budget", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let own = app.appendingPathComponent("budget.sqlite")
        try Data("x".utf8).write(to: own)
        let besideIt = app.appendingPathComponent("budget-copy.sqlite")
        try Data("x".utf8).write(to: besideIt)
        let elsewhere = folder.appendingPathComponent("budget.sqlite")
        try Data("x".utf8).write(to: elsewhere)
        let link = folder.appendingPathComponent("link.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: own)

        XCTAssertTrue(SyncActivation.isAppDatabase(openedPath: own.path, appDatabasePath: own.path))
        XCTAssertTrue(SyncActivation.isAppDatabase(openedPath: link.path, appDatabasePath: own.path))
        XCTAssertFalse(SyncActivation.isAppDatabase(openedPath: besideIt.path, appDatabasePath: own.path))
        XCTAssertFalse(SyncActivation.isAppDatabase(openedPath: elsewhere.path, appDatabasePath: own.path))
        XCTAssertFalse(SyncActivation.isAppDatabase(openedPath: nil, appDatabasePath: own.path))
        XCTAssertFalse(SyncActivation.isAppDatabase(openedPath: "budget.sqlite", appDatabasePath: own.path))
        try FileManager.default.removeItem(at: own)
        XCTAssertFalse(SyncActivation.isAppDatabase(openedPath: own.path, appDatabasePath: own.path), "no file, no database")
    }

    /// The Mac's sync device id: made once, kept with the database, separate from the phone's.
    func testMacDeviceIdIsMadeOnceAndKept() throws {
        let queue = try TestDatabase.migrated()
        let (first, second, phone) = try queue.write { db in
            (try LocalSetting.macDeviceId(db), try LocalSetting.macDeviceId(db), try LocalSetting.phoneDeviceId(db))
        }
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, phone)
        XCTAssertNotNil(UUID(uuidString: first))
    }

    /// The sheet backs up the app's open queue: the same timestamped, checked copy and stage as `backUp(manager:)`.
    func testBackUpOfTheOpenQueue() throws {
        let path = folder.appendingPathComponent("budget.sqlite").path
        let manager = try TestDatabase.migratedManager(path: path)
        try manager.dbQueue.write { db in _ = try SharingFixture.build(db) }
        let url = try SyncTurnOn.backUp(queue: manager.dbQueue, now: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertTrue(url.lastPathComponent.hasPrefix(SyncTurnOn.backupPrefix))
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertEqual(try manager.dbQueue.read { db in try SyncTurnOn.progress(db: db) }.stage, .backedUp)
        XCTAssertEqual(try manager.dbQueue.read { db in try SyncTurnOn.progress(db: db) }.backupPath, url.path)
        let copy = try DatabaseQueue(path: url.path)
        XCTAssertEqual(try copy.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM account") },
                       try manager.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM account") })
        try copy.close()
        // An in-memory queue has nowhere to put it.
        XCTAssertThrowsError(try SyncTurnOn.backUp(queue: try TestDatabase.migrated(), now: Date())) { error in
            XCTAssertEqual(error as? SyncTurnOn.TurnOnError, .notAFileDatabase)
        }
    }
}
