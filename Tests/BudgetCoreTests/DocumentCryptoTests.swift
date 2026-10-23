import XCTest
import CryptoKit
@testable import BudgetCore

/// Document encryption (sync spec §9.1, plan Task 7): a random data key per document seals the file with
/// AES-GCM; the data key travels wrapped with the zone key. Synthetic bytes only.
final class DocumentCryptoTests: XCTestCase {
    private let plaintext = Data("Synthetic receipt — total 12.34 — marker 7f3a9c".utf8) + Data((0..<4096).map { UInt8($0 % 251) })
    private let context = DocumentCrypto.documentContext(uuid: "DOC-1", sha256: String(repeating: "ab", count: 32))

    func testSealAndOpen() throws {
        let zoneKey = DocumentCrypto.newZoneKey()
        let sealed = try DocumentCrypto.seal(plaintext, zoneKey: zoneKey, authenticating: context)
        XCTAssertNotEqual(sealed.ciphertext, plaintext)
        XCTAssertNil(sealed.ciphertext.range(of: plaintext.prefix(32)), "no run of the plaintext in the ciphertext")
        let opened = try DocumentCrypto.open(sealed.ciphertext, wrappedKey: sealed.wrappedKey, zoneKey: zoneKey, authenticating: context)
        XCTAssertEqual(opened, plaintext)

        // The plan's context-free interface works too.
        let plain = try DocumentCrypto.seal(plaintext, zoneKey: zoneKey)
        XCTAssertEqual(try DocumentCrypto.open(plain.ciphertext, wrappedKey: plain.wrappedKey, zoneKey: zoneKey), plaintext)
    }

    func testEachSealUsesItsOwnDataKey() throws {
        let zoneKey = DocumentCrypto.newZoneKey()
        let first = try DocumentCrypto.seal(plaintext, zoneKey: zoneKey, authenticating: context)
        let second = try DocumentCrypto.seal(plaintext, zoneKey: zoneKey, authenticating: context)
        XCTAssertNotEqual(first.wrappedKey, second.wrappedKey)
        XCTAssertNotEqual(first.ciphertext, second.ciphertext)
        // A data key opens only its own file.
        XCTAssertThrowsError(try DocumentCrypto.open(first.ciphertext, wrappedKey: second.wrappedKey, zoneKey: zoneKey, authenticating: context))
    }

    func testAWrongKeyFails() throws {
        let zoneKey = DocumentCrypto.newZoneKey()
        let sealed = try DocumentCrypto.seal(plaintext, zoneKey: zoneKey, authenticating: context)
        XCTAssertThrowsError(try DocumentCrypto.open(sealed.ciphertext, wrappedKey: sealed.wrappedKey, zoneKey: DocumentCrypto.newZoneKey(),
                                                     authenticating: context)) { error in
            XCTAssertEqual(error as? DocumentCryptoError, .wrongZoneKey)
        }
    }

    func testAnotherDocumentsContextFails() throws {
        let zoneKey = DocumentCrypto.newZoneKey()
        let sealed = try DocumentCrypto.seal(plaintext, zoneKey: zoneKey, authenticating: context)
        let otherUuid = DocumentCrypto.documentContext(uuid: "DOC-2", sha256: String(repeating: "ab", count: 32))
        let otherHash = DocumentCrypto.documentContext(uuid: "DOC-1", sha256: String(repeating: "cd", count: 32))
        for wrong in [otherUuid, otherHash, Data()] {
            XCTAssertThrowsError(try DocumentCrypto.open(sealed.ciphertext, wrappedKey: sealed.wrappedKey, zoneKey: zoneKey, authenticating: wrong)) { error in
                XCTAssertEqual(error as? DocumentCryptoError, .authenticationFailed)
            }
        }
    }

