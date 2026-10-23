import Foundation
import GRDB

/// One synced column's value as it travels. It round-trips GRDB's `DatabaseValue` exactly, storage class
/// included: `date` and `bool` are used only where the stored value comes back byte-identical (a
/// `DATETIME` column holding GRDB's own date text, a `BOOLEAN` column holding 0 or 1); anything else
/// travels as what SQLite stores.
public enum SyncValue: Equatable, Hashable, Sendable {
    case int(Int64)
    case double(Double)
    case string(String)
    case data(Data)
    case date(Date)
    case bool(Bool)
    case null

    /// The value of a column whose declared type is `declaredType`.
    public init(_ value: DatabaseValue, declaredType: String) {
        let type = declaredType.uppercased()
        switch value.storage {
        case .null:
            self = .null
        case .int64(let int):
            if type == "BOOLEAN", int == 0 || int == 1 { self = .bool(int == 1) } else { self = .int(int) }
        case .double(let double):
            self = .double(double)
        case .string(let string):
            if type == "DATETIME", let date = Date.fromDatabaseValue(value), date.databaseValue == value {
                self = .date(date)
            } else {
                self = .string(string)
            }
        case .blob(let data):
            self = .data(data)
        }
    }

    public var databaseValue: DatabaseValue {
        switch self {
        case .int(let int): return int.databaseValue
        case .double(let double): return double.databaseValue
        case .string(let string): return string.databaseValue
        case .data(let data): return data.databaseValue
        case .date(let date): return date.databaseValue
        case .bool(let bool): return (bool ? 1 : 0 as Int64).databaseValue
        case .null: return .null
        }
    }

    public var isNull: Bool { self == .null }

    /// A deterministic text form, for tie-breaks and the conflict log.
    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }
}

extension SyncValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case int, double, string, data, date, bool, null
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = container.allKeys.first, container.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "One kind per value"))
        }
        switch key {
        case .int: self = .int(try container.decode(Int64.self, forKey: key))
        // Doubles travel as their bit pattern, so every value (negative zero included) comes back exactly.
        case .double: self = .double(Double(bitPattern: try container.decode(UInt64.self, forKey: key)))
        case .string: self = .string(try container.decode(String.self, forKey: key))
        case .data: self = .data(try container.decode(Data.self, forKey: key))
        case .date: self = .date(Date(timeIntervalSinceReferenceDate: Double(bitPattern: try container.decode(UInt64.self, forKey: key))))
        case .bool: self = .bool(try container.decode(Bool.self, forKey: key))
        case .null: self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .int(let int): try container.encode(int, forKey: .int)
        case .double(let double): try container.encode(double.bitPattern, forKey: .double)
        case .string(let string): try container.encode(string, forKey: .string)
        case .data(let data): try container.encode(data, forKey: .data)
        case .date(let date): try container.encode(date.timeIntervalSinceReferenceDate.bitPattern, forKey: .date)
        case .bool(let bool): try container.encode(bool, forKey: .bool)
        case .null: try container.encodeNil(forKey: .null)
        }
    }
}

/// When a field last changed and who changed it (a `syncFieldClock` row).
public struct SyncClock: Codable, Equatable, Hashable, Sendable {
    public var at: Date
    public var by: String?

    public init(at: Date, by: String?) {
        self.at = at
        self.by = by
    }
}

/// One record as it travels (sync spec §4.1): record type = table name, record name = the row's UUID.
public struct SyncPayload: Codable, Equatable, Sendable {
    public var recordType: String
    public var recordName: String
    public var zone: String
    /// Every synced column. References (declared foreign keys, logical and polymorphic references) are the
    /// referenced row's UUID string, `null` when there is none, or `int(0)` when the reference names no
    /// row here (a deleted row, or a row of a table that doesn't sync) and the column can't be null. JSON
    /// columns carry UUID strings where they hold ids, and 0 for an id that names no row.
    public var fields: [String: SyncValue]
    /// The record's per-field clocks, exactly the sender's `syncFieldClock` rows: `*` is the insert, and a
    /// field without its own entry dates from it. Empty for a row written before tracking (it dates from no
    /// time and loses to any dated edit).
    public var clocks: [String: SyncClock]
    public var modifiedBy: String?
    public var modifiedAt: Date?
    /// A redirect, not a record: this record was merged into the one named (both devices made it). It has
    /// no fields; receivers re-key their row and never delete it.
    public var mergedInto: String?
    /// The import run whose batch this record belongs to (sync spec §5.2): set while the run's batch is
    /// being uploaded, on every record the confirm (or the Undo) wrote. Receivers hold it in staging until
    /// the whole batch is there.
    public var importRunUuid: String?
    /// Which of the run's batches (1: the import, 2: its Undo), with `importRunUuid`.
    public var batchGeneration: Int?
    /// On an `importRun` record: its batch's manifest (record count per type, and more; `SyncBatch`).
    public var manifest: SyncBatchManifest?
    /// On an `importChange` record (ruling R7): the UUIDs it names of rows that were already gone when it
    /// was sent, so a receiver that never had one doesn't wait for it.
    public var deletedReferences: [String]?
    /// Set only on the wire (ruling R4): the record was too large for one server record, so its payload
    /// travels as an encrypted asset field of the record, and this names it. The engine reassembles it.
    public var largePayload: SyncLargePayloadReference?
    /// Ruling R12: sent again because a full fetch found it missing on the server (a delete missed while a
    /// token was expired, or a zone reset). A receiver that deleted it takes it back, and logs that.
    public var resent: Bool?

    public init(recordType: String, recordName: String, zone: String, fields: [String: SyncValue],
                clocks: [String: SyncClock] = [:], modifiedBy: String? = nil, modifiedAt: Date? = nil, mergedInto: String? = nil,
                importRunUuid: String? = nil, batchGeneration: Int? = nil, manifest: SyncBatchManifest? = nil,
                deletedReferences: [String]? = nil) {
        self.recordType = recordType
        self.recordName = recordName
        self.zone = zone
        self.fields = fields
        self.clocks = clocks
        self.modifiedBy = modifiedBy
        self.modifiedAt = modifiedAt
        self.mergedInto = mergedInto
        self.importRunUuid = importRunUuid
        self.batchGeneration = batchGeneration
        self.manifest = manifest
        self.deletedReferences = deletedReferences
    }

    /// When `field` last changed on the sender: its own clock, else the insert's, else never.
    public func clock(_ field: String) -> SyncClock? { clocks[field] ?? clocks[SyncMerge.insertClock] }
}

/// Where a payload too large for a record went (ruling R4): an asset field of the same record, holding
/// the payload sealed with AES-GCM under `key`, a random key that travels only in the record's encrypted
/// fields.
public struct SyncLargePayloadReference: Codable, Equatable, Hashable, Sendable {
    public var assetField: String
    public var key: Data

    public init(assetField: String, key: Data) {
        self.assetField = assetField
        self.key = key
    }
}
