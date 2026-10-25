import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Spec 2026-10-15 §5 (CSV sort code / account number columns) and §4 (reset mapping).
final class StatementAccountCheckTests: XCTestCase {
    private let lloydsHeader = "Transaction Date,Transaction Type,Sort Code,Account Number,Transaction Description,Debit Amount,Credit Amount,Balance"

    private func lloydsProfile(accountId: Int64 = 1, withAccountRoles: Bool = false) -> ImportProfile {
        ImportProfile(accountId: accountId, format: .csv, csvDelimiter: ",", csvDateColumnIndex: 0, csvDescriptionColumnIndex: 4,
                      csvAmountColumnIndex: 5, csvCreditAmountColumnIndex: 6, csvBalanceColumnIndex: 7,
                      csvSortCodeColumnIndex: withAccountRoles ? 2 : nil, csvAccountNumberColumnIndex: withAccountRoles ? 3 : nil,
                      csvDateFormat: "dd/MM/yyyy")
    }

    private func lloydsCSV(_ rows: [(String, String)]) -> String {
        ([lloydsHeader] + rows.map { "01/10/2026,DEB,\($0.0),\($0.1),SHOP,1.00,,99.00" }).joined(separator: "\n")
    }

    private func account(sortCode: String? = nil, accountNumber: String? = nil) -> Account {
        var account = Account(name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        account.sortCode = sortCode
        account.accountNumber = accountNumber
        return account
    }

    // MARK: - Suggester and mapping

    func testSuggesterFindsSortCodeAndAccountNumberHeaders() {
        let s = CSVColumnSuggester.suggest(header: lloydsHeader.components(separatedBy: ","))
        XCTAssertEqual(s.sortCodeColumn, 2)
        XCTAssertEqual(s.accountNumberColumn, 3)
        XCTAssertEqual(s.descriptionColumn, 4)
    }

    func testSuggesterHeaderVariants() {
        XCTAssertEqual(CSVColumnSuggester.suggest(header: ["Date", "Sortcode", "Account No", "Amount"]).sortCodeColumn, 1)
        XCTAssertEqual(CSVColumnSuggester.suggest(header: ["Date", "sort code", "Account No.", "Amount"]).accountNumberColumn, 2)
        XCTAssertEqual(CSVColumnSuggester.suggest(header: ["Date", "Account", "Amount"]).accountNumberColumn, 1)
        let named = CSVColumnSuggester.suggest(header: ["Date", "Account Name", "Amount"])
        XCTAssertNil(named.accountNumberColumn)
        XCTAssertNil(named.sortCodeColumn)
    }

    func testMappingRoundTripsAccountRoles() throws {
        let suggestion = CSVColumnSuggester.suggest(header: lloydsHeader.components(separatedBy: ","))
        let mapping = CSVColumnMapping(columnCount: 8, suggestion: suggestion)
        XCTAssertEqual(mapping.roles, [.date, .ignore, .sortCode, .accountNumber, .description, .moneyOut, .moneyIn, .balance])
        let profile = try XCTUnwrap(mapping.profile(accountId: 1, dateFormat: "dd/MM/yyyy", negateAmounts: false, allowBalance: true))
        XCTAssertEqual(profile.csvSortCodeColumnIndex, 2)
        XCTAssertEqual(profile.csvAccountNumberColumnIndex, 3)
        XCTAssertEqual(CSVColumnMapping(columnCount: 8, profile: profile).roles, mapping.roles)
    }

    // MARK: - Migration and profile store

    func testMigrationAddsAccountColumnIndicesToExistingProfiles() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate(upTo: "addAccountBankRegion")
        try manager.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO account (name, currency, kind, trackingMode) VALUES ('A', 'gbp', 'cash', 'imported')")
            try db.execute(sql: "INSERT INTO importProfile (accountId, format) VALUES (?, 'csv')", arguments: [db.lastInsertedRowID])
        }
        try manager.migrate()
        let profile = try manager.dbQueue.read { try ImportProfile.fetchOne($0)! }
        XCTAssertNil(profile.csvSortCodeColumnIndex)
        XCTAssertNil(profile.csvAccountNumberColumnIndex)
    }

    func testProfileStoreDeleteRemovesOnlyThatFormat() throws {
        let manager = try TestDatabase.migratedManager()
        var a = account()
        try manager.dbQueue.write { db in try a.insert(db) }
        let store = ImportProfileStore(dbQueue: manager.dbQueue)
        try store.save(lloydsProfile(accountId: a.id!, withAccountRoles: true))
        try store.save(ImportProfile(accountId: a.id!, format: .pdf, pdfLayoutConfig: "{}"))
        XCTAssertEqual(try store.find(accountId: a.id!, format: .csv)?.csvSortCodeColumnIndex, 2)

        XCTAssertTrue(try store.delete(accountId: a.id!, format: .csv))
        XCTAssertNil(try store.find(accountId: a.id!, format: .csv))
        XCTAssertNotNil(try store.find(accountId: a.id!, format: .pdf))
        XCTAssertFalse(try store.delete(accountId: a.id!, format: .csv))
    }

    // MARK: - Normalisation and file values

    func testNormalisationStripsQuotesApostrophesSpacesAndDashes() {
        XCTAssertEqual(StatementAccountCheck.normalizedSortCode("'30-94-57"), "309457")
        XCTAssertEqual(StatementAccountCheck.normalizedSortCode(" 30 94 57 "), "309457")
        XCTAssertEqual(StatementAccountCheck.normalizedSortCode("\u{2019}309457"), "309457")
        XCTAssertNil(StatementAccountCheck.normalizedSortCode("30-94"))
        XCTAssertNil(StatementAccountCheck.normalizedSortCode(""))
        XCTAssertEqual(StatementAccountCheck.normalizedAccountNumber("'12345678"), "12345678")
        XCTAssertEqual(StatementAccountCheck.normalizedAccountNumber("1234 5678"), "12345678")
        XCTAssertNil(StatementAccountCheck.normalizedAccountNumber("ABC123"))
        XCTAssertNil(StatementAccountCheck.normalizedAccountNumber(" "))
    }

    func testFileValuesFromLloydsApostropheRowsByHeaderWhenProfileLacksRoles() {
        let csv = lloydsCSV([("'30-94-57", "12345678"), ("\"'30-94-57\"", "12345678"), ("", "")])
        let values = StatementAccountCheck.fileValues(csvText: csv, profile: lloydsProfile())
        XCTAssertEqual(values, StatementAccountValues(sortCodes: ["309457"], accountNumbers: ["12345678"]))
    }

    func testFileValuesUseProfileColumns() {
        // Headers that wouldn't be detected: the saved roles are used.
        let csv = "D,T,X,Y,Desc,Out,In,Bal\n01/10/2026,DEB,'11-22-33,87654321,SHOP,1.00,,9.00"
        let values = StatementAccountCheck.fileValues(csvText: csv, profile: lloydsProfile(withAccountRoles: true))
        XCTAssertEqual(values, StatementAccountValues(sortCodes: ["112233"], accountNumbers: ["87654321"]))
        XCTAssertEqual(StatementAccountCheck.fileValues(csvText: csv, profile: lloydsProfile()), StatementAccountValues())
    }

    // MARK: - Evaluate

    func testMatch() {
        let file = StatementAccountValues(sortCodes: ["309457"], accountNumbers: ["12345678"])
        XCTAssertEqual(StatementAccountCheck.evaluate(file: file, account: account(sortCode: "309457", accountNumber: "12345678")), .ok(fill: nil))
    }

    func testMismatch() {
        let file = StatementAccountValues(sortCodes: ["309457"], accountNumbers: ["12345678"])
        let result = StatementAccountCheck.evaluate(file: file, account: account(sortCode: "300000", accountNumber: "87654321"))
        XCTAssertEqual(result, .mismatch(file: file, account: StatementAccountFill(sortCode: "300000", accountNumber: "87654321")))
        XCTAssertEqual(StatementAccountCheck.mismatchMessage(file: file, account: StatementAccountFill(sortCode: "300000", accountNumber: "87654321"), accountName: "Lloyds"),
                       "This file is for sort code 30-94-57, account 12345678 — Lloyds is 30-00-00, 87654321.")
    }

    func testMultipleAccountsInFileBlockWhenAccountHasDetails() {
        let file = StatementAccountValues(sortCodes: ["309457"], accountNumbers: ["12345678", "11111111"])
        let result = StatementAccountCheck.evaluate(file: file, account: account(sortCode: "309457", accountNumber: "12345678"))
        XCTAssertEqual(result, .mismatch(file: file, account: StatementAccountFill(sortCode: "309457", accountNumber: "12345678")))
        XCTAssertEqual(StatementAccountCheck.mismatchMessage(file: file, account: StatementAccountFill(sortCode: "309457", accountNumber: "12345678"), accountName: "Lloyds"),
                       "This file is for sort code 30-94-57, accounts 12345678 and 11111111 — Lloyds is 30-94-57, 12345678.")
        // An empty account isn't blocked, and nothing is filled from an ambiguous file.
        XCTAssertEqual(StatementAccountCheck.evaluate(file: file, account: account()), .ok(fill: nil))
    }

    func testPartialComparesOnlyWhatBothHave() {
        // The account has only an account number; the file only a sort code: nothing to compare, fill the sort code.
        let sortOnly = StatementAccountValues(sortCodes: ["309457"], accountNumbers: [])
        XCTAssertEqual(StatementAccountCheck.evaluate(file: sortOnly, account: account(accountNumber: "12345678")),
                       .ok(fill: StatementAccountFill(sortCode: "309457", accountNumber: nil)))
        // The account has only a sort code that matches: the account number is filled.
        let both = StatementAccountValues(sortCodes: ["309457"], accountNumbers: ["12345678"])
        XCTAssertEqual(StatementAccountCheck.evaluate(file: both, account: account(sortCode: "309457")),
                       .ok(fill: StatementAccountFill(sortCode: nil, accountNumber: "12345678")))
        // ...or differs: blocked.
        if case .mismatch = StatementAccountCheck.evaluate(file: both, account: account(sortCode: "300000")) {} else { XCTFail("expected mismatch") }
        XCTAssertEqual(StatementAccountCheck.mismatchMessage(file: sortOnly, account: StatementAccountFill(sortCode: "300000", accountNumber: nil), accountName: "Lloyds"),
                       "This file is for sort code 30-94-57 — Lloyds is 30-00-00.")
    }

    func testEmptyAccountGetsAFillPlan() {
        let file = StatementAccountValues(sortCodes: ["309457"], accountNumbers: ["12345678"])
        XCTAssertEqual(StatementAccountCheck.evaluate(file: file, account: account()),
                       .ok(fill: StatementAccountFill(sortCode: "309457", accountNumber: "12345678")))
        // An account number the UK rule wouldn't accept isn't filled.
        let long = StatementAccountValues(sortCodes: ["309457"], accountNumbers: ["1234567890"])
        XCTAssertEqual(StatementAccountCheck.evaluate(file: long, account: account()),
                       .ok(fill: StatementAccountFill(sortCode: "309457", accountNumber: nil)))
        XCTAssertEqual(StatementAccountCheck.evaluate(file: StatementAccountValues(), account: account()), .ok(fill: nil))
    }

    func testFinishWithNothingToSaveStillFillsAndReportsIt() throws {
        let manager = try TestDatabase.migratedManager()
        var a = account()
        try manager.dbQueue.write { db in try a.insert(db) }
        let coordinator = ImportCoordinator(dbQueue: manager.dbQueue, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        let fill = StatementAccountFill(sortCode: "309457", accountNumber: "12345678")
        XCTAssertEqual(try coordinator.finish(accountId: a.id!, sourceFileName: "f.csv", staged: [], decisions: [], statement: nil, accountFill: fill).filled, fill)
        XCTAssertNil(try coordinator.finish(accountId: a.id!, sourceFileName: "f.csv", staged: [], decisions: [], statement: nil, accountFill: fill).filled)
        XCTAssertEqual(try manager.dbQueue.read { db in try ImportBatch.fetchCount(db) }, 0)
    }

    func testNonUKStoredRegionIsNeitherCheckedNorFilled() {
        let file = StatementAccountValues(sortCodes: ["309457"], accountNumbers: ["12345678"])
        for region in [BankRegion.us, .europe, .other] {
            var other = account(accountNumber: "87654321")
            other.bankRegion = region
            XCTAssertEqual(StatementAccountCheck.evaluate(file: file, account: other), .ok(fill: nil), "\(region)")
            var empty = account()
            empty.bankRegion = region
            XCTAssertEqual(StatementAccountCheck.evaluate(file: file, account: empty), .ok(fill: nil), "\(region)")
        }
        var uk = account()
        uk.bankRegion = .uk
        XCTAssertEqual(StatementAccountCheck.evaluate(file: file, account: uk), .ok(fill: StatementAccountFill(sortCode: "309457", accountNumber: "12345678")))
    }

    func testSavedMessage() {
        XCTAssertEqual(StatementAccountCheck.savedMessage(StatementAccountFill(sortCode: "1", accountNumber: "2"), accountName: "Lloyds"),
                       "Saved sort code and account number to Lloyds.")
        XCTAssertEqual(StatementAccountCheck.savedMessage(StatementAccountFill(sortCode: "1", accountNumber: nil), accountName: "Lloyds"),
                       "Saved sort code to Lloyds.")
        XCTAssertEqual(StatementAccountCheck.savedMessage(StatementAccountFill(sortCode: nil, accountNumber: "2"), accountName: "Lloyds"),
                       "Saved account number to Lloyds.")
    }

    // MARK: - Commit fill

    func testCommitFillsOnlyEmptyFieldsAndSetsUKRegion() async throws {
        let manager = try TestDatabase.migratedManager()
        var a = account(sortCode: nil, accountNumber: "87654321")
        a.alias = "Lloyds"
        a.bankName = "Lloyds Bank"
        a.bic = "LOYDGB2L"
        try await manager.dbQueue.write { db in try a.insert(db) }
        let coordinator = ImportCoordinator(dbQueue: manager.dbQueue, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        let csv = lloydsCSV([("'30-94-57", "12345678")])
        let staged = try await coordinator.stageCSVImport(csvText: csv, profile: lloydsProfile(accountId: a.id!), accountId: a.id!)
        let result = try coordinator.finish(accountId: a.id!, sourceFileName: "f.csv", staged: staged.staged, decisions: [], statement: nil,
                                            accountFill: StatementAccountFill(sortCode: "309457", accountNumber: "12345678"))
        XCTAssertEqual(result.filled, StatementAccountFill(sortCode: "309457", accountNumber: nil), "reports what was written, not the plan")
        let accountId = a.id!
        let transactionCount = try await manager.dbQueue.read { db in try Transaction.fetchCount(db) }
        XCTAssertEqual(transactionCount, 1)
        let saved = try await manager.dbQueue.read { db in try Account.fetchOne(db, key: accountId)! }
        XCTAssertEqual(saved.sortCode, "309457")
        XCTAssertEqual(saved.accountNumber, "87654321", "a stored account number is never overwritten")
        XCTAssertEqual(saved.bankRegion, .uk)
        XCTAssertEqual(saved.alias, "Lloyds")
        XCTAssertEqual(saved.bankName, "Lloyds Bank")
        XCTAssertEqual(saved.bic, "LOYDGB2L")
    }

    func testFillKeepsAStoredRegion() throws {
        let manager = try TestDatabase.migratedManager()
        var a = account()
        a.bankRegion = .other
        try manager.dbQueue.write { db in try a.insert(db) }
        let filled = try manager.dbQueue.write { db in
            try StatementAccountCheck.fill(db: db, accountId: a.id!, with: StatementAccountFill(sortCode: "309457", accountNumber: "12345678"))
        }
        XCTAssertEqual(filled, StatementAccountFill(sortCode: "309457", accountNumber: "12345678"))
        let saved = try manager.dbQueue.read { db in try Account.fetchOne(db, key: a.id!)! }
        XCTAssertEqual(saved.bankRegion, .other)
        XCTAssertEqual(saved.accountNumber, "12345678")
        // Nothing left to fill.
        XCTAssertNil(try manager.dbQueue.write { db in
            try StatementAccountCheck.fill(db: db, accountId: a.id!, with: StatementAccountFill(sortCode: "111111", accountNumber: "22222222"))
        })
    }
}
