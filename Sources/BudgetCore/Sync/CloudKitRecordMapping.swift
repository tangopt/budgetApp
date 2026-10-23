import CloudKit
import Foundation

/// The pure half of the CloudKit transport (plan Task 8, ruling R11): `SyncWireRecord` ↔ `CKRecord`, the
/// archived system fields and change tokens, and `CKError` → the `SyncTransport` outcomes. Nothing here talks
/// to iCloud; the operations live in the App target (`CloudKitTransport`). Kept in BudgetCore so the future
/// iPhone and iPad apps share it and so it is tested offline on both platforms.
///
/// Sync spec §4.2: the record type, name and zone are the only plaintext. Every value of `encryptedFields`
/// goes into `CKRecord.encryptedValues`, never a plain field; a wire record carrying `unencryptedFields` is
/// refused. Assets (ciphertext the app sealed itself) are `CKAsset` fields, written to files for the upload.
public enum CloudKitRecordMapping {
    public enum MappingError: Error, Equatable {
        /// A value that would be stored in plaintext: never written.
        case plaintextField(recordType: String, field: String)
        /// An asset field with the same name as an encrypted field.
        case fieldClash(recordType: String, field: String)
        /// The archived system fields don't decode, or are another record's.
        case systemFieldsMismatch(recordName: String)
    }

    /// What one `CKModifyRecordsOperation` carries: at most 400 records, and a request kept well under
    /// CloudKit's size limit (the engine also splits on `limitExceeded`).
    public static let operationLimits = SyncOperationLimits(maxRecords: 400, maxBytes: 1_500_000)
    /// CloudKit's limit on one record's fields (assets don't count).
    public static let recordSizeLimit = 1_000_000

