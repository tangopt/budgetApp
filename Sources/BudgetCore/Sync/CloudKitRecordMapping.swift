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
            guard let (archived, keys) = try? unarchive(systemFields), archived.recordID == id, archived.recordType == wire.recordType else {
                throw MappingError.systemFieldsMismatch(recordName: wire.recordName)
            }
            record = archived
            // A modify only changes the keys it sets; CloudKit keeps the rest. The keys that version held and this
            // record doesn't (a column gone, an R4 payload moved between fields and its asset) are cleared, so the
            // server holds exactly this record, as a whole-record replacement (FakeCloud) would.
            if let keys {
                for key in keys.encrypted where wire.encryptedFields[key] == nil { record.encryptedValues[key] = nil }
                for key in keys.plain where wire.assets[key] == nil && wire.encryptedFields[key] == nil { record[key] = nil }
            }
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

    /// The names (never the values) of the keys a record version holds, kept with its system fields so a save
    /// built on them can clear what the new record no longer has.
    struct Keys: Codable, Equatable {
        var encrypted: [String]
        var plain: [String]
    }

    private static let keysMagic = Data("MSF1".utf8)

    /// The opaque `systemFields` blob of `SyncServerStamp`: `"MSF1"`, the length and JSON of the record's key names,
    /// then CloudKit's `encodeSystemFields` archive (secure coding).
    public static func systemFields(of record: CKRecord) -> Data {
        let encrypted = record.encryptedValues.allKeys().sorted()
        let keys = Keys(encrypted: encrypted, plain: Set(record.allKeys()).subtracting(encrypted).sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]  // the same record gives the same blob
        let json = (try? encoder.encode(keys)) ?? Data("{\"encrypted\":[],\"plain\":[]}".utf8)
        var length = UInt32(json.count).bigEndian
        return keysMagic + Data(bytes: &length, count: 4) + json + archivedSystemFieldsOnly(record)
    }

    /// CloudKit's `encodeSystemFields` archive alone.
    public static func archivedSystemFieldsOnly(_ record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    public static func unarchiveSystemFields(_ data: Data) throws -> CKRecord {
        try unarchive(data).record
    }

    /// The record the blob holds, and its key names when the blob carries them (a bare archive doesn't).
    static func unarchive(_ data: Data) throws -> (record: CKRecord, keys: Keys?) {
        var archive = Data(data)
        var keys: Keys?
        if archive.starts(with: keysMagic), archive.count >= 8 {
            let length = archive.subdata(in: archive.startIndex + 4 ..< archive.startIndex + 8).reduce(0) { $0 << 8 | Int($1) }
            let start = archive.startIndex + 8
            guard archive.count >= 8 + length else { throw CocoaError(.coderReadCorrupt) }
            keys = try JSONDecoder().decode(Keys.self, from: archive.subdata(in: start ..< start + length))
            archive = archive.subdata(in: start + length ..< archive.endIndex)
        }
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archive)
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        guard let record = CKRecord(coder: unarchiver) else { throw CocoaError(.coderReadCorrupt) }
        return (record, keys)
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

    /// One record's save as the protocol's result; a passing failure keeps the server's retry-after (M4).
    public static func saveResult(_ wire: SyncWireRecord, _ result: Result<CKRecord, Error>) -> SaveResult {
        switch result {
        case .success(let record):
            return SaveResult(recordName: wire.recordName, outcome: .saved(stamp(of: record)))
        case .failure(let error):
            let outcome = saveOutcome(for: error, wire: wire)
            guard case .failed = outcome, let error = error as? CKError, passingCodes.contains(error.code) else {
                return SaveResult(recordName: wire.recordName, outcome: outcome)
            }
            return SaveResult(recordName: wire.recordName, outcome: outcome, retryAfter: error.retryAfterSeconds)
        }
    }

    /// What one record of a change feed means for the page.
    public enum FeedOutcome {
        /// The record (or, when it can't be read, a stand-in without a payload the engine stages as unreadable).
        case change(SyncFeedChange)
        /// A passing failure: the page is fetched again from the same token.
        case failPage(Error)
    }

    /// One record a change feed delivered. A record fetched whole but not readable keeps its type (I1), so the
    /// engine still routes reserved types; a failure that passes fails the page; any other failure is that
    /// record's alone (I2), staged as unreadable with its type unknown, so one record never blocks the zone.
    public static func feedChange(_ id: CKRecord.ID, _ result: Result<CKRecord, Error>, zone: String) -> FeedOutcome {
        switch result {
        case .success(let record):
            if let server = try? serverRecord(record) { return .change(.record(server)) }
            return .change(.record(unreadable(id, recordType: record.recordType)))
        case .failure(let error):
            if let mapped = operationError(error, zone: zone) as? SyncTransportError, mapped.isPassing { return .failPage(mapped) }
            return .change(.record(unreadable(id, recordType: "")))
        }
    }

    /// A record named by the feed with no payload: the engine stages it as unreadable.
    static func unreadable(_ id: CKRecord.ID, recordType: String) -> SyncServerRecord {
        SyncServerRecord(wire: SyncWireRecord(recordType: recordType, recordName: id.recordName, zone: id.zoneID.zoneName),
                         stamp: SyncServerStamp(systemFields: Data(), changeTag: "", modifiedAt: .distantPast))
    }

    /// An operation's final error as what the call throws, or nil when the operation counts as finished: with
    /// results per record (saves, deletes, fetches, feed pages), a `partialFailure` is only the sum of those.
    public static func finalError(_ error: Error, zone: String, perRecordResults: Bool) -> Error? {
        if perRecordResults, (error as? CKError)?.code == .partialFailure { return nil }
        return operationError(error, zone: zone)
    }

    /// Codes that pass with time.
    static let passingCodes: Set<CKError.Code> = [.networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy]

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
                case .notAuthenticated, .quotaExceeded: return 1
                case .changeTokenExpired: return 2
                case .limitExceeded: return 3
                case .unavailable, .networkUnavailable: return 4
                case .unreadableRecord: return 5
                }
            }
            return mapped.min { rank($0) < rank($1) } ?? error
        }
        if passingCodes.contains(error.code) { return SyncTransportError.unavailable(retryAfter: error.retryAfterSeconds) }
        switch error.code {
        case .limitExceeded: return SyncTransportError.limitExceeded
        case .changeTokenExpired: return SyncTransportError.changeTokenExpired
        case .zoneNotFound, .userDeletedZone: return SyncTransportError.zoneNotFound(zone)
        case .notAuthenticated: return SyncTransportError.notAuthenticated
        case .quotaExceeded: return SyncTransportError.quotaExceeded
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

/// Assembling a save's results (M10), kept out of the App target so it is tested offline.
public enum CloudKitSaveAssembly {
    /// The results when nothing is to be sent: an atomic save with a record that couldn't be built (all or
    /// nothing: the others `batchRequestFailed`), or a save whose every record was refused. nil: send the rest.
    public static func resultsWithoutSending(_ records: [SyncWireRecord], refused: [String: SaveResult.Outcome], atomic: Bool) -> [SaveResult]? {
        guard !refused.isEmpty else { return nil }
        let allRefused = records.allSatisfy { refused[$0.recordName] != nil }
        guard atomic || allRefused else { return nil }
        return records.map { SaveResult(recordName: $0.recordName, outcome: refused[$0.recordName] ?? .batchRequestFailed) }
    }

    /// One result per record, in order: refused before sending, else the server's, else "no result" (sent again).
    public static func results(_ records: [SyncWireRecord], refused: [String: SaveResult.Outcome], taken: [String: SaveResult]) -> [SaveResult] {
        records.map { wire in
            if let outcome = refused[wire.recordName] { return SaveResult(recordName: wire.recordName, outcome: outcome) }
            return taken[wire.recordName] ?? SaveResult(recordName: wire.recordName, outcome: .failed("no result"))
        }
    }
}
