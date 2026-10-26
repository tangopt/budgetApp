import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 6 Task 8: a level change queues exactly the records whose placement it changes (no data row written, no
/// field clock moved), and the push moves them between zones with markers over the old copies. Every test runs over
/// `TwoPersonHousehold` (the Macs through `LossyTransport`), on both of the admin's writer Macs, the admin's phone
/// and the member's device, and ends with every device's zone audit (append-only) clean.
final class SharingLevelChangeTests: XCTestCase {
    private typealias Device = TwoPersonHousehold.Device

    /// Synchronous access (async tests would otherwise pick GRDB's async overloads).
    private func read<T>(_ device: Device, _ body: (Database) throws -> T) throws -> T { try device.db.read(body) }
    private func write<T>(_ device: Device, _ body: (Database) throws -> T) throws -> T { try device.db.write(body) }

    private func count(_ device: Device, _ sql: String, _ arguments: StatementArguments = []) throws -> Int {
        try read(device) { db in try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0 }
    }

    /// Both Macs sync (twice, so each takes the other's work), then the phone and the member pull.
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

    /// Both Macs are settled: nothing pending, no move unfinished, no needs-attention line.
    private func assertSettled(_ h: TwoPersonHousehold, file: StaticString = #filePath, line: UInt = #line) throws {
        for (name, device) in [("Mac", h.adminMac), ("Mac 2", h.adminMac2)] {
            XCTAssertEqual(try count(device, "SELECT COUNT(*) FROM syncPending"), 0, "\(name): nothing pending", file: file, line: line)
            XCTAssertEqual(try read(device) { db in try SyncZoneMoves.unfinished(db: db) }, [], "\(name): no unfinished move", file: file, line: line)
            XCTAssertEqual(try count(device, "SELECT COUNT(*) FROM syncConflict WHERE losingValueJSON LIKE '%needs attention%'"), 0,
                           "\(name): nothing needs attention", file: file, line: line)
        }
        for (name, device) in [("phone", h.adminPhone), ("member", h.memberDevice)] {
            XCTAssertEqual(try count(device, "SELECT COUNT(*) FROM syncStaging"), 0, "\(name): nothing staged", file: file, line: line)
        }
    }

    /// The record `name` as the server holds it in `zone`, opened with `keys`.
    private func stored(_ h: TwoPersonHousehold, _ name: String, in zone: String, keys: InMemorySyncKeyStore? = nil) async throws -> SyncPayload? {
        guard let record = try await h.cloud.fetch(name, zone: zone) else { return nil }
        return try SyncLargePayload.payload(from: record.wire, keys: try (keys ?? h.adminKeys).allKeys(zone: zone))
    }

    /// The Mac's UUIDs of the account's transactions.
    private func transactionUuids(_ h: TwoPersonHousehold, account: Int64) throws -> [String] {
        try read(h.adminMac) { db in
            try String.fetchAll(db, sql: """
                SELECT s.uuid FROM transaction_ t JOIN syncRecord s ON s.tableName = 'transaction_' AND s.localId = t.id
                WHERE t.accountId = ? ORDER BY t.id
                """, arguments: [account])
        }
    }

    /// How many of `uuids` the device holds as transactions.
    private func held(_ uuids: [String], on device: Device) throws -> Int {
        try read(device) { db in
            try uuids.filter { try SyncRecordStore.localId(table: "transaction_", uuid: $0, db: db) != nil }.count
        }
    }

    /// The admin's actor on a device (by the app user's UUID).
    private func adminActor(_ h: TwoPersonHousehold, on device: Device) throws -> AccessActor {
        let user = try h.uuid("appUser", h.fixture.admin.appUserId)
        return try read(device) { db in
            try AccessActor.load(appUserId: try XCTUnwrap(try SyncRecordStore.localId(table: "appUser", uuid: user, db: db)), db: db)
        }
    }

    private func localAccount(_ h: TwoPersonHousehold, _ account: Int64, on device: Device) throws -> Int64 {
        let uuid = try h.uuid("account", account)
        return try XCTUnwrap(try h.localId("account", uuid: uuid, on: device))
    }

    /// Row counts of every synced table.
    private func rowCounts(_ device: Device) throws -> [String: Int] {
        try read(device) { db in
            var counts: [String: Int] = [:]
            for table in SyncSchema.tables {
                counts[table.name] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(SyncChangeTracker.quoted(table.name))") ?? 0
            }
            return counts
        }
    }

    /// Every server record of a synced table that holds a readable copy (not a marker), by record name, to
    /// the zones holding one.
    private func readableCopies(_ h: TwoPersonHousehold) async throws -> [String: [String]] {
        var copies: [String: [String]] = [:]
        for wire in await h.cloud.storedRecords()
        where SyncSchema.table(wire.recordType) != nil {
            let keys = wire.zone == h.memberZone ? h.memberKeys : h.adminKeys
            let payload = try SyncLargePayload.payload(from: wire, keys: try keys.allKeys(zone: wire.zone))
            if payload.movedTo == nil { copies[wire.recordName, default: []].append(wire.zone) }
        }
        return copies
    }

    // MARK: The brief's tests

    func testLoweringMovesRecordsOutOfHouseholdAndMemberDropsThem() async throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        try await syncEveryone(h)
        let moved = try transactionUuids(h, account: f.shared)
        XCTAssertEqual(moved.count, 2)
        XCTAssertEqual(try held(moved, on: h.memberDevice), 2, "the member holds Shared's transactions before")

        try write(h.adminMac) { db in _ = try SharingLevels.set(.balanceOnly, accountId: f.shared, actor: f.admin, db: db) }
        try await syncEveryone(h)

        let memberShared = try localAccount(h, f.shared, on: h.memberDevice)
        XCTAssertEqual(try count(h.memberDevice, "SELECT COUNT(*) FROM transaction_ WHERE accountId = ?", [memberShared]), 0,
                       "the member's device holds none of the account's transactions")
        XCTAssertEqual(try count(h.memberDevice, "SELECT COUNT(*) FROM importBatch WHERE accountId = ?", [memberShared]), 0, "nor its batches")
        XCTAssertEqual(try held(moved, on: h.memberDevice), 0)
        for uuid in moved {
            let household = try await stored(h, uuid, in: SyncZones.household)
            XCTAssertEqual(household?.movedTo, f.privateZone, "the household holds only a marker")
            XCTAssertEqual(household?.fields.isEmpty, true)
            let privateCopy = try await stored(h, uuid, in: f.privateZone)
            XCTAssertNil(privateCopy?.movedTo)
            XCTAssertEqual(privateCopy?.fields.isEmpty, false, "A's zone holds the record")
        }
        for device in [h.adminMac, h.adminMac2, h.adminPhone] {
            XCTAssertEqual(try held(moved, on: device), 2, "the admin's devices keep them")
            XCTAssertEqual(try count(device, "SELECT COUNT(*) FROM syncRecord WHERE uuid IN (?, ?) AND zone = ?", [moved[0], moved[1], f.privateZone]), 2)
        }
        try assertSettled(h)
        assertAuditsClean(h)
    }

    func testRaisingMovesThemBackAndMemberGetsThem() async throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        try await syncEveryone(h)
        let all = try transactionUuids(h, account: f.privateAccount)
        let movedIds = [f.privateTransaction, f.transferIn]
        let moved = try movedIds.map { try h.uuid("transaction_", $0) }
        let propertyMoney = try h.uuid("transaction_", f.privatePropertyTransaction)
        XCTAssertEqual(try held(moved, on: h.memberDevice), 0, "private before")
        XCTAssertEqual(try held(all, on: h.memberDevice), 2, "only the property money (§10) is shared before")
        let companion = SyncZoneRouter.companionRecordName(accountUuid: try h.uuid("account", f.privateAccount))
        let companionBefore = try await h.cloud.fetch(companion, zone: f.privateZone)
        XCTAssertNotNil(companionBefore)

        try write(h.adminMac) { db in _ = try SharingLevels.set(.everything, accountId: f.privateAccount, actor: f.admin, db: db) }
        try await syncEveryone(h)

        XCTAssertEqual(try held(all, on: h.memberDevice), all.count, "the member gets every transaction of the account")
        for uuid in moved {
            let household = try await stored(h, uuid, in: SyncZones.household)
            XCTAssertNil(household?.movedTo)
            XCTAssertEqual(household?.fields.isEmpty, false, "back in the household")
            let privateCopy = try await stored(h, uuid, in: f.privateZone)
            XCTAssertEqual(privateCopy?.movedTo, SyncZones.household, "A's copy is a marker")
            XCTAssertEqual(privateCopy?.fields.isEmpty, true)
        }
        // The property money stayed in the household; it is sent again with the batch it left out, and the member's
        // copy now names the account's real batch, not the placeholder.
        let resent = try await stored(h, propertyMoney, in: SyncZones.household)
        XCTAssertNotNil(resent?.fields["importBatchId"])
        let batch = try h.uuid("importBatch", f.privateBatch)
        let memberBatch = try read(h.memberDevice) { db in
            try Int64.fetchOne(db, sql: "SELECT importBatchId FROM transaction_ WHERE id = ?",
                               arguments: [try SyncRecordStore.localId(table: "transaction_", uuid: propertyMoney, db: db)])
        }
        XCTAssertEqual(memberBatch, try h.localId("importBatch", uuid: batch, on: h.memberDevice))
        let companionAfter = try await h.cloud.fetch(companion, zone: f.privateZone)
        XCTAssertNil(companionAfter, "the account's details companion is gone")
        for device in [h.adminMac, h.adminMac2, h.adminPhone] {
            XCTAssertEqual(try held(all, on: device), all.count)
        }
        try assertSettled(h)
        assertAuditsClean(h)
    }

    func testLowerThenRaiseLeavesNoDuplicates() async throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        try await syncEveryone(h)
        let devices = [("Mac", h.adminMac), ("Mac 2", h.adminMac2), ("phone", h.adminPhone), ("member", h.memberDevice)]
        let before = try devices.map { try rowCounts($0.1) }

        // Lowered on the first Mac, raised again on the second.
        try write(h.adminMac) { db in _ = try SharingLevels.set(.balanceOnly, accountId: f.shared, actor: f.admin, db: db) }
        try await syncEveryone(h)
        XCTAssertEqual(try held(try transactionUuids(h, account: f.shared), on: h.memberDevice), 0)
        let actor = try adminActor(h, on: h.adminMac2)
        let shared2 = try localAccount(h, f.shared, on: h.adminMac2)
        try write(h.adminMac2) { db in _ = try SharingLevels.set(.everything, accountId: shared2, actor: actor, db: db) }
        try await syncEveryone(h)

        let after = try devices.map { try rowCounts($0.1) }
        for (index, device) in devices.enumerated() {
            XCTAssertEqual(after[index], before[index], "\(device.0): the same rows as before")
        }
        for (name, zones) in try await readableCopies(h) {
            XCTAssertEqual(zones.count, 1, "\(name) is readable in one zone only: \(zones)")
        }
        XCTAssertEqual(try held(try transactionUuids(h, account: f.shared), on: h.memberDevice), 2)
        try assertSettled(h)
        assertAuditsClean(h)
    }

    /// Review Focus 3: the network drops part-way through the move (after the private save, before the household
    /// marker, and at the other points). The next push finishes it: markers over every old copy, nothing duplicated,
    /// and the audit (every household save, as it was made) never saw a readable copy go up after the level dropped.
    func testInterruptedLevelChangeResumesWithoutStaleCopy() async throws {
        var finished = false
        for allowed in 0...10 {
            let h = try TwoPersonHousehold.make()
            let f = h.fixture
            try await syncEveryone(h)
            let moved = try transactionUuids(h, account: f.shared)

            try write(h.adminMac) { db in _ = try SharingLevels.set(.balanceOnly, accountId: f.shared, actor: f.admin, db: db) }
            let start = h.audit.savesByZone[SyncZones.household]?.count ?? 0
            await h.cloud.failSaveOperations(after: allowed)
            do {
                _ = try await h.adminMac.engine.pushPending()
                // Every save operation went: nothing left to interrupt.
                await h.cloud.restoreConnection()
                XCTAssertGreaterThan(allowed, 1, "a move takes more than one save operation")
                finished = true
                break
            } catch SyncTransportError.networkUnavailable {}
            // Whatever went to the household since the change is a marker over a moved record, never a readable copy.
            let keys = try h.adminKeys.allKeys(zone: SyncZones.household)
            for wire in (h.audit.savesByZone[SyncZones.household] ?? []).dropFirst(start) where moved.contains(wire.recordName) {
                let payload = try SyncLargePayload.payload(from: wire, keys: keys)
                XCTAssertEqual(payload.movedTo, f.privateZone, "\(allowed): only a marker went up for \(wire.recordName)")
                XCTAssertTrue(payload.fields.isEmpty)
            }
            // A marker lands only once the private copy is there.
            for uuid in moved {
                let household = try await stored(h, uuid, in: SyncZones.household)
                if household?.movedTo != nil {
                    let privateCopy = try await stored(h, uuid, in: f.privateZone)
                    XCTAssertEqual(privateCopy?.fields.isEmpty, false, "\(allowed): the marker went after the private save")
                }
            }

            await h.cloud.restoreConnection()
            _ = try await h.adminMac.engine.pushPending()
            for uuid in moved {
                let household = try await stored(h, uuid, in: SyncZones.household)
                XCTAssertEqual(household?.movedTo, f.privateZone, "\(allowed): the household has no readable copy")
                XCTAssertEqual(household?.fields.isEmpty, true)
                let privateCopy = try await stored(h, uuid, in: f.privateZone)
                XCTAssertEqual(privateCopy?.fields.isEmpty, false, "\(allowed)")
            }
            try await syncEveryone(h)
            XCTAssertEqual(try held(moved, on: h.memberDevice), 0, "\(allowed)")
            for (name, zones) in try await readableCopies(h) {
                XCTAssertEqual(zones.count, 1, "\(allowed): \(name) is readable in one zone only: \(zones)")
            }
            try assertSettled(h)
            assertAuditsClean(h)
        }
        XCTAssertTrue(finished, "some cut point lets the push finish: every interruption point was tried")
    }

    func testLevelChangeWritesNoDataAndKeepsFiledYears() async throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        try await syncEveryone(h)
        let summaryTables: Set<String> = ["accountBalancePoint", "accountSummaryMonth"]
        // Every synced table's rows (the account's level aside) and every field clock but the level's.
        func data(_ device: Device, skipping: Set<String> = []) throws -> [String: [[String: DatabaseValue]]] {
            try read(device) { db in try Self.dataRows(db, skipping: skipping) }
        }
        func clocks(_ device: Device) throws -> [Row] {
            try read(device) { db in
                try Row.fetchAll(db, sql: """
                    SELECT * FROM syncFieldClock WHERE NOT (tableName = 'account' AND localId = ? AND field = 'sharingLevel') ORDER BY rowid
                    """, arguments: [f.shared])
            }
        }
        let beforeData = try data(h.adminMac)
        let beforeClocks = try clocks(h.adminMac)
        let beforeData2 = try data(h.adminMac2, skipping: summaryTables)

        let change = try write(h.adminMac) { db in try SharingLevels.set(.categoryTotals, accountId: f.shared, actor: f.admin, db: db) }
        XCTAssertEqual(change, .init(from: .everything, to: .categoryTotals, isLowering: true))
        XCTAssertEqual(try data(h.adminMac), beforeData, "the level change wrote no data row but the level")
        XCTAssertEqual(try clocks(h.adminMac), beforeClocks, "and moved no field clock but the level's")
        let level = try read(h.adminMac) { db in try String.fetchOne(db, sql: "SELECT sharingLevel FROM account WHERE id = ?", arguments: [f.shared]) }
        XCTAssertEqual(level, SharingLevel.categoryTotals.rawValue)

        try await syncEveryone(h)
        XCTAssertEqual(try data(h.adminMac, skipping: summaryTables), beforeData.filter { !summaryTables.contains($0.key) },
                       "the moves wrote nothing either (only the summaries the level allows)")
        XCTAssertEqual(try data(h.adminMac2, skipping: summaryTables), beforeData2, "nor on the second Mac")
        try assertSettled(h)
        assertAuditsClean(h)

        try assertDemoFiledYearsUnchangedByLevels()
    }

    /// Every synced table's rows, the accounts' levels aside.
    private static func dataRows(_ db: Database, skipping: Set<String> = []) throws -> [String: [[String: DatabaseValue]]] {
        var tables: [String: [[String: DatabaseValue]]] = [:]
        for table in SyncSchema.tables where !skipping.contains(table.name) {
            tables[table.name] = try Row.fetchAll(db, sql: "SELECT * FROM \(SyncChangeTracker.quoted(table.name)) ORDER BY rowid").map { row in
                Dictionary(uniqueKeysWithValues: row.filter { table.name != "account" || $0.0 != "sharingLevel" })
            }
        }
        return tables
    }

    /// On the demo: every data table is byte-identical (the levels aside) after lowering and after raising each account,
    /// and so is every tax figure. The demo's tax data starts in 2023/24 (its filed years are 2023/24 and 2024/25; the
    /// 2020/21–2022/23 figures are taken but have no inputs): the byte-identical tables are what proves no input moved.
    private func assertDemoFiledYearsUnchangedByLevels() throws {
        let queue = try TestDatabase.demo()
        try queue.write { db in
            let admin = try self.confirmDemoOwnership(db)
            let filedYears = try FiledYearGuard.filedYears(db: db)
            XCTAssertFalse(filedYears.isEmpty)
            XCTAssertTrue(filedYears.isSubset(of: Set(2020...2024)), "the demo's filed years are among 2020/21–2024/25")
            let figures = try TaxFigures.snapshot(db: db, years: Array(2020...2024))
            let filed = figures.values.filter { (2020...2024).contains($0.key.startYear) }
            XCTAssertTrue(Set(filed.keys.map(\.startYear)).isSuperset(of: filedYears), "every filed year has figures")
            let owned = try Int64.fetchAll(db, sql: "SELECT id FROM account WHERE ownerPersonId IS NOT NULL ORDER BY id")
            XCTAssertGreaterThan(owned.count, 1)
            let rows = try Self.dataRows(db)
            // Every owned account to Balance only (lowering the property-linked ones), then all to Everything (raising
            // the rest), the figures taken after each round.
            for level in [SharingLevel.balanceOnly, .everything] {
                let started = Date()
                for account in owned { _ = try SharingLevels.set(level, accountId: account, actor: admin, db: db) }
                let seconds = Date().timeIntervalSince(started)
                print("SharingLevelChangeTests: \(owned.count) demo accounts set to \(level) in \(String(format: "%.3f", seconds)) s")
                XCTAssertTrue(try Self.dataRows(db) == rows, "every data table byte-identical, every account at \(level)")
                XCTAssertEqual(try FiledYearGuard.filedChanges(db: db, from: figures), [], "every account at \(level)")
                let now = try TaxFigures.snapshot(db: db, years: Array(2020...2024))
                XCTAssertEqual(now.values.filter { (2020...2024).contains($0.key.startYear) }, filed, "every account at \(level)")
            }
        }
    }

    func testSummariesAppearOnLoweringAndGoOnRaising() async throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        try await syncEveryone(h)
        let memberShared = try localAccount(h, f.shared, on: h.memberDevice)
        func summaries(_ device: Device, _ account: Int64) throws -> (points: Int, months: Int) {
            (try count(device, "SELECT COUNT(*) FROM accountBalancePoint WHERE accountId = ?", [account]),
             try count(device, "SELECT COUNT(*) FROM accountSummaryMonth WHERE accountId = ?", [account]))
        }
        XCTAssertEqual(try summaries(h.memberDevice, memberShared).points, 0)
        XCTAssertEqual(try summaries(h.memberDevice, memberShared).months, 0)

        try write(h.adminMac) { db in _ = try SharingLevels.set(.categoryTotals, accountId: f.shared, actor: f.admin, db: db) }
        XCTAssertTrue(try read(h.adminMac) { db in try AccountSummaryBuilder.isDirty(db: db) }, "the level change marks the summaries dirty")
        try await syncEveryone(h)
        let lowered = try summaries(h.memberDevice, memberShared)
        XCTAssertGreaterThan(lowered.points, 0, "the member gets the balance points")
        XCTAssertGreaterThan(lowered.months, 0, "and the category totals")
        let macLowered = try summaries(h.adminMac, f.shared)
        XCTAssertEqual(macLowered.points, lowered.points)
        XCTAssertEqual(macLowered.months, lowered.months)
        try assertSettled(h)

        try write(h.adminMac) { db in _ = try SharingLevels.set(.everything, accountId: f.shared, actor: f.admin, db: db) }
        try await syncEveryone(h)
        for device in [h.memberDevice, h.adminMac, h.adminMac2, h.adminPhone] {
            let account = try localAccount(h, f.shared, on: device)
            XCTAssertEqual(try summaries(device, account).points, 0, "raised: the summaries go")
            XCTAssertEqual(try summaries(device, account).months, 0)
        }
        XCTAssertEqual(try held(try transactionUuids(h, account: f.shared), on: h.memberDevice), 2, "the member has the transactions instead")
        try assertSettled(h)
        assertAuditsClean(h)
    }

    func testAffectedCountMatchesMoves() async throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        try await syncEveryone(h)
        let pending = { () throws -> Set<String> in
            Set(try self.read(h.adminMac) { db in try String.fetchAll(db, sql: "SELECT uuid FROM syncPending") })
        }
        XCTAssertEqual(try pending(), [])

        // Category totals to Balance only moves nothing: both keep the records in A's zone behind the same stub (only
        // the summaries change, which the owner's rebuild sees to).
        for (account, level, moves) in [(f.shared, SharingLevel.balanceOnly, true), (f.shared, .everything, true), (f.privateAccount, .everything, true),
                                        (f.privateAccount, .categoryTotals, true), (f.totals, .balanceOnly, false)] {
            let affected = try read(h.adminMac) { db in try SharingLevels.affectedCount(accountId: account, to: level, db: db) }
            XCTAssertEqual(try pending(), [], "counting writes nothing")
            XCTAssertEqual(affected > 0, moves, "account \(account) to \(level)")
            let placedBefore = try placements(h)
            try write(h.adminMac) { db in _ = try SharingLevels.set(level, accountId: account, actor: f.admin, db: db) }
            // Queued: the records placed differently, and the account itself (its level is the one data write).
            let queued = try pending()
            let placedAfter = try placements(h)
            // Summaries aside: the rebuild before the push deletes those the new level doesn't allow.
            let summaries = try read(h.adminMac) { db in
                Set(try String.fetchAll(db, sql: "SELECT uuid FROM syncRecord WHERE tableName IN ('accountBalancePoint', 'accountSummaryMonth')"))
            }
            let changed = Set(placedAfter.keys.filter { placedAfter[$0] != placedBefore[$0] }).subtracting(summaries)
            // The count is the records going to another zone ("Moves N records"); the queue also holds those only
            // resent in another form (the stub, property money leaving out its batch).
            let movedZones = changed.filter { placedBefore[$0]?.zone != placedAfter[$0]?.zone }
            XCTAssertEqual(movedZones.count, affected, "account \(account) to \(level): the count is what moves")
            XCTAssertEqual(queued, changed.union([try h.uuid("account", account)]), "account \(account) to \(level): exactly those are queued")
            XCTAssertEqual(try read(h.adminMac) { db in try SharingLevels.affectedCount(accountId: account, to: level, db: db) }, 0,
                           "nothing to move to the level it has")

            try await syncEveryone(h)
            // The records that changed zone are the ones a marker now covers in the zone they left.
            for uuid in movedZones {
                let left = try XCTUnwrap(placedBefore[uuid]?.zone)
                let marker = try await stored(h, uuid, in: left)
                XCTAssertEqual(marker?.movedTo, placedAfter[uuid]?.zone, "\(uuid) left \(left)")
            }
            try assertSettled(h)
        }
        XCTAssertEqual(try read(h.adminMac) { db in try SharingLevels.affectedCount(accountId: f.joint, to: .balanceOnly, db: db) }, 0,
                       "a joint account never moves")
        assertAuditsClean(h)
    }

    // MARK: Fix round 1: every owner device reconciles (I-1)

    /// Probe P1: the Mac lowers Shared but one moving transaction's private save keeps failing there. The second Mac
    /// pulls the level and finishes the move itself: the household ends with a marker only.
    func testASecondMacFinishesALoweringItPulled() async throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        try await syncEveryone(h)
        let moved = try h.uuid("transaction_", f.sharedTransaction)
        try write(h.adminMac) { db in _ = try SharingLevels.set(.balanceOnly, accountId: f.shared, actor: f.admin, db: db) }
        h.macTransport.failSaves(of: moved, in: f.privateZone)
        _ = try await h.adminMac.engine.pushPending()
        let before = try await stored(h, moved, in: SyncZones.household)
        XCTAssertNil(before?.movedTo, "the Mac couldn't move it")

        for _ in 1...2 { _ = try await h.adminMac2.engine.syncNow() }
        let household = try await stored(h, moved, in: SyncZones.household)
        XCTAssertEqual(household?.movedTo, f.privateZone, "the second Mac moved it: a marker only")
        XCTAssertEqual(household?.fields.isEmpty, true)
        let privateCopy = try await stored(h, moved, in: f.privateZone)
        XCTAssertEqual(privateCopy?.fields.isEmpty, false)
        XCTAssertEqual(try read(h.adminMac2) { db in try String.fetchOne(db, sql: "SELECT zone FROM syncRecord WHERE uuid = ?", arguments: [moved]) },
                       f.privateZone)
        XCTAssertEqual(try count(h.adminMac2, "SELECT COUNT(*) FROM syncPending WHERE uuid = ?", [moved]), 0)

        h.macTransport.restore()
        try await syncEveryone(h)
        XCTAssertEqual(try held([moved], on: h.memberDevice), 0)
        for (name, zones) in try await readableCopies(h) {
            XCTAssertEqual(zones.count, 1, "\(name) is readable in one zone only: \(zones)")
        }
        try assertSettled(h)
        assertAuditsClean(h)
    }

    /// A level written without `SharingLevels.set` (a tool, a restore): the next push moves the records.
    func testALevelWrittenWithoutSetMovesOnThePush() async throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        try await syncEveryone(h)
        let moved = try transactionUuids(h, account: f.shared)
        try write(h.adminMac) { db in
            try db.execute(sql: "UPDATE account SET sharingLevel = ? WHERE id = ?", arguments: [SharingLevel.balanceOnly.rawValue, f.shared])
        }
        try await syncEveryone(h)
        for uuid in moved {
            let household = try await stored(h, uuid, in: SyncZones.household)
            XCTAssertEqual(household?.movedTo, f.privateZone)
            XCTAssertEqual(household?.fields.isEmpty, true)
        }
        XCTAssertEqual(try held(moved, on: h.memberDevice), 0)
        try assertSettled(h)
        assertAuditsClean(h)
    }

    /// With nothing stored of the levels records were placed by (an upgrade, a restore), the push queues only the
    /// records not where they now go, then remembers the levels.
    func testWithNoStoredLevelsOnlyMisplacedRecordsAreQueued() async throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        try await syncEveryone(h)
        let moved = Set(try transactionUuids(h, account: f.shared))
        try write(h.adminMac) { db in
            try db.execute(sql: "UPDATE account SET sharingLevel = ? WHERE id = ?", arguments: [SharingLevel.balanceOnly.rawValue, f.shared])
            try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: [SyncZoneMoves.placedLevelsKey])
            try db.execute(sql: "DELETE FROM syncPending")
        }
        let queued = try write(h.adminMac) { db -> Set<String> in
            let owner = try XCTUnwrap(try SyncRecordStore.localId(table: "person", uuid: f.personAUuid, db: db))
            try SyncZoneMoves.reconcile(owner: owner, zones: [SyncZones.household, f.privateZone], db: db, now: Date())
            XCTAssertNotNil(try SyncZoneMoves.storedFacts(db: db), "the levels are remembered")
            return Set(try String.fetchAll(db, sql: "SELECT uuid FROM syncPending"))
        }
        // Misplaced: not where they go now; plus those placed in a reduced form (stubs, property money), whose last
        // sent form can't be told here.
        let misplaced = try read(h.adminMac) { db -> Set<String> in
            let router = try SyncZoneRouter(db: db)
            return Set(try Row.fetchAll(db, sql: "SELECT uuid, tableName, localId, zone FROM syncRecord WHERE zone <> 'device'").compactMap { row in
                let table: String = row["tableName"]
                guard !["accountBalancePoint", "accountSummaryMonth"].contains(table),
                      let placed = try? router.assignment(table: table, localId: row["localId"]),
                      placed.zone != row["zone"] as String || !placed.omittedFields.isEmpty || placed.companion != nil else { return nil }
                return row["uuid"] as String
            })
        }
        XCTAssertTrue(moved.isSubset(of: misplaced))
        XCTAssertTrue(misplaced.contains(try h.uuid("account", f.shared)), "the account goes again as a stub")
        XCTAssertLessThan(misplaced.count, try count(h.adminMac, "SELECT COUNT(*) FROM syncRecord") / 2, "a few records, not everything")
        XCTAssertEqual(queued, misplaced, "only the misplaced records")
        // Nothing changed since: the next reconcile queues nothing.
        XCTAssertEqual(try write(h.adminMac) { db in try SyncZoneMoves.reconcile(owner: nil, zones: [], db: db, now: Date()) }, 0)
        try await syncEveryone(h)
        XCTAssertEqual(try held(Array(moved), on: h.memberDevice), 0)
        try assertSettled(h)
        assertAuditsClean(h)
    }

    /// A push with nothing changed routes nothing: the reconcile is one query.
    func testAPushWithNothingChangedRoutesNothing() async throws {
        let h = try TwoPersonHousehold.make()
        try await syncEveryone(h)
        // Each writer's first push works out what it placed records by (the member's: nothing stored yet).
        for device in [h.adminMac, h.adminMac2, h.memberDevice] { _ = try await device.engine.syncNow() }
        let routings = SyncZoneMoves.reconcileRoutings.withLock { $0 }
        let started = Date()
        for _ in 1...3 {
            _ = try await h.adminMac.engine.syncNow()
            _ = try await h.adminMac2.engine.syncNow()
            _ = try await h.memberDevice.engine.syncNow()
        }
        let check = Date()
        _ = try write(h.adminMac) { db in try SyncZoneMoves.reconcile(owner: nil, zones: [], db: db, now: Date()) }
        let seconds = Date().timeIntervalSince(check)
        print("SharingLevelChangeTests: nine idle syncs in \(String(format: "%.3f", check.timeIntervalSince(started))) s; one reconcile check \(String(format: "%.4f", seconds)) s")
        XCTAssertEqual(SyncZoneMoves.reconcileRoutings.withLock { $0 }, routings, "no push routed anything")
        XCTAssertLessThan(seconds, 0.05)
        try assertSettled(h)
    }

    // MARK: Fix round 1: files move with their records, never lost (I-2, I-3)

    private struct DocumentFixture {
        var h: TwoPersonHousehold
        var uuid: String
        var sha: String
    }

    /// The household with a document linked to Shared's transaction, its file on the Mac only.
    private func householdWithDocument(_ folder: URL) throws -> DocumentFixture {
        let macLibrary = folder.appendingPathComponent("mac/Library", isDirectory: true)
        let bytes = Data("Synthetic receipt \(UUID().uuidString)".utf8)
        let sha = DocumentCrypto.sha256(bytes)
        let path = EvidenceLibrary.storedRelativePath(sha256: sha, fileExtension: "pdf")
        try FileManager.default.createDirectory(at: macLibrary.appendingPathComponent(path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: macLibrary.appendingPathComponent(path))
        let h = try TwoPersonHousehold.make(macDocuments: SyncDocumentFiles(root: macLibrary, policy: .eager))
        let f = h.fixture
        let document = try write(h.adminMac) { db -> Int64 in
            try db.execute(sql: "INSERT INTO document(sha256, storedRelativePath, originalFileName, byteCount, addedAt) VALUES (?, ?, 'r.pdf', ?, ?)",
                           arguments: [sha, path, bytes.count, Date(timeIntervalSince1970: 1_790_000_000)])
            let id = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO documentLink(documentId, entityType, entityId, createdAt) VALUES (?, 'transaction', ?, ?)",
                           arguments: [id, f.sharedTransaction, Date(timeIntervalSince1970: 1_790_000_000)])
            return id
        }
        return DocumentFixture(h: h, uuid: try h.uuid("document", document), sha: sha)
    }

    private func fileRecords(_ h: TwoPersonHousehold, of uuid: String, in zone: String) async -> [String] {
        await h.cloud.storedRecords().filter { $0.zone == zone && $0.recordType == SyncDocumentFile.recordType && $0.recordName.hasPrefix(uuid) }
            .map(\.recordName).sorted()
    }

    /// Whether `device`, with `keys`, can open the document's file from the server: the file record its reference
    /// names, in `zone`, under that zone's key.
    private func opensFile(_ d: DocumentFixture, on device: Device, keys: InMemorySyncKeyStore, zone: String) async throws -> Bool {
        guard let reference = try read(device, { db in try SyncDocumentFile.reference(uuid: d.uuid, db: db) }),
              let record = try await d.h.cloud.fetch(reference.recordName, zone: zone),
              let ciphertext = record.wire.assets[SyncDocumentFile.assetField],
              let id = try? DocumentCrypto.zoneKeyId(ofWrapped: reference.wrappedKey),
              let key = try keys.allKeys(zone: zone)[id],
              let plaintext = try? DocumentCrypto.open(ciphertext, wrappedKey: reference.wrappedKey, zoneKey: key,
                                                      authenticating: DocumentCrypto.fileContext(table: "document", uuid: d.uuid, sha256: d.sha))
        else { return false }
        return DocumentCrypto.sha256(plaintext) == d.sha
    }

    /// I-3: lowered and raised with the file present: it follows the record both ways, one file record at a time, and
    /// each device opens what it should.
    func testLoweringAndRaisingMoveTheDocumentFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("levels-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let d = try householdWithDocument(folder)
        let h = d.h
        let f = h.fixture
        try await syncEveryone(h)
        let firstHousehold = await fileRecords(h, of: d.uuid, in: SyncZones.household)
        XCTAssertEqual(firstHousehold.count, 1)
        let opensFirst = try await opensFile(d, on: h.memberDevice, keys: h.memberKeys, zone: SyncZones.household)
        XCTAssertTrue(opensFirst)

        try write(h.adminMac) { db in _ = try SharingLevels.set(.balanceOnly, accountId: f.shared, actor: f.admin, db: db) }
        try await syncEveryone(h)
        let lowered = await fileRecords(h, of: d.uuid, in: f.privateZone)
        XCTAssertEqual(lowered.count, 1, "exactly one file record, in A's zone")
        let loweredHousehold = await fileRecords(h, of: d.uuid, in: SyncZones.household)
        XCTAssertEqual(loweredHousehold, [], "none left in the household")
        let named = try await stored(h, d.uuid, in: f.privateZone)
        XCTAssertEqual(named?.documentFile?.recordName, lowered.first, "A's copy names it")
        XCTAssertNil(try h.localId("document", uuid: d.uuid, on: h.memberDevice), "the member has no document")
        for device in [h.adminMac2, h.adminPhone] {
            let opens = try await opensFile(d, on: device, keys: h.adminKeys, zone: f.privateZone)
            XCTAssertTrue(opens, "the admin's other devices open it under A's key")
        }
        XCTAssertTrue(try h.memberKeys.allKeys(zone: f.privateZone).isEmpty, "the member holds no key that would")
        try assertSettled(h)

        try write(h.adminMac) { db in _ = try SharingLevels.set(.everything, accountId: f.shared, actor: f.admin, db: db) }
        try await syncEveryone(h)
        let raised = await fileRecords(h, of: d.uuid, in: SyncZones.household)
        XCTAssertEqual(raised.count, 1, "one household file record again")
        let raisedPrivate = await fileRecords(h, of: d.uuid, in: f.privateZone)
        XCTAssertEqual(raisedPrivate, [], "none left in A's zone")
        let memberOpens = try await opensFile(d, on: h.memberDevice, keys: h.memberKeys, zone: SyncZones.household)
        XCTAssertTrue(memberOpens, "the member opens it")
        try assertSettled(h)
        assertAuditsClean(h)
    }

    /// I-2: the second Mac, which never had the file, raises the account: it seals the file again from A's zone (it
    /// holds both keys) instead of moving the document without it.
    func testADeviceWithoutTheFileMovesItFromTheOldZone() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("levels-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let d = try householdWithDocument(folder)
        let h = d.h
        let f = h.fixture
        try await syncEveryone(h)
        try write(h.adminMac) { db in _ = try SharingLevels.set(.balanceOnly, accountId: f.shared, actor: f.admin, db: db) }
        try await syncEveryone(h)

        let shared2 = try localAccount(h, f.shared, on: h.adminMac2)
        try write(h.adminMac2) { db in _ = try SharingLevels.set(.everything, accountId: shared2, actor: try AccessActor.admin(db: db), db: db) }
        _ = try await h.adminMac2.engine.pushPending()
        let household = await fileRecords(h, of: d.uuid, in: SyncZones.household)
        XCTAssertEqual(household.count, 1, "the second Mac sealed the file for the household")
        let left = await fileRecords(h, of: d.uuid, in: f.privateZone)
        XCTAssertEqual(left, [], "and only then deleted A's")
        try await syncEveryone(h)
        let memberOpens = try await opensFile(d, on: h.memberDevice, keys: h.memberKeys, zone: SyncZones.household)
        XCTAssertTrue(memberOpens, "the member opens it")
        let macOpens = try await opensFile(d, on: h.adminMac, keys: h.adminKeys, zone: SyncZones.household)
        XCTAssertTrue(macOpens)
        try assertSettled(h)
        assertAuditsClean(h)
    }

    /// I-2: when the file can't be had (not on this device, and its copy in the old zone can't be opened), the record
    /// waits with its old file kept, logged once for attention; a device that has the file finishes the move.
    func testAFileThatCantBeFetchedKeepsTheOldCopyAndWaits() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("levels-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let d = try householdWithDocument(folder)
        let h = d.h
        let f = h.fixture
        try await syncEveryone(h)
        try write(h.adminMac) { db in _ = try SharingLevels.set(.balanceOnly, accountId: f.shared, actor: f.admin, db: db) }
        try await syncEveryone(h)
        let privateFiles = await fileRecords(h, of: d.uuid, in: f.privateZone)
        let privateFile = try XCTUnwrap(privateFiles.first)
        await h.cloud.corruptAsset(of: privateFile, field: SyncDocumentFile.assetField)

        let shared2 = try localAccount(h, f.shared, on: h.adminMac2)
        try write(h.adminMac2) { db in _ = try SharingLevels.set(.everything, accountId: shared2, actor: try AccessActor.admin(db: db), db: db) }
        for _ in 1...2 { _ = try await h.adminMac2.engine.pushPending() }
        let kept = await fileRecords(h, of: d.uuid, in: f.privateZone)
        XCTAssertEqual(kept, [privateFile], "the old file is never deleted")
        let household = await fileRecords(h, of: d.uuid, in: SyncZones.household)
        XCTAssertEqual(household, [])
        let marker = try await stored(h, d.uuid, in: SyncZones.household)
        XCTAssertEqual(marker?.movedTo, f.privateZone, "the document hasn't moved: the household still holds its marker")
        XCTAssertEqual(try count(h.adminMac2, "SELECT COUNT(*) FROM syncPending WHERE uuid = ?", [d.uuid]), 1, "it waits, still pending")
        XCTAssertEqual(try count(h.adminMac2, "SELECT COUNT(*) FROM syncConflict WHERE uuid = ? AND losingValueJSON LIKE ?",
                                 [d.uuid, "%" + SyncEngineCore.fileNotMovedMessage + "%"]), 1, "logged for attention, once")
        assertAuditsClean(h)

        // The Mac has the file: once it hears of the level, it moves the document with its file.
        _ = try await h.adminMac.engine.syncNow()
        let moved = await fileRecords(h, of: d.uuid, in: SyncZones.household)
        XCTAssertEqual(moved.count, 1)
        _ = try await h.memberDevice.engine.pull()
        let memberOpens = try await opensFile(d, on: h.memberDevice, keys: h.memberKeys, zone: SyncZones.household)
        XCTAssertTrue(memberOpens)
        assertAuditsClean(h)
    }

    // MARK: Helpers

    /// Where the Mac places each record it tracks now.
    private func placements(_ h: TwoPersonHousehold) throws -> [String: ZoneAssignment] {
        try read(h.adminMac) { db in
            let router = try SyncZoneRouter(db: db)
            var placed: [String: ZoneAssignment] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT uuid, tableName, localId FROM syncRecord WHERE zone <> 'device'") {
                if let assignment = try? router.assignment(table: row["tableName"], localId: row["localId"]) { placed[row["uuid"]] = assignment }
            }
            return placed
        }
    }

    /// The demo with an admin, every account but the first owned by them (the first joint, property-linked ones at
    /// Everything, the others at Balance only) and ownership confirmed, through the sheet. Returns the admin.
    private func confirmDemoOwnership(_ db: Database) throws -> AccessActor {
        let person = try Int64.fetchOne(db, sql: "SELECT id FROM person ORDER BY id LIMIT 1")!
        if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM appUser WHERE isAdmin = 1") == 0 {
            var admin = AppUser(personId: person, displayName: "A", isAdmin: true, createdAt: Date(timeIntervalSince1970: 0))
            try admin.insert(db)
        }
        let adminUser = try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE isAdmin = 1 ORDER BY id LIMIT 1")!
        let admin = try AccessActor.load(appUserId: adminUser, db: db)
        // The demo comes with its ownership saved (`DemoSharing`); a database without it gets it here.
        if try !SharingSetup.isConfirmed(db: db) {
            var rows = try SharingSetup.proposal(admin: admin, db: db)
            if !rows.isEmpty {
                rows[0].owner = .joint
                rows[0].level = .everything
            }
            try SharingSetup.save(rows, admin: admin, db: db, now: Date(timeIntervalSince1970: 0))
        }
        try SyncRecordStore.backfill(db: db)
        return admin
    }
}
