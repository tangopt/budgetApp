import XCTest
import GRDB
@testable import BudgetCore

final class AccountDetailsTests: XCTestCase {
    private func makeDB() throws -> DatabaseManager {
        let m = try DatabaseManager(path: nil)
        try m.migrate()
        return m
    }

    // MARK: Alias / displayName

    func testDisplayNameIsAliasWhenSetOtherwiseName() {
        var account = Account(name: "Lloyds Classic Account", currency: .gbp, kind: .cash, trackingMode: .imported)
        XCTAssertEqual(account.displayName, "Lloyds Classic Account")
        account.alias = "Lloyds"
        XCTAssertEqual(account.displayName, "Lloyds")
        account.alias = "  "
        XCTAssertEqual(account.displayName, "Lloyds Classic Account")
    }

    func testSortedByDisplayNameUsesAliasCaseInsensitiveAndNumeric() {
        let accounts = [
            Account(id: 1, name: "Zeta Bank", currency: .gbp, kind: .cash, trackingMode: .manual, alias: "amex"),
            Account(id: 2, name: "Barclays", currency: .gbp, kind: .cash, trackingMode: .manual),
            Account(id: 3, name: "Card 10", currency: .gbp, kind: .credit, trackingMode: .manual),
            Account(id: 4, name: "Card 9", currency: .gbp, kind: .credit, trackingMode: .manual),
        ]
        XCTAssertEqual(accounts.sortedByDisplayName().map(\.id), [1, 2, 4, 3])
    }

    func testAliasNormalisation() {
        XCTAssertEqual(AccountDetailsFormat.normalizedAlias("  Joint "), "Joint")
        XCTAssertNil(AccountDetailsFormat.normalizedAlias("   "))
        XCTAssertNil(AccountDetailsFormat.normalizedAlias(""))
    }

    // MARK: Sort code

    func testSortCodeNormalisesToSixDigits() throws {
        XCTAssertEqual(try AccountDetailsFormat.normalizedSortCode("30-00-00"), "300000")
        XCTAssertEqual(try AccountDetailsFormat.normalizedSortCode(" 30 00 00 "), "300000")
        XCTAssertEqual(try AccountDetailsFormat.normalizedSortCode("300000"), "300000")
        XCTAssertNil(try AccountDetailsFormat.normalizedSortCode("  "))
    }

    func testSortCodeRejectsWrongLengthOrLetters() {
        for bad in ["30-00-0", "3000000", "30-AB-00"] {
            XCTAssertThrowsError(try AccountDetailsFormat.normalizedSortCode(bad), bad) {
                XCTAssertEqual($0 as? AccountDetailsError, .invalidSortCode)
            }
        }
    }

    func testSortCodeDisplay() {
        XCTAssertEqual(AccountDetailsFormat.formattedSortCode("300000"), "30-00-00")
        XCTAssertEqual(AccountDetailsFormat.formattedSortCode("12345"), "12345")
    }

    // MARK: Account number

    func testAccountNumberDigitsSixToEight() throws {
        XCTAssertEqual(try AccountDetailsFormat.normalizedAccountNumber(" 1234 5678 "), "12345678")
        XCTAssertEqual(try AccountDetailsFormat.normalizedAccountNumber("123456"), "123456")
        XCTAssertNil(try AccountDetailsFormat.normalizedAccountNumber(""))
        for bad in ["12345", "123456789", "1234A678"] {
            XCTAssertThrowsError(try AccountDetailsFormat.normalizedAccountNumber(bad), bad) {
                XCTAssertEqual($0 as? AccountDetailsError, .invalidAccountNumber)
            }
        }
    }

    // MARK: IBAN

    func testIBANUppercasedWithoutSpaces() throws {
        XCTAssertEqual(try AccountDetailsFormat.normalizedIBAN("gb29 nwbk 6016 1331 9268 19"), "GB29NWBK60161331926819")
        XCTAssertEqual(try AccountDetailsFormat.normalizedIBAN("NO9386011117947"), "NO9386011117947") // 15, shortest
        XCTAssertNil(try AccountDetailsFormat.normalizedIBAN("  "))
    }

    func testIBANRejectsBadShape() {
        let tooLong = "GB29" + String(repeating: "1", count: 31) // 35
        for bad in ["GB2912345678", "1229NWBK60161331926819", "GBX9NWBK60161331926819", "GB29-NWBK-6016-1331-9268-19", tooLong] {
            XCTAssertThrowsError(try AccountDetailsFormat.normalizedIBAN(bad), bad) {
                XCTAssertEqual($0 as? AccountDetailsError, .invalidIBAN)
            }
        }
    }

    func testIBANDisplayInGroupsOfFour() {
        XCTAssertEqual(AccountDetailsFormat.formattedIBAN("GB29NWBK60161331926819"), "GB29 NWBK 6016 1331 9268 19")
    }

