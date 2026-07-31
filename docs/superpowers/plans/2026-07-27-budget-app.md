# Budget App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS app that imports bank statements (CSV/PDF), categorizes transactions automatically, tracks budgets across payday-to-payday periods, forecasts future spending with adjustable assumptions, and tracks net worth across multiple GBP/EUR accounts — replacing the manual workflow in `Budget copy.numbers`.

**Architecture:** SwiftUI macOS app + an internal Swift package `BudgetCore` holding all non-UI logic (parsing, categorization, forecasting, persistence), so it's testable independent of UI. Persistence via GRDB (SQLite). Money stored as integer minor units (pence) throughout to avoid floating-point errors.

**Tech Stack:** Swift 5.10+, SwiftUI, GRDB.swift 6.x, PDFKit, XCTest, xcodegen (project generation), Anthropic Messages API (Claude) via URLSession for LLM categorization fallback.

## Global Constraints

- Money is always stored/passed as `Int` minor units (pence for GBP, cents for EUR) — never `Double`/`Decimal` in the data model, to avoid rounding bugs. Convert to display strings only at the UI layer.
- All `BudgetCore` logic must be unit-testable without a UI or a real database file (use in-memory GRDB `DatabaseQueue`).
- No network calls except the optional Claude categorization fallback; the app must remain fully usable (with manual categorization) if that call fails or no API key is configured.
- Bundle identifier: `com.personal.budget`. App name: `Budget`.
- Every task ends with a passing `swift test` (for BudgetCore tasks) or a successful `xcodebuild build` (for app-target/UI tasks) before commit.

---

## Phase 0: Project Scaffolding

### Task 1: Create BudgetCore Swift package and Budget Xcode project

**Files:**
- Create: `Package.swift` (at repo root, defines `BudgetCore` package)
- Create: `Sources/BudgetCore/BudgetCore.swift` (empty marker file)
- Create: `Tests/BudgetCoreTests/BudgetCoreTests.swift`
- Create: `project.yml` (xcodegen config for the `Budget` app target)
- Create: `App/BudgetApp.swift`
- Create: `App/ContentView.swift`

**Interfaces:**
- Produces: a `BudgetCore` library target that later tasks add files to; a `Budget` app target that depends on `BudgetCore` and can be built with `xcodebuild`.

- [ ] **Step 1: Create the Swift package manifest**

```swift
// Package.swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BudgetCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BudgetCore", targets: ["BudgetCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .target(name: "BudgetCore", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift")
        ]),
        .testTarget(name: "BudgetCoreTests", dependencies: ["BudgetCore"])
    ]
)
```

- [ ] **Step 2: Add marker source file**

```swift
// Sources/BudgetCore/BudgetCore.swift
public enum BudgetCore {
    public static let version = "0.1.0"
}
```

- [ ] **Step 3: Write a trivial test to prove the harness works**

```swift
// Tests/BudgetCoreTests/BudgetCoreTests.swift
import XCTest
@testable import BudgetCore

final class BudgetCoreTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertEqual(BudgetCore.version, "0.1.0")
    }
}
```

- [ ] **Step 4: Run the test suite**

Run: `swift test`
Expected: 1 test, PASS

- [ ] **Step 5: Create the xcodegen project config for the app target**

```yaml
# project.yml
name: Budget
options:
  bundleIdPrefix: com.personal
packages:
  BudgetCore:
    path: .
targets:
  Budget:
    type: application
    platform: macOS
    deploymentTarget: "13.0"
    sources: [App]
    dependencies:
      - package: BudgetCore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.personal.budget
        MARKETING_VERSION: "0.1.0"
```

- [ ] **Step 6: Create the minimal app entry point and content view**

```swift
// App/BudgetApp.swift
import SwiftUI

@main
struct BudgetApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

```swift
// App/ContentView.swift
import SwiftUI
import BudgetCore

struct ContentView: View {
    var body: some View {
        Text("Budget — v\(BudgetCore.version)")
            .padding()
    }
}
```

- [ ] **Step 7: Generate and build the Xcode project**

Run (installs xcodegen if missing, then generates and builds):
```bash
which xcodegen || brew install xcodegen
xcodegen generate
xcodebuild -project Budget.xcodeproj -scheme Budget -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Add .gitignore and commit**

```bash
cat > .gitignore <<'EOF'
.build/
.swiftpm/
*.xcodeproj/
DerivedData/
.DS_Store
EOF
git add Package.swift Sources Tests project.yml App .gitignore
git commit -m "Scaffold BudgetCore package and Budget app target"
```

---

## Phase 1: Core Data Model & Database Layer

### Task 2: Money helper and DatabaseManager with migrator

**Files:**
- Create: `Sources/BudgetCore/Support/Money.swift`
- Create: `Sources/BudgetCore/Database/DatabaseManager.swift`
- Test: `Tests/BudgetCoreTests/DatabaseManagerTests.swift`

**Interfaces:**
- Produces: `Money` (namespace with `format(_ minorUnits: Int, currency: Currency) -> String`), `Currency` enum (`.gbp`, `.eur`), `DatabaseManager` (class with `init(path: String?)` — `nil` path means in-memory — and `var dbQueue: DatabaseQueue`, and `func migrate() throws`).

- [ ] **Step 1: Write the failing test for Money formatting**

```swift
// Tests/BudgetCoreTests/DatabaseManagerTests.swift
import XCTest
@testable import BudgetCore

final class DatabaseManagerTests: XCTestCase {
    func testMoneyFormatsGBP() {
        XCTAssertEqual(Money.format(180050, currency: .gbp), "£1,800.50")
    }

    func testMoneyFormatsNegative() {
        XCTAssertEqual(Money.format(-500, currency: .gbp), "-£5.00")
    }

    func testDatabaseManagerMigratesInMemory() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let tableExists = try manager.dbQueue.read { db in
            try db.tableExists("category")
        }
        XCTAssertTrue(tableExists)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter DatabaseManagerTests`
Expected: FAIL (no such module members `Money`, `DatabaseManager`)

- [ ] **Step 3: Implement Money and Currency**

```swift
// Sources/BudgetCore/Support/Money.swift
import Foundation

public enum Currency: String, Codable, CaseIterable {
    case gbp
    case eur

    var symbol: String {
        switch self {
        case .gbp: return "£"
        case .eur: return "€"
        }
    }
}

public enum Money {
    /// Formats an integer minor-unit amount (e.g. pence) as a currency string.
    public static func format(_ minorUnits: Int, currency: Currency) -> String {
        let negative = minorUnits < 0
        let absValue = abs(minorUnits)
        let whole = absValue / 100
        let fraction = absValue % 100
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        let wholeString = formatter.string(from: NSNumber(value: whole)) ?? "\(whole)"
        let body = "\(currency.symbol)\(wholeString).\(String(format: "%02d", fraction))"
        return negative ? "-\(body)" : body
    }
}
```

- [ ] **Step 4: Implement DatabaseManager with an empty migrator**

```swift
// Sources/BudgetCore/Database/DatabaseManager.swift
import Foundation
import GRDB

public final class DatabaseManager {
    public let dbQueue: DatabaseQueue

    public init(path: String?) throws {
        if let path {
            dbQueue = try DatabaseQueue(path: path)
        } else {
            dbQueue = try DatabaseQueue()
        }
    }

    public func migrate() throws {
        var migrator = DatabaseMigrator()
        registerMigrations(&migrator)
        try migrator.migrate(dbQueue)
    }

    /// Individual model files append their own migration in an extension
    /// on this function via `registerMigrations(_:)` overloads is not
    /// possible in Swift, so each model file defines a free function
    /// `register<Model>Migration(_ migrator: inout DatabaseMigrator)`
    /// and this function calls them all in order.
    private func registerMigrations(_ migrator: inout DatabaseMigrator) {
        registerCategoryMigration(&migrator)
    }
}
```

- [ ] **Step 5: Implement the category migration (minimal, just to prove the harness — full Category model comes in Task 3)**

```swift
// Sources/BudgetCore/Models/Category+Migration.swift
import GRDB

func registerCategoryMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createCategory") { db in
        try db.create(table: "category") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull().unique()
            t.column("type", .text).notNull()
        }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter DatabaseManagerTests`
Expected: 3 tests, PASS

- [ ] **Step 7: Commit**

```bash
git add Sources/BudgetCore/Support/Money.swift Sources/BudgetCore/Database/DatabaseManager.swift Sources/BudgetCore/Models/Category+Migration.swift Tests/BudgetCoreTests/DatabaseManagerTests.swift
git commit -m "Add Money formatting and DatabaseManager with migrator"
```

### Task 3: Category model

**Files:**
- Modify: `Sources/BudgetCore/Models/Category+Migration.swift` (already has the table; no change needed)
- Create: `Sources/BudgetCore/Models/Category.swift`
- Create: `Sources/BudgetCore/Models/CategorySeeder.swift`
- Test: `Tests/BudgetCoreTests/CategoryTests.swift`

**Interfaces:**
- Consumes: `DatabaseManager` (Task 2)
- Produces: `Category` (GRDB `Codable, FetchableRecord, MutablePersistableRecord` struct: `id: Int64?`, `name: String`, `type: CategoryType`), `CategoryType` enum (`.expense`, `.transfer`, `.income`), `CategorySeeder.seedDefaults(_ db: Database) throws`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BudgetCoreTests/CategoryTests.swift
import XCTest
import GRDB
@testable import BudgetCore

final class CategoryTests: XCTestCase {
    func testInsertAndFetchCategory() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        var category = Category(name: "Rent", type: .expense)
        try manager.dbQueue.write { db in
            try category.insert(db)
        }
        let fetched = try manager.dbQueue.read { db in
            try Category.filter(Column("name") == "Rent").fetchOne(db)
        }
        XCTAssertEqual(fetched?.type, .expense)
    }

    func testSeedDefaultsCreatesKnownCategories() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in
            try CategorySeeder.seedDefaults(db)
        }
        let count = try manager.dbQueue.read { db in
            try Category.fetchCount(db)
        }
        XCTAssertGreaterThanOrEqual(count, 40)
        let rent = try manager.dbQueue.read { db in
            try Category.filter(Column("name") == "Rent").fetchOne(db)
        }
        XCTAssertNotNil(rent)
        XCTAssertEqual(rent?.type, .expense)
        let income = try manager.dbQueue.read { db in
            try Category.filter(Column("name") == "Income").fetchOne(db)
        }
        XCTAssertEqual(income?.type, .income)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter CategoryTests`
Expected: FAIL (no such type `Category`)

- [ ] **Step 3: Implement Category**

```swift
// Sources/BudgetCore/Models/Category.swift
import GRDB

public enum CategoryType: String, Codable, CaseIterable {
    case expense
    case transfer
    case income
}

public struct Category: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var name: String
    public var type: CategoryType

    public init(id: Int64? = nil, name: String, type: CategoryType) {
        self.id = id
        self.name = name
        self.type = type
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "category"
}
```

- [ ] **Step 4: Implement the seeder with the categories from the existing spreadsheet**

```swift
// Sources/BudgetCore/Models/CategorySeeder.swift
import GRDB

public enum CategorySeeder {
    public static let expenseNames: [String] = [
        "Rent", "Internet", "Gas/Electricity", "Mobile Patricia", "Mobile Pablo",
        "Apple iCloud / Subscriptions", "Microsoft 365", "Apple Arcade", "NOW",
        "Apple One", "Netflix", "Spotify", "Disney+", "Council Tax",
        "HP Instant Ink", "TV License", "Amazon Prime", "PlayStation Plus / Games",
        "Thames Water",
        "Car Parking Permit", "Car Payments", "Car Tax", "Car MOT", "Car Insurance",
        "Car Service", "Car Subscriptions", "Car Fines", "Car Maintenance/Accessories",
        "Car Parking", "Car Tolls", "Car Charge", "Car Gas",
        "Commute / Public Transport", "Meals/Drinks", "Delivery", "Eating Out",
        "Holidays / Travel / Events", "Sport", "Groceries",
        "House Decor / Move Expenses", "Optician",
        "Confirmed other expenses", "Confirmed other SIGNIFICANT expenses"
    ]

    public static let transferNames: [String] = [
        "Business Expenses (credit) / AMEX Travel (debit)",
        "Investments (Stocks + Crypto)", "Trading tools & training",
        "Transfer: Santander Patricia", "Transfer: Lloyds Joint",
        "Transfer: Lloyds International EUR", "Transfer: Lloyds Investment ISA",
        "Transfer: BBVA Portugal", "Accountant", "UK Taxes"
    ]

    public static let incomeNames: [String] = ["Income", "Bonus", "Other income/refunds"]

    public static func seedDefaults(_ db: Database) throws {
        for name in expenseNames {
            var category = Category(name: name, type: .expense)
            if try Category.filter(Column("name") == name).fetchCount(db) == 0 {
                try category.insert(db)
            }
        }
        for name in transferNames {
            var category = Category(name: name, type: .transfer)
            if try Category.filter(Column("name") == name).fetchCount(db) == 0 {
                try category.insert(db)
            }
        }
        for name in incomeNames {
            var category = Category(name: name, type: .income)
            if try Category.filter(Column("name") == name).fetchCount(db) == 0 {
                try category.insert(db)
            }
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter CategoryTests`
Expected: 2 tests, PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/BudgetCore/Models/Category.swift Sources/BudgetCore/Models/CategorySeeder.swift Tests/BudgetCoreTests/CategoryTests.swift
git commit -m "Add Category model and default category seeder"
```

### Task 4: Account model

**Files:**
- Create: `Sources/BudgetCore/Models/Account.swift`
- Modify: `Sources/BudgetCore/Database/DatabaseManager.swift:registerMigrations` (add `registerAccountMigration(&migrator)`)
- Test: `Tests/BudgetCoreTests/AccountTests.swift`

**Interfaces:**
- Produces: `Account` (`id: Int64?`, `name: String`, `currency: Currency`, `kind: AccountKind`, `trackingMode: AccountTrackingMode`), `AccountKind` enum (`.cash`, `.credit`, `.investment`), `AccountTrackingMode` enum (`.imported`, `.manual`)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BudgetCoreTests/AccountTests.swift
import XCTest
import GRDB
@testable import BudgetCore

final class AccountTests: XCTestCase {
    func testInsertAndFetchAccount() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        var account = Account(name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        try manager.dbQueue.write { db in try account.insert(db) }
        let fetched = try manager.dbQueue.read { db in
            try Account.filter(Column("name") == "Lloyds Classic").fetchOne(db)
        }
        XCTAssertEqual(fetched?.currency, .gbp)
        XCTAssertEqual(fetched?.trackingMode, .imported)
    }

    func testManualInvestmentAccount() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        var account = Account(name: "Lloyds Investment ISA", currency: .gbp, kind: .investment, trackingMode: .manual)
        try manager.dbQueue.write { db in try account.insert(db) }
        XCTAssertNotNil(account.id)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter AccountTests`
Expected: FAIL (no such type `Account`)

- [ ] **Step 3: Implement Account**

```swift
// Sources/BudgetCore/Models/Account.swift
import GRDB

public enum AccountKind: String, Codable, CaseIterable {
    case cash
    case credit
    case investment
}

public enum AccountTrackingMode: String, Codable, CaseIterable {
    case imported
    case manual
}

public struct Account: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var name: String
    public var currency: Currency
    public var kind: AccountKind
    public var trackingMode: AccountTrackingMode

    public init(id: Int64? = nil, name: String, currency: Currency, kind: AccountKind, trackingMode: AccountTrackingMode) {
        self.id = id
        self.name = name
        self.currency = currency
        self.kind = kind
        self.trackingMode = trackingMode
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "account"
}

func registerAccountMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createAccount") { db in
        try db.create(table: "account") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull().unique()
            t.column("currency", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("trackingMode", .text).notNull()
        }
    }
}
```

- [ ] **Step 4: Register the migration**

```swift
// Sources/BudgetCore/Database/DatabaseManager.swift
// In registerMigrations(_:), add after registerCategoryMigration:
        registerCategoryMigration(&migrator)
        registerAccountMigration(&migrator)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter AccountTests`
Expected: 2 tests, PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/BudgetCore/Models/Account.swift Sources/BudgetCore/Database/DatabaseManager.swift Tests/BudgetCoreTests/AccountTests.swift
git commit -m "Add Account model"
```

### Task 5: ImportProfile, ImportBatch, and Transaction models

**Files:**
- Create: `Sources/BudgetCore/Models/ImportProfile.swift`
- Create: `Sources/BudgetCore/Models/ImportBatch.swift`
- Create: `Sources/BudgetCore/Models/Transaction.swift`
- Modify: `Sources/BudgetCore/Database/DatabaseManager.swift:registerMigrations`
- Test: `Tests/BudgetCoreTests/TransactionTests.swift`

**Interfaces:**
- Consumes: `Account` (Task 4), `Category` (Task 3)
- Produces: `ImportProfile` (`id`, `accountId: Int64`, `format: ImportFormat`, `csvDelimiter: String?`, `csvDateColumnIndex: Int?`, `csvDescriptionColumnIndex: Int?`, `csvAmountColumnIndex: Int?`, `csvDateFormat: String?`, `pdfLayoutConfig: String?` — JSON blob for PDF, decoded in Phase 3), `ImportFormat` enum (`.csv`, `.pdf`); `ImportBatch` (`id`, `accountId: Int64`, `sourceFileName: String`, `importedAt: Date`); `Transaction` (`id`, `importBatchId: Int64`, `accountId: Int64`, `date: Date`, `rawDescription: String`, `amountMinorUnits: Int`, `categoryId: Int64?`, `status: TransactionStatus`, `categorizedBy: CategorizedBy`, `fingerprint: String`), `TransactionStatus` enum (`.pendingReview`, `.confirmed`), `CategorizedBy` enum (`.rule`, `.llm`, `.manual`, `.none`)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BudgetCoreTests/TransactionTests.swift
import XCTest
import GRDB
@testable import BudgetCore

final class TransactionTests: XCTestCase {
    func testInsertBatchAndTransaction() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        var account = Account(name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        try manager.dbQueue.write { db in try account.insert(db) }

        var batch = ImportBatch(accountId: account.id!, sourceFileName: "july.csv", importedAt: Date())
        try manager.dbQueue.write { db in try batch.insert(db) }

        var transaction = Transaction(
            importBatchId: batch.id!,
            accountId: account.id!,
            date: Date(),
            rawDescription: "SAINSBURYS LONDON",
            amountMinorUnits: -4564,
            categoryId: nil,
            status: .pendingReview,
            categorizedBy: .none,
            fingerprint: "abc123"
        )
        try manager.dbQueue.write { db in try transaction.insert(db) }

        let fetched = try manager.dbQueue.read { db in
            try Transaction.filter(Column("fingerprint") == "abc123").fetchOne(db)
        }
        XCTAssertEqual(fetched?.amountMinorUnits, -4564)
        XCTAssertEqual(fetched?.status, .pendingReview)
    }

    func testFingerprintMustBeUniquePerAccount() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        var account = Account(name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        try manager.dbQueue.write { db in try account.insert(db) }
        var batch = ImportBatch(accountId: account.id!, sourceFileName: "a.csv", importedAt: Date())
        try manager.dbQueue.write { db in try batch.insert(db) }

        var t1 = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Date(), rawDescription: "X", amountMinorUnits: -100, categoryId: nil, status: .pendingReview, categorizedBy: .none, fingerprint: "dup")
        try manager.dbQueue.write { db in try t1.insert(db) }

        var t2 = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Date(), rawDescription: "X", amountMinorUnits: -100, categoryId: nil, status: .pendingReview, categorizedBy: .none, fingerprint: "dup")
        XCTAssertThrowsError(try manager.dbQueue.write { db in try t2.insert(db) })
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter TransactionTests`
Expected: FAIL (no such types)

- [ ] **Step 3: Implement ImportProfile**

```swift
// Sources/BudgetCore/Models/ImportProfile.swift
import GRDB

public enum ImportFormat: String, Codable, CaseIterable {
    case csv
    case pdf
}

public struct ImportProfile: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var accountId: Int64
    public var format: ImportFormat
    public var csvDelimiter: String?
    public var csvDateColumnIndex: Int?
    public var csvDescriptionColumnIndex: Int?
    public var csvAmountColumnIndex: Int?
    public var csvDateFormat: String?
    public var pdfLayoutConfig: String?

    public init(id: Int64? = nil, accountId: Int64, format: ImportFormat, csvDelimiter: String? = nil, csvDateColumnIndex: Int? = nil, csvDescriptionColumnIndex: Int? = nil, csvAmountColumnIndex: Int? = nil, csvDateFormat: String? = nil, pdfLayoutConfig: String? = nil) {
        self.id = id
        self.accountId = accountId
        self.format = format
        self.csvDelimiter = csvDelimiter
        self.csvDateColumnIndex = csvDateColumnIndex
        self.csvDescriptionColumnIndex = csvDescriptionColumnIndex
        self.csvAmountColumnIndex = csvAmountColumnIndex
        self.csvDateFormat = csvDateFormat
        self.pdfLayoutConfig = pdfLayoutConfig
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "importProfile"
}

func registerImportProfileMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createImportProfile") { db in
        try db.create(table: "importProfile") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("accountId", .integer).notNull().references("account")
            t.column("format", .text).notNull()
            t.column("csvDelimiter", .text)
            t.column("csvDateColumnIndex", .integer)
            t.column("csvDescriptionColumnIndex", .integer)
            t.column("csvAmountColumnIndex", .integer)
            t.column("csvDateFormat", .text)
            t.column("pdfLayoutConfig", .text)
            t.uniqueKey(["accountId", "format"])
        }
    }
}
```

- [ ] **Step 4: Implement ImportBatch**

```swift
// Sources/BudgetCore/Models/ImportBatch.swift
import GRDB
import Foundation

