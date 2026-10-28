import XCTest
import GRDB
import CryptoKit
@testable import BudgetCore
import TestSupport

/// Step 15: a new household key when someone is removed, and the re-seal sweep (sync spec §9.1 "Rotation"). Two Macs
/// sharing one iCloud Keychain (`InMemorySyncKeyStore`) through the CloudKit fake. Synthetic data only.
final class KeyRotationTests: XCTestCase {
    private var cloud: FakeCloud!
    private var keys: InMemorySyncKeyStore!
    private var a: DocumentSyncTestDevice!
    private var b: DocumentSyncTestDevice!
    private let zone = SyncZones.household
    private static let day = Date(timeIntervalSince1970: 1_700_000_000)
    private static let marker = "Synthetic invoice — amount 98.76 — never real"

    override func setUp() async throws {
        try await makeDevices(cloud: FakeCloud())
    }

    private func makeDevices(cloud: FakeCloud) async throws {
        self.cloud = cloud
        keys = InMemorySyncKeyStore()
        a = try DocumentSyncTestDevice("user-a", transport: cloud, keys: keys)
        b = try DocumentSyncTestDevice("user-b", transport: cloud, keys: keys)
    }

    private static func bytes(_ name: String) -> Data {
        Data("\(marker) \(name)".utf8) + Data((0..<4096).map { UInt8(($0 * 11) % 251) })
    }

