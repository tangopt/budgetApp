import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 7a Task 7: adding the member, the invite's gate (local blockers and the server audit), the zone share, binding
/// her iCloud user, and removing her. Over `TwoPersonHousehold` with the member not invited yet: every Mac call goes
/// through `LossyTransport` over `ZoneAuditingTransport`, her device through her own audited session. Synthetic data only.
final class HouseholdInviteTests: XCTestCase {
    private let household = SyncZones.household
    private let member = TwoPersonHousehold.memberICloudUser

    // MARK: Fixture

    /// The household with real sync on and everything uploaded: the gate passes.
    private func ready(file: StaticString = #filePath, line: UInt = #line) async throws -> TwoPersonHousehold {
        let h = try TwoPersonHousehold.make(memberInvited: false)
        try write(h.adminMac.db) { db in
            try SyncImportGate.setState(Data(SyncTurnOn.Stage.done.rawValue.utf8), key: SyncTurnOn.stageKey, db: db, now: Date())
        }
        try await settle(h)
        XCTAssertEqual(try read(h.adminMac.db) { db in try HouseholdInvite.localBlockers(db: db) }, [], "precondition: the gate passes",
                       file: file, line: line)
        return h
    }

    /// The Mac pushes until nothing is left to upload.
    private func settle(_ h: TwoPersonHousehold) async throws {
        for _ in 0..<4 {
            try await h.adminMac.engine.pushPending()
            let left = try read(h.adminMac.db) { db in
                try SyncChangeTracker.pending(db: db).count + SyncZoneMoves.unfinished(db: db).count
            }
            if left == 0 { return }
        }
    }

    private func invite(_ h: TwoPersonHousehold, transport: (any SyncTransport & SyncShareTransport)? = nil) async throws -> HouseholdInvite.Result {
        try await HouseholdInvite.invite(transport: transport ?? h.macTransport, keys: h.adminKeys, db: h.adminMac.db, title: "Synthetic household")
    }

    private func share(_ result: HouseholdInvite.Result, file: StaticString = #filePath, line: UInt = #line) throws -> SyncZoneShare {
        guard case .share(let share) = result else {
            XCTFail("expected a share, got \(result)", file: file, line: line)
            throw XCTSkip("no share")
        }
        return share
    }

    /// Her device as the member's app runs it: read-only, the household through her shared database.
    private func memberEngine(_ h: TwoPersonHousehold, viewer: SyncViewer = .none) -> SyncEngineCore {
        SyncEngineCore(db: h.memberDevice.db, transport: h.memberAudit, device: SyncDevice(id: "member-ipad", name: "iPad"),
                       keyStore: h.memberKeys, readOnly: true, viewer: viewer, householdIsShared: true)
    }

    /// Invited (gate passed), she accepts on her device (the share sheet and the link), the Mac binds her and pushes.
    private func joined(_ h: TwoPersonHousehold) async throws -> SyncZoneShare {
        _ = try share(try await invite(h))
        h.cloud.invite(member, zone: household)
        h.cloud.accept(zone: household, as: member)
        try write(h.memberDevice.db) { db in try SyncHouseholdMembership.record(ownerRecordName: TwoPersonHousehold.adminICloudUser, db: db) }
        let accepted = try await h.macTransport.zoneShare(household)!
        XCTAssertEqual(try write(h.adminMac.db) { db in try HouseholdInvite.bindAcceptedParticipant(share: accepted, db: db) }, .bound)
        try await settle(h)
        return accepted
    }

    private func memberAppUser(_ h: TwoPersonHousehold) throws -> AppUser {
        try read(h.adminMac.db) { db in try HouseholdInvite.member(db: db)! }
    }

    private func zones(_ engine: SyncEngineCore, _ device: TwoPersonHousehold.Device) throws -> [String] {
        try device.db.read { db in try engine.zones(db: db) }
    }

    private func uuids(_ device: TwoPersonHousehold.Device, zoneLike pattern: String) throws -> Set<String> {
        Set(try read(device.db) { db in try String.fetchAll(db, sql: "SELECT uuid FROM syncRecord WHERE zone LIKE ?", arguments: [pattern]) })
    }

    private func noShare(_ h: TwoPersonHousehold, file: StaticString = #filePath, line: UInt = #line) async throws {
        let made = try await h.cloud.zoneShare(household)
        XCTAssertNil(made, "nothing was shared", file: file, line: line)
    }

    // MARK: Adding the member

