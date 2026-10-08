# Faster Categorising — Design Spec

## Overview

Requested 2026-10-08: importing needs fewer manual decisions, similar transactions must be categorisable in bulk, and the category selector must be easier. Applies to the import Review screen and the Uncategorized screen.

**Why it's slow today:** `RuleLearner.learnFromCorrection` saves a `contains` rule with the *whole* description ("PLAYTOMIC* PI-5B20"), so the next variant ("PLAYTOMIC* PI-793A") doesn't match; past categorised transactions are never consulted before the on-device model.

## 1. Merchant key (BudgetCore)

`MerchantKey.make(_ description: String) -> String`: uppercase; split on whitespace; drop tokens containing any digit (store numbers, references like `PI-5B20`, card digits, dates); strip leading/trailing punctuation (`*`, `-`, `/`, `.`, `,`, `#`) from each remaining token and drop tokens that become empty; join with single spaces. If the result is shorter than 3 characters, return the uppercased, whitespace-collapsed full description instead.

Examples: "TESCO STORES 2041" and "TESCO STORES 3312" → "TESCO STORES"; "PLAYTOMIC* PI-5B20" → "PLAYTOMIC"; "Shake Shack - Argy" → "SHAKE SHACK ARGY"; "SQ *DONUTELIER CAR" → "SQ DONUTELIER CAR"; "TFL TRAVEL CH" → "TFL TRAVEL CH"; "APPLE.COM/BILL" → "APPLE.COM/BILL" (inner punctuation kept); "12345" → "12345".

## 2. Learning and suggestion order (BudgetCore)

- **Learning:** `RuleLearner.learn(description:categoryId:db:)` saves/updates a `contains` rule whose pattern is the merchant key — unless the key is shorter than 4 characters, in which case the uppercased full description is used (as today). Matching stays case-insensitive `contains`. Existing rules are untouched. `learnFromCorrection` delegates to `learn`.
  - A key-based `contains` rule matches descriptions containing the key text; because keys drop digit tokens, "TESCO STORES" matches "TESCO STORES 3312". Descriptions whose punctuation differs from the key (e.g. "PLAYTOMIC* PI-793A" vs key "PLAYTOMIC") still match since the key is a substring.
- **History:** `HistoryCategorizer.suggest(merchantKey:history:) -> (categoryId, count)?` over past transactions with a category (status confirmed, any `categorizedBy`), grouped by merchant key: suggest the most used category when it covers ≥ 70% of that key's categorised transactions and there are at least 2 of them.
- **Order in `CategorizationService.categorizeBatch`:** rules → history → on-device model → none. History suggestions get a new `CategorizedBy.history` source (stored as text; decoding older rows unaffected), confidence = share (0.7–1.0), and the review row shows "Suggested from N past transactions".
- The import staging loads history once per import (categorised transactions of all accounts), not per row.

## 3. Category picker (App, shared)

A searchable popover replacing the plain `Picker` on the Review and Uncategorized screens:
- Button shows the chosen category (or "Choose category") with a chevron.
- Popover: search field focused on open (type to filter, case-insensitive substring on name and group name); sections **Suggested** (the row's suggestion, if any), **Recent** (up to 5 categories most used in the last 90 days, from transactions), then all assignable categories under their category groups (ungrouped last, alphabetical within).
- Filtered by sign: money out → expense and transfer categories; money in → income and transfer categories; a "Show all categories" row at the bottom removes the filter. Reserves never appear (as today, `isAssignable`). "Uncategorized" option at the top to clear.
- Keyboard: ↑/↓ moves the highlight, Return picks, Escape closes. Mouse click picks.
- BudgetCore helper `CategoryShortlist.recent(db:since:limit:) -> [Int64]` (tested).

## 4. Review screen (import)

- **Grouping:** rows in "Needs your attention" and "Ready to confirm" are grouped by merchant key. A group of 2+ shows one row: key, "× N", date range, total, and one category picker that sets every row in the group; a disclosure expands its rows, each with its own picker (changing one row individually detaches it: its picker shows its own value, the group picker shows "Mixed"). Single-row groups render as today's row.
- **Selection:** the list supports multi-select (⌘-click, ⇧-click) of rows and groups; a **Set category…** button (enabled with ≥1 selected) opens the category picker and applies to every selected row (a selected group = all its rows).
- **Remember:** a "Remember for <key>" toggle appears on a group row and in the Set category… popover, on by default when categorising a group or 2+ rows, off for a single row. On commit, rows whose category was set with Remember on learn a key rule (`RuleLearner.learn`); rows set without it don't learn. (Today every manual override learns; now single-row overrides learn only if Remember is ticked — default off for single rows.)
  - Implementation: `ImportDecision` gains `learnRule: Bool` (default true for source compatibility); `commit` learns only when `wasOverridden && learnRule`.
- Confirm / "Confirm N ready" / "Save remaining as Uncategorized" / Return-to-confirm keep working; confirming a group confirms all its rows.

## 5. Uncategorized screen

Same grouping by merchant key, multi-select, Set category…, the new picker and the Remember toggle; saving a category updates each transaction (as today) and learns a key rule when Remember is on.

## Testing

BudgetCore XCTest: `MerchantKey` (examples above, short-key fallback, empty); `RuleLearner.learn` (key pattern, short-key fallback, updates existing rule); `HistoryCategorizer` (majority ≥70% with ≥2, ties/no majority → nil, single transaction → nil); `CategorizationService` order rules → history → model, `.history` source and confidence; `CategoryShortlist.recent`; `ImportCoordinator.commit` learns only when `learnRule`. App: build; full suite.