    /// An account and `count` transactions on `device`.
    @discardableResult
    private func transactions(_ device: DocumentSyncTestDevice, count: Int, prefix: String = "Shop") throws -> [Int64] {
        try device.write { db in
            var account = Account(name: "Current \(prefix)", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "synthetic.csv", importedAt: Self.day)
            try batch.insert(db)
            return try (0..<count).map { i in
                var t = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Self.day, rawDescription: "\(prefix) \(i)",
                                    amountMinorUnits: -100 * (i + 1), categoryId: nil, status: .pendingReview, categorizedBy: .none,
                                    fingerprint: "fp-\(prefix)-\(i)", isManual: true)
                try t.insert(db)
                return t.id!
            }
        }
    }

    /// The marker's key id on the server.
    private func currentKeyId() async throws -> String {
        let wire = await cloud.storedRecords().first { $0.recordType == SyncZoneKeys.recordType }
        return try SyncZoneKeys.marker(from: try XCTUnwrap(wire)).keyId
    }

    /// Every record the sweep is about: sealed under a zone key (not the marker, not a document file, not the exchange's).
    private func sealedRecords() async -> [SyncWireRecord] {
        let leftAlone = Set([SyncZoneKeys.recordType, SyncDocumentFile.recordType]).union(SyncKeyExchange.recordTypes)
        return await cloud.storedRecords().filter { $0.zone == zone && !leftAlone.contains($0.recordType) }
    }

    private func saves(since index: Int) async -> [String] {
        let calls = await cloud.calls
        return calls.dropFirst(index).flatMap { call -> [String] in
            if case .save(let names, _) = call { return names } else { return [] }
        }
    }

    // MARK: The sweep

    func testSweepResealsEveryOldKeyRecordSoTheRetiredKeyOpensNone() async throws {
        try transactions(a, count: 6)
        let (_, document) = try a.add("one.pdf", Self.bytes("one"))
        try await a.engine.syncNow()
        try await b.engine.syncNow()
        let retiredId = try await currentKeyId()
        let retired = try XCTUnwrap(try keys.allKeys(zone: zone)[retiredId])

        try await a.engine.rotateZoneKey()
        let newId = try await currentKeyId()
        XCTAssertNotEqual(newId, retiredId)
        let beforeSweep = await sealedRecords().filter { FieldSealing.keyId(of: $0) == retiredId }
        XCTAssertFalse(beforeSweep.isEmpty, "rotation alone re-wraps; records keep the retired key until the sweep")

        let report = try await a.engine.resealSweep()
        XCTAssertEqual(report.remaining, 0)
        XCTAssertEqual(report.resealed, beforeSweep.count)

        let after = await sealedRecords()
        XCTAssertFalse(after.isEmpty)
        for record in after {
            XCTAssertEqual(FieldSealing.keyId(of: record), newId, "\(record.recordType) still sealed under another key")
            XCTAssertThrowsError(try FieldSealing.open(record, keys: [retiredId: retired]))
        }
        // The document's data key: re-wrapped, and the retired key can't unwrap it.
        let payload = try await cloud.payload(named: document, keys: keys)
        let reference = try XCTUnwrap(payload?.documentFile)
        XCTAssertEqual(try DocumentCrypto.zoneKeyId(ofWrapped: reference.wrappedKey), newId)

        // Written after the rotation: sealed under the new key only.
        let added = try transactions(a, count: 1, prefix: "After")
        try await a.engine.syncNow()
        let uuid = try a.read { db in try XCTUnwrap(SyncRecordStore.existingUUID(table: "transaction_", localId: added[0], db: db)) }
        let stored = await cloud.record(named: uuid)
        let fresh = try XCTUnwrap(stored)
        XCTAssertEqual(FieldSealing.keyId(of: fresh.wire), newId)
        XCTAssertThrowsError(try FieldSealing.open(fresh.wire, keys: [retiredId: retired]))

        // The other Mac reads everything as before.
        try await b.engine.syncNow()
        let descriptions = try b.read { db in try String.fetchAll(db, sql: "SELECT rawDescription FROM transaction_ ORDER BY rawDescription") }
        XCTAssertEqual(descriptions, ["After 0"] + (0..<6).map { "Shop \($0)" })
    }

    func testTheSweepingMacHoldsItsOwnResealsAndPullsNothingBack() async throws {
        try transactions(a, count: 3)
        try await a.engine.syncNow()
        try await a.engine.rotateZoneKey()
        try await a.engine.resealSweep()
        let tags = try a.read { db in try Row.fetchAll(db, sql: "SELECT uuid, changeTag FROM syncRecord WHERE changeTag IS NOT NULL") }
        XCTAssertFalse(tags.isEmpty)
        for row in tags {
            let uuid: String = row["uuid"]
            let server = await cloud.record(named: uuid)
            XCTAssertEqual(server?.stamp.changeTag, row["changeTag"], "the Mac holds the version its sweep saved")
        }
        let pulled = try await a.engine.pull()
        XCTAssertEqual(pulled.received, pulled.alreadyHeld, "nothing comes back as a change")
    }

    func testSweepResumesAfterAnInterruptionAndKeepsCounting() async throws {
        try await makeDevices(cloud: FakeCloud(limits: SyncOperationLimits(maxRecords: 3, maxBytes: 2_000_000)))
        try transactions(a, count: 10)
        try await a.engine.syncNow()
        try await a.engine.rotateZoneKey()
        let newId = try await currentKeyId()
        let stale = await sealedRecords().filter { FieldSealing.keyId(of: $0) != newId }.count
        XCTAssertGreaterThan(stale, 6)

        await cloud.failSaveOperations(after: 1)
        do {
            try await a.engine.resealSweep()
            XCTFail("the dropped connection stops the sweep")
        } catch let error as SyncTransportError {
            XCTAssertEqual(error, .networkUnavailable)
        }
        let midway = try a.read { db in try SyncKeyRotation.state(db: db).progress }
        XCTAssertEqual(midway.done, 3)
        XCTAssertEqual(midway.total, stale)

        await cloud.restoreConnection()
        let seen = RotationProgressLog()
        let report = try await a.engine.resealSweep { seen.append($0) }
        XCTAssertEqual(report.remaining, 0)
        XCTAssertEqual(report.resealed, stale - 3)
        XCTAssertEqual(report.progress, SyncKeyRotation.Progress(done: stale, total: stale))
        XCTAssertEqual(seen.values.last, SyncKeyRotation.Progress(done: stale, total: stale))
        XCTAssertTrue(seen.values.allSatisfy { $0.total == stale }, "the total stays what the sweep found")
        let left = await sealedRecords().filter { FieldSealing.keyId(of: $0) != newId }
        XCTAssertEqual(left, [])
    }

    func testSweepRewrapsDocumentsWithoutUploadingFilesAndNoAssetHoldsPlaintext() async throws {
        let first = Self.bytes("first")
        let (_, one) = try a.add("first.pdf", first)
        let (_, two) = try a.add("second.pdf", Self.bytes("second"))
        try await a.engine.syncNow()
        // Sealed before this Mac re-wraps: a record the rotation's push doesn't reach (here, the reference kept on the
        // other Mac only).
        try a.write { db in
            try SyncDocumentFile.setReference(nil, uuid: two, db: db, now: Date())
        }
        let filesBefore = await cloud.storedRecords().filter { $0.recordType == SyncDocumentFile.recordType }
        try await a.engine.rotateZoneKey()
        let newId = try await currentKeyId()
        let mark = await cloud.calls.count
        try await a.engine.resealSweep()

        let saved = await saves(since: mark)
        let fileRecords = Set(filesBefore.map(\.recordName))
        XCTAssertTrue(saved.allSatisfy { !fileRecords.contains($0) }, "no document file saved again")
        let filesAfter = await cloud.storedRecords().filter { $0.recordType == SyncDocumentFile.recordType }
        XCTAssertEqual(filesAfter, filesBefore, "the ciphertext is untouched")
        for uuid in [one, two] {
            let payload = try await cloud.payload(named: uuid, keys: keys)
            let reference = try XCTUnwrap(payload?.documentFile)
            XCTAssertEqual(try DocumentCrypto.zoneKeyId(ofWrapped: reference.wrappedKey), newId)
        }
        // No uploaded asset, and no field, holds the plaintext.
        let needle = Data(Self.marker.utf8)
        for record in await cloud.storedRecords() {
            for data in Array(record.assets.values) + Array(record.encryptedFields.values) {
                XCTAssertNil(data.range(of: needle), "\(record.recordType) carries plaintext")
            }
        }
        // The other Mac still opens the file with the new key.
        try await b.engine.syncNow()
        XCTAssertEqual(try b.file(uuid: one), first)
    }
}

