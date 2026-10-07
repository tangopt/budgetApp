# Accounts Screen (Net Worth + Accounts merged) — Design Spec

## Overview

The app has two thin screens about the same thing: **Net Worth** (total, balances by kind, "Update a balance…", history list, reconciliation warning) under Overview, and **Accounts** (plain list + add form) under Settings. This merges them into one **Accounts** screen under Overview, following the mockup the user approved on 2026-10-05: net worth on top, accounts grouped by kind, the selected account in a detail panel, plus bulk balance updates, account editing and an opening balance on add.

## Current state (verified)

- `AppScreen.netWorth` ("Net Worth", Overview) → `NetWorthView` + `NetWorthViewModel` (`load`, `addSnapshot(accountId:enteredMinorUnits:note:)` with reconciliation for `.imported` accounts, `updateExchangeRate` — unused by the UI). `AddSnapshotView` sheet (one account at a time; credit accounts enter the amount owed as a positive number).
- `AppScreen.accounts` ("Accounts", Settings) → `AccountsSettingsView` + `AccountsSettingsViewModel` (`load`, `addAccount(name:currency:kind:trackingMode:)`). No editing, no deleting.
- Dashboard links to `.netWorth` from `NetWorthCard`, `YearChangeCard`, `AccountsCard` (title link and "+ N more ›"), and the attention item "N balances not updated…" ("Update balances"). `FreshnessImportCard` links to `.accounts` ("Add an account to import into").
- `ContentView` refreshes shared state on `accountsViewModel.accounts` changes; the EUR-rate refresh banner (`AppEnvironment.exchangeRateBanner`) is shown only in `NetWorthView`.
- `NetWorthCalculator`: `accountBalances`, `netWorth`, `signedSnapshotBalance` / `enteredBalance` (credit sign handling), `runningBalance`, `reconciliationDrift`, `monthEndNetWorth`. Stale-balance rule (45 days, `trackingMode != .imported`) lives inline in `DashboardCalculator.attentionItems`.
- Real data: 6 manual GBP/EUR accounts (5 cash, 1 investment), each with 74 snapshots, latest 1 Feb 2026.

## Goals

- One **Accounts** screen in Overview replacing both; no functionality lost.
- Bring all balances up to date in one sheet.
- Edit an account's name, kind and tracking mode.
- Optional opening balance when adding an account.

## Non-goals

- Deleting accounts or snapshots; editing a snapshot.
- Changing an account's currency (its snapshots and transactions are in that currency).
- Editing the exchange rate by hand (`updateExchangeRate` is removed with the old view model).
- A net-worth history chart on this screen (the Dashboard has it).

## BudgetCore

New `Sources/BudgetCore/NetWorth/AccountsOverview.swift`:

```swift
public struct AccountRow: Equatable, Identifiable {
    public let account: Account
    public let nativeBalanceMinorUnits: Int   // signed (credit owed < 0)
    public let gbpBalanceMinorUnits: Int
    public let lastUpdated: Date?             // latest snapshot date (manual) or latest snapshot/transaction (imported)
    public let isStale: Bool
    public var id: Int64 { account.id! }
}
public struct AccountGroup: Equatable, Identifiable { kind: AccountKind; subtotalGBP: Int; rows: [AccountRow] }
public struct AccountsOverview: Equatable {
    public let netWorthGBP: Int
    public let asOf: Date?                    // latest snapshot date across accounts
    public let changeVsPreviousMonthGBP: Int? // net worth now minus at the end of the previous calendar month
    public let groups: [AccountGroup]         // order: cash, investment, credit; rows by GBP balance desc
    public let staleCount: Int
    public let oldestStaleDate: Date?
    public static func make(accounts: [Account], snapshots: [BalanceSnapshot], transactions: [Transaction], rate: ExchangeRateSetting, today: Date) -> AccountsOverview
}
public enum BalanceStaleness {
    public static let thresholdDays = 45
    public static func isStale(account: Account, latestSnapshot: Date?, today: Date) -> Bool  // never stale for .imported; stale when no snapshot
}
```

`DashboardCalculator.attentionItems` switches to `BalanceStaleness` (same rule, one place).

`Sources/BudgetCore/NetWorth/AccountEditing.swift`:

- `AccountEditing.update(db:accountId:name:kind:trackingMode:) throws` — name trimmed, non-empty, unique (`AccountEditError.emptyName / .duplicateName`). Kind may change between `.cash` and `.investment`; changing to or from `.credit` throws `.creditKindChange` when the account has any snapshot or transaction (sign convention), allowed otherwise.
- `AccountEditing.add(db:name:currency:kind:trackingMode:openingBalanceEntered:asOf:) throws -> Account` — same name rules; when `openingBalanceEntered` is non-nil inserts a snapshot dated `asOf` (signed with `signedSnapshotBalance`).
- `BalanceUpdates.save(db:entries:[(accountId, enteredMinorUnits, note?)], asOf: Date) throws -> [ReconciliationWarning]` — one snapshot per account per day dated `asOf` (an existing snapshot for that account on that exact date is updated, value and note, instead of inserting a second), in one transaction; returns drift warnings for `.imported` accounts (against the latest snapshot strictly before `asOf`), never blocks the save. The latest snapshot on a date breaks ties by id (newest insert wins). A statement import for the same day replaces a typed balance (the bank's figure wins).

Snapshot dates: `asOf` is a calendar day from a date picker, stored as that day at 00:00 UTC (convert local → UTC day with `PayCalendar.utcDay(sameDayAs:in:)`), default today. (Today's single-update flow stamps `Date()`; balances mean "close of that day", per the statement-balances spec.)

## App

**Navigation.** `AppScreen.netWorth` is removed. `.accounts` ("Accounts", icon `building.columns`) moves to the Overview section after Forecast. Every Dashboard `navigate(.netWorth)` becomes `navigate(.accounts)`, and the link titles read "Accounts". `NetWorthView`, `NetWorthViewModel`, `AddSnapshotView`, `AccountsSettingsView` and `AccountsSettingsViewModel` are deleted; `ContentView` observes the new view model's accounts for shared-state refresh.

**`AccountsViewModel`** (`App/Accounts/AccountsViewModel.swift`): loads accounts, snapshots, transactions, rate; publishes `overview`, `selectedAccountId` (default: first row), `selectedHistory: [BalanceSnapshot]` (newest first), `errorMessage`, `warnings: [String]`; actions `add…`, `update…`, `saveBalances…`, each write-first then reload, returning `Bool`.

**`AccountsView`** (`App/Accounts/AccountsView.swift`), layout as in the mockup:
- Header: "Net worth · as of <asOf>", the total, "↑/↓ £x vs previous month"; buttons "Update balances…" and "+ Add account".
- Banners: stale balances ("N balances not updated since <date> — import a statement or update them."), reconciliation warnings from the last save, the EUR-rate refresh banner (moved from `NetWorthView`, dismissable).
- Left: groups with "Kind · £subtotal" headers; rows: name, native amount for non-GBP accounts in secondary text, GBP balance; credit rows show "£x owed" coloured as debt (as `NetWorthView` does today). Selection highlights the row.
- Right (selected account): name; "Currency · Kind · Manual balance / Imported"; balance (native, plus GBP for non-GBP); "Updated <date> · <age>" (warning colour when stale); a small Swift Charts line of its snapshot balances (native); buttons "Update balance…" and "Edit…"; "Balance history" list (date, balance, note) showing the latest 12 with "Show all" expanding.
- Footer under the list: "EUR rate <rate> · updated <date>".
- Empty state (no accounts): "Add your first account" with the add button.

**Sheets** (inline errors, Save disabled until valid):
- **Add account:** name, currency, kind, tracking, optional opening balance (credit: "amount owed") with an as-of date.
- **Edit account:** name, kind (credit transitions disabled with the reason when it has history), tracking; currency shown read-only.
- **Update balance:** one account (from the detail panel), amount, as-of date, note.
- **Update balances:** every account listed with a text field prefilled with its current entered balance (credit as amount owed), an "include" checkbox per row (default on), one as-of date, Save "Save N balances". Unchanged included rows are saved too (confirms the balance as of that date).

## Testing

BudgetCore (XCTest): `AccountsOverview.make` (grouping order, subtotals, GBP conversion, change vs previous month, stale count/oldest, imported never stale), `BalanceStaleness`, `AccountEditing.update` (name rules, credit-kind rule with/without history), `AccountEditing.add` (opening balance signed for credit), `BalanceUpdates.save` (one snapshot per account per day, asOf date, drift warnings only for imported accounts, all-or-nothing on error), and `DashboardCalculator.attentionItems` unchanged results. App: build; manual check on a database copy.
