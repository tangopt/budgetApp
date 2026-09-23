import XCTest
@testable import BudgetCore

final class TransactionFingerprintTests: XCTestCase {
    func testSameInputsProduceSameFingerprint() {
        let date = Date(timeIntervalSince1970: 1_770_000_000)
        let a = TransactionFingerprint.compute(accountId: 1, date: date, amountMinorUnits: -4564, description: "SAINSBURYS LONDON")
        let b = TransactionFingerprint.compute(accountId: 1, date: date, amountMinorUnits: -4564, description: "SAINSBURYS LONDON")
        XCTAssertEqual(a, b)
    }

    func testDescriptionNormalizationIgnoresCaseAndWhitespace() {
        let date = Date(timeIntervalSince1970: 1_770_000_000)
        let a = TransactionFingerprint.compute(accountId: 1, date: date, amountMinorUnits: -4564, description: "Sainsburys  London")
        let b = TransactionFingerprint.compute(accountId: 1, date: date, amountMinorUnits: -4564, description: "SAINSBURYS LONDON")
        XCTAssertEqual(a, b)
    }

    func testDifferentAmountsProduceDifferentFingerprints() {
        let date = Date(timeIntervalSince1970: 1_770_000_000)
        let a = TransactionFingerprint.compute(accountId: 1, date: date, amountMinorUnits: -4564, description: "SAINSBURYS")
        let b = TransactionFingerprint.compute(accountId: 1, date: date, amountMinorUnits: -4500, description: "SAINSBURYS")
        XCTAssertNotEqual(a, b)
    }

    func testOccurrenceZeroMatchesLegacyFingerprintAndLaterOccurrencesDiffer() {
        let date = Date(timeIntervalSince1970: 1_770_000_000)
        let legacy = TransactionFingerprint.compute(accountId: 1, date: date, amountMinorUnits: -330, description: "PRET")
        let first = TransactionFingerprint.compute(accountId: 1, date: date, amountMinorUnits: -330, description: "PRET", occurrence: 0)
        let second = TransactionFingerprint.compute(accountId: 1, date: date, amountMinorUnits: -330, description: "PRET", occurrence: 1)
        XCTAssertEqual(legacy, first)
        XCTAssertNotEqual(first, second)
    }

    func testDifferentAccountsProduceDifferentFingerprints() {
        let date = Date(timeIntervalSince1970: 1_770_000_000)
        let a = TransactionFingerprint.compute(accountId: 1, date: date, amountMinorUnits: -4564, description: "SAINSBURYS")
        let b = TransactionFingerprint.compute(accountId: 2, date: date, amountMinorUnits: -4564, description: "SAINSBURYS")
        XCTAssertNotEqual(a, b)
    }
}