    func testAddMemberRefusedForNonAdmin() throws {
        let db = try TestDatabase.migrated()
        try db.write { db in
            try db.execute(sql: "INSERT INTO person(name) VALUES ('Synthetic Person A')")
            var admin = AppUser(personId: db.lastInsertedRowID, displayName: "A", isAdmin: true, createdAt: Date())
            try admin.insert(db)
            var other = Person(name: "Synthetic Person C")
            try People.save(db: db, &other)
            var notAdmin = AppUser(personId: other.id!, displayName: "C", isAdmin: false, createdAt: Date())
            try notAdmin.insert(db)
            XCTAssertThrowsError(try AppUserStore.addMember(db, personId: nil, name: "Synthetic Person B", by: notAdmin.id!, now: Date())) {
                XCTAssertEqual($0 as? AppUserStoreError, .notAdmin)
            }
            try db.execute(sql: "DELETE FROM appUser WHERE id = ?", arguments: [notAdmin.id])

            // The admin adds her: a new person, no password, not an admin, her default permissions, written as the admin.
            let added = try AppUserStore.addMember(db, personId: nil, name: "  Synthetic Person B ", by: admin.id!, now: Date())
            XCTAssertEqual(added.displayName, "Synthetic Person B")
            XCTAssertFalse(added.isAdmin)
            XCTAssertNil(added.cloudKitUserRecordName)
            XCTAssertEqual(try Person.fetchOne(db, key: added.personId)?.name, "Synthetic Person B")
            XCTAssertEqual(try LocalCredential.fetchCount(db), 0, "no local credential")
            XCTAssertGreaterThan(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memberPermission WHERE appUserId = ?", arguments: [added.id])!, 0)
            let adminUuid = try SyncRecordStore.uuid(for: "appUser", localId: admin.id!, db: db)
            let writers = try String.fetchAll(db, sql: """
                SELECT DISTINCT modifiedBy FROM syncFieldClock WHERE tableName = 'appUser' AND localId = ?
                """, arguments: [added.id])
            XCTAssertEqual(writers, [adminUuid], "written as the admin")

            // A second member is refused; so is an existing person who already has a user.
            XCTAssertThrowsError(try AppUserStore.addMember(db, personId: other.id!, name: "Synthetic Person C", by: admin.id!, now: Date())) {
                XCTAssertEqual($0 as? AppUserStoreError, .householdHasMember)
            }
        }
    }

    // MARK: The gate

    func testInviteBlockedUntilOwnershipConfirmed() async throws {
        let h = try await ready()
        try write(h.adminMac.db) { db in try db.execute(sql: "UPDATE personSharing SET ownershipConfirmedAt = NULL") }
        let result = try await invite(h)
        guard case .blocked(let blockers) = result else { return XCTFail("must be blocked: \(result)") }
        XCTAssertEqual(blockers.first, .ownershipNotConfirmed)
        XCTAssertFalse(blockers.contains { if case .misplaced = $0 { return true } else { return false } }, "no placement before ownership")
        try await noShare(h)
        XCTAssertEqual(HouseholdCopy.blocker(.ownershipNotConfirmed), "Confirm who owns each account first, in Settings ▸ Sharing.")
    }

    func testInviteBlockedUntilSyncIsOnAndAMemberIsAdded() async throws {
        let h = try await ready()
        try write(h.adminMac.db) { db in
            try SyncImportGate.setState(Data(SyncTurnOn.Stage.uploading.rawValue.utf8), key: SyncTurnOn.stageKey, db: db, now: Date())
        }
        let result1 = try await invite(h)
        XCTAssertEqual(result1, .blocked([.syncNotOn]))
        try write(h.adminMac.db) { db in
            try SyncImportGate.setState(Data(SyncTurnOn.Stage.done.rawValue.utf8), key: SyncTurnOn.stageKey, db: db, now: Date())
            try AppUserStore.remove(db, try HouseholdInvite.member(db: db)!.id!, by: h.fixture.admin.appUserId)
            try SyncChangeTracker.acknowledge(try SyncChangeTracker.pending(db: db), db: db)
        }
        let result2 = try await invite(h)
        XCTAssertEqual(result2, .blocked([.noMember]))
        try await noShare(h)
        XCTAssertEqual(HouseholdCopy.blocker(.syncNotOn), "Turn on iCloud sync first, in Settings ▸ Sync.")
        XCTAssertEqual(HouseholdCopy.blocker(.noMember), "Add the person you're inviting first.")
    }

    func testInviteBlockedWhilePending() async throws {
        let h = try await ready()
        try write(h.adminMac.db) { db in
            try db.execute(sql: "UPDATE transaction_ SET note = 'Synthetic note' WHERE id = ?", arguments: [h.fixture.sharedTransaction])
        }
        let result3 = try await invite(h)
        XCTAssertEqual(result3, .blocked([.pendingUpload(1)]))
        try await noShare(h)
        XCTAssertEqual(HouseholdCopy.blocker(.pendingUpload(1)), "Mango still has 1 change to upload. Sync now, then try again.")
        XCTAssertEqual(HouseholdCopy.blocker(.pendingUpload(3)), "Mango still has 3 changes to upload. Sync now, then try again.")

        try await settle(h)
        _ = try share(try await invite(h))
    }

    func testInviteBlockedByMisplacedRecord() async throws {
        let h = try await ready()
        let f = h.fixture
        let moving = try h.uuid("transaction_", f.sharedTransaction)
        // Shared drops below Everything without the move being queued (as on a build before the sweep): its records now
        // belong in A's zone and haven't moved.
        try write(h.adminMac.db) { db in
            try db.execute(sql: "UPDATE account SET sharingLevel = ? WHERE id = ?", arguments: [SharingLevel.balanceOnly.rawValue, f.shared])
        }
        let unsettled = try read(h.adminMac.db) { db in
            try SyncPlacementSweep.unsettled(zones: [SyncZones.household, f.privateZone], db: db).map(\.uuid)
        }
        XCTAssertTrue(unsettled.contains(moving), "\(unsettled)")
        let result = try await invite(h)
        guard case .blocked(let blockers) = result else { return XCTFail("must be blocked: \(result)") }
        XCTAssertTrue(blockers.contains(.misplaced(unsettled.count)), "\(blockers)")
        try await noShare(h)
        XCTAssertEqual(HouseholdCopy.blocker(.misplaced(1)), "1 record isn't in the right place yet. Sync now, then try again.")
        XCTAssertEqual(HouseholdCopy.blocker(.misplaced(2)), "2 records aren't in the right place yet. Sync now, then try again.")

        // The push's sweep moves it: the gate passes.
        try await settle(h)
        _ = try share(try await invite(h))
        XCTAssertEqual(h.audit.householdViolations(router: h.adminRouter()), [])
    }

    /// The push's guard stops any household save of a private record, so a copy that got there anyway (an older build,
    /// a router bug in another device's push) is planted on the server directly: the household key seals A's private
    /// transaction into `household`, which nothing on this Mac knows. Only the server audit sees it.
    func testInviteRefusedWhileARecordBelowEverythingIsInHousehold() async throws {
        let h = try await ready()
        let f = h.fixture
        let leaking = try h.uuid("transaction_", f.privateTransaction)
        let original = try await h.cloud.fetch(leaking, zone: f.privateZone)
        var payload = try SyncLargePayload.payload(from: XCTUnwrap(original), keys: try h.adminKeys.allKeys(zone: f.privateZone))
        payload.zone = household
        payload.serverWriter = nil
        let (planted, _) = try SyncLargePayload.wire(for: payload, key: try XCTUnwrap(try h.adminKeys.key(zone: household)))
        _ = try await h.cloud.save([planted], ifUnchanged: [:], atomic: false)
        XCTAssertEqual(try read(h.adminMac.db) { db in try HouseholdInvite.localBlockers(db: db) }, [], "nothing here knows of it")

        let violations = try await HouseholdInvite.auditServer(transport: h.macTransport, keys: h.adminKeys, db: h.adminMac.db)
        XCTAssertEqual(violations.map(\.recordName), [leaking])
        let result4 = try await invite(h)
        XCTAssertEqual(result4, .blocked([.householdAudit(1)]))
        try await noShare(h)
        XCTAssertEqual(HouseholdCopy.blocker(.householdAudit(1)), "1 record in the household shouldn't be there. Nothing was shared.")
        XCTAssertEqual(HouseholdCopy.blocker(.householdAudit(4)), "4 records in the household shouldn't be there. Nothing was shared.")
        XCTAssertEqual(HouseholdCopy.blocker(.householdAudit(1), alreadyShared: true),
                       "1 record in the household shouldn't be there. Nothing new was shared.")

        // A record that doesn't open with the household key counts too.
        _ = try await h.cloud.delete([leaking], zone: household)
        let (foreign, _) = try SyncLargePayload.wire(for: payload, key: DocumentCrypto.newZoneKey())
        _ = try await h.cloud.save([foreign], ifUnchanged: [:], atomic: false)
        let result5 = try await invite(h)
        XCTAssertEqual(result5, .blocked([.householdAudit(1)]))
        _ = try await h.cloud.delete([leaking], zone: household)
        _ = try share(try await invite(h))
    }

    func testInviteOfflineIsBlocked() async throws {
        let h = try await ready()
        let result = try await invite(h, transport: OfflineShareTransport())
        XCTAssertEqual(result, .blocked([.offline]))
        try await noShare(h)
        XCTAssertEqual(HouseholdCopy.blocker(.offline), "Mango couldn't check iCloud. Try again when you're online.")
    }

    // MARK: The share

    func testInviteMakesZoneShare() async throws {
        let h = try await ready()
        let made = try share(try await invite(h))
        XCTAssertEqual(made.zone, household)
        XCTAssertEqual(made.ownerRecordName, TwoPersonHousehold.adminICloudUser)
        XCTAssertEqual(made.participants, [])
        XCTAssertNotNil(made.url)
        let held = try await h.cloud.zoneShare(household)
        XCTAssertEqual(held, made)
        XCTAssertEqual(HouseholdInvite.status(share: made, member: try memberAppUser(h)), .invited)
        XCTAssertEqual(HouseholdInvite.status(share: nil, member: try memberAppUser(h)), .notInvited)
        XCTAssertEqual(h.audit.householdViolations(router: h.adminRouter()), [])
    }

    func testInviteTwiceReusesTheShare() async throws {
        let h = try await ready()
        let first = try share(try await invite(h))
        // She's on it (the share sheet), then "Invite…" again, as after the app quit mid-invite.
        h.cloud.invite(member, zone: household)
        let second = try share(try await invite(h))
        XCTAssertEqual(second.url, first.url)
        XCTAssertEqual(second.participants.map(\.userRecordName), [member], "the same share: she's still on it")
    }

    // MARK: Pressing "Invite…" on the Mac (`press`)

    private func press(_ h: TwoPersonHousehold, running: Bool = true, transport: (any SyncTransport & SyncShareTransport)? = nil,
                       sheet: () async throws -> String? = { "sheet" }) async throws -> HouseholdInvite.PressOutcome<String> {
        try await HouseholdInvite.press(running: running, transport: transport ?? h.macTransport, keys: h.adminKeys,
                                        db: h.adminMac.db, title: "Synthetic household", sheet: sheet)
    }

    private func lines(_ outcome: HouseholdInvite.PressOutcome<String>, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        guard case .blocked(let lines) = outcome else { XCTFail("expected blocked, got \(outcome)", file: file, line: line); return [] }
        return lines
    }

    func testPressPresentsTheSheetForTheShare() async throws {
        let h = try await ready()
        var asked = 0
        let outcome = try await press(h) { asked += 1; return "sheet" }
        guard case .present(let made, let sheet) = outcome else { return XCTFail("expected the sheet, got \(outcome)") }
        XCTAssertEqual(sheet, "sheet")
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(made.zone, household)
        let held = try await h.cloud.zoneShare(household)
        XCTAssertEqual(held, made)
    }

    func testPressWithSyncOffIsBlockedVisiblyAndSharesNothing() async throws {
        let h = try await ready()
        var asked = 0
        let outcome = try await press(h, running: false) { asked += 1; return "sheet" }
        XCTAssertEqual(lines(outcome), ["Turn on iCloud sync first, in Settings ▸ Sync."])
        XCTAssertEqual(asked, 0)
        try await noShare(h)
    }

    func testPressLocalBlockersAreLines() async throws {
        let h = try await ready()
        try write(h.adminMac.db) { db in try db.execute(sql: "UPDATE personSharing SET ownershipConfirmedAt = NULL") }
        let outcome = try await press(h)
        XCTAssertEqual(lines(outcome).first, "Confirm who owns each account first, in Settings ▸ Sharing.")
        try await noShare(h)
    }

    func testPressOfflineIsALine() async throws {
        let h = try await ready()
        let outcome = try await press(h, transport: OfflineShareTransport())
        XCTAssertEqual(lines(outcome), ["Mango couldn't check iCloud. Try again when you're online."])
    }

    func testPressWithoutASheetSaysSo() async throws {
        let h = try await ready()
        let outcome = try await press(h) { nil }
        guard case .sheetUnavailable(let made) = outcome else { return XCTFail("expected sheetUnavailable, got \(outcome)") }
        XCTAssertEqual(made.zone, household)
    }

    func testPressSheetErrorIsThrownForTheErrorLine() async throws {
        struct Refused: Error {}
        let h = try await ready()
        do {
            _ = try await press(h) { throw Refused() }
            XCTFail("must throw")
        } catch is Refused {}
    }

    // A real household: "Invite…" spun forever (bug A). The gate now reads the household once, without the documents'
    // contents, reports where it is, and gives up when iCloud stops answering.

    func testPressReadsTheHouseholdOnceWithoutFiles() async throws {
        let h = try await ready()
        let counting = DelayedShareTransport(inner: h.macTransport)
        let stages = StageLog()
        let outcome = try await HouseholdInvite.press(running: true, transport: counting, keys: h.adminKeys, db: h.adminMac.db,
                                                      title: "Synthetic household", progress: { stages.add($0) }) { "sheet" }
        guard case .present = outcome else { return XCTFail("expected the sheet, got \(outcome)") }
        let reads = await counting.reads
        XCTAssertEqual(reads.full, 0, "never the documents' contents")
        XCTAssertEqual(reads.withoutFiles, 1, "one read for the clean and the audit (one page here)")
        let seen = stages.all
        XCTAssertEqual(seen.first, .checkingThisMac)
        XCTAssertTrue(seen.contains { if case .readingICloud = $0 { return true } else { return false } })
        XCTAssertEqual(Array(seen.suffix(2)), [.sharing, .preparingSheet])
    }

    func testPressTimesOutCleanlyWhenICloudNeverAnswers() async throws {
        let h = try await ready()
        let silent = DelayedShareTransport(inner: h.macTransport, delay: .seconds(3_600))
        let started = ContinuousClock.now
        var asked = 0
        let outcome = try await HouseholdInvite.press(running: true, transport: silent, keys: h.adminKeys, db: h.adminMac.db,
                                                      title: "Synthetic household", idleLimit: .milliseconds(300)) { asked += 1; return "sheet" }
        guard case .timedOut = outcome else { return XCTFail("expected a time-out, got \(outcome)") }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "gives up, doesn't wait for the reply")
        XCTAssertEqual(asked, 0)
        try await noShare(h)
        XCTAssertEqual(HouseholdCopy.inviteTimedOut, "Mango couldn't finish checking iCloud. Try again.")
    }

