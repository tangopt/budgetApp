import XCTest
import GRDB
@testable import BudgetCore

/// A small chart of own accounts for transfer tests: Classic and International (GBP), Euro
/// (EUR at 0.87), a bank batch per account and Classic's spreadsheet history.
struct TransferFixture {
    let manager: DatabaseManager
    let classic: Int64, international: Int64, euro: Int64
    let classicBatch: Int64, internationalBatch: Int64, euroBatch: Int64, historyBatch: Int64
    let transferCategory: Int64, externalCategory: Int64, groceries: Int64

    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    init() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        var ids: [Int64] = []
        try manager.dbQueue.write { db in
            for (name, currency) in [("Lloyds Classic", Currency.gbp), ("Lloyds International", .gbp), ("Euro", .eur)] {
                var account = Account(name: name, currency: currency, kind: .cash, trackingMode: .imported)
                try account.insert(db)
                ids.append(account.id!)
            }
            for (account, file) in [(ids[0], "classic.csv"), (ids[1], "international.csv"), (ids[2], "euro.csv"), (ids[0], "Budget copy.numbers")] {
                var batch = ImportBatch(accountId: account, sourceFileName: file, importedAt: Date())
                try batch.insert(db)
                ids.append(batch.id!)
            }
            for (name, type, external) in [("Transfer: International", CategoryType.transfer, false), ("Transfer: Santander Person B", .transfer, true), ("Groceries", .expense, false)] {
                var category = Category(name: name, type: type, isExternalTransfer: external)
                try category.insert(db)
                ids.append(category.id!)
            }
            try ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date()).inserted(db)
        }
        (classic, international, euro) = (ids[0], ids[1], ids[2])
        (classicBatch, internationalBatch, euroBatch, historyBatch) = (ids[3], ids[4], ids[5], ids[6])
        (transferCategory, externalCategory, groceries) = (ids[7], ids[8], ids[9])
    }

    func batch(for account: Int64) -> Int64 {
        account == classic ? classicBatch : account == international ? internationalBatch : euroBatch
    }

    /// Inserts a transaction; `historical` files it under Classic's spreadsheet batch.
    @discardableResult
    func add(_ account: Int64, _ date: Date, _ amount: Int, category: Int64? = nil, historical: Bool = false, description: String = "A PERSON") throws -> Int64 {
        try manager.dbQueue.write { db in
            var transaction = Transaction(importBatchId: historical ? historyBatch : batch(for: account), accountId: account, date: date,
                                          rawDescription: description, amountMinorUnits: amount, categoryId: category,
                                          status: category == nil ? .pendingReview : .confirmed, categorizedBy: .manual,
                                          fingerprint: UUID().uuidString)
            try transaction.insert(db)
            return transaction.id!
        }
    }

    @discardableResult
    func match() throws -> Int {
        try manager.dbQueue.write { db in try TransferMatcher.match(db: db, today: TransferFixture.date(2026, 10, 12)) }
    }

    func links() throws -> [TransferLink] {
        try manager.dbQueue.read { db in try TransferLink.order(Column("id")).fetchAll(db) }
    }

    func pairs() throws -> Set<TransferPair> {
        Set(try links().filter { !$0.isDismissed }.map { TransferPair(outId: $0.outTransactionId, inId: $0.inTransactionId) })
    }
}

final class TransferMatcherTests: XCTestCase {
    private let d = TransferFixture.date

    // MARK: Bank rows

    func testSameCurrencyEqualAmountsWithinThreeDaysLink() throws {
        let f = try TransferFixture()
        let out = try f.add(f.classic, d(2026, 3, 9), -36_000, category: f.transferCategory)
        let inLeg = try f.add(f.international, d(2026, 3, 9), 36_000)
        XCTAssertEqual(try f.match(), 1)
        XCTAssertEqual(try f.pairs(), [TransferPair(outId: out, inId: inLeg)])
        XCTAssertEqual(try f.links().first?.origin, .auto)
    }

    func testDifferentAmountOrMoreThanThreeDaysApartOrSameAccountDontLink() throws {
        let f = try TransferFixture()
        try f.add(f.classic, d(2026, 3, 9), -36_000)
        try f.add(f.international, d(2026, 3, 9), 36_001)
        try f.add(f.international, d(2026, 3, 13), 36_000)
        try f.add(f.classic, d(2026, 3, 10), 36_000)
        XCTAssertEqual(try f.match(), 0)
    }

