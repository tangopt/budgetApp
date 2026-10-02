# Statement Balances Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Importing a bank CSV with a running Balance column records the account's balance as `BalanceSnapshot`s (month starts + closing), verified against the transaction amounts, and the CSV mapping wizard pre-selects columns from the header.

**Architecture:** Pure BudgetCore logic (`CSVColumnSuggester`, `StatementBalanceExtractor`) plus small additions to the parser, `ImportProfile` (new nullable column) and `ImportCoordinator` (attach the verified result at staging; upsert snapshots on demand). The App layer only wires UI: wizard pre-selection and a Balance picker, an `ImportViewModel` that records once on first commit, and a "Statement balances" panel in `ReviewView`. An `AppEnvironment` env-var override lets the importer be exercised against a copy of the database.

**Tech Stack:** Swift 5.10 / SwiftUI (macOS 26), GRDB 6.29, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-02-statement-balances-design.md` (companion: `2026-10-02-dashboard-design.md`)

## Global Constraints

- Money is `Int` minor units, signed (negative = money out). All date logic uses a **UTC** gregorian calendar. No new dependencies.
- A snapshot dated *d* means "balance at the close of day *d*" (consistent with `NetWorthCalculator.runningBalance`, which adds transactions dated strictly after the snapshot).
- Existing tests (158) must stay green; existing `ImportProfile`/`ParsedTransaction` call sites use labeled arguments, so new parameters are added **with defaults**.
- Test files: never annotate with a bare `Category` type (ambiguous with an Objective-C typedef in this toolchain) — use inferred types. App files that reference `Category` use `import struct BudgetCore.Category`.
- Work directly on `main` (no worktree). Commit messages end with a blank line then `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. **Do not push.**
- Build hygiene (repo lives under iCloud-synced `~/Documents`): never run `swift test` and `xcodebuild` at the same time. If you see "ambiguous for type lookup" errors mentioning GRDB files with " 2.swift" names, run `rm -rf .build` and rebuild once in isolation. `xcodebuild` can exceed 2–5 minutes; let it finish.
- Test commands: `swift test --filter <ClassName>` for one class, `swift test` for everything. App build: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' build` (note the DerivedData path in the output; launch with `open "<that path>/Build/Products/Debug/Budget.app"`, never by bundle id — stale builds exist in other DerivedData folders).
- **Never run, import into, or write to the real database** (`~/Library/Application Support/Budget/budget.sqlite`) during this plan. Task 8 uses a copy.

---

### Task 1: CSVColumnSuggester

**Files:**
- Create: `Sources/BudgetCore/Import/CSVColumnSuggester.swift`
- Test: `Tests/BudgetCoreTests/CSVColumnSuggesterTests.swift`

**Interfaces:**
- Produces: `CSVColumnSuggestion` (`dateColumn`, `descriptionColumn`, `amountColumn`, `creditColumn`, `balanceColumn`: all `Int?`; `hasSeparateDebitCredit: Bool`) and `CSVColumnSuggester.suggest(header: [String]) -> CSVColumnSuggestion`. Used by Task 6.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/BudgetCoreTests/CSVColumnSuggesterTests.swift
import XCTest
@testable import BudgetCore

final class CSVColumnSuggesterTests: XCTestCase {
    func testSuggestsLloydsDebitCreditLayout() {
        let header = ["Transaction Date", "Transaction Type", "Sort Code", "Account Number",
                      "Transaction Description", "Debit Amount", "Credit Amount", "Balance"]
        XCTAssertEqual(
            CSVColumnSuggester.suggest(header: header),
            CSVColumnSuggestion(dateColumn: 0, descriptionColumn: 4, amountColumn: 5, creditColumn: 6, balanceColumn: 7)
        )
    }

    func testSuggestsSingleAmountLayout() {
        let suggestion = CSVColumnSuggester.suggest(header: ["Date", "Description", "Amount"])
        XCTAssertEqual(suggestion, CSVColumnSuggestion(dateColumn: 0, descriptionColumn: 1, amountColumn: 2, creditColumn: nil, balanceColumn: nil))
        XCTAssertFalse(suggestion.hasSeparateDebitCredit)
    }

    func testSuggestsPaidInPaidOutLayout() {
        let suggestion = CSVColumnSuggester.suggest(header: ["Date", "Details", "Paid out", "Paid in", "Balance"])
        XCTAssertEqual(suggestion, CSVColumnSuggestion(dateColumn: 0, descriptionColumn: 1, amountColumn: 2, creditColumn: 3, balanceColumn: 4))
        XCTAssertTrue(suggestion.hasSeparateDebitCredit)
    }

    func testLoneCreditColumnIsIgnored() {
        let suggestion = CSVColumnSuggester.suggest(header: ["Date", "Description", "Credit", "Notes"])
        XCTAssertNil(suggestion.amountColumn)
        XCTAssertNil(suggestion.creditColumn)
    }

    func testPrefersTransactionDateOverOtherDateColumns() {
        let suggestion = CSVColumnSuggester.suggest(header: ["Posting Date", "Transaction Date", "Description", "Amount"])
        XCTAssertEqual(suggestion.dateColumn, 1)
    }

    func testDescriptionKeywordPriority() {
        let suggestion = CSVColumnSuggester.suggest(header: ["Date", "Reference", "Payee", "Narrative", "Amount"])
        XCTAssertEqual(suggestion.descriptionColumn, 3)
    }

    func testUnknownHeaderYieldsNoSuggestions() {
        XCTAssertEqual(CSVColumnSuggester.suggest(header: ["A", "B", "C"]), CSVColumnSuggestion())
    }

