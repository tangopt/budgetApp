# Accounts Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Net Worth and Accounts screens with one Accounts screen (Overview section): net worth header, accounts grouped by kind, a detail panel for the selected account, bulk balance updates, account editing and an opening balance on add.

**Architecture:** All rules (overview figures, staleness, edit rules, saving balances) live in BudgetCore with tests; the app adds one view model, one screen and four sheets, and rewires navigation.

**Tech Stack:** Swift 6 / SwiftUI + Swift Charts (macOS 26), GRDB 6.29, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-05-accounts-screen-design.md` — read it before any task. Mockup decisions are summarised there.

## Global Constraints

- Balances are signed `Int` minor units; credit owed is negative. The UI enters/shows credit balances as a positive "amount owed" via `NetWorthCalculator.signedSnapshotBalance` / `enteredBalance`.
- Snapshot dates from date pickers: the picked local calendar day → that day 00:00 UTC via `PayCalendar.utcDay(sameDayAs:in:)`; default today.
- Stale rule: `.imported` accounts are never stale; others are stale when they have no snapshot or the latest is more than 45 days before today (start of day, UTC) — one implementation, `BalanceStaleness`, also used by `DashboardCalculator.attentionItems`.
- Kind change to/from `.credit` is refused when the account has any snapshot or transaction; currency never changes after creation.
- Account names: trimmed, non-empty, unique.
- Tests: XCTest in `Tests/BudgetCoreTests/`; in-memory DB `let m = try DatabaseManager(path: nil); try m.migrate()`. Run `swift test --scratch-path /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/build-acc` (`--filter X` while iterating). App: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' -derivedDataPath /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/dd-acc build 2>&1 | tail -5`. Never both at once.
- Commit after each task (author's Co-Authored-By line). Never push. Never touch `~/Library/Application Support/Budget`.

---

### Task 1: BudgetCore — overview, staleness, editing, saving balances

**Files:**
- Create: `Sources/BudgetCore/NetWorth/AccountsOverview.swift`, `Sources/BudgetCore/NetWorth/AccountEditing.swift`
- Modify: `Sources/BudgetCore/Dashboard/DashboardCalculator.swift` (attentionItems uses `BalanceStaleness`)
- Test: `Tests/BudgetCoreTests/AccountsOverviewTests.swift`, `Tests/BudgetCoreTests/AccountEditingTests.swift`

**Interfaces — Produces:**

```swift
public enum BalanceStaleness {
    public static let thresholdDays = 45
    public static func isStale(account: Account, latestSnapshot: Date?, today: Date) -> Bool
}
public struct AccountRow: Equatable, Identifiable {
    public let account: Account
    public let nativeBalanceMinorUnits: Int
    public let gbpBalanceMinorUnits: Int
    public let lastUpdated: Date?   // latest snapshot; for .imported, max(latest snapshot, latest transaction)
    public let isStale: Bool
    public var id: Int64 { account.id! }
}
public struct AccountGroup: Equatable, Identifiable {
    public let kind: AccountKind
    public let subtotalGBP: Int
    public let rows: [AccountRow]      // by gbpBalance desc, then name
    public var id: String { kind.rawValue }
}
public struct AccountsOverview: Equatable {
    public let netWorthGBP: Int
    public let asOf: Date?
    public let changeVsPreviousMonthGBP: Int?   // netWorth − monthEndNetWorth(previous calendar month of today); nil if unknown
    public let groups: [AccountGroup]           // cash, investment, credit; empty groups omitted
    public let staleCount: Int
    public let oldestStaleDate: Date?           // oldest latest-snapshot among stale accounts that have one
    public static func make(accounts: [Account], snapshots: [BalanceSnapshot], transactions: [Transaction], rate: ExchangeRateSetting, today: Date) -> AccountsOverview
}

public enum AccountEditError: Error, Equatable { case emptyName, duplicateName, creditKindChange, accountNotFound }
public struct ReconciliationWarning: Equatable { public let accountName: String; public let driftMinorUnits: Int; public let currency: Currency }

public enum AccountEditing {
    @discardableResult
    public static func add(db: Database, name: String, currency: Currency, kind: AccountKind, trackingMode: AccountTrackingMode, openingBalanceEntered: Int?, asOf: Date) throws -> Account
    public static func update(db: Database, accountId: Int64, name: String, kind: AccountKind, trackingMode: AccountTrackingMode) throws
    public static func hasHistory(db: Database, accountId: Int64) throws -> Bool
}

public enum BalanceUpdates {
    public struct Entry: Equatable { public let accountId: Int64; public let enteredMinorUnits: Int; public let note: String?; public init(...) }
    /// One snapshot per entry dated `asOf`, all in the caller's write transaction. Drift
    /// warnings only for `.imported` accounts (previous snapshot + transactions since vs the
    /// new balance, `NetWorthCalculator.reconciliationDrift`); they never block the save.
    public static func save(db: Database, entries: [Entry], asOf: Date) throws -> [ReconciliationWarning]
}
```

- [ ] **Step 1: Failing tests.**
  - `BalanceStaleness`: imported never stale; manual with no snapshot stale; 45 days old not stale, 46 stale (dates at noon UTC vs today at 09:00 — use start-of-day).
  - `AccountsOverview.make`: 2 cash (one GBP £100, one EUR €100 at rate 0.5 → £50), 1 investment £200, 1 credit owing £30 → groups order cash, investment, credit; subtotals 15_000, 20_000, −3_000; net worth 32_000; EUR row native 10_000 / gbp 5_000; rows sorted by GBP desc; `changeVsPreviousMonthGBP` = net worth − previous month-end net worth (set snapshots so it's −1_000); `asOf` = latest snapshot date; stale count/oldest; an `.imported` account with old snapshot not stale.
  - `AccountEditing.add`: inserts; opening balance for a credit account entered 30_000 → snapshot −30_000 dated `asOf`; no opening balance → no snapshot; empty/duplicate names throw.
  - `AccountEditing.update`: renames; cash → investment OK with history; cash → credit with a snapshot throws `.creditKindChange`; cash → credit with no history OK; duplicate name throws; unknown id throws `.accountNotFound`.
  - `BalanceUpdates.save`: two entries → two snapshots dated `asOf`, credit signed; an `.imported` account whose previous snapshot + transactions since ≠ the new balance returns one warning with the drift; a manual account never warns; an unknown accountId throws and nothing is written when the caller wraps it in a transaction (test with `dbQueue.write`).
  - `DashboardCalculator.attentionItems` existing tests still pass unchanged.
- [ ] **Step 2: Run** → fail (types missing).
- [ ] **Step 3: Implement** in the two new files (use `NetWorthCalculator.accountBalances`, `monthEndNetWorth`, `signedSnapshotBalance`, `runningBalance`, `reconciliationDrift`; read `NetWorthCalculator.swift` and `App/NetWorth/NetWorthViewModel.swift` `addSnapshot` for the existing reconciliation logic and reuse it, don't re-derive it). Replace the inline stale rule in `DashboardCalculator.attentionItems` with `BalanceStaleness.isStale`.
- [ ] **Step 4: Verify** — focused + full suite green; app build.
- [ ] **Step 5: Commit** — "Add accounts overview, staleness, account editing and bulk balance saving".

---

### Task 2: Accounts screen, navigation and Dashboard links

**Files:** create `App/Accounts/AccountsViewModel.swift`, `App/Accounts/AccountsView.swift`; modify `App/ContentView.swift`, `App/Dashboard/NetWorthCard.swift`, `App/Dashboard/YearChangeCard.swift`, `App/Dashboard/SmallCards.swift`; delete `App/NetWorth/NetWorthView.swift`, `App/NetWorth/NetWorthViewModel.swift`, `App/Accounts/AccountsSettingsView.swift` (keep `App/NetWorth/AddSnapshotView.swift` until Task 3 replaces it, or delete it here if nothing uses it).

**Interfaces — Consumes (Task 1):** `AccountsOverview.make`, `AccountRow`, `AccountGroup`, `BalanceStaleness`, `AccountEditing`, `BalanceUpdates`, `ReconciliationWarning`.

**Produces (`AccountsViewModel`, `@MainActor ObservableObject`):** `overview: AccountsOverview?`, `accounts: [Account]`, `rate: ExchangeRateSetting`, `selectedAccountId: Int64?` (defaults to the first row after load; kept if still present), `selectedHistory: [BalanceSnapshot]` (newest first), `errorMessage: String?`, `warnings: [String]`; `func load()`; `func addAccount(name:currency:kind:trackingMode:openingBalanceEntered:asOf:) -> Bool`, `func updateAccount(id:name:kind:trackingMode:) -> Bool`, `func hasHistory(_ id: Int64) -> Bool`, `func saveBalances(_ entries: [BalanceUpdates.Entry], asOf: Date) -> Bool` (sets `warnings` from the result, formatted "<name>: entered balance differs from the computed running balance by <amount> — check for a missing or duplicate transaction."). Each write: `dbQueue.write`, then `load()`; errors → `errorMessage`, return false. Map `AccountEditError` to messages: "Enter a name.", "An account with that name already exists.", "Can't change to or from credit once the account has balances or transactions."

- [ ] **Step 1: Navigation.** Remove `AppScreen.netWorth`; `.accounts` stays "Accounts" with `building.columns`, moved to the "Overview" section after `.forecast` (adjust `allCases` order and `sidebarSection`). `ContentView` owns `AccountsViewModel` (replacing `netWorthViewModel` and `accountsViewModel`), shows `AccountsView` for `.accounts` with `.onAppear { viewModel.load() }`, and refreshes shared state on `accountsViewModel.accounts` changes as before.
- [ ] **Step 2: Dashboard links.** Every `navigate(.netWorth)` → `navigate(.accounts)`; link titles "Net Worth" → "Accounts" (`NetWorthCard`, `YearChangeCard`, `AccountsCard` title link and "+ N more ›"); the attention row "Update balances" already links — point it to `.accounts`.
- [ ] **Step 3: `AccountsView`** per the spec's App section (the four action buttons — "Update balances…", "+ Add account", "Update balance…", "Edit…" — and their sheets are added in Task 3; this task builds everything else): header (net worth, as-of, change vs previous month with ↑/↓ and colour), stale banner, warnings banner (dismissable), EUR-rate refresh banner from `AppEnvironment.exchangeRateBanner` (dismiss sets it to nil), grouped list with selection (native amount for non-GBP, "owed" for credit, debt coloured), detail panel (name; "GBP · Cash · Manual balance"; balance native + GBP; "Updated <d MMM yyyy> · <N days/months ago>" in warning colour when stale; Swift Charts `LineMark` of snapshot balances in native currency, height ~60; history list latest 12 + "Show all"), footer "EUR rate <rate> · updated <date>", empty state "Add your first account". Use `HSplitView` or an `HStack` with a fixed-width detail column (≥ 280pt).
- [ ] **Step 4: Verify** — app build; full suite green.
- [ ] **Step 5: Commit** — "Merge Net Worth into a new Accounts screen".

---

### Task 3: Sheets — add, edit, update one, update all

**Files:** create `App/Accounts/AccountFormSheets.swift` (add + edit), `App/Accounts/BalanceUpdateSheets.swift` (single + bulk); modify `App/Accounts/AccountsView.swift`; delete `App/NetWorth/AddSnapshotView.swift` and the `App/NetWorth` folder if empty.

- [ ] **Step 1: Add account sheet** — name, currency, kind, tracking, "Opening balance (optional)" field (label "Amount owed" for credit), as-of date picker shown when a balance is entered; Save disabled until the name is non-empty and any entered balance parses (`Money.parseMinorUnits`); inline error from the view model; dismiss on success.
- [ ] **Step 2: Edit account sheet** — name, kind picker (options to/from credit disabled with caption "Can't change to or from credit once the account has history." when `hasHistory`), tracking picker, currency read-only text; Save → `updateAccount`; inline error.
- [ ] **Step 3: Update balance sheet (single)** — amount (credit: "Amount owed"), as-of date (default today), note; Save → `saveBalances([entry])`.
- [ ] **Step 4: Update balances sheet (bulk)** — one row per account (grouped like the list): include checkbox (default on), name, text field prefilled with `NetWorthCalculator.enteredBalance` of the current balance formatted to 2 decimals (credit = amount owed), currency suffix; one as-of date; Save "Save N balances" (N = included rows), disabled when any included row doesn't parse; → `saveBalances(entries, asOf:)`.
- [ ] **Step 5: Wire** the four sheets to the header and detail-panel buttons; after a save showing warnings, the warnings banner shows them.
- [ ] **Step 6: Verify** — app build; full suite green.
- [ ] **Step 7: Commit** — "Accounts: add, edit and update-balance sheets".

---

### Task 4: Check on a database copy (controller)

- [ ] Copy the real DB to the scratchpad; open the built app on it (`open -n --env BUDGET_DB_PATH=<copy> <app>`); check the Accounts screen layout, numbers (net worth £158,637), stale banner (6 balances), sidebar, Dashboard links; screenshots if possible.
- [ ] Final whole-branch review, one fix wave, merge to local `main`.
