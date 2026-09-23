# Budget App — UX Pass Design Spec

Date: 2026-09-23

## Background

The v1 budgeting app (see [2026-07-27-budget-app-design.md](2026-07-27-budget-app-design.md))
is built and merged: import, categorization, review, budget grid,
forecasting, and net worth all work end to end, verified by 110
`BudgetCore` tests and a final whole-branch review that caught and fixed
7 Critical cross-cutting bugs. It has not yet had any real design pass —
screens were built to the letter of the original plan's SwiftUI code
blocks, functionally correct but visually plain, and several features the
original spec implied were never actually wired into the UI.

This spec covers a comprehensive UX pass: a consistent visual language
across every screen, four specific functional gaps closed, and workflow
speed-ups on the daily import/review loop. It also replaces the
LLM-categorization fallback entirely — the original design assumed
Anthropic API access, but the user has a Claude Pro (claude.ai)
subscription, which does not include API access. Pro and the API are
separate products with separate billing.

## Scope

In scope:
- A shared design system: color semantics (green/red for money), a
  reusable money-text component, a category badge component (sized
  small/medium/large, with an icon slot for a future per-category icon
  set), consistent native light/dark handling.
- Review screen redesign: confidence indicator per row, grouping into
  "ready to confirm" vs. "needs your attention," partial bulk-confirm,
  keyboard navigation and type-ahead category selection.
- A new "Uncategorized" screen for assigning categories to transactions
  that were committed without one.
- Budget grid cell drill-down (tap a cell, see its transactions or
  forecast entry).
- Forecast entry editing and un-confirming; a real forecast horizon
  (end of current year, extendable to next year) replacing the 3-month
  placeholder.
- Automatic EUR→GBP exchange rate fetching at launch, replacing manual
  entry, with a change-impact tooltip.
- Replacing `ClaudeCategorizer` (Anthropic API) with an on-device
  categorizer built on Apple's Foundation Models framework — no API key,
  no network call, no per-use cost. Removing the now-unnecessary API key
  Settings screen.

Out of scope (not ruled out for later):
- A full per-category icon library (the badge component is built to
  support it; sourcing/designing actual icons is separate work).
- Smarter recurrence detection beyond what `AutoForecastGenerator`
  already does.
- Multi-currency beyond EUR/GBP.
- Any change to the CSV/PDF import pipeline itself (already covered by
  the final-review fix wave).

## Global Constraints

- Money is always `Int` minor units in the data model (unchanged from
  the original spec) — the new `MoneyText` view is the only place that
  formats/colors it for display.
- `BudgetCore` logic must stay unit-testable without a UI, a real
  database, or network access. The on-device categorizer's
  prompt-building and response-parsing logic must be structured so it's
  testable independent of actually invoking `LanguageModelSession`
  (inject the session dependency, same pattern `ClaudeCategorizer` used
  for `URLSession`).
- The on-device categorizer and the exchange-rate fetch must both be
  non-blocking and silently degrade: unavailable Apple Intelligence, a
  failed generation, being offline, or a bad exchange-rate response must
  never crash or block the app — they fall back to manual
  categorization / the last saved rate, exactly as the original spec's
  error-handling philosophy required for the Claude fallback.
- Bundle id `com.personal.budget` (unchanged).
- Every screen touched must work correctly in both light and dark mode —
  no hardcoded colors; use semantic `Color`/system materials throughout.

## Design system

- **`MoneyText`** — a SwiftUI view wrapping `Money.format`, taking
  `minorUnits: Int` and `currency: Currency`. Renders tabular-figure
  text colored `.green` for positive amounts, `.red` for negative, using
  semantic colors that adapt to light/dark automatically. Every existing
  `Text(Money.format(...))` call site across `App/` is replaced with
  `MoneyText(...)`. `.contentTransition(.numericText())` is applied so
  values animate when they change rather than popping.
- **`CategoryBadge`** — a small colored circle keyed by `CategoryType`
  (expense/transfer/income), with a `size: BadgeSize` parameter
  (`.small`/`.medium`/`.large`) controlling diameter and an optional
  icon slot (`SF Symbol` name, currently unused/nil everywhere it's
  placed) so a future per-category icon set is a data change, not a
  component rewrite. Used in the Review screen and the new Uncategorized
  screen.
- **Light/dark audit** — every existing view is checked for
  non-semantic colors (e.g. a literal `Color(.systemGray6)` or hardcoded
  hex) and switched to semantic equivalents
  (`Color(.controlBackgroundColor)`, `.primary`, `.secondary`, etc.).

## On-device categorization

Replaces `Sources/BudgetCore/Categorization/ClaudeCategorizer.swift`
with `Sources/BudgetCore/Categorization/OnDeviceCategorizer.swift`,
conforming to the existing `Categorizing` protocol
(`suggestCategory(description:candidateCategoryNames:) async throws ->
CategorySuggestion?`) so `CategorizationService` needs no changes.

- Uses `FoundationModels.LanguageModelSession` with guided generation
  (a `@Generable` response type carrying `categoryName: String` and
  `confidence: Double`) to constrain the model's output to a valid
  shape, avoiding the free-text-parsing fragility the Claude
  implementation had.
