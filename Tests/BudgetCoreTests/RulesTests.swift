import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

final class RulesTests: XCTestCase {
    private struct Fixture {
        let manager: DatabaseManager
        let eatingOut: Int64
        let groceries: Int64
        let reserve: Int64
        /// Ids by description, in insertion order.
        let ids: [String: Int64]
    }

    /// NANDOS LONDON (uncategorised), NANDOS LEEDS (confirmed, Groceries), SQ *NANDOS CARD
    /// (pending review, suggested Groceries), TESCO STORES 2041 (uncategorised).
    private func makeFixture() throws -> Fixture {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        return try manager.dbQueue.write { db -> Fixture in
            var account = Account(name: "Lloyds", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "a.csv", importedAt: Date())
            try batch.insert(db)
            var eatingOut = Category(name: "Eating Out", type: .expense)
            try eatingOut.insert(db)
            var groceries = Category(name: "Groceries", type: .expense)
            try groceries.insert(db)
            var reserve = Category(name: "Holiday", type: .expense, isReserved: true)
            try reserve.insert(db)
            let rows: [(String, Int64?, TransactionStatus, CategorizedBy)] = [
                ("NANDOS LONDON", nil, .confirmed, .none),
                ("NANDOS LEEDS", groceries.id, .confirmed, .manual),
                ("SQ *NANDOS CARD", groceries.id, .pendingReview, .llm),
                ("TESCO STORES 2041", nil, .confirmed, .none),
            ]
            var ids: [String: Int64] = [:]
            for (index, row) in rows.enumerated() {
                var transaction = Transaction(importBatchId: batch.id!, accountId: account.id!,
                                              date: Date(timeIntervalSince1970: TimeInterval(1_000_000 + index * 86_400)),
                                              rawDescription: row.0, amountMinorUnits: -1500, categoryId: row.1,
                                              status: row.2, categorizedBy: row.3, fingerprint: "f\(index)")
                try transaction.insert(db)
                ids[row.0] = transaction.id!
            }
            return Fixture(manager: manager, eatingOut: eatingOut.id!, groceries: groceries.id!, reserve: reserve.id!, ids: ids)
        }
    }

    // MARK: - Validation

    func testValidationRejectsBlankPatternAndBadRegex() {
        XCTAssertEqual(Rules.validationError(pattern: "  ", matchType: .contains), .emptyPattern)
        XCTAssertEqual(Rules.validationError(pattern: "NANDOS(", matchType: .regex), .invalidRegex)
        XCTAssertNil(Rules.validationError(pattern: "NANDOS(", matchType: .contains))
        XCTAssertNil(Rules.validationError(pattern: "^NANDOS", matchType: .regex))
    }

    // MARK: - Preview

    func testPreviewCountsMatchesAndUncategorisedWithSamples() throws {
        let f = try makeFixture()
        let preview = try f.manager.dbQueue.read { db in try Rules.preview(db: db, pattern: "nandos", matchType: .contains) }
        XCTAssertEqual(preview.matchCount, 3)
        // The uncategorised one and the one still pending review.
        XCTAssertEqual(preview.uncategorisedCount, 2)
        // Newest first.
        XCTAssertEqual(preview.sampleDescriptions, ["SQ *NANDOS CARD", "NANDOS LEEDS", "NANDOS LONDON"])
    }

    func testPreviewUsesTheImportMatcherForMerchantKeysAndRegex() throws {
        let f = try makeFixture()
        let regex = try f.manager.dbQueue.read { db in try Rules.preview(db: db, pattern: "^NANDOS L", matchType: .regex) }
        XCTAssertEqual(regex.matchCount, 2)
        XCTAssertEqual(regex.uncategorisedCount, 1)
        // Contains rules match the merchant key too (same as `RuleMatcher`).
        let key = MerchantKey.make("SQ *NANDOS CARD")
        let byKey = try f.manager.dbQueue.read { db in try Rules.preview(db: db, pattern: key, matchType: .contains) }
        XCTAssertGreaterThanOrEqual(byKey.matchCount, 1)
    }

    func testPreviewOfAnInvalidPatternIsEmpty() throws {
        let f = try makeFixture()
        let preview = try f.manager.dbQueue.read { db in try Rules.preview(db: db, pattern: "(", matchType: .regex) }
        XCTAssertEqual(preview, RulePreview(matchCount: 0, uncategorisedCount: 0, sampleDescriptions: []))
    }

    func testPreviewSampleIsLimited() throws {
        let f = try makeFixture()
        let preview = try f.manager.dbQueue.read { db in try Rules.preview(db: db, pattern: "N", matchType: .contains, sampleLimit: 2) }
        XCTAssertEqual(preview.matchCount, 3)
        XCTAssertEqual(preview.sampleDescriptions.count, 2)
    }

    // MARK: - Add

