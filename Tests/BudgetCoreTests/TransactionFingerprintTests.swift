import XCTest
@testable import BudgetCore

final class TransactionFingerprintTests: XCTestCase {
    func testWhichInputsChangeTheFingerprint() {
        let date = Date(timeIntervalSince1970: 1_770_000_000)
        typealias Inputs = (accountId: Int64, amount: Int, description: String)
        let cases: [(name: String, first: Inputs, second: Inputs, same: Bool)] = [
            ("same inputs", (1, -4564, "SAINSBURYS LONDON"), (1, -4564, "SAINSBURYS LONDON"), true),
            ("description normalisation ignores case and whitespace", (1, -4564, "Sainsburys  London"), (1, -4564, "SAINSBURYS LONDON"), true),
            ("different amounts", (1, -4564, "SAINSBURYS"), (1, -4500, "SAINSBURYS"), false),
            ("different accounts", (1, -4564, "SAINSBURYS"), (2, -4564, "SAINSBURYS"), false),
        ]
        for c in cases {
            let a = TransactionFingerprint.compute(accountId: c.first.accountId, date: date, amountMinorUnits: c.first.amount, description: c.first.description)
            let b = TransactionFingerprint.compute(accountId: c.second.accountId, date: date, amountMinorUnits: c.second.amount, description: c.second.description)
            if c.same {
                XCTAssertEqual(a, b, c.name)
            } else {
                XCTAssertNotEqual(a, b, c.name)
            }
        }
    }

    func testOccurrenceZeroMatchesLegacyFingerprintAndLaterOccurrencesDiffer() {
        let date = Date(timeIntervalSince1970: 1_770_000_000)
        let legacy = TransactionFingerprint.compute(accountId: 1, date: date, amountMinorUnits: -330, description: "PRET")
        let first = TransactionFingerprint.compute(accountId: 1, date: date, amountMinorUnits: -330, description: "PRET", occurrence: 0)
        let second = TransactionFingerprint.compute(accountId: 1, date: date, amountMinorUnits: -330, description: "PRET", occurrence: 1)
        XCTAssertEqual(legacy, first)
        XCTAssertNotEqual(first, second)
    }
}
