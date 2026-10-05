# Reserved Forecast Categories Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Forecast-only "reserved" expense categories, shown as a separate Reserved block in the Forecast grid, Budget grid and Dashboard, replacing the single catch-all — plus a one-off tool that seeds the spreadsheet's £2,000/month reserve and its missing planned amounts.

**Architecture:** Two flags on `Category` (`isReserved`, `excludeFromAutoForecast`) with database triggers that keep transactions and rules out of reserves. Reserve allowances are ordinary `ForecastEntry` rows in a "Reserved" forecast group. All rules live in BudgetCore (`ReservedCategories`, `ForecastPlanSeeder`); the app screens only filter and lay out.

**Tech Stack:** Swift 6 / SwiftUI (macOS 26), GRDB 6.29, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-05-reserved-forecast-categories-design.md` — read it before starting any task.

## Global Constraints

- Money is `Int` minor units (pence), **signed**: expenses and transfers out are negative, income positive. Dashboard flow figures are positive magnitudes.
- Calendars are Gregorian **UTC** everywhere (`MonthRange`, `DashboardFixture.calendar`).
- Tests are XCTest classes in `Tests/BudgetCoreTests/`, using an in-memory DB: `let m = try DatabaseManager(path: nil); try m.migrate()`. In this test target a bare `Category` annotation can be ambiguous — use `BudgetCore.Category` if the compiler complains.
- Test commands: `swift test --filter <ClassName>`, full suite `swift test`. App build: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' build 2>&1 | tail -5` → `** BUILD SUCCEEDED **`.
- Build hygiene (repo is under iCloud-synced `~/Documents`): never run `swift test` and `xcodebuild` at the same time. If "ambiguous for type lookup" errors name GRDB files ending in ` 2.swift`, `rm -rf .build` and rebuild once.
- New migrations are appended at the **end** of `DatabaseManager.registerMigrations` (triggers need the `transaction_` and `rule` tables to exist).
- Trigger error text, verbatim: `Reserved categories can't hold transactions.`
- Reserved forecast group name: `Reserved`. Seeded reserve: `Remaining for expenses`, −£2,000.00/month from 2026-10-01. Seed plan group: `Spreadsheet plan`; seeded entry note: `From spreadsheet plan`.
- Commit after every task; message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push.
- Never write to the real database (`~/Library/Application Support/Budget/budget.sqlite`) except in Task 8, and only after its backup step.

---

### Task 1: Reserved and excluded flags, triggers, `ReservedCategories`

**Files:**
- Modify: `Sources/BudgetCore/Models/Category.swift`
- Modify: `Sources/BudgetCore/Models/Category+Migration.swift`
- Modify: `Sources/BudgetCore/Database/DatabaseManager.swift`
- Create: `Sources/BudgetCore/Forecasting/ReservedCategories.swift`
- Modify: `Sources/BudgetCore/Forecasting/AutoForecastGenerator.swift:59`
- Modify: `Sources/BudgetCore/Categorization/CategorizationService.swift` (`categorize`, `categorizeBatch`)
- Test: `Tests/BudgetCoreTests/ReservedCategoriesTests.swift` (create), `Tests/BudgetCoreTests/AutoForecastGeneratorTests.swift`, `Tests/BudgetCoreTests/CategorizationServiceTests.swift`

**Interfaces:**
- Produces:
  - `Category.isReserved: Bool`, `Category.excludeFromAutoForecast: Bool`, `Category.isAssignable: Bool { !isReserved }`; init `Category(id:name:type:groupId:isCatchAll:isReserved:excludeFromAutoForecast:)` with the three Bools defaulting to `false` (`isCatchAll` stays until Task 2).
  - `ReservedCategoryError: Error, Equatable { case emptyName, duplicateName, notReserved }`
  - `ReservedCategories.groupName: String` (= "Reserved")
  - `ReservedCategories.create(db: Database, name: String) throws -> Category`
  - `ReservedCategories.ensureGroup(db: Database) throws -> ForecastGroup` (`@discardableResult`)
  - `ReservedCategories.rename(db: Database, categoryId: Int64, to name: String) throws`
  - `ReservedCategories.delete(db: Database, categoryId: Int64) throws`
  - `ReservedCategories.setExcludedFromAutoForecast(db: Database, categoryId: Int64, _ excluded: Bool) throws -> Int` (`@discardableResult`, returns the number of `.auto` entries deleted)
  - `ReservedCategories.countsAllowance(year: Int, month: Int, today: Date) -> Bool`

- [ ] **Step 1: Write the failing tests** — create `Tests/BudgetCoreTests/ReservedCategoriesTests.swift`:

```swift
// Tests/BudgetCoreTests/ReservedCategoriesTests.swift
import XCTest
import GRDB
@testable import BudgetCore

final class ReservedCategoriesTests: XCTestCase {
    private func manager() throws -> DatabaseManager {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        return manager
    }
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testFlagsDefaultToFalse() throws {
        try manager().dbQueue.write { db in
            var category = BudgetCore.Category(name: "Groceries", type: .expense)
            try category.insert(db)
            let fetched = try XCTUnwrap(BudgetCore.Category.fetchOne(db, key: category.id!))
            XCTAssertFalse(fetched.isReserved)
            XCTAssertFalse(fetched.excludeFromAutoForecast)
            XCTAssertTrue(fetched.isAssignable)
        }
    }

    func testCreateMakesAReservedExpenseCategoryWithATrimmedUniqueName() throws {
        try manager().dbQueue.write { db in
            let reserve = try ReservedCategories.create(db: db, name: "  Remaining for expenses ")
            XCTAssertEqual(reserve.name, "Remaining for expenses")
            XCTAssertEqual(reserve.type, .expense)
            XCTAssertTrue(reserve.isReserved)
            XCTAssertFalse(reserve.isAssignable)
            XCTAssertThrowsError(try ReservedCategories.create(db: db, name: "Remaining for expenses")) {
                XCTAssertEqual($0 as? ReservedCategoryError, .duplicateName)
            }
            XCTAssertThrowsError(try ReservedCategories.create(db: db, name: "   ")) {
                XCTAssertEqual($0 as? ReservedCategoryError, .emptyName)
            }
        }
    }

    func testEnsureGroupIsIdempotentAndUserManaged() throws {
        try manager().dbQueue.write { db in
            let first = try ReservedCategories.ensureGroup(db: db)
            let second = try ReservedCategories.ensureGroup(db: db)
            XCTAssertEqual(first.id, second.id)
            XCTAssertEqual(first.name, "Reserved")
            XCTAssertTrue(first.isEnabled)
            XCTAssertFalse(first.isSystemManaged)
        }
    }

    func testDeleteRemovesTheReserveAndItsEntriesButRefusesOrdinaryCategories() throws {
        try manager().dbQueue.write { db in
            let reserve = try ReservedCategories.create(db: db, name: "Reserve")
            let group = try ReservedCategories.ensureGroup(db: db)
            var entry = ForecastEntry(groupId: group.id!, categoryId: reserve.id!, amountMinorUnits: -200_000, frequency: .monthly, interval: 1, startDate: utc(2026, 10, 1), endDate: nil, isEnabled: true, status: .confirmed, note: nil)
            try entry.insert(db)
            var ordinary = BudgetCore.Category(name: "Groceries", type: .expense)
            try ordinary.insert(db)

            try ReservedCategories.delete(db: db, categoryId: reserve.id!)
            XCTAssertNil(try BudgetCore.Category.fetchOne(db, key: reserve.id!))
            XCTAssertNil(try ForecastEntry.fetchOne(db, key: entry.id!))
            XCTAssertThrowsError(try ReservedCategories.delete(db: db, categoryId: ordinary.id!)) {
                XCTAssertEqual($0 as? ReservedCategoryError, .notReserved)
            }
        }
    }

    func testRenameChecksForDuplicates() throws {
        try manager().dbQueue.write { db in
            let reserve = try ReservedCategories.create(db: db, name: "Reserve")
            _ = try ReservedCategories.create(db: db, name: "Other reserve")
            try ReservedCategories.rename(db: db, categoryId: reserve.id!, to: "Day to day")
            XCTAssertEqual(try BudgetCore.Category.fetchOne(db, key: reserve.id!)?.name, "Day to day")
            XCTAssertThrowsError(try ReservedCategories.rename(db: db, categoryId: reserve.id!, to: "Other reserve")) {
                XCTAssertEqual($0 as? ReservedCategoryError, .duplicateName)
            }
        }
    }

    func testExcludingDeletesOnlyAutoEntries() throws {
        try manager().dbQueue.write { db in
            var category = BudgetCore.Category(name: "Confirmed other expenses", type: .expense)
            try category.insert(db)
            var group = ForecastGroup(name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)
            try group.insert(db)
            var auto = ForecastEntry(groupId: group.id!, categoryId: category.id!, amountMinorUnits: -17_139, frequency: .monthly, interval: 1, startDate: utc(2026, 2, 14), endDate: nil, isEnabled: true, status: .auto, note: nil)
            var manual = ForecastEntry(groupId: group.id!, categoryId: category.id!, amountMinorUnits: -5_000, frequency: .once, interval: 1, startDate: utc(2026, 11, 1), endDate: nil, isEnabled: true, status: .manual, note: nil)
            try auto.insert(db)
            try manual.insert(db)

            let deleted = try ReservedCategories.setExcludedFromAutoForecast(db: db, categoryId: category.id!, true)
            XCTAssertEqual(deleted, 1)
            XCTAssertTrue(try XCTUnwrap(BudgetCore.Category.fetchOne(db, key: category.id!)).excludeFromAutoForecast)
            XCTAssertNil(try ForecastEntry.fetchOne(db, key: auto.id!))
            XCTAssertNotNil(try ForecastEntry.fetchOne(db, key: manual.id!))

            XCTAssertEqual(try ReservedCategories.setExcludedFromAutoForecast(db: db, categoryId: category.id!, false), 0)
            XCTAssertFalse(try XCTUnwrap(BudgetCore.Category.fetchOne(db, key: category.id!)).excludeFromAutoForecast)
        }
    }

    func testTransactionsAndRulesCannotUseAReserve() throws {
        try manager().dbQueue.write { db in
            let reserve = try ReservedCategories.create(db: db, name: "Reserve")
            var ordinary = BudgetCore.Category(name: "Groceries", type: .expense)
            try ordinary.insert(db)
            var account = Account(name: "Current", currency: .gbp, kind: .cash, trackingMode: .manual)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "x.csv", importedAt: utc(2026, 10, 1))
            try batch.insert(db)

            var txn = Transaction(importBatchId: batch.id!, accountId: account.id!, date: utc(2026, 10, 1), rawDescription: "Shop", amountMinorUnits: -1_000, categoryId: reserve.id!, status: .confirmed, categorizedBy: .manual, fingerprint: "fp1")
            XCTAssertThrowsError(try txn.insert(db)) { error in
                XCTAssertTrue("\(error)".contains("Reserved categories can't hold transactions."))
            }
            txn.categoryId = ordinary.id!
            try txn.insert(db)
            txn.categoryId = reserve.id!
            XCTAssertThrowsError(try txn.update(db))

            var rule = Rule(matchPattern: "SHOP", matchType: .contains, categoryId: reserve.id!, priority: 0)
            XCTAssertThrowsError(try rule.insert(db))
            rule.categoryId = ordinary.id!
            try rule.insert(db)
            rule.categoryId = reserve.id!
            XCTAssertThrowsError(try rule.update(db))
        }
    }

    func testReserveAllowancesLowerTheNetWorthProjection() {
        let reserve = BudgetCore.Category(id: 1, name: "Remaining for expenses", type: .expense, isReserved: true)
        let group = ForecastGroup(id: 1, name: "Reserved", note: nil, isEnabled: true, isSystemManaged: false)
        let entry = ForecastEntry(id: 1, groupId: 1, categoryId: 1, amountMinorUnits: -200_000, frequency: .monthly, interval: 1, startDate: utc(2026, 10, 1), endDate: nil, isEnabled: true, status: .confirmed, note: nil)
        let november = PayPeriod(startDate: utc(2026, 11, 1), endDate: utc(2026, 11, 30), type: .projected)
        XCTAssertEqual(ForecastCalculator.confirmedNetWorthImpact(period: november, categories: [reserve], entries: [entry], groups: [group]), -200_000)
    }

    func testCountsAllowanceFromTheCurrentCalendarMonthOn() {
        let today = utc(2026, 10, 5)
        XCTAssertFalse(ReservedCategories.countsAllowance(year: 2026, month: 9, today: today))
        XCTAssertTrue(ReservedCategories.countsAllowance(year: 2026, month: 10, today: today))
        XCTAssertTrue(ReservedCategories.countsAllowance(year: 2027, month: 1, today: today))
        XCTAssertFalse(ReservedCategories.countsAllowance(year: 2025, month: 12, today: today))
    }
}
```