    func testPressCompletesWhenICloudIsSlowButAnswers() async throws {
        let h = try await ready()
        // Every reply takes 150 ms against a 400 ms limit: the whole press takes longer than the limit, but iCloud never
        // goes that long without answering.
        let slow = DelayedShareTransport(inner: h.macTransport, delay: .milliseconds(150))
        let started = ContinuousClock.now
        let outcome = try await HouseholdInvite.press(running: true, transport: slow, keys: h.adminKeys, db: h.adminMac.db,
                                                      title: "Synthetic household", idleLimit: .milliseconds(400)) { "sheet" }
        guard case .present(let made, _) = outcome else { return XCTFail("expected the sheet, got \(outcome)") }
        XCTAssertGreaterThan(ContinuousClock.now - started, .milliseconds(400), "precondition: longer than the limit in all")
        let held = try await h.cloud.zoneShare(household)
        XCTAssertEqual(held, made)
    }

    func testWatchdogPassesTheWorksErrorAndResult() async throws {
        struct Refused: Error {}
        let value = try await InviteWatchdog.run(idleLimit: .seconds(5)) { _ in 7 }
        XCTAssertEqual(value, 7)
        do {
            _ = try await InviteWatchdog.run(idleLimit: .seconds(5)) { _ -> Int in throw Refused() }
            XCTFail("must throw")
        } catch is Refused {}
    }