/// Collects the sweep's progress reports.
private final class RotationProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SyncKeyRotation.Progress] = []
    func append(_ value: SyncKeyRotation.Progress) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [SyncKeyRotation.Progress] { lock.lock(); defer { lock.unlock() }; return stored }
}

/// A share transport that can't reach iCloud.
private struct OfflineShareTransport: SyncShareTransport {
    func currentUserRecordName() async throws -> String { throw SyncTransportError.networkUnavailable }
    func zoneShare(_ zone: String) async throws -> SyncZoneShare? { throw SyncTransportError.networkUnavailable }
    func makeZoneShare(_ zone: String, title: String) async throws -> SyncZoneShare { throw SyncTransportError.networkUnavailable }
    func removeParticipant(userRecordName: String, zone: String) async throws { throw SyncTransportError.networkUnavailable }
    func removeAllParticipants(zone: String) async throws -> [String] { throw SyncTransportError.networkUnavailable }
}

/// Step 15 through the household: the admin removes the member (Settings ▸ Household ▸ Remove), the household gets a
/// new key, every record is sealed again, and a re-invited member receives the new key only. `TwoPersonHousehold`
/// over the CloudKit fake; synthetic data only.
final class HouseholdRemovalTests: XCTestCase {
    private let household = SyncZones.household
    private let member = TwoPersonHousehold.memberICloudUser
    private let owner = TwoPersonHousehold.adminICloudUser

    private func memberUser(_ h: TwoPersonHousehold) throws -> AppUser {
        try XCTUnwrap(try h.adminMac.db.read { db in try HouseholdInvite.member(db: db) })
    }

    private func markerKeyId(_ h: TwoPersonHousehold) async throws -> String {
        let wire = await h.cloud.storedRecords().first { $0.recordType == SyncZoneKeys.recordType && $0.zone == household }
        return try SyncZoneKeys.marker(from: try XCTUnwrap(wire)).keyId
    }

    private func householdSealed(_ h: TwoPersonHousehold) async -> [SyncWireRecord] {
        let leftAlone = Set([SyncZoneKeys.recordType, SyncDocumentFile.recordType]).union(SyncKeyExchange.recordTypes)
        return await h.cloud.storedRecords().filter { $0.zone == household && !leftAlone.contains($0.recordType) }
    }