    func testErrorsHaveReadableMessages() {
        XCTAssertEqual(AccountDetailsError.invalidSortCode.errorDescription, "Sort code must be 6 digits.")
        XCTAssertEqual(AccountDetailsError.invalidAccountNumber.errorDescription, "Account number must be 6 to 8 digits.")
        XCTAssertEqual(AccountDetailsError.invalidIBAN.errorDescription, "IBAN must be 15–34 letters and digits, starting with a country code and 2 check digits.")
    }

    func testNormalizedDetailsReportsFirstError() throws {
        let ok = try AccountDetails(alias: " Joint ", sortCode: "30-00-00", accountNumber: "12345678", iban: "").normalized()
        XCTAssertEqual(ok, AccountDetails(alias: "Joint", sortCode: "300000", accountNumber: "12345678", iban: nil))
        XCTAssertThrowsError(try AccountDetails(sortCode: "1").normalized()) { XCTAssertEqual($0 as? AccountDetailsError, .invalidSortCode) }
    }

    // MARK: Migration and editing

    func testMigrationAddsNullableDetailColumns() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate(upTo: "addCategoryIsExternalTransfer")
        try manager.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO account (name, currency, kind, trackingMode) VALUES ('Old', 'gbp', 'cash', 'manual')")
        }
        try manager.migrate()
        let columns = try manager.dbQueue.read { db in try db.columns(in: "account").map(\.name) }
        for column in ["alias", "sortCode", "accountNumber", "iban"] { XCTAssertTrue(columns.contains(column), column) }
        let old = try manager.dbQueue.read { db in try Account.fetchOne(db) }
        XCTAssertEqual(old?.name, "Old")
        XCTAssertNil(old?.alias)
        XCTAssertNil(old?.iban)
    }

    func testAddAndUpdateSaveNormalisedDetails() throws {
        let m = try makeDB()
        try m.dbQueue.write { db in
            let a = try AccountEditing.add(db: db, name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported, openingBalanceEntered: nil, asOf: Date(),
                                           details: AccountDetails(alias: " Lloyds ", sortCode: "30-00-00", accountNumber: "12345678", iban: nil))
            var fetched = try Account.fetchOne(db, key: a.id!)!
            XCTAssertEqual(fetched.alias, "Lloyds")
            XCTAssertEqual(fetched.sortCode, "300000")
            XCTAssertEqual(fetched.accountNumber, "12345678")
            XCTAssertEqual(fetched.displayName, "Lloyds")

            try AccountEditing.update(db: db, accountId: a.id!, name: "Lloyds Classic", kind: .cash, trackingMode: .imported,
                                      details: AccountDetails(alias: "", sortCode: nil, accountNumber: nil, iban: "gb29 nwbk 6016 1331 9268 19"))
            fetched = try Account.fetchOne(db, key: a.id!)!
            XCTAssertNil(fetched.alias)
            XCTAssertNil(fetched.sortCode)
            XCTAssertEqual(fetched.iban, "GB29NWBK60161331926819")

            // Omitting details leaves them unchanged.
            try AccountEditing.update(db: db, accountId: a.id!, name: "Lloyds", kind: .cash, trackingMode: .imported)
            XCTAssertEqual(try Account.fetchOne(db, key: a.id!)!.iban, "GB29NWBK60161331926819")

            XCTAssertThrowsError(try AccountEditing.update(db: db, accountId: a.id!, name: "Lloyds", kind: .cash, trackingMode: .imported, details: AccountDetails(accountNumber: "12"))) {
                XCTAssertEqual($0 as? AccountDetailsError, .invalidAccountNumber)
            }
            XCTAssertThrowsError(try AccountEditing.add(db: db, name: "X", currency: .gbp, kind: .cash, trackingMode: .manual, openingBalanceEntered: nil, asOf: Date(), details: AccountDetails(iban: "XX"))) {
                XCTAssertEqual($0 as? AccountDetailsError, .invalidIBAN)
            }
            XCTAssertNil(try Account.filter(Column("name") == "X").fetchOne(db))
        }
    }

    func testBalanceUpdateOutcomeUsesDisplayName() throws {
        let m = try makeDB()
        let outcomes = try m.dbQueue.write { db -> [BalanceUpdates.Outcome] in
            let a = try AccountEditing.add(db: db, name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported, openingBalanceEntered: nil, asOf: Date(), details: AccountDetails(alias: "Lloyds"))
            var batch = ImportBatch(accountId: a.id!, sourceFileName: "f", importedAt: Date())
            try batch.insert(db)
            var t = Transaction(importBatchId: batch.id!, accountId: a.id!, date: Date(timeIntervalSince1970: 0), rawDescription: "x", amountMinorUnits: -100, categoryId: nil, status: .confirmed, categorizedBy: .none, fingerprint: "fp")
            try t.insert(db)
            return try BalanceUpdates.save(db: db, entries: [.init(accountId: a.id!, enteredMinorUnits: 500)], asOf: Date())
        }
        XCTAssertEqual(outcomes.map(\.accountName), ["Lloyds"])
    }
}