    func testThreeDaysApartStillLinks() throws {
        let f = try TransferFixture()
        let out = try f.add(f.classic, d(2026, 3, 9), -36_000)
        let inLeg = try f.add(f.international, d(2026, 3, 12), 36_000)
        try f.match()
        XCTAssertEqual(try f.pairs(), [TransferPair(outId: out, inId: inLeg)])
    }

    func testDifferentCurrenciesMatchWithinThreePercentAtTheStoredRate() throws {
        let f = try TransferFixture()
        // €100 at 0.87 = £87.00: £85.00 is within 3% (±2.61), £84.00 isn't.
        let out = try f.add(f.euro, d(2026, 3, 9), -10_000)
        let inLeg = try f.add(f.classic, d(2026, 3, 10), 8_500)
        try f.add(f.international, d(2026, 3, 10), 8_400)
        try f.match()
        XCTAssertEqual(try f.pairs(), [TransferPair(outId: out, inId: inLeg)])
    }

    func testGBPToEURConvertsTheOtherWay() throws {
        let f = try TransferFixture()
        // £87 / 0.87 = €100.
        let out = try f.add(f.classic, d(2026, 3, 9), -8_700)
        let inLeg = try f.add(f.euro, d(2026, 3, 9), 10_100)
        try f.match()
        XCTAssertEqual(try f.pairs(), [TransferPair(outId: out, inId: inLeg)])
    }

    func testClosestDateWins() throws {
        let f = try TransferFixture()
        let out = try f.add(f.classic, d(2026, 3, 10), -5_000)
        try f.add(f.international, d(2026, 3, 8), 5_000)
        let closer = try f.add(f.international, d(2026, 3, 11), 5_000)
        try f.match()
        XCTAssertEqual(try f.pairs(), [TransferPair(outId: out, inId: closer)])
    }

    func testExactTiesStayUnmatched() throws {
        let f = try TransferFixture()
        try f.add(f.classic, d(2026, 3, 10), -5_000)
        try f.add(f.international, d(2026, 3, 9), 5_000)
        try f.add(f.international, d(2026, 3, 11), 5_000)
        XCTAssertEqual(try f.match(), 0)
    }

    func testOneLinkPerIncomingTransaction() throws {
        let f = try TransferFixture()
        // Two outs for one in: the closer out takes it, the other stays unmatched.
        let near = try f.add(f.classic, d(2026, 3, 10), -5_000)
        try f.add(f.euro, d(2026, 3, 12), -5_747) // €57.47 ≈ £50.00
        let inLeg = try f.add(f.international, d(2026, 3, 10), 5_000)
        try f.match()
        XCTAssertEqual(try f.pairs(), [TransferPair(outId: near, inId: inLeg)])
    }

    func testTwoOutsEquallyCloseToOneIncomingStayUnmatched() throws {
        let f = try TransferFixture()
        try f.add(f.classic, d(2026, 3, 10), -5_000)
        try f.add(f.euro, d(2026, 3, 10), -5_747)
        try f.add(f.international, d(2026, 3, 10), 5_000)
        XCTAssertEqual(try f.match(), 0)
    }

    func testMatchingIsIdempotent() throws {
        let f = try TransferFixture()
        try f.add(f.classic, d(2026, 3, 9), -36_000)
        try f.add(f.international, d(2026, 3, 9), 36_000)
        XCTAssertEqual(try f.match(), 1)
        XCTAssertEqual(try f.match(), 0)
        XCTAssertEqual(try f.links().count, 1)
    }

    func testDismissedLinksAreNeverRelinked() throws {
        let f = try TransferFixture()
        try f.add(f.classic, d(2026, 3, 9), -36_000)
        try f.add(f.international, d(2026, 3, 9), 36_000)
        try f.match()
        let link = try XCTUnwrap(f.links().first)
        try f.manager.dbQueue.write { db in try TransferLinks.unlink(db: db, linkId: link.id!) }
        XCTAssertEqual(try f.links().map(\.isDismissed), [true])
        // A new, equally good candidate for the same out doesn't relink it either.
        try f.add(f.euro, d(2026, 3, 9), 41_379)
        XCTAssertEqual(try f.match(), 0)
        XCTAssertTrue(try f.pairs().isEmpty)
    }