Add to `Tests/BudgetCoreTests/AutoForecastGeneratorTests.swift`, next to `testRegenerateLeavesCatchAllCategoryEntriesUntouched` (same helper `seededManagerWithRentHistory()`):

```swift
    // Reserves and categories excluded from the auto-forecast keep whatever entries they
    // have: the generator must neither delete, update nor add one.
    func testRegenerateSkipsReservedAndExcludedCategories() throws {
        let (manager, _, _, periods) = try seededManagerWithRentHistory()
        try manager.dbQueue.write { db in
            var reserve = Category(name: "Remaining for expenses", type: .expense, isReserved: true)
            var excluded = Category(name: "Groceries", type: .expense, excludeFromAutoForecast: true)
            try reserve.insert(db)
            try excluded.insert(db)
            let group = try AutoForecastGenerator.ensureDetectedRecurringGroup(db: db)
            for category in [reserve, excluded] {
                var entry = ForecastEntry(groupId: group.id!, categoryId: category.id!, amountMinorUnits: -17_139, frequency: .monthly, interval: 1, startDate: periods[0].startDate, endDate: nil, isEnabled: true, status: .auto, note: nil)
                try entry.insert(db)
            }

            try AutoForecastGenerator.regenerate(db: db, actualPeriods: periods)

            for category in [reserve, excluded] {
                let kept = try ForecastEntry.filter(Column("categoryId") == category.id!).fetchAll(db)
                XCTAssertEqual(kept.count, 1, category.name)
                XCTAssertEqual(kept[0].amountMinorUnits, -17_139, category.name)
                XCTAssertEqual(kept[0].status, .auto, category.name)
            }
        }
    }
```

In `Tests/BudgetCoreTests/CategorizationServiceTests.swift`, make `FakeCategorizer` record the candidates it is offered — add `private(set) var lastCandidateNames: [String]?` and set `lastCandidateNames = candidateCategoryNames` as the first line of both `suggestCategory` and `suggestCategories` — then add:

```swift
    func testReservedCategoriesAreNeverOfferedToTheModel() async {
        let reserve = Category(id: 3, name: "Remaining for expenses", type: .expense, isReserved: true)
        let fake = FakeCategorizer()
        let service = CategorizationService(categorizer: fake)

        _ = await service.categorize(description: "TESCO", rules: [], categories: [groceries, reserve])
        XCTAssertEqual(fake.lastCandidateNames, ["Groceries"])

        _ = await service.categorizeBatch(descriptions: ["TESCO", "ALDI"], rules: [], categories: [reserve, eatingOut])
        XCTAssertEqual(fake.lastCandidateNames, ["Eating Out"])
    }
```

- [ ] **Step 2: Run to verify they fail** — `swift test --filter ReservedCategoriesTests` → compile errors (`isReserved`, `ReservedCategories` not found).

- [ ] **Step 3: Implement.**

`Sources/BudgetCore/Models/Category.swift` — add the properties, init params and `isAssignable`:

```swift
    /// The one expense category that stands in for unplanned, never-itemised spending: its
    /// monthly allowance stays in the forecast and the auto-forecast never changes it.
    public var isCatchAll: Bool
    /// A forecast-only expense bucket for expected but uncategorised spending. It never
    /// holds transactions or rules (database triggers enforce this).
    public var isReserved: Bool
    /// The auto-forecast never creates, updates or deletes entries for this category
    /// (its spending is covered by a reserve, or its forecast is maintained by hand).
    public var excludeFromAutoForecast: Bool

    public init(id: Int64? = nil, name: String, type: CategoryType, groupId: Int64? = nil, isCatchAll: Bool = false, isReserved: Bool = false, excludeFromAutoForecast: Bool = false) {
        self.id = id
        self.name = name
        self.type = type
        self.groupId = groupId
        self.isCatchAll = isCatchAll
        self.isReserved = isReserved
        self.excludeFromAutoForecast = excludeFromAutoForecast
    }

    /// Whether transactions and rules may be filed into this category.
    public var isAssignable: Bool { !isReserved }
```

`Sources/BudgetCore/Models/Category+Migration.swift` — append:

```swift
func registerCategoryReservedMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addReservedCategoryFlags") { db in
        try db.alter(table: "category") { t in
            t.add(column: "isReserved", .boolean).notNull().defaults(to: false)
            t.add(column: "excludeFromAutoForecast", .boolean).notNull().defaults(to: false)
        }
        // A reserve is forecast-only: no transaction or rule may point at it.
        for table in ["transaction_", "rule"] {
            try db.execute(sql: """
                CREATE TRIGGER \(table)_reserved_insert BEFORE INSERT ON \(table)
                WHEN NEW.categoryId IS NOT NULL AND (SELECT isReserved FROM category WHERE id = NEW.categoryId) = 1
                BEGIN SELECT RAISE(ABORT, 'Reserved categories can''t hold transactions.'); END;
                CREATE TRIGGER \(table)_reserved_update BEFORE UPDATE OF categoryId ON \(table)
                WHEN NEW.categoryId IS NOT NULL AND (SELECT isReserved FROM category WHERE id = NEW.categoryId) = 1
                BEGIN SELECT RAISE(ABORT, 'Reserved categories can''t hold transactions.'); END;
                """)
        }
    }
}
```

`DatabaseManager.registerMigrations` — add `registerCategoryReservedMigration(&migrator)` as the **last** line.

`Sources/BudgetCore/Forecasting/ReservedCategories.swift`:

```swift
// Sources/BudgetCore/Forecasting/ReservedCategories.swift
import Foundation
import GRDB

public enum ReservedCategoryError: Error, Equatable {
    case emptyName
    case duplicateName
    case notReserved
}

/// Reserved categories: forecast-only expense buckets for expected but uncategorised
/// spending (e.g. the spreadsheet's "Remaining for expenses"). Their allowances are
/// ordinary forecast entries, kept in the "Reserved" group.
public enum ReservedCategories {
    public static let groupName = "Reserved"

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    public static func create(db: Database, name: String) throws -> Category {
        let trimmed = try validatedName(db: db, name)
        var category = Category(name: trimmed, type: .expense, isReserved: true)
        try category.insert(db)
        return category
    }

    @discardableResult
    public static func ensureGroup(db: Database) throws -> ForecastGroup {
        if let existing = try ForecastGroup.filter(Column("name") == groupName).fetchOne(db) {
            return existing
        }
        var group = ForecastGroup(name: groupName, note: "Allowances for expected but uncategorised spending", isEnabled: true, isSystemManaged: false)
        try group.insert(db)
        return group
    }

    public static func rename(db: Database, categoryId: Int64, to name: String) throws {
        var category = try reserve(db: db, categoryId)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != category.name else { return }
        category.name = try validatedName(db: db, name)
        try category.update(db, columns: ["name"])
    }

    /// Deletes the reserve and every forecast entry for it. Safe because a reserve never
    /// has transactions or rules.
    public static func delete(db: Database, categoryId: Int64) throws {
        let category = try reserve(db: db, categoryId)
        try ForecastEntry.filter(Column("categoryId") == categoryId).deleteAll(db)
        try category.delete(db)
    }

    /// Turning the flag on deletes the category's `.auto` entries (manual, confirmed and
    /// hypothetical entries are kept). Returns how many entries were deleted.
    @discardableResult
    public static func setExcludedFromAutoForecast(db: Database, categoryId: Int64, _ excluded: Bool) throws -> Int {
        try db.execute(sql: "UPDATE category SET excludeFromAutoForecast = ? WHERE id = ?", arguments: [excluded, categoryId])
        guard excluded else { return 0 }
        return try ForecastEntry
            .filter(Column("categoryId") == categoryId && Column("status") == ForecastEntryStatus.auto.rawValue)
            .deleteAll(db)
    }

    /// Grids (which have no blended month): a reserve's allowance counts from the current
    /// calendar month on; earlier months show nothing.
    public static func countsAllowance(year: Int, month: Int, today: Date) -> Bool {
        let now = MonthRange.components(of: today)
        return MonthRange.index(year: year, month: month) >= MonthRange.index(year: now.year, month: now.month)
    }

    private static func reserve(db: Database, _ categoryId: Int64) throws -> Category {
        guard let category = try Category.fetchOne(db, key: categoryId), category.isReserved else {
            throw ReservedCategoryError.notReserved
        }
        return category
    }

    private static func validatedName(db: Database, _ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ReservedCategoryError.emptyName }
        guard try Category.filter(Column("name") == trimmed).fetchCount(db) == 0 else {
            throw ReservedCategoryError.duplicateName
        }
        return trimmed
    }
}
```

`AutoForecastGenerator.regenerate` line 59 — replace the catch-all skip with:

```swift
            // Reserves and categories maintained by hand keep whatever entries the user has.
            if category.isCatchAll || category.isReserved || category.excludeFromAutoForecast { continue }
```

`CategorizationService` — at the start of both `categorize(description:rules:categories:)` and `categorizeBatch(descriptions:rules:categories:)` add `let categories = categories.filter(\.isAssignable)` (shadowing the parameter) with a one-line comment: `// Reserves are forecast-only; the model must never suggest one.`

- [ ] **Step 4: Verify** — `swift test --filter ReservedCategoriesTests`, `swift test --filter AutoForecastGeneratorTests`, `swift test --filter CategorizationServiceTests` → PASS; then `swift test` → all green; then the app build → `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/BudgetCore Tests/BudgetCoreTests
git commit -m "Add reserved and excluded-from-auto-forecast category flags

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Remove the catch-all

**Files:**
- Modify: `Sources/BudgetCore/Models/Category.swift`, `Sources/BudgetCore/Models/Category+Migration.swift`, `Sources/BudgetCore/Database/DatabaseManager.swift`
- Delete: `Sources/BudgetCore/Forecasting/CatchAllCategory.swift`, `Tests/BudgetCoreTests/CatchAllCategoryTests.swift`
- Modify: `Sources/BudgetCore/Forecasting/AutoForecastGenerator.swift`
- Modify: `Sources/BudgetCore/Dashboard/DashboardInput.swift`, `Sources/BudgetCore/Dashboard/DashboardCalculator.swift`
- Modify: `App/Categories/CategoriesView.swift`, `App/Dashboard/DashboardViewModel.swift`, `App/Dashboard/DashboardView.swift`, `App/Dashboard/CurrentMonthCard.swift`, `App/Dashboard/SmallCards.swift`
- Test: `Tests/BudgetCoreTests/DashboardFixture.swift`, `DashboardCalculatorTests.swift`, `DashboardFlowTests.swift`, `AutoForecastGeneratorTests.swift`, `ReservedCategoriesTests.swift`

**Interfaces:**
- Consumes (Task 1): `Category.isReserved`, `excludeFromAutoForecast`, `ReservedCategories.*`.
- Produces:
  - `Category` init becomes `Category(id:name:type:groupId:isReserved:excludeFromAutoForecast:)` (no `isCatchAll`).
  - `AttentionItems.missingReserveAllowance: Bool` replaces `catchAllIssue`. `CatchAllIssue`, `CatchAllAllowance` and `DashboardCalculator.catchAllAllowance` are removed.
  - `DashboardFixture.input(... reservedId: Int64? = nil)` replaces `catchAllId:` (the category with that id gets `isReserved: true`).

- [ ] **Step 1: Write the failing tests.**

In `ReservedCategoriesTests.swift` add this migration test. It migrates a fresh database only up to Task 1's migration, inserts rows that still have the old `isCatchAll` column, then finishes migrating:

```swift
    func testCatchAllMigrationCarriesTheFlagOverAndDropsTheColumn() throws {
        let manager = try DatabaseManager(path: nil)
        // Migrate up to (but not including) dropCatchAll, insert a catch-all row, then finish.
        try manager.migrate(upTo: "addReservedCategoryFlags")
        try manager.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO category (name, type, isCatchAll) VALUES ('Bulk other', 'expense', 1), ('Rent', 'expense', 0)")
        }
        try manager.migrate()
        try manager.dbQueue.read { db in
            let columns = try db.columns(in: "category").map(\.name)
            XCTAssertFalse(columns.contains("isCatchAll"))
            let bulk = try XCTUnwrap(BudgetCore.Category.filter(Column("name") == "Bulk other").fetchOne(db))
            let rent = try XCTUnwrap(BudgetCore.Category.filter(Column("name") == "Rent").fetchOne(db))
            XCTAssertTrue(bulk.excludeFromAutoForecast)
            XCTAssertFalse(rent.excludeFromAutoForecast)
        }
    }
```

This needs a small test hook on `DatabaseManager` (add it in Step 3):

```swift
    /// Tests only: runs migrations up to and including `target`.
    func migrate(upTo target: String) throws {
        var migrator = DatabaseMigrator()
        registerMigrations(&migrator)
        try migrator.migrate(dbQueue, upTo: target)
    }
```

In `DashboardFixture.swift`: rename the `catchAllId` parameter to `reservedId`, drop every `isCatchAll:` argument, and give the matching category `isReserved: reservedId == <id>` (only `groceriesId`, `diningId` and `bulkId` rows need the expression; salary/rent/savings stay plain).

In `DashboardCalculatorTests.swift` replace `testCatchAllIssueStates` and `testCatchAllAllowanceIsThePositiveMonthlyAmount` with:

```swift
    func testMissingReserveAllowance() {
        let today = date(2026, 10, 2)
        let bulk = ForecastEntry(id: 9, groupId: 1, categoryId: F.bulkId, amountMinorUnits: -200_000, frequency: .monthly, interval: 1, startDate: date(2026, 10, 1), endDate: nil, isEnabled: true, status: .confirmed, note: nil)
        // No reserve at all.
        XCTAssertTrue(DashboardCalculator.attentionItems(F.input(today: today)).missingReserveAllowance)
        // A reserve with no allowance.
        XCTAssertTrue(DashboardCalculator.attentionItems(F.input(today: today, reservedId: F.bulkId)).missingReserveAllowance)
        // A reserve whose allowance covers this month.
        XCTAssertFalse(DashboardCalculator.attentionItems(F.input(today: today, entries: F.withDining + [bulk], reservedId: F.bulkId)).missingReserveAllowance)
        // An allowance that ended before this month doesn't count.
        var ended = bulk; ended.startDate = date(2026, 1, 1); ended.endDate = date(2026, 3, 31)
        XCTAssertTrue(DashboardCalculator.attentionItems(F.input(today: today, entries: F.withDining + [ended], reservedId: F.bulkId)).missingReserveAllowance)
    }
```

In `DashboardFlowTests.swift` `testBulkAllowanceCountsInFullEvenWithNoActuals`: change `catchAllId: F.bulkId` to `reservedId: F.bulkId` (expectation unchanged: 172_139).

In `AutoForecastGeneratorTests.swift` delete `testRegenerateLeavesCatchAllCategoryEntriesUntouched` (Task 1's reserved/excluded test covers it).

- [ ] **Step 2: Run to verify they fail** — `swift test --filter DashboardCalculatorTests` → compile errors (`reservedId`, `missingReserveAllowance`).

- [ ] **Step 3: Implement.**

`Category.swift` — remove `isCatchAll` (property, init parameter, assignment, doc comment).

`Category+Migration.swift` — keep `registerCategoryCatchAllMigration` (old databases need it in order) and append:

```swift
func registerCategoryDropCatchAllMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("dropCatchAll") { db in
        // The catch-all's job ("keep my allowance; never auto-forecast me") is now
        // `excludeFromAutoForecast`; reserves replace the single bulk allowance.
        try db.execute(sql: "UPDATE category SET excludeFromAutoForecast = 1 WHERE isCatchAll = 1")
        try db.alter(table: "category") { t in t.drop(column: "isCatchAll") }
    }
}
```

`DatabaseManager.registerMigrations` — add `registerCategoryDropCatchAllMigration(&migrator)` after `registerCategoryReservedMigration(&migrator)`; add the `migrate(upTo:)` test hook (internal, so `@testable import` sees it).

Delete `CatchAllCategory.swift` and `CatchAllCategoryTests.swift`. In `AutoForecastGenerator` drop `category.isCatchAll ||` from the skip.

`DashboardInput.swift` — delete `CatchAllIssue` and `CatchAllAllowance`; in `AttentionItems` replace `catchAllIssue` with:

```swift
    /// No reserved category has a confirmed allowance for the current month, so unplanned
    /// spending isn't being projected.
    public let missingReserveAllowance: Bool