    func testInviteProgressCopy() {
        XCTAssertEqual(HouseholdCopy.inviteProgress(.checkingThisMac), HouseholdCopy.inviteChecking)
        XCTAssertEqual(HouseholdCopy.inviteProgress(.readingICloud(records: 1_200)),
                       "Checking the household with iCloud before inviting… \(1_200.formatted()) records read.")
        XCTAssertEqual(HouseholdCopy.inviteProgress(.sharing), "Making the invitation…")
    }

    // MARK: Binding

    func testAcceptedParticipantIsBoundToMember() async throws {
        let h = try await ready()
        _ = try share(try await invite(h))
        h.cloud.invite(member, zone: household)
        let invited = try await h.macTransport.zoneShare(household)!
        XCTAssertEqual(try write(h.adminMac.db) { db in try HouseholdInvite.bindAcceptedParticipant(share: invited, db: db) }, .nothing, "not accepted yet")
        XCTAssertEqual(HouseholdInvite.status(share: invited, member: try memberAppUser(h)), .invited)

        h.cloud.accept(zone: household, as: member)
        let accepted = try await h.macTransport.zoneShare(household)!
        XCTAssertEqual(try write(h.adminMac.db) { db in try HouseholdInvite.bindAcceptedParticipant(share: accepted, db: db) }, .bound)
        let bound = try memberAppUser(h)
        XCTAssertEqual(bound.cloudKitUserRecordName, member)
        XCTAssertEqual(HouseholdInvite.status(share: accepted, member: bound), .joined)
        XCTAssertEqual(HouseholdCopy.status(.joined), "Joined")
        XCTAssertEqual(try write(h.adminMac.db) { db in try HouseholdInvite.bindAcceptedParticipant(share: accepted, db: db) }, .nothing, "already bound")
        let pending = try read(h.adminMac.db) { db in try SyncChangeTracker.pending(db: db).map(\.table) }
        XCTAssertEqual(pending, ["appUser"], "the bind syncs")
    }

    func testTwoUnknownParticipantsBindNobody() async throws {
        let h = try await ready()
        _ = try share(try await invite(h))
        for user in [member, "fake-stranger"] {
            h.cloud.invite(user, zone: household)
            h.cloud.accept(zone: household, as: user)
        }
        let accepted = try await h.macTransport.zoneShare(household)!
        XCTAssertEqual(try write(h.adminMac.db) { db in try HouseholdInvite.bindAcceptedParticipant(share: accepted, db: db) }, .ambiguous(2))
        XCTAssertNil(try memberAppUser(h).cloudKitUserRecordName)
        XCTAssertEqual(HouseholdCopy.ambiguousParticipants("Person B"),
                       "More than one person accepted the invitation, so Mango didn't link anyone to Person B. Remove them from the household, then invite Person B again.")
        XCTAssertEqual(try read(h.adminMac.db) { db in try SyncChangeTracker.pending(db: db).count }, 0, "nothing written")
    }

    // MARK: Her device

    func testMemberViewerFollowsOnceHerRecordNameIsBound() async throws {
        let h = try await ready()
        _ = try share(try await invite(h))
        h.cloud.invite(member, zone: household)
        h.cloud.accept(zone: household, as: member)
        try write(h.memberDevice.db) { db in try SyncHouseholdMembership.record(ownerRecordName: TwoPersonHousehold.adminICloudUser, db: db) }

        // She pulls before the Mac has bound her: household only, no viewer, no private zone.
        let first = memberEngine(h)
        XCTAssertEqual(try zones(first, h.memberDevice), [household])
        try await first.pull()
        XCTAssertFalse(try uuids(h.memberDevice, zoneLike: household).isEmpty, "she holds the household")
        XCTAssertEqual(try uuids(h.memberDevice, zoneLike: "private-%"), [], "nothing private")
        XCTAssertEqual(try read(h.memberDevice.db) { db in try SyncViewer.forCloudKitUser(recordName: self.member, db: db) }, SyncViewer.none)
        XCTAssertTrue(try read(h.memberDevice.db) { db in try SyncHouseholdMembership.hasJoined(db: db) })

        // The Mac binds her; the bind reaches her device; her viewer follows.
        let accepted = try await h.macTransport.zoneShare(household)!
        XCTAssertEqual(try write(h.adminMac.db) { db in try HouseholdInvite.bindAcceptedParticipant(share: accepted, db: db) }, .bound)
        try await settle(h)
        try await first.pull()
        let viewer = try read(h.memberDevice.db) { db in try SyncViewer.forCloudKitUser(recordName: self.member, db: db) }
        XCTAssertEqual(viewer, SyncViewer(personUuid: h.personBUuid))
        let followed = memberEngine(h, viewer: viewer)
        XCTAssertEqual(Set(try zones(followed, h.memberDevice)), [household, h.memberZone])
        try await followed.pull()
        XCTAssertEqual(h.memberAudit.householdViolations(router: h.adminRouter()), [])
        XCTAssertEqual(h.audit.householdViolations(router: h.adminRouter()), [])
    }

