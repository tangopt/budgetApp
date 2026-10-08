# CSV Import Mapping Redesign + Grid/Forecast UX — Design Spec

## Overview

Two independent changes requested 2026-10-08:
1. The CSV column-mapping sheet (`App/Import/CSVMappingWizardView.swift`) is a cramped form that clips labels and can't show the file. Replace it with **Option A + result preview**: a wide sheet showing every column of the file with a role menu above each column header, a live check, and a preview of the first transactions as they will be imported.
2. Grid click targets and Forecast spacing (approved design from the same day).

## 1. CSV mapping sheet

### Layout (sheet, min 900×600, resizable)
- **Title:** "Map columns — <account name>" and one line: "Choose what each column holds. Columns set to Ignore aren't imported."
- **File table:** every column of the CSV, header row plus the first 8 data rows, horizontally scrollable when wide. Above each column header a **role menu**: Date, Description, Amount (signed), Money out, Money in, Balance, Ignore. Mapped columns' menus are accent-tinted; ignored columns' cells are secondary-coloured.
  - Each role except Ignore can be on one column only: choosing a role already used elsewhere moves it (the other column becomes Ignore).
  - Amount (signed) and Money out/Money in are exclusive: choosing Amount clears Money out/in and vice versa.
  - Balance isn't offered for credit-card accounts (as today).
- **Options row** under the table:
  - **Date format** menu: formats detected from the Date column's values (every sample value must parse), most likely first, plus "Custom…" (text field). When nothing matches: "Custom…" preselected with a red hint.
  - **Flip sign** toggle, shown only with Amount (signed): for banks that export spending as positive numbers.
  - **Live check:** "N rows read, 0 problems" (green) or "N rows read, M can't be read" (red) with a "Show" disclosure listing up to 10 unreadable lines. Missing roles: "Still needed: Date, Description" (red), instead of the counts.
- **Result preview:** the first 8 parsed transactions — date (d MMM yyyy), description, amount (signed £, red out / green in), balance — computed with `CSVStatementParser` on the full file with the draft mapping.
- **Buttons:** Cancel, **Save mapping** (default). Save is allowed when Date, Description and either Amount or both Money out and Money in are mapped, and at least one row parses; otherwise pressing it shows what's missing inline.

### Starting state
- New mapping: roles prefilled from `CSVColumnSuggester` (as today); everything else Ignore; date format = best detected.
- Existing mapping: the sheet opens prefilled from the account's saved `ImportProfile`. The import screen gets an **"Edit column mapping…"** action for an account that has a CSV profile, which opens the sheet with the next file's (or last chosen file's) contents; saving replaces the profile.

### Model changes (BudgetCore)
- `ImportProfile.csvNegateAmounts: Bool` (default false), migration appended last (`addCSVNegateAmounts`, column NOT NULL DEFAULT 0). `CSVStatementParser` negates single-column amounts when set (split debit/credit columns are unaffected).
- `CSVDateFormatDetector.candidates(values: [String]) -> [String]`: from a fixed list (`dd/MM/yyyy`, `d/M/yyyy`, `MM/dd/yyyy`, `yyyy-MM-dd`, `dd-MM-yyyy`, `dd.MM.yyyy`, `dd MMM yyyy`, `d MMM yyyy`, `dd/MM/yy`, `yyyy/MM/dd`) returns those that parse every non-empty value with `StatementDateFormatter`; ordered so day-first formats come before month-first when both parse (UK default).
- `CSVColumnMapping` (pure): roles per column index ↔ `ImportProfile` fields, with the exclusivity rules above (`assign(role:to:)`), `missingRoles`, and `profile(accountId:dateFormat:negate:)`; init from a profile or a `CSVColumnSuggestion`.

## 2. Grid click targets and Forecast spacing

- **Group rows** (Budget grid and scenario grid): the whole name cell (chevron + name, full row height and column width) toggles expand/collapse, with a hover highlight.
- **Cells:** every month cell, Year Total and multi-year column responds to a click anywhere in its full frame (edge to edge, including padding) — opening details, adding to an empty cell, editing. Reserve cells too. Shared `GridMetrics` sizes.
- **Forecast spacing (Apple HIG):** the Compare / Differences / Grid segmented control moves into the window toolbar (principal placement) and the Horizon picker into the toolbar's trailing side, only while the Forecast screen is shown. Content uses 20pt side margins. The scenario chip row gets a leading secondary "Scenarios" label, then a divider with 16pt spacing before the tab content. Grid tab: the "Editing" bar has 12pt above and below. Differences tab: Apply / Undo / Untick all on their own row below the chips. Compare: 16pt between chips, chart and summary.

## Testing

BudgetCore XCTest: `CSVDateFormatDetector` (UK day-first preferred, ISO, ambiguous values, nothing matches, blanks ignored); `CSVColumnMapping` (exclusivity, amount vs out/in, missing roles, profile round trip incl. balance and negate); parser with `csvNegateAmounts`; migration default. App: build; full suite.
