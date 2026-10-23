import XCTest
@testable import BudgetCore

final class AuthTextTests: XCTestCase {
    func testInitialsTakeTheFirstAndLastWords() {
        XCTAssertEqual(AuthText.initials("Person A"), "PA")
        XCTAssertEqual(AuthText.initials("sam  de example"), "SE")
        XCTAssertEqual(AuthText.initials("Sam"), "S")
        XCTAssertEqual(AuthText.initials("  "), "?")
    }

    func testThrottleMessageRoundsUpAndKeepsTheFigureWhole() {
        XCTAssertEqual(AuthText.tryAgain(after: 3.2), "Try again in 4\u{00A0}s")
        XCTAssertEqual(AuthText.tryAgain(after: 60), "Try again in 60\u{00A0}s")
        // Never "0 s" while still throttled.
        XCTAssertEqual(AuthText.tryAgain(after: 0.01), "Try again in 1\u{00A0}s")
    }

    func testPasswordStrength() {
        XCTAssertEqual(PasswordStrength.assess(""), .tooShort)
        XCTAssertEqual(PasswordStrength.assess("abcdefghi"), .tooShort)
        XCTAssertEqual(PasswordStrength.assess("aaaaaaaaaaaa"), .weak)
        XCTAssertEqual(PasswordStrength.assess("abcdefghij"), .weak)
        XCTAssertEqual(PasswordStrength.assess("abcdefgh12"), .fair)
        XCTAssertEqual(PasswordStrength.assess("Synthetic-pass 42"), .strong)
        XCTAssertEqual(PasswordStrength.assess("four plain words here today"), .strong)
    }

    func testPasswordStrengthHints() {
        XCTAssertEqual(PasswordStrength.tooShort.hint, "At least 10 characters")
        XCTAssertFalse(PasswordStrength.weak.hint.isEmpty)
        XCTAssertTrue(PasswordStrength.tooShort < PasswordStrength.strong)
        XCTAssertFalse(PasswordStrength.tooShort.isAcceptable)
        XCTAssertTrue(PasswordStrength.weak.isAcceptable)
    }

    func testSentenceEndsWithOneFullStop() {
        XCTAssertEqual(AuthText.sentence("The Keychain refused it"), "The Keychain refused it.")
        XCTAssertEqual(AuthText.sentence("The Keychain refused it."), "The Keychain refused it.")
        XCTAssertEqual(AuthText.sentence("Done.. "), "Done.")
        XCTAssertEqual(AuthText.sentence("Really?"), "Really?")
        XCTAssertEqual(AuthText.sentence("  "), "")
    }
}
