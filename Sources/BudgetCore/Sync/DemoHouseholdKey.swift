import CryptoKit
import Foundation
import GRDB

/// The household key handed to the iPhone simulator for the sync demo (plan step 4 Task 12): the simulator has no
/// iCloud Keychain, so a DEBUG simulator launch with `--sync-demo` takes the demo key from
/// `MANGO_DEMO_HOUSEHOLD_KEY` (64 hex characters) and stores it under the demo key-store scope. Never a real key:
/// the demo scope seals only the demo database.
public enum DemoHouseholdKey {
    public static let environmentVariable = "MANGO_DEMO_HOUSEHOLD_KEY"

    /// The 32-byte key `text` spells in hex (64 characters, either case, surrounding whitespace ignored); nil for
    /// anything else, so a malformed value stores nothing.
    public static func parse(_ text: String) -> SymmetricKey? {
        let hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count == 64 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16), hex[index..<next].allSatisfy(\.isHexDigit) else { return nil }
            bytes.append(byte)
            index = next
        }
        return SymmetricKey(data: bytes)
    }

    /// `key` as 64 lowercase hex characters (what `parse` reads).
    public static func hex(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { bytes in bytes.map { String(format: "%02x", $0) }.joined() }
    }

    /// The household key the zone's marker names, in hex, once that marker is on the server (this database has a
    /// stamp for it: a sync published or adopted it) and `keyStore` holds it; nil otherwise. The Mac's
    /// `--print-demo-key` passes only the demo scope's store.
    public static func confirmedKeyHex(db: any DatabaseReader, keyStore: any SyncKeyStore,
                                       zone: String = SyncRecordStore.householdZone) throws -> String? {
        guard let local = try db.read({ db in try SyncZoneKeys.local(zone: zone, db: db) }), local.systemFields != nil,
              let key = try keyStore.allKeys(zone: zone)[local.marker.keyId] else { return nil }
        return hex(key)
    }
}