    // MARK: External transfer categories

    func testExternalTransferCategoriesAreNeverMatchedOnEitherLeg() throws {
        let f = try TransferFixture()
        // Classic → Santander (external) and money back from Santander into International.
        try f.add(f.classic, d(2026, 3, 9), -125_000, category: f.externalCategory, description: "B PERSON")
        try f.add(f.international, d(2026, 3, 9), 125_000)
        try f.add(f.classic, d(2026, 4, 9), -100_000)
        try f.add(f.international, d(2026, 4, 9), 100_000, category: f.externalCategory, description: "B PERSON")
        XCTAssertEqual(try f.match(), 0)
    }

    func testSettingExternalRemovesAutoLinksAndClearingItMatchesAgain() throws {
        let f = try TransferFixture()
        let out = try f.add(f.classic, d(2026, 3, 9), -125_000, category: f.externalCategory)
        let inLeg = try f.add(f.international, d(2026, 3, 9), 125_000)
        try f.manager.dbQueue.write { db in try TransferLinks.setExternalTransfer(db: db, categoryId: f.externalCategory, false) }
        XCTAssertEqual(try f.pairs(), [TransferPair(outId: out, inId: inLeg)])
        try f.manager.dbQueue.write { db in try TransferLinks.setExternalTransfer(db: db, categoryId: f.externalCategory, true) }
        XCTAssertTrue(try f.links().isEmpty)
        let flag = try f.manager.dbQueue.read { db in try Category.fetchOne(db, key: f.externalCategory)!.isExternalTransfer }
        XCTAssertTrue(flag)
    }

    func testMoneySentUnderAnIncomeOrExpenseCategoryIsNotATransfer() throws {
        let f = try TransferFixture()
        try f.add(f.classic, d(2026, 3, 9), -5_000, category: f.groceries, description: "TESCO")
        try f.add(f.international, d(2026, 3, 9), 5_000)
        try f.add(f.classic, d(2026, 1, 25), -41_237, category: f.groceries, historical: true, description: "Groceries")
        try f.add(f.international, d(2026, 1, 5), 41_237)
        XCTAssertEqual(try f.match(), 0)
        // Received money may be in any (non-external) category.
        let out = try f.add(f.classic, d(2026, 4, 9), -7_000, category: f.transferCategory)
        let inLeg = try f.add(f.international, d(2026, 4, 9), 7_000, category: f.groceries)
        try f.match()
        XCTAssertEqual(try f.pairs(), [TransferPair(outId: out, inId: inLeg)])
    }

    // MARK: Historical spreadsheet rows

    func testHistoricalRowMatchesASingleEqualAmountInTheSamePayMonth() throws {
        let f = try TransferFixture()
        // No salaries: pay months are calendar months.
        let out = try f.add(f.classic, d(2026, 1, 25), -50_000, category: f.transferCategory, historical: true, description: "Transfer: International")
        let inLeg = try f.add(f.international, d(2026, 1, 3), 50_000)
        try f.add(f.international, d(2026, 2, 2), 50_000) // next pay month
        try f.match()
        XCTAssertEqual(try f.pairs(), [TransferPair(outId: out, inId: inLeg)])
    }

    func testHistoricalRowMatchesTheSmallestExactSumSet() throws {
        let f = try TransferFixture()
        let out = try f.add(f.classic, d(2026, 1, 25), -50_000, historical: true)
        let a = try f.add(f.international, d(2026, 1, 3), 30_000)
        let b = try f.add(f.international, d(2026, 1, 10), 20_000)
        try f.add(f.international, d(2026, 1, 12), 5_000)
        try f.add(f.international, d(2026, 1, 13), 7_000)
        try f.match()
        XCTAssertEqual(try f.pairs(), [TransferPair(outId: out, inId: a), TransferPair(outId: out, inId: b)])
    }

    func testHistoricalRowPrefersFewerTransactions() throws {
        let f = try TransferFixture()
        let out = try f.add(f.classic, d(2026, 1, 25), -50_000, historical: true)
        try f.add(f.international, d(2026, 1, 3), 30_000)
        try f.add(f.international, d(2026, 1, 10), 20_000)
        let single = try f.add(f.international, d(2026, 1, 20), 50_000)
        try f.match()
        XCTAssertEqual(try f.pairs(), [TransferPair(outId: out, inId: single)])
    }