    func testMatchingIsCaseInsensitive() {
        let suggestion = CSVColumnSuggester.suggest(header: ["DATE", "DESCRIPTION", "AMOUNT", "RUNNING BALANCE"])
        XCTAssertEqual(suggestion, CSVColumnSuggestion(dateColumn: 0, descriptionColumn: 1, amountColumn: 2, creditColumn: nil, balanceColumn: 3))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter CSVColumnSuggesterTests`
Expected: FAIL — compile error "cannot find 'CSVColumnSuggester' in scope".

- [ ] **Step 3: Implement**

```swift
// Sources/BudgetCore/Import/CSVColumnSuggester.swift
import Foundation

/// A best-guess CSV column mapping derived from a statement's header row.
public struct CSVColumnSuggestion: Equatable {
    public var dateColumn: Int?
    public var descriptionColumn: Int?
    /// The single signed amount column — or the debit (money out) column when
    /// `creditColumn` is also set.
    public var amountColumn: Int?
    public var creditColumn: Int?
    public var balanceColumn: Int?

    public init(dateColumn: Int? = nil, descriptionColumn: Int? = nil, amountColumn: Int? = nil, creditColumn: Int? = nil, balanceColumn: Int? = nil) {
        self.dateColumn = dateColumn
        self.descriptionColumn = descriptionColumn
        self.amountColumn = amountColumn
        self.creditColumn = creditColumn
        self.balanceColumn = balanceColumn
    }

    public var hasSeparateDebitCredit: Bool { creditColumn != nil }
}

public enum CSVColumnSuggester {
    /// Matches header names case-insensitively. Amount-like headers are classified in a
    /// fixed order (balance, credit, debit, amount) so overlapping words resolve
    /// correctly — e.g. "Debit Amount" is a debit column, not an amount column.
    public static func suggest(header: [String]) -> CSVColumnSuggestion {
        let lowered = header.map { $0.lowercased() }
        var suggestion = CSVColumnSuggestion()
        var debitColumn: Int?
        var creditColumn: Int?
        var amountOnlyColumn: Int?

        for (index, name) in lowered.enumerated() {
            if name.contains("balance") {
                if suggestion.balanceColumn == nil { suggestion.balanceColumn = index }
            } else if ["credit", "paid in", "money in"].contains(where: { name.contains($0) }) {
                if creditColumn == nil { creditColumn = index }
            } else if ["debit", "paid out", "money out", "withdrawal"].contains(where: { name.contains($0) }) {
                if debitColumn == nil { debitColumn = index }
            } else if name.contains("amount") {
                if amountOnlyColumn == nil { amountOnlyColumn = index }
            }
        }

        if let debitColumn, let creditColumn {
            suggestion.amountColumn = debitColumn
            suggestion.creditColumn = creditColumn
        } else if let amountOnlyColumn {
            suggestion.amountColumn = amountOnlyColumn
        }

        let dateIndices = lowered.indices.filter { lowered[$0].contains("date") }
        suggestion.dateColumn = dateIndices.first { lowered[$0].contains("transaction") } ?? dateIndices.first

        for keyword in ["description", "details", "narrative", "payee", "reference"] {
            if let index = lowered.firstIndex(where: { $0.contains(keyword) }) {
                suggestion.descriptionColumn = index
                break
            }
        }
        return suggestion
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter CSVColumnSuggesterTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/BudgetCore/Import/CSVColumnSuggester.swift Tests/BudgetCoreTests/CSVColumnSuggesterTests.swift
git commit -m "Suggest CSV column mapping from header names

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 2: ImportProfile.csvBalanceColumnIndex + migration

**Files:**
- Modify: `Sources/BudgetCore/Models/ImportProfile.swift`, `Sources/BudgetCore/Database/DatabaseManager.swift`
- Test: `Tests/BudgetCoreTests/ImportProfileStoreTests.swift`, `Tests/BudgetCoreTests/DatabaseManagerTests.swift`

**Interfaces:**
- Produces: `ImportProfile.csvBalanceColumnIndex: Int?` and an init parameter `csvBalanceColumnIndex: Int? = nil` placed **after** `csvCreditAmountColumnIndex` and before `csvDateFormat`. Used by Tasks 3 and 6.

- [ ] **Step 1: Write the failing tests**

Add to `ImportProfileStoreTests` (after `testSaveThenFindRoundTripsTheCreditColumnIndex`):

```swift
    func testSaveThenFindRoundTripsTheBalanceColumnIndex() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        var account = Account(name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .manual)
        try manager.dbQueue.write { db in try account.insert(db) }
        let store = ImportProfileStore(dbQueue: manager.dbQueue)

        let profile = ImportProfile(
            accountId: account.id!, format: .csv, csvDelimiter: ",",
            csvDateColumnIndex: 0, csvDescriptionColumnIndex: 4, csvAmountColumnIndex: 5,
            csvCreditAmountColumnIndex: 6, csvBalanceColumnIndex: 7, csvDateFormat: "dd/MM/yyyy"
        )
        try store.save(profile)

        let found = try store.find(accountId: account.id!, format: .csv)
        XCTAssertEqual(found?.csvBalanceColumnIndex, 7)
    }

    func testProfileWithoutBalanceColumnRoundTripsAsNil() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        var account = Account(name: "Lloyds Classic", currency: .gbp, kind: .cash, trackingMode: .manual)
        try manager.dbQueue.write { db in try account.insert(db) }
        let store = ImportProfileStore(dbQueue: manager.dbQueue)
        try store.save(ImportProfile(accountId: account.id!, format: .csv, csvDelimiter: ",", csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2, csvDateFormat: "dd/MM/yyyy"))
        XCTAssertNil(try store.find(accountId: account.id!, format: .csv)?.csvBalanceColumnIndex)
    }
```

Add to `DatabaseManagerTests`:

```swift
    func testImportProfileTableHasBalanceColumn() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let columns = try manager.dbQueue.read { db in try db.columns(in: "importProfile").map(\.name) }
        XCTAssertTrue(columns.contains("csvBalanceColumnIndex"))
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter "ImportProfileStoreTests|DatabaseManagerTests"`
Expected: FAIL — compile error "extra argument 'csvBalanceColumnIndex' in call".

- [ ] **Step 3: Implement**

In `ImportProfile.swift`, add the property after `csvCreditAmountColumnIndex`:

```swift
    /// Optional column holding the statement's running balance *after* each row. When set,
    /// `CSVStatementParser` fills `ParsedTransaction.balanceAfterMinorUnits` and the importer
    /// can record the account's balance from the statement (see `StatementBalanceExtractor`).
    /// `nil` (the default) means no balance column — unchanged for every existing profile.
    public var csvBalanceColumnIndex: Int?
```

Change the initializer signature and body:

```swift
    public init(id: Int64? = nil, accountId: Int64, format: ImportFormat, csvDelimiter: String? = nil, csvDateColumnIndex: Int? = nil, csvDescriptionColumnIndex: Int? = nil, csvAmountColumnIndex: Int? = nil, csvCreditAmountColumnIndex: Int? = nil, csvBalanceColumnIndex: Int? = nil, csvDateFormat: String? = nil, pdfLayoutConfig: String? = nil) {
        // ... existing assignments unchanged ...
        self.csvBalanceColumnIndex = csvBalanceColumnIndex
        // ... remaining assignments unchanged ...
    }
```

Append at the end of the file:

```swift
/// Plain nullable column added via `alter(table:)`, same approach as the credit-column migration.
func registerImportProfileBalanceColumnMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addBalanceColumnIndexToImportProfile") { db in
        try db.alter(table: "importProfile") { t in
            t.add(column: "csvBalanceColumnIndex", .integer)
        }
    }
}
```

In `DatabaseManager.registerMigrations`, add directly after `registerImportProfileCreditColumnMigration(&migrator)`:

```swift
        registerImportProfileBalanceColumnMigration(&migrator)
```

- [ ] **Step 4: Run to verify they pass, then the full suite**

Run: `swift test --filter "ImportProfileStoreTests|DatabaseManagerTests"` → PASS. Then `swift test` → all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/BudgetCore/Models/ImportProfile.swift Sources/BudgetCore/Database/DatabaseManager.swift Tests/BudgetCoreTests/ImportProfileStoreTests.swift Tests/BudgetCoreTests/DatabaseManagerTests.swift
git commit -m "Add optional balance column index to ImportProfile

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Parse the Balance column

**Files:**
- Modify: `Sources/BudgetCore/Import/ParsedTransaction.swift`, `Sources/BudgetCore/Import/CSVStatementParser.swift`
- Test: `Tests/BudgetCoreTests/CSVStatementParserTests.swift`

**Interfaces:**
- Consumes: `ImportProfile.csvBalanceColumnIndex` (Task 2).
- Produces: `ParsedTransaction.balanceAfterMinorUnits: Int?` (init parameter, default `nil`, last position). Used by Task 4.

- [ ] **Step 1: Write the failing tests**

Add to `CSVStatementParserTests`:

```swift
    func testParsesBalanceColumnWhenMapped() {
        let csv = "Date,Description,Amount,Balance\n01/07/2026,SAINSBURYS,-45.64,\"1,954.36\"\n02/07/2026,SALARY,2800.00,4754.36"
        let profile = ImportProfile(
            accountId: 1, format: .csv, csvDelimiter: ",",
            csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2,
            csvBalanceColumnIndex: 3, csvDateFormat: "dd/MM/yyyy"
        )
        let result = CSVStatementParser.parse(csvText: csv, profile: profile)
        XCTAssertEqual(result.transactions.map(\.balanceAfterMinorUnits), [195436, 475436])
    }

    func testParsesNegativeBalance() {
        let csv = "Date,Description,Amount,Balance\n01/07/2026,OVERDRAFT FEE,-5.00,-120.50"
        let profile = ImportProfile(
            accountId: 1, format: .csv, csvDelimiter: ",",
            csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2,
            csvBalanceColumnIndex: 3, csvDateFormat: "dd/MM/yyyy"
        )
        let result = CSVStatementParser.parse(csvText: csv, profile: profile)
        XCTAssertEqual(result.transactions.first?.balanceAfterMinorUnits, -12050)
    }

    // A blank or missing balance cell must never cost the transaction itself.
    func testBlankOrMissingBalanceCellGivesNilWithoutFailingTheRow() {
        let csv = "Date,Description,Amount,Balance\n01/07/2026,SHOP,-10.00,\n02/07/2026,SHOP,-5.00"
        let profile = ImportProfile(
            accountId: 1, format: .csv, csvDelimiter: ",",
            csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2,
            csvBalanceColumnIndex: 3, csvDateFormat: "dd/MM/yyyy"
        )
        let result = CSVStatementParser.parse(csvText: csv, profile: profile)
        XCTAssertEqual(result.transactions.count, 2)
        XCTAssertEqual(result.transactions.map(\.balanceAfterMinorUnits), [nil, nil])
        XCTAssertTrue(result.unparsedLines.isEmpty)
    }

    func testBalanceIsNilWhenNoBalanceColumnIsMapped() {
        let csv = "Date,Description,Amount\n01/07/2026,SAINSBURYS LONDON,-45.64"
        let result = CSVStatementParser.parse(csvText: csv, profile: standardProfile)
        XCTAssertNil(result.transactions.first?.balanceAfterMinorUnits)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter CSVStatementParserTests`
Expected: FAIL — "value of type 'ParsedTransaction' has no member 'balanceAfterMinorUnits'".

- [ ] **Step 3: Implement**

Replace `ParsedTransaction.swift`:

```swift
import Foundation

public struct ParsedTransaction: Equatable {
    public let date: Date
    public let rawDescription: String
    public let amountMinorUnits: Int
    /// The statement's running balance immediately after this row, when the statement has
    /// a Balance column that was mapped and readable. `nil` otherwise (always for PDFs).
    public let balanceAfterMinorUnits: Int?

    public init(date: Date, rawDescription: String, amountMinorUnits: Int, balanceAfterMinorUnits: Int? = nil) {
        self.date = date
        self.rawDescription = rawDescription
        self.amountMinorUnits = amountMinorUnits
        self.balanceAfterMinorUnits = balanceAfterMinorUnits
    }
}
```

In `CSVStatementParser.parse`, add next to the other index lookups:

```swift
        let balanceIndex = profile.csvBalanceColumnIndex
```

and replace the final `transactions.append(...)` in the loop with (the balance index is deliberately **not** added to `requiredIndices`):

```swift
            let balance: Int? = balanceIndex.flatMap { $0 < fields.count ? Money.parseMinorUnits(fields[$0]) : nil }
            transactions.append(ParsedTransaction(date: date, rawDescription: fields[descriptionIndex], amountMinorUnits: minorUnits, balanceAfterMinorUnits: balance))
```

- [ ] **Step 4: Run to verify they pass, then the full suite**

Run: `swift test --filter CSVStatementParserTests` → PASS. Then `swift test` → all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/BudgetCore/Import/ParsedTransaction.swift Sources/BudgetCore/Import/CSVStatementParser.swift Tests/BudgetCoreTests/CSVStatementParserTests.swift
git commit -m "Parse the optional Balance column from CSV statements

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 4: StatementBalanceExtractor

**Files:**
- Create: `Sources/BudgetCore/Import/StatementBalanceExtractor.swift`
- Test: `Tests/BudgetCoreTests/StatementBalanceExtractorTests.swift`

**Interfaces:**
- Consumes: `ParsedTransaction.balanceAfterMinorUnits` (Task 3).
- Produces: `StatementBalancePoint(date:balanceMinorUnits:isClosing:)`, `StatementBalanceResult` (`.notProvided`, `.unverified(String)`, `.available([StatementBalancePoint])`), `StatementBalanceExtractor.extract(from: [ParsedTransaction]) -> StatementBalanceResult`. Used by Task 5.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/BudgetCoreTests/StatementBalanceExtractorTests.swift
import XCTest
@testable import BudgetCore

final class StatementBalanceExtractorTests: XCTestCase {
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func row(_ y: Int, _ m: Int, _ d: Int, _ amount: Int, _ balance: Int?) -> ParsedTransaction {
        ParsedTransaction(date: utc(y, m, d), rawDescription: "X", amountMinorUnits: amount, balanceAfterMinorUnits: balance)
    }

    /// Chronological fixture (pence). Opening balance 100_000.
    /// 15 Jan -1000 → 99_000 · 31 Jan -2000 → 97_000 · 1 Feb RENT -500 → 96_500 ·
    /// 1 Feb REFUND +3000 → 99_500 · 20 Feb -1500 → 98_000 · 2 Mar -250 → 97_750
    private var chronological: [ParsedTransaction] {
        [row(2026, 1, 15, -1000, 99_000), row(2026, 1, 31, -2000, 97_000),
         row(2026, 2, 1, -500, 96_500), row(2026, 2, 1, 3000, 99_500),
         row(2026, 2, 20, -1500, 98_000), row(2026, 3, 2, -250, 97_750)]
    }

    private func points(_ result: StatementBalanceResult, file: StaticString = #filePath, line: UInt = #line) -> [StatementBalancePoint] {
        guard case .available(let points) = result else {
            XCTFail("expected .available, got \(result)", file: file, line: line)
            return []
        }
        return points
    }

    private var expectedPoints: [StatementBalancePoint] {
        [StatementBalancePoint(date: utc(2026, 2, 1), balanceMinorUnits: 99_500, isClosing: false),
         StatementBalancePoint(date: utc(2026, 3, 1), balanceMinorUnits: 98_000, isClosing: false),
         StatementBalancePoint(date: utc(2026, 3, 2), balanceMinorUnits: 97_750, isClosing: true)]
    }

    // The real bank export is newest-first, with several rows per day in reverse order.
    func testNewestFirstFileWithSameDayRowsResolvesOrder() {
        let newestFirst = Array(chronological.reversed())
        XCTAssertEqual(points(StatementBalanceExtractor.extract(from: newestFirst)), expectedPoints)
    }

    func testOldestFirstFileGivesTheSamePoints() {
        XCTAssertEqual(points(StatementBalanceExtractor.extract(from: chronological)), expectedPoints)
    }

    // The 1 Feb point is the balance after BOTH rows dated 1 Feb (the rent and the refund).
    func testBalanceOnTheFirstIncludesThatDaysTransactions() {
        XCTAssertEqual(points(StatementBalanceExtractor.extract(from: chronological)).first?.balanceMinorUnits, 99_500)
    }

    func testQuietFirstOfMonthCarriesThePreviousBalance() {
        let rows = [row(2026, 1, 10, -1000, 99_000), row(2026, 2, 20, -2000, 97_000)]
        XCTAssertEqual(points(StatementBalanceExtractor.extract(from: rows)), [
            StatementBalancePoint(date: utc(2026, 2, 1), balanceMinorUnits: 99_000, isClosing: false),
            StatementBalancePoint(date: utc(2026, 2, 20), balanceMinorUnits: 97_000, isClosing: true)
        ])
    }

    func testLastTransactionOnAFirstYieldsASingleClosingPoint() {
        let rows = [row(2026, 1, 15, -1000, 99_000), row(2026, 2, 1, -500, 98_500)]
        XCTAssertEqual(points(StatementBalanceExtractor.extract(from: rows)), [
            StatementBalancePoint(date: utc(2026, 2, 1), balanceMinorUnits: 98_500, isClosing: true)
        ])
    }

    func testFirstTransactionOnAFirstIncludesThatDate() {
        let rows = [row(2026, 1, 1, -1000, 99_000), row(2026, 1, 15, -500, 98_500)]
        XCTAssertEqual(points(StatementBalanceExtractor.extract(from: rows)), [
            StatementBalancePoint(date: utc(2026, 1, 1), balanceMinorUnits: 99_000, isClosing: false),
            StatementBalancePoint(date: utc(2026, 1, 15), balanceMinorUnits: 98_500, isClosing: true)
        ])
    }

    func testSingleRowFileHasOnlyAClosingPoint() {
        XCTAssertEqual(points(StatementBalanceExtractor.extract(from: [row(2026, 1, 15, -1000, 99_000)])), [
            StatementBalancePoint(date: utc(2026, 1, 15), balanceMinorUnits: 99_000, isClosing: true)
        ])
    }

    func testMonthStartPointsCrossAYearBoundary() {
        let rows = [row(2025, 12, 20, -100, 9_900), row(2026, 1, 5, -100, 9_800)]
        XCTAssertEqual(points(StatementBalanceExtractor.extract(from: rows)), [
            StatementBalancePoint(date: utc(2026, 1, 1), balanceMinorUnits: 9_900, isClosing: false),
            StatementBalancePoint(date: utc(2026, 1, 5), balanceMinorUnits: 9_800, isClosing: true)
        ])
    }

    func testBalancesThatDoNotAddUpAreUnverified() {
        var rows = chronological
        rows[3] = row(2026, 2, 1, 3000, 123_456) // breaks the chain
        guard case .unverified = StatementBalanceExtractor.extract(from: rows) else {
            return XCTFail("expected .unverified")
        }
    }

    func testOneMissingBalanceIsUnverified() {
        var rows = chronological
        rows[2] = row(2026, 2, 1, -500, nil)
        guard case .unverified = StatementBalanceExtractor.extract(from: rows) else {
            return XCTFail("expected .unverified")
        }
    }

    func testNoBalancesAtAllIsNotProvided() {
        let rows = [row(2026, 1, 15, -1000, nil), row(2026, 1, 16, -500, nil)]
        XCTAssertEqual(StatementBalanceExtractor.extract(from: rows), .notProvided)
        XCTAssertEqual(StatementBalanceExtractor.extract(from: []), .notProvided)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter StatementBalanceExtractorTests`
Expected: FAIL — "cannot find 'StatementBalanceExtractor' in scope".

- [ ] **Step 3: Implement**

```swift
// Sources/BudgetCore/Import/StatementBalanceExtractor.swift
import Foundation

/// The balance at the **close** of `date` (UTC midnight of that day). `isClosing` marks
/// the final point (the statement's last transaction date).
public struct StatementBalancePoint: Equatable {
    public let date: Date
    public let balanceMinorUnits: Int
    public let isClosing: Bool

    public init(date: Date, balanceMinorUnits: Int, isClosing: Bool) {
        self.date = date
        self.balanceMinorUnits = balanceMinorUnits
        self.isClosing = isClosing
    }
}

public enum StatementBalanceResult: Equatable {
    /// No row carries a balance (no Balance column mapped, or all cells blank).
    case notProvided
    /// Some rows lack a balance, or no row ordering makes the balances add up. Nothing is
    /// recorded; the string explains why.
    case unverified(String)
    case available([StatementBalancePoint])
}

public enum StatementBalanceExtractor {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Verifies a statement's Balance column and turns it into snapshot points: one for
    /// each 1st of a month between the first and last transaction date (inclusive), plus a
    /// closing point at the last transaction date.
    ///
    /// The order of rows *within a day* isn't knowable from dates alone and varies by bank
    /// (newest-first exports list a day's rows newest-first). Two candidate chronological
    /// orders are tried — rows stably date-sorted as given, and reversed-then-stably-sorted
    /// — and a candidate is accepted only if `balance[i-1] + amount[i] == balance[i]`
    /// holds for every consecutive pair. If neither does, nothing is recorded.
    public static func extract(from rows: [ParsedTransaction]) -> StatementBalanceResult {
        guard rows.contains(where: { $0.balanceAfterMinorUnits != nil }) else { return .notProvided }
        guard rows.allSatisfy({ $0.balanceAfterMinorUnits != nil }) else {
            return .unverified("Some rows have no readable balance, so the statement's balances can't be used.")
        }
        let candidates = [chronological(rows), chronological(Array(rows.reversed()))]
        guard let ordered = candidates.first(where: isConsistent) else {
            return .unverified("The Balance column doesn't add up with the transaction amounts, so it wasn't used.")
        }

        let firstDate = ordered.first!.date
        let lastDate = ordered.last!.date
        var points: [StatementBalancePoint] = []
        var cursor = firstOfMonth(onOrAfter: firstDate)
        while cursor <= lastDate {
            if let row = ordered.last(where: { $0.date <= cursor }) {
                points.append(StatementBalancePoint(date: cursor, balanceMinorUnits: row.balanceAfterMinorUnits!, isClosing: cursor == lastDate))
            }
            cursor = calendar.date(byAdding: .month, value: 1, to: cursor)!
        }
        if points.last?.date != lastDate {
            points.append(StatementBalancePoint(date: lastDate, balanceMinorUnits: ordered.last!.balanceAfterMinorUnits!, isClosing: true))
        }
        return .available(points)
    }

    /// Stable sort by date: rows with equal dates keep their incoming relative order.
    private static func chronological(_ rows: [ParsedTransaction]) -> [ParsedTransaction] {
        rows.enumerated()
            .sorted { lhs, rhs in
                lhs.element.date != rhs.element.date ? lhs.element.date < rhs.element.date : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func isConsistent(_ ordered: [ParsedTransaction]) -> Bool {
        zip(ordered, ordered.dropFirst()).allSatisfy { previous, next in
            previous.balanceAfterMinorUnits! + next.amountMinorUnits == next.balanceAfterMinorUnits!
        }
    }

    private static func firstOfMonth(onOrAfter date: Date) -> Date {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
        return start >= date ? start : calendar.date(byAdding: .month, value: 1, to: start)!
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter StatementBalanceExtractorTests`
Expected: PASS (11 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/BudgetCore/Import/StatementBalanceExtractor.swift Tests/BudgetCoreTests/StatementBalanceExtractorTests.swift
git commit -m "Verify statement balances and derive month-start and closing snapshot points

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 5: ImportCoordinator — attach balances at staging, record on demand

**Files:**
- Modify: `Sources/BudgetCore/Import/ImportCoordinator.swift`
- Test: `Tests/BudgetCoreTests/ImportCoordinatorTests.swift`

**Interfaces:**
- Consumes: `StatementBalanceExtractor`, `StatementBalanceResult`, `StatementBalancePoint` (Task 4); `ImportProfile.csvBalanceColumnIndex` (Task 2).
- Produces: `StagedImport.statementBalances: StatementBalanceResult` (init parameter, default `.notProvided`, last position); `StatementBalanceRecording(added: Int, updated: Int)`; `ImportCoordinator.recordStatementBalances(accountId: Int64, sourceFileName: String, points: [StatementBalancePoint]) throws -> StatementBalanceRecording`. Used by Task 7.

- [ ] **Step 1: Write the failing tests**

Add to `ImportCoordinatorTests`:

```swift
    private func utcDate(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func balanceProfile(accountId: Int64) -> ImportProfile {
        ImportProfile(accountId: accountId, format: .csv, csvDelimiter: ",", csvDateColumnIndex: 0, csvDescriptionColumnIndex: 1, csvAmountColumnIndex: 2, csvBalanceColumnIndex: 3, csvDateFormat: "dd/MM/yyyy")
    }

    // Newest-first, with two rows on 1 Feb (REFUND listed before RENT, as a bank would).
    private let newestFirstCSV = """
    Date,Description,Amount,Balance
    02/03/2026,SHOP C,-2.50,977.50
    20/02/2026,SHOP B,-15.00,980.00
    01/02/2026,REFUND,30.00,995.00
    01/02/2026,RENT,-5.00,965.00
    31/01/2026,SHOP A,-20.00,970.00
    15/01/2026,SHOP 0,-10.00,990.00
    """

    func testStagingAttachesVerifiedStatementBalances() async throws {
        let (manager, account, _) = try makeSeededManager()
        let coordinator = ImportCoordinator(dbQueue: manager.dbQueue, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        let staged = try await coordinator.stageCSVImport(csvText: newestFirstCSV, profile: balanceProfile(accountId: account.id!), accountId: account.id!)
        XCTAssertEqual(staged.statementBalances, .available([
            StatementBalancePoint(date: utcDate(2026, 2, 1), balanceMinorUnits: 99_500, isClosing: false),
            StatementBalancePoint(date: utcDate(2026, 3, 1), balanceMinorUnits: 98_000, isClosing: false),
            StatementBalancePoint(date: utcDate(2026, 3, 2), balanceMinorUnits: 97_750, isClosing: true)
        ]))
    }

    func testStatementBalancesAreNotProvidedWithoutABalanceColumn() async throws {
        let (manager, account, profile) = try makeSeededManager()
        let coordinator = ImportCoordinator(dbQueue: manager.dbQueue, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        let staged = try await coordinator.stageCSVImport(csvText: "Date,Description,Amount\n01/07/2026,SHOP,-10.00", profile: profile, accountId: account.id!)
        XCTAssertEqual(staged.statementBalances, .notProvided)
    }

    // Balances are a fact about the whole file, so a re-stage whose every row is already
    // imported (all duplicates) still carries them.
    func testRestagingAnAlreadyImportedFileStillCarriesBalances() async throws {
        let (manager, account, _) = try makeSeededManager()
        let coordinator = ImportCoordinator(dbQueue: manager.dbQueue, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        let profile = balanceProfile(accountId: account.id!)
        let first = try await coordinator.stageCSVImport(csvText: newestFirstCSV, profile: profile, accountId: account.id!)
        try coordinator.commit(accountId: account.id!, sourceFileName: "a.csv", staged: first.staged, decisions: [])
        let second = try await coordinator.stageCSVImport(csvText: newestFirstCSV, profile: profile, accountId: account.id!)
        XCTAssertEqual(second.staged.count, 0)
        XCTAssertEqual(second.duplicateCount, 6)
        XCTAssertEqual(second.statementBalances, first.statementBalances)
    }

    func testRecordStatementBalancesInsertsThenIsIdempotent() throws {
        let (manager, account, _) = try makeSeededManager()
        let coordinator = ImportCoordinator(dbQueue: manager.dbQueue, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        let points = [
            StatementBalancePoint(date: utcDate(2026, 3, 1), balanceMinorUnits: 98_000, isClosing: false),
            StatementBalancePoint(date: utcDate(2026, 3, 2), balanceMinorUnits: 97_750, isClosing: true)
        ]
        let first = try coordinator.recordStatementBalances(accountId: account.id!, sourceFileName: "a.csv", points: points)
        XCTAssertEqual(first, StatementBalanceRecording(added: 2, updated: 0))
        let second = try coordinator.recordStatementBalances(accountId: account.id!, sourceFileName: "a.csv", points: points)
        XCTAssertEqual(second, StatementBalanceRecording(added: 0, updated: 2))

        let snapshots = try manager.dbQueue.read { db in try BalanceSnapshot.order(Column("date")).fetchAll(db) }
        XCTAssertEqual(snapshots.map(\.balanceMinorUnits), [98_000, 97_750])
        XCTAssertEqual(snapshots.first?.note, "Statement balance — a.csv")
    }

    func testRecordStatementBalancesReplacesSameDateSnapshotButNotATypedOne() throws {
        let (manager, account, _) = try makeSeededManager()
        let coordinator = ImportCoordinator(dbQueue: manager.dbQueue, categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        try manager.dbQueue.write { db in
            var sameDate = BalanceSnapshot(accountId: account.id!, date: utcDate(2026, 3, 1), balanceMinorUnits: 1, note: "old")
            try sameDate.insert(db)
            // A typed snapshot carries a time of day, so it never matches a statement date.
            var typed = BalanceSnapshot(accountId: account.id!, date: utcDate(2026, 3, 1, hour: 9), balanceMinorUnits: 2, note: "typed")
            try typed.insert(db)
        }
        let result = try coordinator.recordStatementBalances(
            accountId: account.id!, sourceFileName: "a.csv",
            points: [StatementBalancePoint(date: utcDate(2026, 3, 1), balanceMinorUnits: 98_000, isClosing: false)]
        )
        XCTAssertEqual(result, StatementBalanceRecording(added: 0, updated: 1))
        let snapshots = try manager.dbQueue.read { db in try BalanceSnapshot.order(Column("date")).fetchAll(db) }
        XCTAssertEqual(snapshots.map(\.balanceMinorUnits), [98_000, 2])
        XCTAssertEqual(snapshots.last?.note, "typed")
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter ImportCoordinatorTests`
Expected: FAIL — "value of type 'StagedImport' has no member 'statementBalances'".

- [ ] **Step 3: Implement**

In `StagedImport`, add the property and init parameter:

```swift
    /// Verified Balance-column result for the whole file (including rows later skipped as
    /// duplicates). `.notProvided` for PDFs and for CSV profiles without a balance column.
    public let statementBalances: StatementBalanceResult

    public init(staged: [StagedTransaction], duplicates: [ParsedTransaction], unparsedLines: [String], statementBalances: StatementBalanceResult = .notProvided) {
        self.staged = staged
        self.duplicates = duplicates
        self.unparsedLines = unparsedLines
        self.statementBalances = statementBalances
    }
```

(Delete the old 3-parameter `init`; keep the existing properties and `duplicateCount`.)

Add near `ImportDecision`:

```swift
public struct StatementBalanceRecording: Equatable {
    public let added: Int
    public let updated: Int

    public init(added: Int, updated: Int) {
        self.added = added
        self.updated = updated
    }
}
```

Replace `stageCSVImport`:

```swift
    public func stageCSVImport(csvText: String, profile: ImportProfile, accountId: Int64, onProgress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> StagedImport {
        let parseResult = CSVStatementParser.parse(csvText: csvText, profile: profile)
        let staged = try await stage(parsed: parseResult.transactions, unparsedLines: parseResult.unparsedLines, accountId: accountId, onProgress: onProgress)
        return StagedImport(
            staged: staged.staged, duplicates: staged.duplicates, unparsedLines: staged.unparsedLines,
            statementBalances: StatementBalanceExtractor.extract(from: parseResult.transactions)
        )
    }
```

Add after `commit`:

```swift
    /// Records statement-derived balances as `BalanceSnapshot`s, upserting by exact
    /// `(accountId, date)`: a snapshot already on that date is updated, otherwise one is
    /// inserted. Re-recording the same points is therefore idempotent. A snapshot typed on
    /// the Net Worth screen carries a time of day, so it never matches a statement date
    /// (UTC midnight) and is never overwritten.
    public func recordStatementBalances(accountId: Int64, sourceFileName: String, points: [StatementBalancePoint]) throws -> StatementBalanceRecording {
        let note = "Statement balance — \(sourceFileName)"
        return try dbQueue.write { db in
            var added = 0
            var updated = 0
            for point in points {
                if var existing = try BalanceSnapshot
                    .filter(Column("accountId") == accountId && Column("date") == point.date)
                    .fetchOne(db) {
                    existing.balanceMinorUnits = point.balanceMinorUnits
                    existing.note = note
                    try existing.update(db)
                    updated += 1
                } else {
                    var snapshot = BalanceSnapshot(accountId: accountId, date: point.date, balanceMinorUnits: point.balanceMinorUnits, note: note)
                    try snapshot.insert(db)
                    added += 1
                }
            }
            return StatementBalanceRecording(added: added, updated: updated)
        }
    }
```

- [ ] **Step 4: Run to verify they pass, then the full suite**

Run: `swift test --filter ImportCoordinatorTests` → PASS. Then `swift test` → all green (including `ImportCoordinatorPDFTests`, which use `StagedImport` without the new parameter).

- [ ] **Step 5: Commit**

```bash
git add Sources/BudgetCore/Import/ImportCoordinator.swift Tests/BudgetCoreTests/ImportCoordinatorTests.swift
git commit -m "Attach verified statement balances at staging and record them as snapshots

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 6: CSV mapping wizard — suggestions and Balance picker

**Files:**
- Modify: `App/Import/CSVMappingWizardView.swift`

**Interfaces:**
- Consumes: `CSVColumnSuggester.suggest(header:)` (Task 1), `ImportProfile.csvBalanceColumnIndex` (Task 2).
- Produces: the wizard saves `csvBalanceColumnIndex`; call sites (`ImportView`) are unchanged — the initializer keeps the same labels `account:sampleHeaderRow:onSave:`.

- [ ] **Step 1: Replace the view**

```swift
// App/Import/CSVMappingWizardView.swift
import SwiftUI
import BudgetCore

struct CSVMappingWizardView: View {
    let account: Account
    let sampleHeaderRow: [String]
    let onSave: (ImportProfile) -> Void

    @State private var dateColumn: Int
    @State private var descriptionColumn: Int
    @State private var amountColumn: Int
    @State private var hasSeparateCreditColumn: Bool
    @State private var creditColumn: Int
    @State private var balanceColumn: Int?
    @State private var dateFormat = "dd/MM/yyyy"

    /// Pre-selects columns from the header names (`CSVColumnSuggester`); anything it
    /// can't recognise falls back to the old positional defaults (0, 1, 2, 3), clamped to
    /// the header's width.
    init(account: Account, sampleHeaderRow: [String], onSave: @escaping (ImportProfile) -> Void) {
        self.account = account
        self.sampleHeaderRow = sampleHeaderRow
        self.onSave = onSave
        let suggestion = CSVColumnSuggester.suggest(header: sampleHeaderRow)
        let lastIndex = max(sampleHeaderRow.count - 1, 0)
        _dateColumn = State(initialValue: suggestion.dateColumn ?? min(0, lastIndex))
        _descriptionColumn = State(initialValue: suggestion.descriptionColumn ?? min(1, lastIndex))
        _amountColumn = State(initialValue: suggestion.amountColumn ?? min(2, lastIndex))
        _hasSeparateCreditColumn = State(initialValue: suggestion.hasSeparateDebitCredit)
        _creditColumn = State(initialValue: suggestion.creditColumn ?? min(3, lastIndex))
        _balanceColumn = State(initialValue: suggestion.balanceColumn)
    }

    var body: some View {
        Form {
            Picker("Date column", selection: $dateColumn) {
                ForEach(sampleHeaderRow.indices, id: \.self) { i in Text(sampleHeaderRow[i]).tag(i) }
            }
            Picker("Description column", selection: $descriptionColumn) {
                ForEach(sampleHeaderRow.indices, id: \.self) { i in Text(sampleHeaderRow[i]).tag(i) }
            }
            Toggle("This statement splits amounts into separate debit/credit columns", isOn: $hasSeparateCreditColumn)
            Picker(hasSeparateCreditColumn ? "Debit column" : "Amount column", selection: $amountColumn) {
                ForEach(sampleHeaderRow.indices, id: \.self) { i in Text(sampleHeaderRow[i]).tag(i) }
            }
            if hasSeparateCreditColumn {
                Picker("Credit column", selection: $creditColumn) {
                    ForEach(sampleHeaderRow.indices, id: \.self) { i in Text(sampleHeaderRow[i]).tag(i) }
                }
            }
            if account.kind != .credit {
                Picker("Balance column", selection: $balanceColumn) {
                    Text("None").tag(Int?.none)
                    ForEach(sampleHeaderRow.indices, id: \.self) { i in Text(sampleHeaderRow[i]).tag(Int?.some(i)) }
                }
                Text("With a Balance column the importer can record this account's balance from the statement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("Date format (e.g. dd/MM/yyyy)", text: $dateFormat)
            Button("Save mapping") {
                let profile = ImportProfile(
                    accountId: account.id!, format: .csv, csvDelimiter: ",",
                    csvDateColumnIndex: dateColumn, csvDescriptionColumnIndex: descriptionColumn,
                    csvAmountColumnIndex: amountColumn,
                    csvCreditAmountColumnIndex: hasSeparateCreditColumn ? creditColumn : nil,
                    csvBalanceColumnIndex: account.kind == .credit ? nil : balanceColumn,
                    csvDateFormat: dateFormat
                )
                onSave(profile)
            }
        }
        .padding()
        .frame(width: 440)
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/Import/CSVMappingWizardView.swift
git commit -m "Pre-select CSV columns from the header and add a Balance column picker

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 7: ImportViewModel + ReviewView — record balances on first commit

**Files:**
- Modify: `App/Import/ImportViewModel.swift`, `App/Import/ReviewView.swift`

**Interfaces:**
- Consumes: `StagedImport.statementBalances`, `ImportCoordinator.recordStatementBalances`, `StatementBalanceRecording` (Task 5).
- Produces: `ImportViewModel.statementBalances`, `.recordStatementBalancesOnConfirm`, `.statementBalancesRecorded`, `.statementBalanceSummary`, `recordStatementBalancesNow()`.

- [ ] **Step 1: Edit `ImportViewModel`**

Add these published properties next to `stagingProgress`:

```swift
    /// Verified Balance-column result for the file under review. `.notProvided` for PDFs,
    /// credit-card accounts, and files without a mapped Balance column.
    @Published private(set) var statementBalances: StatementBalanceResult = .notProvided
    /// When on, the statement balances are recorded once, on the first successful commit.
    @Published var recordStatementBalancesOnConfirm = true
    /// Set once the balances for the current review have been recorded.
    @Published private(set) var statementBalancesRecorded: StatementBalanceRecording?
```

Add next to `lastAccountId`:

```swift
    private var lastAccountCurrency: Currency = .gbp

    private static let utcDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()
```

Change `apply` to take the account and set the new state — update both call sites (`stageCSV`: `apply(result, sourceFileName: fileURL.lastPathComponent, account: account)`; `stagePDF`: `apply(result, sourceFileName: sourceFileName, account: account)`) and the method itself:

```swift
    private func apply(_ result: StagedImport, sourceFileName: String, account: Account) {
        lastSourceFileName = sourceFileName
        lastAccountId = account.id ?? 0
        lastAccountCurrency = account.currency
        // Credit-card statements show balances with bank-specific sign conventions, so the
        // feature is off for them (see the spec's non-goals).
        statementBalances = account.kind == .credit ? .notProvided : result.statementBalances
        statementBalancesRecorded = nil
        recordStatementBalancesOnConfirm = true
        stagedRows = result.staged.map { ReviewRow(staged: $0, chosenCategoryId: $0.suggestedCategoryId) }
        duplicates = result.duplicates
        unparsedLines = result.unparsedLines
        isReviewing = true
        if result.staged.isEmpty && result.duplicates.isEmpty && result.unparsedLines.isEmpty {
            isReviewing = false
            fail("No transactions were found in \(sourceFileName).")
        }
    }
```

Add these members (before `cancel()`):

```swift
    /// "8 balances from the statement, closing £27,596.28 on 29 Sep 2026" — `nil` unless
    /// there is a verified result.
    var statementBalanceSummary: String? {
        guard case .available(let points) = statementBalances, let closing = points.last else { return nil }
        let day = Self.utcDayFormatter.string(from: closing.date)
        return "\(points.count) balances from the statement, closing \(Money.format(closing.balanceMinorUnits, currency: lastAccountCurrency)) on \(day)"
    }

    /// Records the verified balances now (the panel's "Record now" button). A no-op when
    /// there is nothing to record or it was already recorded.
    @discardableResult
    func recordStatementBalancesNow() -> Bool {
        recordStatementBalances(failurePrefix: "Couldn't save the statement balances")
    }

    /// Called after every successful commit. Records at most once per review, and only if
    /// the user left the toggle on. Returns a short note for the status line when it
    /// recorded something. A failure here never undoes the commit that already succeeded.
    private func recordBalancesAfterCommitIfWanted() -> String? {
        guard recordStatementBalancesOnConfirm, statementBalancesRecorded == nil, case .available = statementBalances else { return nil }
        guard recordStatementBalances(failurePrefix: "Transactions were confirmed, but the statement balances couldn't be saved"),
              let recorded = statementBalancesRecorded else { return nil }
        return "Recorded \(recorded.added + recorded.updated) balance snapshot(s)."
    }

    private func recordStatementBalances(failurePrefix: String) -> Bool {
        guard statementBalancesRecorded == nil, case .available(let points) = statementBalances else { return true }
        do {
            statementBalancesRecorded = try coordinator.recordStatementBalances(accountId: lastAccountId, sourceFileName: lastSourceFileName, points: points)
            return true
        } catch {
            fail("\(failurePrefix): \(error.localizedDescription)")
            return false
        }
    }
```

In `confirmReady`, `confirmRow` and `saveRemainingAsUncategorized`, call `recordBalancesAfterCommitIfWanted()` right after the commit succeeds and the rows are removed, and fold its note into the status line where one exists. Concretely:

```swift
        // confirmReady — replace the statusMessage line with:
        let recordedNote = recordBalancesAfterCommitIfWanted()
        statusMessage = "Confirmed \(ready.count) transaction(s)." + (recordedNote.map { " " + $0 } ?? "")

        // confirmRow — after `stagedRows.removeAll { $0.id == row.id }`:
        _ = recordBalancesAfterCommitIfWanted()

        // saveRemainingAsUncategorized — replace the statusMessage line with:
        let recordedNote = recordBalancesAfterCommitIfWanted()
        statusMessage = "Saved \(remaining.count) transaction(s) — assign categories from Uncategorized." + (recordedNote.map { " " + $0 } ?? "")
```

Reset in `reset()`:

```swift
        statementBalances = .notProvided
        statementBalancesRecorded = nil
```

- [ ] **Step 2: Add the panel to `ReviewView`**

Insert `statementBalancesPanel` as the first child of the top-level `VStack` in `body` (above the unparsed-lines `GroupBox`), and add this property to the view:

```swift
    @ViewBuilder
    private var statementBalancesPanel: some View {
        switch viewModel.statementBalances {
        case .notProvided:
            EmptyView()
        case .unverified(let reason):
            GroupBox {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Statement balances")
            }
        case .available:
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    if let recorded = viewModel.statementBalancesRecorded {
                        Label("Recorded \(recorded.added + recorded.updated) balance snapshot(s)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        if let summary = viewModel.statementBalanceSummary { Text(summary) }
                        Toggle("Record them when I confirm", isOn: $viewModel.recordStatementBalancesOnConfirm)
                        HStack {
                            Button("Record now") { viewModel.recordStatementBalancesNow() }
                            Text("Snapshots on the same dates are replaced.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Statement balances", systemImage: "banknote")
            }
        }
    }
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add App/Import/ImportViewModel.swift App/Import/ReviewView.swift
git commit -m "Record statement balances on first commit and show them in the review screen

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Database path override + live verification on a copy

**Files:**
- Modify: `App/AppEnvironment.swift`

**Interfaces:**
- Produces: optional `BUDGET_DB_PATH` environment override (used here and by the dashboard plan's verification).

- [ ] **Step 1: Add the override**

In `AppEnvironment.init`, replace the three lines that build `appSupport`, create the directory and compute `dbPath` with:

```swift
        let dbPath: String
        if let override = ProcessInfo.processInfo.environment["BUDGET_DB_PATH"], !override.isEmpty {
            // Lets the app run against a copy of the database for safe manual testing.
            dbPath = override
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Budget", isDirectory: true)
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            dbPath = appSupport.appendingPathComponent("budget.sqlite").path
        }
```

- [ ] **Step 2: Build and commit**

Run: `xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' build 2>&1 | tail -5` → `** BUILD SUCCEEDED **`.

```bash
git add App/AppEnvironment.swift
git commit -m "Allow overriding the database path via BUDGET_DB_PATH for safe testing

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 3: Prepare a copy of the live database (read-only on the original)**

```bash
SCRATCH="$(mktemp -d)"   # use your session scratchpad directory if one is provided
sqlite3 -readonly "$HOME/Library/Application Support/Budget/budget.sqlite" ".backup '$SCRATCH/budget-copy.sqlite'"
# The import picker only lists .imported accounts until the dashboard plan lands; flip it in the COPY only.
sqlite3 "$SCRATCH/budget-copy.sqlite" "update account set trackingMode='imported' where name='Lloyds Classic'; select id,name,trackingMode from account;"
echo "$SCRATCH"
```

- [ ] **Step 4: Launch against the copy**

Quit any running Budget app first. Then, with the `.app` path from the Task 7 build output:

```bash
BUDGET_DB_PATH="$SCRATCH/budget-copy.sqlite" "<DerivedData path>/Build/Products/Debug/Budget.app/Contents/MacOS/Budget" &
```

(If the app opens the real database instead, stop and fix the override — do not continue.)

- [ ] **Step 5: Walk the import**

In the app: Import → Import into "Lloyds Classic" → *Import CSV statement…* → choose `~/Downloads/44116660_20264430_1009.csv`.
Expected:
1. The mapping wizard pre-selects Date = Transaction Date, Description = Transaction Description, the debit/credit toggle **on** with Debit = Debit Amount and Credit = Credit Amount, Balance = Balance. Save mapping.
2. Staging runs (several minutes of on-device categorization is normal; the progress bar advances).
3. The review screen shows **Statement balances — "8 balances from the statement, closing £27,596.28 on 29 Sep 2026"**, toggle on.
4. Click *Confirm N ready* (or *Save remaining as Uncategorized*). The panel changes to "Recorded 8 balance snapshot(s)" and the status line mentions it.

- [ ] **Step 6: Verify the stored snapshots**

```bash
sqlite3 "$SCRATCH/budget-copy.sqlite" "select date(date), balanceMinorUnits/100.0, note from balanceSnapshot where note like 'Statement balance%' order by date;"
```

Expected exactly these 8 rows (note: `Statement balance — 44116660_20264430_1009.csv`):

```
2026-03-01|41419.46
2026-04-01|38183.15
2026-05-01|36447.01
2026-06-01|35836.84
2026-07-01|34099.72
2026-08-01|31522.99
2026-09-01|27926.43
2026-09-29|27596.28
```

Also open **Net Worth** in the app: Lloyds Classic shows £27,596.28.

- [ ] **Step 7: Idempotency and cleanup**

Re-import the same file (all rows now duplicates): the review shows the panel again; click *Record now* → "Recorded 8 balance snapshot(s)"; re-run the Step 6 query — still exactly 8 rows. Then quit the app and delete the scratch copy:

```bash
rm -rf "$SCRATCH"
```

Finally run the full suite once more: `swift test` → all green. No commit is needed for Steps 3–7 (nothing in the repo changed).