```

`DashboardCalculator.attentionItems` — replace the catch-all block with:

```swift
        let parts = MonthRange.components(of: input.effectiveToday)
        let range = MonthRange.of(year: parts.year, month: parts.month)
        let thisMonth = PayPeriod(startDate: range.start, endDate: range.end, type: .projected)
        let hasReserveAllowance = input.categories.contains { category in
            guard category.isReserved, let id = category.id else { return false }
            return ForecastCalculator.confirmedTotal(categoryId: id, period: thisMonth, entries: input.forecastEntries, groups: input.forecastGroups) != 0
        }
        return AttentionItems(uncategorizedCount: uncategorized, staleBalanceCount: staleCount, oldestStaleSnapshotDate: oldest, missingReserveAllowance: !hasReserveAllowance)
```

Delete `catchAllAllowance(_:)`.

App:
- `DashboardViewModel.swift`: remove the `catchAll` field from the content struct and its `catchAllAllowance` assignment.
- `DashboardView.swift:40`: `CurrentMonthCard(month: content.currentMonth, navigate: navigate)`.
- `CurrentMonthCard.swift`: remove `catchAll` and the sentence appended in `unreviewedFootnote` (Task 4 adds the reserve wording).
- `SmallCards.swift` `AttentionCard`: replace the `switch items.catchAllIssue` with:

```swift
            if items.missingReserveAllowance {
                row(warning: true, "No reserve for unplanned spending in the forecast", link: "Forecast") { navigate(.forecast) }
            }
```

- `CategoriesView.swift`: replace `setCatchAll` with

```swift
    /// "Covered by a reserve": the auto-forecast leaves this category alone (and its
    /// existing auto entries are removed when turning this on).
    func setExcludedFromAutoForecast(_ category: Category, excluded: Bool) throws {
        guard let id = category.id else { return }
        try dbQueue.write { db in try ReservedCategories.setExcludedFromAutoForecast(db: db, categoryId: id, excluded) }
        try load()
    }
```

  make `load()` read `Category.filter(Column("isReserved") == false).fetchAll(db)` (reserves are managed on the Forecast screen), and replace the toggle with:

```swift
                    if category.type == .expense {
                        Toggle("Exclude from auto-forecast", isOn: Binding(
                            get: { category.excludeFromAutoForecast },
                            set: { newValue in try? viewModel.setExcludedFromAutoForecast(category, excluded: newValue) }
                        ))
                        .toggleStyle(.checkbox)
                        .help("Covered by a reserve — the forecast won't detect a recurring amount for it.")
                    }
```

- [ ] **Step 4: Verify** — `grep -rn "isCatchAll\|CatchAll\|catchAll" Sources App Tests` → only the historical `registerCategoryCatchAllMigration`/`addIsCatchAllToCategory`/`dropCatchAll` migration code and comments; `swift test` → all green; app build → `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit** — `git add -A Sources App Tests && git commit -m "Replace the catch-all category with reserves and the auto-forecast exclusion flag" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 3: Dashboard figures — reserves as their own figure

**Files:**
- Modify: `Sources/BudgetCore/Dashboard/DashboardCalculator+Flows.swift`
- Test: `Tests/BudgetCoreTests/DashboardFlowTests.swift`

**Interfaces:**
- Consumes: `Category.isReserved`, `DashboardFixture.input(... reservedId:)` (Task 2).
- Produces:
  - `CurrentMonthTracking.reservedProjected: Int` — positive magnitude of the reserves' projected spend this month; **already included** in `expenses.projected` and `expenses.expected`.
  - `MonthlyFlow.reservedRemaining: Int` — positive magnitude; the part of `expenseRemaining` that comes from reserves (always ≤ `expenseRemaining`).
  - `topCategories` never returns a reserve.

- [ ] **Step 1: Write the failing tests** — add to `DashboardFlowTests`:

```swift
    private var bulkReserve: ForecastEntry {
        ForecastEntry(id: 9, groupId: 1, categoryId: F.bulkId, amountMinorUnits: -200_000, frequency: .monthly, interval: 1, startDate: date(2026, 1, 1), endDate: nil, isEnabled: true, status: .confirmed, note: nil)
    }

    func testCurrentMonthReportsTheReserveSeparatelyAndInsideExpenses() {
        let input = F.input(today: date(2026, 10, 14), transactions: [F.txn(1, date(2026, 10, 13), -55_000, category: F.diningId)], entries: F.withDining + [bulkReserve], reservedId: F.bulkId)
        let month = DashboardCalculator.currentMonth(input)
        XCTAssertEqual(month.monthClass, .blended)
        XCTAssertEqual(month.reservedProjected, 200_000)
        // 100k rent + max(55k actual, 40k expected) dining + 200k reserve.
        XCTAssertEqual(month.expenses.projected, 355_000)
    }

    func testReserveIsZeroInActualMonthsAndRemainingInBlendedAndForecastMonths() {
        let input = F.input(today: date(2026, 10, 14), transactions: [F.txn(1, date(2026, 9, 3), -1_000, category: F.diningId), F.txn(2, date(2026, 10, 13), -55_000, category: F.diningId)], entries: F.withDining + [bulkReserve], reservedId: F.bulkId)
        let flows = DashboardCalculator.monthlyFlows(input, year: 2026)
        XCTAssertEqual(flows[8].monthClass, .actual)     // September
        XCTAssertEqual(flows[8].reservedRemaining, 0)
        XCTAssertEqual(flows[9].monthClass, .blended)    // October
        XCTAssertEqual(flows[9].reservedRemaining, 200_000)
        XCTAssertEqual(flows[10].monthClass, .forecast)  // November
        XCTAssertEqual(flows[10].reservedRemaining, 200_000)
        XCTAssertGreaterThanOrEqual(flows[10].expenseRemaining, flows[10].reservedRemaining)
    }

    func testTopCategoriesLeavesReservesOut() {
        let input = F.input(today: date(2026, 10, 14), transactions: [F.txn(1, date(2026, 10, 13), -55_000, category: F.diningId)], entries: F.withDining + [bulkReserve], reservedId: F.bulkId)
        XCTAssertFalse(DashboardCalculator.topCategories(input).contains { $0.name == "Bulk other" })
    }