    func testAmbiguousHistoricalSetsStayUnmatched() throws {
        let f = try TransferFixture()
        try f.add(f.classic, d(2026, 1, 25), -50_000, historical: true)
        try f.add(f.international, d(2026, 1, 3), 30_000)
        try f.add(f.international, d(2026, 1, 10), 20_000)
        try f.add(f.international, d(2026, 1, 11), 25_000)
        try f.add(f.international, d(2026, 1, 12), 25_000)
        XCTAssertEqual(try f.match(), 0)
    }

    func testHistoricalSetsOnlyUseUncategorisedOrTransferMoneyReceived() throws {
        let f = try TransferFixture()
        let out = try f.add(f.classic, d(2026, 1, 25), -50_000, category: f.transferCategory, historical: true)
        try f.add(f.international, d(2026, 1, 3), 50_000, category: f.groceries) // a refund, say
        let a = try f.add(f.international, d(2026, 1, 4), 20_000, category: f.transferCategory)
        let b = try f.add(f.international, d(2026, 1, 5), 30_000)
        try f.match()
        XCTAssertEqual(try f.pairs(), [TransferPair(outId: out, inId: a), TransferPair(outId: out, inId: b)])
    }

    func testHistoricalSetMustBeInOneAccount() throws {
        let f = try TransferFixture()
        // 300 in International + 200 in Euro (converted) never add up to one set.
        try f.add(f.classic, d(2026, 1, 25), -50_000, historical: true)
        try f.add(f.international, d(2026, 1, 3), 30_000)
        try f.add(f.euro, d(2026, 1, 10), 20_000)
        XCTAssertEqual(try f.match(), 0)
    }

    func testHistoricalRowsDontMatchByDay() throws {
        let f = try TransferFixture()
        // A historical total dated on payday isn't a bank transfer: an equal amount the next
        // day in the next pay month doesn't link.
        try f.add(f.classic, d(2026, 1, 31), -50_000, historical: true)
        try f.add(f.international, d(2026, 2, 1), 50_000)
        XCTAssertEqual(try f.match(), 0)
    }

    func testSmallestExactSum() {
        XCTAssertEqual(TransferMatcher.smallestExactSum([300, 200, 50], target: 500).map { [$0.size, $0.count] }, [2, 1])
        XCTAssertEqual(TransferMatcher.smallestExactSum([300, 200, 250, 250], target: 500).map { [$0.size, $0.count] }, [2, 2])
        XCTAssertEqual(TransferMatcher.smallestExactSum([100, 100, 100, 200], target: 300).map { [$0.size, $0.count] }, [2, 2])
        XCTAssertNil(TransferMatcher.smallestExactSum([300, 100], target: 500))
        // The subset is rebuilt from the table, as indices into the input.
        XCTAssertEqual(TransferMatcher.smallestExactSum([50, 300, 70, 200], target: 500)?.indices.sorted(), [1, 3])
        XCTAssertEqual(TransferMatcher.smallestExactSum([1, 2, 4, 8, 16, -3, 900], target: 23)?.indices.sorted(), [0, 1, 2, 4])
    }

    // MARK: Import

    func testStagedRowsMatchSavedLegs() throws {
        let f = try TransferFixture()
        let out = try f.add(f.classic, d(2026, 3, 9), -36_000, category: f.transferCategory)
        let matches = try f.manager.dbQueue.read { db in
            try TransferMatcher.stagedMatches(db: db, accountId: f.international,
                                              staged: [(d(2026, 3, 9), 36_000, nil), (d(2026, 3, 9), 1_000, nil),
                                                       (d(2026, 3, 9), 36_000, f.externalCategory)],
                                              today: d(2026, 10, 12))
        }
        XCTAssertEqual(Array(matches.keys), [0])
        XCTAssertEqual(matches[0]?.otherTransactionId, out)
        XCTAssertEqual(matches[0]?.otherAccountName, "Lloyds Classic")
        XCTAssertEqual(matches[0]?.otherCategoryId, f.transferCategory)
        XCTAssertEqual(matches[0]?.isIncoming, true)
    }

