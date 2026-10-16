# Settings Window and Themes — Design Spec

Approved in chat 2026-10-16 ("let the theme affect them, although they should be different from each other in all cases, list is fine, go").

## Settings window
- SwiftUI `Settings` scene (Budget ▸ Settings…, ⌘,) with tabs: **Appearance** (System / Light / Dark — moved from the sidebar; the sidebar AppearanceToggle is removed; same storage key `appAppearance` and NSApp.appearance behaviour) and **Theme** (grid of theme swatch cards).
- Theme swatch card: name + a miniature grid preview drawn from the theme's tokens (header row, two striped rows, a group row, a totals row, an income amount, an expense amount, a pending amount, accent outline when selected); rendered in the current effective appearance (light/dark variant). Click applies immediately app-wide; persisted (`appTheme` AppStorage, default Classic).

## Theme tokens (each theme defines a light and a dark variant)
accent; windowBackgroundTint (subtle, may be clear); gridHeaderBackground; rowStripe; groupRowTint; sectionHeaderTint; totalsTint + totalsNetTint; reservedTint; adjustmentsTint; selectionOutline; income (positive money); expense (negative money); pending (forecast); neutral/secondary money; yoyGood; yoyBad; chartSeries (ordered palette, ≥ 8 colours, used for Dashboard/Accounts/Forecast compare series incl. PlanPalette).
Rule (user): income, expense and pending colours may follow the theme but must always be clearly distinguishable from each other and from body text — enforce with a unit test computing pairwise contrast/difference (e.g. CIEDE2000 ΔE ≥ 20 between income/expense/pending, and WCAG contrast ≥ 3:1 for each against the theme's grid background in both variants).

## Themes (15)
Classic (current look exactly), Ledger (cream paper, ink, red/green ledger), Ocean, Forest, Sunset, Nord, Solarized, Dracula, Graphite, Sakura, Lavender, Desert, Midnight (navy + gold), Mint, High Contrast.

## Implementation
- `Theme` model (App/DesignSystem/Theme.swift): id, name, light/dark token sets; `ThemeStore`/environment value `\.theme` injected at the root (ContentView and Settings), resolved by effective colour scheme.
- Replace hard-coded colours across the app with theme tokens: Color.pending, green/red money colours (MoneyText, PlanCellView, YoY deltas, year cards), grid backgrounds (BudgetGridView, ScenarioGridTab, GridRowLabels stripes/tints, Totals tint, GroupNameCell/SectionHeaderCell orange tints), selection outline (CellSelection), accent (`.tint(theme.accent)` at the root), charts (Dashboard, Accounts, Forecast compare PlanPalette). Grep for `Color.green`, `Color.red`, `.orange`, `.teal`, `Color.pending`, `.accentColor` usages and route them through tokens where they represent these roles (leave semantic system colours like warnings where appropriate, but warnings/destructive stay red).
- Classic must reproduce today's look (regression check by reading/compare values).
- Tests (BudgetCore or an app-free Swift module if theme values are pure data — put the palette data and contrast maths in BudgetCore if needed so it's testable): every theme has all tokens in both variants; the distinguishability rule above; Classic equals current constants.
- Grid smooth-scroll constraints unchanged; caching unaffected; theme change must re-render without reloading data.
