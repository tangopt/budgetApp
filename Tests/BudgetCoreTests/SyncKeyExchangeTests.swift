import XCTest
import CryptoKit
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 7a Task 8: the household key reaches the member's device by a key exchange confirmed with a 6-digit code that
/// both screens show. Her request (a commitment, then her public key) goes on the container's public database (the
/// household share is read-only for her); the Mac's nonce and the sealed grant go in `household`. Over `FakeCloud`,
/// in-memory key stores only. Synthetic data only.
final class SyncKeyExchangeTests: XCTestCase {
    private let household = SyncZones.household
    private let owner = "fake-owner"
    private let member = "fake-member"
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: Fixture

    private struct Setup {
        let cloud: FakeCloud
        let adminKeys: InMemorySyncKeyStore
        let memberKeys: InMemorySyncKeyStore
        let granter: SyncKeyExchange.Granter
        let requester: SyncKeyExchange.Requester
    }

    /// The admin's cloud with `household` shared with the member (accepted), the admin holding `keyCount` household
    /// keys, her device holding none.
    private func setup(keyCount: Int = 1) throws -> Setup {
        let cloud = FakeCloud(start: start, zones: [household], ownerRecordName: owner)
        cloud.invite(member, zone: household, canWrite: false)
        cloud.accept(zone: household, as: member)
        let adminKeys = InMemorySyncKeyStore()
        for _ in 0..<keyCount { try adminKeys.store(DocumentCrypto.newZoneKey(), zone: household) }
        let memberKeys = InMemorySyncKeyStore()
        let session = cloud.session(as: member)
        return Setup(cloud: cloud, adminKeys: adminKeys, memberKeys: memberKeys,
                     granter: SyncKeyExchange.Granter(board: cloud, transport: cloud, member: member),
                     requester: SyncKeyExchange.Requester(board: session, transport: session, keys: memberKeys, member: member,
                                                          householdOwner: owner))
    }

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    /// Her request is posted, the Mac answers with its nonce, her device reveals its key: both show a code.
    private func toCodes(_ s: Setup) async throws -> (request: SyncKeyExchange.Request, memberCode: String) {
        try await s.requester.start(now: at(1))
        let none = try await s.granter.poll(now: at(2))
        XCTAssertNil(none, "nothing to confirm before her device has revealed its key")
        let shown = try await s.requester.poll(now: at(3))
        guard case .showCode(let code) = shown else { XCTFail("her device shows no code: \(shown)"); throw CancellationError() }
        let request = try await s.granter.poll(now: at(4))
        guard let request else { XCTFail("the Mac shows no request"); throw CancellationError() }
        return (request, code)
    }