    func testImportStagingPresetsTheOtherLegsCategoryAndCommitLinks() async throws {
        let f = try TransferFixture()
        let out = try f.add(f.classic, d(2026, 3, 9), -36_000, category: f.transferCategory)
        let profile = ImportProfile(accountId: f.international, format: .csv, csvDelimiter: ",", csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2, csvDateFormat: "dd/MM/yyyy")
        let fake = FakeCategorizer()
        fake.stubbedSuggestion = nil
        let coordinator = ImportCoordinator(dbQueue: f.manager.dbQueue, categorizationService: CategorizationService(categorizer: fake))
        let staged = try await coordinator.stageCSVImport(csvText: "Date,Description,Amount\n09/03/2026,A PERSON,360.00\n10/03/2026,SHOP,-5.00",
                                                          profile: profile, accountId: f.international)
        let row = staged.staged[0]
        XCTAssertEqual(row.source, .transfer)
        XCTAssertEqual(row.suggestedCategoryId, f.transferCategory)
        XCTAssertEqual(row.transfer?.otherTransactionId, out)
        XCTAssertTrue(ReviewPartitioning.isSure(row))
        XCTAssertNil(staged.staged[1].transfer)

        try coordinator.commit(accountId: f.international, sourceFileName: "international.csv", staged: staged.staged,
                               decisions: staged.staged.map { ImportDecision(stagedId: $0.id, finalCategoryId: $0.suggestedCategoryId) })
        let links = try f.links()
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.outTransactionId, out)
        let saved = try await f.manager.dbQueue.read { db in try Transaction.fetchOne(db, key: links.first!.inTransactionId)! }
        XCTAssertEqual(saved.categorizedBy, .transfer)
        // A transfer's category comes from its other leg: no rule learned.
        let rules = try await f.manager.dbQueue.read { db in try Rule.fetchAll(db) }
        XCTAssertFalse(rules.contains { $0.matchPattern.contains("A PERSON") })
    }

    /// Stages Classic rows against a saved International receipt filed under `receivedCategory`.
    private func stageOutgoing(_ f: TransferFixture, receivedCategory: Int64?) async throws -> (StagedTransaction, Int64) {
        let inLeg = try f.add(f.international, d(2026, 3, 9), 36_000, category: receivedCategory)
        let profile = ImportProfile(accountId: f.classic, format: .csv, csvDelimiter: ",", csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2, csvDateFormat: "dd/MM/yyyy")
        let fake = FakeCategorizer()
        fake.stubbedSuggestion = nil
        let coordinator = ImportCoordinator(dbQueue: f.manager.dbQueue, categorizationService: CategorizationService(categorizer: fake))
        let staged = try await coordinator.stageCSVImport(csvText: "Date,Description,Amount\n09/03/2026,A PERSON,-360.00", profile: profile, accountId: f.classic)
        try coordinator.commit(accountId: f.classic, sourceFileName: "classic.csv", staged: staged.staged,
                               decisions: staged.staged.map { ImportDecision(stagedId: $0.id, finalCategoryId: $0.suggestedCategoryId) })
        return (staged.staged[0], inLeg)
    }

    func testStagedOutgoingRowTakesTheReceivingLegsTransferCategory() async throws {
        let f = try TransferFixture()
        let (row, inLeg) = try await stageOutgoing(f, receivedCategory: f.transferCategory)
        XCTAssertEqual(row.transfer?.otherTransactionId, inLeg)
        XCTAssertEqual(row.transfer?.isIncoming, false)
        XCTAssertEqual(row.source, .transfer)
        XCTAssertEqual(row.suggestedCategoryId, f.transferCategory)
        XCTAssertEqual(try f.links().map(\.inTransactionId), [inLeg])
    }

    func testStagedOutgoingRowNeverTakesAnIncomeOrExpenseCategory() async throws {
        let f = try TransferFixture()
        // The receipt was filed as Groceries: copying it would make money sent unlinkable, so
        // the row keeps its own (empty) suggestion — and still links, as the badge says.
        let (row, inLeg) = try await stageOutgoing(f, receivedCategory: f.groceries)
        XCTAssertNil(row.suggestedCategoryId)
        XCTAssertNotEqual(row.source, .transfer)
        XCTAssertFalse(ReviewPartitioning.isSure(row))
        XCTAssertEqual(row.transfer?.otherTransactionId, inLeg)
        XCTAssertEqual(try f.links().map(\.inTransactionId), [inLeg])
    }

    func testForcedDuplicatesAreMatchedToo() async throws {
        let f = try TransferFixture()
        let out = try f.add(f.classic, d(2026, 3, 9), -36_000, category: f.transferCategory)
        let fake = FakeCategorizer()
        fake.stubbedSuggestion = nil
        let coordinator = ImportCoordinator(dbQueue: f.manager.dbQueue, categorizationService: CategorizationService(categorizer: fake))
        let parsed = ParsedTransaction(date: d(2026, 3, 9), rawDescription: "A PERSON", amountMinorUnits: 36_000)
        let forced = try await coordinator.stageForcedDuplicates([parsed], accountId: f.international, alreadyStaged: [])
        XCTAssertEqual(forced.first?.transfer?.otherTransactionId, out)
        XCTAssertEqual(forced.first?.suggestedCategoryId, f.transferCategory)
    }

    // MARK: Manual links

    func testManualLinkCandidatesUnlinkAndRelink() throws {
        let f = try TransferFixture()
        let out = try f.add(f.classic, d(2026, 3, 9), -36_000)
        let inLeg = try f.add(f.international, d(2026, 3, 15), 35_000) // 6 days, ~2.8% off: no auto match
        try f.add(f.international, d(2026, 3, 20), 36_000)              // 11 days: not offered
        try f.add(f.international, d(2026, 3, 10), -36_000)             // same sign: not offered
        XCTAssertEqual(try f.match(), 0)
        let candidates = try f.manager.dbQueue.read { db in try TransferLinks.candidates(db: db, for: out, today: d(2026, 10, 12)) }
        XCTAssertEqual(candidates.map(\.transactionId), [inLeg])

        let link = try f.manager.dbQueue.write { db in try TransferLinks.link(db: db, transactionId: inLeg, with: out) }
        XCTAssertEqual(link.outTransactionId, out)
        XCTAssertEqual(link.origin, .manual)
        let counterparts = try f.manager.dbQueue.read { db in try TransferLinks.counterparts(db: db) }
        XCTAssertEqual(counterparts[out]?.map(\.transactionId), [inLeg])
        XCTAssertEqual(counterparts[inLeg]?.first?.accountName, "Lloyds Classic")
        XCTAssertThrowsError(try f.manager.dbQueue.write { db in try TransferLinks.link(db: db, transactionId: out, with: inLeg) }) {
            XCTAssertEqual($0 as? TransferLinkError, .alreadyLinked)
        }

        // Unlinking a manual link deletes it.
        try f.manager.dbQueue.write { db in try TransferLinks.unlink(db: db, linkId: link.id!) }
        XCTAssertTrue(try f.links().isEmpty)
    }

    func testAManuallyLinkedLegCanBeLinkedAfterItsAutoLinkWasDismissed() throws {
        let f = try TransferFixture()
        let out = try f.add(f.classic, d(2026, 3, 9), -36_000)
        let inLeg = try f.add(f.international, d(2026, 3, 9), 36_000)
        let other = try f.add(f.euro, d(2026, 3, 11), -41_379)
        try f.match()
        let autoLink = try f.links()[0]
        try f.manager.dbQueue.write { db in try TransferLinks.unlink(db: db, linkId: autoLink.id!) }
        try f.manager.dbQueue.write { db in _ = try TransferLinks.link(db: db, transactionId: inLeg, with: other) }
        XCTAssertEqual(try f.pairs(), [TransferPair(outId: other, inId: inLeg)])
        XCTAssertEqual(try f.links().count, 2)
        _ = out
    }

    func testDeletingATransactionDeletesItsLinks() throws {
        let f = try TransferFixture()
        let out = try f.add(f.classic, d(2026, 3, 9), -36_000)
        try f.add(f.international, d(2026, 3, 9), 36_000)
        try f.match()
        try f.manager.dbQueue.write { db in
            _ = try Transaction.deleteOne(db, key: out)
        }
        XCTAssertTrue(try f.links().isEmpty)
    }
}