    func testMemberNeverReceivesPrivateRecordsAfterJoining() async throws {
        let h = try await ready()
        _ = try await joined(h)
        let engine = memberEngine(h, viewer: SyncViewer(personUuid: h.personBUuid))
        XCTAssertEqual(Set(try zones(engine, h.memberDevice)), [household, h.memberZone], "her zone set: household and hers")
        try await engine.pull()
        // The admin keeps editing; she pulls again.
        try write(h.adminMac.db) { db in
            try db.execute(sql: "UPDATE transaction_ SET note = 'Synthetic private note' WHERE id = ?", arguments: [h.fixture.privateTransaction])
            try db.execute(sql: "UPDATE transaction_ SET note = 'Synthetic shared note' WHERE id = ?", arguments: [h.fixture.sharedTransaction])
        }
        try await settle(h)
        try await engine.pull()

        let adminPrivate = try uuids(h.adminMac, zoneLike: "private-%")
        XCTAssertFalse(adminPrivate.isEmpty, "precondition: A has private records")
        let hers = Set(try read(h.memberDevice.db) { db in try String.fetchAll(db, sql: "SELECT uuid FROM syncRecord") })
        XCTAssertTrue(hers.isDisjoint(with: adminPrivate), "none of A's private records: \(hers.intersection(adminPrivate))")
        XCTAssertFalse(hers.isEmpty)
        XCTAssertEqual(try read(h.memberDevice.db) { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT zone FROM syncRecord WHERE zone <> ?", arguments: [SyncZoneSet.deviceOnlyZone])
        }, [household], "nothing but the household (and this device's own local rows)")
        XCTAssertEqual(try read(h.memberDevice.db) { db in
            try String.fetchAll(db, sql: "SELECT accountNumber FROM account WHERE accountNumber IS NOT NULL OR sortCode IS NOT NULL")
        }, [], "no account details")
        XCTAssertEqual(try read(h.memberDevice.db) { db in
            try String.fetchAll(db, sql: "SELECT note FROM transaction_ WHERE note = 'Synthetic private note'")
        }, [])
        XCTAssertEqual(try read(h.memberDevice.db) { db in
            try String.fetchAll(db, sql: "SELECT note FROM transaction_ WHERE note = 'Synthetic shared note'")
        }, ["Synthetic shared note"])
        XCTAssertEqual(h.memberAudit.householdViolations(router: h.adminRouter()), [])
        XCTAssertEqual(h.audit.householdViolations(router: h.adminRouter()), [])
        XCTAssertEqual(h.memberAudit.savesByZone, [:], "her read-only device sent nothing")
        let audit = try await HouseholdInvite.auditServer(transport: h.macTransport, keys: h.adminKeys, db: h.adminMac.db)
        XCTAssertEqual(audit, [])
    }

    /// Carried M4: right after accepting, the household may not be listed in her shared database yet; that is not removal.
    func testMembershipJoinsOnlyAfterTheFirstHouseholdPull() async throws {
        let h = try await ready()
        _ = try share(try await invite(h))
        h.cloud.invite(member, zone: household)
        try write(h.memberDevice.db) { db in try SyncHouseholdMembership.record(ownerRecordName: TwoPersonHousehold.adminICloudUser, db: db) }
        let engine = memberEngine(h)
        let early = try await engine.pull()
        XCTAssertFalse(early.leftHousehold, "not reachable yet is not removal")
        XCTAssertFalse(try read(h.memberDevice.db) { db in try SyncHouseholdMembership.hasJoined(db: db) })
        XCTAssertEqual(try read(h.memberDevice.db) { db in try SyncHouseholdMembership.current(db: db) }, TwoPersonHousehold.adminICloudUser)

        h.cloud.accept(zone: household, as: member)
        let first = try await engine.pull()
        XCTAssertFalse(first.leftHousehold)
        XCTAssertTrue(try read(h.memberDevice.db) { db in try SyncHouseholdMembership.hasJoined(db: db) })
        XCTAssertGreaterThan(first.received, 0)
    }

    func testRemoveThenMemberLeavesHousehold() async throws {
        let h = try await ready()
        _ = try await joined(h)
        let engine = memberEngine(h, viewer: SyncViewer(personUuid: h.personBUuid))
        try await engine.pull()
        let held = try uuids(h.memberDevice, zoneLike: household)
        XCTAssertFalse(held.isEmpty)
        let memberSession = h.cloud.session(as: member)

        // She can't take herself off, nor make or delete zones in the admin's database.
        do {
            try await memberSession.removeParticipant(userRecordName: member, zone: household)
            XCTFail("a participant can't edit the share")
        } catch FakeCloudError.permissionFailure {}
        do {
            try await memberSession.deleteZone(household)
            XCTFail("a participant can't delete the zone")
        } catch FakeCloudError.permissionFailure {}
        do {
            try await memberSession.createZone(household)
            XCTFail("a participant can't make the zone")
        } catch FakeCloudError.permissionFailure {}

        let onServer = await h.cloud.storedRecords().filter { $0.zone == household }.count
        try await HouseholdInvite.remove(transport: h.macTransport, member: try memberAppUser(h), db: h.adminMac.db)
        let after = try await h.cloud.zoneShare(household)
        XCTAssertEqual(after?.participants, [])
        XCTAssertEqual(HouseholdInvite.status(share: after, member: try memberAppUser(h)), .invited)

        let report = try await engine.pull()
        XCTAssertTrue(report.leftHousehold)
        let dropped = try write(h.memberDevice.db) { db in try SyncHouseholdMembership.left(db: db) }
        XCTAssertEqual(dropped, held.count)
        XCTAssertEqual(try uuids(h.memberDevice, zoneLike: household), [])
        XCTAssertFalse(try read(h.memberDevice.db) { db in try SyncHouseholdMembership.hasJoined(db: db) })
        XCTAssertNil(try read(h.memberDevice.db) { db in try SyncHouseholdMembership.current(db: db) })
        let kept = await h.cloud.storedRecords().filter { $0.zone == household }.count
        XCTAssertEqual(kept, onServer, "the Mac's household stays on the server")
        XCTAssertGreaterThan(try uuids(h.adminMac, zoneLike: household).count, 0, "and on the Mac")
        XCTAssertEqual(HouseholdCopy.removedNotice, "You're no longer in this household. Its data was removed from this device.")

        XCTAssertEqual(try read(h.adminMac.db) { db in try HouseholdInvite.removed(db: db) }, [member], "the removal is recorded")
    }

