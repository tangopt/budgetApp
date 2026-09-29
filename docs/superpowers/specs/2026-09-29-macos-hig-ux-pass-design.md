# macOS HIG UX Pass — Design Spec

## Overview

The app's navigation shell and several screens don't follow macOS Human Interface Guidelines conventions that users of native Mac apps expect: a sidebar with no icons or grouping, a window title that never changes, page actions hand-positioned to *look* like toolbar buttons without being real ones, and no search on the two list-heavy screens. This is a presentation-layer pass across the whole app to bring it in line with those conventions — no data model or `BudgetCore` changes.

## Current State (as of this session)

`App/ContentView.swift` drives an 8-item `NavigationSplitView` sidebar (`AppScreen`: Import, Budget, Forecast, Net Worth, Rules, Categories, Uncategorized, Accounts) as a single flat `List` of `Text(screen.rawValue)` rows, no icons, no `Section` grouping. Neither `ContentView.swift` nor `App/BudgetApp.swift` sets a `.navigationTitle` anywhere, so the window title is always the static bundle display name ("Budget"), regardless of the selected screen.

No file in the app calls `.toolbar`. One screen has a genuinely standalone page-level action button, manually positioned in the content body to look native:
- `App/Budget/BudgetGridView.swift` — "Export CSV…" button (line 127), sitting alone in an `HStack` with a `Spacer()`, no adjacent form dependency.

`App/Accounts/AccountsSettingsView.swift`'s "Add account" button (line 44) looks similar at a glance but isn't a standalone action — it submits the `Name`/`Currency`/`Kind`/`Tracking` `Form` immediately above it in the same body, reading those fields' `@State` directly. This is the same shape as Categories' "Add Group", not Budget's "Export CSV…".

No file calls `.searchable`. Two screens hold a plain, unfiltered list/table that would benefit from it:
- `App/Uncategorized/UncategorizedView.swift` — a `List` of uncategorized transactions, filterable by `transaction.rawDescription`
- `App/Rules/RulesView.swift` — a `Table` of categorization rules, filterable by `rule.matchPattern`

## Goals

- Sidebar rows get SF Symbol icons and are grouped into labeled sections reflecting how the screens are actually used.
- The window title reflects the currently selected screen.
- The two existing "looks like a toolbar button but isn't" actions become real `.toolbar` items.
- The two list-heavy screens get `.searchable`.
- Every change stays visually correct in both light and dark mode (no new hardcoded colors — this app already avoids them everywhere else).

## Non-Goals

- No change to `BudgetCore`, any view model's data/logic, or any screen's core functionality.
- No redesign of `Categories`' inline "Add Group" flow, or `Accounts`' inline "Add account" flow, into a toolbar/popover — both are a compact form submitted by an adjacent button, not a standalone page action; forcing either into a toolbar would mean a real interaction redesign (the form would need to become a sheet/popover), out of scope for a conventions pass. Both stay exactly as they are today.
- No change to `Import`'s "Import into" account picker — it's a content filter, not a page action, so it stays inline.
- No new sidebar items, no removal of existing screens, no renaming of any `AppScreen` case's user-facing label (only icons/grouping are added around the existing labels).
- No addition of a "Dashboard" landing screen — that's separate, already-deferred work, not part of this pass.

## Design

### 1. Sidebar: icons + grouping

`AppScreen`'s `List(AppScreen.allCases, selection:)` becomes a sectioned list with three `Section`s, in this order:

- **Workflow** — Import (`square.and.arrow.down`), Uncategorized (`folder.badge.questionmark`)
- **Overview** — Budget (`tablecells`), Forecast (`chart.line.uptrend.xyaxis`), Net Worth (`banknote`)
- **Settings** — Rules (`wand.and.stars`), Categories (`tag`), Accounts (`building.columns`)

Each row becomes `Label(screen.rawValue, systemImage: screen.systemImage)` instead of a bare `Text`. `AppScreen` gains a `systemImage: String` computed property (one `switch` over `self`, mirroring the icons above) and a `sidebarSection: String` computed property returning one of `"Workflow"`, `"Overview"`, `"Settings"` (used to build the three `Section`s). The sidebar body groups `AppScreen.allCases` by `sidebarSection` while preserving the fixed order above (not alphabetical — `Section` grouping must not silently reorder screens within a group if a future case is added in a different position in the enum).

### 2. Dynamic window title

`ContentView`'s `detail:` closure gets `.navigationTitle(selection?.rawValue ?? "Budget")` applied to its outermost `Group`. `AppScreen.rawValue` is already the exact user-facing label ("Import", "Budget", "Forecast", …), so the title bar shows exactly the sidebar's current selection with no extra plumbing. The `"Budget"` fallback covers `selection == nil` (the initial launch state is `.importReview`, so this is a defensive fallback, not a normally-reachable state).

### 3. Toolbar migration

One button moves from inline body content into `.toolbar { ToolbarItem(placement: .primaryAction) { ... } }`:

- `BudgetGridView`: "Export CSV…" — same closure/behavior, moved from its current `HStack { Spacer(); Button(...) }` (`BudgetGridView.swift:125-131`) into a toolbar item; the now-empty `HStack`/`Spacer()` wrapper is removed since it existed only to right-align this button.

It keeps its exact existing action closure; only its position (inline body → `.toolbar`) changes. `ToolbarItem(placement: .primaryAction)` is the standard placement for a screen's one main affirmative action on macOS (right side of the title bar).

### 4. Search

- `UncategorizedView`: `.searchable(text:)` bound to a new `@State private var searchText = ""` on the view, filtering `viewModel.transactions` by a case-insensitive `rawDescription` substring match before rendering the `List`. Filtering happens in the view (a computed `filteredTransactions` property), not the view model — this is presentation-only filtering of already-loaded data, consistent with the view model owning data loading and the view owning how it's displayed.
- `RulesView`: same pattern — `.searchable(text:)` + `@State private var searchText`, filtering `viewModel.rules` by a case-insensitive `matchPattern` substring match before rendering the `Table`.

Both default to an empty search field (no filter applied) so existing behavior is unchanged until the user actually types.

### 5. Testing

This entire pass is SwiftUI presentation structure — no `BudgetCore` surface, no view-model logic changes, nothing this codebase's existing test suite pattern (`XCTest` against `BudgetCore`) can exercise. Verification is: a full Debug build (`xcodebuild`) plus a live manual walkthrough of every one of the 8 screens confirming:
- Every sidebar row shows its icon and sits in the correct section, in the same order as today
- Selecting each screen updates the window title to match
- Budget's Export CSV works identically from its new toolbar position
- Uncategorized and Rules both filter correctly as text is typed into the search field, and show everything again when cleared
- Light and dark mode both look correct (no hardcoded colors were introduced)

## File-by-File Summary

- `App/ContentView.swift` — sectioned sidebar with icons, `.navigationTitle`
- `App/Budget/BudgetGridView.swift` — Export CSV button → toolbar
- `App/Uncategorized/UncategorizedView.swift` — `.searchable` + filtered list
- `App/Rules/RulesView.swift` — `.searchable` + filtered table

`App/Accounts/AccountsSettingsView.swift` does not change (see Non-Goals — its "Add account" button is a form submission, not a standalone action). No other files change.
