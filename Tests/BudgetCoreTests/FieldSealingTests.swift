import XCTest
import CryptoKit
@testable import BudgetCore

/// Ruling R15: every record's fields are one AES-GCM box under the zone key (`FieldSealing`), the wire record
/// carries exactly `sealed` and `keyId`, and the zone key lives in a `SyncKeyStore`. Synthetic values only.
final class FieldSealingTests: XCTestCase {
    private let zone = SyncRecordStore.householdZone
    private let uuid = "6F1C2A4E-3B7D-4C1A-9E2F-0A1B2C3D4E5F"

    private func payload(_ name: String = "Synthetic Grocer Ltd", amount: Int64 = -4_321) -> SyncPayload {
        SyncPayload(recordType: "transaction_", recordName: uuid, zone: zone,
                    fields: ["rawDescription": .string(name), "amount": .int(amount),
                             "accountId": .string("0B7E3C1D-2A4F-4E6B-8C9D-1E2F3A4B5C6D")],
                    clocks: ["*": SyncClock(at: Date(timeIntervalSinceReferenceDate: 800_000_000), by: "user-a")],
                    modifiedBy: "user-a")
    }

    // MARK: Round trip and shape

    func testSealedRecordRoundTripsAndCarriesExactlySealedAndKeyId() throws {
        let key = DocumentCrypto.newZoneKey()
        let (wire, packed) = try SyncLargePayload.wire(for: payload(), key: key)
        XCTAssertFalse(packed)
        XCTAssertEqual(Set(wire.encryptedFields.keys), [FieldSealing.sealedField, FieldSealing.keyIdField])
        XCTAssertTrue(wire.unencryptedFields.isEmpty)
        XCTAssertTrue(wire.assets.isEmpty)
        XCTAssertEqual(wire.encryptedFields[FieldSealing.keyIdField], Data(DocumentCrypto.zoneKeyId(key).utf8))
        XCTAssertEqual(wire.recordType, "transaction_")
        XCTAssertEqual(wire.recordName, uuid)
        let opened = try SyncLargePayload.payload(from: wire, keys: [DocumentCrypto.zoneKeyId(key): key])
        XCTAssertEqual(opened, payload())
    }

    func testNoSourceValueBytesAppearInTheSealedRecord() throws {
        let key = DocumentCrypto.newZoneKey()
        let (wire, _) = try SyncLargePayload.wire(for: payload(), key: key)
        let sealed = try XCTUnwrap(wire.encryptedFields[FieldSealing.sealedField])
        for needle in ["Synthetic Grocer", "0B7E3C1D", "user-a", "{\"string\"", "{\"int\"", "rawDescription", "f_amount", "-4321"] {
            for data in wire.encryptedFields.values {
                XCTAssertNil(data.range(of: Data(needle.utf8)), "\(needle) is readable")
            }
        }
        XCTAssertTrue(sealed.starts(with: Data("MSB".utf8) + Data([1])), "magic and wire format version")
    }

    func testTheEncodingIsDeterministic() throws {
        let fields = try SyncWireRecord(payload()).encryptedFields
        XCTAssertEqual(FieldSealing.encode(fields), FieldSealing.encode(Dictionary(uniqueKeysWithValues: fields.reversed().map { ($0.key, $0.value) })))
        XCTAssertEqual(try FieldSealing.decode(FieldSealing.encode(fields)), fields)
    }

    func testALargePayloadTravelsAsAnAssetSealedUnderTheZoneKey() throws {
        let key = DocumentCrypto.newZoneKey()
        let big = payload(String(repeating: "Synthetic memo line. ", count: 2_000))
        let (wire, packed) = try SyncLargePayload.wire(for: big, key: key, threshold: 10_000)
        XCTAssertTrue(packed)
        XCTAssertEqual(Set(wire.encryptedFields.keys), [FieldSealing.sealedField, FieldSealing.keyIdField])
        XCTAssertEqual(Set(wire.assets.keys), [SyncLargePayload.assetField])
        let asset = try XCTUnwrap(wire.assets[SyncLargePayload.assetField])
        XCTAssertNil(asset.range(of: Data("Synthetic memo".utf8)))
        XCTAssertTrue(asset.starts(with: Data("MSB".utf8) + Data([1])))
        XCTAssertEqual(try SyncLargePayload.payload(from: wire, keys: [DocumentCrypto.zoneKeyId(key): key]), big)
        // The asset can't be opened without the zone key: no key travels with the record any more.
        XCTAssertThrowsError(try SyncLargePayload.payload(from: wire, keys: [:]))
    }

    // MARK: Failures

    func testAWrongKeyFailsAsAMissingKey() throws {
        let key = DocumentCrypto.newZoneKey()
        let other = DocumentCrypto.newZoneKey()
        let (wire, _) = try SyncLargePayload.wire(for: payload(), key: key)
        XCTAssertThrowsError(try SyncLargePayload.payload(from: wire, keys: [DocumentCrypto.zoneKeyId(other): other])) { error in
            XCTAssertEqual(error as? FieldSealing.SealingError, .keyMissing(DocumentCrypto.zoneKeyId(key)))
        }
        // A key filed under the record's id that isn't that key: authentication fails.
        XCTAssertThrowsError(try SyncLargePayload.payload(from: wire, keys: [DocumentCrypto.zoneKeyId(key): other])) { error in
            XCTAssertEqual(error as? FieldSealing.SealingError, .authenticationFailed)
        }
    }