    /// Fix round 1 (I1): Remove before her iCloud user is bound takes every invitee off the share, pending or accepted,
    /// and a late acceptance from one of them is never bound.
    func testRemoveBeforeBindingRemovesEveryInvitee() async throws {
        let h = try await ready()
        _ = try share(try await invite(h))
        // One invitation still pending, one accepted but not bound yet.
        h.cloud.invite(member, zone: household)
        h.cloud.invite("fake-pending", zone: household)
        h.cloud.accept(zone: household, as: member)
        let before = try await h.cloud.zoneShare(household)
        XCTAssertEqual(before?.participants.count, 2)
        XCTAssertNil(try memberAppUser(h).cloudKitUserRecordName, "precondition: not bound")

        try await HouseholdInvite.remove(transport: h.macTransport, member: try memberAppUser(h), db: h.adminMac.db)
        let after = try await h.cloud.zoneShare(household)
        XCTAssertEqual(after?.participants, [], "nobody left on the share")
        XCTAssertEqual(try read(h.adminMac.db) { db in try HouseholdInvite.removed(db: db) }, ["fake-member", "fake-pending"])
        XCTAssertTrue(try read(h.adminMac.db) { db in try HouseholdInvite.wasRemoved(db: db) }, "the pane shows Removed")
        do {
            _ = try await h.cloud.session(as: member).changes(since: nil, zone: household)
            XCTFail("the household is out of her reach")
        } catch SyncTransportError.zoneNotFound {}

        // A share listing her as accepted (a stale read, or a late acceptance) binds nobody.
        let stale = SyncZoneShare(zone: household, url: before?.url, ownerRecordName: TwoPersonHousehold.adminICloudUser,
                                  participants: [SyncShareParticipant(userRecordName: member, status: .accepted, canWrite: false)])
        XCTAssertEqual(try write(h.adminMac.db) { db in try HouseholdInvite.bindAcceptedParticipant(share: stale, db: db) }, .nothing)
        XCTAssertNil(try memberAppUser(h).cloudKitUserRecordName)

        // Invited again: the record clears, and her acceptance binds.
        _ = try share(try await invite(h))
        XCTAssertEqual(try read(h.adminMac.db) { db in try HouseholdInvite.removed(db: db) }, [])
        XCTAssertFalse(try read(h.adminMac.db) { db in try HouseholdInvite.wasRemoved(db: db) }, "invited again: no longer removed")
        h.cloud.invite(member, zone: household)
        h.cloud.accept(zone: household, as: member)
        let accepted = try await h.cloud.zoneShare(household)!
        XCTAssertEqual(try write(h.adminMac.db) { db in try HouseholdInvite.bindAcceptedParticipant(share: accepted, db: db) }, .bound)
    }

    /// Step 8 (was fix round 1 M2's read-only rule): the invite makes the share read-write, with no public access. Whoever
    /// is on it can write; an invitee the sheet adds later gets what the sheet gives (read-write, `allowedParticipantPermissionOptions`).
    func testShareIsReadWriteForParticipants() async throws {
        let h = try await ready()
        // Someone on the household's share read-only before the invite (as a 7a share left her).
        h.cloud.invite(member, zone: household, canWrite: false)
        h.cloud.accept(zone: household, as: member)
        let made = try share(try await invite(h))
        XCTAssertEqual(made.participants.map(\.canWrite), [true], "made read-write")
        h.cloud.invite("fake-later", zone: household, canWrite: true)
        let later = try await h.cloud.zoneShare(household)
        XCTAssertEqual(later?.participants.map(\.canWrite), [true, true], "a later invitee writes too")

        let wire = SyncWireRecord(recordType: "transaction_", recordName: UUID().uuidString.lowercased(), zone: household)
        let results = try await h.cloud.session(as: member).save([wire], ifUnchanged: [:], atomic: false)
        guard case .saved = results.first?.outcome else { return XCTFail("not saved: \(results)") }
        let stored = await h.cloud.record(named: wire.recordName)
        XCTAssertEqual(stored?.lastModifiedBy, member)
    }

    /// Fix round 1 (I2): a document file whose document isn't in the household (an orphan) fails the audit, even when
    /// this Mac doesn't know the document at all. Final review I-1: the invite cleans it first (`HouseholdOrphanFiles`).
    func testOrphanDocumentFileFailsTheAuditAndTheInviteCleansIt() async throws {
        let h = try await ready()
        let orphan = SyncDocumentFile.newRecordName(uuid: UUID().uuidString.lowercased())
        let inner = SyncWireRecord(recordType: SyncDocumentFile.recordType, recordName: orphan, zone: household,
                                   assets: ["file": Data("Synthetic private bytes".utf8)])
        let sealed = try FieldSealing.seal(inner, key: try XCTUnwrap(try h.adminKeys.key(zone: household)))
        _ = try await h.cloud.save([sealed], ifUnchanged: [:], atomic: false)

        let violations = try await HouseholdInvite.auditServer(transport: h.macTransport, keys: h.adminKeys, db: h.adminMac.db)
        XCTAssertEqual(violations.map(\.recordName), [orphan])
        _ = try share(try await invite(h))
        let left = await h.cloud.storedRecords().filter { $0.recordName == orphan }
        XCTAssertEqual(left, [], "cleaned before the audit")
        let after = try await HouseholdInvite.auditServer(transport: h.macTransport, keys: h.adminKeys, db: h.adminMac.db)
        XCTAssertEqual(after, [])
    }

    /// A file whose record is live in the household is never cleaned.
    func testFileOfALiveRecordIsNeverCleaned() async throws {
        let h = try await ready()
        let stored = await h.cloud.storedRecords()
        let record = try XCTUnwrap(stored.first { $0.zone == household && $0.recordType == "account" })
        let file = SyncDocumentFile.newRecordName(uuid: record.recordName)
        let inner = SyncWireRecord(recordType: SyncDocumentFile.recordType, recordName: file, zone: household,
                                   assets: ["file": Data("Synthetic bytes".utf8)])
        let sealed = try FieldSealing.seal(inner, key: try XCTUnwrap(try h.adminKeys.key(zone: household)))
        _ = try await h.cloud.save([sealed], ifUnchanged: [:], atomic: false)
        let removed = try await HouseholdOrphanFiles.clean(transport: h.macTransport, keys: h.adminKeys, db: h.adminMac.db)
        XCTAssertEqual(removed, 0, "its record is live there")
        let kept = await h.cloud.storedRecords().filter { $0.recordName == file }
        XCTAssertEqual(kept.count, 1)
    }

    // MARK: Step 8: letting her make changes

    /// A 7a household: shared read-only (the old rule), she accepted, the Mac bound her and has nothing left to upload.
    private func joinedReadOnly(_ h: TwoPersonHousehold) async throws -> SyncZoneShare {
        _ = try share(try await invite(h))
        h.cloud.invite(member, zone: household, canWrite: false)
        h.cloud.accept(zone: household, as: member)
        let accepted = try await h.macTransport.zoneShare(household)!
        XCTAssertEqual(try write(h.adminMac.db) { db in try HouseholdInvite.bindAcceptedParticipant(share: accepted, db: db) }, .bound)
        try await settle(h)
        XCTAssertEqual(HouseholdInvite.status(share: accepted, member: try memberAppUser(h)), .joined)
        return accepted
    }

