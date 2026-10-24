import CryptoKit
import Foundation
import os
import Security
import BudgetCore

/// The zone keys in iCloud Keychain (ruling R15, sync spec §9.1): one synchronizable generic-password item per
/// zone key, so every device signed in to the Apple Account receives it end to end and Apple never holds it.
/// - data-protection keychain, `kSecAttrSynchronizable`, `kSecAttrAccessibleAfterFirstUnlock` (background sync
///   works while locked; never `ThisDeviceOnly`, which wouldn't sync), never bound to biometry;
/// - service `ubberninja.mango.sync`, account `<container>/<zone>/<keyId>`, value the 32 key bytes;
/// - `kSecAttrGeneric` holds when it was stored here (8 bytes), so `key(zone:)` is the newest.
///
/// In the `MangoSync` target, shared by the Mac and iOS apps; never exercised by tests or tools (they use
/// `InMemorySyncKeyStore`).
public final class KeychainSyncKeyStore: SyncKeyStore {
    public static let service = "ubberninja.mango.sync"
    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    public enum KeychainError: Error, Equatable {
        case status(OSStatus)
    }

    let container: String
    /// The scope this store's items live under: the container's (real data) or `CloudKitTransport.demoKeyScope`.
    public var scope: String { container }

    public init(container: String = CloudKitTransport.containerIdentifier) {
        self.container = container
    }

    func prefix(_ zone: String) -> String { "\(container)/\(zone)/" }

    func baseQuery() -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: Self.service,
         kSecAttrSynchronizable: kCFBooleanTrue as Any,
         kSecUseDataProtectionKeychain: true]
    }

    public func key(zone: String) throws -> SymmetricKey? {
        try items(zone: zone).max { $0.storedAt < $1.storedAt }?.key
    }

    public func allKeys(zone: String) throws -> [String: SymmetricKey] {
        Dictionary(try items(zone: zone).map { ($0.id, $0.key) }, uniquingKeysWith: { first, _ in first })
    }

    public func store(_ key: SymmetricKey, zone: String) throws {
        let id = DocumentCrypto.zoneKeyId(key)
        var query = baseQuery()
        query[kSecAttrAccount] = prefix(zone) + id
        query[kSecValueData] = key.withUnsafeBytes { Data($0) }
        query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        query[kSecAttrLabel] = "Mango household key"
        var storedAt = Date().timeIntervalSinceReferenceDate.bitPattern.bigEndian
        query[kSecAttrGeneric] = Data(bytes: &storedAt, count: 8)
        let status = SecItemAdd(query as CFDictionary, nil)
        // A key already held (here, or delivered by iCloud Keychain) changes nothing.
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            Self.log.error("Sync key store: SecItemAdd returned \(status, privacy: .public)")
            throw KeychainError.status(status)
        }
    }

    private struct Item {
        var id: String
        var key: SymmetricKey
        var storedAt: UInt64
    }

    /// Every item of `zone` whose value is a 256-bit key matching its account's id.
    private func items(zone: String) throws -> [Item] {
        var query = baseQuery()
        query[kSecReturnAttributes] = true
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = result as? [[CFString: Any]] else {
            Self.log.error("Sync key store: SecItemCopyMatching returned \(status, privacy: .public)")
            throw KeychainError.status(status)
        }
        let prefix = prefix(zone)
        return rows.compactMap { row in
            guard let account = row[kSecAttrAccount] as? String, account.hasPrefix(prefix),
                  let data = row[kSecValueData] as? Data, data.count == 32 else { return nil }
            let key = SymmetricKey(data: data)
            let id = String(account.dropFirst(prefix.count))
            guard DocumentCrypto.zoneKeyId(key) == id else { return nil }
            let stamp = (row[kSecAttrGeneric] as? Data).flatMap { $0.count == 8 ? $0.reduce(UInt64(0)) { $0 << 8 | UInt64($1) } : nil }
            return Item(id: id, key: key, storedAt: stamp ?? 0)
        }
    }
}
