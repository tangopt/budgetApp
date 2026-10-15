import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

/// Transfer categories per account (spec 2026-10-14 §4), on the user's own chart of accounts.
final class TransferCategoriesTests: XCTestCase {
    struct Fixture {
        let manager: DatabaseManager
        let current: Int64, international: Int64, isaSavings: Int64, joint: Int64, isaInvestment: Int64, euro: Int64, revolut: Int64
        let bankBatch: [Int64: Int64]
        let historyBatch: Int64
        let external: Int64, groceries: Int64, investments: Int64

        func categoryId(forAccount accountId: Int64) throws -> Int64? {
            try manager.dbQueue.read { db in try TransferCategories.category(db: db, forAccountId: accountId)?.id }
        }

        func transaction(_ id: Int64) throws -> Transaction {
            try manager.dbQueue.read { db in try Transaction.fetchOne(db, key: id)! }
        }

        func categoryName(_ id: Int64?) throws -> String? {
            guard let id else { return nil }
            return try manager.dbQueue.read { db in try Category.fetchOne(db, key: id)?.name }
        }

        @discardableResult
        func add(_ account: Int64, _ date: Date, _ amount: Int, category: Int64? = nil, historical: Bool = false) throws -> Int64 {
            try manager.dbQueue.write { db in
                var t = Transaction(importBatchId: historical ? historyBatch : bankBatch[account]!, accountId: account, date: date,
                                    rawDescription: "P DIMENZA", amountMinorUnits: amount, categoryId: category,
                                    status: category == nil ? .pendingReview : .confirmed, categorizedBy: category == nil ? .none : .manual,
                                    fingerprint: UUID().uuidString)
                try t.insert(db)
                return t.id!
            }
        }

        func ensure() throws {
            try manager.dbQueue.write { db in _ = try TransferCategories.ensure(db: db) }
        }
    }

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { TransferFixture.date(y, m, d) }

    static let accounts: [(name: String, alias: String?, currency: Currency, kind: AccountKind)] = [
        ("Lloyds Classic", "Current", .gbp, .cash),
        ("Lloyds International Premier GBP", "International", .gbp, .cash),
        ("Lloyds Advantage ISA Saver", "ISA Savings", .gbp, .cash),
        ("Lloyds Club Joint", "Joint", .gbp, .cash),
        ("Lloyds Investment ISA", "ISA Investment", .gbp, .investment),
        ("Lloyds International Account (EUR)", "International Euro", .eur, .cash),
        ("Revolut", nil, .gbp, .cash)
    ]

