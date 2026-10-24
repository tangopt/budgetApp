import Foundation
import Security
import BudgetCore

/// Removing one zone key from the Keychain: used only by the Mac's DEBUG `--sync-demo-reset` (plan step 4
/// Task 13), which removes the demo household key the earlier demo runs kept under the real scope
/// (`iCloud.ubberninja.mango/household/<keyId>`), approved by the user on 2026-10-24, so a later Production
/// bootstrap can never reuse it. Not part of `SyncKeyStore`: no sync path ever removes a key.
extension KeychainSyncKeyStore {
    public enum RemovalError: Error, Equatable {
        /// Not a key id (16 lowercase hex digits): nothing is removed.
        case notAKeyId
    }

    /// The query naming exactly one item: this scope's `<zone>/<keyId>`, synchronizable, data-protection keychain.
    func removalQuery(keyId: String, zone: String) -> [CFString: Any] {
        var query = baseQuery()
        query[kSecAttrAccount] = prefix(zone) + keyId
        return query
    }

    /// Removes the key `keyId` of `zone` from this scope (iCloud Keychain removes it from the account's other
    /// devices too). Returns whether there was one. Throws `notAKeyId` for anything but a key id, and the
    /// Keychain's status for any other failure.
    @discardableResult
    public func remove(keyId: String, zone: String) throws -> Bool {
        guard keyId.count == 16, keyId.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw RemovalError.notAKeyId }
        let status = SecItemDelete(removalQuery(keyId: keyId, zone: zone) as CFDictionary)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw KeychainError.status(status)
        }
    }
}