    func testAddInsertsARuleWithTheLearnersPriority() throws {
        let f = try makeFixture()
        let rule = try f.manager.dbQueue.write { db in
            try Rules.add(db: db, pattern: "  NANDOS ", matchType: .contains, categoryId: f.eatingOut, applyToUncategorised: false)
        }
        XCTAssertNotNil(rule.id)
        XCTAssertEqual(rule.matchPattern, "NANDOS")
        XCTAssertEqual(rule.priority, "NANDOS".count)
        let saved = try f.manager.dbQueue.read { db in try Rule.fetchAll(db) }
        XCTAssertEqual(saved, [rule])
        // Nothing applied.
        let london = try f.manager.dbQueue.read { db in try Transaction.fetchOne(db, key: f.ids["NANDOS LONDON"]!)! }
        XCTAssertNil(london.categoryId)
    }

    func testAddAppliesToUncategorisedMatchesOnly() throws {
        let f = try makeFixture()
        try f.manager.dbQueue.write { db in
            _ = try Rules.add(db: db, pattern: "NANDOS", matchType: .contains, categoryId: f.eatingOut, applyToUncategorised: true)
        }
        let rows = try f.manager.dbQueue.read { db in try Transaction.fetchAll(db) }
        let byDescription = Dictionary(uniqueKeysWithValues: rows.map { ($0.rawDescription, $0) })
        for description in ["NANDOS LONDON", "SQ *NANDOS CARD"] {
            XCTAssertEqual(byDescription[description]?.categoryId, f.eatingOut, description)
            XCTAssertEqual(byDescription[description]?.status, .confirmed, description)
            XCTAssertEqual(byDescription[description]?.categorizedBy, .rule, description)
        }
        // An already-categorised match is left alone; a non-match too.
        XCTAssertEqual(byDescription["NANDOS LEEDS"]?.categoryId, f.groceries)
        XCTAssertEqual(byDescription["NANDOS LEEDS"]?.categorizedBy, .manual)
        XCTAssertNil(byDescription["TESCO STORES 2041"]?.categoryId)
    }