    func testATamperedBoxFails() throws {
        let key = DocumentCrypto.newZoneKey()
        var (wire, _) = try SyncLargePayload.wire(for: payload(), key: key)
        var sealed = try XCTUnwrap(wire.encryptedFields[FieldSealing.sealedField])
        sealed[sealed.startIndex + 20] ^= 0x01
        wire.encryptedFields[FieldSealing.sealedField] = sealed
        XCTAssertThrowsError(try SyncLargePayload.payload(from: wire, keys: [DocumentCrypto.zoneKeyId(key): key])) { error in
            XCTAssertEqual(error as? FieldSealing.SealingError, .authenticationFailed)
        }
    }

    func testABlobMovedToAnotherRecordTypeOrZoneFails() throws {
        let key = DocumentCrypto.newZoneKey()
        let keys = [DocumentCrypto.zoneKeyId(key): key]
        let (wire, _) = try SyncLargePayload.wire(for: payload(), key: key)
        var moved = wire
        moved.recordName = "1D2C3B4A-5E6F-4A7B-8C9D-0E1F2A3B4C5D"
        XCTAssertThrowsError(try SyncLargePayload.payload(from: moved, keys: keys)) { XCTAssertEqual($0 as? FieldSealing.SealingError, .authenticationFailed) }
        var retyped = wire
        retyped.recordType = "account"
        XCTAssertThrowsError(try SyncLargePayload.payload(from: retyped, keys: keys)) { XCTAssertEqual($0 as? FieldSealing.SealingError, .authenticationFailed) }
        var rezoned = wire
        rezoned.zone = "private-user-a"
        XCTAssertThrowsError(try SyncLargePayload.payload(from: rezoned, keys: keys)) { XCTAssertEqual($0 as? FieldSealing.SealingError, .authenticationFailed) }
        // A key id swapped for another held key's id: the box names its key in its authenticated data.
        let second = DocumentCrypto.newZoneKey()
        var relabelled = wire
        relabelled.encryptedFields[FieldSealing.keyIdField] = Data(DocumentCrypto.zoneKeyId(second).utf8)
        XCTAssertThrowsError(try SyncLargePayload.payload(from: relabelled, keys: [DocumentCrypto.zoneKeyId(second): key])) {
            XCTAssertEqual($0 as? FieldSealing.SealingError, .authenticationFailed)
        }
    }

    func testAnUnknownVersionAnUnsealedRecordAndAnExtraFieldAreRefused() throws {
        let key = DocumentCrypto.newZoneKey()
        let keys = [DocumentCrypto.zoneKeyId(key): key]
        var (wire, _) = try SyncLargePayload.wire(for: payload(), key: key)
        var sealed = try XCTUnwrap(wire.encryptedFields[FieldSealing.sealedField])
        sealed[sealed.startIndex + 3] = 2
        var future = wire
        future.encryptedFields[FieldSealing.sealedField] = sealed
        XCTAssertThrowsError(try SyncLargePayload.payload(from: future, keys: keys)) { XCTAssertEqual($0 as? FieldSealing.SealingError, .unknownVersion(2)) }
        // The step 3 format (a value per field): never read.
        XCTAssertThrowsError(try SyncLargePayload.payload(from: try SyncWireRecord(payload()), keys: keys)) {
            XCTAssertEqual($0 as? FieldSealing.SealingError, .notSealed)
        }
        wire.encryptedFields["f_amount"] = Data("{\"int\":1}".utf8)
        XCTAssertThrowsError(try SyncLargePayload.payload(from: wire, keys: keys)) { XCTAssertEqual($0 as? FieldSealing.SealingError, .notSealed) }
    }

    // MARK: The in-memory key store

    func testTheInMemoryKeyStoreKeepsKeysByIdAndTheNewestAsCurrent() throws {
        let store = InMemorySyncKeyStore()
        XCTAssertNil(try store.key(zone: zone))
        XCTAssertEqual(try store.allKeys(zone: zone).count, 0)
        let first = DocumentCrypto.newZoneKey()
        let second = DocumentCrypto.newZoneKey()
        try store.store(first, zone: zone)
        try store.store(second, zone: zone)
        try store.store(first, zone: zone)  // already held: changes nothing
        XCTAssertEqual(try store.key(zone: zone).map(DocumentCrypto.zoneKeyId), DocumentCrypto.zoneKeyId(second))
        XCTAssertEqual(Set(try store.allKeys(zone: zone).keys), [DocumentCrypto.zoneKeyId(first), DocumentCrypto.zoneKeyId(second)])
        XCTAssertEqual(try store.allKeys(zone: "other").count, 0, "per zone")
    }
}