- Checks `SystemLanguageModel.default.availability` before attempting
  generation; if not `.available` (Apple Intelligence disabled, or a
  Mac that doesn't support it), returns `nil` immediately — the same
  "no suggestion" contract as a missing API key had, so
  `CategorizationService`'s rules-first-then-fallback-then-uncategorized
  chain is unaffected.
- `Sources/BudgetCore/Support/KeychainAPIKeyStore.swift` and
  `App/Settings/APIKeySettingsView.swift` are deleted, along with the
  `.settings`/`APIKeySettingsView()` case in `ContentView`'s navigation
  — there is nothing left to configure.

## Review screen redesign

- `StagedTransaction.confidence` (already computed, currently unused in
  the UI) drives a small `ConfidenceDot` next to each row's category
  picker: green for a rule match (confidence 1.0), amber for an
  on-device suggestion with confidence at or above 0.6, gray for no
  suggestion at all (confidence 0 / nil). A subtitle under the description shows the source
  in words ("Matched rule: SAINSBURYS" / "Suggested by on-device model"
  / "No suggestion").
- Rows split into two sections via a computed property on
  `ImportViewModel`: **Ready to confirm** (rule matches + high-confidence
  suggestions) and **Needs your attention** (low-confidence + none).
  Needs-attention starts expanded, ready-to-confirm starts collapsed
  showing just a count ("18 ready").
- Two actions replace the single "Confirm all": **"Confirm N ready"**
  commits only the ready-to-confirm group; each needs-attention row gets
  its own inline confirm once you've set its category. Both funnel
  through the same `ImportCoordinator.commit` — the split is a UI-level
  partition of the existing `decisions` array, not a new commit path.
- Keyboard: up/down arrow moves a `@FocusState` row selection; typing
  while a row is focused filters that row's category picker
  (type-ahead); Return confirms the focused row and advances focus to
  the next.

## Uncategorized screen

A new `App/Uncategorized/UncategorizedView.swift` +
`UncategorizedViewModel.swift`, added as a sidebar entry between Rules
and Accounts. The view model loads every `Transaction` where
`categoryId IS NULL OR status = 'pendingReview'`, across all accounts,
sorted by date descending. Each row reuses the Review screen's row
layout (description, `MoneyText`, category picker) without the
staged/import framing — picking a category updates that `Transaction`
directly via a GRDB `update`, sets `status: .confirmed`, and offers the
same "learn a rule from this correction" behavior `RuleLearner` already
provides elsewhere. Empty state: "Nothing uncategorized" with a
secondary line pointing at Import if the list is empty because nothing's
been imported yet.

## Budget grid drill-down

Tapping a non-empty `BudgetGridView` cell opens a sheet:
- For an `.actual` period: the list of `Transaction`s summing to that
  cell, each with a category picker. Re-categorizing here updates the
  underlying transaction immediately (same GRDB update path the
  Uncategorized screen uses); `BudgetGridViewModel` reloads its data
  when the sheet is dismissed, so the grid total reflects the change
  without needing a manual refresh action.
- For a `.projected` period: the single `ForecastEntry` producing the
  cell's forecast value, read-only in this sheet (editing happens via
  the Forecast screen's own edit flow, described next, to avoid two
  different edit surfaces for the same data).

## Forecast entry editing, un-confirm, and horizon

- Tapping a `ForecastEntry` row in `ForecastComparisonView` opens an
  edit sheet (amount, frequency, interval) pre-filled with current
  values. Saving updates the entry and sets `status: .manual` if it was
  `.auto`, so a future `AutoForecastGenerator.refresh` won't silently
  overwrite the edit (mirrors the existing `guard existing.status ==
  .auto` skip-on-manual-tuning behavior).
- A `.confirmed` entry gets an "Un-confirm" button flipping it back to
  `.hypothetical`; reversible via the existing "Confirm" action in the
  other direction.
- `ForecastViewModel`/`BudgetGridViewModel`'s hardcoded `Date() + 3
  months` horizon becomes "end of the current calendar year" by default
  (matching the original spec), with an "Extend to next year" button in
  `ForecastComparisonView` that recomputes the horizon to the end of the
  following year and reloads.

## Automatic exchange rate

- `AppEnvironment` gains a fire-and-forget async task at launch:
  fetch the current EUR→GBP rate from `https://api.frankfurter.app/latest?from=EUR&to=GBP`
  (no API key). Parse the single `GBP` rate from the JSON response.
- Compare the fetched rate to `ExchangeRateSetting.currentOrDefault`,
  rounded to 2 decimal places. If equal, no-op. If different: compute
  net worth under the old rate and under the new rate (via the existing
  `NetWorthCalculator`), save the new `ExchangeRateSetting`, and publish
  a dismissible banner state that `NetWorthView` displays on next
  appearance: *"EUR rate updated to X (was Y) — net worth changed by
  ±£Z."*
- Any failure (no network, non-200, malformed JSON, decode error) is
  caught and ignored — falls back to the existing saved rate exactly as
  today. Never blocks app launch; the fetch races the rest of
  `AppEnvironment`'s synchronous setup and simply updates state
  whenever it finishes (or doesn't).
- `App/NetWorth/AddSnapshotView.swift`'s currency handling is untouched
  by this (it's about account balances, not the conversion rate). No
  manual rate-entry UI is built.

## Testing

- `BudgetCore` gains unit tests for: `OnDeviceCategorizer`'s
  availability-check short-circuit and response-parsing logic (with the
  `LanguageModelSession` dependency injected/mocked, matching the
  `ClaudeCategorizer` test pattern of stubbing the network layer); the
  exchange-rate-change detection logic (2-decimal comparison,
  net-worth-impact calculation) as a pure function separate from the
  actual HTTP fetch; the review-screen row-partitioning logic
  (ready-to-confirm vs. needs-attention) as a pure function over
  `[StagedTransaction]`; the Uncategorized screen's query logic.
- SwiftUI view wiring (the sheets, buttons, keyboard handling,
  `MoneyText`/`CategoryBadge` rendering) is not unit-tested, consistent
  with the rest of the app — verified by build success and, this time,
  an actual interactive pass once implementation is done (the original
  build's biggest known gap was never getting real screen time; this
  pass should close that gap for itself at minimum).