    private func allowEdits(_ h: TwoPersonHousehold, transport: (any SyncTransport & SyncShareTransport)? = nil) async throws
        -> HouseholdInvite.Result {
        try await HouseholdInvite.allowMemberEdits(transport: transport ?? h.macTransport, keys: h.adminKeys, db: h.adminMac.db,
                                                   title: "Synthetic household")
    }

    private func canWrite(_ h: TwoPersonHousehold) async throws -> [Bool] {
        try await h.cloud.zoneShare(household)?.participants.map(\.canWrite) ?? []
    }

    func testAllowMemberEditsUpgradesReadOnlyShare() async throws {
        let h = try await ready()
        let before = try await joinedReadOnly(h)
        XCTAssertTrue(HouseholdInvite.needsEditUpgrade(before))
        XCTAssertFalse(HouseholdInvite.needsEditUpgrade(nil))
        let refused = try await h.cloud.session(as: member).save(
            [SyncWireRecord(recordType: "transaction_", recordName: "synthetic-before", zone: household)], ifUnchanged: [:], atomic: false)
        XCTAssertEqual(refused.map(\.outcome), [.failed("permissionFailure")], "read-only until the admin presses the button")

        let upgraded = try share(try await allowEdits(h))
        XCTAssertEqual(upgraded.url, before.url, "the same share")
        XCTAssertEqual(upgraded.participants, [SyncShareParticipant(userRecordName: member, status: .accepted, canWrite: true)])
        XCTAssertFalse(HouseholdInvite.needsEditUpgrade(upgraded))
        XCTAssertEqual(try memberAppUser(h).cloudKitUserRecordName, member, "still bound")
        let saved = try await h.cloud.session(as: member).save(
            [SyncWireRecord(recordType: "transaction_", recordName: "synthetic-after", zone: household)], ifUnchanged: [:], atomic: false)
        guard case .saved = saved.first?.outcome else { return XCTFail("not saved: \(saved)") }
        XCTAssertEqual(h.audit.householdViolations(router: h.adminRouter()), [])
    }

    /// Pressing the button again (or after another Mac upgraded it) keeps the one share and saves nothing.
    func testAllowMemberEditsTwiceKeepsOneShare() async throws {
        let h = try await ready()
        _ = try await joinedReadOnly(h)
        let counting = CountingShareTransport(inner: h.macTransport)
        let first = try share(try await allowEdits(h, transport: counting))
        let second = try share(try await allowEdits(h, transport: counting))
        XCTAssertEqual(second.url, first.url)
        XCTAssertEqual(second, first)
        let writes1 = try await canWrite(h)
        XCTAssertEqual(writes1, [true])
        let made = await counting.made
        XCTAssertEqual(made, 1, "the second press finds nothing to change")
    }

    /// Something blocks: the share stays read-only; once clear, the same press upgrades it.
    func testAllowMemberEditsBlockedKeepsShareReadOnly() async throws {
        let h = try await ready()
        let before = try await joinedReadOnly(h)
        try write(h.adminMac.db) { db in
            try db.execute(sql: "UPDATE transaction_ SET note = 'Synthetic note' WHERE id = ?", arguments: [h.fixture.sharedTransaction])
        }
        let blocked = try await allowEdits(h)
        XCTAssertEqual(blocked, .blocked([.pendingUpload(1)]))
        let writes2 = try await canWrite(h)
        XCTAssertEqual(writes2, [false])
        let offline = try await allowEdits(h, transport: OfflineShareTransport())
        XCTAssertEqual(offline, .blocked([.offline]))

        try await settle(h)
        let upgraded = try share(try await allowEdits(h))
        XCTAssertEqual(upgraded.url, before.url)
        let writes3 = try await canWrite(h)
        XCTAssertEqual(writes3, [true])
    }

    /// The server audit finds a private record in `household`: nothing changes about the share.
    func testAllowMemberEditsAuditViolationKeepsShareReadOnly() async throws {
        let h = try await ready()
        _ = try await joinedReadOnly(h)
        let f = h.fixture
        let leaking = try h.uuid("transaction_", f.privateTransaction)
        let original = try await h.cloud.fetch(leaking, zone: f.privateZone)
        var payload = try SyncLargePayload.payload(from: XCTUnwrap(original), keys: try h.adminKeys.allKeys(zone: f.privateZone))
        payload.zone = household
        payload.serverWriter = nil
        let (planted, _) = try SyncLargePayload.wire(for: payload, key: try XCTUnwrap(try h.adminKeys.key(zone: household)))
        _ = try await h.cloud.save([planted], ifUnchanged: [:], atomic: false)

        let result = try await allowEdits(h)
        XCTAssertEqual(result, .blocked([.householdAudit(1)]))
        let writes4 = try await canWrite(h)
        XCTAssertEqual(writes4, [false])
        XCTAssertEqual(HouseholdCopy.blocker(.householdAudit(1), alreadyShared: true),
                       "1 record in the household shouldn't be there. Nothing new was shared.")
    }

    func testEditsCopy() {
        XCTAssertEqual(HouseholdCopy.editsAllowed("Person B"), "Person B can make changes within their permissions.")
        XCTAssertEqual(HouseholdCopy.editsWaiting("Person B"), "Person B can view only for now:")
        XCTAssertEqual(HouseholdCopy.allowEditsButton("Person B"), "Let Person B make changes")
    }

    func testCopy() {
        XCTAssertEqual(HouseholdCopy.paneTitle, "Household")
        XCTAssertEqual(HouseholdCopy.addTitle, "Add someone to the household")
        XCTAssertEqual(HouseholdCopy.addField, "Name")
        XCTAssertEqual(HouseholdCopy.addButton, "Add")
        XCTAssertEqual(HouseholdCopy.inviteButton, "Invite…")
        XCTAssertEqual(HouseholdCopy.inviteExplainer("Person B"),
                       "Invite Person B to Mango. They'll see what your sharing levels allow, and can change documents, imports and property; your Mac checks every change.")
        XCTAssertEqual(HouseholdCopy.status(.notInvited), "Not invited yet")
        XCTAssertEqual(HouseholdCopy.status(.invited), "Invited — waiting for them to accept")
        XCTAssertEqual(HouseholdCopy.removeButton, "Remove from household…")
        XCTAssertEqual(HouseholdCopy.removeTitle("Person B"), "Remove Person B from the household?")
        XCTAssertEqual(HouseholdCopy.removeMessage, "Their devices stop syncing and delete the household's data. Your data stays on this Mac.")
        XCTAssertEqual(HouseholdCopy.accountChangedNotice,
                       "This device's iCloud account changed. Mango removed the previous person's private data.")
    }