    private func participants(_ h: TwoPersonHousehold) async throws -> [String] {
        try await h.cloud.zoneShare(household)?.participants.map(\.userRecordName) ?? []
    }

    func testRemovalRevokesTheShareThenRotatesAndResealsEverything() async throws {
        let h = try TwoPersonHousehold.make()
        try await h.syncAll()
        let oldId = try await markerKeyId(h)
        let old = try XCTUnwrap(try h.memberKeys.allKeys(zone: household)[oldId], "her device holds the household key")
        let seen = RotationProgressLog()

        let outcome = try await HouseholdRemoval.remove(transport: h.cloud, engine: h.adminMac.engine, member: try memberUser(h),
                                                        db: h.adminMac.db) { seen.append($0) }
        guard case .removed(let report) = outcome else { return XCTFail("not secured: \(outcome)") }
        XCTAssertEqual(report.remaining, 0)
        XCTAssertGreaterThan(report.resealed, 0)
        XCTAssertEqual(seen.values.last, report.progress)

        let participants = try await participants(h)
        XCTAssertFalse(participants.contains(member), "she is off the share")
        let newId = try await markerKeyId(h)
        XCTAssertNotEqual(newId, oldId)
        let pending = try await h.adminMac.db.read { db in try SyncKeyRotation.isPending(db: db) }
        XCTAssertFalse(pending)
        let revoked = try await h.adminMac.db.read { db in try SyncKeyRotation.revokedKeyIds(db: db) }
        XCTAssertEqual(revoked, [oldId])
        for record in await householdSealed(h) {
            XCTAssertEqual(FieldSealing.keyId(of: record), newId, "\(record.recordType) still under her key")
            XCTAssertThrowsError(try FieldSealing.open(record, keys: [oldId: old]), "her key opens \(record.recordType)")
        }
        // The household is gone from her databases; the admin's other devices read on with the new key.
        do {
            _ = try await h.cloud.session(as: member).changes(since: nil, zone: household)
            XCTFail("she still reaches the household")
        } catch SyncTransportError.zoneNotFound {}
        let phone = try await h.adminPhone.engine.pull()
        XCTAssertEqual(phone.unreadable, 0)
        XCTAssertEqual(phone.waitingForKey, 0)
    }

    func testRemovalIsRefusedOfflineAndChangesNothing() async throws {
        let h = try TwoPersonHousehold.make()
        try await h.syncAll()
        let oldId = try await markerKeyId(h)
        let outcome = try await HouseholdRemoval.remove(transport: OfflineShareTransport(), engine: h.adminMac.engine,
                                                        member: try memberUser(h), db: h.adminMac.db)
        XCTAssertEqual(outcome, .offline)
        XCTAssertEqual(HouseholdCopy.removeOffline, "Connect to the internet to remove someone")
        let participants = try await participants(h)
        XCTAssertTrue(participants.contains(member), "still on the share")
        let newId = try await markerKeyId(h)
        XCTAssertEqual(newId, oldId, "no new key")
        let state = try await h.adminMac.db.read { db in (try SyncKeyRotation.isPending(db: db), try SyncKeyRotation.revokedKeyIds(db: db)) }
        XCTAssertFalse(state.0)
        XCTAssertEqual(state.1, [])
        let removed = try await h.adminMac.db.read { db in try HouseholdInvite.wasRemoved(db: db) }
        XCTAssertFalse(removed)
    }

