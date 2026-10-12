# Side Panels, Year Cards, Categories Screen — Design Spec

Requested 2026-10-12 (mockup approved in chat).

## 1. Budget: year selector cards

Each year in the Budget year selector is a card: the year (bold), the **year-end net worth** (31 Dec, or for the current year the forecast to December, captioned "forecast to Dec"; for past years with no data "—"), and the % change vs the previous year's year-end net worth (green ↑ / red ↓, one decimal). Selected cards are filled with the accent tint and outlined; ⌘-click still toggles multi-year compare; a dashed "Compare…" card at the end explains "⌘-click years" (non-interactive hint). Cards sit in one horizontally scrolling row. Year-end net worth comes from the same source the Dashboard/Accounts use (actual net worth at year end; forecast via the projection for the current year) — put the per-year value in a tested BudgetCore helper if it isn't already exposed.

## 2. Budget: side panel instead of the drill-down pop-up

- Clicking a non-empty cell (category, group row, section header, reserve, Year Total, multi-year year column) outlines that cell (2pt accent stroke + light accent fill) and opens a **right side panel** (slides in, ~320pt wide, resizable not required) instead of the sheet. Title: "<row name> — <Mon yyyy>" or "<row name> — <yyyy>".
- Panel content: transactions for that row and period (date, description, category name when the row is a group/section, amount, note icon), sorted by date desc, count and total; then the planned occurrences section (as in today's drill-down: expected amounts, Edit…/Remove… for unconfirmed). Each transaction has **Edit…** (existing EditTransactionSheet). Notes are shown under the description in the panel.
- Group rows and section headers aggregate their member categories; reserves show planned items only (as today).
- Clicking another cell updates the panel; ✕ or Escape closes it and clears the outline. The grid narrows while the panel is open; frozen header / pinned Year Total alignment and smooth horizontal scrolling must be preserved (scroll offset observed only by HorizontalOffsetFollower; widths by BodyWidthFollower).
- Empty open-month cells keep opening Add planned item (unchanged). The old GridDrillDownSheet is replaced by the panel (keep shared row/section views if useful).

## 3. Notes indicator on cells

A cell whose transactions include at least one with a note shows a small triangle in its top-right corner (accent/secondary colour, ~6pt). Same for group/section aggregate cells when any member transaction has a note. The panel shows the notes (§2). Computed per cell from the view model's transaction data (no extra DB reads per render).

## 4. Categories screen

- Sections **Expenses**, **Income**, **Transfers** (by category type), each listing its groups as collapsible rows "<Group> · N", then **Ungrouped · N**. Reserves (isReserved) are listed in a separate "Reserves" section, read-only here (managed on the Budget grid).
- Search field filters category and group names (case-insensitive).
- **+ Group**: creates a group and puts its name in inline edit. Group ⋯ menu: Rename (inline), Delete (confirmation; its categories become ungrouped), Add category here (New category sheet with the group preselected).
- **+ Category**: the existing New category sheet (NewCategorySheet).
- Categories: multi-select (⌘/⇧-click); drag one or several onto a group row or "Ungrouped" to move them (a group may hold categories of any type, as today); right-click menu: Move to group ▸ (list), Rename…, Exclude from auto-forecast (toggle; expenses only), Delete… (refused with a readable message when the category has transactions or planned items: "Rent has 73 transactions and 2 planned items — move or recategorise them first").
- Each category row: type icon, name, 12-month average monthly amount (actuals over the last 12 pay months; "—" when none).
- Selecting a category opens the same kind of **right side panel** with all its transactions: year filter (defaults to current year; "All years"), count and total, rows with date, description, amount, note; Edit… per transaction.
- BudgetCore (tested): `CategoryGroups.create/rename/delete(db:)` (delete ungroups members), `Categories.rename(db:id:name:)` (unique), `Categories.delete(db:id:)` (refused with a readable error when transactions or forecast entries reference it; otherwise deletes the category and the rules pointing at it), `Categories.move(db:ids:toGroupId:)`, `CategoryStats.monthlyAverage(...)`.

## 5. Accounts chart tooltip

The Accounts screen's chart shows a hover readout: a vertical rule at the hovered month and a box with the month and the value of each plotted series (same style as the Dashboard/Compare readouts), kept inside the plot area (overlay, clamped).

## Testing

BudgetCore XCTest for the new helpers (year-end net worth per year if added; category group CRUD; rename/delete/move rules; monthly average). App: build; full suite.

## 6. Transfers between your own accounts (added 2026-10-12)

User decisions: a matched pair counts **once, as sent** (the outgoing leg, in its Transfer category); pairs are **auto-matched** and the user can unlink or link manually.

- **Model:** table `transferLink` (migration appended last): `id`, `outTransactionId` (FK cascade; NOT unique — one historical monthly total can link several incoming legs), `inTransactionId` (FK cascade; unique among active links — a partial unique index `WHERE isDismissed = 0`, so a dismissed marker doesn't stop the leg being linked by hand), `origin` (`auto`/`manual`), `isDismissed` (bool — an auto link the user unlinked; kept so auto-matching never re-links it).
- **Matching** (`TransferMatcher.match(db:)`, BudgetCore, tested): over transactions not in an active or dismissed link — an outgoing transaction (amount < 0) in account A and an incoming one (amount > 0) in account B ≠ A, both among the user's accounts; same currency → equal absolute amounts; different currencies → converted with the stored exchange rate within ±3%; dates within ±3 days. **Historical spreadsheet rows** (transactions from the spreadsheet import — their batch's source file ends in `.numbers`; their description is the category name and they are monthly totals dated on payday) match differently: an outgoing historical row matches incoming transactions in one other account within the **same pay month**, either a single transaction of equal amount, or a set of incoming transactions in that account whose amounts sum exactly to it (choose the smallest such set; if more than one set qualifies, leave unmatched). Each incoming transaction joins at most one link; a bank (non-historical) outgoing transaction joins at most one link; when several candidates qualify, the closest date wins; exact ties are left unmatched. Runs after every committed import (inside the commit's write, after inserting) and once on app launch (idempotent).
- **Counting once, as sent:** the incoming leg of an active link is hidden from every budget/plan calculation: Budget grid actuals, Dashboard flows/totals, pay-month totals, plan status, history categorisation, recent categories, Uncategorized list and count, scenario comparison actuals, auto-forecast detection. Implement through one helper (`Transaction.budgetFacing` request / filter, mirroring `ForecastEntry.budget`) and use it at every such load site. **Balances and net worth are unaffected** (any balance roll-forward that uses transactions keeps using all of them).
- **Import review:** a staged incoming row that matches an existing outgoing transaction (or vice versa) shows a "↔ Transfer from <account>, <date>" badge; its category is pre-set to the other leg's category and it is Ready (source `.rule`-equivalent: new `CategorizedBy.transfer`). Staged pairs within the same file can't occur (one account per import).
- **UI:** in side panels and Edit transaction, a linked transaction shows "↔ <other account> · <date> · <amount>". Edit transaction gets **Unlink** (marks an auto link dismissed / deletes a manual one) and **Link to transfer…** (pick from candidates: opposite sign, other account, ±7 days, ±3% amount).

### External transfer categories (added 2026-10-12)

Some transfer categories move money to or from accounts that are never imported (e.g. "Transfer: Santander Patricia" — the user's wife's Santander account: the user sends money there monthly and some comes back into Lloyds International). Those must never be matched, and both directions count normally in the budget (out as spending, back as a positive amount in the same category, so the category nets them).
- `category.isExternalTransfer` (bool, default false; migration appended last; only meaningful for transfer categories). Toggle on the Categories screen (right-click / row menu on transfer categories): "Money goes to an account you don't import — never match".
- The matcher skips any transaction whose category (or, for staged rows, suggested/chosen category) is an external-transfer category, on either leg.
- One-off data step after merge (controller, with backup, user's go-ahead): set it on "Transfer: Santander Patricia".

## 7. Budget account filter (added 2026-10-12)

- A slim, collapsible **account panel** to the left of the Budget grid: "All accounts" then each account with its transaction count; multi-select (tick one or several; "All accounts" clears the selection). The choice persists while the app runs.
- With a filter: category actuals (month cells, group/section aggregates, Year Totals, multi-year columns, note indicators) use only transactions from the selected accounts; the side panel lists only those transactions and each transaction row shows its account name (account name also shown when "All accounts" is selected).
- Planned items have no account: while a filter is active, pending/expected amounts and pending icons are hidden (cells show actuals only), Add planned item on empty cells is unavailable, and a caption above the grid says "Showing actuals for <account names> only".
- Transfers: with "All accounts", linked pairs count once as sent (§6). With a filter, each selected account's own legs count (the receiving account shows the money arriving); if both legs' accounts are selected, the pair counts once as sent.
- Net worth rows / year-card values stay for all accounts (unchanged).