    func testAddWithAnExistingPatternUpdatesItInsteadOfDuplicating() throws {
        let f = try makeFixture()
        try f.manager.dbQueue.write { db in
            _ = try Rules.add(db: db, pattern: "NANDOS", matchType: .contains, categoryId: f.groceries, applyToUncategorised: false)
            _ = try Rules.add(db: db, pattern: "NANDOS", matchType: .contains, categoryId: f.eatingOut, applyToUncategorised: false)
        }
        let saved = try f.manager.dbQueue.read { db in try Rule.fetchAll(db) }
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].categoryId, f.eatingOut)
    }

    func testAddRefusesInvalidInputAndWritesNothing() throws {
        let f = try makeFixture()
        let cases: [(String, RuleMatchType, Int64, RuleSaveError)] = [
            (" ", .contains, f.eatingOut, .emptyPattern),
            ("(", .regex, f.eatingOut, .invalidRegex),
            ("NANDOS", .contains, f.reserve, .unassignableCategory),
            ("NANDOS", .contains, 9_999, .unassignableCategory),
        ]
        for (pattern, type, category, expected) in cases {
            XCTAssertThrowsError(try f.manager.dbQueue.write { db in
                try Rules.add(db: db, pattern: pattern, matchType: type, categoryId: category, applyToUncategorised: true)
            }) { error in XCTAssertEqual(error as? RuleSaveError, expected, pattern) }
        }
        XCTAssertEqual(try f.manager.dbQueue.read { db in try Rule.fetchCount(db) }, 0)
        let london = try f.manager.dbQueue.read { db in try Transaction.fetchOne(db, key: f.ids["NANDOS LONDON"]!)! }
        XCTAssertNil(london.categoryId)
    }

    func testABuiltInCategoryIsNotAssignable() throws {
        let f = try makeFixture()
        try f.manager.dbQueue.write { db in try CategorySeeder.seedDefaults(db) }
        let builtIn = try f.manager.dbQueue.read { db in try Category.fetchAll(db).first { $0.isBuiltIn } }
        guard let builtInId = builtIn?.id else { return }
        XCTAssertThrowsError(try f.manager.dbQueue.write { db in
            try Rules.add(db: db, pattern: "NANDOS", matchType: .contains, categoryId: builtInId, applyToUncategorised: false)
        }) { error in XCTAssertEqual(error as? RuleSaveError, .unassignableCategory) }
    }

    func testApplySkipsPendingRowsFiledInAnUnassignableCategory() throws {
        let f = try makeFixture()
        // A pending-review row the app filed in a built-in category isn't re-filed.
        let pendingId = f.ids["SQ *NANDOS CARD"]!
        let builtIn = try f.manager.dbQueue.write { db -> Int64 in
            let id: Int64
            if let existing = try Category.filter(Column("builtInRole") == CategoryBuiltInRole.balanceAdjustment.rawValue).fetchOne(db) {
                id = existing.id!
            } else {
                var category = Category(name: "Balance adjustment", type: .expense, builtInRole: .balanceAdjustment)
                try category.insert(db)
                id = category.id!
            }
            try db.execute(sql: "UPDATE transaction_ SET categoryId = ? WHERE id = ?", arguments: [id, pendingId])
            return id
        }
        let preview = try f.manager.dbQueue.read { db in try Rules.preview(db: db, pattern: "NANDOS", matchType: .contains) }
        XCTAssertEqual(preview.uncategorisedCount, 1)
        try f.manager.dbQueue.write { db in
            _ = try Rules.add(db: db, pattern: "NANDOS", matchType: .contains, categoryId: f.eatingOut, applyToUncategorised: true)
        }
        let pending = try f.manager.dbQueue.read { db in try Transaction.fetchOne(db, key: pendingId)! }
        XCTAssertEqual(pending.categoryId, builtIn)
        XCTAssertEqual(pending.status, .pendingReview)
        let london = try f.manager.dbQueue.read { db in try Transaction.fetchOne(db, key: f.ids["NANDOS LONDON"]!)! }
        XCTAssertEqual(london.categoryId, f.eatingOut)
    }

    func testTheLearnerNeverRepointsAManualRegexRuleWithTheSamePattern() throws {
        let f = try makeFixture()
        let regex = try f.manager.dbQueue.write { db in
            try Rules.add(db: db, pattern: "NANDOS", matchType: .regex, categoryId: f.groceries, applyToUncategorised: false)
        }
        try f.manager.dbQueue.write { db in try RuleLearner.learn(description: "NANDOS", categoryId: f.eatingOut, db: db) }
        let rules = try f.manager.dbQueue.read { db in try Rule.fetchAll(db) }
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules.first { $0.id == regex.id }?.categoryId, f.groceries)
        XCTAssertEqual(rules.first { $0.matchType == .contains }?.categoryId, f.eatingOut)
    }

    // MARK: - Update

    func testUpdateChangesPatternTypeCategoryAndPriority() throws {
        let f = try makeFixture()
        let rule = try f.manager.dbQueue.write { db in
            try Rules.add(db: db, pattern: "NANDOS", matchType: .contains, categoryId: f.groceries, applyToUncategorised: false)
        }
        let updated = try f.manager.dbQueue.write { db in
            try Rules.update(db: db, id: rule.id!, pattern: "^TESCO", matchType: .regex, categoryId: f.eatingOut, applyToUncategorised: true)
        }
        XCTAssertEqual(updated.id, rule.id)
        XCTAssertEqual(updated.matchPattern, "^TESCO")
        XCTAssertEqual(updated.matchType, .regex)
        XCTAssertEqual(updated.categoryId, f.eatingOut)
        XCTAssertEqual(updated.priority, "^TESCO".count)
        XCTAssertEqual(try f.manager.dbQueue.read { db in try Rule.fetchAll(db) }, [updated])
        let tesco = try f.manager.dbQueue.read { db in try Transaction.fetchOne(db, key: f.ids["TESCO STORES 2041"]!)! }
        XCTAssertEqual(tesco.categoryId, f.eatingOut)
        XCTAssertEqual(tesco.categorizedBy, .rule)
    }

    func testUpdateOfAMissingRuleThrows() throws {
        let f = try makeFixture()
        XCTAssertThrowsError(try f.manager.dbQueue.write { db in
            try Rules.update(db: db, id: 42, pattern: "NANDOS", matchType: .contains, categoryId: f.eatingOut, applyToUncategorised: false)
        }) { error in XCTAssertEqual(error as? RuleSaveError, .ruleNotFound) }
    }

    func testUpdateToAnotherRulesPatternIsRefused() throws {
        let f = try makeFixture()
        let second = try f.manager.dbQueue.write { db -> Rule in
            _ = try Rules.add(db: db, pattern: "NANDOS", matchType: .contains, categoryId: f.groceries, applyToUncategorised: false)
            return try Rules.add(db: db, pattern: "TESCO", matchType: .contains, categoryId: f.groceries, applyToUncategorised: false)
        }
        XCTAssertThrowsError(try f.manager.dbQueue.write { db in
            try Rules.update(db: db, id: second.id!, pattern: "nandos", matchType: .contains, categoryId: f.eatingOut, applyToUncategorised: false)
        }) { error in XCTAssertEqual(error as? RuleSaveError, .duplicatePattern) }
    }

    // MARK: - Matcher

    func testRuleMatcherSingleRuleAgreesWithMatch() {
        let rule = Rule(matchPattern: "NANDOS", matchType: .contains, categoryId: 1, priority: 6)
        XCTAssertTrue(RuleMatcher.matches(rule, description: "SQ *NANDOS CARD"))
        XCTAssertFalse(RuleMatcher.matches(rule, description: "TESCO"))
        let bad = Rule(matchPattern: "(", matchType: .regex, categoryId: 1, priority: 1)
        XCTAssertFalse(RuleMatcher.matches(bad, description: "("))
    }
}
