import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Sharing set per account (sync-ui, 2026-10-26): the turn-on confirms owners with the defaults at its start (no
/// ownership step), each account's Sharing section reads and saves its owner and level (`AccountSharing`), and the
/// admin moves an account between theirs and Joint (`SharingLevels.setOwner`), which moves its records. Synthetic data only.
final class AccountSharingTests: XCTestCase {
    private typealias Device = TwoPersonHousehold.Device
    private static let day = Date(timeIntervalSince1970: 1_790_000_000)

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("AccountSharingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func read<T>(_ queue: DatabaseQueue, _ body: (Database) throws -> T) throws -> T { try queue.read(body) }
    private func write<T>(_ queue: DatabaseQueue, _ body: (Database) throws -> T) throws -> T { try queue.write(body) }

    // MARK: A database shaped like the user's (11 accounts, 3 property-linked, one named "* Joint")

    private static let accountNames = ["Synthetic current", "Synthetic * Joint", "Synthetic savings", "Synthetic card", "Synthetic ISA",
                                       "Synthetic pension", "Synthetic euro", "Synthetic travel", "Synthetic flat rent",
                                       "Synthetic flat costs", "Synthetic flat deposit"]
    private static let propertyLinked: Set<String> = ["Synthetic flat rent", "Synthetic flat costs", "Synthetic flat deposit"]

    /// The accounts written at the schema before step 6 (no owner or level columns), then every migration run: the
    /// owner defaults to none and the level to Everything, as on the user's database.
    private func preStepSixDatabase() throws -> (manager: DatabaseManager, admin: AccessActor) {
        let path = folder.appendingPathComponent("budget.sqlite").path
        let manager = try DatabaseManager(path: path)
        try manager.migrate(upTo: "createImportWaitingFile")
        try manager.dbQueue.write { db in
            XCTAssertFalse(try db.columns(in: "account").map(\.name).contains("ownerPersonId"))
            try db.execute(sql: "INSERT INTO person(name) VALUES ('Synthetic Person A')")
            try db.execute(sql: "INSERT INTO person(name) VALUES ('Synthetic Person B')")
            try db.execute(sql: "INSERT INTO property(name, country) VALUES ('Synthetic flat', 'PT')")
            let property = db.lastInsertedRowID
            for (index, name) in Self.accountNames.enumerated() {
                try db.execute(sql: "INSERT INTO account(name, currency, kind, trackingMode, sortOrder) VALUES (?, 'gbp', 'cash', 'imported', ?)",
                               arguments: [name, index])
                if Self.propertyLinked.contains(name) {
                    try db.execute(sql: "INSERT INTO propertyAccount(propertyId, accountId, role) VALUES (?, ?, 'current')",
                                   arguments: [property, db.lastInsertedRowID])
                }
            }
        }
        try manager.migrate()
        let admin = try manager.dbQueue.write { db -> AccessActor in
            let person = try Int64.fetchOne(db, sql: "SELECT id FROM person ORDER BY id LIMIT 1")!
            var user = AppUser(personId: person, displayName: "A", isAdmin: true, createdAt: Self.day)
            try user.insert(db)
            try ActorWrite.useDefaultWriter(appUserId: nil, db: db)
            return try AccessActor.load(appUserId: user.id!, db: db)
        }
        return (manager, admin)
    }

    /// The ownership proposal on that database names all 11 accounts: the 3 property-linked at Everything, the rest at
    /// Balance only, every one the admin's (the data was never the cause of the sheet showing 3).
    func testEveryAccountOfAPreStepSixDatabaseIsProposed() throws {
        let (manager, admin) = try preStepSixDatabase()
        try read(manager.dbQueue) { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM account WHERE ownerPersonId IS NULL AND sharingLevel = 'everything'"), 11)
            let rows = try SharingSetup.proposal(admin: admin, db: db)
            XCTAssertEqual(rows.map(\.displayName), Self.accountNames)
            XCTAssertEqual(Set(rows.filter(\.isPropertyLinked).map(\.displayName)), Self.propertyLinked)
            XCTAssertTrue(rows.allSatisfy { $0.owner == .person(admin.personId) })
            XCTAssertEqual(rows.filter { $0.level == .everything }.count, 3)
            XCTAssertEqual(rows.filter { $0.level == .balanceOnly }.count, 8)
        }
    }

    // MARK: Turn on sync confirms the owners itself

    func testTheUploadsStartConfirmsOwnersWithTheDefaults() throws {
        let (manager, admin) = try preStepSixDatabase()
        try write(manager.dbQueue) { db in
            XCTAssertThrowsError(try SyncTurnOn.confirmOwnershipAtStart(admin: admin, db: db, now: Self.day), "the backup comes first") {
                XCTAssertEqual($0 as? SyncTurnOn.TurnOnError, .wrongStage(.notStarted))
            }
            XCTAssertFalse(try SharingSetup.isConfirmed(db: db))
        }
        try SyncTurnOn.backUp(manager: manager, now: Self.day)
        try write(manager.dbQueue) { db in
            let member = try AccessActor.load(appUserId: try { () throws -> Int64 in
                let person = try Int64.fetchOne(db, sql: "SELECT id FROM person ORDER BY id DESC LIMIT 1")!
                var user = AppUser(personId: person, displayName: "B", isAdmin: false, createdAt: Self.day)
                try user.insert(db)
                return user.id!
            }(), db: db)
            XCTAssertThrowsError(try SyncTurnOn.confirmOwnershipAtStart(admin: member, db: db, now: Self.day)) {
                XCTAssertEqual($0 as? SharingError, .notAdmin)
            }

            try SyncTurnOn.confirmOwnershipAtStart(admin: admin, db: db, now: Self.day)
            XCTAssertTrue(try SharingSetup.isConfirmed(db: db))
            XCTAssertEqual(try SyncTurnOn.stage(db: db), .ownershipConfirmed)
            let accounts = try Account.fetchAll(db)
            XCTAssertEqual(accounts.count, 11)
            XCTAssertTrue(accounts.allSatisfy { $0.ownerPersonId == admin.personId })
            for account in accounts {
                XCTAssertEqual(account.sharingLevel, Self.propertyLinked.contains(account.name) ? .everything : .balanceOnly, account.name)
            }

            // Owners and levels set since are kept: a second start changes nothing.
            let joint = accounts.first { $0.name == "Synthetic * Joint" }!.id!
            try SharingLevels.setOwner(.joint, level: .everything, accountId: joint, actor: admin, db: db)
            let card = accounts.first { $0.name == "Synthetic card" }!.id!
            try SharingLevels.set(.categoryTotals, accountId: card, actor: admin, db: db)
            try SyncTurnOn.confirmOwnershipAtStart(admin: admin, db: db, now: Self.day)
            XCTAssertNil(try Account.fetchOne(db, key: joint)?.ownerPersonId)
            XCTAssertEqual(try Account.fetchOne(db, key: card)?.sharingLevel, .categoryTotals)
        }
    }

    /// The sheet has two steps: once backed up, Start upload is the next thing (the owners no longer gate it).
    func testTheSheetGoesFromBackUpToUpload() {
        func facts(_ stage: SyncTurnOn.Stage, work: SyncTurnOnFlow.Work = .none) -> SyncTurnOnFlow.Facts {
            SyncTurnOnFlow.Facts(progress: SyncTurnOn.Progress(stage: stage, backupPath: stage >= .backedUp ? "/synthetic/b" : nil, total: 0, sent: 0),
                                 blockers: [], checked: true, syncStatus: .off, work: work)
        }
        let before = SyncTurnOnFlow.screen(facts(.notStarted))
        XCTAssertEqual(before.upload, .waiting)
        XCTAssertFalse(before.canStartUpload)
        XCTAssertEqual(before.uploadLine, SyncTurnOnFlow.uploadWaiting)
        let ready = SyncTurnOnFlow.screen(facts(.backedUp))
        XCTAssertEqual(ready.backUp, .done)
        XCTAssertEqual(ready.upload, .current)
        XCTAssertTrue(ready.canStartUpload)
        XCTAssertEqual(ready.uploadLine, SyncTurnOnFlow.uploadExplanation)
        XCTAssertFalse(SyncTurnOnFlow.sheetNote.contains("owns"), "the sheet no longer asks who owns each account")
    }

    // MARK: The account's Sharing section

    /// Before the owners are confirmed the section shows the defaults the upload would confirm; the admin's Save
    /// confirms them all, then this account's choice.
    func testSavingAnAccountsSharingBeforeConfirmationConfirmsTheDefaultsFirst() throws {
        let (manager, admin) = try preStepSixDatabase()
        try write(manager.dbQueue) { db in
            let joint = try Account.filter(Column("name") == "Synthetic * Joint").fetchOne(db)!.id!
            let flat = try Account.filter(Column("name") == "Synthetic flat rent").fetchOne(db)!.id!
            let state = try AccountSharing.load(accountId: joint, actor: admin, db: db)
            XCTAssertEqual(state.owner, .person(admin.personId))
            XCTAssertEqual(state.level, .balanceOnly)
            XCTAssertTrue(state.canChangeOwner)
            XCTAssertTrue(state.canChangeLevel)
            XCTAssertEqual(try AccountSharing.load(accountId: flat, actor: admin, db: db).level, .everything)

            try AccountSharing.apply(owner: .joint, level: .everything, accountId: joint, actor: admin, db: db, now: Self.day)
            XCTAssertTrue(try SharingSetup.isConfirmed(db: db))
            XCTAssertNil(try Account.fetchOne(db, key: joint)?.ownerPersonId)
            XCTAssertEqual(try Account.filter(Column("ownerPersonId") == admin.personId).fetchCount(db), 10)
            let after = try AccountSharing.load(accountId: joint, actor: admin, db: db)
            XCTAssertEqual(after.owner, .joint)
            XCTAssertFalse(after.canChangeLevel, "a joint account is always Everything")
            XCTAssertTrue(after.canChangeOwner, "the admin can make it theirs again")
        }
    }

    /// Only the owner changes a level, only the admin changes an owner, only between theirs and Joint; joint is
    /// Everything; nobody gives an account to another person (step 7).
    func testOwnerChangeRules() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            let memberUser = try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE personId = ?", arguments: [f.personB])!
            let member = try AccessActor.load(appUserId: memberUser, db: db)

            XCTAssertThrowsError(try SharingLevels.setOwner(.joint, level: .everything, accountId: f.privateAccount, actor: member, db: db)) {
                XCTAssertEqual($0 as? SharingError, .notAdmin)
            }
            XCTAssertThrowsError(try SharingLevels.setOwner(.person(f.personB), level: .everything, accountId: f.privateAccount, actor: f.admin, db: db)) {
                XCTAssertEqual($0 as? SharingError, .ownerMustBeAdminOrJoint)
            }
            XCTAssertThrowsError(try SharingLevels.setOwner(.person(f.personB), level: .everything, accountId: f.joint, actor: f.admin, db: db)) {
                XCTAssertEqual($0 as? SharingError, .ownerMustBeAdminOrJoint)
            }
            XCTAssertThrowsError(try SharingLevels.setOwner(.joint, level: .balanceOnly, accountId: f.privateAccount, actor: f.admin, db: db)) {
                XCTAssertEqual($0 as? SharingError, .jointMustBeEverything)
            }
            XCTAssertEqual(try Account.fetchOne(db, key: f.privateAccount)?.ownerPersonId, f.personA, "nothing written")

            let state = try AccountSharing.load(accountId: f.privateAccount, actor: member, db: db)
            XCTAssertFalse(state.canChangeOwner)
            XCTAssertFalse(state.canChangeLevel)

            // The area map: the admin's owner change is allowed, anyone else's denied, a joint below Everything denied.
            func decision(before: Int64?, after: Int64?, level: SharingLevel) throws -> AccessDecision {
                try AccessAreaMap.area(table: "account", origin: .edit,
                                       change: .update(before: ["ownerPersonId": before.map(SyncValue.int) ?? .null, "sharingLevel": .string("balanceOnly")]),
                                       changedFields: ["ownerPersonId", "sharingLevel"],
                                       row: ["ownerPersonId": after.map(SyncValue.int) ?? .null, "sharingLevel": .string(level.rawValue)], db: db)
            }
            XCTAssertTrue(try AccessPolicy.allows(f.admin, try decision(before: f.personA, after: nil, level: .everything), db: db))
            XCTAssertTrue(try AccessPolicy.allows(f.admin, try decision(before: nil, after: f.personA, level: .balanceOnly), db: db))
            XCTAssertFalse(try AccessPolicy.allows(member, try decision(before: f.personA, after: nil, level: .everything), db: db))
            XCTAssertEqual(try decision(before: f.personA, after: nil, level: .balanceOnly), .denied)
            XCTAssertEqual(try decision(before: f.personA, after: f.personB, level: .everything), .denied)
            XCTAssertEqual(try decision(before: nil, after: f.personB, level: .everything), .denied)
        }
    }

    /// The preview of a change in the section: the records it moves (an owner change counted like a level change),
    /// whether it lowers, what blocks it.
    func testPreviewCountsAnOwnerChange() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let f = try SharingFixture.build(db)
            let toJoint = try AccountSharing.preview(accountId: f.privateAccount, owner: .joint, level: .everything, db: db)
            XCTAssertFalse(toJoint.isLowering)
            XCTAssertTrue(toJoint.blockers.isEmpty)
            XCTAssertEqual(toJoint.affectedCount, try SharingLevels.affectedCount(accountId: f.privateAccount, to: .everything, db: db))
            XCTAssertGreaterThan(toJoint.affectedCount, 0)
            let toMine = try AccountSharing.preview(accountId: f.joint, owner: .person(f.personA), level: .balanceOnly, db: db)
            XCTAssertTrue(toMine.isLowering)
            XCTAssertGreaterThan(toMine.affectedCount, 0)
            let hidden = try AccountSharing.preview(accountId: f.lisbon, owner: .person(f.personA), level: .hidden, db: db)
            XCTAssertFalse(hidden.blockers.isEmpty)
            let same = try AccountSharing.preview(accountId: f.shared, owner: .person(f.personA), level: .everything, db: db)
            XCTAssertEqual(same.affectedCount, 0)
        }
    }

    // MARK: Moving records on an owner change (two people, lossy Macs, audited)

    private func count(_ device: Device, _ sql: String, _ arguments: StatementArguments = []) throws -> Int {
        try device.db.read { db in try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0 }
    }

    private func syncEveryone(_ h: TwoPersonHousehold) async throws {
        for _ in 1...2 {
            _ = try await h.adminMac.engine.syncNow()
            _ = try await h.adminMac2.engine.syncNow()
        }
        _ = try await h.adminPhone.engine.pull()
        _ = try await h.memberDevice.engine.pull()
    }

    private func assertAuditsClean(_ h: TwoPersonHousehold, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(h.audit.householdViolations(router: h.adminRouter()), [], "Mac and phone", file: file, line: line)
        XCTAssertEqual(h.audit2.householdViolations(router: TwoPersonHousehold.router(h.adminMac2.db)), [], "Mac 2", file: file, line: line)
        XCTAssertEqual(h.memberAudit.householdViolations(router: TwoPersonHousehold.router(h.memberDevice.db)), [], "member", file: file, line: line)
    }

    private func transactionUuids(_ h: TwoPersonHousehold, account: Int64) throws -> [String] {
        try h.adminMac.db.read { db in
            try String.fetchAll(db, sql: """
                SELECT s.uuid FROM transaction_ t JOIN syncRecord s ON s.tableName = 'transaction_' AND s.localId = t.id
                WHERE t.accountId = ? ORDER BY t.id
                """, arguments: [account])
        }
    }

    private func held(_ uuids: [String], on device: Device) throws -> Int {
        try device.db.read { db in
            try uuids.filter { try SyncRecordStore.localId(table: "transaction_", uuid: $0, db: db) != nil }.count
        }
    }

    private func zones(_ uuids: [String], on device: Device) throws -> Set<String> {
        try device.db.read { db in
            Set(try uuids.compactMap { try String.fetchOne(db, sql: "SELECT zone FROM syncRecord WHERE uuid = ?", arguments: [$0]) })
        }
    }

    func testMineToJointMovesTheRecordsToTheHouseholdForTheMember() async throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        try await syncEveryone(h)
        let all = try transactionUuids(h, account: f.privateAccount)
        XCTAssertLessThan(try held(all, on: h.memberDevice), all.count, "the member holds only its property money before")

        try write(h.adminMac.db) { db in try SharingLevels.setOwner(.joint, level: .everything, accountId: f.privateAccount, actor: f.admin, db: db) }
        try await syncEveryone(h)

        XCTAssertEqual(try held(all, on: h.memberDevice), all.count, "the member reads every transaction of the account")
        let memberAccount = try XCTUnwrap(try h.localId("account", uuid: try h.uuid("account", f.privateAccount), on: h.memberDevice))
        XCTAssertEqual(try count(h.memberDevice, "SELECT COUNT(*) FROM account WHERE id = ? AND ownerPersonId IS NULL AND sharingLevel = 'everything'",
                                 [memberAccount]), 1, "the member sees it as joint")
        XCTAssertEqual(try zones(all, on: h.adminMac), [SyncZones.household])
        XCTAssertEqual(try count(h.adminMac, "SELECT COUNT(*) FROM syncPending"), 0)
        assertAuditsClean(h)
    }

    func testJointToMineMovesTheRecordsPrivate() async throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        try await syncEveryone(h)
        let all = try transactionUuids(h, account: f.joint)
        XCTAssertEqual(try held(all, on: h.memberDevice), all.count)

        try write(h.adminMac.db) { db in try SharingLevels.setOwner(.person(f.personA), level: .balanceOnly, accountId: f.joint, actor: f.admin, db: db) }
        try await syncEveryone(h)

        XCTAssertEqual(try held(all, on: h.memberDevice), 0, "the member no longer holds them")
        XCTAssertEqual(try zones(all, on: h.adminMac), [f.privateZone])
        XCTAssertEqual(try held(all, on: h.adminPhone), all.count, "the admin's phone keeps them")
        XCTAssertEqual(try count(h.adminMac, "SELECT COUNT(*) FROM syncPending"), 0)
        assertAuditsClean(h)
    }

    // MARK: The sidebar's sync row

    func testSidebarSyncRow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let uploading = SyncTurnOn.Progress(stage: .uploading, backupPath: nil, total: 3_006, sent: 1_248)
        let done = SyncTurnOn.Progress(stage: .done, backupPath: nil, total: 3_006, sent: 3_006)
        typealias Row = SyncSidebarStatus

        XCTAssertNil(Row.make(isRunning: false, status: .off, progress: nil, refusal: nil), "sync off: nothing shown")
        XCTAssertEqual(Row.make(isRunning: false, status: .off, progress: uploading, refusal: SyncTurnOnFlow.iCloudUserUnknown), .attention)
        XCTAssertEqual(Row.make(isRunning: true, status: .syncing(.pushing), progress: uploading, refusal: nil), .syncing(sent: 1_248, total: 3_006))
        XCTAssertEqual(Row.make(isRunning: true, status: .idle(lastSync: now), progress: uploading, refusal: nil), .syncing(sent: 1_248, total: 3_006),
                       "the first upload between pushes is still syncing")
        XCTAssertEqual(Row.make(isRunning: true, status: .syncing(.pulling), progress: done, refusal: nil), .syncing(sent: nil, total: nil))
        XCTAssertEqual(Row.make(isRunning: true, status: .idle(lastSync: now), progress: done, refusal: nil), .synced(now))
        XCTAssertEqual(Row.make(isRunning: true, status: .offline(since: now, retryAt: nil), progress: uploading, refusal: nil), .paused)
        XCTAssertEqual(Row.make(isRunning: true, status: .waitingForKey(since: now), progress: done, refusal: nil), .paused)
        for status in [SyncStatus.failed(reason: "database"), .needsAttention(held: 2, lastSync: now), .unavailable(.noICloudAccount)] {
            XCTAssertEqual(Row.make(isRunning: true, status: status, progress: done, refusal: nil), .attention, "\(status)")
        }

        XCTAssertEqual(Row.syncing(sent: 1_248, total: 3_006).text(now: now), "Syncing…")
        XCTAssertEqual(Row.syncing(sent: 1_248, total: 3_006).detail, "1,248 of 3,006")
        XCTAssertEqual(Row.syncing(sent: 1_248, total: 3_006).fraction ?? 0, 1_248.0 / 3_006.0, accuracy: 1e-9)
        XCTAssertNil(Row.syncing(sent: nil, total: nil).detail)
        XCTAssertEqual(Row.synced(now.addingTimeInterval(-120)).text(now: now), "Synced 2 minutes ago")
        XCTAssertEqual(Row.paused.text(now: now), "Sync paused")
        XCTAssertEqual(Row.attention.text(now: now), "Sync needs attention")
        XCTAssertTrue(Row.attention.opensSettings)
        XCTAssertFalse(Row.paused.opensSettings)
    }
}