    /// Records live in the household zone of the admin's private database in build step 3.
    public static func zoneID(_ zone: String) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zone, ownerName: CKCurrentUserDefaultName)
    }

    public static func recordID(_ recordName: String, zone: String) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: zoneID(zone))
    }

    // MARK: Records

    /// The record to save: built on the archived `systemFields` of the version last seen (so
    /// `.ifServerRecordUnchanged` compares against it), or new when there are none. Assets are written to
    /// files in `assetDirectory`, which the caller removes once the operation has finished.
    public static func record(from wire: SyncWireRecord, systemFields: Data?, assetDirectory: URL) throws -> CKRecord {
        if let field = wire.unencryptedFields.keys.sorted().first {
            throw MappingError.plaintextField(recordType: wire.recordType, field: field)
        }
        if let field = wire.assets.keys.sorted().first(where: { wire.encryptedFields[$0] != nil }) {
            throw MappingError.fieldClash(recordType: wire.recordType, field: field)
        }
        let id = recordID(wire.recordName, zone: wire.zone)
        let record: CKRecord
        if let systemFields {
            guard let archived = try? unarchiveSystemFields(systemFields), archived.recordID == id, archived.recordType == wire.recordType else {
                throw MappingError.systemFieldsMismatch(recordName: wire.recordName)
            }
            record = archived
        } else {
            record = CKRecord(recordType: wire.recordType, recordID: id)
        }
        for (key, value) in wire.encryptedFields { record.encryptedValues[key] = value as NSData }
        if !wire.assets.isEmpty { try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true) }
        for (key, data) in wire.assets {
            let file = assetDirectory.appendingPathComponent(UUID().uuidString)
            try data.write(to: file, options: .atomic)
            record[key] = CKAsset(fileURL: file)
        }
        return record
    }

    /// A record as the server holds it, as a wire record. Encrypted values must be data (only this app writes
    /// them); assets are read from their files; any other plain value lands in `unencryptedFields`, where the
    /// engine's checks see it.
    public static func wire(from record: CKRecord) throws -> SyncWireRecord {
        let name = record.recordID.recordName
        var encrypted: [String: Data] = [:]
        let encryptedKeys = record.encryptedValues.allKeys()
        for key in encryptedKeys {
            guard let data = record.encryptedValues[key] as? Data else { throw SyncTransportError.unreadableRecord(name) }
            encrypted[key] = data
        }
        var assets: [String: Data] = [:]
        var plain: [String: Data] = [:]
        for key in Set(record.allKeys()).subtracting(encryptedKeys) {
            switch record[key] {
            case let asset as CKAsset:
                guard let url = asset.fileURL, let data = try? Data(contentsOf: url) else { throw SyncTransportError.unreadableRecord(name) }
                assets[key] = data
            case let data as Data:
                plain[key] = data
            case let value?:
                plain[key] = Data(String(describing: value).utf8)
            case nil:
                continue
            }
        }
        return SyncWireRecord(recordType: record.recordType, recordName: name, zone: record.recordID.zoneID.zoneName,
                              encryptedFields: encrypted, unencryptedFields: plain, assets: assets)
    }

    /// The server's stamp on a record it returned.
    public static func stamp(of record: CKRecord) -> SyncServerStamp {
        SyncServerStamp(systemFields: systemFields(of: record), changeTag: record.recordChangeTag ?? "",
                        modifiedAt: record.modificationDate ?? .distantPast)
    }

    public static func serverRecord(_ record: CKRecord) throws -> SyncServerRecord {
        SyncServerRecord(wire: try wire(from: record), stamp: stamp(of: record))
    }

    // MARK: Archives

    /// `encodeSystemFields`, archived with secure coding.
    public static func systemFields(of record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    public static func unarchiveSystemFields(_ data: Data) throws -> CKRecord {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        guard let record = CKRecord(coder: unarchiver) else { throw CocoaError(.coderReadCorrupt) }
        return record
    }

    public static func archiveToken(_ token: CKServerChangeToken) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    /// A stored token that no longer decodes is treated as expired: the zone is fetched from the start.
    public static func unarchiveToken(_ data: Data) throws -> CKServerChangeToken {
        guard let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data) else {
            throw SyncTransportError.changeTokenExpired
        }
        return token
    }

    // MARK: Errors

    /// One record's save error as the protocol's outcome.
    public static func saveOutcome(for error: Error, wire: SyncWireRecord) -> SaveResult.Outcome {
        guard let error = error as? CKError else { return .failed(String(describing: type(of: error))) }
        switch error.code {
        case .serverRecordChanged:
            guard let record = error.serverRecord, let server = try? serverRecord(record) else {
                return .failed("serverRecordChanged without a readable server record")
            }
            return .changed(server)
        case .unknownItem: return .deleted
        case .limitExceeded: return .tooLarge(bytes: wire.size)
        case .batchRequestFailed: return .batchRequestFailed
        case .zoneNotFound, .userDeletedZone: return .zoneNotFound
        default: return .failed(codeName(error.code))
        }
    }

    /// Whether a fetch error means the server has no record by that name.
    public static func isMissingRecord(_ error: Error) -> Bool {
        (error as? CKError)?.code == .unknownItem
    }

    /// A whole operation's error as what the engine acts on. Errors sync can't act on (signed out, over quota,
    /// a missing entitlement) are passed on as they are, for the app to show.
    public static func operationError(_ error: Error, zone: String) -> Error {
        guard let error = error as? CKError else { return error }
        if error.code == .partialFailure, let items = error.partialErrorsByItemID?.values {
            // The most decisive item wins: the zone gone, then the token, then the size, then a passing failure.
            let mapped = items.map { operationError($0, zone: zone) }.compactMap { $0 as? SyncTransportError }
            let rank: (SyncTransportError) -> Int = {
                switch $0 {
                case .zoneNotFound: return 0
                case .changeTokenExpired: return 1
                case .limitExceeded: return 2
                case .unavailable, .networkUnavailable: return 3
                case .unreadableRecord: return 4
                }
            }
            return mapped.min { rank($0) < rank($1) } ?? error
        }
        switch error.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return SyncTransportError.unavailable(retryAfter: error.retryAfterSeconds)
        case .limitExceeded: return SyncTransportError.limitExceeded
        case .changeTokenExpired: return SyncTransportError.changeTokenExpired
        case .zoneNotFound, .userDeletedZone: return SyncTransportError.zoneNotFound(zone)
        default: return error
        }
    }

    /// A short name for a CloudKit error code (logs and `.failed` outcomes; never record content).
    public static func codeName(_ code: CKError.Code) -> String {
        switch code {
        case .zoneBusy: return "zoneBusy"
        case .serviceUnavailable: return "serviceUnavailable"
        case .requestRateLimited: return "requestRateLimited"
        case .networkFailure: return "networkFailure"
        case .networkUnavailable: return "networkUnavailable"
        case .quotaExceeded: return "quotaExceeded"
        case .notAuthenticated: return "notAuthenticated"
        case .permissionFailure: return "permissionFailure"
        case .invalidArguments: return "invalidArguments"
        case .serverRejectedRequest: return "serverRejectedRequest"
        case .assetFileNotFound: return "assetFileNotFound"
        case .assetFileModified: return "assetFileModified"
        default: return "CKError \(code.rawValue)"
        }
    }
}
