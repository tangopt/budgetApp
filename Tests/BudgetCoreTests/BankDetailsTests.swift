import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

final class BankDetailsTests: XCTestCase {
    private func makeDB() throws -> DatabaseManager {
        return try TestDatabase.migratedManager()
    }

    private func account(_ currency: Currency = .gbp, region: BankRegion? = nil, sortCode: String? = nil, accountNumber: String? = nil,
                         iban: String? = nil, routingNumber: String? = nil, bankName: String? = nil, bic: String? = nil) -> Account {
        var a = Account(id: 1, name: "Lloyds Classic", currency: currency, kind: .cash, trackingMode: .imported,
                        sortCode: sortCode, accountNumber: accountNumber, iban: iban)
        a.bankRegion = region
        a.routingNumber = routingNumber
        a.bankName = bankName
        a.bic = bic
        return a
    }

    // MARK: Region derivation

    func testEffectiveRegionPrefersStoredThenDetailsThenCurrency() {
        XCTAssertEqual(account(region: .other, sortCode: "300000").effectiveBankRegion, .other)
        XCTAssertEqual(account(.eur, sortCode: "300000", iban: "DE89370400440532013000").effectiveBankRegion, .uk)
        XCTAssertEqual(account(.gbp, iban: "DE89370400440532013000", routingNumber: "021000021").effectiveBankRegion, .europe)
        XCTAssertEqual(account(.gbp, routingNumber: "021000021").effectiveBankRegion, .us)
        XCTAssertEqual(account(.gbp).effectiveBankRegion, .uk)
        XCTAssertEqual(account(.eur).effectiveBankRegion, .europe)
        XCTAssertEqual(BankRegion.forCurrency(.gbp), .uk)
        XCTAssertEqual(BankRegion.forCurrency(.eur), .europe)
    }

    func testRegionFields() {
        XCTAssertEqual(BankRegion.uk.fields, [.sortCode, .accountNumber, .iban])
        XCTAssertEqual(BankRegion.us.fields, [.routingNumber, .accountNumber])
        XCTAssertEqual(BankRegion.europe.fields, [.iban])
        XCTAssertEqual(BankRegion.other.fields, [.accountNumber])
    }

    // MARK: US

    func testRoutingNumberNineDigitsWithABAChecksum() throws {
        XCTAssertEqual(try AccountDetailsFormat.normalizedRoutingNumber(" 021-000-021 "), "021000021")
        XCTAssertEqual(try AccountDetailsFormat.normalizedRoutingNumber("011000015"), "011000015")
        XCTAssertNil(try AccountDetailsFormat.normalizedRoutingNumber(" "))
        for bad in ["021000022", "02100002", "0210000211", "02100002A"] {
            XCTAssertThrowsError(try AccountDetailsFormat.normalizedRoutingNumber(bad), bad) {
                XCTAssertEqual($0 as? AccountDetailsError, .invalidRoutingNumber)
            }
        }
    }

    func testUSAccountNumberFourToSeventeenDigits() throws {
        XCTAssertEqual(try AccountDetailsFormat.normalizedAccountNumber("1234", region: .us), "1234")
        XCTAssertEqual(try AccountDetailsFormat.normalizedAccountNumber("1234 5678 9012 34567", region: .us), "12345678901234567")
        for bad in ["123", "123456789012345678", "12A4"] {
            XCTAssertThrowsError(try AccountDetailsFormat.normalizedAccountNumber(bad, region: .us), bad) {
                XCTAssertEqual($0 as? AccountDetailsError, .invalidUSAccountNumber)
            }
        }
    }

    // MARK: Europe

    func testIBANMod97ChecksumEnforced() throws {
        XCTAssertEqual(try AccountDetailsFormat.normalizedIBAN("de89 3704 0044 0532 0130 00"), "DE89370400440532013000")
        XCTAssertEqual(try AccountDetailsFormat.normalizedIBAN("FR1420041010050500013M02606"), "FR1420041010050500013M02606")
        for bad in ["GB28NWBK60161331926819", "DE89370400440532013001"] {
            XCTAssertThrowsError(try AccountDetailsFormat.normalizedIBAN(bad), bad) {
                XCTAssertEqual($0 as? AccountDetailsError, .invalidIBANChecksum)
            }
        }
    }

    // MARK: Other

