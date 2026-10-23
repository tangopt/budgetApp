import CryptoKit
import Foundation

public enum DocumentCryptoError: Error, Equatable, Sendable {
    /// The wrapped key isn't one this code wrote.
    case malformed
    /// The data key was wrapped with another zone key than the one given.
    case wrongZoneKey
    /// The ciphertext, the wrapped key or the context doesn't authenticate: damaged, or not this document's.
    case authenticationFailed
}

/// Document encryption (sync spec §9.1), because Advanced Data Protection isn't available to UK accounts:
/// - each document gets a random 256-bit **data key**; its file is sealed with AES-GCM under it,
///   authenticating the context (the document's record name and plaintext SHA-256), so a file can't be
///   passed off as another document's;
/// - the data key is sealed (wrapped) with the zone's 256-bit **zone key**; the wrapped key travels in the
///   document record's encrypted fields, the ciphertext alone in its asset;
/// - rotation re-wraps data keys under a new zone key; the files (and their ciphertext) don't change.
///
/// A wrapped key is `"MDK1"` + the zone key's 8-byte id + the AES-GCM combined box of the data key, so a
/// device can tell which zone key it needs.
public enum DocumentCrypto {
    private static let magic = Data("MDK1".utf8)
    private static let idLength = 8
    private static let wrapContext = Data("mango.document-key.v1".utf8)

    public static func newZoneKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    /// A zone key's id: hex of the first 8 bytes of a SHA-256 over a label and the key (not the key).
    public static func zoneKeyId(_ zoneKey: SymmetricKey) -> String {
        hex(Data(rawId(zoneKey)))
    }

    /// The id of the zone key `wrappedKey` was wrapped with.
    public static func zoneKeyId(ofWrapped wrappedKey: Data) throws -> String {
        let (id, _) = try split(wrappedKey)
        return hex(id)
    }

    /// The authenticated context of a document's file: its record name and its plaintext SHA-256.
    public static func documentContext(uuid: String, sha256: String) -> Data {
        Data("mango.document.v1|\(uuid)|\(sha256.lowercased())".utf8)
    }

    /// Seals `plaintext` under a new random data key, and wraps that key with `zoneKey`.
    public static func seal(_ plaintext: Data, zoneKey: SymmetricKey, authenticating context: Data = Data()) throws
        -> (ciphertext: Data, wrappedKey: Data) {
        let dataKey = SymmetricKey(size: .bits256)
        guard let ciphertext = try AES.GCM.seal(plaintext, using: dataKey, authenticating: context).combined else {
            throw DocumentCryptoError.malformed
        }
        return (ciphertext, try wrap(dataKey, with: zoneKey))
    }

    /// Opens a file sealed by `seal`.
    public static func open(_ ciphertext: Data, wrappedKey: Data, zoneKey: SymmetricKey, authenticating context: Data = Data()) throws -> Data {
        let dataKey = try unwrap(wrappedKey, with: zoneKey)
        do {
            return try AES.GCM.open(try AES.GCM.SealedBox(combined: ciphertext), using: dataKey, authenticating: context)
        } catch {
            throw DocumentCryptoError.authenticationFailed
        }
    }

    /// The same data key, wrapped with `new` instead of `old` (rotation): the file isn't touched.
    public static func rewrap(_ wrappedKey: Data, from old: SymmetricKey, to new: SymmetricKey) throws -> Data {
        try wrap(try unwrap(wrappedKey, with: old), with: new)
    }

    public static func sha256(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    // MARK: Wrapping

    private static func wrap(_ dataKey: SymmetricKey, with zoneKey: SymmetricKey) throws -> Data {
        let raw = dataKey.withUnsafeBytes { Data($0) }
        guard let box = try AES.GCM.seal(raw, using: zoneKey, authenticating: wrapContext).combined else { throw DocumentCryptoError.malformed }
        return magic + rawId(zoneKey) + box
    }

    private static func unwrap(_ wrappedKey: Data, with zoneKey: SymmetricKey) throws -> SymmetricKey {
        let (id, box) = try split(wrappedKey)
        guard id == Data(rawId(zoneKey)) else { throw DocumentCryptoError.wrongZoneKey }
        do {
            let raw = try AES.GCM.open(try AES.GCM.SealedBox(combined: box), using: zoneKey, authenticating: wrapContext)
            guard raw.count == 32 else { throw DocumentCryptoError.malformed }
            return SymmetricKey(data: raw)
        } catch let error as DocumentCryptoError {
            throw error
        } catch {
            throw DocumentCryptoError.authenticationFailed
        }
    }

    private static func split(_ wrappedKey: Data) throws -> (id: Data, box: Data) {
        let bytes = Data(wrappedKey)
        // magic + id + nonce (12) + key (32) + tag (16)
        guard bytes.count == magic.count + idLength + 12 + 32 + 16, bytes.prefix(magic.count) == magic else {
            throw DocumentCryptoError.malformed
        }
        let id = bytes.subdata(in: magic.count..<(magic.count + idLength))
        return (id, bytes.subdata(in: (magic.count + idLength)..<bytes.count))
    }

    private static func rawId(_ zoneKey: SymmetricKey) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data("mango.zone-key-id.v1".utf8))
        zoneKey.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        return Data(hasher.finalize().prefix(idLength))
    }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