```

- [ ] **Step 2: Run to verify they fail** — `swift test --filter DashboardFlowTests` → "no member 'reservedProjected'".

- [ ] **Step 3: Implement** in `DashboardCalculator+Flows.swift`:
  - `CurrentMonthTracking`: add `public let reservedProjected: Int` after `expenses` with the doc comment from the Interfaces block.
  - `MonthlyFlow`: add `public let reservedRemaining: Int` after `expenseRemaining`, doc comment as above.
  - `MonthTotals`: add `var reservedProjected = 0`; in `monthTotals`, inside `case .expense:` after the existing line add `if category.isReserved { totals.reservedProjected -= projected }`.
  - `currentMonth`: pass `reservedProjected: totals.reservedProjected`.
  - `monthlyFlows`: compute `let expenseRemaining = max(totals.expenses.projected - totals.expenses.actual, 0)` and pass `expenseRemaining: expenseRemaining, reservedRemaining: min(totals.reservedProjected, expenseRemaining)`.
  - `topCategories`: change the guard to `guard category.type == .expense, !category.isReserved else { return }`.
  - Fix any other `MonthlyFlow(`/`CurrentMonthTracking(` construction the compiler reports (tests or previews) by adding the new argument.

- [ ] **Step 4: Verify** — `swift test --filter DashboardFlowTests` → PASS; `swift test` → all green.

- [ ] **Step 5: Commit** — `git add Sources Tests && git commit -m "Report reserves as their own dashboard figure" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 4: Dashboard UI — Reserved line and chart segment

**Files:**
- Modify: `App/Dashboard/CurrentMonthCard.swift`, `App/Dashboard/YearAtAGlanceChart.swift`, `App/Dashboard/YearAtAGlanceCard.swift`

**Interfaces:**
- Consumes (Task 3): `CurrentMonthTracking.reservedProjected`, `MonthlyFlow.reservedRemaining`.

- [ ] **Step 1: Current month card.** After `row("Expenses", …)` add, only when `month.reservedProjected > 0`:

```swift
            if month.reservedProjected > 0 {
                HStack {
                    Text("of which reserved").font(.caption)
                    Spacer()
                    Text(DashboardFormat.pounds(month.reservedProjected)).font(.caption).monospacedDigit()
                }
                .foregroundStyle(.secondary)
                .help("Allowance for expected but uncategorised spending (Forecast › Reserved). Counted in full every month.")
            }
```

  and in `unreviewedFootnote`, after the count sentence: `if month.reservedProjected > 0 { text += " Your reserves (\(DashboardFormat.pounds(month.reservedProjected)) this month) stand in for unplanned spending." }`.

- [ ] **Step 2: Year-at-a-glance chart.** Split the hatched expense bar: replace the `if flow.expenseRemaining > 0 { … }` block with

```swift
                let otherRemaining = flow.expenseRemaining - flow.reservedRemaining
                if otherRemaining > 0 {
                    BarMark(x: .value("Month", name(flow)), y: .value("Expenses", pounds(otherRemaining)))
                        .position(by: .value("Type", "Expenses"))
                        .foregroundStyle(HatchPattern.style(.orange))
                }
                if flow.reservedRemaining > 0 {
                    BarMark(x: .value("Month", name(flow)), y: .value("Expenses", pounds(flow.reservedRemaining)))
                        .position(by: .value("Type", "Expenses"))
                        .foregroundStyle(HatchPattern.style(.purple))
                }
```

  and update the accessibility label to "Monthly income, expenses (with reserves) and net for the selected year, actual and forecast".

- [ ] **Step 3: Legend.** In `YearAtAGlanceCard`, after the Expenses label add `Label("Reserved", systemImage: "square.fill").foregroundStyle(.purple)`.

- [ ] **Step 4: Verify** — app build → `** BUILD SUCCEEDED **`; `swift test` still green.

- [ ] **Step 5: Commit** — `git add App/Dashboard && git commit -m "Show reserves on the dashboard current-month card and year chart" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 5: Forecast screen — Reserved section and reserve management

**Files:**
- Modify: `App/Forecast/ForecastViewModel.swift`, `App/Forecast/ForecastView.swift`

**Interfaces:**
- Consumes (Task 1): `ReservedCategories.create/ensureGroup/rename/delete/countsAllowance`, `ReservedCategoryError`.
- Produces (ForecastViewModel):
  - `var reserves: [Category]` — `categories.filter(\.isReserved)` sorted by name.
  - `func reserveEntries(_ reserve: Category) -> [ForecastEntry]`
  - `func reserveTotal(year: Int, month: Int, preview: Bool) -> Int` — sum over `reserves` of `categoryTotal`/`previewCategoryTotal`.
  - `@discardableResult func addReserve(name: String, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date?) -> Bool`
  - `@discardableResult func addReserveAmount(to reserve: Category, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date?) -> Bool`
  - `@discardableResult func renameReserve(_ reserve: Category, to name: String) -> Bool`
  - `@discardableResult func deleteReserve(_ reserve: Category) -> Bool`

- [ ] **Step 1: View model — month rule.** In `categoryTotal` and `previewCategoryTotal`, before the `isActual` check, add:

```swift
        if category.isReserved {
            // Reserves are forecast-only: nothing before the current calendar month,
            // the allowance from this month on (even if the month already has actuals).
            guard ReservedCategories.countsAllowance(year: year, month: month, today: Date()) else { return 0 }
            return forecastValue(category, year: year, month: month, preview: <false|true>)
        }
```

  and extract the existing non-actual branch of each into one private helper so it isn't duplicated:

```swift
    private func forecastValue(_ category: Category, year: Int, month: Int, preview: Bool) -> Int {
        guard let categoryId = category.id else { return 0 }
        if let cached = forecastTotalsCache[categoryId]?[year]?[month] { return preview ? cached.preview : cached.confirmed }
        let range = dateRange(forYear: year, month: month)
        let period = PayPeriod(startDate: range.start, endDate: range.end, type: .projected)
        return preview
            ? ForecastCalculator.previewTotal(categoryId: categoryId, period: period, entries: entries, groups: groups, selectedScenarioGroupId: selectedScenarioGroupId)
            : ForecastCalculator.confirmedTotal(categoryId: categoryId, period: period, entries: entries, groups: groups)
    }
```

  (`categoryTotal` non-actual path becomes `return forecastValue(category, year: year, month: month, preview: false)`; `previewCategoryTotal` likewise with `true`.)

- [ ] **Step 2: View model — mutations.** Add the Produces members. Pattern for each (write-first, reload on success, `errorMessage` on failure — like `createScenario`):

```swift
    var reserves: [Category] { categories.filter(\.isReserved).sorted { $0.name < $1.name } }

    func reserveEntries(_ reserve: Category) -> [ForecastEntry] {
        entries.filter { $0.categoryId == reserve.id }.sorted { $0.startDate < $1.startDate }
    }

    func reserveTotal(year: Int, month: Int, preview: Bool) -> Int {
        reserves.reduce(0) { $0 + (preview ? previewCategoryTotal($1, year: year, month: month) : categoryTotal($1, year: year, month: month)) }
    }

    @discardableResult
    func addReserve(name: String, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date?) -> Bool {
        errorMessage = nil
        do {
            try dbQueue.write { db in
                let reserve = try ReservedCategories.create(db: db, name: name)
                let group = try ReservedCategories.ensureGroup(db: db)
                var entry = ForecastEntry(groupId: group.id!, categoryId: reserve.id!, amountMinorUnits: -abs(amountMinorUnits), frequency: frequency, interval: interval, startDate: startDate, endDate: endDate, isEnabled: true, status: .confirmed, note: nil)
                try entry.insert(db)
            }
        } catch ReservedCategoryError.duplicateName {
            errorMessage = "A category with that name already exists."
            return false
        } catch {
            errorMessage = "Couldn't add this reserve: \(error.localizedDescription)"
            return false
        }
        try? load()
        return true
    }
```

  `addReserveAmount` inserts the same kind of entry for an existing reserve (`ensureGroup`, `-abs(amount)`, `.confirmed`). `renameReserve` calls `ReservedCategories.rename` (map `.duplicateName` to the same message, `.emptyName` to "Enter a name."). `deleteReserve` calls `ReservedCategories.delete`. Each reloads with `try? load()` on success. Note `load()` resets `selectedScenarioGroupId`; that is acceptable for these rare actions.

- [ ] **Step 3: View — sections.** In `ForecastView`:
  - `categoriesByType` → `viewModel.categories.filter { $0.type == type && !$0.isReserved }`.
  - Add row kinds `case reservedHeader`, `case reserve(Category)`, `case reservedTotal` with ids `"reserved-header"`, `"reserve-\(id)"`, `"reserved-total"`.
  - `allRows`: insert after the Expenses section:

```swift
        var reservedRows: [ForecastRow] = [ForecastRow(kind: .reservedHeader, shaded: false)]
        for (index, reserve) in viewModel.reserves.enumerated() {
            reservedRows.append(ForecastRow(kind: .reserve(reserve), shaded: index % 2 == 1))
        }
        if !viewModel.reserves.isEmpty { reservedRows.append(ForecastRow(kind: .reservedTotal, shaded: false)) }
        return section("Income", .income) + section("Expenses", .expense) + reservedRows + section("Transfers", .transfer)
```

  - `rowLabel`:
    - `.reservedHeader`: same style as `.sectionHeader("RESERVED")` plus a trailing `Button { reserveSheet = .newReserve } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("Add reserve…")`.
    - `.reserve(let reserve)`: same as `.category` but the leading stripe is `.purple`, and a `.contextMenu`:

```swift
            .contextMenu {
                ForEach(viewModel.reserveEntries(reserve)) { entry in
                    Button("Edit \(Self.frequencyLabel(entry)) allowance…") { editingEntry = entry }
                }
                Button("Add amount…") { reserveSheet = .addAmount(reserve) }
                Button("Rename…") { renamingReserve = reserve; renameText = reserve.name }
                Divider()
                Button("Delete reserve…", role: .destructive) { deletingReserve = reserve }
            }
```

    - `.reservedTotal`: bold "Total reserved", purple stripe, same height as a category row.
  - `rowCells`:
    - `.reservedHeader`: same as `.sectionHeader` cells.
    - `.reserve(let reserve)`: identical to the `.category` branch (it already reads `categoryTotal`/`previewCategoryTotal`, which apply the reserve rule) — repeat the body, as the `.groupChild` branch does, and use `isTwoLine(reserve, year:)`.
    - `.reservedTotal`: per month `forecastCell(confirmed: viewModel.reserveTotal(year:month:preview: false), preview: viewModel.reserveTotal(year:month:preview: true), twoLine: <any reserve isTwoLine>, bold: true)`, plus the year total cell, with `.background(Color.purple.opacity(0.08))`.
  - State: `@State private var reserveSheet: ReserveSheet?` where `enum ReserveSheet: Identifiable { case newReserve; case addAmount(Category); var id: String {…} }`; `@State private var renamingReserve: Category?`, `@State private var renameText = ""`, `@State private var deletingReserve: Category?`.
  - Sheets/alerts:
    - `.sheet(item: $reserveSheet)` → `ReserveFormView(mode:) { name, amount, frequency, interval, start, end in … }` calling `addReserve` or `addReserveAmount`; dismiss (`reserveSheet = nil`) only when it returns `true`.
    - `.alert("Rename reserve", isPresented: <renamingReserve != nil>)` with a `TextField` bound to `renameText` and Save → `renameReserve`.
    - `.confirmationDialog("Delete “\(name)”? Its allowances are removed from the forecast.", isPresented: <deletingReserve != nil>)` → `deleteReserve`.
  - Show `viewModel.errorMessage` (if the view doesn't already) as a red caption above the grid.

- [ ] **Step 4: `ReserveFormView`** (same file, after `EditForecastEntryView`), modelled on `ScenarioItemFormView` minus the category picker:

```swift
struct ReserveFormView: View {
    enum Mode { case newReserve; case addAmount(Category) }
    let mode: Mode
    let onSave: (_ name: String, _ amountMinorUnits: Int, ForecastFrequency, Int, Date, Date?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var amountPounds = ""
    @State private var frequency: ForecastFrequency = .monthly
    @State private var interval = 1
    @State private var startDate = Date()
    @State private var hasEndDate = false
    @State private var endDate = Date()

    var body: some View {
        Form {
            switch mode {
            case .newReserve:
                TextField("Reserve name", text: $name)
                Text("A forecast-only allowance for spending you expect but don't plan line by line. It never holds transactions.")
                    .font(.caption).foregroundStyle(.secondary)
            case .addAmount(let reserve):
                Text("Add an amount to \(reserve.name)").font(.headline)
            }
            TextField("Amount (£, positive number)", text: $amountPounds)
            Picker("Frequency", selection: $frequency) {
                ForEach(ForecastFrequency.allCases, id: \.self) { freq in Text(freq.rawValue).tag(freq) }
            }
            Stepper("Every \(interval) \(frequency.rawValue)", value: $interval, in: 1...12)
            DatePicker("Starting", selection: $startDate, displayedComponents: .date)
            Toggle("Ends on a specific date", isOn: $hasEndDate)
            if hasEndDate { DatePicker("Ends", selection: $endDate, displayedComponents: .date) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    guard let minorUnits = Money.parseMinorUnits(amountPounds), minorUnits != 0 else { return }
                    onSave(name, -abs(minorUnits), frequency, interval, ForecastView.normalizedStartOfDay(startDate), hasEndDate ? ForecastView.normalizedEndOfDay(endDate) : nil)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
```

- [ ] **Step 5: Scenario picker.** In `ScenarioItemFormView`'s category `Picker`, list `viewModel.categories.filter { !$0.isReserved }` first, then `if !viewModel.reserves.isEmpty { Section("Reserved") { ForEach(viewModel.reserves) { … tag … } } }`, then "+ New category…". (Scenario items create forecast entries, so reserves are valid here.)

- [ ] **Step 6: Verify** — app build → `** BUILD SUCCEEDED **`. Run the app against a scratch copy of the database (`cp "$HOME/Library/Application Support/Budget/budget.sqlite" /tmp/budget-task5.sqlite`, then launch the built binary `…/Budget.app/Contents/MacOS/Budget` with `BUDGET_DB_PATH=/tmp/budget-task5.sqlite`; quit any running Budget first). On Forecast: add reserve "Test reserve" £100/month from today; check the Reserved section shows "—" before this month and −£100.00 from this month, the Total reserved row, the context menu actions, and that the Dec net-worth headline drops by £100 × remaining months. Screenshot for the reviewer.

- [ ] **Step 7: Commit** — `git add App/Forecast && git commit -m "Add the Reserved section and reserve management to the Forecast screen" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 6: Budget grid Reserved section; keep reserves out of every transaction picker

**Files:**
- Modify: `App/Budget/BudgetGridViewModel.swift`, `App/Budget/BudgetGridView.swift`
- Modify: `App/Import/ReviewView.swift:218`, `App/Uncategorized/UncategorizedView.swift:63`, `App/Rules/RulesView.swift:27`, `App/Budget/GridDrillDownSheet.swift:61`

**Interfaces:**
- Consumes: `Category.isReserved`, `Category.isAssignable`, `ReservedCategories.countsAllowance`, `ForecastCalculator.confirmedTotal`.
- Produces (BudgetGridViewModel): `var reserves: [Category]`, `func reserveTotal(_ reserve: Category, year: Int, month: Int) -> Int`.

- [ ] **Step 1: View model.**

```swift
    var reserves: [Category] { categories.filter(\.isReserved).sorted { $0.name < $1.name } }

    /// Reserves are forecast-only, so the grid shows their confirmed allowance from the
    /// current calendar month on and nothing before it.
    func reserveTotal(_ reserve: Category, year: Int, month: Int) -> Int {
        guard let id = reserve.id, ReservedCategories.countsAllowance(year: year, month: month, today: Date()) else { return 0 }
        let range = dateRange(forYear: year, month: month)
        return ForecastCalculator.confirmedTotal(categoryId: id, period: PayPeriod(startDate: range.start, endDate: range.end, type: .projected), entries: forecastEntries, groups: forecastGroups)
    }
```

- [ ] **Step 2: View.** In `BudgetGridView`:
  - `categoriesByType` → also `&& !$0.isReserved`.
  - Add row kinds `.reservedHeader`, `.reserve(Category)`, `.reservedTotal` (ids as in Task 5); in `allRows` insert after the Expenses section (header always; rows and total only when `!viewModel.reserves.isEmpty`; when empty, the header row's label reads "RESERVED — add reserves on the Forecast screen").
  - Labels: like `.category`, purple leading stripe; total row bold "Total reserved".
  - Cells: `calendarCell(viewModel.reserveTotal(reserve, year:month:))` per month and the year sum; **no** `onTapGesture` (no drill-down). Total row sums `viewModel.reserves`.
  - Export (line 202): pass `viewModel.categories.filter { !$0.isReserved }`.

- [ ] **Step 3: Pickers.** Change each `ForEach(categories)` / `ForEach(viewModel.categories)` in the four files listed to `ForEach(<same>.filter(\.isAssignable))`. Also check `UncategorizedViewModel` and `RulesViewModel` for any other place a category list is offered (e.g. a default selection) and filter there too.

- [ ] **Step 4: Verify** — app build → `** BUILD SUCCEEDED **`. Run the app on a scratch DB copy with a reserve added (as in Task 5): Budget grid shows the Reserved section with "—" before this month and the allowance from this month; tapping a reserve cell does nothing; the reserve is absent from the Uncategorized, Rules, drill-down and Review pickers. Screenshot.

- [ ] **Step 5: Commit** — `git add App && git commit -m "Show reserves in the Budget grid and keep them out of category pickers" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 7: `ForecastPlanSeeder`

**Files:**
- Create: `Sources/BudgetCore/Forecasting/ForecastPlanSeeder.swift`
- Test: `Tests/BudgetCoreTests/ForecastPlanSeederTests.swift`

**Interfaces:**
- Consumes: `ReservedCategories.create/ensureGroup/setExcludedFromAutoForecast`.
- Produces:
  - `ForecastPlanSeederError: Error, Equatable { case missingCategories([String]); case nameTakenByOrdinaryCategory(String) }`
  - `ForecastPlanSeeder.reserveName` (= "Remaining for expenses"), `.planGroupName` (= "Spreadsheet plan"), `.note` (= "From spreadsheet plan"), `.requiredCategoryNames: [String]`
  - `ForecastPlanSeeder.apply(db: Database) throws -> [String]` — one human-readable line per change; empty when nothing changed. Throws before writing anything if a name is missing.

- [ ] **Step 1: Write the failing tests:**

```swift
// Tests/BudgetCoreTests/ForecastPlanSeederTests.swift
import XCTest
import GRDB
@testable import BudgetCore

final class ForecastPlanSeederTests: XCTestCase {
    private static let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    private func month(_ y: Int, _ m: Int) -> Date { Self.utc.date(from: DateComponents(year: y, month: m, day: 1))! }

    /// The real category names, with the real types (UK Taxes and Accountant start as
    /// transfers), plus the auto entries the real database has.
    private func fixture() throws -> DatabaseManager {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in
            let transfers: Set<String> = ["Transfer: Lloyds Joint", "UK Taxes", "Accountant"]
            for name in ForecastPlanSeeder.requiredCategoryNames {
                var category = BudgetCore.Category(name: name, type: transfers.contains(name) ? .transfer : .expense)
                try category.insert(db)
            }
            var detected = ForecastGroup(name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)
            try detected.insert(db)
            func auto(_ name: String, _ amount: Int, _ frequency: ForecastFrequency, _ interval: Int) throws {
                let id = try XCTUnwrap(BudgetCore.Category.filter(Column("name") == name).fetchOne(db)?.id)
                var entry = ForecastEntry(groupId: detected.id!, categoryId: id, amountMinorUnits: amount, frequency: frequency, interval: interval, startDate: month(2026, 2), endDate: nil, isEnabled: true, status: .auto, note: nil)
                try entry.insert(db)
            }
            try auto("Rent", -217_108, .monthly, 1)
            try auto("TV License", -17_450, .annually, 1)
            try auto("Thames Water", -32_441, .monthly, 6)
            try auto("Confirmed other expenses", -17_139, .monthly, 1)
            try auto("House Decor / Move Expenses", -6_025, .monthly, 2)
        }
        return manager
    }

    private func category(_ db: Database, _ name: String) throws -> BudgetCore.Category {
        try XCTUnwrap(BudgetCore.Category.filter(Column("name") == name).fetchOne(db))
    }
    private func entries(_ db: Database, _ name: String) throws -> [ForecastEntry] {
        try ForecastEntry.filter(Column("categoryId") == category(db, name).id!).fetchAll(db)
    }

    func testSeedsTheReserve() throws {
        try fixture().dbQueue.write { db in
            _ = try ForecastPlanSeeder.apply(db: db)
            let reserve = try category(db, "Remaining for expenses")
            XCTAssertTrue(reserve.isReserved)
            let entry = try XCTUnwrap(entries(db, "Remaining for expenses").first)
            XCTAssertEqual(entry.amountMinorUnits, -200_000)
            XCTAssertEqual(entry.frequency, .monthly)
            XCTAssertEqual(entry.startDate, month(2026, 10))
            XCTAssertEqual(entry.status, .confirmed)
            XCTAssertEqual(try ForecastGroup.fetchOne(db, key: entry.groupId)?.name, "Reserved")
        }
    }

    func testCoveredCategoriesAreExcludedAndLoseTheirAutoEntries() throws {
        try fixture().dbQueue.write { db in
            _ = try ForecastPlanSeeder.apply(db: db)
            for name in ["Groceries", "Confirmed other expenses", "House Decor / Move Expenses", "Confirmed other SIGNIFICANT expenses"] {
                XCTAssertTrue(try category(db, name).excludeFromAutoForecast, name)
            }
            XCTAssertTrue(try entries(db, "Confirmed other expenses").isEmpty)
            XCTAssertTrue(try entries(db, "House Decor / Move Expenses").isEmpty)
        }
    }

    func testPlannedItemsAreAddedAndExcludedFromAutoForecast() throws {
        try fixture().dbQueue.write { db in
            _ = try ForecastPlanSeeder.apply(db: db)
            let expected: [(String, Int, ForecastFrequency, Int, Date)] = [
                ("Car Payments", -35_125, .monthly, 1, month(2026, 10)),
                ("Council Tax", -35_000, .monthly, 1, month(2026, 10)),
                ("Transfer: Lloyds Joint", -200_000, .monthly, 1, month(2026, 10)),
                ("UK Taxes", -320_000, .annually, 1, month(2026, 12)),
                ("Accountant", -72_000, .annually, 1, month(2026, 12)),
                ("Car Insurance", -120_000, .annually, 1, month(2027, 5)),
                ("Car Service", -100_000, .annually, 1, month(2027, 5)),
                ("Car MOT", -15_000, .annually, 1, month(2027, 8)),
                ("Car Tax", -19_500, .annually, 1, month(2027, 1))
            ]
            for (name, amount, frequency, interval, start) in expected {
                let all = try entries(db, name)
                XCTAssertEqual(all.count, 1, name)
                let entry = try XCTUnwrap(all.first)
                XCTAssertEqual(entry.amountMinorUnits, amount, name)
                XCTAssertEqual(entry.frequency, frequency, name)
                XCTAssertEqual(entry.interval, interval, name)
                XCTAssertEqual(entry.startDate, start, name)
                XCTAssertEqual(entry.status, .confirmed, name)
                XCTAssertEqual(entry.note, "From spreadsheet plan", name)
                XCTAssertEqual(try ForecastGroup.fetchOne(db, key: entry.groupId)?.name, "Spreadsheet plan", name)
                XCTAssertTrue(try category(db, name).excludeFromAutoForecast, name)
            }
        }
    }

    func testTaxesAndAccountantBecomeExpenses() throws {
        try fixture().dbQueue.write { db in
            _ = try ForecastPlanSeeder.apply(db: db)
            XCTAssertEqual(try category(db, "UK Taxes").type, .expense)
            XCTAssertEqual(try category(db, "Accountant").type, .expense)
            XCTAssertEqual(try category(db, "Transfer: Lloyds Joint").type, .transfer)
        }
    }

    func testCorrectionsUpdateTheAutoEntriesInPlaceAndMakeThemManual() throws {
        try fixture().dbQueue.write { db in
            _ = try ForecastPlanSeeder.apply(db: db)
            let expected: [(String, Int, ForecastFrequency, Int, Date)] = [
                ("Rent", -290_000, .monthly, 1, month(2026, 10)),
                ("TV License", -18_000, .annually, 1, month(2027, 5)),
                ("Thames Water", -35_000, .monthly, 6, month(2027, 3))
            ]
            for (name, amount, frequency, interval, start) in expected {
                let all = try entries(db, name)
                XCTAssertEqual(all.count, 1, name)
                let entry = try XCTUnwrap(all.first)
                XCTAssertEqual(entry.amountMinorUnits, amount, name)
                XCTAssertEqual(entry.frequency, frequency, name)
                XCTAssertEqual(entry.interval, interval, name)
                XCTAssertEqual(entry.startDate, start, name)
                XCTAssertEqual(entry.status, .manual, name)
                XCTAssertEqual(try ForecastGroup.fetchOne(db, key: entry.groupId)?.name, "Detected recurring", name)
            }
        }
    }

    func testASecondRunChangesNothing() throws {
        try fixture().dbQueue.write { db in
            XCTAssertFalse(try ForecastPlanSeeder.apply(db: db).isEmpty)
            let entryCount = try ForecastEntry.fetchCount(db)
            XCTAssertEqual(try ForecastPlanSeeder.apply(db: db), [])
            XCTAssertEqual(try ForecastEntry.fetchCount(db), entryCount)
        }
    }

    func testAMissingCategoryAbortsWithoutWriting() throws {
        let manager = try fixture()
        try manager.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM category WHERE name = 'Car MOT'")
        }
        try manager.dbQueue.write { db in
            XCTAssertThrowsError(try ForecastPlanSeeder.apply(db: db)) {
                XCTAssertEqual($0 as? ForecastPlanSeederError, .missingCategories(["Car MOT"]))
            }
            XCTAssertNil(try BudgetCore.Category.filter(Column("name") == "Remaining for expenses").fetchOne(db))
            XCTAssertEqual(try category(db, "UK Taxes").type, .transfer)
        }
    }

    func testAnOrdinaryCategoryWithTheReserveNameAborts() throws {
        let manager = try fixture()
        try manager.dbQueue.write { db in
            var clash = BudgetCore.Category(name: "Remaining for expenses", type: .expense)
            try clash.insert(db)
            XCTAssertThrowsError(try ForecastPlanSeeder.apply(db: db)) {
                XCTAssertEqual($0 as? ForecastPlanSeederError, .nameTakenByOrdinaryCategory("Remaining for expenses"))
            }
        }
    }
}
```

- [ ] **Step 2: Run to verify they fail** — `swift test --filter ForecastPlanSeederTests` → "cannot find 'ForecastPlanSeeder'".

- [ ] **Step 3: Implement:**

```swift
// Sources/BudgetCore/Forecasting/ForecastPlanSeeder.swift
import Foundation
import GRDB

public enum ForecastPlanSeederError: Error, Equatable {
    case missingCategories([String])
    case nameTakenByOrdinaryCategory(String)
}

/// One-off: brings the spreadsheet's 2026 plan into the forecast — the £2,000/month
/// "Remaining for expenses" reserve, the planned items the app never imported, and
/// corrected amounts for three auto-detected entries. Idempotent; run it inside one
/// transaction (see `Sources/SeedForecastPlan`).
public enum ForecastPlanSeeder {
    public static let reserveName = "Remaining for expenses"
    public static let planGroupName = "Spreadsheet plan"
    public static let note = "From spreadsheet plan"

    struct Item {
        let name: String
        let amountMinorUnits: Int
        let frequency: ForecastFrequency
        let interval: Int
        let year: Int
        let month: Int
    }

    /// Day-to-day spending the reserve stands in for (no planned amounts of its own).
    static let coveredByReserve = [
        "Groceries", "Eating Out", "Delivery", "Meals/Drinks", "Commute / Public Transport",
        "Car Parking Permit", "Car Parking", "Car Tolls", "Car Charge", "Car Gas", "Car Fines",
        "Car Maintenance/Accessories", "Sport", "Holidays / Travel / Events",
        "House Decor / Move Expenses", "Optician", "Confirmed other expenses",
        "Confirmed other SIGNIFICANT expenses"
    ]

    static let becomeExpenses = ["UK Taxes", "Accountant"]

    static let planned = [
        Item(name: "Car Payments", amountMinorUnits: -35_125, frequency: .monthly, interval: 1, year: 2026, month: 10),
        Item(name: "Council Tax", amountMinorUnits: -35_000, frequency: .monthly, interval: 1, year: 2026, month: 10),
        Item(name: "Transfer: Lloyds Joint", amountMinorUnits: -200_000, frequency: .monthly, interval: 1, year: 2026, month: 10),
        Item(name: "UK Taxes", amountMinorUnits: -320_000, frequency: .annually, interval: 1, year: 2026, month: 12),
        Item(name: "Accountant", amountMinorUnits: -72_000, frequency: .annually, interval: 1, year: 2026, month: 12),
        Item(name: "Car Insurance", amountMinorUnits: -120_000, frequency: .annually, interval: 1, year: 2027, month: 5),
        Item(name: "Car Service", amountMinorUnits: -100_000, frequency: .annually, interval: 1, year: 2027, month: 5),
        Item(name: "Car MOT", amountMinorUnits: -15_000, frequency: .annually, interval: 1, year: 2027, month: 8),
        Item(name: "Car Tax", amountMinorUnits: -19_500, frequency: .annually, interval: 1, year: 2027, month: 1)
    ]

    /// Auto-detected entries whose amounts the spreadsheet plan corrects.
    static let corrections = [
        Item(name: "Rent", amountMinorUnits: -290_000, frequency: .monthly, interval: 1, year: 2026, month: 10),
        Item(name: "TV License", amountMinorUnits: -18_000, frequency: .annually, interval: 1, year: 2027, month: 5),
        Item(name: "Thames Water", amountMinorUnits: -35_000, frequency: .monthly, interval: 6, year: 2027, month: 3)
    ]

    static let reserveItem = Item(name: reserveName, amountMinorUnits: -200_000, frequency: .monthly, interval: 1, year: 2026, month: 10)

    public static var requiredCategoryNames: [String] {
        var seen = Set<String>()
        return (coveredByReserve + becomeExpenses + planned.map(\.name) + corrections.map(\.name)).filter { seen.insert($0).inserted }
    }

    public static func apply(db: Database) throws -> [String] {
        var categories: [String: Category] = [:]
        for category in try Category.fetchAll(db) { categories[category.name] = category }
        let missing = requiredCategoryNames.filter { categories[$0] == nil }
        guard missing.isEmpty else { throw ForecastPlanSeederError.missingCategories(missing) }
        if let clash = categories[reserveName], !clash.isReserved {
            throw ForecastPlanSeederError.nameTakenByOrdinaryCategory(reserveName)
        }

        var log: [String] = []

        // 1. UK Taxes and Accountant are money leaving, not moving between own accounts.
        for name in becomeExpenses where categories[name]!.type != .expense {
            try db.execute(sql: "UPDATE category SET type = 'expense' WHERE id = ?", arguments: [categories[name]!.id!])
            log.append("\(name): transfer → expense")
        }

        // 2. The reserve and its allowance.
        let reserve = try categories[reserveName] ?? ReservedCategories.create(db: db, name: reserveName)
        if categories[reserveName] == nil { log.append("Created reserve \(reserveName)") }
        if try ForecastEntry.filter(Column("categoryId") == reserve.id!).fetchCount(db) == 0 {
            let group = try ReservedCategories.ensureGroup(db: db)
            try insert(reserveItem, categoryId: reserve.id!, groupId: group.id!, db: db)
            log.append("\(reserveName): \(describe(reserveItem))")
        }

        // 3. Everything the reserve covers, plus every planned item, is kept out of the
        //    auto-forecast (the reserve or the plan entry is maintained by hand).
        for name in coveredByReserve + planned.map(\.name) {
            let category = categories[name]!
            let autoCount = try ForecastEntry.filter(Column("categoryId") == category.id! && Column("status") == ForecastEntryStatus.auto.rawValue).fetchCount(db)
            guard !category.excludeFromAutoForecast || autoCount > 0 else { continue }
            let deleted = try ReservedCategories.setExcludedFromAutoForecast(db: db, categoryId: category.id!, true)
            log.append("\(name): excluded from auto-forecast" + (deleted > 0 ? " (removed \(deleted) auto entr\(deleted == 1 ? "y" : "ies"))" : ""))
        }

        // 4. Planned items missing from the forecast.
        var planGroup: ForecastGroup?
        for item in planned {
            let categoryId = categories[item.name]!.id!
            let exists = try ForecastEntry.filter(Column("categoryId") == categoryId && Column("note") == note).fetchCount(db) > 0
            guard !exists else { continue }
            if planGroup == nil { planGroup = try ensurePlanGroup(db: db) }
            try insert(item, categoryId: categoryId, groupId: planGroup!.id!, db: db)
            log.append("\(item.name): \(describe(item))")
        }

        // 5. Corrections: update the auto-detected entry in place and make it manual, so
        //    the auto-forecast keeps it; add one to the plan group if there is none.
        let detected = try ForecastGroup.filter(Column("name") == "Detected recurring").fetchOne(db)
        for item in corrections {
            let categoryId = categories[item.name]!.id!
            let start = startDate(item)
            if let groupId = detected?.id,
               var entry = try ForecastEntry.filter(Column("categoryId") == categoryId && Column("groupId") == groupId).fetchOne(db) {
                let matches = entry.amountMinorUnits == item.amountMinorUnits && entry.frequency == item.frequency && entry.interval == item.interval && entry.startDate == start && entry.status == .manual
                guard !matches else { continue }
                entry.amountMinorUnits = item.amountMinorUnits
                entry.frequency = item.frequency
                entry.interval = item.interval
                entry.startDate = start
                entry.endDate = nil
                entry.status = .manual
                entry.note = note
                try entry.update(db)
                log.append("\(item.name): corrected to \(describe(item))")
            } else if try ForecastEntry.filter(Column("categoryId") == categoryId && Column("note") == note).fetchCount(db) == 0 {
                if planGroup == nil { planGroup = try ensurePlanGroup(db: db) }
                try insert(item, categoryId: categoryId, groupId: planGroup!.id!, db: db)
                log.append("\(item.name): \(describe(item))")
            }
        }
        return log
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func startDate(_ item: Item) -> Date {
        calendar.date(from: DateComponents(year: item.year, month: item.month, day: 1))!
    }

    private static func ensurePlanGroup(db: Database) throws -> ForecastGroup {
        if let existing = try ForecastGroup.filter(Column("name") == planGroupName).fetchOne(db) { return existing }
        var group = ForecastGroup(name: planGroupName, note: "Planned amounts from the original spreadsheet", isEnabled: true, isSystemManaged: false)
        try group.insert(db)
        return group
    }

    private static func insert(_ item: Item, categoryId: Int64, groupId: Int64, db: Database) throws {
        var entry = ForecastEntry(groupId: groupId, categoryId: categoryId, amountMinorUnits: item.amountMinorUnits, frequency: item.frequency, interval: item.interval, startDate: startDate(item), endDate: nil, isEnabled: true, status: .confirmed, note: note)
        try entry.insert(db)
    }

    private static func describe(_ item: Item) -> String {
        let pounds = Money.format(item.amountMinorUnits, currency: .gbp)
        let every = item.interval == 1 ? item.frequency.rawValue : "every \(item.interval) months"
        return "\(pounds) \(every) from \(item.year)-\(String(format: "%02d", item.month))"
    }
}
```

  Check `Money.format`'s real signature in `Sources/BudgetCore/Support/Money.swift` and adjust the call if it differs.

  The `matches` check deliberately ignores `note`, so an existing manual entry the user already tuned to the same values is not rewritten.

- [ ] **Step 4: Verify** — `swift test --filter ForecastPlanSeederTests` → PASS; `swift test` → all green.

- [ ] **Step 5: Commit** — `git add Sources Tests && git commit -m "Add ForecastPlanSeeder for the spreadsheet's reserve and planned amounts" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

### Task 8: `SeedForecastPlan` tool, rehearsal, and the real run

**Files:**
- Create: `Sources/SeedForecastPlan/main.swift`
- Modify: `Package.swift`

This task is run by the controller session (it touches the real database), not a subagent.

- [ ] **Step 1: Tool.** `Package.swift`: add `.executableTarget(name: "SeedForecastPlan", dependencies: ["BudgetCore", .product(name: "GRDB", package: "GRDB.swift")]),` after `SeedCategoryGroups`. `Sources/SeedForecastPlan/main.swift`:

```swift
// Sources/SeedForecastPlan/main.swift
//
// One-time seed (spec: docs/superpowers/specs/2026-10-05-reserved-forecast-categories-design.md):
// the spreadsheet's £2,000/month "Remaining for expenses" reserve, its planned items and
// corrected amounts. Idempotent. Usage: SeedForecastPlan <path-to-budget.sqlite> [--dry-run]

import Foundation
import BudgetCore
import GRDB

let arguments = Array(CommandLine.arguments.dropFirst())
let dryRun = arguments.contains("--dry-run")
guard let path = arguments.first(where: { !$0.hasPrefix("--") }) else {
    print("Usage: SeedForecastPlan <path-to-budget.sqlite> [--dry-run]")
    exit(2)
}
print("Database: \(path)\(dryRun ? " (dry run)" : "")")

let manager = try DatabaseManager(path: path)
try manager.migrate()

var lines: [String] = []
do {
    try manager.dbQueue.inTransaction { db in
        lines = try ForecastPlanSeeder.apply(db: db)
        return dryRun ? .rollback : .commit
    }
} catch let error as ForecastPlanSeederError {
    print("Aborted, nothing written: \(error)")
    exit(1)
}
print(lines.isEmpty ? "No changes." : lines.map { "  " + $0 }.joined(separator: "\n"))
if dryRun { print("Dry run — nothing written.") }
```

  `swift build --product SeedForecastPlan` → builds. Commit: `git add Package.swift Sources/SeedForecastPlan && git commit -m "Add the SeedForecastPlan one-off tool" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`.

- [ ] **Step 2: Rehearse on a copy.** Quit Budget. `cp "$HOME/Library/Application Support/Budget/budget.sqlite" <scratch>/rehearsal.sqlite`; `swift run SeedForecastPlan <scratch>/rehearsal.sqlite --dry-run` → the expected change list; run without `--dry-run` → same list; run again → "No changes.". Check with `sqlite3` that the entries match the spec table.

- [ ] **Step 3: Check the app on the rehearsal copy.** Launch the built binary with `BUDGET_DB_PATH=<scratch>/rehearsal.sqlite`. Check: Forecast › Reserved shows "Remaining for expenses" −£2,000.00 from Oct 2026 and "Total reserved"; December shows UK Taxes and Accountant in expenses; Dec 2026 forecast net worth before vs after (note both); Budget grid Reserved section; Dashboard current month "of which reserved £2,000", purple reserve segment, no "No reserve" attention item; Categories shows "Exclude from auto-forecast" ticked for the covered categories. Screenshots.

- [ ] **Step 4: Real run.** Back up first: `cp "$HOME/Library/Application Support/Budget/budget.sqlite" "$HOME/Library/Application Support/Budget/budget-before-reserves-2026-10-05.sqlite"`. With Budget quit, `swift run SeedForecastPlan "$HOME/Library/Application Support/Budget/budget.sqlite"`; then once more → "No changes.".

- [ ] **Step 5: Update memory and spec status** (memory file `reserved-forecast-categories.md`: built, seeded, backup path, before/after Dec 2026 forecast net worth).
