# CSV Import Mapping + Grid/Forecast UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the CSV mapping form with a column-menu table + live check + result preview, and enlarge grid click targets / respace the Forecast screen per Apple HIG.

**Architecture:** BudgetCore gains `CSVDateFormatDetector`, `CSVColumnMapping` and `ImportProfile.csvNegateAmounts` (migration + parser), all XCTest-covered; the sheet and the grid/Forecast changes are SwiftUI.

**Tech Stack:** Swift 6 / SwiftUI (macOS 26), GRDB 6.29, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-08-import-mapping-and-grid-ux-design.md` — read it before any task.

## Global Constraints

- Tests: XCTest, in-memory DB. `swift test --scratch-path /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/build-im`. App: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' -derivedDataPath /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/dd-im build 2>&1 | tail -5`. Never both at once.
- Migrations appended last in DatabaseManager; existing profiles keep working unchanged (`csvNegateAmounts` default false).
- Horizontal grid scrolling must stay smooth: scroll offset observed only by `HorizontalOffsetFollower`, widths only by `BodyWidthFollower`; sizes from `GridMetrics`.
- Commit per task with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push. Never touch `~/Library/Application Support/Budget`.

---

### Task 1: BudgetCore — date format detection, column mapping, flip sign

**Files:** create `Sources/BudgetCore/Import/CSVDateFormatDetector.swift`, `Sources/BudgetCore/Import/CSVColumnMapping.swift`; modify `Sources/BudgetCore/Models/ImportProfile.swift` (+ migration `addCSVNegateAmounts` in DatabaseManager, appended last), `Sources/BudgetCore/Import/CSVStatementParser.swift`; tests `CSVDateFormatDetectorTests.swift`, `CSVColumnMappingTests.swift`, additions to `CSVStatementParserTests.swift` and `DatabaseManagerTests.swift`.

**Produces:**
```swift
public enum CSVDateFormatDetector {
    public static let knownFormats: [String] // the spec's list, in preference order
    /// Formats that parse every non-blank value, in `knownFormats` order (day-first before month-first).
    public static func candidates(values: [String]) -> [String]
}
public enum CSVColumnRole: String, CaseIterable, Sendable { case date, description, amount, moneyOut, moneyIn, balance, ignore }
public struct CSVColumnMapping: Equatable, Sendable {
    public private(set) var roles: [CSVColumnRole] // one per column
    public init(columnCount: Int)
    public init(columnCount: Int, suggestion: CSVColumnSuggestion)
    public init(columnCount: Int, profile: ImportProfile)
    /// Applies the spec's exclusivity rules (one column per role; amount vs moneyOut/moneyIn).
    public mutating func assign(_ role: CSVColumnRole, toColumn index: Int)
    public var missingRoles: [CSVColumnRole] // e.g. [.date, .description] or [.moneyIn] when only moneyOut set; [.amount] when no amount at all
    public func profile(accountId: Int64, dateFormat: String, negateAmounts: Bool, allowBalance: Bool) -> ImportProfile?  // nil while missingRoles is non-empty
}
// ImportProfile: public var csvNegateAmounts: Bool (default false)
```
- [ ] Tests first: detector — ["01/10/2026","30/09/2026"] → first is "dd/MM/yyyy" and "MM/dd/yyyy" absent; ["01/02/2026","03/04/2026"] (ambiguous) → "dd/MM/yyyy" before "MM/dd/yyyy"; ["2026-10-01"] → ["yyyy-MM-dd"]; ["1 Oct 2026"] contains "d MMM yyyy"; ["hello"] → []; blanks ignored. Mapping — assigning .date to col 2 when col 0 has .date leaves col 0 .ignore; assigning .amount clears moneyOut/moneyIn and vice versa; missing roles cases; profile round trip (single amount + negate; debit/credit split → csvAmountColumnIndex = moneyOut, csvCreditAmountColumnIndex = moneyIn; balance dropped when allowBalance false); init from profile reproduces roles. Parser — csvNegateAmounts true flips a single-column amount, leaves split columns unchanged. Migration — column exists, default false for existing rows.
- [ ] Implement; full suite + app build; commit "CSV mapping model: date format detection, column roles, flip sign".

### Task 2: CSV mapping sheet

**Files:** rewrite `App/Import/CSVMappingWizardView.swift` (split into focused views if large, e.g. `CSVMappingTable.swift`, `CSVMappingPreview.swift`); modify `App/Import/ImportFlowHost.swift` / `ImportView.swift` / `ImportViewModel.swift` to pass the CSV text (header + rows) and an optional existing profile, and add "Edit column mapping…" for an account with a CSV profile.

**Consumes:** Task 1 APIs; `CSVRowSplitter.split`, `CSVStatementParser.parse/splitLines`, `CSVColumnSuggester.suggest`, `MoneyText`/`Money.format`.

- [ ] Build the sheet per spec section 1 (layout, menus above headers with accent tint for mapped, ignored cells secondary, options row with date-format menu + Custom… field + Flip sign toggle (amount only) + live check with "Show" disclosure of up to 10 unreadable lines, "Still needed: …" when roles missing, result preview of 8 parsed transactions, Cancel / Save mapping with inline missing-roles message).
- [ ] Recompute check and preview off the main thread or cheaply (debounce not required for typical statement sizes, but don't re-split the file per cell render — split once on init).
- [ ] Prefill from an existing profile when editing; save replaces the account's profile via the existing profile store.
- [ ] Full suite + app build; commit "CSV import: column-menu mapping with live check and result preview".

### Task 3: Grid click targets

**Files:** `App/Budget/BudgetGridView.swift`, `App/Forecast/ScenarioGridTab.swift`, `App/DesignSystem/PlanCellView.swift` (if the tap frame lives there).

- [ ] Group rows: the whole name cell (full category-column width and row height) toggles expand/collapse, with `.contentShape(Rectangle())` and a hover highlight (`onHover` → subtle fill).
- [ ] Every month cell, Year Total, multi-year year column and reserve cell: the tap target is the full cell frame (`GridMetrics.columnWidth` × row height, `.contentShape(Rectangle())` applied after the frame) in both grids; behaviour unchanged (details / add on empty / edit).
- [ ] Don't add scroll-offset observation. Full suite + app build; commit "Grids: whole-cell click targets and clickable group names".

### Task 4: Forecast spacing (Apple HIG)

**Files:** `App/Forecast/ScenarioLabView.swift`, `ScenarioChips.swift`, `CompareTab.swift`, `DifferencesTab.swift`, `ScenarioGridTab.swift`; `App/ContentView.swift` only if toolbar items must be hosted there.

- [ ] Move the tab segmented control to `.toolbar { ToolbarItem(placement: .principal) }` and the Horizon picker to a trailing toolbar item, present only while the Forecast screen is shown (no duplicates when switching screens).
- [ ] 20pt content margins; chip row with leading secondary "Scenarios" label; divider + 16pt before tab content; Grid "Editing" bar 12pt above/below; Differences action buttons on their own row below the chips; Compare 16pt between chips, chart and summary.
- [ ] Full suite + app build; commit "Forecast: toolbar tabs and HIG spacing".

### Task 5: Final review, merge (controller)

- [ ] Final whole-branch review, one fix wave, merge to main, `xcodegen generate` + xcodebuild in the main checkout, push.