    func testOtherAccountNumberFreeTextUpTo34() throws {
        XCTAssertEqual(try AccountDetailsFormat.normalizedAccountNumber("  AB-12 34/X ", region: .other), "AB-12 34/X")
        XCTAssertNil(try AccountDetailsFormat.normalizedAccountNumber("  ", region: .other))
        XCTAssertEqual(try AccountDetailsFormat.normalizedAccountNumber(String(repeating: "1", count: 34), region: .other)?.count, 34)
        XCTAssertThrowsError(try AccountDetailsFormat.normalizedAccountNumber(String(repeating: "1", count: 35), region: .other)) {
            XCTAssertEqual($0 as? AccountDetailsError, .accountNumberTooLong)
        }
    }

    func testUKAccountNumberKeepsSixToEight() throws {
        XCTAssertEqual(try AccountDetailsFormat.normalizedAccountNumber("123456", region: .uk), "123456")
        XCTAssertThrowsError(try AccountDetailsFormat.normalizedAccountNumber("12345", region: .uk))
    }

    // MARK: All regions

    func testBICUppercasedEightOrEleven() throws {
        XCTAssertEqual(try AccountDetailsFormat.normalizedBIC(" loydgb2l "), "LOYDGB2L")
        XCTAssertEqual(try AccountDetailsFormat.normalizedBIC("DEUT DE FF 500"), "DEUTDEFF500")
        XCTAssertNil(try AccountDetailsFormat.normalizedBIC(""))
        for bad in ["LOYDGB2", "LOYDGB2L5", "1OYDGB2L", "LOYD12AA", "LOYDGB2L50!", "LOYDGB-2L"] {
            XCTAssertThrowsError(try AccountDetailsFormat.normalizedBIC(bad), bad) {
                XCTAssertEqual($0 as? AccountDetailsError, .invalidBIC)
            }
        }
    }

    func testBankNameTrimmed() {
        XCTAssertEqual(AccountDetailsFormat.normalizedBankName("  Lloyds Bank "), "Lloyds Bank")
        XCTAssertNil(AccountDetailsFormat.normalizedBankName("  "))
    }

    // MARK: AccountDetails per region

    func testValidationOnlyForVisibleFields() throws {
        // UK: an invalid routing number is hidden, so it doesn't count.
        let uk = AccountDetails(sortCode: "30-00-00", accountNumber: "12345678", iban: "", region: .uk, bankName: " Lloyds Bank ", routingNumber: "999", bic: "loydgb2l")
        XCTAssertEqual(uk.errors(), [:])
        let n = try uk.normalized()
        XCTAssertEqual(n.sortCode, "300000")
        XCTAssertEqual(n.bankName, "Lloyds Bank")
        XCTAssertEqual(n.bic, "LOYDGB2L")
        XCTAssertEqual(n.region, .uk)

        let us = AccountDetails(sortCode: "1", accountNumber: "12", region: .us, routingNumber: "021000022", bic: "X")
        XCTAssertEqual(us.errors(), [.routingNumber: .invalidRoutingNumber, .accountNumber: .invalidUSAccountNumber, .bic: .invalidBIC])
        XCTAssertThrowsError(try us.normalized()) { XCTAssertEqual($0 as? AccountDetailsError, .invalidRoutingNumber) }

        let europe = AccountDetails(accountNumber: "nope", iban: "GB28NWBK60161331926819", region: .europe)
        XCTAssertEqual(europe.errors(), [.iban: .invalidIBANChecksum])
    }

    func testStoredValuesFailingNewRulesStillSaveWhenUnchanged() throws {
        let existing = account(region: .europe, iban: "GB28NWBK60161331926819")
        let unchanged = AccountDetails(iban: "GB28 NWBK 6016 1331 9268 19", region: .europe)
        XCTAssertEqual(unchanged.errors(existing: existing), [:])
        XCTAssertEqual(try unchanged.normalized(existing: existing).iban, "GB28NWBK60161331926819")
        let edited = AccountDetails(iban: "GB28 NWBK 6016 1331 9268 18", region: .europe)
        XCTAssertEqual(edited.errors(existing: existing), [.iban: .invalidIBANChecksum])
    }

    // MARK: Migration and saving