public struct ImportBatch: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var accountId: Int64
    public var sourceFileName: String
    public var importedAt: Date

    public init(id: Int64? = nil, accountId: Int64, sourceFileName: String, importedAt: Date) {
        self.id = id
        self.accountId = accountId
        self.sourceFileName = sourceFileName
        self.importedAt = importedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "importBatch"
}

func registerImportBatchMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createImportBatch") { db in
        try db.create(table: "importBatch") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("accountId", .integer).notNull().references("account")
            t.column("sourceFileName", .text).notNull()
            t.column("importedAt", .datetime).notNull()
        }
    }
}
```

- [ ] **Step 5: Implement Transaction**

```swift
// Sources/BudgetCore/Models/Transaction.swift
import GRDB
import Foundation

public enum TransactionStatus: String, Codable, CaseIterable {
    case pendingReview
    case confirmed
}

public enum CategorizedBy: String, Codable, CaseIterable {
    case rule
    case llm
    case manual
    case none
}

public struct Transaction: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var importBatchId: Int64
    public var accountId: Int64
    public var date: Date
    public var rawDescription: String
    public var amountMinorUnits: Int
    public var categoryId: Int64?
    public var status: TransactionStatus
    public var categorizedBy: CategorizedBy
    public var fingerprint: String

    public init(id: Int64? = nil, importBatchId: Int64, accountId: Int64, date: Date, rawDescription: String, amountMinorUnits: Int, categoryId: Int64?, status: TransactionStatus, categorizedBy: CategorizedBy, fingerprint: String) {
        self.id = id
        self.importBatchId = importBatchId
        self.accountId = accountId
        self.date = date
        self.rawDescription = rawDescription
        self.amountMinorUnits = amountMinorUnits
        self.categoryId = categoryId
        self.status = status
        self.categorizedBy = categorizedBy
        self.fingerprint = fingerprint
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "transaction_"
}

func registerTransactionMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createTransaction") { db in
        try db.create(table: "transaction_") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("importBatchId", .integer).notNull().references("importBatch")
            t.column("accountId", .integer).notNull().references("account")
            t.column("date", .datetime).notNull()
            t.column("rawDescription", .text).notNull()
            t.column("amountMinorUnits", .integer).notNull()
            t.column("categoryId", .integer).references("category")
            t.column("status", .text).notNull()
            t.column("categorizedBy", .text).notNull()
            t.column("fingerprint", .text).notNull()
            t.uniqueKey(["accountId", "fingerprint"])
        }
    }
}
```

Note: the table is named `transaction_` (trailing underscore) because `transaction` is a reserved word in SQLite.

- [ ] **Step 6: Register the migrations in order**

```swift
// Sources/BudgetCore/Database/DatabaseManager.swift
// In registerMigrations(_:):
        registerCategoryMigration(&migrator)
        registerAccountMigration(&migrator)
        registerImportProfileMigration(&migrator)
        registerImportBatchMigration(&migrator)
        registerTransactionMigration(&migrator)
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --filter TransactionTests`
Expected: 2 tests, PASS

- [ ] **Step 8: Commit**

```bash
git add Sources/BudgetCore/Models/ImportProfile.swift Sources/BudgetCore/Models/ImportBatch.swift Sources/BudgetCore/Models/Transaction.swift Sources/BudgetCore/Database/DatabaseManager.swift Tests/BudgetCoreTests/TransactionTests.swift
git commit -m "Add ImportProfile, ImportBatch, and Transaction models"
```

### Task 6: Rule model

**Files:**
- Create: `Sources/BudgetCore/Models/Rule.swift`
- Modify: `Sources/BudgetCore/Database/DatabaseManager.swift:registerMigrations`
- Test: `Tests/BudgetCoreTests/RuleTests.swift`

**Interfaces:**
- Consumes: `Category` (Task 3)
- Produces: `Rule` (`id`, `matchPattern: String`, `matchType: RuleMatchType`, `categoryId: Int64`, `priority: Int`), `RuleMatchType` enum (`.contains`, `.regex`)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BudgetCoreTests/RuleTests.swift
import XCTest
import GRDB
@testable import BudgetCore

final class RuleTests: XCTestCase {
    func testInsertAndFetchRule() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in try CategorySeeder.seedDefaults(db) }
        let groceries = try manager.dbQueue.read { db in
            try Category.filter(Column("name") == "Groceries").fetchOne(db)!
        }
        var rule = Rule(matchPattern: "SAINSBURYS", matchType: .contains, categoryId: groceries.id!, priority: 10)
        try manager.dbQueue.write { db in try rule.insert(db) }
        let fetched = try manager.dbQueue.read { db in
            try Rule.filter(Column("matchPattern") == "SAINSBURYS").fetchOne(db)
        }
        XCTAssertEqual(fetched?.categoryId, groceries.id)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter RuleTests`
Expected: FAIL (no such type `Rule`)

- [ ] **Step 3: Implement Rule**

```swift
// Sources/BudgetCore/Models/Rule.swift
import GRDB

public enum RuleMatchType: String, Codable, CaseIterable {
    case contains
    case regex
}

public struct Rule: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var matchPattern: String
    public var matchType: RuleMatchType
    public var categoryId: Int64
    public var priority: Int

    public init(id: Int64? = nil, matchPattern: String, matchType: RuleMatchType, categoryId: Int64, priority: Int) {
        self.id = id
        self.matchPattern = matchPattern
        self.matchType = matchType
        self.categoryId = categoryId
        self.priority = priority
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "rule"
}

func registerRuleMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createRule") { db in
        try db.create(table: "rule") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("matchPattern", .text).notNull()
            t.column("matchType", .text).notNull()
            t.column("categoryId", .integer).notNull().references("category")
            t.column("priority", .integer).notNull()
        }
    }
}
```

- [ ] **Step 4: Register the migration**

```swift
// Sources/BudgetCore/Database/DatabaseManager.swift
// In registerMigrations(_:), append:
        registerRuleMigration(&migrator)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter RuleTests`
Expected: 1 test, PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/BudgetCore/Models/Rule.swift Sources/BudgetCore/Database/DatabaseManager.swift Tests/BudgetCoreTests/RuleTests.swift
git commit -m "Add Rule model"
```

---

## Phase 2: CSV Import, Categorization, and Review

### Task 7: CSV row splitter and statement parser

**Files:**
- Create: `Sources/BudgetCore/Import/CSVRowSplitter.swift`
- Create: `Sources/BudgetCore/Import/CSVStatementParser.swift`
- Create: `Sources/BudgetCore/Import/ParsedTransaction.swift`
- Test: `Tests/BudgetCoreTests/CSVStatementParserTests.swift`

**Interfaces:**
- Consumes: `ImportProfile` (Task 5)
- Produces: `ParsedTransaction` (plain struct: `date: Date`, `rawDescription: String`, `amountMinorUnits: Int`), `CSVRowSplitter.split(line: String, delimiter: Character) -> [String]`, `CSVStatementParser.parse(csvText: String, profile: ImportProfile) -> CSVParseResult` where `CSVParseResult` has `transactions: [ParsedTransaction]` and `unparsedLines: [String]`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BudgetCoreTests/CSVStatementParserTests.swift
import XCTest
@testable import BudgetCore

final class CSVStatementParserTests: XCTestCase {
    func testSplitsQuotedFieldsWithEmbeddedCommas() {
        let fields = CSVRowSplitter.split(line: "01/07/2026,\"SAINSBURYS, LONDON\",-45.64", delimiter: ",")
        XCTAssertEqual(fields, ["01/07/2026", "SAINSBURYS, LONDON", "-45.64"])
    }

    func testParsesLloydsStyleCSV() {
        let csv = """
        Date,Description,Amount
        01/07/2026,SAINSBURYS LONDON,-45.64
        02/07/2026,SALARY PAYMENT,2800.00
        """
        let profile = ImportProfile(
            accountId: 1,
            format: .csv,
            csvDelimiter: ",",
            csvDateColumnIndex: 0,
            csvDescriptionColumnIndex: 1,
            csvAmountColumnIndex: 2,
            csvDateFormat: "dd/MM/yyyy"
        )
        let result = CSVStatementParser.parse(csvText: csv, profile: profile)
        XCTAssertEqual(result.transactions.count, 2)
        XCTAssertEqual(result.transactions[0].rawDescription, "SAINSBURYS LONDON")
        XCTAssertEqual(result.transactions[0].amountMinorUnits, -4564)
        XCTAssertEqual(result.transactions[1].amountMinorUnits, 280000)
        XCTAssertTrue(result.unparsedLines.isEmpty)
    }

    func testFlagsUnparsableRows() {
        let csv = """
        Date,Description,Amount
        01/07/2026,SAINSBURYS LONDON,-45.64
        NOT-A-DATE,BROKEN ROW,notanumber
        """
        let profile = ImportProfile(
            accountId: 1, format: .csv, csvDelimiter: ",",
            csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2,
            csvDateFormat: "dd/MM/yyyy"
        )
        let result = CSVStatementParser.parse(csvText: csv, profile: profile)
        XCTAssertEqual(result.transactions.count, 1)
        XCTAssertEqual(result.unparsedLines.count, 1)
        XCTAssertTrue(result.unparsedLines[0].contains("BROKEN ROW"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter CSVStatementParserTests`
Expected: FAIL (no such types)

- [ ] **Step 3: Implement ParsedTransaction**

```swift
// Sources/BudgetCore/Import/ParsedTransaction.swift
import Foundation

public struct ParsedTransaction: Equatable {
    public let date: Date
    public let rawDescription: String
    public let amountMinorUnits: Int

    public init(date: Date, rawDescription: String, amountMinorUnits: Int) {
        self.date = date
        self.rawDescription = rawDescription
        self.amountMinorUnits = amountMinorUnits
    }
}
```

- [ ] **Step 4: Implement CSVRowSplitter (handles quoted fields)**

```swift
// Sources/BudgetCore/Import/CSVRowSplitter.swift
import Foundation

public enum CSVRowSplitter {
    public static func split(line: String, delimiter: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var insideQuotes = false
        var iterator = line.makeIterator()
        while let char = iterator.next() {
            if char == "\"" {
                insideQuotes.toggle()
            } else if char == delimiter && !insideQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current)
        return fields.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
```

- [ ] **Step 5: Implement the amount parser and CSVStatementParser**

```swift
// Sources/BudgetCore/Import/CSVStatementParser.swift
import Foundation

public struct CSVParseResult {
    public let transactions: [ParsedTransaction]
    public let unparsedLines: [String]
}

public enum CSVStatementParser {
    public static func parse(csvText: String, profile: ImportProfile) -> CSVParseResult {
        let delimiter = Character(profile.csvDelimiter ?? ",")
        let dateFormat = profile.csvDateFormat ?? "dd/MM/yyyy"
        let dateIndex = profile.csvDateColumnIndex ?? 0
        let descriptionIndex = profile.csvDescriptionColumnIndex ?? 1
        let amountIndex = profile.csvAmountColumnIndex ?? 2

        let formatter = DateFormatter()
        formatter.dateFormat = dateFormat
        formatter.locale = Locale(identifier: "en_GB")

        var lines = csvText.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return CSVParseResult(transactions: [], unparsedLines: []) }
        lines.removeFirst() // header row

        var transactions: [ParsedTransaction] = []
        var unparsedLines: [String] = []

        for line in lines {
            let fields = CSVRowSplitter.split(line: line, delimiter: delimiter)
            guard fields.count > max(dateIndex, descriptionIndex, amountIndex) else {
                unparsedLines.append(line)
                continue
            }
            guard let date = formatter.date(from: fields[dateIndex]),
                  let minorUnits = parseAmountMinorUnits(fields[amountIndex]) else {
                unparsedLines.append(line)
                continue
            }
            transactions.append(ParsedTransaction(date: date, rawDescription: fields[descriptionIndex], amountMinorUnits: minorUnits))
        }

        return CSVParseResult(transactions: transactions, unparsedLines: unparsedLines)
    }

    private static func parseAmountMinorUnits(_ raw: String) -> Int? {
        let cleaned = raw.replacingOccurrences(of: ",", with: "")
        guard let decimalValue = Decimal(string: cleaned) else { return nil }
        let scaled = decimalValue * 100
        return NSDecimalNumber(decimal: scaled).intValue == 0 && cleaned != "0" && cleaned != "0.00"
            ? nil
            : NSDecimalNumber(decimal: scaled).intValue
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter CSVStatementParserTests`
Expected: 3 tests, PASS

- [ ] **Step 7: Commit**

```bash
git add Sources/BudgetCore/Import/CSVRowSplitter.swift Sources/BudgetCore/Import/CSVStatementParser.swift Sources/BudgetCore/Import/ParsedTransaction.swift Tests/BudgetCoreTests/CSVStatementParserTests.swift
git commit -m "Add CSV row splitter and statement parser"
```

### Task 8: Transaction fingerprinting for duplicate detection

**Files:**
- Create: `Sources/BudgetCore/Import/TransactionFingerprint.swift`
- Test: `Tests/BudgetCoreTests/TransactionFingerprintTests.swift`

