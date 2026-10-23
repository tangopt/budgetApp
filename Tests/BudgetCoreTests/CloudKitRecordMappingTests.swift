import XCTest
import CloudKit
@testable import BudgetCore

/// The CloudKit transport's pure parts (plan Task 8, ruling R11), offline: `CKRecord`, `CKAsset` and `CKError`
/// are built locally, nothing talks to iCloud. Synthetic values only.
final class CloudKitRecordMappingTests: XCTestCase {
    private var assets: URL!
    private let zone = SyncRecordStore.householdZone

    override func setUpWithError() throws {
        assets = FileManager.default.temporaryDirectory.appendingPathComponent("CloudKitMappingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: assets)
    }

    private func wire(name: String = "4F1C2D7E-0000-4000-8000-000000000001", assets: [String: Data] = [:]) throws -> SyncWireRecord {
        let payload = SyncPayload(recordType: "account", recordName: name, zone: zone,
                                  fields: ["name": .string("Synthetic current account"), "openingBalance": .double(12.5)])
        var wire = try SyncWireRecord(payload)
        wire.assets = assets
        return wire
    }

    private func archived(_ record: CKRecord) -> Data {
        CloudKitRecordMapping.systemFields(of: record)
    }

    // MARK: Records

    func testWireRoundTripsThroughCKRecordWithEveryFieldEncrypted() throws {
        let sealed = Data((0..<4096).map { UInt8(($0 * 13) % 251) })
        let wire = try wire(assets: ["payload": sealed])
        let record = try CloudKitRecordMapping.record(from: wire, systemFields: nil, assetDirectory: assets)

        XCTAssertEqual(record.recordType, "account")
        XCTAssertEqual(record.recordID.recordName, wire.recordName)
        XCTAssertEqual(record.recordID.zoneID.zoneName, zone)
        XCTAssertEqual(record.recordID.zoneID.ownerName, CKCurrentUserDefaultName)
        // Every value in encryptedValues; the only plain keys are the asset fields.
        XCTAssertEqual(Set(record.encryptedValues.allKeys()), Set(wire.encryptedFields.keys))
        for (key, value) in wire.encryptedFields {
            XCTAssertEqual(record.encryptedValues[key] as? Data, value, key)
        }
        let plain = Set(record.allKeys()).subtracting(record.encryptedValues.allKeys())
        XCTAssertEqual(plain, ["payload"])
        let asset = try XCTUnwrap(record["payload"] as? CKAsset)
        let url = try XCTUnwrap(asset.fileURL)
        XCTAssertTrue(url.path.hasPrefix(assets.path), "asset files are written to the operation's folder")
        XCTAssertEqual(try Data(contentsOf: url), sealed)

        XCTAssertEqual(try CloudKitRecordMapping.wire(from: record), wire)
        XCTAssertEqual(try CloudKitRecordMapping.wire(from: record).payload(), try wire.payload())
    }

    func testAServerRecordArchivedWholeComesBackAsTheSameWire() throws {
        // What a `serverRecordChanged` error or a fetch hands back: a whole record, encrypted values and assets.
        let wire = try wire(assets: ["file": Data("ciphertext".utf8)])
        let record = try CloudKitRecordMapping.record(from: wire, systemFields: nil, assetDirectory: assets)
        let data = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
        let back = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data))
        XCTAssertEqual(try CloudKitRecordMapping.wire(from: back), wire)
    }

    func testAFieldOutsideEncryptedFieldsIsNeverWritten() throws {
        var plain = try wire()
        plain.unencryptedFields = ["name": Data("Synthetic".utf8)]
        XCTAssertThrowsError(try CloudKitRecordMapping.record(from: plain, systemFields: nil, assetDirectory: assets)) { error in
            XCTAssertEqual(error as? CloudKitRecordMapping.MappingError, .plaintextField(recordType: "account", field: "name"))
        }
    }

    func testAnAssetFieldNamedLikeAnEncryptedFieldIsRefused() throws {
        let clash = try wire(assets: ["meta": Data([1, 2, 3])])
        XCTAssertThrowsError(try CloudKitRecordMapping.record(from: clash, systemFields: nil, assetDirectory: assets)) { error in
            XCTAssertEqual(error as? CloudKitRecordMapping.MappingError, .fieldClash(recordType: "account", field: "meta"))
        }
    }

    func testAPlainValueOnAServerRecordIsReportedOutsideEncryptedFields() throws {
        let record = try CloudKitRecordMapping.record(from: try wire(), systemFields: nil, assetDirectory: assets)
        record["note"] = "plain text" as NSString
        let back = try CloudKitRecordMapping.wire(from: record)
        XCTAssertEqual(Array(back.unencryptedFields.keys), ["note"], "visible to the engine's checks, never silently dropped")
    }

    func testAnEncryptedValueThatIsNotDataIsUnreadable() throws {
        let record = try CloudKitRecordMapping.record(from: try wire(), systemFields: nil, assetDirectory: assets)
        record.encryptedValues["f_name"] = "a string" as NSString
        XCTAssertThrowsError(try CloudKitRecordMapping.wire(from: record)) { error in
            XCTAssertEqual(error as? SyncTransportError, .unreadableRecord(record.recordID.recordName))
        }
    }

    // MARK: System fields

    func testSystemFieldsArchiveRoundTripsAndTheSaveIsBuiltOnThem() throws {
        let wire = try wire()
        let server = try CloudKitRecordMapping.record(from: wire, systemFields: nil, assetDirectory: assets)
        let systemFields = archived(server)
        XCTAssertFalse(systemFields.isEmpty)

        let unarchived = try CloudKitRecordMapping.unarchiveSystemFields(systemFields)
        XCTAssertEqual(unarchived.recordID, server.recordID)
        XCTAssertEqual(unarchived.recordType, server.recordType)
        XCTAssertEqual(unarchived.allKeys(), [], "system fields only")

        var edited = wire
        edited.encryptedFields["f_name"] = Data("\"Renamed\"".utf8)
        let rebuilt = try CloudKitRecordMapping.record(from: edited, systemFields: systemFields, assetDirectory: assets)
        XCTAssertEqual(rebuilt.recordID, server.recordID)
        XCTAssertEqual(rebuilt.encryptedValues["f_name"] as? Data, Data("\"Renamed\"".utf8))
        XCTAssertEqual(try CloudKitRecordMapping.wire(from: rebuilt), edited)

        let stamp = CloudKitRecordMapping.stamp(of: rebuilt)
        XCTAssertEqual(try CloudKitRecordMapping.unarchiveSystemFields(stamp.systemFields).recordID, server.recordID)
        XCTAssertEqual(stamp.changeTag, "", "a record never saved has no change tag")
    }

    func testSystemFieldsOfAnotherRecordAreRefused() throws {
        let other = try CloudKitRecordMapping.record(from: try wire(name: "OTHER"), systemFields: nil, assetDirectory: assets)
        XCTAssertThrowsError(try CloudKitRecordMapping.record(from: try wire(), systemFields: archived(other), assetDirectory: assets)) { error in
            XCTAssertEqual(error as? CloudKitRecordMapping.MappingError, .systemFieldsMismatch(recordName: try! self.wire().recordName))
        }
        XCTAssertThrowsError(try CloudKitRecordMapping.record(from: try wire(), systemFields: Data("not an archive".utf8), assetDirectory: assets)) { error in
            XCTAssertEqual(error as? CloudKitRecordMapping.MappingError, .systemFieldsMismatch(recordName: try! self.wire().recordName))
        }
    }

    func testAChangeTokenThatDoesNotDecodeFetchesFromTheStart() {
        XCTAssertThrowsError(try CloudKitRecordMapping.unarchiveToken(Data("garbage".utf8))) { error in
            XCTAssertEqual(error as? SyncTransportError, .changeTokenExpired)
        }
    }

    // MARK: Errors, per record

    func testPerRecordSaveErrorsMapToTheProtocolsOutcomes() throws {
        let wire = try wire()
        let server = try CloudKitRecordMapping.record(from: wire, systemFields: nil, assetDirectory: assets)
        func outcome(_ code: CKError.Code, _ info: [String: Any] = [:]) -> SaveResult.Outcome {
            CloudKitRecordMapping.saveOutcome(for: CKError(code, userInfo: info), wire: wire)
        }
        XCTAssertEqual(outcome(.serverRecordChanged, [CKRecordChangedErrorServerRecordKey: server]),
                       .changed(SyncServerRecord(wire: wire, stamp: CloudKitRecordMapping.stamp(of: server))))
        guard case .failed = outcome(.serverRecordChanged) else { return XCTFail("changed without the server's record") }
        XCTAssertEqual(outcome(.unknownItem), .deleted)
        XCTAssertEqual(outcome(.limitExceeded), .tooLarge(bytes: wire.size))
        XCTAssertEqual(outcome(.batchRequestFailed), .batchRequestFailed)
        XCTAssertEqual(outcome(.zoneNotFound), .zoneNotFound)
        XCTAssertEqual(outcome(.userDeletedZone), .zoneNotFound)
        for code: CKError.Code in [.zoneBusy, .serviceUnavailable, .requestRateLimited, .networkFailure, .networkUnavailable, .quotaExceeded] {
            guard case .failed = outcome(code) else { return XCTFail("\(code.rawValue) passes: sent again later") }
        }
        guard case .failed = CloudKitRecordMapping.saveOutcome(for: URLError(.timedOut), wire: wire) else { return XCTFail("non-CloudKit error") }
    }

    func testAMissingRecordOnFetchIsNil() {
        XCTAssertTrue(CloudKitRecordMapping.isMissingRecord(CKError(.unknownItem)))
        XCTAssertFalse(CloudKitRecordMapping.isMissingRecord(CKError(.zoneNotFound)))
        XCTAssertFalse(CloudKitRecordMapping.isMissingRecord(URLError(.timedOut)))
    }

    // MARK: Errors, per operation

    func testOperationErrorsMapToTransportErrors() {
        func mapped(_ code: CKError.Code, _ info: [String: Any] = [:]) -> SyncTransportError? {
            CloudKitRecordMapping.operationError(CKError(code, userInfo: info), zone: zone) as? SyncTransportError
        }
        for code: CKError.Code in [.networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy] {
            XCTAssertEqual(mapped(code, [CKErrorRetryAfterKey: 3.5]), .unavailable(retryAfter: 3.5), "\(code.rawValue)")
            XCTAssertEqual(mapped(code), .unavailable(retryAfter: nil), "\(code.rawValue)")
        }
        XCTAssertEqual(mapped(.limitExceeded), .limitExceeded)
        XCTAssertEqual(mapped(.changeTokenExpired), .changeTokenExpired)
        XCTAssertEqual(mapped(.zoneNotFound), .zoneNotFound(zone))
        XCTAssertEqual(mapped(.userDeletedZone), .zoneNotFound(zone))
        // Not something sync can act on (signed out, over quota): the CloudKit error itself, for the app to show.
        XCTAssertNil(mapped(.notAuthenticated))
        XCTAssertEqual((CloudKitRecordMapping.operationError(CKError(.notAuthenticated), zone: zone) as? CKError)?.code, .notAuthenticated)
        XCTAssertNil(mapped(.quotaExceeded))
        XCTAssertTrue(CloudKitRecordMapping.operationError(URLError(.timedOut), zone: zone) is URLError)
    }

    func testPartialFailuresMapByTheirItems() {
        let id = CKRecord.ID(recordName: "a", zoneID: CloudKitRecordMapping.zoneID(zone))
        let zoneID = CloudKitRecordMapping.zoneID(zone)
        func partial(_ errors: [AnyHashable: Error]) -> SyncTransportError? {
            CloudKitRecordMapping.operationError(CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: errors]), zone: zone) as? SyncTransportError
        }
        XCTAssertEqual(partial([zoneID: CKError(.zoneNotFound)]), .zoneNotFound(zone))
        XCTAssertEqual(partial([zoneID: CKError(.changeTokenExpired)]), .changeTokenExpired)
        XCTAssertEqual(partial([id: CKError(.networkFailure, userInfo: [CKErrorRetryAfterKey: 2.0])]), .unavailable(retryAfter: 2.0))
        XCTAssertEqual(partial([id: CKError(.limitExceeded)]), .limitExceeded)
        // The zone going wins over a passing failure of another item.
        XCTAssertEqual(partial([id: CKError(.networkFailure), zoneID: CKError(.userDeletedZone)]), .zoneNotFound(zone))
    }

    func testPassingErrors() {
        XCTAssertTrue(SyncTransportError.networkUnavailable.isPassing)
        XCTAssertTrue(SyncTransportError.unavailable(retryAfter: 1).isPassing)
        XCTAssertFalse(SyncTransportError.limitExceeded.isPassing)
        XCTAssertFalse(SyncTransportError.changeTokenExpired.isPassing)
        XCTAssertEqual(SyncTransportError.unavailable(retryAfter: 4).retryAfter, 4)
        XCTAssertNil(SyncTransportError.networkUnavailable.retryAfter)
    }
}
