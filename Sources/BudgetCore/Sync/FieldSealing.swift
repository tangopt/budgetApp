import CryptoKit
import Foundation

/// Ruling R15 (sync spec §4.2): Mango seals every record's fields itself, because CloudKit's `encryptedValues`
/// proved readable in the CloudKit Console for the household's accounts.
///
/// A record built by `SyncWireRecord(payload)` (a value per field, its metadata in `meta`) is the *inner* record.
/// What goes to the server is the *outer* record: the same type, name and zone, and exactly two fields, both
/// still in `encryptedValues` as a second layer:
/// - `sealed`: `"MSB"`, the wire format version (1), then the AES-GCM-256 combined box (nonce, ciphertext, tag)
///   of the inner fields in a deterministic encoding (sorted keys, length-prefixed), under the zone key;
/// - `keyId`: the id of that zone key (`DocumentCrypto.zoneKeyId`, 16 hex digits).
///
/// The authenticated data binds the version, zone, record type, record name, key id and the part (`fields`, or
/// `asset:<name>`), so a blob can't be moved to another record, type or zone, or relabelled with another key.
/// The inner record's assets (ruling R4's large payloads) are sealed the same way, each under its own part.
public enum FieldSealing {
    public static let sealedField = "sealed"
    public static let keyIdField = "keyId"
    public static let version: UInt8 = 1
    static let magic = Data("MSB".utf8)

    public enum SealingError: Error, Equatable, Sendable {
        /// Not a sealed record (another format, or a field beside `sealed` and `keyId`): never read.
        case notSealed
        /// A wire format this build doesn't know.
        case unknownVersion(UInt8)
        /// Sealed under a zone key this device doesn't hold (yet).
        case keyMissing(String)
        /// The box doesn't open: damaged, moved from another record, or not this key's.
        case authenticationFailed
        /// The opened fields aren't in this encoding.
        case malformed
    }

    // MARK: Records

    /// The outer record for `inner`, sealed under `key`.
    public static func seal(_ inner: SyncWireRecord, key: SymmetricKey) throws -> SyncWireRecord {
        guard inner.unencryptedFields.isEmpty else { throw SealingError.notSealed }
        let id = DocumentCrypto.zoneKeyId(key)
        var outer = SyncWireRecord(recordType: inner.recordType, recordName: inner.recordName, zone: inner.zone)
        outer.encryptedFields[sealedField] = try box(encode(inner.encryptedFields), key: key, keyId: id, part: "fields", record: inner)
        outer.encryptedFields[keyIdField] = Data(id.utf8)
        for (name, data) in inner.assets {
            guard name != sealedField, name != keyIdField else { throw SealingError.notSealed }
            outer.assets[name] = try box(data, key: key, keyId: id, part: "asset:" + name, record: inner)
        }
        return outer
    }

    /// The inner record `outer` holds, opened with the key its `keyId` names.
    public static func open(_ outer: SyncWireRecord, keys: [String: SymmetricKey]) throws -> SyncWireRecord {
        guard outer.unencryptedFields.isEmpty, Set(outer.encryptedFields.keys) == [sealedField, keyIdField],
              let sealed = outer.encryptedFields[sealedField], let id = keyId(of: outer) else { throw SealingError.notSealed }
        guard let key = keys[id] else { throw SealingError.keyMissing(id) }
        var inner = SyncWireRecord(recordType: outer.recordType, recordName: outer.recordName, zone: outer.zone)
        inner.encryptedFields = try decode(unbox(sealed, key: key, keyId: id, part: "fields", record: outer))
        for (name, data) in outer.assets {
            inner.assets[name] = try unbox(data, key: key, keyId: id, part: "asset:" + name, record: outer)
        }
        return inner
    }

    /// The zone key id a sealed record names, if it names one.
    public static func keyId(of outer: SyncWireRecord) -> String? {
        guard let data = outer.encryptedFields[keyIdField], let id = String(data: data, encoding: .utf8),
              id.count == 16, id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return id
    }

    // MARK: Boxes

    private static func box(_ plaintext: Data, key: SymmetricKey, keyId: String, part: String, record: SyncWireRecord) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: key, authenticating: context(keyId: keyId, part: part, record: record)).combined else {
            throw SealingError.malformed
        }
        return magic + Data([version]) + combined
    }

    private static func unbox(_ blob: Data, key: SymmetricKey, keyId: String, part: String, record: SyncWireRecord) throws -> Data {
        let bytes = Data(blob)
        guard bytes.count > magic.count, bytes.prefix(magic.count) == magic else { throw SealingError.notSealed }
        let found = bytes[bytes.startIndex + magic.count]
        guard found == version else { throw SealingError.unknownVersion(found) }
        do {
            let box = try AES.GCM.SealedBox(combined: bytes.dropFirst(magic.count + 1))
            return try AES.GCM.open(box, using: key, authenticating: context(keyId: keyId, part: part, record: record))
        } catch {
            throw SealingError.authenticationFailed
        }
    }

    /// The authenticated data: a label, the version, then each component length-prefixed (no separator to forge).
    static func context(keyId: String, part: String, record: SyncWireRecord) -> Data {
        var data = Data("mango.sealed-record".utf8) + Data([version])
        for component in [record.zone, record.recordType, record.recordName, keyId, part] {
            let bytes = Data(component.utf8)
            data += lengthPrefix(bytes.count) + bytes
        }
        return data
    }

    // MARK: The fields' encoding

    /// The count, then each field as its name and its value, each length-prefixed, in sorted name order: the same
    /// fields always give the same bytes.
    static func encode(_ fields: [String: Data]) -> Data {
        var data = lengthPrefix(fields.count)
        for name in fields.keys.sorted() {
            let key = Data(name.utf8)
            let value = fields[name] ?? Data()
            data += lengthPrefix(key.count) + key + lengthPrefix(value.count) + value
        }
        return data
    }

    /// The fields `encode` wrote; anything else (trailing bytes, names out of order or repeated) is malformed.
    static func decode(_ encoded: Data) throws -> [String: Data] {
        let bytes = Data(encoded)
        var offset = 0
        func take(_ count: Int) throws -> Data {
            guard count >= 0, offset + count <= bytes.count else { throw SealingError.malformed }
            defer { offset += count }
            return bytes.subdata(in: offset ..< offset + count)
        }
        func length() throws -> Int { try take(4).reduce(0) { $0 << 8 | Int($1) } }
        let count = try length()
        var fields: [String: Data] = [:]
        var previous: String?
        for _ in 0 ..< count {
            guard let name = String(data: try take(try length()), encoding: .utf8) else { throw SealingError.malformed }
            if let previous, previous >= name { throw SealingError.malformed }
            previous = name
            fields[name] = try take(try length())
        }
        guard offset == bytes.count else { throw SealingError.malformed }
        return fields
    }

    private static func lengthPrefix(_ count: Int) -> Data {
        var value = UInt32(count).bigEndian
        return Data(bytes: &value, count: 4)
    }
}