    private func raw(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    // MARK: Tests

    func testGrantDeliversAllHouseholdKeysToRequester() async throws {
        let s = try setup(keyCount: 2)
        let (request, _) = try await toCodes(s)
        try await s.granter.grant(request, keys: s.adminKeys, now: at(5))
        let status = try await s.requester.poll(now: at(6))
        XCTAssertEqual(status, .received)
        let admin = try s.adminKeys.allKeys(zone: household).mapValues(raw)
        let delivered = try s.memberKeys.allKeys(zone: household).mapValues(raw)
        XCTAssertEqual(delivered, admin)
        XCTAssertEqual(try s.memberKeys.key(zone: household).map(raw), try s.adminKeys.key(zone: household).map(raw),
                       "the admin's newest key is her newest too")
        // Her request is gone from the public database; the Mac's next look clears its nonce and the grant.
        let left = await s.cloud.publicRecords()
        XCTAssertEqual(left, [])
        _ = try await s.granter.poll(now: at(7))
        let names = await s.cloud.storedRecords().map(\.recordName)
        XCTAssertFalse(names.contains { $0.hasPrefix("keyOffer-") || $0.hasPrefix("keyGrant-") }, "\(names)")
    }

    func testCodeMatchesOnBothSides() async throws {
        let s = try setup()
        let (request, code) = try await toCodes(s)
        XCTAssertEqual(request.code, code)
        XCTAssertEqual(request.lastModifiedBy, member)
        XCTAssertNotNil(code.range(of: "^[0-9]{3} [0-9]{3}$", options: .regularExpression), code)
        XCTAssertEqual(SyncKeyExchange.code(transcript: Data([1, 2, 3])).count, 7)
    }

    func testSubstitutedKeyOrNonceChangesTheCode() async throws {
        // The server swaps her commitment and key for an attacker's: the Mac's code isn't hers.
        let s = try setup()
        try await s.requester.start(now: at(1))
        let attackerKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let attackerNonce = Data(repeating: 7, count: 32)
        let name = "keyRequest-" + member
        let rid = try await requestId(s.cloud)
        let attackerCommitment = SyncKeyExchange.commitment(requestId: rid, publicKey: attackerKey, nonce: attackerNonce)
        await s.cloud.rewritePublicRecord(named: name, fields: ["requestId": Data(rid.utf8), "commitment": attackerCommitment])
        _ = try await s.granter.poll(now: at(2))
        guard case .showCode(let memberCode) = try await s.requester.poll(now: at(3)) else { return XCTFail("no code on her device") }
        await s.cloud.rewritePublicRecord(named: name, fields: ["requestId": Data(rid.utf8), "commitment": attackerCommitment,
                                                                "publicKey": attackerKey, "nonce": attackerNonce])
        let request = try await s.granter.poll(now: at(4))
        let adminCode = try XCTUnwrap(request?.code)
        XCTAssertNotEqual(adminCode, memberCode, "a substituted key shows a different code on the Mac")

        // The server swaps the Mac's nonce on its way to her device: her code isn't the Mac's either.
        let t = try setup()
        try await t.requester.start(now: at(1))
        _ = try await t.granter.poll(now: at(2))
        let offered = try await requestId(t.cloud)
        await t.cloud.rewrite(recordName: "keyOffer-" + offered, encryptedFields: ["nonce": Data(repeating: 9, count: 32)])
        guard case .showCode(let herCode) = try await t.requester.poll(now: at(3)) else { return XCTFail("no code on her device") }
        let macRequest = try await t.granter.poll(now: at(4))
        let macCode = try XCTUnwrap(macRequest?.code)
        XCTAssertNotEqual(macCode, herCode)
    }

    func testCommitmentChangedAfterTheOfferIsRefused() async throws {
        let s = try setup()
        try await s.requester.start(now: at(1))
        _ = try await s.granter.poll(now: at(2))
        let name = "keyRequest-" + member
        let id = try await requestId(s.cloud)
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let nonce = Data(repeating: 3, count: 32)
        // A key and nonce that open a new commitment, swapped in after the Mac took the first one.
        await s.cloud.rewritePublicRecord(named: name, fields: ["requestId": Data(id.utf8),
                                                                "commitment": SyncKeyExchange.commitment(requestId: id, publicKey: key, nonce: nonce),
                                                                "publicKey": key, "nonce": nonce])
        let request = try await s.granter.poll(now: at(3))
        XCTAssertNil(request)
    }

    func testRequestFromNonMemberIsNotListed() async throws {
        // A stranger takes her request's name before she does: never listed.
        let s = try setup()
        let stranger = SyncKeyExchange.Requester(board: s.cloud.session(as: "fake-stranger"), transport: s.cloud.session(as: "fake-stranger"),
                                                 keys: InMemorySyncKeyStore(), member: member, householdOwner: owner)
        try await stranger.start(now: at(1))
        let listed = try await s.granter.poll(now: at(2))
        XCTAssertNil(listed)
        let offers = await s.cloud.storedRecords().filter { $0.recordType == SyncKeyExchange.offerRecordType }
        XCTAssertEqual(offers, [], "no nonce is offered to a stranger's request")
        // She can't overwrite or remove the stranger's record, and the Mac never answers it.
        do {
            try await s.requester.start(now: at(3))
            XCTFail("her post over a record she didn't create succeeded")
        } catch {}
    }

    func testRemovedMemberIsRefused() async throws {
        let s = try setup()
        let (request, _) = try await toCodes(s)
        try await s.cloud.removeParticipant(userRecordName: member, zone: household)
        do {
            try await s.granter.grant(request, keys: s.adminKeys, now: at(5))
            XCTFail("granted to a removed member")
        } catch let error as SyncKeyExchange.ExchangeError {
            XCTAssertEqual(error, .notAMember)
        }
        let listed = try await s.granter.poll(now: at(6))
        XCTAssertNil(listed, "a removed member's request isn't listed")
        let grants = await s.cloud.storedRecords().filter { $0.recordType == SyncKeyExchange.grantRecordType }
        XCTAssertEqual(grants, [])
    }

    func testExpiredRequestIsRefused() async throws {
        // Confirmed too late on the Mac.
        let s = try setup()
        let (request, _) = try await toCodes(s)
        do {
            try await s.granter.grant(request, keys: s.adminKeys, now: at(2 + SyncKeyExchange.lifetime + 1))
            XCTFail("granted after expiry")
        } catch let error as SyncKeyExchange.ExchangeError {
            XCTAssertEqual(error, .expired)
        }
        // A request already old when the Mac first sees it is never answered.
        let t = try setup()
        try await t.requester.start(now: at(1))
        let stale = try await t.granter.poll(now: at(1 + SyncKeyExchange.lifetime + 60))
        XCTAssertNil(stale)
        let offers = await t.cloud.storedRecords().filter { $0.recordType == SyncKeyExchange.offerRecordType }
        XCTAssertEqual(offers, [])
        // Her device gives up after the lifetime and takes its request down.
        let status = try await t.requester.poll(now: at(1 + SyncKeyExchange.lifetime + 1))
        XCTAssertEqual(status, .expired)
        let left = await t.cloud.publicRecords()
        XCTAssertEqual(left, [])
    }

    func testGrantIsOneTimeAndAReplayDoesNotOpen() async throws {
        let s = try setup()
        let (request, _) = try await toCodes(s)
        try await s.granter.grant(request, keys: s.adminKeys, now: at(5))
        do {
            try await s.granter.grant(request, keys: s.adminKeys, now: at(5))
            XCTFail("granted twice")
        } catch let error as SyncKeyExchange.ExchangeError {
            XCTAssertEqual(error, .notConfirmable)
        }
        let stored = await s.cloud.storedRecords()
        let firstGrant = try XCTUnwrap(stored.first { $0.recordType == SyncKeyExchange.grantRecordType })
        let received = try await s.requester.poll(now: at(6))
        XCTAssertEqual(received, .received)
        let again = try await s.requester.poll(now: at(7))
        XCTAssertEqual(again, .expired, "nothing pending once received")

        // A new request on another device of hers: the server replays the old grant under the new request's name.
        let otherKeys = InMemorySyncKeyStore()
        let session = s.cloud.session(as: member)
        let other = SyncKeyExchange.Requester(board: session, transport: session, keys: otherKeys, member: member, householdOwner: owner)
        try await other.start(now: at(10))
        _ = try await s.granter.poll(now: at(11))
        guard case .showCode = try await other.poll(now: at(12)) else { return XCTFail("no code") }
        let newId = try await requestId(s.cloud)
        var replay = firstGrant
        replay.recordName = "keyGrant-" + newId
        _ = await s.cloud.save(wire: replay, ifUnchanged: nil)
        let status = try await other.poll(now: at(13))
        XCTAssertEqual(status, .refused)
        XCTAssertEqual(try otherKeys.allKeys(zone: household).count, 0)
    }

    func testTamperedGrantStoresNothing() async throws {
        let s = try setup()
        let (request, _) = try await toCodes(s)
        try await s.granter.grant(request, keys: s.adminKeys, now: at(5))
        let stored = await s.cloud.storedRecords()
        let grant = try XCTUnwrap(stored.first { $0.recordType == SyncKeyExchange.grantRecordType })
        var sealed = try XCTUnwrap(grant.encryptedFields["sealed"])
        sealed[sealed.index(sealed.startIndex, offsetBy: 40)] ^= 0x01
        await s.cloud.rewrite(recordName: grant.recordName, encryptedFields: ["sealed": sealed, "keyId": Data("exchange-v1".utf8)])
        let status = try await s.requester.poll(now: at(6))
        XCTAssertEqual(status, .refused)
        XCTAssertEqual(try s.memberKeys.allKeys(zone: household).count, 0)
    }

    func testGrantOpensOnlyOnTheRequestingDevice() throws {
        let key = DocumentCrypto.newZoneKey()
        let device = Curve25519.KeyAgreement.PrivateKey()
        let transcript = Data(repeating: 4, count: 32)
        let sealed = try SyncKeyExchange.seal([key], to: device.publicKey, requestId: "r1", transcript: transcript)
        XCTAssertEqual(try SyncKeyExchange.open(sealed, with: device, requestId: "r1", transcript: transcript).map(raw), [raw(key)])
        XCTAssertThrowsError(try SyncKeyExchange.open(sealed, with: Curve25519.KeyAgreement.PrivateKey(), requestId: "r1", transcript: transcript))
        XCTAssertThrowsError(try SyncKeyExchange.open(sealed, with: device, requestId: "r2", transcript: transcript))
        XCTAssertThrowsError(try SyncKeyExchange.open(sealed, with: device, requestId: "r1", transcript: Data(repeating: 5, count: 32)))
    }

    func testGrantRecordCarriesExactlySealedAndKeyId() async throws {
        let s = try setup(keyCount: 2)
        let (request, _) = try await toCodes(s)
        try await s.granter.grant(request, keys: s.adminKeys, now: at(5))
        let records = await s.cloud.storedRecords()
        let grant = try XCTUnwrap(records.first { $0.recordType == SyncKeyExchange.grantRecordType })
        XCTAssertEqual(grant.recordName, "keyGrant-" + request.id)
        XCTAssertEqual(grant.zone, household)
        XCTAssertEqual(Set(grant.encryptedFields.keys), ["sealed", "keyId"])
        XCTAssertEqual(grant.encryptedFields["keyId"], Data("exchange-v1".utf8))
        XCTAssertEqual(grant.unencryptedFields, [:])
        XCTAssertEqual(grant.assets, [:])
        let offer = try XCTUnwrap(records.first { $0.recordType == SyncKeyExchange.offerRecordType })
        XCTAssertEqual(Set(offer.encryptedFields.keys), ["nonce"])
        // No household key's bytes appear in any record, in either database.
        let secrets = try s.adminKeys.allKeys(zone: household).values.map(raw)
        let publicRecords = await s.cloud.publicRecords()
        let blobs = records.flatMap { Array($0.encryptedFields.values) + Array($0.unencryptedFields.values) + Array($0.assets.values) }
            + publicRecords.flatMap { Array($0.fields.values) }
        for secret in secrets {
            for blob in blobs { XCTAssertNil(blob.range(of: secret), "a household key in the clear") }
        }
    }

    func testEngineIgnoresExchangeRecords() async throws {
        let h = try TwoPersonHousehold.make()
        try await h.syncAll()
        let requester = SyncKeyExchange.Requester(board: h.cloud.session(as: member), transport: h.memberAudit, keys: h.memberKeys,
                                                  member: member, householdOwner: owner)
        let granter = SyncKeyExchange.Granter(board: h.cloud, transport: h.macTransport, member: member)
        try await requester.start(now: Date())
        _ = try await granter.poll(now: Date())
        _ = try await requester.poll(now: Date())
        let request = try await granter.poll(now: Date())
        try await granter.grant(try XCTUnwrap(request), keys: h.adminKeys, now: Date())
        // The offer and the grant are in `household` now: every engine passes over them.
        try await h.adminMac.engine.pull()
        try await h.syncAll()
        for device in [h.adminMac, h.adminPhone, h.memberDevice] {
            let staged = try await device.db.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncStaging") ?? 0
            }
            XCTAssertEqual(staged, 0, "nothing staged on \(device.engine.device.name)")
        }
        XCTAssertEqual(h.audit.householdViolations(router: h.adminRouter()), [])
        let findings = try await HouseholdInvite.auditServer(transport: h.macTransport, keys: h.adminKeys, db: h.adminMac.db)
        XCTAssertEqual(findings, [])
    }