    func testTamperedCiphertextOrWrappedKeyFails() throws {
        let zoneKey = DocumentCrypto.newZoneKey()
        let sealed = try DocumentCrypto.seal(plaintext, zoneKey: zoneKey, authenticating: context)
        var ciphertext = sealed.ciphertext
        ciphertext[ciphertext.startIndex + 40] ^= 0x01
        XCTAssertThrowsError(try DocumentCrypto.open(ciphertext, wrappedKey: sealed.wrappedKey, zoneKey: zoneKey, authenticating: context))
        var wrapped = sealed.wrappedKey
        wrapped[wrapped.endIndex - 1] ^= 0x01
        XCTAssertThrowsError(try DocumentCrypto.open(sealed.ciphertext, wrappedKey: wrapped, zoneKey: zoneKey, authenticating: context))
        XCTAssertThrowsError(try DocumentCrypto.open(sealed.ciphertext, wrappedKey: Data([1, 2, 3]), zoneKey: zoneKey, authenticating: context)) { error in
            XCTAssertEqual(error as? DocumentCryptoError, .malformed)
        }
    }

    func testRewrapOnRotation() throws {
        let old = DocumentCrypto.newZoneKey()
        let new = DocumentCrypto.newZoneKey()
        let sealed = try DocumentCrypto.seal(plaintext, zoneKey: old, authenticating: context)
        let rewrapped = try DocumentCrypto.rewrap(sealed.wrappedKey, from: old, to: new)

        XCTAssertEqual(try DocumentCrypto.zoneKeyId(ofWrapped: sealed.wrappedKey), DocumentCrypto.zoneKeyId(old))
        XCTAssertEqual(try DocumentCrypto.zoneKeyId(ofWrapped: rewrapped), DocumentCrypto.zoneKeyId(new))
        // The same ciphertext (no file re-sealed) opens under the new zone key, and no longer under the old one.
        XCTAssertEqual(try DocumentCrypto.open(sealed.ciphertext, wrappedKey: rewrapped, zoneKey: new, authenticating: context), plaintext)
        XCTAssertThrowsError(try DocumentCrypto.open(sealed.ciphertext, wrappedKey: rewrapped, zoneKey: old, authenticating: context))
        // Rewrapping needs the key it was wrapped with.
        XCTAssertThrowsError(try DocumentCrypto.rewrap(sealed.wrappedKey, from: new, to: old)) { error in
            XCTAssertEqual(error as? DocumentCryptoError, .wrongZoneKey)
        }
    }

    func testTheHashIsThePlaintextsAndUnchanged() throws {
        let zoneKey = DocumentCrypto.newZoneKey()
        let sha = SHA256.hash(data: plaintext).map { String(format: "%02x", $0) }.joined()
        let sealed = try DocumentCrypto.seal(plaintext, zoneKey: zoneKey, authenticating: DocumentCrypto.documentContext(uuid: "D", sha256: sha))
        let next = DocumentCrypto.newZoneKey()
        let rewrapped = try DocumentCrypto.rewrap(sealed.wrappedKey, from: zoneKey, to: next)
        let opened = try DocumentCrypto.open(sealed.ciphertext, wrappedKey: rewrapped, zoneKey: next,
                                             authenticating: DocumentCrypto.documentContext(uuid: "D", sha256: sha))
        XCTAssertEqual(DocumentCrypto.sha256(opened), sha, "the evidence hash stays the SHA-256 of the plaintext")
        XCTAssertNotEqual(DocumentCrypto.sha256(sealed.ciphertext), sha)
    }

    func testZoneKeyIdsDifferAndKeysAre256Bits() {
        let a = DocumentCrypto.newZoneKey()
        let b = DocumentCrypto.newZoneKey()
        XCTAssertEqual(a.bitCount, 256)
        XCTAssertNotEqual(DocumentCrypto.zoneKeyId(a), DocumentCrypto.zoneKeyId(b))
        XCTAssertEqual(DocumentCrypto.zoneKeyId(a), DocumentCrypto.zoneKeyId(a))
    }
}