    func testMigrationAddsRegionColumns() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate(upTo: "addCategoryTransferAccountId")
        try manager.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO account (name, currency, kind, trackingMode, sortCode) VALUES ('Old', 'gbp', 'cash', 'manual', '300000')")
        }
        try manager.migrate()
        let columns = try manager.dbQueue.read { db in try db.columns(in: "account").map(\.name) }
        for column in ["bankRegion", "bankName", "routingNumber", "bic"] { XCTAssertTrue(columns.contains(column), column) }
        let old = try manager.dbQueue.read { db in try Account.fetchOne(db) }
        XCTAssertNil(old?.bankRegion)
        XCTAssertEqual(old?.effectiveBankRegion, .uk)
    }

    func testSavingStoresRegionAndKeepsHiddenFields() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            let a = try AccountEditing.add(db: db, name: "Lloyds", currency: .gbp, kind: .cash, openingBalanceEntered: nil, asOf: Date(),
                                           details: AccountDetails(sortCode: "30-00-00", accountNumber: "12345678", region: .uk, bankName: "Lloyds Bank", routingNumber: "021000021", bic: "LOYDGB2L"))
            var fetched = try Account.fetchOne(db, key: a.id!)!
            XCTAssertEqual(fetched.bankRegion, .uk)
            XCTAssertEqual(fetched.bankName, "Lloyds Bank")
            XCTAssertEqual(fetched.bic, "LOYDGB2L")
            XCTAssertNil(fetched.routingNumber) // hidden on add: not saved

            // Switch to US: the sort code stays in the DB, hidden.
            try AccountEditing.update(db: db, accountId: a.id!, name: "Lloyds", kind: .cash,
                                      details: AccountDetails(sortCode: "", accountNumber: "1234", region: .us, bankName: "", routingNumber: "021000021", bic: ""))
            fetched = try Account.fetchOne(db, key: a.id!)!
            XCTAssertEqual(fetched.bankRegion, .us)
            XCTAssertEqual(fetched.sortCode, "300000")
            XCTAssertEqual(fetched.accountNumber, "1234")
            XCTAssertEqual(fetched.routingNumber, "021000021")
            XCTAssertNil(fetched.bankName)
            XCTAssertNil(fetched.bic)
            XCTAssertEqual(fetched.effectiveBankRegion, .us)

            // Back to UK shows it again; the US account number fails UK rules unless unchanged.
            var back = AccountDetails(fetched)
            back.region = .uk
            XCTAssertNoThrow(try AccountEditing.update(db: db, accountId: a.id!, name: "Lloyds", kind: .cash, details: back))
            fetched = try Account.fetchOne(db, key: a.id!)!
            XCTAssertEqual(fetched.bankRegion, .uk)
            XCTAssertEqual(fetched.accountNumber, "1234")
            XCTAssertEqual(fetched.routingNumber, "021000021")
        }
    }

    // MARK: Detail panel lines and Copy all

    func testLinesForUK() {
        let a = account(sortCode: "300000", accountNumber: "12345678", iban: "GB29NWBK60161331926819", routingNumber: "021000021", bankName: "Lloyds Bank", bic: "LOYDGB2L")
        XCTAssertEqual(BankDetailsFormat.lines(for: a), [
            BankDetailLine(label: "Bank", shown: "Lloyds Bank", copied: "Lloyds Bank"),
            BankDetailLine(label: "Sort code", shown: "30-00-00", copied: "300000"),
            BankDetailLine(label: "Account number", shown: "12345678", copied: "12345678"),
            BankDetailLine(label: "IBAN", shown: "GB29 NWBK 6016 1331 9268 19", copied: "GB29NWBK60161331926819"),
            BankDetailLine(label: "BIC", shown: "LOYDGB2L", copied: "LOYDGB2L"),
        ])
    }

    func testLinesForUSAndEuropeOnlySetFields() {
        let us = account(region: .us, sortCode: "300000", accountNumber: "1234", routingNumber: "021000021")
        XCTAssertEqual(BankDetailsFormat.lines(for: us).map(\.label), ["Routing number", "Account number"])
        let europe = account(.eur, iban: "DE89370400440532013000")
        XCTAssertEqual(BankDetailsFormat.lines(for: europe), [BankDetailLine(label: "IBAN", shown: "DE89 3704 0044 0532 0130 00", copied: "DE89370400440532013000")])
        XCTAssertEqual(BankDetailsFormat.lines(for: account(region: .other, bankName: "  ")), [])
        XCTAssertEqual(BankDetailsFormat.lines(for: account()), [])
    }

    func testCopyAllText() {
        let a = account(sortCode: "300000", accountNumber: "12345678", bankName: "Lloyds Bank", bic: "LOYDGB2L")
        XCTAssertEqual(BankDetailsFormat.copyAllText(for: a),
                       "Lloyds Bank\nName: Lloyds Classic\nSort code: 30-00-00\nAccount number: 12345678\nBIC: LOYDGB2L")
        let noBank = account(region: .other, accountNumber: "X-1")
        XCTAssertEqual(BankDetailsFormat.copyAllText(for: noBank), "Name: Lloyds Classic\nAccount number: X-1")
        XCTAssertNil(BankDetailsFormat.copyAllText(for: account()))
    }
}
