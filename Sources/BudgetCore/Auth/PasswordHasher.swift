import Foundation
import CommonCrypto
import Security

/// PBKDF2-HMAC-SHA256 password hashing. Encoded as `pbkdf2-sha256$<rounds>$<salt b64>$<hash b64>`.
/// Used for sign-in passwords and recovery keys; the result lives only in `localCredential`. Never logged.
public enum PasswordHasher {
    public static let currentRounds = 600_000
    static let scheme = "pbkdf2-sha256"
    static let saltLength = 16
    static let hashLength = 32

    public static func hash(_ password: String, rounds: Int = currentRounds) -> String {
        var salt = Data(count: saltLength)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, saltLength, $0.baseAddress!) }
        precondition(status == errSecSuccess, "No secure random bytes")
        let derived = pbkdf2(password: password, salt: salt, rounds: rounds)
        return [scheme, String(rounds), salt.base64EncodedString(), derived.base64EncodedString()].joined(separator: "$")
    }

    public static func verify(_ password: String, against encoded: String) -> Bool {
        guard let parts = parse(encoded) else { return false }
        let derived = pbkdf2(password: password, salt: parts.salt, rounds: parts.rounds)
        return constantTimeEqual(Array(derived), Array(parts.hash))
    }

    /// True when the stored hash was made with fewer rounds than today's (or can't be read).
    public static func needsRehash(_ encoded: String) -> Bool {
        guard let parts = parse(encoded) else { return true }
        return parts.rounds < currentRounds
    }

    static func pbkdf2(password: String, salt: Data, rounds: Int) -> Data {
        var derived = [UInt8](repeating: 0, count: hashLength)
        let passwordBytes = Array(password.utf8)
        let saltBytes = Array(salt)
        let status = passwordBytes.withUnsafeBufferPointer { pw in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                UnsafeRawPointer(pw.baseAddress)?.assumingMemoryBound(to: Int8.self), passwordBytes.count,
                saltBytes, saltBytes.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                &derived, derived.count)
        }
        precondition(status == kCCSuccess, "PBKDF2 failed")
        return Data(derived)
    }

    private static func parse(_ encoded: String) -> (rounds: Int, salt: Data, hash: Data)? {
        let parts = encoded.split(separator: "$", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == scheme, let rounds = Int(parts[1]), rounds > 0,
              let salt = Data(base64Encoded: String(parts[2])), !salt.isEmpty,
              let hash = Data(base64Encoded: String(parts[3])), !hash.isEmpty else { return nil }
        return (rounds, salt, hash)
    }

    /// XOR-accumulates over equal-length byte arrays, so the time doesn't depend on where they differ.
    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}