**Interfaces:**
- Produces: `TransactionFingerprint.compute(accountId: Int64, date: Date, amountMinorUnits: Int, description: String) -> String`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BudgetCoreTests/TransactionFingerprintTests.swift
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

    func testDifferentAccountsProduceDifferentFingerprints() {
        let date = Date(timeIntervalSince1970: 1_770_000_000)
        let a = TransactionFingerprint.compute(accountId: 1, date: date, amountMinorUnits: -4564, description: "SAINSBURYS")
        let b = TransactionFingerprint.compute(accountId: 2, date: date, amountMinorUnits: -4564, description: "SAINSBURYS")
        XCTAssertNotEqual(a, b)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter TransactionFingerprintTests`
Expected: FAIL (no such type `TransactionFingerprint`)

- [ ] **Step 3: Implement TransactionFingerprint using CryptoKit**

```swift
// Sources/BudgetCore/Import/TransactionFingerprint.swift
import Foundation
import CryptoKit

public enum TransactionFingerprint {
    public static func compute(accountId: Int64, date: Date, amountMinorUnits: Int, description: String) -> String {
        let normalizedDescription = description
            .uppercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone(identifier: "UTC")
        let dayString = dayFormatter.string(from: date)

        let raw = "\(accountId)|\(dayString)|\(amountMinorUnits)|\(normalizedDescription)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TransactionFingerprintTests`
Expected: 4 tests, PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/BudgetCore/Import/TransactionFingerprint.swift Tests/BudgetCoreTests/TransactionFingerprintTests.swift
git commit -m "Add transaction fingerprinting for duplicate detection"
```

### Task 9: Rule matching engine

**Files:**
- Create: `Sources/BudgetCore/Categorization/RuleMatcher.swift`
- Test: `Tests/BudgetCoreTests/RuleMatcherTests.swift`

**Interfaces:**
- Consumes: `Rule`, `RuleMatchType` (Task 6)
- Produces: `RuleMatcher.match(description: String, rules: [Rule]) -> Rule?`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BudgetCoreTests/RuleMatcherTests.swift
import XCTest
@testable import BudgetCore

final class RuleMatcherTests: XCTestCase {
    func testContainsMatchIsCaseInsensitive() {
        let rule = Rule(id: 1, matchPattern: "sainsburys", matchType: .contains, categoryId: 1, priority: 10)
        let match = RuleMatcher.match(description: "SAINSBURYS LONDON SW1", rules: [rule])
        XCTAssertEqual(match?.id, 1)
    }

    func testRegexMatch() {
        let rule = Rule(id: 2, matchPattern: "^TFL TRAVEL.*$", matchType: .regex, categoryId: 2, priority: 10)
        let match = RuleMatcher.match(description: "TFL TRAVEL CH 1234", rules: [rule])
        XCTAssertEqual(match?.id, 2)
    }

    func testHigherPriorityWinsWhenMultipleMatch() {
        let low = Rule(id: 1, matchPattern: "AMAZON", matchType: .contains, categoryId: 1, priority: 1)
        let high = Rule(id: 2, matchPattern: "AMAZON PRIME", matchType: .contains, categoryId: 2, priority: 10)
        let match = RuleMatcher.match(description: "AMAZON PRIME MEMBERSHIP", rules: [low, high])
        XCTAssertEqual(match?.id, 2)
    }

    func testNoMatchReturnsNil() {
        let rule = Rule(id: 1, matchPattern: "SAINSBURYS", matchType: .contains, categoryId: 1, priority: 10)
        let match = RuleMatcher.match(description: "TESCO EXPRESS", rules: [rule])
        XCTAssertNil(match)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter RuleMatcherTests`
Expected: FAIL (no such type `RuleMatcher`)

- [ ] **Step 3: Implement RuleMatcher**

```swift
// Sources/BudgetCore/Categorization/RuleMatcher.swift
import Foundation

public enum RuleMatcher {
    /// Returns the highest-priority rule whose pattern matches `description`, or nil.
    public static func match(description: String, rules: [Rule]) -> Rule? {
        let candidates = rules.filter { rule in
            switch rule.matchType {
            case .contains:
                return description.range(of: rule.matchPattern, options: .caseInsensitive) != nil
            case .regex:
                return (try? NSRegularExpression(pattern: rule.matchPattern, options: .caseInsensitive))
                    .map { regex in
                        regex.firstMatch(in: description, range: NSRange(description.startIndex..., in: description)) != nil
                    } ?? false
            }
        }
        return candidates.max(by: { $0.priority < $1.priority })
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RuleMatcherTests`
Expected: 4 tests, PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/BudgetCore/Categorization/RuleMatcher.swift Tests/BudgetCoreTests/RuleMatcherTests.swift
git commit -m "Add rule matching engine"
```

### Task 10: Keychain API key store and Claude categorization fallback

**Files:**
- Create: `Sources/BudgetCore/Support/KeychainAPIKeyStore.swift`
- Create: `Sources/BudgetCore/Categorization/ClaudeCategorizer.swift`
- Test: `Tests/BudgetCoreTests/ClaudeCategorizerTests.swift`

**Interfaces:**
- Produces: `APIKeyStoring` protocol (`func getAPIKey() -> String?`, `func setAPIKey(_ key: String) throws`), `KeychainAPIKeyStore: APIKeyStoring`; `CategorySuggestion` (`categoryName: String`, `confidence: Double`); `Categorizing` protocol (`func suggestCategory(description: String, candidateCategoryNames: [String]) async throws -> CategorySuggestion?`); `ClaudeCategorizer: Categorizing` (takes an `APIKeyStoring` and a `URLSession`); `CategorizerError` enum (`.missingAPIKey`, `.requestFailed`, `.unparsableResponse`)

- [ ] **Step 1: Write the failing test using a URLProtocol stub (no real network call)**

```swift
// Tests/BudgetCoreTests/ClaudeCategorizerTests.swift
import XCTest
@testable import BudgetCore

final class StubAPIKeyStore: APIKeyStoring {
    var key: String?
    func getAPIKey() -> String? { key }
    func setAPIKey(_ key: String) throws { self.key = key }
}

final class StubURLProtocol: URLProtocol {
    static var responseData: Data?
    static var statusCode: Int = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data = Self.responseData {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ClaudeCategorizerTests: XCTestCase {
    func testReturnsNilWhenNoAPIKeyConfigured() async throws {
        let store = StubAPIKeyStore()
        let categorizer = ClaudeCategorizer(apiKeyStore: store, session: .shared)
        let suggestion = try await categorizer.suggestCategory(description: "SAINSBURYS", candidateCategoryNames: ["Groceries"])
        XCTAssertNil(suggestion)
    }

    func testParsesSuggestionFromClaudeResponse() async throws {
        let store = StubAPIKeyStore()
        store.key = "test-key"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)

        let responseJSON = """
        {"content":[{"type":"text","text":"{\\"categoryName\\":\\"Groceries\\",\\"confidence\\":0.92}"}]}
        """
        StubURLProtocol.responseData = Data(responseJSON.utf8)
        StubURLProtocol.statusCode = 200

        let categorizer = ClaudeCategorizer(apiKeyStore: store, session: session)
        let suggestion = try await categorizer.suggestCategory(description: "SAINSBURYS LONDON", candidateCategoryNames: ["Groceries", "Eating Out"])
        XCTAssertEqual(suggestion?.categoryName, "Groceries")
        XCTAssertEqual(suggestion?.confidence, 0.92, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ClaudeCategorizerTests`
Expected: FAIL (no such types)

- [ ] **Step 3: Implement KeychainAPIKeyStore**

```swift
// Sources/BudgetCore/Support/KeychainAPIKeyStore.swift
import Foundation
import Security

public protocol APIKeyStoring {
    func getAPIKey() -> String?
    func setAPIKey(_ key: String) throws
}

public final class KeychainAPIKeyStore: APIKeyStoring {
    private let service = "com.personal.budget.anthropic-api-key"
    private let account = "default"

    public init() {}

    public func getAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setAPIKey(_ key: String) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "KeychainAPIKeyStore", code: Int(status))
        }
    }
}
```

- [ ] **Step 4: Implement ClaudeCategorizer**

```swift
// Sources/BudgetCore/Categorization/ClaudeCategorizer.swift
import Foundation

public struct CategorySuggestion: Equatable {
    public let categoryName: String
    public let confidence: Double
}

public protocol Categorizing {
    func suggestCategory(description: String, candidateCategoryNames: [String]) async throws -> CategorySuggestion?
}

public enum CategorizerError: Error {
    case requestFailed
    case unparsableResponse
}

public final class ClaudeCategorizer: Categorizing {
    private let apiKeyStore: APIKeyStoring
    private let session: URLSession
    private let model = "claude-sonnet-5"

    public init(apiKeyStore: APIKeyStoring, session: URLSession) {
        self.apiKeyStore = apiKeyStore
        self.session = session
    }

    public func suggestCategory(description: String, candidateCategoryNames: [String]) async throws -> CategorySuggestion? {
        guard let apiKey = apiKeyStore.getAPIKey(), !apiKey.isEmpty else { return nil }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let prompt = """
        Categorize this UK bank transaction description into exactly one of these categories: \(candidateCategoryNames.joined(separator: ", ")).
        Transaction description: "\(description)"
        Respond with ONLY a JSON object: {"categoryName": "<one of the categories above>", "confidence": <0.0-1.0>}
        """
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 256,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw CategorizerError.requestFailed
        }

        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = envelope["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String,
              let textData = text.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: textData) as? [String: Any],
              let categoryName = parsed["categoryName"] as? String,
              let confidence = parsed["confidence"] as? Double else {
            throw CategorizerError.unparsableResponse
        }

        return CategorySuggestion(categoryName: categoryName, confidence: confidence)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ClaudeCategorizerTests`
Expected: 2 tests, PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/BudgetCore/Support/KeychainAPIKeyStore.swift Sources/BudgetCore/Categorization/ClaudeCategorizer.swift Tests/BudgetCoreTests/ClaudeCategorizerTests.swift
git commit -m "Add Keychain API key store and Claude categorization fallback"
```

### Task 11: CategorizationService orchestrating rules and LLM fallback

**Files:**
- Create: `Sources/BudgetCore/Categorization/CategorizationService.swift`
- Test: `Tests/BudgetCoreTests/CategorizationServiceTests.swift`

**Interfaces:**
- Consumes: `RuleMatcher` (Task 9), `Categorizing` (Task 10), `Category`, `Rule`
- Produces: `CategorizationResult` (`categoryId: Int64?`, `source: CategorizedBy`, `confidence: Double`), `CategorizationService` (`init(categorizer: Categorizing)`, `func categorize(description: String, rules: [Rule], categories: [Category]) async -> CategorizationResult`)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BudgetCoreTests/CategorizationServiceTests.swift
import XCTest
@testable import BudgetCore

final class FakeCategorizer: Categorizing {
    var stubbedSuggestion: CategorySuggestion?
    func suggestCategory(description: String, candidateCategoryNames: [String]) async throws -> CategorySuggestion? {
        stubbedSuggestion
    }
}

final class CategorizationServiceTests: XCTestCase {
    let groceries = Category(id: 1, name: "Groceries", type: .expense)
    let eatingOut = Category(id: 2, name: "Eating Out", type: .expense)

    func testRuleMatchWinsOverLLM() async {
        let rule = Rule(id: 1, matchPattern: "SAINSBURYS", matchType: .contains, categoryId: 1, priority: 10)
        let fake = FakeCategorizer()
        fake.stubbedSuggestion = CategorySuggestion(categoryName: "Eating Out", confidence: 0.9)
        let service = CategorizationService(categorizer: fake)

        let result = await service.categorize(description: "SAINSBURYS LONDON", rules: [rule], categories: [groceries, eatingOut])
        XCTAssertEqual(result.categoryId, 1)
        XCTAssertEqual(result.source, .rule)
        XCTAssertEqual(result.confidence, 1.0)
    }

    func testFallsBackToLLMWhenNoRuleMatches() async {
        let fake = FakeCategorizer()
        fake.stubbedSuggestion = CategorySuggestion(categoryName: "Eating Out", confidence: 0.75)
        let service = CategorizationService(categorizer: fake)

        let result = await service.categorize(description: "NANDOS CROYDON", rules: [], categories: [groceries, eatingOut])
        XCTAssertEqual(result.categoryId, 2)
        XCTAssertEqual(result.source, .llm)
        XCTAssertEqual(result.confidence, 0.75)
    }

    func testUncategorizedWhenNoRuleAndNoLLMSuggestion() async {
        let fake = FakeCategorizer()
        fake.stubbedSuggestion = nil
        let service = CategorizationService(categorizer: fake)

        let result = await service.categorize(description: "UNKNOWN MERCHANT", rules: [], categories: [groceries, eatingOut])
        XCTAssertNil(result.categoryId)
        XCTAssertEqual(result.source, .none)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter CategorizationServiceTests`
Expected: FAIL (no such type `CategorizationService`)

- [ ] **Step 3: Implement CategorizationService**

```swift
// Sources/BudgetCore/Categorization/CategorizationService.swift
import Foundation

public struct CategorizationResult: Equatable {
    public let categoryId: Int64?
    public let source: CategorizedBy
    public let confidence: Double
}

public final class CategorizationService {
    private let categorizer: Categorizing

    public init(categorizer: Categorizing) {
        self.categorizer = categorizer
    }

    public func categorize(description: String, rules: [Rule], categories: [Category]) async -> CategorizationResult {
        if let rule = RuleMatcher.match(description: description, rules: rules) {
            return CategorizationResult(categoryId: rule.categoryId, source: .rule, confidence: 1.0)
        }

        let candidateNames = categories.map(\.name)
        if let suggestion = try? await categorizer.suggestCategory(description: description, candidateCategoryNames: candidateNames),
           let matchedCategory = categories.first(where: { $0.name == suggestion.categoryName }) {
            return CategorizationResult(categoryId: matchedCategory.id, source: .llm, confidence: suggestion.confidence)
        }

        return CategorizationResult(categoryId: nil, source: .none, confidence: 0.0)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CategorizationServiceTests`
Expected: 3 tests, PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/BudgetCore/Categorization/CategorizationService.swift Tests/BudgetCoreTests/CategorizationServiceTests.swift
git commit -m "Add CategorizationService orchestrating rules and LLM fallback"
```

### Task 12: RuleLearner and ImportCoordinator (staging + commit + dedup)

**Files:**
- Create: `Sources/BudgetCore/Categorization/RuleLearner.swift`
- Create: `Sources/BudgetCore/Import/ImportCoordinator.swift`
- Test: `Tests/BudgetCoreTests/ImportCoordinatorTests.swift`

**Interfaces:**
- Consumes: `CSVStatementParser` (Task 7), `TransactionFingerprint` (Task 8), `CategorizationService` (Task 11), `Transaction`, `ImportBatch`, `Rule`
- Produces: `RuleLearner.learnFromCorrection(description: String, categoryId: Int64, db: Database) throws`; `StagedTransaction` (`id: UUID`, `parsed: ParsedTransaction`, `suggestedCategoryId: Int64?`, `source: CategorizedBy`, `confidence: Double`); `StagedImport` (`staged: [StagedTransaction]`, `duplicateCount: Int`); `ImportDecision` (`stagedId: UUID`, `finalCategoryId: Int64?`); `ImportCoordinator` (`init(dbQueue: DatabaseQueue, categorizationService: CategorizationService)`, `func stageCSVImport(csvText: String, profile: ImportProfile, accountId: Int64) async throws -> StagedImport`, `func commit(accountId: Int64, sourceFileName: String, staged: [StagedTransaction], decisions: [ImportDecision]) throws`)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BudgetCoreTests/ImportCoordinatorTests.swift
import XCTest
import GRDB
@testable import BudgetCore

final class ImportCoordinatorTests: XCTestCase {
    func makeSeededManager() throws -> (DatabaseManager, Account, ImportProfile) {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in try CategorySeeder.seedDefaults(db) }
        var account = Account(name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        try manager.dbQueue.write { db in try account.insert(db) }
        let profile = ImportProfile(accountId: account.id!, format: .csv, csvDelimiter: ",", csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2, csvDateFormat: "dd/MM/yyyy")
        return (manager, account, profile)
    }

    func testStagingCategorizesViaRuleAndSkipsExistingDuplicates() async throws {
        let (manager, account, profile) = try makeSeededManager()
        let groceries = try manager.dbQueue.read { db in try Category.filter(Column("name") == "Groceries").fetchOne(db)! }
        try manager.dbQueue.write { db in
            var rule = Rule(matchPattern: "SAINSBURYS", matchType: .contains, categoryId: groceries.id!, priority: 10)
            try rule.insert(db)
        }
        let fake = FakeCategorizer()
        let service = CategorizationService(categorizer: fake)
        let coordinator = ImportCoordinator(dbQueue: manager.dbQueue, categorizationService: service)

        let csv = "Date,Description,Amount\n01/07/2026,SAINSBURYS LONDON,-45.64\n02/07/2026,UNKNOWN SHOP,-10.00"
        let staged = try await coordinator.stageCSVImport(csvText: csv, profile: profile, accountId: account.id!)
        XCTAssertEqual(staged.staged.count, 2)
        XCTAssertEqual(staged.staged[0].suggestedCategoryId, groceries.id)
        XCTAssertEqual(staged.staged[0].source, .rule)
        XCTAssertEqual(staged.staged[1].suggestedCategoryId, nil)

        // Commit, then re-stage the same CSV — should be skipped as duplicates.
        let decisions = staged.staged.map { ImportDecision(stagedId: $0.id, finalCategoryId: $0.suggestedCategoryId ?? groceries.id!) }
        try coordinator.commit(accountId: account.id!, sourceFileName: "july.csv", staged: staged.staged, decisions: decisions)

        let restaged = try await coordinator.stageCSVImport(csvText: csv, profile: profile, accountId: account.id!)
        XCTAssertEqual(restaged.staged.count, 0)
        XCTAssertEqual(restaged.duplicateCount, 2)
    }

    func testCorrectingASuggestionCreatesARule() async throws {
        let (manager, account, profile) = try makeSeededManager()
        let eatingOut = try manager.dbQueue.read { db in try Category.filter(Column("name") == "Eating Out").fetchOne(db)! }
        let fake = FakeCategorizer()
        fake.stubbedSuggestion = nil
        let service = CategorizationService(categorizer: fake)
        let coordinator = ImportCoordinator(dbQueue: manager.dbQueue, categorizationService: service)

        let csv = "Date,Description,Amount\n01/07/2026,NANDOS CROYDON,-22.50"
        let staged = try await coordinator.stageCSVImport(csvText: csv, profile: profile, accountId: account.id!)
        XCTAssertNil(staged.staged[0].suggestedCategoryId)

        let decisions = [ImportDecision(stagedId: staged.staged[0].id, finalCategoryId: eatingOut.id!)]
        try coordinator.commit(accountId: account.id!, sourceFileName: "july.csv", staged: staged.staged, decisions: decisions)

        let rules = try manager.dbQueue.read { db in try Rule.fetchAll(db) }
        XCTAssertTrue(rules.contains { $0.matchPattern.contains("NANDOS CROYDON") && $0.categoryId == eatingOut.id })
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ImportCoordinatorTests`
Expected: FAIL (no such types)

- [ ] **Step 3: Implement RuleLearner**

```swift
// Sources/BudgetCore/Categorization/RuleLearner.swift
import GRDB

public enum RuleLearner {
    /// Creates (or reuses) a "contains" rule from a manually-corrected transaction description.
    public static func learnFromCorrection(description: String, categoryId: Int64, db: Database) throws {
        let pattern = description.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return }
        if var existing = try Rule.filter(Column("matchPattern") == pattern).fetchOne(db) {
            existing.categoryId = categoryId
            try existing.update(db)
        } else {
            var rule = Rule(matchPattern: pattern, matchType: .contains, categoryId: categoryId, priority: pattern.count)
            try rule.insert(db)
        }
    }
}
```

- [ ] **Step 4: Implement ImportCoordinator**

```swift
// Sources/BudgetCore/Import/ImportCoordinator.swift
import Foundation
import GRDB

public struct StagedTransaction: Equatable, Identifiable {
    public let id: UUID
    public let parsed: ParsedTransaction
    public let suggestedCategoryId: Int64?
    public let source: CategorizedBy
    public let confidence: Double

    public init(id: UUID = UUID(), parsed: ParsedTransaction, suggestedCategoryId: Int64?, source: CategorizedBy, confidence: Double) {
        self.id = id
        self.parsed = parsed
        self.suggestedCategoryId = suggestedCategoryId
        self.source = source
        self.confidence = confidence
    }
}

public struct StagedImport {
    public let staged: [StagedTransaction]
    public let duplicateCount: Int
}

public struct ImportDecision {
    public let stagedId: UUID
    public let finalCategoryId: Int64?

    public init(stagedId: UUID, finalCategoryId: Int64?) {
        self.stagedId = stagedId
        self.finalCategoryId = finalCategoryId
    }
}

public final class ImportCoordinator {
    private let dbQueue: DatabaseQueue
    private let categorizationService: CategorizationService

    public init(dbQueue: DatabaseQueue, categorizationService: CategorizationService) {
        self.dbQueue = dbQueue
        self.categorizationService = categorizationService
    }

    public func stageCSVImport(csvText: String, profile: ImportProfile, accountId: Int64) async throws -> StagedImport {
        let parseResult = CSVStatementParser.parse(csvText: csvText, profile: profile)
        let existingFingerprints = try dbQueue.read { db in
            try Set(String.fetchAll(db, sql: "SELECT fingerprint FROM transaction_ WHERE accountId = ?", arguments: [accountId]))
        }
        let categories = try dbQueue.read { db in try Category.fetchAll(db) }
        let rules = try dbQueue.read { db in try Rule.fetchAll(db) }

        var staged: [StagedTransaction] = []
        var duplicateCount = 0
        for parsedTransaction in parseResult.transactions {
            let fingerprint = TransactionFingerprint.compute(
                accountId: accountId, date: parsedTransaction.date,
                amountMinorUnits: parsedTransaction.amountMinorUnits, description: parsedTransaction.rawDescription
            )
            if existingFingerprints.contains(fingerprint) {
                duplicateCount += 1
                continue
            }
            let result = await categorizationService.categorize(description: parsedTransaction.rawDescription, rules: rules, categories: categories)
            staged.append(StagedTransaction(parsed: parsedTransaction, suggestedCategoryId: result.categoryId, source: result.source, confidence: result.confidence))
        }
        return StagedImport(staged: staged, duplicateCount: duplicateCount)
    }

    public func commit(accountId: Int64, sourceFileName: String, staged: [StagedTransaction], decisions: [ImportDecision]) throws {
        let decisionById = Dictionary(uniqueKeysWithValues: decisions.map { ($0.stagedId, $0.finalCategoryId) })
        try dbQueue.write { db in
            var batch = ImportBatch(accountId: accountId, sourceFileName: sourceFileName, importedAt: Date())
            try batch.insert(db)
            for stagedTransaction in staged {
                guard let finalCategoryId = decisionById[stagedTransaction.id] ?? nil else { continue }
                let fingerprint = TransactionFingerprint.compute(
                    accountId: accountId, date: stagedTransaction.parsed.date,
                    amountMinorUnits: stagedTransaction.parsed.amountMinorUnits, description: stagedTransaction.parsed.rawDescription
                )
                let wasOverridden = finalCategoryId != stagedTransaction.suggestedCategoryId
                var transaction = Transaction(
                    importBatchId: batch.id!, accountId: accountId, date: stagedTransaction.parsed.date,
                    rawDescription: stagedTransaction.parsed.rawDescription, amountMinorUnits: stagedTransaction.parsed.amountMinorUnits,
                    categoryId: finalCategoryId, status: .confirmed,
                    categorizedBy: wasOverridden ? .manual : stagedTransaction.source,
                    fingerprint: fingerprint
                )
                try transaction.insert(db)
                if wasOverridden {
                    try RuleLearner.learnFromCorrection(description: stagedTransaction.parsed.rawDescription, categoryId: finalCategoryId, db: db)
                }
            }
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ImportCoordinatorTests`
Expected: 2 tests, PASS

- [ ] **Step 6: Run the full BudgetCore suite to check for regressions**

Run: `swift test`
Expected: all tests PASS

- [ ] **Step 7: Commit**

```bash
git add Sources/BudgetCore/Categorization/RuleLearner.swift Sources/BudgetCore/Import/ImportCoordinator.swift Tests/BudgetCoreTests/ImportCoordinatorTests.swift
git commit -m "Add RuleLearner and ImportCoordinator for staged CSV import"
```

### Task 13: ImportProfileStore

**Files:**
- Create: `Sources/BudgetCore/Import/ImportProfileStore.swift`
- Test: `Tests/BudgetCoreTests/ImportProfileStoreTests.swift`

**Interfaces:**
- Consumes: `ImportProfile` (Task 5)
- Produces: `ImportProfileStore` (`init(dbQueue: DatabaseQueue)`, `func find(accountId: Int64, format: ImportFormat) throws -> ImportProfile?`, `func save(_ profile: ImportProfile) throws -> ImportProfile`)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BudgetCoreTests/ImportProfileStoreTests.swift
import XCTest
@testable import BudgetCore

final class ImportProfileStoreTests: XCTestCase {
    func testSaveThenFindReturnsProfile() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        var account = Account(name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        try manager.dbQueue.write { db in try account.insert(db) }
        let store = ImportProfileStore(dbQueue: manager.dbQueue)

        let profile = ImportProfile(accountId: account.id!, format: .csv, csvDelimiter: ",", csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2, csvDateFormat: "dd/MM/yyyy")
        let saved = try store.save(profile)
        XCTAssertNotNil(saved.id)

        let found = try store.find(accountId: account.id!, format: .csv)
        XCTAssertEqual(found?.csvDateFormat, "dd/MM/yyyy")
    }

    func testFindReturnsNilWhenNoProfileExists() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let store = ImportProfileStore(dbQueue: manager.dbQueue)
        let found = try store.find(accountId: 999, format: .csv)
        XCTAssertNil(found)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ImportProfileStoreTests`
Expected: FAIL (no such type `ImportProfileStore`)

- [ ] **Step 3: Implement ImportProfileStore**

```swift
// Sources/BudgetCore/Import/ImportProfileStore.swift
import GRDB

public final class ImportProfileStore {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func find(accountId: Int64, format: ImportFormat) throws -> ImportProfile? {
        try dbQueue.read { db in
            try ImportProfile
                .filter(Column("accountId") == accountId && Column("format") == format.rawValue)
                .fetchOne(db)
        }
    }

    @discardableResult
    public func save(_ profile: ImportProfile) throws -> ImportProfile {
        var mutableProfile = profile
        try dbQueue.write { db in
            if let existing = try ImportProfile
                .filter(Column("accountId") == profile.accountId && Column("format") == profile.format.rawValue)
                .fetchOne(db) {
                mutableProfile.id = existing.id
                try mutableProfile.update(db)
            } else {
                try mutableProfile.insert(db)
            }
        }
        return mutableProfile
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ImportProfileStoreTests`
Expected: 2 tests, PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/BudgetCore/Import/ImportProfileStore.swift Tests/BudgetCoreTests/ImportProfileStoreTests.swift
git commit -m "Add ImportProfileStore for saving/reusing column mapping profiles"
```

### Task 14: Import, mapping wizard, and review UI

**Files:**
- Create: `App/Import/ImportViewModel.swift`
- Create: `App/Import/CSVMappingWizardView.swift`
- Create: `App/Import/ReviewView.swift`
- Create: `App/Import/ImportView.swift`
- Modify: `App/ContentView.swift` (add navigation to `ImportView`)

**Interfaces:**
- Consumes: `ImportCoordinator`, `StagedTransaction`, `ImportDecision` (Task 12), `ImportProfileStore` (Task 13), `Account`, `Category`
- Produces: `ImportViewModel` (`@Published var stagedRows: [ReviewRow]`, `func pickFileAndStage(account: Account) async`, `func commit() async throws`), `ReviewRow` (identifiable wrapper around a `StagedTransaction` plus a mutable `chosenCategoryId: Int64?`)

- [ ] **Step 1: Implement the view model**

```swift
// App/Import/ImportViewModel.swift
import Foundation
import BudgetCore
import GRDB

struct ReviewRow: Identifiable {
    let staged: StagedTransaction
    var chosenCategoryId: Int64?
    var id: UUID { staged.id }
}

@MainActor
final class ImportViewModel: ObservableObject {
    @Published var stagedRows: [ReviewRow] = []
    @Published var duplicateCount: Int = 0
    @Published var errorMessage: String?

    private let dbQueue: DatabaseQueue
    private let coordinator: ImportCoordinator
    private let profileStore: ImportProfileStore
    private var lastSourceFileName: String = ""
    private var lastAccountId: Int64 = 0

    init(dbQueue: DatabaseQueue, coordinator: ImportCoordinator, profileStore: ImportProfileStore) {
        self.dbQueue = dbQueue
        self.coordinator = coordinator
        self.profileStore = profileStore
    }

    func stageCSV(fileURL: URL, account: Account) async {
        do {
            let csvText = try String(contentsOf: fileURL, encoding: .utf8)
            guard let profile = try profileStore.find(accountId: account.id!, format: .csv) else {
                errorMessage = "No column mapping saved for this account yet. Run the mapping wizard first."
                return
            }
            lastSourceFileName = fileURL.lastPathComponent
            lastAccountId = account.id!
            let result = try await coordinator.stageCSVImport(csvText: csvText, profile: profile, accountId: account.id!)
            stagedRows = result.staged.map { ReviewRow(staged: $0, chosenCategoryId: $0.suggestedCategoryId) }
            duplicateCount = result.duplicateCount
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func commit() throws {
        let decisions = stagedRows.map { ImportDecision(stagedId: $0.staged.id, finalCategoryId: $0.chosenCategoryId) }
        try coordinator.commit(accountId: lastAccountId, sourceFileName: lastSourceFileName, staged: stagedRows.map(\.staged), decisions: decisions)
        stagedRows = []
    }
}
```

- [ ] **Step 2: Implement the CSV mapping wizard view**

```swift
// App/Import/CSVMappingWizardView.swift
import SwiftUI
import BudgetCore

struct CSVMappingWizardView: View {
    let account: Account
    let sampleHeaderRow: [String]
    let onSave: (ImportProfile) -> Void

    @State private var dateColumn = 0
    @State private var descriptionColumn = 1
    @State private var amountColumn = 2
    @State private var dateFormat = "dd/MM/yyyy"

    var body: some View {
        Form {
            Picker("Date column", selection: $dateColumn) {
                ForEach(sampleHeaderRow.indices, id: \.self) { i in Text(sampleHeaderRow[i]).tag(i) }
            }
            Picker("Description column", selection: $descriptionColumn) {
                ForEach(sampleHeaderRow.indices, id: \.self) { i in Text(sampleHeaderRow[i]).tag(i) }
            }
            Picker("Amount column", selection: $amountColumn) {
                ForEach(sampleHeaderRow.indices, id: \.self) { i in Text(sampleHeaderRow[i]).tag(i) }
            }
            TextField("Date format (e.g. dd/MM/yyyy)", text: $dateFormat)
            Button("Save mapping") {
                let profile = ImportProfile(
                    accountId: account.id!, format: .csv, csvDelimiter: ",",
                    csvDateColumnIndex: dateColumn, csvDescriptionColumnIndex: descriptionColumn,
                    csvAmountColumnIndex: amountColumn, csvDateFormat: dateFormat
                )
                onSave(profile)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
```

- [ ] **Step 3: Implement the review list view**

```swift
// App/Import/ReviewView.swift
import SwiftUI
import BudgetCore

struct ReviewView: View {
    @ObservedObject var viewModel: ImportViewModel
    let categories: [Category]
    let onCommitted: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            if viewModel.duplicateCount > 0 {
                Text("\(viewModel.duplicateCount) duplicate transaction(s) skipped")
                    .foregroundStyle(.secondary)
            }
            Table(viewModel.stagedRows) {
                TableColumn("Date") { row in Text(row.staged.parsed.date.formatted(date: .abbreviated, time: .omitted)) }
                TableColumn("Description") { row in Text(row.staged.parsed.rawDescription) }
                TableColumn("Amount") { row in Text(Money.format(row.staged.parsed.amountMinorUnits, currency: .gbp)) }
                TableColumn("Category") { row in
                    categoryPicker(for: row)
                }
                TableColumn("Source") { row in Text(row.staged.source.rawValue) }
            }
            Button("Confirm all \(viewModel.stagedRows.count) transactions") {
                try? viewModel.commit()
                onCommitted()
            }
            .disabled(viewModel.stagedRows.isEmpty)
        }
        .padding()
    }

    private func categoryPicker(for row: ReviewRow) -> some View {
        let binding = Binding<Int64?>(
            get: { row.chosenCategoryId },
            set: { newValue in
                if let index = viewModel.stagedRows.firstIndex(where: { $0.id == row.id }) {
                    viewModel.stagedRows[index].chosenCategoryId = newValue
                }
            }
        )
        return Picker("", selection: binding) {
            Text("Uncategorized").tag(Int64?.none)
            ForEach(categories) { category in Text(category.name).tag(Int64?.some(category.id!)) }
        }
        .labelsHidden()
    }
}
```

- [ ] **Step 4: Implement the top-level import view tying picker, wizard, and review together**

```swift
// App/Import/ImportView.swift
import SwiftUI
import BudgetCore
import UniformTypeIdentifiers

struct ImportView: View {
    @StateObject var viewModel: ImportViewModel
    let account: Account
    let categories: [Category]
    let profileStore: ImportProfileStore

    @State private var showFilePicker = false
    @State private var pendingHeaderRowForWizard: [String]?
    @State private var pendingFileURL: URL?

    var body: some View {
        VStack {
            if !viewModel.stagedRows.isEmpty {
                ReviewView(viewModel: viewModel, categories: categories) {}
            } else {
                Button("Import CSV statement…") { showFilePicker = true }
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.commaSeparatedText]) { result in
            guard case .success(let url) = result else { return }
            handlePickedFile(url)
        }
        .sheet(item: Binding(get: { pendingHeaderRowForWizard.map { Wrapped(value: $0) } }, set: { _ in pendingHeaderRowForWizard = nil })) { wrapped in
            CSVMappingWizardView(account: account, sampleHeaderRow: wrapped.value) { profile in
                try? profileStore.save(profile)
                pendingHeaderRowForWizard = nil
                if let url = pendingFileURL {
                    Task { await viewModel.stageCSV(fileURL: url, account: account) }
                }
            }
        }
    }

    private func handlePickedFile(_ url: URL) {
        pendingFileURL = url
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let firstLine = text.split(separator: "\n").first else { return }
        let existingProfile = try? profileStore.find(accountId: account.id!, format: .csv)
        if existingProfile != nil {
            Task { await viewModel.stageCSV(fileURL: url, account: account) }
        } else {
            pendingHeaderRowForWizard = CSVRowSplitter.split(line: String(firstLine), delimiter: ",")
        }
    }
}

private struct Wrapped: Identifiable {
    let value: [String]
    var id: String { value.joined() }
}
```

- [ ] **Step 5: Wire ImportView into ContentView**

```swift
// App/ContentView.swift
import SwiftUI
import BudgetCore

struct ContentView: View {
    var body: some View {
        Text("Budget — v\(BudgetCore.version) — Import screen wired in Task 14")
            .padding()
        // NOTE: full navigation shell (sidebar linking Import / Review / Budget grid /
        // Forecast / Net worth) is built in Task 24. For now this task's manual
        // verification launches ImportView directly (see Step 6).
    }
}
```

- [ ] **Step 6: Build and manually verify**

Run:
```bash
xcodegen generate
xcodebuild -project Budget.xcodeproj -scheme Budget -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`. Manually verify by temporarily pointing `BudgetApp`'s `WindowGroup` at an `ImportView` constructed with a real `DatabaseManager(path:)` pointed at a scratch SQLite file, an `Account` seeded via a debug button, and a small real CSV file — confirm the mapping wizard appears on first import, saved profile is reused on the next import, staged rows show suggested categories, and confirming writes rows into the `transaction_` table (check via `sqlite3` on the scratch DB file).

- [ ] **Step 7: Commit**

```bash
git add App/Import Tests/BudgetCoreTests App/ContentView.swift
git commit -m "Add CSV import, mapping wizard, and review UI"
```

---

## Phase 3: PDF Import

### Task 15: PDFLayoutConfig and PDFLineParser (pure logic)

**Files:**
- Create: `Sources/BudgetCore/Import/PDFLayoutConfig.swift`
- Create: `Sources/BudgetCore/Import/PDFLineParser.swift`
- Test: `Tests/BudgetCoreTests/PDFLineParserTests.swift`

**Interfaces:**
- Produces: `PDFLayoutConfig` (`Codable`: `regexPattern: String` with exactly 3 capture groups in order date/description/amount, `dateFormat: String`, `func encoded() throws -> String`, `static func decode(_ json: String) throws -> PDFLayoutConfig`); `PDFParseResult` (`transactions: [ParsedTransaction]`, `unparsedLines: [String]`); `PDFLineParser.parse(lines: [String], config: PDFLayoutConfig) -> PDFParseResult`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BudgetCoreTests/PDFLineParserTests.swift
import XCTest
@testable import BudgetCore

final class PDFLineParserTests: XCTestCase {
    // A typical Lloyds PDF statement line, extracted as one line of text:
    // "01 Jul 26   SAINSBURYS LONDON SW1        45.64 DR"
    let lloydsConfig = PDFLayoutConfig(
        regexPattern: #"^(\d{2} \w{3} \d{2})\s+(.+?)\s+([\d.]+)\s*(?:DR|CR)?$"#,
        dateFormat: "dd MMM yy"
    )

    func testParsesDebitLineAsNegativeAmount() {
        let result = PDFLineParser.parse(lines: ["01 Jul 26   SAINSBURYS LONDON SW1        45.64 DR"], config: lloydsConfig)
        XCTAssertEqual(result.transactions.count, 1)
        XCTAssertEqual(result.transactions[0].amountMinorUnits, -4564)
        XCTAssertEqual(result.transactions[0].rawDescription, "SAINSBURYS LONDON SW1")
    }

    func testParsesCreditLineAsPositiveAmount() {
        let result = PDFLineParser.parse(lines: ["02 Jul 26   SALARY PAYMENT        2800.00 CR"], config: lloydsConfig)
        XCTAssertEqual(result.transactions[0].amountMinorUnits, 280000)
    }

    func testNonMatchingLinesAreFlaggedUnparsed() {
        let result = PDFLineParser.parse(lines: ["Statement period: 01 Jul 2026 to 31 Jul 2026", "01 Jul 26   SAINSBURYS LONDON SW1        45.64 DR"], config: lloydsConfig)
        XCTAssertEqual(result.transactions.count, 1)
        XCTAssertEqual(result.unparsedLines.count, 1)
    }

    func testConfigRoundTripsThroughJSON() throws {
        let encoded = try lloydsConfig.encoded()
        let decoded = try PDFLayoutConfig.decode(encoded)
        XCTAssertEqual(decoded.regexPattern, lloydsConfig.regexPattern)
        XCTAssertEqual(decoded.dateFormat, lloydsConfig.dateFormat)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter PDFLineParserTests`
Expected: FAIL (no such types)

- [ ] **Step 3: Implement PDFLayoutConfig**

```swift
// Sources/BudgetCore/Import/PDFLayoutConfig.swift
import Foundation

public struct PDFLayoutConfig: Codable, Equatable {
    /// Must contain exactly 3 capture groups, in order: date, description, amount.
    /// The line is expected to optionally end in "DR" (debit, negative) or "CR" (credit, positive);
    /// absence of a suffix is treated as a debit.
    public let regexPattern: String
    public let dateFormat: String

    public init(regexPattern: String, dateFormat: String) {
        self.regexPattern = regexPattern
        self.dateFormat = dateFormat
    }

    public func encoded() throws -> String {
        String(data: try JSONEncoder().encode(self), encoding: .utf8)!
    }

    public static func decode(_ json: String) throws -> PDFLayoutConfig {
        try JSONDecoder().decode(PDFLayoutConfig.self, from: Data(json.utf8))
    }
}
```

- [ ] **Step 4: Implement PDFLineParser**

```swift
// Sources/BudgetCore/Import/PDFLineParser.swift
import Foundation

public struct PDFParseResult {
    public let transactions: [ParsedTransaction]
    public let unparsedLines: [String]
}

public enum PDFLineParser {
    public static func parse(lines: [String], config: PDFLayoutConfig) -> PDFParseResult {
        guard let regex = try? NSRegularExpression(pattern: config.regexPattern) else {
            return PDFParseResult(transactions: [], unparsedLines: lines)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = config.dateFormat
        formatter.locale = Locale(identifier: "en_GB")

        var transactions: [ParsedTransaction] = []
        var unparsedLines: [String] = []

        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges >= 4,
                  let dateRange = Range(match.range(at: 1), in: line),
                  let descriptionRange = Range(match.range(at: 2), in: line),
                  let amountRange = Range(match.range(at: 3), in: line) else {
                unparsedLines.append(line)
                continue
            }
            let dateString = String(line[dateRange])
            let description = String(line[descriptionRange]).trimmingCharacters(in: .whitespaces)
            let amountString = String(line[amountRange])

            guard let date = formatter.date(from: dateString),
                  let magnitude = Decimal(string: amountString) else {
                unparsedLines.append(line)
                continue
            }

            let isCredit = line.uppercased().hasSuffix("CR")
            let signedMinorUnits = NSDecimalNumber(decimal: magnitude * 100).intValue * (isCredit ? 1 : -1)
            transactions.append(ParsedTransaction(date: date, rawDescription: description, amountMinorUnits: signedMinorUnits))
        }

        return PDFParseResult(transactions: transactions, unparsedLines: unparsedLines)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter PDFLineParserTests`
Expected: 4 tests, PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/BudgetCore/Import/PDFLayoutConfig.swift Sources/BudgetCore/Import/PDFLineParser.swift Tests/BudgetCoreTests/PDFLineParserTests.swift
git commit -m "Add PDFLayoutConfig and PDFLineParser"
```

### Task 16: PDFTextExtractor, ImportCoordinator PDF staging, and PDF import UI

**Files:**
- Create: `Sources/BudgetCore/Import/PDFTextExtractor.swift`
- Modify: `Sources/BudgetCore/Import/ImportCoordinator.swift` (add `stagePDFImport`)
- Create: `App/Import/PDFLayoutWizardView.swift`
- Modify: `App/Import/ImportView.swift` (add a PDF import entry point)
- Test: `Tests/BudgetCoreTests/ImportCoordinatorPDFTests.swift`

**Interfaces:**
- Consumes: `PDFLineParser`, `PDFLayoutConfig` (Task 15)
- Produces: `PDFTextExtractor.extractLines(from url: URL) throws -> [String]`; `ImportCoordinator.stagePDFImport(lines: [String], config: PDFLayoutConfig, accountId: Int64) async throws -> StagedImport`

- [ ] **Step 1: Write the failing test for the new coordinator method (using raw lines, no real PDF needed)**

```swift
// Tests/BudgetCoreTests/ImportCoordinatorPDFTests.swift
import XCTest
import GRDB
@testable import BudgetCore

final class ImportCoordinatorPDFTests: XCTestCase {
    func testStagePDFImportCategorizesAndDedups() async throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in try CategorySeeder.seedDefaults(db) }
        var account = Account(name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        try manager.dbQueue.write { db in try account.insert(db) }
        let groceries = try manager.dbQueue.read { db in try Category.filter(Column("name") == "Groceries").fetchOne(db)! }
        try manager.dbQueue.write { db in
            var rule = Rule(matchPattern: "SAINSBURYS", matchType: .contains, categoryId: groceries.id!, priority: 10)
            try rule.insert(db)
        }

        let coordinator = ImportCoordinator(dbQueue: manager.dbQueue, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        let config = PDFLayoutConfig(regexPattern: #"^(\d{2} \w{3} \d{2})\s+(.+?)\s+([\d.]+)\s*(?:DR|CR)?$"#, dateFormat: "dd MMM yy")
        let lines = ["01 Jul 26   SAINSBURYS LONDON SW1        45.64 DR"]

        let staged = try await coordinator.stagePDFImport(lines: lines, config: config, accountId: account.id!)
        XCTAssertEqual(staged.staged.count, 1)
        XCTAssertEqual(staged.staged[0].suggestedCategoryId, groceries.id)

        let decisions = [ImportDecision(stagedId: staged.staged[0].id, finalCategoryId: groceries.id)]
        try coordinator.commit(accountId: account.id!, sourceFileName: "statement.pdf", staged: staged.staged, decisions: decisions)

        let restaged = try await coordinator.stagePDFImport(lines: lines, config: config, accountId: account.id!)
        XCTAssertEqual(restaged.staged.count, 0)
        XCTAssertEqual(restaged.duplicateCount, 1)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ImportCoordinatorPDFTests`
Expected: FAIL (no method `stagePDFImport`)

- [ ] **Step 3: Implement PDFTextExtractor**

```swift
// Sources/BudgetCore/Import/PDFTextExtractor.swift
import PDFKit

public enum PDFTextExtractionError: Error {
    case couldNotOpenDocument
}

public enum PDFTextExtractor {
    public static func extractLines(from url: URL) throws -> [String] {
        guard let document = PDFDocument(url: url) else {
            throw PDFTextExtractionError.couldNotOpenDocument
        }
        var lines: [String] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex), let text = page.string else { continue }
            lines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
        }
        return lines
    }
}
```

- [ ] **Step 4: Add stagePDFImport to ImportCoordinator**

```swift
// Sources/BudgetCore/Import/ImportCoordinator.swift
// Add this method inside the ImportCoordinator class, alongside stageCSVImport:

    public func stagePDFImport(lines: [String], config: PDFLayoutConfig, accountId: Int64) async throws -> StagedImport {
        let parseResult = PDFLineParser.parse(lines: lines, config: config)
        let existingFingerprints = try dbQueue.read { db in
            try Set(String.fetchAll(db, sql: "SELECT fingerprint FROM transaction_ WHERE accountId = ?", arguments: [accountId]))
        }
        let categories = try dbQueue.read { db in try Category.fetchAll(db) }
        let rules = try dbQueue.read { db in try Rule.fetchAll(db) }

        var staged: [StagedTransaction] = []
        var duplicateCount = 0
        for parsedTransaction in parseResult.transactions {
            let fingerprint = TransactionFingerprint.compute(
                accountId: accountId, date: parsedTransaction.date,
                amountMinorUnits: parsedTransaction.amountMinorUnits, description: parsedTransaction.rawDescription
            )
            if existingFingerprints.contains(fingerprint) {
                duplicateCount += 1
                continue
            }
            let result = await categorizationService.categorize(description: parsedTransaction.rawDescription, rules: rules, categories: categories)
            staged.append(StagedTransaction(parsed: parsedTransaction, suggestedCategoryId: result.categoryId, source: result.source, confidence: result.confidence))
        }
        return StagedImport(staged: staged, duplicateCount: duplicateCount)
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ImportCoordinatorPDFTests`
Expected: 1 test, PASS

- [ ] **Step 6: Implement the PDF layout wizard view (regex-based, with a live preview against the first few extracted lines)**

```swift
// App/Import/PDFLayoutWizardView.swift
import SwiftUI
import BudgetCore

struct PDFLayoutWizardView: View {
    let account: Account
    let sampleLines: [String]
    let onSave: (ImportProfile) -> Void

    @State private var regexPattern = #"^(\d{2} \w{3} \d{2})\s+(.+?)\s+([\d.]+)\s*(?:DR|CR)?$"#
    @State private var dateFormat = "dd MMM yy"

    private var previewResult: PDFParseResult {
        PDFLineParser.parse(lines: Array(sampleLines.prefix(10)), config: PDFLayoutConfig(regexPattern: regexPattern, dateFormat: dateFormat))
    }

    var body: some View {
        Form {
            Text("Paste the sample lines below into a regex with 3 capture groups: date, description, amount. Lines ending 'CR' are treated as credits, everything else as a debit.")
                .font(.caption)
            TextField("Regex pattern", text: $regexPattern)
            TextField("Date format", text: $dateFormat)
            List(sampleLines.prefix(10), id: \.self) { line in Text(line).font(.system(.body, design: .monospaced)) }
            Text("Preview: \(previewResult.transactions.count) matched, \(previewResult.unparsedLines.count) unmatched")
            Button("Save layout") {
                guard let config = try? PDFLayoutConfig(regexPattern: regexPattern, dateFormat: dateFormat).encoded() else { return }
                let profile = ImportProfile(accountId: account.id!, format: .pdf, pdfLayoutConfig: config)
                onSave(profile)
            }
        }
        .padding()
        .frame(width: 520)
    }
}
```

- [ ] **Step 7: Wire a PDF import entry point into ImportView**

```swift
// App/Import/ImportView.swift
// Add alongside the existing "Import CSV statement…" button:

Button("Import PDF statement…") { showPDFPicker = true }
    .fileImporter(isPresented: $showPDFPicker, allowedContentTypes: [.pdf]) { result in
        guard case .success(let url) = result,
              let lines = try? PDFTextExtractor.extractLines(from: url) else { return }
        if let existingProfile = try? profileStore.find(accountId: account.id!, format: .pdf),
           let configJSON = existingProfile.pdfLayoutConfig,
           let config = try? PDFLayoutConfig.decode(configJSON) {
            Task {
                if let staged = try? await viewModel.stagePDF(lines: lines, config: config, account: account) {
                    _ = staged
                }
            }
        } else {
            pendingPDFLines = lines
        }
    }
// Add @State private var showPDFPicker = false and @State private var pendingPDFLines: [String]?
// alongside the existing @State vars, and a second .sheet(item:) presenting
// PDFLayoutWizardView(account: account, sampleLines: pendingPDFLines ?? []) { profile in
//     try? profileStore.save(profile)
//     pendingPDFLines = nil
// } mirroring the CSV wizard sheet wiring from Task 14 Step 4.
```

Also add to `ImportViewModel` (Task 14):

```swift
// App/Import/ImportViewModel.swift
// Add inside ImportViewModel:

    func stagePDF(lines: [String], config: PDFLayoutConfig, account: Account) async throws {
        lastSourceFileName = "statement.pdf"
        lastAccountId = account.id!
        let result = try await coordinator.stagePDFImport(lines: lines, config: config, accountId: account.id!)
        stagedRows = result.staged.map { ReviewRow(staged: $0, chosenCategoryId: $0.suggestedCategoryId) }
        duplicateCount = result.duplicateCount
    }
```

- [ ] **Step 8: Build and manually verify**

Run:
```bash
xcodegen generate
xcodebuild -project Budget.xcodeproj -scheme Budget -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`. Manually verify with one real (anonymized, or your own) PDF bank statement: confirm text extraction produces readable lines, the layout wizard's live preview shows a reasonable match count as you adjust the regex, saving reuses the profile on a second PDF from the same account, and unparsed lines surface rather than silently vanishing.

- [ ] **Step 9: Commit**

```bash
git add Sources/BudgetCore/Import/PDFTextExtractor.swift Sources/BudgetCore/Import/ImportCoordinator.swift App/Import Tests/BudgetCoreTests/ImportCoordinatorPDFTests.swift
git commit -m "Add PDF text extraction, PDF staging, and layout wizard UI"
```

---

## Phase 4: Pay Periods

### Task 17: PayPeriod model

**Files:**
- Create: `Sources/BudgetCore/Models/PayPeriod.swift`
- Modify: `Sources/BudgetCore/Database/DatabaseManager.swift:registerMigrations`
- Test: `Tests/BudgetCoreTests/PayPeriodModelTests.swift`

**Interfaces:**
- Produces: `PayPeriod` (`id: Int64?`, `startDate: Date`, `endDate: Date`, `type: PayPeriodType`), `PayPeriodType` enum (`.actual`, `.projected`)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BudgetCoreTests/PayPeriodModelTests.swift
import XCTest
import GRDB
@testable import BudgetCore

final class PayPeriodModelTests: XCTestCase {
    func testInsertAndFetchPayPeriod() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        var period = PayPeriod(startDate: Date(timeIntervalSince1970: 0), endDate: Date(timeIntervalSince1970: 2_500_000), type: .actual)
        try manager.dbQueue.write { db in try period.insert(db) }
        let fetched = try manager.dbQueue.read { db in try PayPeriod.fetchOne(db) }
        XCTAssertEqual(fetched?.type, .actual)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter PayPeriodModelTests`
Expected: FAIL (no such type `PayPeriod`)

- [ ] **Step 3: Implement PayPeriod**

```swift
// Sources/BudgetCore/Models/PayPeriod.swift
import GRDB
import Foundation

public enum PayPeriodType: String, Codable, CaseIterable {
    case actual
    case projected
}

public struct PayPeriod: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var startDate: Date
    public var endDate: Date
    public var type: PayPeriodType

    public init(id: Int64? = nil, startDate: Date, endDate: Date, type: PayPeriodType) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.type = type
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "payPeriod"
}

func registerPayPeriodMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createPayPeriod") { db in
        try db.create(table: "payPeriod") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("startDate", .datetime).notNull()
            t.column("endDate", .datetime).notNull()
            t.column("type", .text).notNull()
        }
    }
}
```

- [ ] **Step 4: Register the migration**

```swift
// Sources/BudgetCore/Database/DatabaseManager.swift
// In registerMigrations(_:), append:
        registerPayPeriodMigration(&migrator)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter PayPeriodModelTests`
Expected: 1 test, PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/BudgetCore/Models/PayPeriod.swift Sources/BudgetCore/Database/DatabaseManager.swift Tests/BudgetCoreTests/PayPeriodModelTests.swift
git commit -m "Add PayPeriod model"
```

### Task 18: PayPeriodDetector (cadence detection + actual/projected generation)

**Files:**
- Create: `Sources/BudgetCore/PayPeriods/PayPeriodDetector.swift`
- Test: `Tests/BudgetCoreTests/PayPeriodDetectorTests.swift`

**Interfaces:**
- Consumes: `Transaction`, `PayPeriod`, `PayPeriodType`
- Produces: `PayCadence` (`averageIntervalDays: Double`, `lastPayDate: Date`); `PayPeriodDetector.detectCadence(incomeDates: [Date]) -> PayCadence?`; `PayPeriodDetector.generateActualPeriods(incomeDates: [Date]) -> [PayPeriod]`; `PayPeriodDetector.generateProjectedPeriods(cadence: PayCadence, horizon: Date) -> [PayPeriod]`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BudgetCoreTests/PayPeriodDetectorTests.swift
import XCTest
@testable import BudgetCore

final class PayPeriodDetectorTests: XCTestCase {
    func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var components = DateComponents()
        components.year = y; components.month = m; components.day = d
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    func testDetectsCadenceFromRegularMonthlyIncome() {
        let dates = [date(2026, 4, 26), date(2026, 5, 26), date(2026, 6, 26)]
        let cadence = PayPeriodDetector.detectCadence(incomeDates: dates)
        XCTAssertNotNil(cadence)
        XCTAssertEqual(cadence!.averageIntervalDays, 30.5, accuracy: 1.0)
        XCTAssertEqual(cadence!.lastPayDate, date(2026, 6, 26))
    }

    func testToleratesWeekendShiftedPaydays() {
        // 26 April 2026 is a Sunday; a real payday would shift to Friday 24th.
        let dates = [date(2026, 3, 26), date(2026, 4, 24), date(2026, 5, 26)]
        let cadence = PayPeriodDetector.detectCadence(incomeDates: dates)
        XCTAssertNotNil(cadence)
    }

    func testReturnsNilWithInsufficientHistory() {
        let cadence = PayPeriodDetector.detectCadence(incomeDates: [date(2026, 6, 26)])
        XCTAssertNil(cadence)
    }

    func testGenerateActualPeriodsProducesConsecutiveNonOverlappingRanges() {
        let dates = [date(2026, 4, 26), date(2026, 5, 26), date(2026, 6, 26)]
        let periods = PayPeriodDetector.generateActualPeriods(incomeDates: dates)
        XCTAssertEqual(periods.count, 3)
        XCTAssertEqual(periods[0].startDate, date(2026, 4, 26))
        XCTAssertEqual(periods[0].endDate, date(2026, 5, 25))
        XCTAssertEqual(periods[1].startDate, date(2026, 5, 26))
        XCTAssertTrue(periods.allSatisfy { $0.type == .actual })
    }

    func testGenerateProjectedPeriodsExtrapolatesForwardToHorizon() {
        let cadence = PayCadence(averageIntervalDays: 30, lastPayDate: date(2026, 6, 26))
        let periods = PayPeriodDetector.generateProjectedPeriods(cadence: cadence, horizon: date(2026, 12, 31))
        XCTAssertTrue(periods.allSatisfy { $0.type == .projected })
        XCTAssertTrue(periods.first!.startDate > date(2026, 6, 26))
        XCTAssertTrue(periods.last!.endDate <= date(2027, 1, 30))
        XCTAssertTrue(periods.last!.startDate <= date(2026, 12, 31))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter PayPeriodDetectorTests`
Expected: FAIL (no such types)

- [ ] **Step 3: Implement PayPeriodDetector**

```swift
// Sources/BudgetCore/PayPeriods/PayPeriodDetector.swift
import Foundation

public struct PayCadence: Equatable {
    public let averageIntervalDays: Double
    public let lastPayDate: Date

    public init(averageIntervalDays: Double, lastPayDate: Date) {
        self.averageIntervalDays = averageIntervalDays
        self.lastPayDate = lastPayDate
    }
}

public enum PayPeriodDetector {
    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// Requires at least 2 income dates to establish an interval.
    /// Tolerates weekend/bank-holiday shifts of a few days either side of a ~30-day cadence.
    public static func detectCadence(incomeDates: [Date]) -> PayCadence? {
        let sorted = incomeDates.sorted()
        guard sorted.count >= 2 else { return nil }

        let intervals: [Double] = zip(sorted, sorted.dropFirst()).map { earlier, later in
            Double(calendar.dateComponents([.day], from: earlier, to: later).day ?? 0)
        }
        // Only consider intervals that look like "one pay period" (20-45 days),
        // to avoid a missed month (≈60 days) skewing the average.
        let plausibleIntervals = intervals.filter { $0 >= 20 && $0 <= 45 }
        guard !plausibleIntervals.isEmpty else { return nil }

        let average = plausibleIntervals.reduce(0, +) / Double(plausibleIntervals.count)
        return PayCadence(averageIntervalDays: average, lastPayDate: sorted.last!)
    }

    public static func generateActualPeriods(incomeDates: [Date]) -> [PayPeriod] {
        let sorted = incomeDates.sorted()
        guard sorted.count >= 2 else { return [] }

        var periods: [PayPeriod] = []
        for i in 0..<(sorted.count - 1) {
            let start = sorted[i]
            let nextStart = sorted[i + 1]
            let end = calendar.date(byAdding: .day, value: -1, to: nextStart)!
            periods.append(PayPeriod(startDate: start, endDate: end, type: .actual))
        }
        // The most recent period is still open; estimate its end from the detected cadence.
        if let cadence = detectCadence(incomeDates: sorted) {
            let start = sorted.last!
            let end = calendar.date(byAdding: .day, value: Int(cadence.averageIntervalDays.rounded()) - 1, to: start)!
            periods.append(PayPeriod(startDate: start, endDate: end, type: .actual))
        }
        return periods
    }

    public static func generateProjectedPeriods(cadence: PayCadence, horizon: Date) -> [PayPeriod] {
        var periods: [PayPeriod] = []
        var cursor = cadence.lastPayDate
        let intervalDays = Int(cadence.averageIntervalDays.rounded())
        while cursor < horizon {
            guard let nextStart = calendar.date(byAdding: .day, value: intervalDays, to: cursor) else { break }
            let end = calendar.date(byAdding: .day, value: -1, to: calendar.date(byAdding: .day, value: intervalDays, to: nextStart)!)!
            periods.append(PayPeriod(startDate: nextStart, endDate: end, type: .projected))
            cursor = nextStart
        }
        return periods
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PayPeriodDetectorTests`
Expected: 5 tests, PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/BudgetCore/PayPeriods/PayPeriodDetector.swift Tests/BudgetCoreTests/PayPeriodDetectorTests.swift
git commit -m "Add PayPeriodDetector for payday cadence detection and period generation"
```

---

## Phase 5: Forecasting

### Task 19: ForecastGroup and ForecastEntry models

**Files:**
- Create: `Sources/BudgetCore/Models/ForecastGroup.swift`
- Create: `Sources/BudgetCore/Models/ForecastEntry.swift`
- Modify: `Sources/BudgetCore/Database/DatabaseManager.swift:registerMigrations`
- Test: `Tests/BudgetCoreTests/ForecastModelsTests.swift`

**Interfaces:**
- Consumes: `Category` (Task 3)
- Produces: `ForecastGroup` (`id`, `name: String`, `note: String?`, `isEnabled: Bool`, `isSystemManaged: Bool`), `ForecastEntry` (`id`, `groupId: Int64`, `categoryId: Int64`, `amountMinorUnits: Int`, `frequency: ForecastFrequency`, `interval: Int`, `startDate: Date`, `endDate: Date?`, `isEnabled: Bool`, `status: ForecastEntryStatus`, `note: String?`), `ForecastFrequency` enum (`.once`, `.weekly`, `.monthly`, `.annually`), `ForecastEntryStatus` enum (`.auto`, `.manual`, `.hypothetical`, `.confirmed`)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BudgetCoreTests/ForecastModelsTests.swift
import XCTest
import GRDB
@testable import BudgetCore

final class ForecastModelsTests: XCTestCase {
    func testInsertGroupAndEntry() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in try CategorySeeder.seedDefaults(db) }
        let rent = try manager.dbQueue.read { db in try Category.filter(Column("name") == "Rent").fetchOne(db)! }

        var group = ForecastGroup(name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)
        try manager.dbQueue.write { db in try group.insert(db) }

        var entry = ForecastEntry(
            groupId: group.id!, categoryId: rent.id!, amountMinorUnits: 280000,
            frequency: .monthly, interval: 1, startDate: Date(), endDate: nil,
            isEnabled: true, status: .auto, note: nil
        )
        try manager.dbQueue.write { db in try entry.insert(db) }

        let fetched = try manager.dbQueue.read { db in try ForecastEntry.fetchOne(db) }
        XCTAssertEqual(fetched?.amountMinorUnits, 280000)
        XCTAssertEqual(fetched?.frequency, .monthly)
        XCTAssertEqual(fetched?.status, .auto)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ForecastModelsTests`
Expected: FAIL (no such types)

- [ ] **Step 3: Implement ForecastGroup**

```swift
// Sources/BudgetCore/Models/ForecastGroup.swift
import GRDB

public struct ForecastGroup: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var name: String
    public var note: String?
    public var isEnabled: Bool
    public var isSystemManaged: Bool

    public init(id: Int64? = nil, name: String, note: String?, isEnabled: Bool, isSystemManaged: Bool) {
        self.id = id
        self.name = name
        self.note = note
        self.isEnabled = isEnabled
        self.isSystemManaged = isSystemManaged
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "forecastGroup"
}

func registerForecastGroupMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createForecastGroup") { db in
        try db.create(table: "forecastGroup") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull()
            t.column("note", .text)
            t.column("isEnabled", .boolean).notNull().defaults(to: true)
            t.column("isSystemManaged", .boolean).notNull().defaults(to: false)
        }
    }
}
```

- [ ] **Step 4: Implement ForecastEntry**

```swift
// Sources/BudgetCore/Models/ForecastEntry.swift
import GRDB
import Foundation

public enum ForecastFrequency: String, Codable, CaseIterable {
    case once
    case weekly
    case monthly
    case annually
}

public enum ForecastEntryStatus: String, Codable, CaseIterable {
    case auto
    case manual
    case hypothetical
    case confirmed
}

public struct ForecastEntry: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var groupId: Int64
    public var categoryId: Int64
    public var amountMinorUnits: Int
    public var frequency: ForecastFrequency
    public var interval: Int
    public var startDate: Date
    public var endDate: Date?
    public var isEnabled: Bool
    public var status: ForecastEntryStatus
    public var note: String?

    public init(id: Int64? = nil, groupId: Int64, categoryId: Int64, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date?, isEnabled: Bool, status: ForecastEntryStatus, note: String?) {
        self.id = id
        self.groupId = groupId
        self.categoryId = categoryId
        self.amountMinorUnits = amountMinorUnits
        self.frequency = frequency
        self.interval = interval
        self.startDate = startDate
        self.endDate = endDate
        self.isEnabled = isEnabled
        self.status = status
        self.note = note
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "forecastEntry"
}

func registerForecastEntryMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createForecastEntry") { db in
        try db.create(table: "forecastEntry") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("groupId", .integer).notNull().references("forecastGroup")
            t.column("categoryId", .integer).notNull().references("category")
            t.column("amountMinorUnits", .integer).notNull()
            t.column("frequency", .text).notNull()
            t.column("interval", .integer).notNull().defaults(to: 1)
            t.column("startDate", .datetime).notNull()
            t.column("endDate", .datetime)
            t.column("isEnabled", .boolean).notNull().defaults(to: true)
            t.column("status", .text).notNull()
            t.column("note", .text)
        }
    }
}
```

- [ ] **Step 5: Register the migrations**

```swift
// Sources/BudgetCore/Database/DatabaseManager.swift
// In registerMigrations(_:), append:
        registerForecastGroupMigration(&migrator)
        registerForecastEntryMigration(&migrator)
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter ForecastModelsTests`
Expected: 1 test, PASS

- [ ] **Step 7: Commit**

```bash
git add Sources/BudgetCore/Models/ForecastGroup.swift Sources/BudgetCore/Models/ForecastEntry.swift Sources/BudgetCore/Database/DatabaseManager.swift Tests/BudgetCoreTests/ForecastModelsTests.swift
git commit -m "Add ForecastGroup and ForecastEntry models"
```

### Task 20: FrequencyExpander

**Files:**
- Create: `Sources/BudgetCore/Forecasting/FrequencyExpander.swift`
- Test: `Tests/BudgetCoreTests/FrequencyExpanderTests.swift`

**Interfaces:**
- Consumes: `ForecastEntry`, `PayPeriod` (Task 17, 19)
- Produces: `FrequencyExpander.occurrences(for entry: ForecastEntry, in period: PayPeriod) -> [Date]`, `FrequencyExpander.amount(for entry: ForecastEntry, in period: PayPeriod) -> Int`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BudgetCoreTests/FrequencyExpanderTests.swift
import XCTest
@testable import BudgetCore

final class FrequencyExpanderTests: XCTestCase {
    func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func makeEntry(frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date? = nil, amount: Int = 1000) -> ForecastEntry {
        ForecastEntry(groupId: 1, categoryId: 1, amountMinorUnits: amount, frequency: frequency, interval: interval, startDate: startDate, endDate: endDate, isEnabled: true, status: .auto, note: nil)
    }

    func testOnceOccursExactlyOnStartDateIfWithinPeriod() {
        let entry = makeEntry(frequency: .once, interval: 1, startDate: date(2026, 8, 15))
        let period = PayPeriod(startDate: date(2026, 7, 26), endDate: date(2026, 8, 25), type: .projected)
        XCTAssertEqual(FrequencyExpander.occurrences(for: entry, in: period), [date(2026, 8, 15)])
        XCTAssertEqual(FrequencyExpander.amount(for: entry, in: period), 1000)
    }

    func testOnceOutsidePeriodProducesNoOccurrences() {
        let entry = makeEntry(frequency: .once, interval: 1, startDate: date(2026, 9, 15))
        let period = PayPeriod(startDate: date(2026, 7, 26), endDate: date(2026, 8, 25), type: .projected)
        XCTAssertEqual(FrequencyExpander.occurrences(for: entry, in: period), [])
    }

    func testMonthlyOccursOnceInAMatchingPeriod() {
        let entry = makeEntry(frequency: .monthly, interval: 1, startDate: date(2026, 6, 26))
        let period = PayPeriod(startDate: date(2026, 8, 26), endDate: date(2026, 9, 25), type: .projected)
        XCTAssertEqual(FrequencyExpander.occurrences(for: entry, in: period), [date(2026, 9, 26)])
    }

    func testEveryTwoMonthsSkipsAlternatePeriods() {
        let entry = makeEntry(frequency: .monthly, interval: 2, startDate: date(2026, 6, 26))
        let matchingPeriod = PayPeriod(startDate: date(2026, 8, 26), endDate: date(2026, 9, 25), type: .projected)
        let skippedPeriod = PayPeriod(startDate: date(2026, 7, 26), endDate: date(2026, 8, 25), type: .projected)
        XCTAssertEqual(FrequencyExpander.occurrences(for: entry, in: matchingPeriod).count, 1)
        XCTAssertEqual(FrequencyExpander.occurrences(for: entry, in: skippedPeriod).count, 0)
    }

    func testWeeklyCanOccurMultipleTimesInOnePeriod() {
        let entry = makeEntry(frequency: .weekly, interval: 1, startDate: date(2026, 7, 26), amount: 500)
        let period = PayPeriod(startDate: date(2026, 7, 26), endDate: date(2026, 8, 25), type: .projected)
        let occurrences = FrequencyExpander.occurrences(for: entry, in: period)
        XCTAssertEqual(occurrences.count, 5) // 30-day period / 7-day interval
        XCTAssertEqual(FrequencyExpander.amount(for: entry, in: period), 2500)
    }

    func testRespectsEndDate() {
        let entry = makeEntry(frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: date(2026, 8, 1))
        let period = PayPeriod(startDate: date(2026, 8, 26), endDate: date(2026, 9, 25), type: .projected)
        XCTAssertEqual(FrequencyExpander.occurrences(for: entry, in: period), [])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter FrequencyExpanderTests`
Expected: FAIL (no such type `FrequencyExpander`)

- [ ] **Step 3: Implement FrequencyExpander**

```swift
// Sources/BudgetCore/Forecasting/FrequencyExpander.swift
import Foundation

public enum FrequencyExpander {
    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
    private static let maxIterations = 2000

    public static func occurrences(for entry: ForecastEntry, in period: PayPeriod) -> [Date] {
        guard entry.startDate <= period.endDate else { return [] }
        if let endDate = entry.endDate, endDate < period.startDate { return [] }

        var results: [Date] = []

        if entry.frequency == .once {
            if entry.startDate >= period.startDate && entry.startDate <= period.endDate {
                results.append(entry.startDate)
            }
            return results
        }

        let component: Calendar.Component
        switch entry.frequency {
        case .weekly: component = .day
        case .monthly: component = .month
        case .annually: component = .year
        case .once: return results // handled above
        }
        let stepValue = entry.frequency == .weekly ? entry.interval * 7 : entry.interval

        var cursor = entry.startDate
        var iterations = 0
        while cursor <= period.endDate && iterations < maxIterations {
            iterations += 1
            if let entryEnd = entry.endDate, cursor > entryEnd { break }
            if cursor >= period.startDate && cursor <= period.endDate {
                results.append(cursor)
            }
            guard let next = calendar.date(byAdding: component, value: stepValue, to: cursor) else { break }
            cursor = next
        }
        return results
    }

    public static func amount(for entry: ForecastEntry, in period: PayPeriod) -> Int {
        occurrences(for: entry, in: period).count * entry.amountMinorUnits
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter FrequencyExpanderTests`
Expected: 6 tests, PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/BudgetCore/Forecasting/FrequencyExpander.swift Tests/BudgetCoreTests/FrequencyExpanderTests.swift
git commit -m "Add FrequencyExpander for mapping forecast entries onto pay periods"
```

### Task 21: AutoForecastGenerator (trend detection into the "Detected recurring" group)

**Files:**
- Create: `Sources/BudgetCore/Forecasting/AutoForecastGenerator.swift`
- Test: `Tests/BudgetCoreTests/AutoForecastGeneratorTests.swift`

**Interfaces:**
- Consumes: `Transaction`, `Category`, `PayPeriod`, `ForecastGroup`, `ForecastEntry` (Tasks 5, 3, 17, 19)
- Produces: `AutoForecastGenerator.ensureDetectedRecurringGroup(db: Database) throws -> ForecastGroup`, `AutoForecastGenerator.regenerate(db: Database, actualPeriods: [PayPeriod]) throws`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BudgetCoreTests/AutoForecastGeneratorTests.swift
import XCTest
import GRDB
@testable import BudgetCore

final class AutoForecastGeneratorTests: XCTestCase {
    func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func seededManagerWithRentHistory() throws -> (DatabaseManager, Category, Account, [PayPeriod]) {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in try CategorySeeder.seedDefaults(db) }
        let rent = try manager.dbQueue.read { db in try Category.filter(Column("name") == "Rent").fetchOne(db)! }
        var account = Account(name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        try manager.dbQueue.write { db in try account.insert(db) }

        let periods = [
            PayPeriod(startDate: date(2026, 4, 26), endDate: date(2026, 5, 25), type: .actual),
            PayPeriod(startDate: date(2026, 5, 26), endDate: date(2026, 6, 25), type: .actual),
            PayPeriod(startDate: date(2026, 6, 26), endDate: date(2026, 7, 25), type: .actual)
        ]
        try manager.dbQueue.write { db in
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "x.csv", importedAt: Date())
            try batch.insert(db)
            for (i, rentDate) in [date(2026, 4, 28), date(2026, 5, 28), date(2026, 6, 28)].enumerated() {
                var t = Transaction(importBatchId: batch.id!, accountId: account.id!, date: rentDate, rawDescription: "RENT", amountMinorUnits: -280000, categoryId: rent.id!, status: .confirmed, categorizedBy: .manual, fingerprint: "rent-\(i)")
                try t.insert(db)
            }
        }
        return (manager, rent, account, periods)
    }

    func testFixedCategoryForecastsLastActualAmount() throws {
        let (manager, rent, _, periods) = try seededManagerWithRentHistory()
        try manager.dbQueue.write { db in
            try AutoForecastGenerator.regenerate(db: db, actualPeriods: periods)
        }
        let entries = try manager.dbQueue.read { db in try ForecastEntry.filter(Column("categoryId") == rent.id!).fetchAll(db) }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].amountMinorUnits, 280000)
        XCTAssertEqual(entries[0].status, .auto)
        XCTAssertEqual(entries[0].frequency, .monthly)
    }

    func testRegenerateDoesNotOverwriteManuallyTunedEntry() throws {
        let (manager, rent, _, periods) = try seededManagerWithRentHistory()
        try manager.dbQueue.write { db in try AutoForecastGenerator.regenerate(db: db, actualPeriods: periods) }
        try manager.dbQueue.write { db in
            var entry = try ForecastEntry.filter(Column("categoryId") == rent.id!).fetchOne(db)!
            entry.amountMinorUnits = 300000
            entry.status = .manual
            try entry.update(db)
        }
        try manager.dbQueue.write { db in try AutoForecastGenerator.regenerate(db: db, actualPeriods: periods) }
        let entry = try manager.dbQueue.read { db in try ForecastEntry.filter(Column("categoryId") == rent.id!).fetchOne(db)! }
        XCTAssertEqual(entry.amountMinorUnits, 300000)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter AutoForecastGeneratorTests`
Expected: FAIL (no such type `AutoForecastGenerator`)

- [ ] **Step 3: Implement AutoForecastGenerator**

```swift
// Sources/BudgetCore/Forecasting/AutoForecastGenerator.swift
import GRDB
import Foundation

public enum AutoForecastGenerator {
    private static let detectedRecurringGroupName = "Detected recurring"

    @discardableResult
    public static func ensureDetectedRecurringGroup(db: Database) throws -> ForecastGroup {
        if let existing = try ForecastGroup.filter(Column("name") == detectedRecurringGroupName).fetchOne(db) {
            return existing
        }
        var group = ForecastGroup(name: detectedRecurringGroupName, note: "Auto-detected from transaction history", isEnabled: true, isSystemManaged: true)
        try group.insert(db)
        return group
    }

    /// Buckets confirmed expense/transfer/income transactions into `actualPeriods`,
    /// sums per category per period, and creates or refreshes an `auto`-status
    /// ForecastEntry per category in the "Detected recurring" group. Entries whose
    /// status has been changed away from `.auto` (i.e. the user tuned them) are left untouched.
    public static func regenerate(db: Database, actualPeriods: [PayPeriod]) throws {
        guard !actualPeriods.isEmpty else { return }
        let group = try ensureDetectedRecurringGroup(db: db)
        let sortedPeriods = actualPeriods.sorted { $0.startDate < $1.startDate }
        let categories = try Category.filter(Column("type") != CategoryType.transfer.rawValue || Column("type") == CategoryType.transfer.rawValue).fetchAll(db)

        for category in categories {
            var perPeriodSums: [Int] = []
            for period in sortedPeriods {
                let sum = try Int.fetchOne(db, sql: """
                    SELECT COALESCE(SUM(amountMinorUnits), 0) FROM transaction_
                    WHERE categoryId = ? AND status = 'confirmed' AND date >= ? AND date <= ?
                    """, arguments: [category.id!, period.startDate, period.endDate]) ?? 0
                if sum != 0 { perPeriodSums.append(abs(sum)) }
            }
            guard perPeriodSums.count >= 2 else { continue }

            let mean = Double(perPeriodSums.reduce(0, +)) / Double(perPeriodSums.count)
            let variance = perPeriodSums.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(perPeriodSums.count)
            let relativeStdDev = mean == 0 ? 0 : sqrt(variance) / mean
            let isFixed = relativeStdDev < 0.15

            let forecastAmount = isFixed ? perPeriodSums.last! : Int(mean.rounded())
            let signedAmount = category.type == .income ? forecastAmount : -forecastAmount
            let nextPeriodStart = sortedPeriods.last!.startDate

            if var existing = try ForecastEntry
                .filter(Column("categoryId") == category.id! && Column("groupId") == group.id!)
                .fetchOne(db) {
                guard existing.status == .auto else { continue } // respect manual tuning
                existing.amountMinorUnits = signedAmount
                try existing.update(db)
            } else {
                var entry = ForecastEntry(
                    groupId: group.id!, categoryId: category.id!, amountMinorUnits: signedAmount,
                    frequency: .monthly, interval: 1, startDate: nextPeriodStart, endDate: nil,
                    isEnabled: true, status: .auto, note: nil
                )
                try entry.insert(db)
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AutoForecastGeneratorTests`
Expected: 2 tests, PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/BudgetCore/Forecasting/AutoForecastGenerator.swift Tests/BudgetCoreTests/AutoForecastGeneratorTests.swift
git commit -m "Add AutoForecastGenerator for trend-based default forecasting"
```

### Task 22: ForecastCalculator (confirmed vs. preview totals)

**Files:**
- Create: `Sources/BudgetCore/Forecasting/ForecastCalculator.swift`
- Test: `Tests/BudgetCoreTests/ForecastCalculatorTests.swift`

**Interfaces:**
- Consumes: `FrequencyExpander` (Task 20), `ForecastEntry`, `ForecastGroup`, `PayPeriod`
- Produces: `ForecastCalculator.confirmedTotal(categoryId: Int64, period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup]) -> Int`, `ForecastCalculator.previewTotal(categoryId: Int64, period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup]) -> Int`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BudgetCoreTests/ForecastCalculatorTests.swift
import XCTest
@testable import BudgetCore

final class ForecastCalculatorTests: XCTestCase {
    func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func testConfirmedTotalIncludesAutoAndManualAndConfirmedButNotHypothetical() {
        let period = PayPeriod(startDate: date(2026, 8, 26), endDate: date(2026, 9, 25), type: .projected)
        let groups = [ForecastGroup(id: 1, name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)]
        let entries = [
            ForecastEntry(id: 1, groupId: 1, categoryId: 10, amountMinorUnits: -280000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .auto, note: nil),
            ForecastEntry(id: 2, groupId: 1, categoryId: 10, amountMinorUnits: -5000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .hypothetical, note: nil)
        ]
        let confirmed = ForecastCalculator.confirmedTotal(categoryId: 10, period: period, entries: entries, groups: groups)
        XCTAssertEqual(confirmed, -280000)
    }

    func testPreviewTotalAddsEnabledHypotheticals() {
        let period = PayPeriod(startDate: date(2026, 8, 26), endDate: date(2026, 9, 25), type: .projected)
        let groups = [ForecastGroup(id: 1, name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)]
        let entries = [
            ForecastEntry(id: 1, groupId: 1, categoryId: 10, amountMinorUnits: -280000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .auto, note: nil),
            ForecastEntry(id: 2, groupId: 1, categoryId: 10, amountMinorUnits: -5000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .hypothetical, note: nil)
        ]
        let preview = ForecastCalculator.previewTotal(categoryId: 10, period: period, entries: entries, groups: groups)
        XCTAssertEqual(preview, -285000)
    }

    func testDisabledGroupExcludesAllItsEntriesRegardlessOfEntryToggle() {
        let period = PayPeriod(startDate: date(2026, 8, 26), endDate: date(2026, 9, 25), type: .projected)
        let groups = [ForecastGroup(id: 2, name: "New car", note: nil, isEnabled: false, isSystemManaged: false)]
        let entries = [
            ForecastEntry(id: 3, groupId: 2, categoryId: 20, amountMinorUnits: -30000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .confirmed, note: nil)
        ]
        XCTAssertEqual(ForecastCalculator.confirmedTotal(categoryId: 20, period: period, entries: entries, groups: groups), 0)
    }

    func testDisabledIndividualEntryIsExcludedEvenIfGroupEnabled() {
        let period = PayPeriod(startDate: date(2026, 8, 26), endDate: date(2026, 9, 25), type: .projected)
        let groups = [ForecastGroup(id: 1, name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)]
        let entries = [
            ForecastEntry(id: 1, groupId: 1, categoryId: 10, amountMinorUnits: -280000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: false, status: .auto, note: nil)
        ]
        XCTAssertEqual(ForecastCalculator.confirmedTotal(categoryId: 10, period: period, entries: entries, groups: groups), 0)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ForecastCalculatorTests`
Expected: FAIL (no such type `ForecastCalculator`)

- [ ] **Step 3: Implement ForecastCalculator**

```swift
// Sources/BudgetCore/Forecasting/ForecastCalculator.swift
import Foundation

public enum ForecastCalculator {
    public static func confirmedTotal(categoryId: Int64, period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup]) -> Int {
        total(categoryId: categoryId, period: period, entries: entries, groups: groups, includeHypothetical: false)
    }

    public static func previewTotal(categoryId: Int64, period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup]) -> Int {
        total(categoryId: categoryId, period: period, entries: entries, groups: groups, includeHypothetical: true)
    }

    private static func total(categoryId: Int64, period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup], includeHypothetical: Bool) -> Int {
        let enabledGroupIds = Set(groups.filter(\.isEnabled).compactMap(\.id))
        return entries
            .filter { $0.categoryId == categoryId }
            .filter { $0.isEnabled }
            .filter { enabledGroupIds.contains($0.groupId) }
            .filter { entry in
                switch entry.status {
                case .auto, .manual, .confirmed: return true
                case .hypothetical: return includeHypothetical
                }
            }
            .reduce(0) { $0 + FrequencyExpander.amount(for: $1, in: period) }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ForecastCalculatorTests`
Expected: 4 tests, PASS

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: all tests PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/BudgetCore/Forecasting/ForecastCalculator.swift Tests/BudgetCoreTests/ForecastCalculatorTests.swift
git commit -m "Add ForecastCalculator for confirmed vs preview forecast totals"
```

### Task 23: Forecast comparison UI

**Files:**
- Create: `App/Forecast/ForecastViewModel.swift`
- Create: `App/Forecast/ForecastComparisonView.swift`

**Interfaces:**
- Consumes: `ForecastCalculator` (Task 22), `ForecastEntry`, `ForecastGroup` (Task 19), `PayPeriodDetector` (Task 18), `Category`
- Produces: `ForecastViewModel` (`@Published var groups: [ForecastGroup]`, `@Published var entries: [ForecastEntry]`, `@Published var periods: [PayPeriod]`, `func toggleGroup(_ group: ForecastGroup)`, `func toggleEntry(_ entry: ForecastEntry)`, `func confirmedTotal(categoryId: Int64, period: PayPeriod) -> Int`, `func previewTotal(categoryId: Int64, period: PayPeriod) -> Int`)

- [ ] **Step 1: Implement the view model**

```swift
// App/Forecast/ForecastViewModel.swift
import Foundation
import BudgetCore
import GRDB

@MainActor
final class ForecastViewModel: ObservableObject {
    @Published var groups: [ForecastGroup] = []
    @Published var entries: [ForecastEntry] = []
    @Published var periods: [PayPeriod] = []

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func load(horizon: Date) throws {
        groups = try dbQueue.read { db in try ForecastGroup.fetchAll(db) }
        entries = try dbQueue.read { db in try ForecastEntry.fetchAll(db) }
        let incomeDates = try dbQueue.read { db -> [Date] in
            let incomeCategoryIds = try Category.filter(Column("type") == CategoryType.income.rawValue).fetchAll(db).compactMap(\.id)
            return try Date.fetchAll(db, sql: "SELECT date FROM transaction_ WHERE categoryId IN (\(incomeCategoryIds.map(String.init).joined(separator: ","))) AND status = 'confirmed' ORDER BY date")
        }
        var allPeriods = PayPeriodDetector.generateActualPeriods(incomeDates: incomeDates)
        if let cadence = PayPeriodDetector.detectCadence(incomeDates: incomeDates) {
            allPeriods += PayPeriodDetector.generateProjectedPeriods(cadence: cadence, horizon: horizon)
        }
        periods = allPeriods
    }

    func toggleGroup(_ group: ForecastGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].isEnabled.toggle()
        try? dbQueue.write { db in try groups[index].update(db) }
    }

    func toggleEntry(_ entry: ForecastEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].isEnabled.toggle()
        try? dbQueue.write { db in try entries[index].update(db) }
    }

    func confirm(_ entry: ForecastEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].status = .confirmed
        try? dbQueue.write { db in try entries[index].update(db) }
    }

    func confirmedTotal(categoryId: Int64, period: PayPeriod) -> Int {
        ForecastCalculator.confirmedTotal(categoryId: categoryId, period: period, entries: entries, groups: groups)
    }

    func previewTotal(categoryId: Int64, period: PayPeriod) -> Int {
        ForecastCalculator.previewTotal(categoryId: categoryId, period: period, entries: entries, groups: groups)
    }

    func addHypotheticalEntry(groupName: String, categoryId: Int64, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date) {
        try? dbQueue.write { db in
            let group: ForecastGroup
            if let existing = try ForecastGroup.filter(Column("name") == groupName).fetchOne(db) {
                group = existing
            } else {
                var newGroup = ForecastGroup(name: groupName, note: nil, isEnabled: true, isSystemManaged: false)
                try newGroup.insert(db)
                group = newGroup
            }
            var entry = ForecastEntry(groupId: group.id!, categoryId: categoryId, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, startDate: startDate, endDate: nil, isEnabled: true, status: .hypothetical, note: nil)
            try entry.insert(db)
        }
        groups = (try? dbQueue.read { db in try ForecastGroup.fetchAll(db) }) ?? groups
        entries = (try? dbQueue.read { db in try ForecastEntry.fetchAll(db) }) ?? entries
    }
}
```

- [ ] **Step 2: Implement the comparison view**

```swift
// App/Forecast/ForecastComparisonView.swift
import SwiftUI
import BudgetCore

struct ForecastComparisonView: View {
    @ObservedObject var viewModel: ForecastViewModel
    let categories: [Category]

    @State private var showNewEntrySheet = false

    private var futurePeriods: [PayPeriod] {
        viewModel.periods.filter { $0.type == .projected }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            groupsSection
            Button("Add hypothetical forecast entry…") { showNewEntrySheet = true }
            Divider()
            comparisonTable
        }
        .padding()
        .sheet(isPresented: $showNewEntrySheet) {
            NewForecastEntryView(categories: categories) { newGroupName, categoryId, amountMinorUnits, frequency, interval, startDate in
                viewModel.addHypotheticalEntry(groupName: newGroupName, categoryId: categoryId, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, startDate: startDate)
                showNewEntrySheet = false
            }
        }
    }

    private var groupsSection: some View {
        VStack(alignment: .leading) {
            Text("Forecast groups").font(.headline)
            ForEach(viewModel.groups) { group in
                HStack {
                    Toggle(group.name, isOn: Binding(
                        get: { group.isEnabled },
                        set: { _ in viewModel.toggleGroup(group) }
                    ))
                    if !group.isSystemManaged {
                        Text("custom").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(viewModel.entries.filter { $0.groupId == group.id }) { entry in
                    HStack {
                        Toggle(categories.first(where: { $0.id == entry.categoryId })?.name ?? "Unknown", isOn: Binding(
                            get: { entry.isEnabled },
                            set: { _ in viewModel.toggleEntry(entry) }
                        ))
                        .padding(.leading, 24)
                        Text(entry.status.rawValue).font(.caption).foregroundStyle(.secondary)
                        if entry.status == .hypothetical {
                            Button("Confirm") { viewModel.confirm(entry) }
                        }
                    }
                }
            }
        }
    }

    private var comparisonTable: some View {
        VStack(alignment: .leading) {
            Text("Confirmed vs. Preview forecast").font(.headline)
            ForEach(futurePeriods) { period in
                VStack(alignment: .leading) {
                    Text(period.startDate.formatted(date: .abbreviated, time: .omitted))
                        .font(.subheadline).bold()
                    ForEach(categories) { category in
                        let confirmed = viewModel.confirmedTotal(categoryId: category.id!, period: period)
                        let preview = viewModel.previewTotal(categoryId: category.id!, period: period)
                        if confirmed != 0 || preview != 0 {
                            HStack {
                                Text(category.name)
                                Spacer()
                                Text(Money.format(confirmed, currency: .gbp))
                                Text(Money.format(preview, currency: .gbp)).foregroundStyle(preview != confirmed ? .orange : .primary)
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }
}
```

- [ ] **Step 3: Implement the new-hypothetical-entry sheet**

```swift
// App/Forecast/ForecastComparisonView.swift
// Add this view in the same file, below ForecastComparisonView:

struct NewForecastEntryView: View {
    let categories: [Category]
    let onSave: (String, Int64, Int, ForecastFrequency, Int, Date) -> Void

    @State private var groupName = "New scenario"
    @State private var categoryId: Int64?
    @State private var amountPounds = ""
    @State private var frequency: ForecastFrequency = .monthly
    @State private var interval = 1
    @State private var startDate = Date()

    var body: some View {
        Form {
            TextField("Group name", text: $groupName)
            Picker("Category", selection: $categoryId) {
                Text("Select…").tag(Int64?.none)
                ForEach(categories) { category in Text(category.name).tag(Int64?.some(category.id!)) }
            }
            TextField("Amount (£, positive number)", text: $amountPounds)
            Picker("Frequency", selection: $frequency) {
                ForEach(ForecastFrequency.allCases, id: \.self) { freq in Text(freq.rawValue).tag(freq) }
            }
            Stepper("Every \(interval) \(frequency.rawValue)", value: $interval, in: 1...12)
            DatePicker("Starting", selection: $startDate, displayedComponents: .date)
            Button("Save") {
                guard let categoryId, let pounds = Double(amountPounds) else { return }
                let category = categories.first { $0.id == categoryId }
                let signedMinorUnits = Int(pounds * 100) * (category?.type == .income ? 1 : -1)
                onSave(groupName, categoryId, signedMinorUnits, frequency, interval, startDate)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
```

- [ ] **Step 4: Build to verify it compiles**

Run:
```bash
xcodegen generate
xcodebuild -project Budget.xcodeproj -scheme Budget -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Manually verify**

Temporarily present `ForecastComparisonView` from `ContentView` with a scratch database that has a few confirmed transactions across 3+ periods (reuse the debug seeding approach from Task 14). Run `AutoForecastGenerator.regenerate` once to populate the "Detected recurring" group. Confirm: toggling a group or entry updates the Preview column immediately; using "Add hypothetical forecast entry…" to add a new one only affects Preview until you tap Confirm on it, at which point Confirmed updates too.

- [ ] **Step 6: Commit**

```bash
git add App/Forecast
git commit -m "Add forecast comparison UI with live group/entry toggles"
```

---

## Phase 6: Accounts & Net Worth

### Task 24: BalanceSnapshot and ExchangeRateSetting models

**Files:**
- Create: `Sources/BudgetCore/Models/BalanceSnapshot.swift`
- Create: `Sources/BudgetCore/Models/ExchangeRateSetting.swift`
- Modify: `Sources/BudgetCore/Database/DatabaseManager.swift:registerMigrations`
- Test: `Tests/BudgetCoreTests/NetWorthModelsTests.swift`

**Interfaces:**
- Consumes: `Account` (Task 4)
- Produces: `BalanceSnapshot` (`id`, `accountId: Int64`, `date: Date`, `balanceMinorUnits: Int`, `note: String?`), `ExchangeRateSetting` (`id`, `eurToGbpRate: Double`, `updatedAt: Date`), `ExchangeRateSetting.currentOrDefault(db: Database) throws -> ExchangeRateSetting`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BudgetCoreTests/NetWorthModelsTests.swift
import XCTest
import GRDB
@testable import BudgetCore

final class NetWorthModelsTests: XCTestCase {
    func testInsertAndFetchBalanceSnapshot() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        var account = Account(name: "Lloyds Investment ISA", currency: .gbp, kind: .investment, trackingMode: .manual)
        try manager.dbQueue.write { db in try account.insert(db) }
        var snapshot = BalanceSnapshot(accountId: account.id!, date: Date(), balanceMinorUnits: 500000, note: "Checked via app")
        try manager.dbQueue.write { db in try snapshot.insert(db) }
        let fetched = try manager.dbQueue.read { db in try BalanceSnapshot.fetchOne(db) }
        XCTAssertEqual(fetched?.balanceMinorUnits, 500000)
    }

    func testExchangeRateSettingDefaultsWhenNoneSet() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let rate = try manager.dbQueue.read { db in try ExchangeRateSetting.currentOrDefault(db: db) }
        XCTAssertEqual(rate.eurToGbpRate, 0.87, accuracy: 0.001)
    }

    func testExchangeRateSettingReturnsMostRecentlySaved() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in
            var rate = ExchangeRateSetting(eurToGbpRate: 0.90, updatedAt: Date())
            try rate.insert(db)
        }
        let rate = try manager.dbQueue.read { db in try ExchangeRateSetting.currentOrDefault(db: db) }
        XCTAssertEqual(rate.eurToGbpRate, 0.90, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter NetWorthModelsTests`
Expected: FAIL (no such types)

- [ ] **Step 3: Implement BalanceSnapshot**

```swift
// Sources/BudgetCore/Models/BalanceSnapshot.swift
import GRDB
import Foundation

public struct BalanceSnapshot: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var accountId: Int64
    public var date: Date
    public var balanceMinorUnits: Int
    public var note: String?

    public init(id: Int64? = nil, accountId: Int64, date: Date, balanceMinorUnits: Int, note: String?) {
        self.id = id
        self.accountId = accountId
        self.date = date
        self.balanceMinorUnits = balanceMinorUnits
        self.note = note
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "balanceSnapshot"
}

func registerBalanceSnapshotMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createBalanceSnapshot") { db in
        try db.create(table: "balanceSnapshot") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("accountId", .integer).notNull().references("account")
            t.column("date", .datetime).notNull()
            t.column("balanceMinorUnits", .integer).notNull()
            t.column("note", .text)
        }
    }
}
```

- [ ] **Step 4: Implement ExchangeRateSetting**

```swift
// Sources/BudgetCore/Models/ExchangeRateSetting.swift
import GRDB
import Foundation

public struct ExchangeRateSetting: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var eurToGbpRate: Double
    public var updatedAt: Date

    public init(id: Int64? = nil, eurToGbpRate: Double, updatedAt: Date) {
        self.id = id
        self.eurToGbpRate = eurToGbpRate
        self.updatedAt = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "exchangeRateSetting"

    /// Returns the most recently saved rate, or a sensible default (0.87) if none has been set yet.
    public static func currentOrDefault(db: Database) throws -> ExchangeRateSetting {
        if let latest = try ExchangeRateSetting.order(Column("updatedAt").desc).fetchOne(db) {
            return latest
        }
        return ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
    }
}

func registerExchangeRateSettingMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createExchangeRateSetting") { db in
        try db.create(table: "exchangeRateSetting") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("eurToGbpRate", .double).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
    }
}
```

- [ ] **Step 5: Register the migrations**

```swift
// Sources/BudgetCore/Database/DatabaseManager.swift
// In registerMigrations(_:), append:
        registerBalanceSnapshotMigration(&migrator)
        registerExchangeRateSettingMigration(&migrator)
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter NetWorthModelsTests`
Expected: 3 tests, PASS

- [ ] **Step 7: Commit**

```bash
git add Sources/BudgetCore/Models/BalanceSnapshot.swift Sources/BudgetCore/Models/ExchangeRateSetting.swift Sources/BudgetCore/Database/DatabaseManager.swift Tests/BudgetCoreTests/NetWorthModelsTests.swift
git commit -m "Add BalanceSnapshot and ExchangeRateSetting models"
```

### Task 25: NetWorthCalculator

**Files:**
- Create: `Sources/BudgetCore/NetWorth/NetWorthCalculator.swift`
- Test: `Tests/BudgetCoreTests/NetWorthCalculatorTests.swift`

**Interfaces:**
- Consumes: `Account`, `AccountKind`, `AccountTrackingMode`, `BalanceSnapshot`, `Transaction`, `ExchangeRateSetting`
- Produces: `AccountBalance` (`account: Account`, `nativeBalanceMinorUnits: Int`, `gbpBalanceMinorUnits: Int`, `reconciliationDriftMinorUnits: Int?`), `NetWorthCalculator.runningBalance(account: Account, latestSnapshot: BalanceSnapshot?, transactionsSinceSnapshot: [Transaction]) -> Int`, `NetWorthCalculator.accountBalances(accounts: [Account], snapshots: [BalanceSnapshot], transactions: [Transaction], rate: ExchangeRateSetting) -> [AccountBalance]`, `NetWorthCalculator.netWorth(balances: [AccountBalance]) -> Int`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BudgetCoreTests/NetWorthCalculatorTests.swift
import XCTest
@testable import BudgetCore

final class NetWorthCalculatorTests: XCTestCase {
    func testRunningBalanceIsSnapshotPlusTransactionsSince() {
        let snapshot = BalanceSnapshot(id: 1, accountId: 1, date: Date(timeIntervalSince1970: 0), balanceMinorUnits: 100000, note: nil)
        let transactions = [
            Transaction(id: 1, importBatchId: 1, accountId: 1, date: Date(timeIntervalSince1970: 1000), rawDescription: "A", amountMinorUnits: -5000, categoryId: nil, status: .confirmed, categorizedBy: .manual, fingerprint: "a"),
            Transaction(id: 2, importBatchId: 1, accountId: 1, date: Date(timeIntervalSince1970: 2000), rawDescription: "B", amountMinorUnits: 2000, categoryId: nil, status: .confirmed, categorizedBy: .manual, fingerprint: "b")
        ]
        let account = Account(id: 1, name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        let balance = NetWorthCalculator.runningBalance(account: account, latestSnapshot: snapshot, transactionsSinceSnapshot: transactions)
        XCTAssertEqual(balance, 97000)
    }

    func testManualAccountUsesLatestSnapshotOnly() {
        let snapshot = BalanceSnapshot(id: 1, accountId: 2, date: Date(), balanceMinorUnits: 500000, note: nil)
        let account = Account(id: 2, name: "Lloyds Investment ISA", currency: .gbp, kind: .investment, trackingMode: .manual)
        let balance = NetWorthCalculator.runningBalance(account: account, latestSnapshot: snapshot, transactionsSinceSnapshot: [])
        XCTAssertEqual(balance, 500000)
    }

    func testEURAccountConvertsToGBPUsingRate() {
        let account = Account(id: 3, name: "BBVA Portugal", currency: .eur, kind: .cash, trackingMode: .manual)
        let snapshot = BalanceSnapshot(id: 2, accountId: 3, date: Date(), balanceMinorUnits: 100000, note: nil)
        let rate = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
        let balances = NetWorthCalculator.accountBalances(accounts: [account], snapshots: [snapshot], transactions: [], rate: rate)
        XCTAssertEqual(balances[0].nativeBalanceMinorUnits, 100000)
        XCTAssertEqual(balances[0].gbpBalanceMinorUnits, 87000)
    }

    func testCreditAccountIsALiabilitySubtractedFromNetWorth() {
        let cash = Account(id: 1, name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        let credit = Account(id: 4, name: "AMEX", currency: .gbp, kind: .credit, trackingMode: .imported)
        let cashSnapshot = BalanceSnapshot(id: 1, accountId: 1, date: Date(), balanceMinorUnits: 200000, note: nil)
        let creditSnapshot = BalanceSnapshot(id: 2, accountId: 4, date: Date(), balanceMinorUnits: 30000, note: nil)
        let rate = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
        let balances = NetWorthCalculator.accountBalances(accounts: [cash, credit], snapshots: [cashSnapshot, creditSnapshot], transactions: [], rate: rate)
        let netWorth = NetWorthCalculator.netWorth(balances: balances)
        XCTAssertEqual(netWorth, 170000)
    }

    func testReconciliationDriftIsNilWhenNoActualBalanceProvided() {
        let account = Account(id: 1, name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .imported)
        let snapshot = BalanceSnapshot(id: 1, accountId: 1, date: Date(), balanceMinorUnits: 100000, note: nil)
        let rate = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
        let balances = NetWorthCalculator.accountBalances(accounts: [account], snapshots: [snapshot], transactions: [], rate: rate)
        XCTAssertNil(balances[0].reconciliationDriftMinorUnits)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter NetWorthCalculatorTests`
Expected: FAIL (no such type `NetWorthCalculator`)

- [ ] **Step 3: Implement NetWorthCalculator**

```swift
// Sources/BudgetCore/NetWorth/NetWorthCalculator.swift
import Foundation

public struct AccountBalance {
    public let account: Account
    public let nativeBalanceMinorUnits: Int
    public let gbpBalanceMinorUnits: Int
    /// Non-nil only when a manually-entered "actual" balance has been checked
    /// against the computed running balance for an `.imported` account.
    public let reconciliationDriftMinorUnits: Int?
}

public enum NetWorthCalculator {
    public static func runningBalance(account: Account, latestSnapshot: BalanceSnapshot?, transactionsSinceSnapshot: [Transaction]) -> Int {
        let base = latestSnapshot?.balanceMinorUnits ?? 0
        switch account.trackingMode {
        case .manual:
            return base
        case .imported:
            return base + transactionsSinceSnapshot.reduce(0) { $0 + $1.amountMinorUnits }
        }
    }

    public static func accountBalances(accounts: [Account], snapshots: [BalanceSnapshot], transactions: [Transaction], rate: ExchangeRateSetting) -> [AccountBalance] {
        accounts.map { account in
            let accountSnapshots = snapshots.filter { $0.accountId == account.id }.sorted { $0.date > $1.date }
            let latestSnapshot = accountSnapshots.first
            let transactionsSince = transactions.filter { $0.accountId == account.id && (latestSnapshot == nil || $0.date > latestSnapshot!.date) }
            let native = runningBalance(account: account, latestSnapshot: latestSnapshot, transactionsSinceSnapshot: transactionsSince)
            let gbp: Int
            switch account.currency {
            case .gbp: gbp = native
            case .eur: gbp = Int((Double(native) * rate.eurToGbpRate).rounded())
            }
            return AccountBalance(account: account, nativeBalanceMinorUnits: native, gbpBalanceMinorUnits: gbp, reconciliationDriftMinorUnits: nil)
        }
    }

    /// Cash and investment balances count as assets; credit balances count as liabilities.
    public static func netWorth(balances: [AccountBalance]) -> Int {
        balances.reduce(0) { total, balance in
            switch balance.account.kind {
            case .cash, .investment: return total + balance.gbpBalanceMinorUnits
            case .credit: return total - balance.gbpBalanceMinorUnits
            }
        }
    }

    /// Compares a manually-entered actual balance against the computed running balance,
    /// surfacing drift instead of silently trusting either figure.
    public static func reconciliationDrift(computedNativeBalanceMinorUnits: Int, actualNativeBalanceMinorUnits: Int) -> Int {
        actualNativeBalanceMinorUnits - computedNativeBalanceMinorUnits
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter NetWorthCalculatorTests`
Expected: 5 tests, PASS

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: all tests PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/BudgetCore/NetWorth/NetWorthCalculator.swift Tests/BudgetCoreTests/NetWorthCalculatorTests.swift
git commit -m "Add NetWorthCalculator"
```

### Task 26: Net worth UI (accounts, snapshot entry, history)

**Files:**
- Create: `App/NetWorth/NetWorthViewModel.swift`
- Create: `App/NetWorth/NetWorthView.swift`
- Create: `App/NetWorth/AddSnapshotView.swift`

**Interfaces:**
- Consumes: `NetWorthCalculator`, `AccountBalance` (Task 25), `Account`, `BalanceSnapshot`, `ExchangeRateSetting`

- [ ] **Step 1: Implement the view model**

```swift
// App/NetWorth/NetWorthViewModel.swift
import Foundation
import BudgetCore
import GRDB

@MainActor
final class NetWorthViewModel: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var balances: [AccountBalance] = []
    @Published var netWorthGBP: Int = 0
    @Published var exchangeRate: ExchangeRateSetting = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
    @Published var history: [(date: Date, netWorthGBP: Int)] = []

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func load() throws {
        accounts = try dbQueue.read { db in try Account.fetchAll(db) }
        let snapshots = try dbQueue.read { db in try BalanceSnapshot.fetchAll(db) }
        let transactions = try dbQueue.read { db in try Transaction.fetchAll(db) }
        exchangeRate = try dbQueue.read { db in try ExchangeRateSetting.currentOrDefault(db: db) }
        balances = NetWorthCalculator.accountBalances(accounts: accounts, snapshots: snapshots, transactions: transactions, rate: exchangeRate)
        netWorthGBP = NetWorthCalculator.netWorth(balances: balances)
        history = computeHistory(snapshots: snapshots, transactions: transactions)
    }

    /// One net-worth data point per distinct snapshot date across all accounts,
    /// using each account's most recent snapshot at or before that date.
    private func computeHistory(snapshots: [BalanceSnapshot], transactions: [Transaction]) -> [(date: Date, netWorthGBP: Int)] {
        let distinctDates = Set(snapshots.map(\.date)).sorted()
        return distinctDates.map { asOfDate in
            let snapshotsAsOf = snapshots.filter { $0.date <= asOfDate }
            let balancesAsOf = NetWorthCalculator.accountBalances(accounts: accounts, snapshots: snapshotsAsOf, transactions: transactions.filter { $0.date <= asOfDate }, rate: exchangeRate)
            return (asOfDate, NetWorthCalculator.netWorth(balances: balancesAsOf))
        }
    }

    @Published var reconciliationWarning: String?

    /// For `.imported` accounts, compares the balance being entered against what the
    /// running balance (previous snapshot + transactions since) computes to, and
    /// surfaces a warning rather than silently accepting a figure that implies a
    /// missing or duplicate transaction. The snapshot is saved either way.
    func addSnapshot(accountId: Int64, balanceMinorUnits: Int, note: String?) throws {
        reconciliationWarning = nil
        if let account = accounts.first(where: { $0.id == accountId }), account.trackingMode == .imported {
            let previousSnapshot = try dbQueue.read { db in
                try BalanceSnapshot.filter(Column("accountId") == accountId).order(Column("date").desc).fetchOne(db)
            }
            let transactionsSince = try dbQueue.read { db -> [Transaction] in
                if let previousSnapshot {
                    return try Transaction.filter(Column("accountId") == accountId && Column("date") > previousSnapshot.date).fetchAll(db)
                } else {
                    return try Transaction.filter(Column("accountId") == accountId).fetchAll(db)
                }
            }
            let computed = NetWorthCalculator.runningBalance(account: account, latestSnapshot: previousSnapshot, transactionsSinceSnapshot: transactionsSince)
            let drift = NetWorthCalculator.reconciliationDrift(computedNativeBalanceMinorUnits: computed, actualNativeBalanceMinorUnits: balanceMinorUnits)
            if drift != 0 {
                reconciliationWarning = "\(account.name): entered balance differs from the computed running balance by \(Money.format(drift, currency: account.currency)) — check for a missing or duplicate transaction."
            }
        }
        var snapshot = BalanceSnapshot(accountId: accountId, date: Date(), balanceMinorUnits: balanceMinorUnits, note: note)
        try dbQueue.write { db in try snapshot.insert(db) }
        try load()
    }

    func updateExchangeRate(_ rate: Double) throws {
        var setting = ExchangeRateSetting(eurToGbpRate: rate, updatedAt: Date())
        try dbQueue.write { db in try setting.insert(db) }
        try load()
    }
}
```

- [ ] **Step 2: Implement the add-snapshot sheet**

```swift
// App/NetWorth/AddSnapshotView.swift
import SwiftUI
import BudgetCore

struct AddSnapshotView: View {
    let accounts: [Account]
    let onSave: (Int64, Int, String?) -> Void

    @State private var accountId: Int64?
    @State private var amountText = ""
    @State private var note = ""

    var body: some View {
        Form {
            Picker("Account", selection: $accountId) {
                Text("Select…").tag(Int64?.none)
                ForEach(accounts) { account in Text("\(account.name) (\(account.currency.rawValue.uppercased()))").tag(Int64?.some(account.id!)) }
            }
            TextField("Current balance", text: $amountText)
            TextField("Note (optional)", text: $note)
            Button("Save") {
                guard let accountId, let value = Double(amountText) else { return }
                onSave(accountId, Int((value * 100).rounded()), note.isEmpty ? nil : note)
            }
        }
        .padding()
        .frame(width: 360)
    }
}
```

- [ ] **Step 3: Implement the net worth view**

```swift
// App/NetWorth/NetWorthView.swift
import SwiftUI
import BudgetCore

struct NetWorthView: View {
    @ObservedObject var viewModel: NetWorthViewModel
    @State private var showAddSnapshot = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Net Worth: \(Money.format(viewModel.netWorthGBP, currency: .gbp))")
                .font(.largeTitle).bold()

            if let warning = viewModel.reconciliationWarning {
                Text(warning)
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            ForEach(groupedByKind(), id: \.0) { kind, balancesInKind in
                VStack(alignment: .leading) {
                    Text(kind.rawValue.capitalized).font(.headline)
                    ForEach(balancesInKind, id: \.account.id) { balance in
                        HStack {
                            Text(balance.account.name)
                            Spacer()
                            Text(Money.format(balance.nativeBalanceMinorUnits, currency: balance.account.currency))
                            if balance.account.currency != .gbp {
                                Text("(\(Money.format(balance.gbpBalanceMinorUnits, currency: .gbp)))")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Button("Update a balance…") { showAddSnapshot = true }

            if !viewModel.history.isEmpty {
                Text("History").font(.headline)
                ForEach(viewModel.history, id: \.date) { point in
                    HStack {
                        Text(point.date.formatted(date: .abbreviated, time: .omitted))
                        Spacer()
                        Text(Money.format(point.netWorthGBP, currency: .gbp))
                    }
                }
            }
        }
        .padding()
        .sheet(isPresented: $showAddSnapshot) {
            AddSnapshotView(accounts: viewModel.accounts) { accountId, minorUnits, note in
                try? viewModel.addSnapshot(accountId: accountId, balanceMinorUnits: minorUnits, note: note)
                showAddSnapshot = false
            }
        }
    }

    private func groupedByKind() -> [(AccountKind, [AccountBalance])] {
        Dictionary(grouping: viewModel.balances, by: { $0.account.kind })
            .sorted { $0.key.rawValue < $1.key.rawValue }
    }
}
```

- [ ] **Step 4: Build to verify it compiles**

Run:
```bash
xcodegen generate
xcodebuild -project Budget.xcodeproj -scheme Budget -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Manually verify**

Temporarily present `NetWorthView` from `ContentView` with a scratch database. Create 2-3 accounts (one GBP cash `.imported`, one GBP investment `.manual`, one EUR cash `.manual`) via a debug seeding button, add a balance snapshot to each via "Update a balance…", and confirm: totals group correctly by kind, the EUR account shows its GBP-converted equivalent, and net worth reflects credit accounts (if you add one) as a subtraction. Then, for the `.imported` account, insert a transaction directly via `sqlite3` after its first snapshot and add a second snapshot whose value does *not* account for that transaction — confirm the reconciliation warning appears with a nonzero drift amount, and that the snapshot still saves.

- [ ] **Step 6: Commit**

```bash
git add App/NetWorth
git commit -m "Add net worth UI with account balances, snapshots, and history"
```

---

## Phase 7: Budget Grid, Export, Rules UI, and Navigation

### Task 27: BudgetGridCalculator

**Files:**
- Create: `Sources/BudgetCore/Budget/BudgetGridCalculator.swift`
- Test: `Tests/BudgetCoreTests/BudgetGridCalculatorTests.swift`

**Interfaces:**
- Consumes: `Transaction`, `Category`, `CategoryType`, `PayPeriod`, `PayPeriodType`, `ForecastCalculator` (Tasks 5, 3, 17, 22)
- Produces: `PeriodSummary` (`period: PayPeriod`, `incomeMinorUnits: Int`, `expensesMinorUnits: Int`, `transfersMinorUnits: Int`, computed `moneyRemainingMinorUnits: Int`), `BudgetGridCalculator.categoryTotal(category: Category, period: PayPeriod, transactions: [Transaction], forecastEntries: [ForecastEntry], forecastGroups: [ForecastGroup]) -> Int`, `BudgetGridCalculator.periodSummary(period: PayPeriod, categories: [Category], transactions: [Transaction], forecastEntries: [ForecastEntry], forecastGroups: [ForecastGroup]) -> PeriodSummary`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BudgetCoreTests/BudgetGridCalculatorTests.swift
import XCTest
@testable import BudgetCore

final class BudgetGridCalculatorTests: XCTestCase {
    func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func testActualPeriodSumsConfirmedTransactions() {
        let rent = Category(id: 1, name: "Rent", type: .expense)
        let period = PayPeriod(startDate: date(2026, 6, 26), endDate: date(2026, 7, 25), type: .actual)
        let transactions = [
            Transaction(id: 1, importBatchId: 1, accountId: 1, date: date(2026, 6, 28), rawDescription: "RENT", amountMinorUnits: -280000, categoryId: 1, status: .confirmed, categorizedBy: .manual, fingerprint: "a")
        ]
        let total = BudgetGridCalculator.categoryTotal(category: rent, period: period, transactions: transactions, forecastEntries: [], forecastGroups: [])
        XCTAssertEqual(total, -280000)
    }

    func testProjectedPeriodUsesConfirmedForecastTotal() {
        let rent = Category(id: 1, name: "Rent", type: .expense)
        let period = PayPeriod(startDate: date(2026, 9, 26), endDate: date(2026, 10, 25), type: .projected)
        let group = ForecastGroup(id: 1, name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)
        let entry = ForecastEntry(id: 1, groupId: 1, categoryId: 1, amountMinorUnits: -280000, frequency: .monthly, interval: 1, startDate: date(2026, 6, 26), endDate: nil, isEnabled: true, status: .auto, note: nil)
        let total = BudgetGridCalculator.categoryTotal(category: rent, period: period, transactions: [], forecastEntries: [entry], forecastGroups: [group])
        XCTAssertEqual(total, -280000)
    }

    func testPeriodSummaryComputesIncomeExpensesTransfersAndRemaining() {
        let income = Category(id: 1, name: "Income", type: .income)
        let rent = Category(id: 2, name: "Rent", type: .expense)
        let isaTransfer = Category(id: 3, name: "Transfer: Lloyds Investment ISA", type: .transfer)
        let period = PayPeriod(startDate: date(2026, 6, 26), endDate: date(2026, 7, 25), type: .actual)
        let transactions = [
            Transaction(id: 1, importBatchId: 1, accountId: 1, date: date(2026, 6, 26), rawDescription: "SALARY", amountMinorUnits: 280000, categoryId: 1, status: .confirmed, categorizedBy: .manual, fingerprint: "a"),
            Transaction(id: 2, importBatchId: 1, accountId: 1, date: date(2026, 6, 28), rawDescription: "RENT", amountMinorUnits: -180000, categoryId: 2, status: .confirmed, categorizedBy: .manual, fingerprint: "b"),
            Transaction(id: 3, importBatchId: 1, accountId: 1, date: date(2026, 6, 29), rawDescription: "ISA", amountMinorUnits: -50000, categoryId: 3, status: .confirmed, categorizedBy: .manual, fingerprint: "c")
        ]
        let summary = BudgetGridCalculator.periodSummary(period: period, categories: [income, rent, isaTransfer], transactions: transactions, forecastEntries: [], forecastGroups: [])
        XCTAssertEqual(summary.incomeMinorUnits, 280000)
        XCTAssertEqual(summary.expensesMinorUnits, 180000)
        XCTAssertEqual(summary.transfersMinorUnits, 50000)
        XCTAssertEqual(summary.moneyRemainingMinorUnits, 50000)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter BudgetGridCalculatorTests`
Expected: FAIL (no such type `BudgetGridCalculator`)

- [ ] **Step 3: Implement BudgetGridCalculator**

```swift
// Sources/BudgetCore/Budget/BudgetGridCalculator.swift
import Foundation

public struct PeriodSummary {
    public let period: PayPeriod
    public let incomeMinorUnits: Int
    public let expensesMinorUnits: Int
    public let transfersMinorUnits: Int

    public var moneyRemainingMinorUnits: Int {
        incomeMinorUnits - expensesMinorUnits - transfersMinorUnits
    }
}

public enum BudgetGridCalculator {
    public static func categoryTotal(category: Category, period: PayPeriod, transactions: [Transaction], forecastEntries: [ForecastEntry], forecastGroups: [ForecastGroup]) -> Int {
        switch period.type {
        case .actual:
            return transactions
                .filter { $0.categoryId == category.id && $0.status == .confirmed && $0.date >= period.startDate && $0.date <= period.endDate }
                .reduce(0) { $0 + $1.amountMinorUnits }
        case .projected:
            return ForecastCalculator.confirmedTotal(categoryId: category.id!, period: period, entries: forecastEntries, groups: forecastGroups)
        }
    }

    public static func periodSummary(period: PayPeriod, categories: [Category], transactions: [Transaction], forecastEntries: [ForecastEntry], forecastGroups: [ForecastGroup]) -> PeriodSummary {
        var income = 0, expenses = 0, transfers = 0
        for category in categories {
            let total = categoryTotal(category: category, period: period, transactions: transactions, forecastEntries: forecastEntries, forecastGroups: forecastGroups)
            switch category.type {
            case .income: income += total
            case .expense: expenses += abs(total)
            case .transfer: transfers += abs(total)
            }
        }
        return PeriodSummary(period: period, incomeMinorUnits: income, expensesMinorUnits: expenses, transfersMinorUnits: transfers)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BudgetGridCalculatorTests`
Expected: 3 tests, PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/BudgetCore/Budget/BudgetGridCalculator.swift Tests/BudgetCoreTests/BudgetGridCalculatorTests.swift
git commit -m "Add BudgetGridCalculator for actual/forecast category and period totals"
```

### Task 28: Budget grid and period summary UI

**Files:**
- Create: `App/Budget/BudgetGridViewModel.swift`
- Create: `App/Budget/BudgetGridView.swift`

**Interfaces:**
- Consumes: `BudgetGridCalculator`, `PeriodSummary` (Task 27), `PayPeriodDetector` (Task 18)

- [ ] **Step 1: Implement the view model**

```swift
// App/Budget/BudgetGridViewModel.swift
import Foundation
import BudgetCore
import GRDB

@MainActor
final class BudgetGridViewModel: ObservableObject {
    @Published var categories: [Category] = []
    @Published var periods: [PayPeriod] = []
    @Published var transactions: [Transaction] = []
    @Published var forecastEntries: [ForecastEntry] = []
    @Published var forecastGroups: [ForecastGroup] = []

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func load(horizon: Date) throws {
        categories = try dbQueue.read { db in try Category.fetchAll(db) }
        transactions = try dbQueue.read { db in try Transaction.fetchAll(db) }
        forecastEntries = try dbQueue.read { db in try ForecastEntry.fetchAll(db) }
        forecastGroups = try dbQueue.read { db in try ForecastGroup.fetchAll(db) }
        let incomeCategoryIds = categories.filter { $0.type == .income }.compactMap(\.id)
        let incomeDates = transactions
            .filter { $0.status == .confirmed && incomeCategoryIds.contains($0.categoryId ?? -1) }
            .map(\.date).sorted()
        var allPeriods = PayPeriodDetector.generateActualPeriods(incomeDates: incomeDates)
        if let cadence = PayPeriodDetector.detectCadence(incomeDates: incomeDates) {
            allPeriods += PayPeriodDetector.generateProjectedPeriods(cadence: cadence, horizon: horizon)
        }
        periods = allPeriods
    }

    func categoryTotal(_ category: Category, in period: PayPeriod) -> Int {
        BudgetGridCalculator.categoryTotal(category: category, period: period, transactions: transactions, forecastEntries: forecastEntries, forecastGroups: forecastGroups)
    }

    func summary(for period: PayPeriod) -> PeriodSummary {
        BudgetGridCalculator.periodSummary(period: period, categories: categories, transactions: transactions, forecastEntries: forecastEntries, forecastGroups: forecastGroups)
    }
}
```

- [ ] **Step 2: Implement the grid view**

```swift
// App/Budget/BudgetGridView.swift
import SwiftUI
import BudgetCore

struct BudgetGridView: View {
    @ObservedObject var viewModel: BudgetGridViewModel

    private func categoriesByType(_ type: CategoryType) -> [Category] {
        viewModel.categories.filter { $0.type == type }
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading) {
                headerRow
                summaryRows
                Divider()
                categorySection(.income, title: "Income")
                categorySection(.expense, title: "Expenses")
                categorySection(.transfer, title: "Transfers")
            }
            .padding()
        }
    }

    private var headerRow: some View {
        GridRow {
            Text("").frame(width: 220, alignment: .leading)
            ForEach(viewModel.periods) { period in
                VStack {
                    Text(period.startDate.formatted(date: .abbreviated, time: .omitted))
                    if period.type == .projected { Text("(forecast)").font(.caption).foregroundStyle(.secondary) }
                }
                .frame(width: 120)
            }
        }
        .font(.headline)
    }

    private var summaryRows: some View {
        Group {
            summaryRow("Income") { viewModel.summary(for: $0).incomeMinorUnits }
            summaryRow("Total Expenses") { viewModel.summary(for: $0).expensesMinorUnits }
            summaryRow("Total Transfers") { viewModel.summary(for: $0).transfersMinorUnits }
            summaryRow("Money Remaining") { viewModel.summary(for: $0).moneyRemainingMinorUnits }
        }
        .bold()
    }

    private func summaryRow(_ title: String, _ value: @escaping (PayPeriod) -> Int) -> some View {
        GridRow {
            Text(title).frame(width: 220, alignment: .leading)
            ForEach(viewModel.periods) { period in
                Text(Money.format(value(period), currency: .gbp)).frame(width: 120)
            }
        }
    }

    private func categorySection(_ type: CategoryType, title: String) -> some View {
        Section {
            ForEach(categoriesByType(type)) { category in
                GridRow {
                    Text(category.name).frame(width: 220, alignment: .leading)
                    ForEach(viewModel.periods) { period in
                        let total = viewModel.categoryTotal(category, in: period)
                        Text(total == 0 ? "—" : Money.format(total, currency: .gbp))
                            .frame(width: 120)
                            .foregroundStyle(total == 0 ? .secondary : .primary)
                    }
                }
            }
        } header: {
            GridRow { Text(title).font(.subheadline).bold().padding(.top, 8) }
        }
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run:
```bash
xcodegen generate
xcodebuild -project Budget.xcodeproj -scheme Budget -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Manually verify**

Present `BudgetGridView` from `ContentView` against a scratch database populated by importing a real (or synthetic) CSV statement through the flow built in Task 14, running `AutoForecastGenerator.regenerate`, and confirming the grid shows actuals for past periods and forecast figures for future ones, with the summary rows adding up correctly.

- [ ] **Step 5: Commit**

```bash
git add App/Budget
git commit -m "Add budget grid and period summary UI"
```

### Task 29: CSV export of the actuals grid

**Files:**
- Create: `Sources/BudgetCore/Budget/BudgetGridExporter.swift`
- Modify: `App/Budget/BudgetGridView.swift` (add an export button)
- Test: `Tests/BudgetCoreTests/BudgetGridExporterTests.swift`

**Interfaces:**
- Consumes: `Category`, `PayPeriod`, `Transaction`, `BudgetGridCalculator` (Task 27)
- Produces: `BudgetGridExporter.export(categories: [Category], periods: [PayPeriod], transactions: [Transaction]) -> String`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BudgetCoreTests/BudgetGridExporterTests.swift
import XCTest
@testable import BudgetCore

final class BudgetGridExporterTests: XCTestCase {
    func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func testExportsOnlyActualPeriodsAsCSV() {
        let rent = Category(id: 1, name: "Rent", type: .expense)
        let actualPeriod = PayPeriod(startDate: date(2026, 6, 26), endDate: date(2026, 7, 25), type: .actual)
        let projectedPeriod = PayPeriod(startDate: date(2026, 7, 26), endDate: date(2026, 8, 25), type: .projected)
        let transactions = [
            Transaction(id: 1, importBatchId: 1, accountId: 1, date: date(2026, 6, 28), rawDescription: "RENT", amountMinorUnits: -280000, categoryId: 1, status: .confirmed, categorizedBy: .manual, fingerprint: "a")
        ]
        let csv = BudgetGridExporter.export(categories: [rent], periods: [actualPeriod, projectedPeriod], transactions: transactions)
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines[0], "Category,2026-06-26")
        XCTAssertEqual(lines[1], "Rent,-2800.00")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter BudgetGridExporterTests`
Expected: FAIL (no such type `BudgetGridExporter`)

- [ ] **Step 3: Implement BudgetGridExporter**

```swift
// Sources/BudgetCore/Budget/BudgetGridExporter.swift
import Foundation

public enum BudgetGridExporter {
    public static func export(categories: [Category], periods: [PayPeriod], transactions: [Transaction]) -> String {
        let actualPeriods = periods.filter { $0.type == .actual }.sorted { $0.startDate < $1.startDate }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")

        var lines = ["Category," + actualPeriods.map { dateFormatter.string(from: $0.startDate) }.joined(separator: ",")]
        for category in categories {
            let values = actualPeriods.map { period -> String in
                let total = BudgetGridCalculator.categoryTotal(category: category, period: period, transactions: transactions, forecastEntries: [], forecastGroups: [])
                return String(format: "%.2f", Double(total) / 100.0)
            }
            lines.append(([category.name] + values).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BudgetGridExporterTests`
Expected: 1 test, PASS

- [ ] **Step 5: Wire an export button into BudgetGridView**

```swift
// App/Budget/BudgetGridView.swift
// Add to the top of the VStack/ScrollView content, and a matching @State + .fileExporter:

Button("Export CSV…") { showExporter = true }
// Add @State private var showExporter = false to BudgetGridView, and:
.fileExporter(isPresented: $showExporter, document: CSVDocument(text: BudgetGridExporter.export(categories: viewModel.categories, periods: viewModel.periods, transactions: viewModel.transactions)), contentType: .commaSeparatedText, defaultFilename: "budget-export") { _ in }
```

```swift
// App/Budget/BudgetGridView.swift
// Add near the top of the file, below the imports:

import UniformTypeIdentifiers

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    let text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = "" }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
```

- [ ] **Step 6: Build to verify it compiles**

Run:
```bash
xcodegen generate
xcodebuild -project Budget.xcodeproj -scheme Budget -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Manually verify**

Click "Export CSV…" in a running build with real data and confirm the saved file opens correctly in Numbers/Excel with one row per category and one column per actual pay period.

- [ ] **Step 8: Commit**

```bash
git add Sources/BudgetCore/Budget/BudgetGridExporter.swift App/Budget/BudgetGridView.swift Tests/BudgetCoreTests/BudgetGridExporterTests.swift
git commit -m "Add CSV export of the category by period actuals grid"
```

### Task 30: Rules settings UI

**Files:**
- Create: `App/Rules/RulesViewModel.swift`
- Create: `App/Rules/RulesView.swift`

**Interfaces:**
- Consumes: `Rule`, `RuleMatchType`, `Category` (Tasks 6, 3)

- [ ] **Step 1: Implement the view model**

```swift
// App/Rules/RulesViewModel.swift
import Foundation
import BudgetCore
import GRDB

@MainActor
final class RulesViewModel: ObservableObject {
    @Published var rules: [Rule] = []
    @Published var categories: [Category] = []

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func load() throws {
        rules = try dbQueue.read { db in try Rule.fetchAll(db).sorted { $0.priority > $1.priority } }
        categories = try dbQueue.read { db in try Category.fetchAll(db) }
    }

    func delete(_ rule: Rule) throws {
        _ = try dbQueue.write { db in try rule.delete(db) }
        try load()
    }

    func updateCategory(_ rule: Rule, to categoryId: Int64) throws {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index].categoryId = categoryId
        try dbQueue.write { db in try rules[index].update(db) }
    }
}
```

- [ ] **Step 2: Implement the rules list view**

```swift
// App/Rules/RulesView.swift
import SwiftUI
import BudgetCore

struct RulesView: View {
    @ObservedObject var viewModel: RulesViewModel

    var body: some View {
        Table(viewModel.rules) {
            TableColumn("Pattern") { rule in Text(rule.matchPattern) }
            TableColumn("Type") { rule in Text(rule.matchType.rawValue) }
            TableColumn("Category") { rule in
                Picker("", selection: Binding(
                    get: { rule.categoryId },
                    set: { newValue in try? viewModel.updateCategory(rule, to: newValue) }
                )) {
                    ForEach(viewModel.categories) { category in Text(category.name).tag(category.id!) }
                }
                .labelsHidden()
            }
            TableColumn("Priority") { rule in Text("\(rule.priority)") }
            TableColumn("") { rule in
                Button("Delete") { try? viewModel.delete(rule) }
            }
        }
        .padding()
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run:
```bash
xcodegen generate
xcodebuild -project Budget.xcodeproj -scheme Budget -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Manually verify**

Present `RulesView` against a scratch database that has a few rules created by the review-screen correction flow (Task 12/14). Confirm you can re-point a rule at a different category and delete a rule, and that both persist after reloading.

- [ ] **Step 5: Commit**

```bash
git add App/Rules
git commit -m "Add rules settings UI for viewing, editing, and deleting learned rules"
```

### Task 31: App shell — persistent database, accounts settings, API key settings, navigation, and end-to-end verification

**Files:**
- Create: `App/AppEnvironment.swift`
- Create: `App/Accounts/AccountsSettingsView.swift`
- Create: `App/Settings/APIKeySettingsView.swift`
- Modify: `App/BudgetApp.swift`
- Modify: `App/ContentView.swift` (becomes the navigation shell)

**Interfaces:**
- Consumes: everything from Tasks 1-30
- Produces: `AppEnvironment` (`@MainActor` object holding `let dbQueue: DatabaseQueue`, constructed once at app launch, injected via `.environmentObject` or passed explicitly to each screen's view model)

- [ ] **Step 1: Implement AppEnvironment with a persistent, migrated, seeded database**

```swift
// App/AppEnvironment.swift
import Foundation
import BudgetCore
import GRDB

@MainActor
final class AppEnvironment: ObservableObject {
    let dbQueue: DatabaseQueue

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Budget", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let dbPath = appSupport.appendingPathComponent("budget.sqlite").path

        let manager = try! DatabaseManager(path: dbPath)
        try! manager.migrate()
        try! manager.dbQueue.write { db in
            try CategorySeeder.seedDefaults(db)
        }
        self.dbQueue = manager.dbQueue
    }
}
```

- [ ] **Step 2: Implement account creation/settings**

```swift
// App/Accounts/AccountsSettingsView.swift
import SwiftUI
import BudgetCore
import GRDB

@MainActor
final class AccountsSettingsViewModel: ObservableObject {
    @Published var accounts: [Account] = []
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func load() throws {
        accounts = try dbQueue.read { db in try Account.fetchAll(db) }
    }

    func addAccount(name: String, currency: Currency, kind: AccountKind, trackingMode: AccountTrackingMode) throws {
        var account = Account(name: name, currency: currency, kind: kind, trackingMode: trackingMode)
        try dbQueue.write { db in try account.insert(db) }
        try load()
    }
}

struct AccountsSettingsView: View {
    @ObservedObject var viewModel: AccountsSettingsViewModel
    @State private var name = ""
    @State private var currency: Currency = .gbp
    @State private var kind: AccountKind = .cash
    @State private var trackingMode: AccountTrackingMode = .manual

    var body: some View {
        VStack(alignment: .leading) {
            List(viewModel.accounts) { account in
                Text("\(account.name) — \(account.currency.rawValue.uppercased()) — \(account.kind.rawValue) — \(account.trackingMode.rawValue)")
            }
            Divider()
            Form {
                TextField("Name", text: $name)
                Picker("Currency", selection: $currency) { ForEach(Currency.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) } }
                Picker("Kind", selection: $kind) { ForEach(AccountKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Picker("Tracking", selection: $trackingMode) { ForEach(AccountTrackingMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Button("Add account") {
                    guard !name.isEmpty else { return }
                    try? viewModel.addAccount(name: name, currency: currency, kind: kind, trackingMode: trackingMode)
                    name = ""
                }
            }
        }
        .padding()
        .onAppear { try? viewModel.load() }
    }
}
```

- [ ] **Step 3: Implement API key settings**

```swift
// App/Settings/APIKeySettingsView.swift
import SwiftUI
import BudgetCore

struct APIKeySettingsView: View {
    private let store: APIKeyStoring = KeychainAPIKeyStore()
    @State private var apiKey: String = ""
    @State private var saved = false

    var body: some View {
        Form {
            SecureField("Anthropic API key", text: $apiKey)
            Button("Save") {
                try? store.setAPIKey(apiKey)
                saved = true
            }
            if saved { Text("Saved.").foregroundStyle(.secondary) }
            Text("Used only as a fallback when a transaction doesn't match any existing rule. If left blank, unmatched transactions are simply left uncategorized for manual review.")
                .font(.caption)
        }
        .padding()
        .onAppear { apiKey = store.getAPIKey() ?? "" }
    }
}
```

- [ ] **Step 4: Wire AppEnvironment into the app entry point**

```swift
// App/BudgetApp.swift
import SwiftUI

@main
struct BudgetApp: App {
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            ContentView(environment: environment)
        }
    }
}
```

- [ ] **Step 5: Build the navigation shell in ContentView**

```swift
// App/ContentView.swift
import SwiftUI
import BudgetCore
import GRDB

enum AppScreen: String, CaseIterable, Identifiable {
    case importReview = "Import"
    case budgetGrid = "Budget"
    case forecast = "Forecast"
    case netWorth = "Net Worth"
    case rules = "Rules"
    case accounts = "Accounts"
    case settings = "Settings"
    var id: String { rawValue }
}

struct ContentView: View {
    @ObservedObject var environment: AppEnvironment
    @State private var selection: AppScreen? = .importReview
    @State private var selectedAccount: Account?
    @State private var accounts: [Account] = []
    @State private var categories: [Category] = []

    var body: some View {
        NavigationSplitView {
            List(AppScreen.allCases, selection: $selection) { screen in
                Text(screen.rawValue).tag(screen)
            }
        } detail: {
            Group {
                switch selection {
                case .importReview:
                    if let account = selectedAccount {
                        ImportView(
                            viewModel: ImportViewModel(dbQueue: environment.dbQueue, coordinator: makeImportCoordinator(), profileStore: ImportProfileStore(dbQueue: environment.dbQueue)),
                            account: account, categories: categories, profileStore: ImportProfileStore(dbQueue: environment.dbQueue)
                        )
                    } else {
                        Text("Add an account under Accounts, then pick it here to import a statement.")
                    }
                case .budgetGrid:
                    BudgetGridView(viewModel: BudgetGridViewModel(dbQueue: environment.dbQueue))
                case .forecast:
                    ForecastComparisonView(viewModel: ForecastViewModel(dbQueue: environment.dbQueue), categories: categories)
                case .netWorth:
                    NetWorthView(viewModel: NetWorthViewModel(dbQueue: environment.dbQueue))
                case .rules:
                    RulesView(viewModel: RulesViewModel(dbQueue: environment.dbQueue))
                case .accounts:
                    AccountsSettingsView(viewModel: AccountsSettingsViewModel(dbQueue: environment.dbQueue))
                case .settings, .none:
                    APIKeySettingsView()
                }
            }
        }
        .onAppear {
            categories = (try? environment.dbQueue.read { db in try Category.fetchAll(db) }) ?? []
            accounts = (try? environment.dbQueue.read { db in try Account.fetchAll(db) }) ?? []
            selectedAccount = accounts.first
        }
    }

    private func makeImportCoordinator() -> ImportCoordinator {
        let categorizer = ClaudeCategorizer(apiKeyStore: KeychainAPIKeyStore(), session: .shared)
        let service = CategorizationService(categorizer: categorizer)
        return ImportCoordinator(dbQueue: environment.dbQueue, categorizationService: service)
    }
}
```

- [ ] **Step 6: Build the full app**

Run:
```bash
xcodegen generate
xcodebuild -project Budget.xcodeproj -scheme Budget -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Run the full BudgetCore test suite one last time**

Run: `swift test`
Expected: all tests PASS

- [ ] **Step 8: End-to-end manual verification**

Launch the app (`open Budget.xcodeproj`, run the `Budget` scheme, or `xcodebuild ... && open build/Debug/Budget.app`) against the real, persistent database and walk the full flow with your own real (or safely anonymized) data:
1. Under **Accounts**, add "Lloyds Classic" (GBP, cash, imported), "AMEX" (GBP, credit, imported), and at least one manual account (e.g. an ISA, GBP, investment, manual).
2. Optionally set your Anthropic API key under **Settings**.
3. Under **Import**, select Lloyds Classic and import a real CSV export — run the mapping wizard once, confirm categorization suggestions look reasonable, correct any wrong ones, and commit.
4. Re-import the same file (or an overlapping-date export) and confirm duplicates are correctly skipped.
5. Import a real PDF statement for an account and confirm the layout wizard produces a sensible match count, adjusting the regex if needed.
6. Under **Budget**, confirm actual totals for past periods look right and match what you'd expect from the statement.
7. Under **Forecast**, confirm the "Detected recurring" group picked up your fixed bills at roughly the right amounts; add a hypothetical entry (e.g. a speculative new expense) and confirm the Preview column updates without touching Confirmed, then confirm it and watch it join Confirmed.
8. Under **Net Worth**, add a snapshot for your manual account and confirm the total and EUR conversion (if applicable) look right.
9. Export a CSV from the Budget screen and open it in Numbers to sanity-check it against the original spreadsheet's numbers for an overlapping period.

Note and fix any rough edges found during this pass before considering v1 done — this step is exploratory verification, not a fixed checklist to rubber-stamp.

- [ ] **Step 9: Commit**

```bash
git add App/AppEnvironment.swift App/Accounts App/Settings App/BudgetApp.swift App/ContentView.swift
git commit -m "Wire app shell: persistent database, accounts, API key settings, and navigation"
```
