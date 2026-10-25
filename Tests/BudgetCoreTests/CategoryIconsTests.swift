import XCTest
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category
import TestSupport

final class CategoryIconsTests: XCTestCase {
    private func makeDB() throws -> DatabaseManager {
        return try TestDatabase.migratedManager()
    }

    private func insert(_ m: DatabaseManager, _ name: String = "Groceries") throws -> Int64 {
        try m.dbQueue.write { db in try Categories.create(db: db, name: name, type: .expense, groupId: nil).id! }
    }

    private func iconName(_ m: DatabaseManager, _ id: Int64) throws -> String? {
        try m.dbQueue.read { db in try Category.fetchOne(db, key: id)?.iconName }
    }

    // MARK: setIcon

    func testANewCategoryHasNoIcon() throws {
        let m = try makeDB()
        XCTAssertNil(try iconName(m, try insert(m)))
    }

    func testSetsATrimmedIcon() throws {
        let m = try makeDB()
        let id = try insert(m)
        try m.dbQueue.write { db in try Categories.setIcon(db: db, id: id, iconName: "  cart.fill \n") }
        XCTAssertEqual(try iconName(m, id), "cart.fill")
    }

    func testNilOrBlankClearsTheIcon() throws {
        let m = try makeDB()
        let id = try insert(m)
        try m.dbQueue.write { db in try Categories.setIcon(db: db, id: id, iconName: "cart.fill") }
        try m.dbQueue.write { db in try Categories.setIcon(db: db, id: id, iconName: "   ") }
        XCTAssertNil(try iconName(m, id))
        try m.dbQueue.write { db in try Categories.setIcon(db: db, id: id, iconName: "cart.fill") }
        try m.dbQueue.write { db in try Categories.setIcon(db: db, id: id, iconName: nil) }
        XCTAssertNil(try iconName(m, id))
    }

    func testSettingTheIconLeavesOtherFieldsAlone() throws {
        let m = try makeDB()
        let id = try insert(m)
        try m.dbQueue.write { db in _ = try ReservedCategories.setExcludedFromAutoForecast(db: db, categoryId: id, true) }
        try m.dbQueue.write { db in try Categories.setIcon(db: db, id: id, iconName: "fork.knife") }
        let fetched = try m.dbQueue.read { db in try Category.fetchOne(db, key: id) }
        XCTAssertEqual(fetched?.name, "Groceries")
        XCTAssertEqual(fetched?.excludeFromAutoForecast, true)
        XCTAssertEqual(fetched?.iconName, "fork.knife")
    }

    func testOnlyTheGivenCategoryChanges() throws {
        let m = try makeDB()
        let a = try insert(m, "A")
        let b = try insert(m, "B")
        try m.dbQueue.write { db in try Categories.setIcon(db: db, id: a, iconName: "car.fill") }
        XCTAssertEqual(try iconName(m, a), "car.fill")
        XCTAssertNil(try iconName(m, b))
    }

    func testRefusesAMissingCategory() throws {
        let m = try makeDB()
        XCTAssertThrowsError(try m.dbQueue.write { db in try Categories.setIcon(db: db, id: 999, iconName: "car.fill") }) { error in
            XCTAssertEqual(error as? CategoryEditError, .notFound)
        }
    }

    // MARK: migration

    func testMigrationAddsANullableIconName() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate(upTo: "addAccountSortOrder")
        try manager.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO category (name, type) VALUES ('Old', 'expense')")
        }
        try manager.migrate()
        let columns = try manager.dbQueue.read { db in try db.columns(in: "category").map(\.name) }
        XCTAssertTrue(columns.contains("iconName"))
        let old = try manager.dbQueue.read { db in try Category.fetchOne(db) }
        XCTAssertEqual(old?.name, "Old")
        XCTAssertNil(old?.iconName)
    }

    // MARK: curated set

    func testEveryCuratedSymbolExists() {
        // The same SF Symbols must exist on the Mac and on iPhone/iPad.
        let missing = CategoryIcons.allSymbols.filter { !Self.symbolExists($0) }
        XCTAssertEqual(missing, [])
    }

    private static func symbolExists(_ name: String) -> Bool {
        #if canImport(AppKit)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #else
        return UIImage(systemName: name) != nil
        #endif
    }

    func testCuratedSymbolsAreUniqueAndAbout80() {
        let all = CategoryIcons.allSymbols
        XCTAssertEqual(Set(all).count, all.count)
        XCTAssertGreaterThanOrEqual(all.count, 70)
    }

    func testThemesAreInTheSpecOrder() {
        XCTAssertEqual(CategoryIcons.themes.map(\.title), [
            "Home & bills", "Food & drink", "Transport & car", "Shopping", "Leisure & travel",
            "Health", "Money & transfers", "Work & income", "Kids & pets", "Other",
        ])
        XCTAssertTrue(CategoryIcons.themes.allSatisfy { !$0.icons.isEmpty })
    }

    func testAnEmptySearchReturnsEveryTheme() {
        XCTAssertEqual(CategoryIcons.search("  ").map(\.title), CategoryIcons.themes.map(\.title))
    }

    func testSearchMatchesKeywordsAndSymbolNamesAndDropsEmptyThemes() {
        let coffee = CategoryIcons.search("coffee")
        XCTAssertTrue(coffee.flatMap(\.icons).map(\.symbol).contains("cup.and.saucer.fill"))
        XCTAssertTrue(coffee.allSatisfy { !$0.icons.isEmpty })
        XCTAssertFalse(coffee.map(\.title).contains("Transport & car"))
        XCTAssertTrue(CategoryIcons.search("FUELPUMP").flatMap(\.icons).map(\.symbol).contains("fuelpump.fill"))
        XCTAssertEqual(CategoryIcons.search("zzzz-nothing"), [])
    }

    func testSearchingAThemeNameShowsTheWholeTheme() {
        let pets = CategoryIcons.search("pets")
        let theme = CategoryIcons.themes.first { $0.title == "Kids & pets" }!
        XCTAssertEqual(pets.first { $0.title == "Kids & pets" }?.icons, theme.icons)
    }
}