    func testMemberOpensHouseholdAfterGrant() async throws {
        let h = try TwoPersonHousehold.make(memberHasHouseholdKey: false)
        try await h.adminMac.engine.pushPending()
        _ = try await h.memberDevice.engine.pull()
        let before = try await h.memberDevice.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM account") ?? 0 }
        XCTAssertEqual(before, 0, "without the key her device opens nothing")

        let requester = SyncKeyExchange.Requester(board: h.cloud.session(as: member), transport: h.memberAudit, keys: h.memberKeys,
                                                  member: member, householdOwner: owner)
        let granter = SyncKeyExchange.Granter(board: h.cloud, transport: h.macTransport, member: member)
        try await requester.start(now: Date())
        _ = try await granter.poll(now: Date())
        guard case .showCode(let code) = try await requester.poll(now: Date()) else { return XCTFail("no code on her device") }
        let polled = try await granter.poll(now: Date())
        let request = try XCTUnwrap(polled)
        XCTAssertEqual(request.code, code)
        try await granter.grant(request, keys: h.adminKeys, now: Date())
        let received = try await requester.poll(now: Date())
        XCTAssertEqual(received, .received)

        _ = try await h.memberDevice.engine.pull()
        let after = try await h.memberDevice.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM account") ?? 0 }
        XCTAssertGreaterThan(after, 0, "the waiting household records open once the key is here")
        XCTAssertEqual(h.memberAudit.householdViolations(router: TwoPersonHousehold.router(h.memberDevice.db)), [])
    }

    func testCopy() {
        XCTAssertEqual(HouseholdCopy.keyRequestTitle("Person B"), "Person B's device is asking for the household key.")
        XCTAssertEqual(HouseholdCopy.keyRequestCheck("123 456"), "Check that it shows this code: 123 456")
        XCTAssertEqual(HouseholdCopy.giveKeyButton, "Give the key")
        XCTAssertEqual(HouseholdCopy.notNowButton, "Not now")
        XCTAssertEqual(HouseholdCopy.showCode("Person A", "123 456"), "Show this code to Person A on the Mac: 123 456")
        XCTAssertEqual(HouseholdCopy.waitingForKey, "Waiting for the household key…")
    }

    // MARK: Helpers

    private func requestId(_ cloud: FakeCloud) async throws -> String {
        let posted = await cloud.publicRecord(named: "keyRequest-" + member)
        let record = try XCTUnwrap(posted)
        return String(decoding: try XCTUnwrap(record.fields["requestId"]), as: UTF8.self)
    }
}
