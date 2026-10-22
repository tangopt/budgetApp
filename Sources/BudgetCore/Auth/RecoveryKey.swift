import Foundation
import Security

/// A recovery key: 24 characters from an alphabet without look-alikes, shown as six groups of four.
/// Stored only as a `PasswordHasher` hash.
public enum RecoveryKey {
    public static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    public static let length = 24

    public static func generate() -> String {
        // The alphabet has 32 characters, which divides 256, so a byte modulo 32 is unbiased.
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "No secure random bytes")
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    /// "XXXX-XXXX-…" for display.
    public static func formatted(_ key: String) -> String {
        let characters = Array(key)
        return stride(from: 0, to: characters.count, by: 4)
            .map { String(characters[$0..<min($0 + 4, characters.count)]) }
            .joined(separator: "-")
    }

    /// The key as typed (any case, with spaces or hyphens) in canonical form; nil when it can't be a key.
    public static func normalised(_ input: String) -> String? {
        let cleaned = input.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard cleaned.count == length, cleaned.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return cleaned
    }
}