    // MARK: Helpers

    private func read<T>(_ db: DatabaseQueue, _ body: (Database) throws -> T) throws -> T { try db.read(body) }
    private func read<T>(_ device: TwoPersonHousehold.Device, _ body: (Database) throws -> T) throws -> T { try device.db.read(body) }
    private func write<T>(_ db: DatabaseQueue, _ body: (Database) throws -> T) throws -> T { try db.write(body) }
}

/// iCloud out of reach: every call fails with a passing error.
private struct OfflineShareTransport: SyncTransport, SyncShareTransport {
    func operationLimits() async -> SyncOperationLimits { SyncOperationLimits(maxRecords: 400, maxBytes: 1_000_000) }
    func createZone(_ zone: String) async throws { throw SyncTransportError.networkUnavailable }
    func save(_ records: [SyncWireRecord], ifUnchanged: [String: Data], atomic: Bool) async throws -> [SaveResult] {
        throw SyncTransportError.networkUnavailable
    }
    func changes(since token: Data?, zone: String) async throws -> SyncChanges { throw SyncTransportError.networkUnavailable }
    func delete(_ recordNames: [String], zone: String) async throws { throw SyncTransportError.networkUnavailable }
    func fetch(_ recordName: String, zone: String) async throws -> SyncServerRecord? { throw SyncTransportError.networkUnavailable }
    func serverTime() async throws -> Date? { throw SyncTransportError.networkUnavailable }
    func currentUserRecordName() async throws -> String { throw SyncTransportError.networkUnavailable }
    func zoneShare(_ zone: String) async throws -> SyncZoneShare? { throw SyncTransportError.networkUnavailable }
    func makeZoneShare(_ zone: String, title: String) async throws -> SyncZoneShare { throw SyncTransportError.networkUnavailable }
    func removeParticipant(userRecordName: String, zone: String) async throws { throw SyncTransportError.networkUnavailable }
    func removeAllParticipants(zone: String) async throws -> [String] { throw SyncTransportError.networkUnavailable }
}

/// Counts the shares made or changed (`makeZoneShare`); everything else goes to the wrapped transport.
private actor CountingShareTransport: SyncTransport, SyncShareTransport {
    let inner: any SyncTransport & SyncShareTransport
    private(set) var made = 0
    init(inner: any SyncTransport & SyncShareTransport) { self.inner = inner }

    func operationLimits() async -> SyncOperationLimits { await inner.operationLimits() }
    func createZone(_ zone: String) async throws { try await inner.createZone(zone) }
    func save(_ records: [SyncWireRecord], ifUnchanged: [String: Data], atomic: Bool) async throws -> [SaveResult] {
        try await inner.save(records, ifUnchanged: ifUnchanged, atomic: atomic)
    }
    func changes(since token: Data?, zone: String) async throws -> SyncChanges { try await inner.changes(since: token, zone: zone) }
    func delete(_ recordNames: [String], zone: String) async throws { try await inner.delete(recordNames, zone: zone) }
    func fetch(_ recordName: String, zone: String) async throws -> SyncServerRecord? { try await inner.fetch(recordName, zone: zone) }
    func serverTime() async throws -> Date? { try await inner.serverTime() }
    func currentUserRecordName() async throws -> String { try await inner.currentUserRecordName() }
    func zoneShare(_ zone: String) async throws -> SyncZoneShare? { try await inner.zoneShare(zone) }
    func makeZoneShare(_ zone: String, title: String) async throws -> SyncZoneShare {
        made += 1
        return try await inner.makeZoneShare(zone, title: title)
    }
    func removeParticipant(userRecordName: String, zone: String) async throws {
        try await inner.removeParticipant(userRecordName: userRecordName, zone: zone)
    }
    func removeAllParticipants(zone: String) async throws -> [String] { try await inner.removeAllParticipants(zone: zone) }
}

/// The stages a press reported, in order.
private final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [HouseholdInvite.Stage] = []
    func add(_ stage: HouseholdInvite.Stage) { lock.withLock { stages.append(stage) } }
    var all: [HouseholdInvite.Stage] { lock.withLock { stages } }
}

/// iCloud that answers after `delay` (an hour: never, for a test), counting the household reads with and without the
/// documents' contents. Waits are cancellable, as a CloudKit operation is.
private actor DelayedShareTransport: SyncTransport, SyncShareTransport {
    let inner: any SyncTransport & SyncShareTransport
    let delay: Duration
    private(set) var reads = (full: 0, withoutFiles: 0)
    init(inner: any SyncTransport & SyncShareTransport, delay: Duration = .zero) {
        self.inner = inner
        self.delay = delay
    }

    private func wait() async throws { if delay > .zero { try await Task.sleep(for: delay) } }

    func operationLimits() async -> SyncOperationLimits { await inner.operationLimits() }
    func createZone(_ zone: String) async throws { try await wait(); try await inner.createZone(zone) }
    func save(_ records: [SyncWireRecord], ifUnchanged: [String: Data], atomic: Bool) async throws -> [SaveResult] {
        try await wait()
        return try await inner.save(records, ifUnchanged: ifUnchanged, atomic: atomic)
    }
    func changes(since token: Data?, zone: String) async throws -> SyncChanges {
        reads.full += 1
        try await wait()
        return try await inner.changes(since: token, zone: zone)
    }
    func changesWithoutFiles(since token: Data?, zone: String) async throws -> SyncChanges {
        reads.withoutFiles += 1
        try await wait()
        return try await inner.changes(since: token, zone: zone)
    }
    func delete(_ recordNames: [String], zone: String) async throws { try await wait(); try await inner.delete(recordNames, zone: zone) }
    func fetch(_ recordName: String, zone: String) async throws -> SyncServerRecord? {
        try await wait()
        return try await inner.fetch(recordName, zone: zone)
    }
    func serverTime() async throws -> Date? { try await inner.serverTime() }
    func currentUserRecordName() async throws -> String { try await inner.currentUserRecordName() }
    func zoneShare(_ zone: String) async throws -> SyncZoneShare? { try await wait(); return try await inner.zoneShare(zone) }
    func makeZoneShare(_ zone: String, title: String) async throws -> SyncZoneShare {
        try await wait()
        return try await inner.makeZoneShare(zone, title: title)
    }
    func removeParticipant(userRecordName: String, zone: String) async throws {
        try await inner.removeParticipant(userRecordName: userRecordName, zone: zone)
    }
    func removeAllParticipants(zone: String) async throws -> [String] { try await inner.removeAllParticipants(zone: zone) }
}