    func testAnInterruptedRemovalIsFinishedAfterALaterSync() async throws {
        let h = try TwoPersonHousehold.make()
        try await h.syncAll()
        let oldId = try await markerKeyId(h)
        // The new marker goes; the connection drops before the sweep's first save.
        await h.cloud.failSaveOperations(after: 1)
        let outcome = try await HouseholdRemoval.remove(transport: h.cloud, engine: h.adminMac.engine, member: try memberUser(h),
                                                        db: h.adminMac.db)
        XCTAssertEqual(outcome, .securingLater)
        let participants = try await participants(h)
        XCTAssertFalse(participants.contains(member), "she is off the share already")
        let pending = try await h.adminMac.db.read { db in try SyncKeyRotation.isPending(db: db) }
        XCTAssertTrue(pending)
        let rotatedId = try await markerKeyId(h)
        XCTAssertNotEqual(rotatedId, oldId)

        // Back online (after a quit: nothing in memory carries over): the Mac finishes without making another key.
        await h.cloud.restoreConnection()
        let resumed = try await HouseholdRemoval.resumeIfPending(engine: h.adminMac.engine, db: h.adminMac.db)
        guard case .removed(let report)? = resumed else { return XCTFail("not finished: \(String(describing: resumed))") }
        XCTAssertEqual(report.remaining, 0)
        let finalId = try await markerKeyId(h)
        XCTAssertEqual(finalId, rotatedId, "the resume keeps the key the removal made")
        for record in await householdSealed(h) { XCTAssertEqual(FieldSealing.keyId(of: record), rotatedId) }
        let again = try await HouseholdRemoval.resumeIfPending(engine: h.adminMac.engine, db: h.adminMac.db)
        XCTAssertNil(again, "nothing left pending")
    }

    func testAReinvitedMemberIsGrantedTheNewKeyOnly() async throws {
        let h = try TwoPersonHousehold.make()
        try await h.syncAll()
        let oldId = try await markerKeyId(h)
        _ = try await HouseholdRemoval.remove(transport: h.cloud, engine: h.adminMac.engine, member: try memberUser(h), db: h.adminMac.db)
        let newId = try await markerKeyId(h)

        // Invited again, she accepts on a device that holds no household key yet.
        h.cloud.invite(member, zone: household)
        h.cloud.accept(zone: household, as: member)
        let fresh = InMemorySyncKeyStore()
        let session = h.cloud.session(as: member)
        let requester = SyncKeyExchange.Requester(board: session, transport: session, keys: fresh, member: member, householdOwner: owner)
        let granter = SyncKeyExchange.Granter(board: h.cloud, transport: h.cloud, member: member, db: h.adminMac.db)
        try await requester.start(now: Date())
        _ = try await granter.poll(now: Date())
        guard case .showCode = try await requester.poll(now: Date()) else { return XCTFail("no code on her device") }
        let polled = try await granter.poll(now: Date())
        try await granter.grant(try XCTUnwrap(polled), keys: h.adminKeys, now: Date())
        let received = try await requester.poll(now: Date())
        XCTAssertEqual(received, .received)

        XCTAssertEqual(Set(try h.adminKeys.allKeys(zone: household).keys), [oldId, newId], "the Mac keeps the retired key")
        XCTAssertEqual(Set(try fresh.allKeys(zone: household).keys), [newId], "she receives the new key only")
    }

    func testNoKeyIsGrantedWhileTheNewKeyIsStillOwed() async throws {
        let h = try TwoPersonHousehold.make()
        try await h.syncAll()
        try await h.adminMac.engine.beginKeyRevocation()
        let granter = SyncKeyExchange.Granter(board: h.cloud, transport: h.cloud, member: member, db: h.adminMac.db)
        let session = h.cloud.session(as: member)
        let requester = SyncKeyExchange.Requester(board: session, transport: session, keys: InMemorySyncKeyStore(), member: member,
                                                  householdOwner: owner)
        try await requester.start(now: Date())
        _ = try await granter.poll(now: Date())
        _ = try await requester.poll(now: Date())
        let polled = try await granter.poll(now: Date())
        do {
            try await granter.grant(try XCTUnwrap(polled), keys: h.adminKeys, now: Date())
            XCTFail("a revoked key was granted")
        } catch let error as SyncKeyExchange.ExchangeError {
            XCTAssertEqual(error, .noKeys)
        }
    }
}

final class KeyRotationCopyTests: XCTestCase {
    func testCopy() {
        XCTAssertEqual(HouseholdCopy.securing(SyncKeyRotation.Progress(done: 12, total: 340)), "Securing the household… 12 of 340")
        XCTAssertEqual(HouseholdCopy.securing(SyncKeyRotation.Progress(done: 0, total: 0)), "Securing the household…")
        XCTAssertEqual(HouseholdCopy.removeRecall("Sam"), "Copies Sam already downloaded can't be recalled.")
        XCTAssertEqual(HouseholdCopy.removeOffline, "Connect to the internet to remove someone")
    }
}
