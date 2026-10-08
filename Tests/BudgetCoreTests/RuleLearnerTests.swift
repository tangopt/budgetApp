import XCTest
import GRDB
@testable import BudgetCore

final class RuleLearnerTests: XCTestCase {
    func makeManager() throws -> (DatabaseManager, Int64, Int64) {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in try CategorySeeder.seedDefaults(db) }
        let (g, e) = try manager.dbQueue.read { db in
            (try Category.filter(Column("name") == "Groceries").fetchOne(db)!.id!, try Category.filter(Column("name") == "Eating Out").fetchOne(db)!.id!)
        }
        return (manager, g, e)
    }

    func testLearnSavesTheMerchantKeyAsContainsRule() throws {
        let (manager, groceries, _) = try makeManager()
        try manager.dbQueue.write { db in try RuleLearner.learn(description: "TESCO STORES 2041", categoryId: groceries, db: db) }
        let rules = try manager.dbQueue.read { db in try Rule.fetchAll(db) }
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].matchPattern, "TESCO STORES")
        XCTAssertEqual(rules[0].matchType, .contains)
        XCTAssertEqual(RuleMatcher.match(description: "TESCO STORES 3312", rules: rules)?.categoryId, groceries)
    }

    func testShortKeyFallsBackToFullUppercasedDescription() throws {
        let (manager, groceries, _) = try makeManager()
        try manager.dbQueue.write { db in try RuleLearner.learn(description: "ab 12", categoryId: groceries, db: db) }
        let rules = try manager.dbQueue.read { db in try Rule.fetchAll(db) }
        XCTAssertEqual(rules.map(\.matchPattern), ["AB 12"])
    }

    func testLearnUpdatesAnExistingRuleForTheSameKey() throws {
        let (manager, groceries, eatingOut) = try makeManager()
        try manager.dbQueue.write { db in
            try RuleLearner.learn(description: "TESCO STORES 2041", categoryId: groceries, db: db)
            try RuleLearner.learn(description: "TESCO STORES 3312", categoryId: eatingOut, db: db)
        }
        let rules = try manager.dbQueue.read { db in try Rule.fetchAll(db) }
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].categoryId, eatingOut)
    }

    func testLearnFromCorrectionDelegatesToLearn() throws {
        let (manager, groceries, _) = try makeManager()
        try manager.dbQueue.write { db in try RuleLearner.learnFromCorrection(description: "PLAYTOMIC* PI-5B20", categoryId: groceries, db: db) }
        let rules = try manager.dbQueue.read { db in try Rule.fetchAll(db) }
        XCTAssertEqual(rules.map(\.matchPattern), ["PLAYTOMIC"])
    }

    func testEmptyDescriptionLearnsNothing() throws {
        let (manager, groceries, _) = try makeManager()
        try manager.dbQueue.write { db in try RuleLearner.learn(description: "  ", categoryId: groceries, db: db) }
        XCTAssertEqual(try manager.dbQueue.read { db in try Rule.fetchCount(db) }, 0)
    }
}