    /// The user's accounts and a few non-account categories; no transfer category tied yet
    /// unless `ensure`.
    func makeFixture(ensure: Bool = true) throws -> Fixture {
        let m = try DatabaseManager(path: nil)
        try m.migrate()
        let f: Fixture = try m.dbQueue.write { db in
            var ids: [Int64] = []
            var batches: [Int64: Int64] = [:]
            for spec in Self.accounts {
                var account = Account(name: spec.name, currency: spec.currency, kind: spec.kind, trackingMode: .imported, alias: spec.alias)
                try account.insert(db)
                ids.append(account.id!)
                var batch = ImportBatch(accountId: account.id!, sourceFileName: "\(spec.name).csv", importedAt: Date())
                try batch.insert(db)
                batches[account.id!] = batch.id!
            }
            var history = ImportBatch(accountId: ids[0], sourceFileName: "Budget.numbers", importedAt: Date())
            try history.insert(db)
            var external = Category(name: "Transfer: Santander Patricia", type: .transfer, isExternalTransfer: true)
            var groceries = Category(name: "Groceries", type: .expense)
            var investments = Category(name: "Investments (Stocks + Crypto)", type: .transfer)
            try external.insert(db); try groceries.insert(db); try investments.insert(db)
            _ = try ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date()).inserted(db)
            return Fixture(manager: m, current: ids[0], international: ids[1], isaSavings: ids[2], joint: ids[3], isaInvestment: ids[4],
                           euro: ids[5], revolut: ids[6], bankBatch: batches, historyBatch: history.id!,
                           external: external.id!, groceries: groceries.id!, investments: investments.id!)
        }
        if ensure { try f.ensure() }
        return f
    }

    // MARK: Migration

    /// The database just before this task's migration, with the user's accounts.
    private func preMigrationDatabase(categories: [(String, String, Bool)]) throws -> DatabaseManager {
        let m = try DatabaseManager(path: nil)
        try m.migrate(upTo: "addAccountBalanceConfirmedAt")
        try m.dbQueue.write { db in
            for spec in Self.accounts {
                try db.execute(sql: "INSERT INTO account (name, currency, kind, trackingMode, alias) VALUES (?, ?, ?, 'imported', ?)",
                               arguments: [spec.name, spec.currency.rawValue, spec.kind.rawValue, spec.alias])
            }
            for (name, type, external) in categories {
                try db.execute(sql: "INSERT INTO category (name, type, isExternalTransfer) VALUES (?, ?, ?)", arguments: [name, type, external])
            }
        }
        try m.migrate()
        return m
    }

    private func ties(_ m: DatabaseManager) throws -> [String: String] {
        try m.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT c.name AS category, a.name AS account FROM category c JOIN account a ON a.id = c.transferAccountId")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["category"] as String, $0["account"] as String) })
        }
    }

    func testMigrationTiesExistingTransferCategoriesByExactNameOrAlias() throws {
        let m = try preMigrationDatabase(categories: [
            ("Transfer: Revolut", "transfer", false),                 // name
            ("Transfer: Lloyds Investment ISA", "transfer", false),   // name
            ("Transfer: ISA Savings", "transfer", false),             // alias
            ("Transfer: Lloyds Joint", "transfer", false),            // neither: stays untied
            ("Transfer: Lloyds International EUR", "transfer", false),
            ("Transfer: BBVA Portugal", "transfer", false),
            ("Investments (Stocks + Crypto)", "transfer", false)
        ])
        XCTAssertEqual(try ties(m), [
            "Transfer: Revolut": "Revolut",
            "Transfer: Lloyds Investment ISA": "Lloyds Investment ISA",
            "Transfer: ISA Savings": "Lloyds Advantage ISA Saver"
        ])
        // The migration never creates categories.
        XCTAssertEqual(try m.dbQueue.read { db in try Category.filter(Column("type") == "transfer").fetchCount(db) }, 7)
    }

    func testMigrationTiesOneCategoryPerAccountNameFirst() throws {
        let m = try preMigrationDatabase(categories: [
            ("Transfer: Joint", "transfer", false),
            ("Transfer: Lloyds Club Joint", "transfer", false)
        ])
        XCTAssertEqual(try ties(m), ["Transfer: Lloyds Club Joint": "Lloyds Club Joint"])
    }

    func testMigrationNeverTiesExternalOrNonTransferCategories() throws {
        let m = try preMigrationDatabase(categories: [
            ("Transfer: Revolut", "transfer", true),
            ("Transfer: Current", "expense", false),
            ("Transfer: Joint", "income", false)
        ])
        XCTAssertEqual(try ties(m), [:])
        // Built-in categories (type adjustment) are never transfer categories either.
        XCTAssertEqual(try m.dbQueue.read { db in try Category.filter(Column("builtInRole") != nil && Column("transferAccountId") != nil).fetchCount(db) }, 0)
    }

    func testTransferAccountIdIsUniqueAndClearedWhenTheAccountIsDeleted() throws {
        let f = try makeFixture(ensure: false)
        try f.manager.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO category (name, type, transferAccountId) VALUES ('A', 'transfer', ?)", arguments: [f.revolut])
            XCTAssertThrowsError(try db.execute(sql: "INSERT INTO category (name, type, transferAccountId) VALUES ('B', 'transfer', ?)", arguments: [f.revolut]))
            try db.execute(sql: "DELETE FROM importBatch WHERE accountId = ?", arguments: [f.revolut])
            try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [f.revolut])
            XCTAssertNil(try Category.filter(Column("name") == "A").fetchOne(db)?.transferAccountId)
        }
    }

    // MARK: Ensure

    func testEnsureCreatesATransferCategoryPerAccountNamedByDisplayName() throws {
        let f = try makeFixture()
        let names = try f.manager.dbQueue.read { db in
            try Category.filter(Column("transferAccountId") != nil).fetchAll(db).map(\.name).sorted()
        }
        XCTAssertEqual(names, ["Transfer: Current", "Transfer: International", "Transfer: International Euro", "Transfer: ISA Investment",
                               "Transfer: ISA Savings", "Transfer: Joint", "Transfer: Revolut"].sorted())
        let joint = try f.manager.dbQueue.read { db in try TransferCategories.category(db: db, forAccountId: f.joint)! }
        XCTAssertEqual(joint.name, "Transfer: Joint")
        XCTAssertEqual(joint.type, .transfer)
        XCTAssertFalse(joint.isExternalTransfer)
        XCTAssertEqual(joint.transferAccountId, f.joint)
    }

    func testEnsurePutsANewAccountsCategoryInTheGroupMostTiedCategoriesUse() throws {
        let f = try makeFixture()
        let groupId = try f.manager.dbQueue.write { db -> Int64 in
            var group = CategoryGroup(name: "Own accounts")
            try group.insert(db)
            try db.execute(sql: "UPDATE category SET groupId = ? WHERE transferAccountId IS NOT NULL", arguments: [group.id!])
            var account = Account(name: "Monzo", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            return group.id!
        }
        try f.ensure()
        let monzo = try f.manager.dbQueue.read { db in try Category.filter(Column("name") == "Transfer: Monzo").fetchOne(db) }
        XCTAssertEqual(monzo?.groupId, groupId)
    }

    func testEnsureTiesAnExistingUntiedCategoryOfTheSameName() throws {
        let f = try makeFixture(ensure: false)
        let existing = try f.manager.dbQueue.write { db in
            var category = Category(name: "Transfer: Joint", type: .transfer)
            try category.insert(db)
            return category.id!
        }
        try f.ensure()
        XCTAssertEqual(try f.categoryId(forAccount: f.joint), existing)
        XCTAssertEqual(try f.manager.dbQueue.read { db in try Category.filter(Column("name").like("Transfer: Joint%")).fetchCount(db) }, 1)
    }

    func testEnsureSuffixesTheAccountNameWhenTheNameIsTakenByAnotherKindOfCategory() throws {
        let f = try makeFixture(ensure: false)
        try f.manager.dbQueue.write { db in
            var expense = Category(name: "Transfer: Revolut", type: .expense)
            var external = Category(name: "Transfer: Joint", type: .transfer, isExternalTransfer: true)
            try expense.insert(db); try external.insert(db)
        }
        try f.ensure()
        XCTAssertEqual(try f.categoryName(try f.categoryId(forAccount: f.revolut)), "Transfer: Revolut (Revolut)")
        XCTAssertEqual(try f.categoryName(try f.categoryId(forAccount: f.joint)), "Transfer: Joint (Lloyds Club Joint)")
    }

    func testEnsureRenamesTiedCategoriesWhenTheNameIsFree() throws {
        let f = try makeFixture(ensure: false)
        try f.manager.dbQueue.write { db in
            // Tied by hand, as the controller does for names the migration can't match.
            var lloydsJoint = Category(name: "Transfer: Lloyds Joint", type: .transfer)
            try lloydsJoint.insert(db)
            try TransferCategories.setLinkedAccount(db: db, categoryId: lloydsJoint.id!, accountId: f.joint)
        }
        try f.ensure()
        let joint = try XCTUnwrap(try f.categoryId(forAccount: f.joint))
        XCTAssertEqual(try f.categoryName(joint), "Transfer: Joint")
        // An alias change renames it.
        try f.manager.dbQueue.write { db in
            try AccountEditing.update(db: db, accountId: f.joint, name: "Lloyds Club Joint", kind: .cash, details: AccountDetails(alias: "Household"))
        }
        XCTAssertEqual(try f.categoryName(joint), "Transfer: Household")
        // A taken name leaves it as it is.
        try f.manager.dbQueue.write { db in
            _ = try Categories.create(db: db, name: "Transfer: Home", type: .expense, groupId: nil)
            try AccountEditing.update(db: db, accountId: f.joint, name: "Lloyds Club Joint", kind: .cash, details: AccountDetails(alias: "Home"))
        }
        XCTAssertEqual(try f.categoryName(joint), "Transfer: Household")
        XCTAssertEqual(try f.categoryId(forAccount: f.joint), joint)
    }

    func testEnsureIsIdempotent() throws {
        let f = try makeFixture()
        let before = try f.manager.dbQueue.read { db in try Category.order(Column("id")).fetchAll(db) }
        try f.ensure()
        try f.ensure()
        XCTAssertEqual(try f.manager.dbQueue.read { db in try Category.order(Column("id")).fetchAll(db) }, before)
    }

    func testAddingAnAccountCreatesItsTransferCategory() throws {
        let f = try makeFixture()
        let account = try f.manager.dbQueue.write { db in
            try AccountEditing.add(db: db, name: "Monzo", currency: .gbp, kind: .cash, openingBalanceEntered: nil, asOf: Self.day(2026, 1, 1))
        }
        XCTAssertEqual(try f.categoryName(try f.categoryId(forAccount: account.id!)), "Transfer: Monzo")
    }

    // MARK: Linked account (Categories screen)

    func testSetLinkedAccountTiesRenamesAndRefusesTakenAccountsOrExternalCategories() throws {
        let f = try makeFixture(ensure: false)
        try f.manager.dbQueue.write { db in
            var eur = Category(name: "Transfer: Lloyds International EUR", type: .transfer)
            try eur.insert(db)
            try TransferCategories.setLinkedAccount(db: db, categoryId: eur.id!, accountId: f.euro)
            XCTAssertEqual(try Category.fetchOne(db, key: eur.id!)?.name, "Transfer: International Euro")
            XCTAssertEqual(try TransferCategories.category(db: db, forAccountId: f.euro)?.id, eur.id)

            var other = Category(name: "Transfer: Other", type: .transfer)
            try other.insert(db)
            XCTAssertThrowsError(try TransferCategories.setLinkedAccount(db: db, categoryId: other.id!, accountId: f.euro)) {
                XCTAssertEqual($0 as? TransferCategoryError, .accountAlreadyLinked(categoryName: "Transfer: International Euro"))
            }
            XCTAssertThrowsError(try TransferCategories.setLinkedAccount(db: db, categoryId: f.external, accountId: f.revolut)) {
                XCTAssertEqual($0 as? TransferCategoryError, .externalCategory)
            }
            XCTAssertThrowsError(try TransferCategories.setLinkedAccount(db: db, categoryId: f.groceries, accountId: f.revolut)) {
                XCTAssertEqual($0 as? TransferCategoryError, .notATransferCategory)
            }
            // A linked category can't become external.
            XCTAssertThrowsError(try TransferLinks.setExternalTransfer(db: db, categoryId: eur.id!, true)) {
                XCTAssertEqual($0 as? TransferCategoryError, .linkedCategory)
            }
            // None unties it (its name stays).
            try TransferCategories.setLinkedAccount(db: db, categoryId: eur.id!, accountId: nil)
            XCTAssertNil(try TransferCategories.category(db: db, forAccountId: f.euro))
            XCTAssertEqual(try Category.fetchOne(db, key: eur.id!)?.name, "Transfer: International Euro")
        }
    }

    // MARK: Apply on link

    private func assertLeg(_ f: Fixture, _ id: Int64, account: Int64, file: StaticString = #filePath, line: UInt = #line) throws {
        let t = try f.transaction(id)
        XCTAssertEqual(t.categoryId, try f.categoryId(forAccount: account), file: file, line: line)
        XCTAssertEqual(t.status, .confirmed, file: file, line: line)
        XCTAssertEqual(t.categorizedBy, .transfer, file: file, line: line)
    }

    func testAutoMatchFilesEachLegUnderTheOtherAccountsTransferCategory() throws {
        let f = try makeFixture()
        let out = try f.add(f.current, Self.day(2026, 3, 9), -36_000)
        let inLeg = try f.add(f.joint, Self.day(2026, 3, 9), 36_000, category: f.investments)
        try f.manager.dbQueue.write { db in _ = try TransferMatcher.match(db: db, today: Self.day(2026, 10, 12)) }
        try assertLeg(f, out, account: f.joint)
        try assertLeg(f, inLeg, account: f.current)
    }

    func testManualLinkFilesBothLegs() throws {
        let f = try makeFixture()
        let out = try f.add(f.current, Self.day(2026, 3, 9), -36_000, category: f.investments)
        let inLeg = try f.add(f.isaInvestment, Self.day(2026, 3, 14), 35_500)
        try f.manager.dbQueue.write { db in
            try TransactionEditing.save(db: db, id: out, changes: TransactionEditChanges(categoryId: f.investments, note: nil, transfer: .link(transactionId: inLeg)))
        }
        try assertLeg(f, out, account: f.isaInvestment)
        try assertLeg(f, inLeg, account: f.current)
    }

    func testAddTheOtherSideFilesTheNewAndOriginalLegs() throws {
        let f = try makeFixture()
        let out = try f.add(f.current, Self.day(2026, 3, 9), -36_000)
        let other = try f.manager.dbQueue.write { db in try ManualTransactions.addOtherSide(db: db, transactionId: out, accountId: f.isaSavings) }
        try assertLeg(f, out, account: f.isaSavings)
        try assertLeg(f, other.id!, account: f.current)

        // Money received: the new leg is the one sent.
        let received = try f.add(f.revolut, Self.day(2026, 4, 2), 2_000, category: f.investments)
        let sent = try f.manager.dbQueue.write { db in try ManualTransactions.addOtherSide(db: db, transactionId: received, accountId: f.joint) }
        try assertLeg(f, received, account: f.joint)
        try assertLeg(f, sent.id!, account: f.revolut)
    }

    func testHistoricalMultiLegLinkFilesEveryPair() throws {
        let f = try makeFixture()
        // No salaries: pay months are calendar months.
        let out = try f.add(f.current, Self.day(2026, 1, 25), -50_000, category: f.investments, historical: true)
        let a = try f.add(f.international, Self.day(2026, 1, 3), 30_000)
        let b = try f.add(f.international, Self.day(2026, 1, 10), 20_000)
        try f.manager.dbQueue.write { db in _ = try TransferMatcher.match(db: db, today: Self.day(2026, 10, 12)) }
        XCTAssertEqual(try f.manager.dbQueue.read { db in try TransferLink.fetchCount(db) }, 2)
        try assertLeg(f, out, account: f.international)
        try assertLeg(f, a, account: f.current)
        try assertLeg(f, b, account: f.current)
    }

    func testExternalAndBuiltInLegsKeepTheirCategory() throws {
        let f = try makeFixture()
        let builtIn = try f.manager.dbQueue.read { db in try BuiltInCategories.category(db: db, role: .balanceAdjustment).id! }
        let out = try f.add(f.current, Self.day(2026, 3, 9), -36_000, category: f.external)
        let inLeg = try f.add(f.joint, Self.day(2026, 3, 9), 36_000)
        let out2 = try f.add(f.current, Self.day(2026, 5, 9), -1_000)
        let in2 = try f.add(f.revolut, Self.day(2026, 5, 9), 1_000, category: builtIn)
        try f.manager.dbQueue.write { db in
            try TransferLinks.link(db: db, transactionId: out, with: inLeg)
            // Link to transfer… refuses an adjustment; a link made otherwise still leaves it be.
            var link = TransferLink(outTransactionId: out2, inTransactionId: in2, origin: .manual)
            try link.insert(db)
            try TransferCategories.applyOnLink(db: db, outTransactionId: out2, inTransactionId: in2)
        }
        XCTAssertEqual(try f.transaction(out).categoryId, f.external)
        try assertLeg(f, inLeg, account: f.current)
        try assertLeg(f, out2, account: f.revolut)
        XCTAssertEqual(try f.transaction(in2).categoryId, builtIn)
    }

    func testIncomeAndExpenseLegsKeepTheirCategory() throws {
        let f = try makeFixture()
        let salary = try f.manager.dbQueue.write { db in try Categories.create(db: db, name: "Income", type: .income, groupId: nil).id! }
        // Money sent filed as Groceries, received as Income: both keep them.
        let out = try f.add(f.current, Self.day(2026, 3, 9), -36_000, category: f.groceries)
        let inLeg = try f.add(f.joint, Self.day(2026, 3, 9), 36_000, category: salary)
        // An uncategorised out leg with an income in leg: only the out leg moves.
        let out2 = try f.add(f.current, Self.day(2026, 5, 9), -1_000)
        let in2 = try f.add(f.revolut, Self.day(2026, 5, 9), 1_000, category: salary)
        try f.manager.dbQueue.write { db in
            try TransferLinks.link(db: db, transactionId: out, with: inLeg)
            try TransferLinks.link(db: db, transactionId: out2, with: in2)
        }
        XCTAssertEqual(try f.transaction(out).categoryId, f.groceries)
        XCTAssertEqual(try f.transaction(inLeg).categoryId, salary)
        try assertLeg(f, out2, account: f.revolut)
        XCTAssertEqual(try f.transaction(in2).categoryId, salary)
        // The one-off step leaves them too.
        let report = try f.manager.dbQueue.write { db in try TransferCategories.applyToExistingLinks(db: db) }
        XCTAssertTrue(report.changedTransactionIds.isEmpty)
        XCTAssertEqual(try f.transaction(out).categoryId, f.groceries)
        XCTAssertEqual(try f.transaction(in2).categoryId, salary)
    }

    func testLinkToTransferNeverOffersOrLinksAnAdjustment() throws {
        let f = try makeFixture()
        let builtIn = try f.manager.dbQueue.read { db in try BuiltInCategories.category(db: db, role: .marketMovement).id! }
        let out = try f.add(f.current, Self.day(2026, 3, 9), -36_000)
        let adjustment = try f.add(f.isaInvestment, Self.day(2026, 3, 9), 36_000, category: builtIn)
        let plain = try f.add(f.joint, Self.day(2026, 3, 10), 36_000)
        try f.manager.dbQueue.write { db in
            XCTAssertEqual(try TransferLinks.candidates(db: db, for: out, today: Self.day(2026, 10, 12)).map(\.transactionId), [plain])
            XCTAssertEqual(try TransferLinks.candidates(db: db, for: adjustment, today: Self.day(2026, 10, 12)), [])
            XCTAssertThrowsError(try TransferLinks.link(db: db, transactionId: out, with: adjustment)) {
                XCTAssertEqual($0 as? TransferLinkError, .adjustment)
                XCTAssertEqual(($0 as? LocalizedError)?.errorDescription, "A balance adjustment can't be part of a transfer.")
            }
            XCTAssertEqual(try TransferLink.fetchCount(db), 0)
        }
    }

    func testTieIsANoOpWhenRerunAfterTheCategoryWasRenamed() throws {
        let f = try makeFixture(ensure: false)
        try f.manager.dbQueue.write { db in _ = try Categories.create(db: db, name: "Transfer: Lloyds Joint", type: .transfer, groupId: nil) }
        let first = try f.manager.dbQueue.write { db in try TransferCategories.tie(db: db, categoryName: "Transfer: Lloyds Joint", accountNameOrAlias: "Joint") }
        XCTAssertEqual(first, ["Tied “Transfer: Lloyds Joint” to Lloyds Club Joint, renamed “Transfer: Joint”"])
        let before = try f.manager.dbQueue.read { db in try Category.order(Column("id")).fetchAll(db) }
        let again = try f.manager.dbQueue.write { db in try TransferCategories.tie(db: db, categoryName: "Transfer: Lloyds Joint", accountNameOrAlias: "Joint") }
        XCTAssertEqual(again, ["“Transfer: Lloyds Joint” not found; Lloyds Club Joint already tied to “Transfer: Joint”"])
        XCTAssertEqual(try f.manager.dbQueue.read { db in try Category.order(Column("id")).fetchAll(db) }, before)
    }

    func testUnlinkLeavesCategoriesAsTheyAre() throws {
        let f = try makeFixture()
        let out = try f.add(f.current, Self.day(2026, 3, 9), -36_000)
        let inLeg = try f.add(f.joint, Self.day(2026, 3, 9), 36_000)
        let link = try f.manager.dbQueue.write { db in try TransferLinks.link(db: db, transactionId: out, with: inLeg) }
        try f.manager.dbQueue.write { db in try TransferLinks.unlink(db: db, linkId: link.id!) }
        try assertLeg(f, out, account: f.joint)
        try assertLeg(f, inLeg, account: f.current)
    }

    func testWithoutTiedCategoriesLinkingLeavesCategoriesAlone() throws {
        let f = try makeFixture(ensure: false)
        let out = try f.add(f.current, Self.day(2026, 3, 9), -36_000, category: f.investments)
        let inLeg = try f.add(f.joint, Self.day(2026, 3, 9), 36_000)
        try f.manager.dbQueue.write { db in _ = try TransferLinks.link(db: db, transactionId: out, with: inLeg) }
        XCTAssertEqual(try f.transaction(out).categoryId, f.investments)
        XCTAssertNil(try f.transaction(inLeg).categoryId)
    }

    func testImportReviewSuggestsTheOtherLegsAccountsTransferCategory() async throws {
        let f = try makeFixture()
        // The saved leg is filed under a non-account transfer category.
        let out = try f.add(f.current, Self.day(2026, 3, 9), -36_000, category: f.investments)
        let profile = ImportProfile(accountId: f.joint, format: .csv, csvDelimiter: ",", csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2, csvDateFormat: "dd/MM/yyyy")
        let fake = FakeCategorizer()
        fake.stubbedSuggestion = nil
        let coordinator = ImportCoordinator(dbQueue: f.manager.dbQueue, categorizationService: CategorizationService(categorizer: fake))
        let staged = try await coordinator.stageCSVImport(csvText: "Date,Description,Amount\n09/03/2026,P DIMENZA,360.00", profile: profile, accountId: f.joint)
        let row = staged.staged[0]
        XCTAssertEqual(row.transfer?.otherTransactionId, out)
        XCTAssertEqual(row.source, .transfer)
        XCTAssertEqual(row.suggestedCategoryId, try f.categoryId(forAccount: f.current))
        try coordinator.commit(accountId: f.joint, sourceFileName: "joint.csv", staged: staged.staged,
                               decisions: staged.staged.map { ImportDecision(stagedId: $0.id, finalCategoryId: $0.suggestedCategoryId) })
        // Commit links them: the saved leg moves to the importing account's category.
        try assertLeg(f, out, account: f.joint)
    }

    // MARK: Existing links (one-off data step)

    func testApplyToExistingLinksReportsEachMoveAndIsIdempotent() throws {
        let f = try makeFixture()
        let ids = try f.manager.dbQueue.write { db -> [Int64] in
            var made: [Int64] = []
            for (outAccount, inAccount, outCategory, inCategory, amount) in [
                (f.current, f.joint, f.investments, nil, 1_000),
                (f.current, f.joint, f.investments, f.investments, 2_000),
                (f.current, f.isaInvestment, f.external, nil, 3_000)
            ] as [(Int64, Int64, Int64?, Int64?, Int)] {
                var out = Transaction(importBatchId: f.bankBatch[outAccount]!, accountId: outAccount, date: Self.day(2026, 2, 1), rawDescription: "TFR",
                                      amountMinorUnits: -amount, categoryId: outCategory, status: .confirmed, categorizedBy: .manual, fingerprint: UUID().uuidString)
                var inLeg = Transaction(importBatchId: f.bankBatch[inAccount]!, accountId: inAccount, date: Self.day(2026, 2, 1), rawDescription: "TFR",
                                        amountMinorUnits: amount, categoryId: inCategory, status: inCategory == nil ? .pendingReview : .confirmed,
                                        categorizedBy: inCategory == nil ? .none : .manual, fingerprint: UUID().uuidString)
                try out.insert(db); try inLeg.insert(db)
                var link = TransferLink(outTransactionId: out.id!, inTransactionId: inLeg.id!, origin: .auto)
                try link.insert(db)
                made += [out.id!, inLeg.id!]
            }
            // A dismissed link is left alone.
            var out = Transaction(importBatchId: f.bankBatch[f.revolut]!, accountId: f.revolut, date: Self.day(2026, 2, 1), rawDescription: "TFR",
                                  amountMinorUnits: -9, categoryId: f.investments, status: .confirmed, categorizedBy: .manual, fingerprint: UUID().uuidString)
            var inLeg = Transaction(importBatchId: f.bankBatch[f.joint]!, accountId: f.joint, date: Self.day(2026, 2, 1), rawDescription: "TFR",
                                    amountMinorUnits: 9, categoryId: nil, status: .pendingReview, categorizedBy: .none, fingerprint: UUID().uuidString)
            try out.insert(db); try inLeg.insert(db)
            var dismissed = TransferLink(outTransactionId: out.id!, inTransactionId: inLeg.id!, origin: .auto, isDismissed: true)
            try dismissed.insert(db)
            return made + [out.id!, inLeg.id!]
        }
        let report = try f.manager.dbQueue.write { db in try TransferCategories.applyToExistingLinks(db: db) }
        let joint = try XCTUnwrap(try f.categoryId(forAccount: f.joint))
        let current = try XCTUnwrap(try f.categoryId(forAccount: f.current))
        XCTAssertEqual(Set(report.changedTransactionIds), Set([ids[0], ids[1], ids[2], ids[3], ids[5]]))
        XCTAssertEqual(Set(report.moves), [
            TransferCategories.Move(fromCategory: "Investments (Stocks + Crypto)", toCategory: "Transfer: Joint", count: 2),
            TransferCategories.Move(fromCategory: nil, toCategory: "Transfer: Current", count: 2),
            TransferCategories.Move(fromCategory: "Investments (Stocks + Crypto)", toCategory: "Transfer: Current", count: 1)
        ])
        XCTAssertTrue(report.text.contains("2 legs moved from Investments (Stocks + Crypto) → Transfer: Joint"), report.text)
        XCTAssertTrue(report.text.contains("2 legs moved from Uncategorised → Transfer: Current"), report.text)
        XCTAssertEqual(try f.transaction(ids[0]).categoryId, joint)
        XCTAssertEqual(try f.transaction(ids[1]).categoryId, current)
        XCTAssertEqual(try f.transaction(ids[4]).categoryId, f.external)      // external leg untouched
        XCTAssertEqual(try f.transaction(ids[6]).categoryId, f.investments)   // dismissed link untouched
        XCTAssertNil(try f.transaction(ids[7]).categoryId)

        let again = try f.manager.dbQueue.write { db in try TransferCategories.applyToExistingLinks(db: db) }
        XCTAssertTrue(again.changedTransactionIds.isEmpty)
        XCTAssertTrue(again.moves.isEmpty)
    }

    // MARK: Budget counting

    func testALinkedTransferStillCountsOnceAsSentAndTheAccountFilterShowsOwnLegs() throws {
        let f = try makeFixture()
        let out = try f.add(f.current, Self.day(2026, 3, 9), -36_000)
        let inLeg = try f.add(f.joint, Self.day(2026, 3, 9), 36_000)
        try f.manager.dbQueue.write { db in _ = try TransferMatcher.match(db: db, today: Self.day(2026, 10, 12)) }
        let (all, links) = try f.manager.dbQueue.read { db in (try Transaction.fetchAll(db), try TransferLink.fetchAll(db)) }
        XCTAssertEqual(TransferLinks.budgetFacing(all, links: links).compactMap(\.id), [out])
        XCTAssertEqual(try f.manager.dbQueue.read { db in try Transaction.budgetFacing.fetchAll(db).compactMap(\.id) }, [out])
        XCTAssertEqual(TransferLinks.budgetFacing(all, links: links, accountIds: [f.joint]).compactMap(\.id), [inLeg])
        XCTAssertEqual(TransferLinks.budgetFacing(all, links: links, accountIds: [f.current, f.joint]).compactMap(\.id), [out])
        XCTAssertEqual(try f.transaction(out).categoryId, try f.categoryId(forAccount: f.joint))
    }

    // MARK: Review fixes

    func testATiedCategoryCannotBeRenamed() throws {
        let f = try makeFixture()
        let joint = try XCTUnwrap(try f.categoryId(forAccount: f.joint))
        try f.manager.dbQueue.write { db in
            XCTAssertThrowsError(try Categories.rename(db: db, id: joint, name: "Household")) {
                XCTAssertEqual($0 as? CategoryEditError, .linkedToAccount)
                XCTAssertEqual(($0 as? LocalizedError)?.errorDescription, "Named after its linked account — rename the account instead.")
            }
            // Untied transfer categories still rename.
            try Categories.rename(db: db, id: f.investments, name: "Investments")
        }
        XCTAssertEqual(try f.categoryName(joint), "Transfer: Joint")
    }

    func testTieMovesTheAccountsTieAndDeletesAnUnusedPreviousCategory() throws {
        let f = try makeFixture() // the launch-time ensure created an empty "Transfer: Joint"
        let created = try XCTUnwrap(try f.categoryId(forAccount: f.joint))
        let lloydsJoint = try f.manager.dbQueue.write { db in try Categories.create(db: db, name: "Transfer: Lloyds Joint", type: .transfer, groupId: nil).id! }
        let log = try f.manager.dbQueue.write { db in try TransferCategories.tie(db: db, categoryName: "Transfer: Lloyds Joint", accountNameOrAlias: "Joint") }
        XCTAssertEqual(log, ["Deleted the unused “Transfer: Joint” (was tied to Lloyds Club Joint)",
                             "Tied “Transfer: Lloyds Joint” to Lloyds Club Joint, renamed “Transfer: Joint”"])
        XCTAssertNil(try f.categoryName(created))
        XCTAssertEqual(try f.categoryId(forAccount: f.joint), lloydsJoint)
        XCTAssertEqual(try f.categoryName(lloydsJoint), "Transfer: Joint")
    }

    func testTieKeepsAPreviousCategoryInUse() throws {
        // name → how the previous category is in use
        let uses: [(String, (Fixture, Int64) throws -> Void)] = [
            ("transaction", { f, id in try f.add(f.euro, Self.day(2026, 1, 1), -100, category: id) }),
            ("rule", { f, id in
                try f.manager.dbQueue.write { db in
                    try db.execute(sql: "INSERT INTO rule (matchPattern, matchType, categoryId, priority) VALUES ('TFR', 'contains', ?, 0)", arguments: [id])
                }
            }),
            ("forecast entry", { f, id in
                try f.manager.dbQueue.write { db in
                    try db.execute(sql: "INSERT INTO forecastGroup (name, isEnabled, isSystemManaged) VALUES ('G', 1, 0)")
                    try db.execute(sql: """
                        INSERT INTO forecastEntry (groupId, categoryId, amountMinorUnits, frequency, interval, startDate, isEnabled, status)
                        VALUES ((SELECT MAX(id) FROM forecastGroup), ?, -100, 'monthly', 1, '2026-01-01', 1, 'manual')
                        """, arguments: [id])
                }
            })
        ]
        for (label, use) in uses {
            let f = try makeFixture()
            let previous = try XCTUnwrap(try f.categoryId(forAccount: f.euro))
            try use(f, previous)
            let eur = try f.manager.dbQueue.write { db in try Categories.create(db: db, name: "Transfer: Lloyds International EUR", type: .transfer, groupId: nil).id! }
            let log = try f.manager.dbQueue.write { db in
                try TransferCategories.tie(db: db, categoryName: "Transfer: Lloyds International EUR", accountNameOrAlias: "Lloyds International Account (EUR)")
            }
            XCTAssertEqual(log, ["Untied “Transfer: International Euro” from Lloyds International Account (EUR) (in use, kept)",
                                 "Tied “Transfer: Lloyds International EUR” to Lloyds International Account (EUR)"], label)
            XCTAssertEqual(try f.categoryName(previous), "Transfer: International Euro", label)
            XCTAssertEqual(try f.categoryId(forAccount: f.euro), eur, label)
        }
    }

    func testTieRefusesUnknownNames() throws {
        // No ties yet: an unknown category is an error (with a tie, see the re-run test).
        let f = try makeFixture(ensure: false)
        try f.manager.dbQueue.write { db in
            XCTAssertThrowsError(try TransferCategories.tie(db: db, categoryName: "Nope", accountNameOrAlias: "Joint")) {
                XCTAssertEqual($0 as? TransferCategoryError, .noCategoryNamed("Nope"))
            }
            XCTAssertThrowsError(try TransferCategories.tie(db: db, categoryName: "Investments (Stocks + Crypto)", accountNameOrAlias: "Nope")) {
                XCTAssertEqual($0 as? TransferCategoryError, .noAccountNamed("Nope"))
            }
        }
    }

    /// A historical total (out) linked to money received in two accounts keeps its category —
    /// as `match` applies it (every link inserted, then `applyOnLink` per pair) and in the
    /// one-off `applyToExistingLinks`; its in legs still move.
    func testHistoricalOutLinkedIntoTwoAccountsKeepsItsCategory() throws {
        for viaExistingLinks in [false, true] {
            let f = try makeFixture()
            let out = try f.add(f.current, Self.day(2026, 1, 25), -50_000, category: f.investments, historical: true)
            let a = try f.add(f.international, Self.day(2026, 1, 3), 30_000)
            let b = try f.add(f.joint, Self.day(2026, 1, 10), 20_000)
            try f.manager.dbQueue.write { db in
                for inId in [a, b] {
                    var link = TransferLink(outTransactionId: out, inTransactionId: inId, origin: .auto)
                    try link.insert(db)
                }
                if viaExistingLinks {
                    _ = try TransferCategories.applyToExistingLinks(db: db)
                } else {
                    for inId in [a, b] { try TransferCategories.applyOnLink(db: db, outTransactionId: out, inTransactionId: inId) }
                }
            }
            XCTAssertEqual(try f.transaction(out).categoryId, f.investments, "\(viaExistingLinks)")
            try assertLeg(f, a, account: f.current)
            try assertLeg(f, b, account: f.current)
            // Matching again changes nothing.
            try f.manager.dbQueue.write { db in _ = try TransferMatcher.match(db: db, today: Self.day(2026, 10, 12)) }
            XCTAssertEqual(try f.transaction(out).categoryId, f.investments, "\(viaExistingLinks)")
        }
    }
}
