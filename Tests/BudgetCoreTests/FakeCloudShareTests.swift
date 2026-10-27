import XCTest
@testable import BudgetCore

/// The FakeCloud's zone share (step 7a Task 1): per-user sessions, invite / accept / remove, the server's writer.
final class FakeCloudShareTests: XCTestCase {
    private let zone = SyncZones.household
    private let member = "fake-member"

    private func wire(_ name: String, zone: String? = nil) -> SyncWireRecord {
        SyncWireRecord(recordType: "note", recordName: name, zone: zone ?? self.zone, encryptedFields: ["sealed": Data([1, 2, 3])])
    }

    /// A cloud whose owner made the household zone and shared it with the member, who accepted.
    private func sharedCloud(canWrite: Bool = true) async throws -> FakeCloud {
        let cloud = FakeCloud()
        try await cloud.createZone(zone)
        cloud.invite(member, zone: zone, canWrite: canWrite)
        cloud.accept(zone: zone, as: member)
        return cloud
    }

    private func assertZoneNotFound(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected zoneNotFound", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SyncTransportError, .zoneNotFound(zone), file: file, line: line)
        }
    }

    func testSavesCarryTheActingUser() async throws {
        let cloud = try await sharedCloud()
        _ = try await cloud.save([wire("by-owner")], ifUnchanged: [:], atomic: true)
        let results = try await cloud.session(as: member).save([wire("by-member")], ifUnchanged: [:], atomic: true)
        guard case .saved = results.first?.outcome else { return XCTFail("not saved: \(results)") }

        let feed = try await cloud.changes(since: nil, zone: zone)
        let writers = Dictionary(uniqueKeysWithValues: feed.records.map { ($0.wire.recordName, $0.lastModifiedBy) })
        XCTAssertEqual(writers["by-member"], "fake-member")
        XCTAssertEqual(writers["by-owner"], "fake-owner")
        let fetched = try await cloud.session(as: member).fetch("by-owner", zone: zone)
        XCTAssertEqual(fetched?.lastModifiedBy, "fake-owner")

        // A new version by the owner is the owner's; a deletion is stamped with who deleted.
        let memberRecord = await cloud.record(named: "by-member")
        let memberVersion = try XCTUnwrap(memberRecord)
        let overwrite = try await cloud.save([wire("by-member")], ifUnchanged: ["by-member": memberVersion.stamp.systemFields], atomic: true)
        guard case .saved = overwrite.first?.outcome else { return XCTFail("not saved: \(overwrite)") }
        let overwritten = await cloud.record(named: "by-member")
        XCTAssertEqual(overwritten?.lastModifiedBy, "fake-owner")
        try await cloud.session(as: member).delete(["by-owner"], zone: zone)
        let deletedBy = await cloud.deletedBy("by-owner", zone: zone)
        XCTAssertEqual(deletedBy, "fake-member")
    }

    func testNonParticipantGetsZoneNotFound() async throws {
        let cloud = try await sharedCloud()
        _ = try await cloud.save([wire("r1")], ifUnchanged: [:], atomic: true)
        let stranger = cloud.session(as: "fake-stranger")
        await assertZoneNotFound { _ = try await stranger.changes(since: nil, zone: self.zone) }
        await assertZoneNotFound { _ = try await stranger.fetch("r1", zone: self.zone) }
        await assertZoneNotFound { try await stranger.delete(["r1"], zone: self.zone) }
        await assertZoneNotFound { try await stranger.createZone(self.zone) }
        await assertZoneNotFound { _ = try await stranger.zoneShare(self.zone) }
        let results = try await stranger.save([wire("r2")], ifUnchanged: [:], atomic: true)
        XCTAssertEqual(results.map(\.outcome), [.zoneNotFound])
        let stored = await cloud.storedRecords().map(\.recordName)
        XCTAssertEqual(stored, ["r1"])
    }

    func testInvitedButNotAcceptedCannotRead() async throws {
        let cloud = FakeCloud()
        try await cloud.createZone(zone)
        cloud.invite(member, zone: zone)
        let share = try await cloud.zoneShare(zone)
        XCTAssertEqual(share?.participants, [SyncShareParticipant(userRecordName: member, status: .invited, canWrite: true)])
        let session = cloud.session(as: member)
        await assertZoneNotFound { _ = try await session.changes(since: nil, zone: self.zone) }
        let results = try await session.save([wire("r1")], ifUnchanged: [:], atomic: true)
        XCTAssertEqual(results.map(\.outcome), [.zoneNotFound])
    }

    func testAcceptedParticipantReadsAndWrites() async throws {
        let cloud = try await sharedCloud()
        _ = try await cloud.save([wire("by-owner")], ifUnchanged: [:], atomic: true)
        let session = cloud.session(as: member)
        let currentUser = try await session.currentUserRecordName()
        XCTAssertEqual(currentUser, member)
        let feed = try await session.changes(since: nil, zone: zone)
        XCTAssertEqual(feed.records.map(\.wire.recordName), ["by-owner"])
        do {
            try await session.createZone(zone)
            XCTFail("a participant saved the owner's zone")
        } catch {
            XCTAssertEqual(error as? FakeCloudError, .permissionFailure)
        }
        do {
            try await session.deleteZone(zone)
            XCTFail("a participant deleted the owner's zone")
        } catch {
            XCTAssertEqual(error as? FakeCloudError, .permissionFailure)
        }
        let results = try await session.save([wire("by-member")], ifUnchanged: [:], atomic: true)
        guard case .saved = results.first?.outcome else { return XCTFail("not saved: \(results)") }
        let names = await cloud.storedRecords().map(\.recordName)
        XCTAssertEqual(names, ["by-member", "by-owner"])
        let share = try await session.zoneShare(zone)
        XCTAssertEqual(share?.ownerRecordName, "fake-owner")
        XCTAssertEqual(share?.participants, [SyncShareParticipant(userRecordName: member, status: .accepted, canWrite: true)])

        // Her own zone is hers: the owner can't reach it.
        let mine = "private-member"
        try await session.createZone(mine)
        _ = try await session.save([wire("hers", zone: mine)], ifUnchanged: [:], atomic: true)
        do {
            _ = try await cloud.changes(since: nil, zone: mine)
            XCTFail("the owner reached the member's zone")
        } catch {
            XCTAssertEqual(error as? SyncTransportError, .zoneNotFound(mine))
        }
    }

    func testReadOnlyParticipantSaveRefused() async throws {
        let cloud = try await sharedCloud(canWrite: false)
        _ = try await cloud.save([wire("by-owner")], ifUnchanged: [:], atomic: true)
        let session = cloud.session(as: member)
        let feed = try await session.changes(since: nil, zone: zone)
        XCTAssertEqual(feed.records.map(\.wire.recordName), ["by-owner"])
        let results = try await session.save([wire("by-member")], ifUnchanged: [:], atomic: true)
        XCTAssertEqual(results.map(\.outcome), [.failed("permissionFailure")])
        do {
            try await session.delete(["by-owner"], zone: zone)
            XCTFail("a read-only participant deleted")
        } catch {
            XCTAssertEqual(error as? FakeCloudError, .permissionFailure)
        }
        let names = await cloud.storedRecords().map(\.recordName)
        XCTAssertEqual(names, ["by-owner"])
    }

    func testRemovedParticipantGetsZoneNotFound() async throws {
        let cloud = try await sharedCloud()
        let session = cloud.session(as: member)
        _ = try await session.changes(since: nil, zone: zone)
        try await cloud.removeParticipant(userRecordName: member, zone: zone)
        await assertZoneNotFound { _ = try await session.changes(since: nil, zone: self.zone) }
        await assertZoneNotFound { _ = try await session.fetch("anything", zone: self.zone) }
        let results = try await session.save([wire("r1")], ifUnchanged: [:], atomic: true)
        XCTAssertEqual(results.map(\.outcome), [.zoneNotFound])
        let share = try await cloud.zoneShare(zone)
        XCTAssertEqual(share?.participants, [])
    }

    /// Only the owner edits the share: she leaves by deleting it from her shared database, as in CloudKit.
    func testParticipantLeavesByDeletingTheShare() async throws {
        let cloud = try await sharedCloud()
        let session = cloud.session(as: member)
        do {
            try await session.removeParticipant(userRecordName: member, zone: zone)
            XCTFail("a participant edited the share")
        } catch {
            XCTAssertEqual(error as? FakeCloudError, .permissionFailure)
        }
        try await session.delete([FakeCloud.zoneShareRecordName], zone: zone)
        await assertZoneNotFound { _ = try await session.changes(since: nil, zone: self.zone) }
        let share = try await cloud.zoneShare(zone)
        XCTAssertEqual(share?.participants, [], "the owner's zone and share stay")
    }

    func testMakeZoneShareIsIdempotent() async throws {
        let cloud = FakeCloud()
        try await cloud.createZone(zone)
        let none = try await cloud.zoneShare(zone)
        XCTAssertNil(none)
        let first = try await cloud.makeZoneShare(zone, title: "Household")
        XCTAssertEqual(first.ownerRecordName, "fake-owner")
        XCTAssertEqual(first.zone, zone)
        XCTAssertNotNil(first.url)
        XCTAssertEqual(first.participants, [])
        cloud.invite(member, zone: zone)
        let second = try await cloud.makeZoneShare(zone, title: "Household")
        XCTAssertEqual(second.url, first.url)
        XCTAssertEqual(second.participants.map(\.userRecordName), [member])
        let fetched = try await cloud.zoneShare(zone)
        XCTAssertEqual(fetched, second)
    }

    // MARK: Step 8: the share is read-write

    /// A read-only participant (as a 7a share left her) can write once the owner's `makeZoneShare` upgrades the share.
    func testMadeShareLetsParticipantWrite() async throws {
        let cloud = try await sharedCloud(canWrite: false)
        let session = cloud.session(as: member)
        let refused = try await session.save([wire("before")], ifUnchanged: [:], atomic: true)
        XCTAssertEqual(refused.map(\.outcome), [.failed("permissionFailure")], "read-only until the upgrade")

        let made = try await cloud.makeZoneShare(zone, title: "Household")
        XCTAssertEqual(made.participants, [SyncShareParticipant(userRecordName: member, status: .accepted, canWrite: true)])
        let results = try await session.save([wire("by-member")], ifUnchanged: [:], atomic: true)
        guard case .saved = results.first?.outcome else { return XCTFail("not saved: \(results)") }
        let stored = await cloud.record(named: "by-member")
        XCTAssertEqual(stored?.lastModifiedBy, "fake-member")
        let again = try await cloud.makeZoneShare(zone, title: "Household")
        XCTAssertEqual(again, made, "the same share, upgraded in place")
    }

    /// Upgrading the share gives nobody else access: no public access, and someone it doesn't list can't reach the zone.
    func testUninvitedUserStillCannotReach() async throws {
        let cloud = try await sharedCloud(canWrite: false)
        _ = try await cloud.save([wire("r1")], ifUnchanged: [:], atomic: true)
        _ = try await cloud.makeZoneShare(zone, title: "Household")
        let stranger = cloud.session(as: "fake-stranger")
        cloud.accept(zone: zone, as: "fake-stranger")
        await assertZoneNotFound { _ = try await stranger.changes(since: nil, zone: self.zone) }
        await assertZoneNotFound { _ = try await stranger.fetch("r1", zone: self.zone) }
        await assertZoneNotFound { try await stranger.delete(["r1"], zone: self.zone) }
        let results = try await stranger.save([wire("r2")], ifUnchanged: [:], atomic: true)
        XCTAssertEqual(results.map(\.outcome), [.zoneNotFound])
        let share = try await cloud.zoneShare(zone)
        XCTAssertEqual(share?.participants.map(\.userRecordName), [member])
    }

    /// Removed from a read-write share, she can't write, and neither accepting again nor another upgrade brings her back.
    func testRemovedParticipantCannotWrite() async throws {
        let cloud = try await sharedCloud(canWrite: false)
        _ = try await cloud.makeZoneShare(zone, title: "Household")
        let session = cloud.session(as: member)
        let before = try await session.save([wire("r1")], ifUnchanged: [:], atomic: true)
        guard case .saved = before.first?.outcome else { return XCTFail("not saved: \(before)") }

        try await cloud.removeParticipant(userRecordName: member, zone: zone)
        cloud.accept(zone: zone, as: member)
        let upgraded = try await cloud.makeZoneShare(zone, title: "Household")
        XCTAssertEqual(upgraded.participants, [])
        let results = try await session.save([wire("r2")], ifUnchanged: [:], atomic: true)
        XCTAssertEqual(results.map(\.outcome), [.zoneNotFound])
        await assertZoneNotFound { _ = try await session.changes(since: nil, zone: self.zone) }
        await assertZoneNotFound { try await session.delete(["r1"], zone: self.zone) }
        let names = await cloud.storedRecords().map(\.recordName)
        XCTAssertEqual(names, ["r1"])
    }

    func testSplitTransportRoutesHouseholdToSharedSide() async throws {
        let cloud = try await sharedCloud()
        let own = FakeCloud(limits: SyncOperationLimits(maxRecords: 100, maxBytes: 5_000_000), ownerRecordName: member)
        let split = SyncZoneSplitTransport(household: cloud.session(as: member), others: own)
        let mine = "private-member"
        try await split.createZone(zone)  // the admin's: nothing is made through her shared database
        try await split.createZone(mine)
        let made = await cloud.calls.filter { if case .createZone = $0 { return true } else { return false } }
        XCTAssertEqual(made, [.createZone(zone)], "only the owner's own creation in the setup")
        let results = try await split.save([wire("h1"), wire("p1", zone: mine), wire("h2")], ifUnchanged: [:], atomic: false)
        XCTAssertEqual(results.map(\.recordName), ["h1", "p1", "h2"])
        let shared = await cloud.storedRecords().map(\.recordName)
        XCTAssertEqual(shared, ["h1", "h2"])
        let ownNames = await own.storedRecords().map(\.recordName)
        XCTAssertEqual(ownNames, ["p1"])
        let householdFeed = try await split.changes(since: nil, zone: zone)
        XCTAssertEqual(householdFeed.records.map(\.lastModifiedBy), [member, member])
        let fetched = try await split.fetch("p1", zone: mine)
        XCTAssertEqual(fetched?.wire.recordName, "p1")
        try await split.delete(["h1"], zone: zone)
        let afterDelete = await cloud.storedRecords().map(\.recordName)
        XCTAssertEqual(afterDelete, ["h2"])
        let limits = await split.operationLimits()
        XCTAssertEqual(limits, SyncOperationLimits(maxRecords: 100, maxBytes: 2_000_000))
    }
}
