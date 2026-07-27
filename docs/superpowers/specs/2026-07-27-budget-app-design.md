# Budget App — Design Spec

Date: 2026-07-27

## Background

The user currently tracks their personal budget in a Numbers spreadsheet
(`Budget copy.numbers`). Its "Budget" sheet holds a category × month grid
(2020–2026), where every cell is a literal arithmetic formula
(e.g. `3.3+3.88+9+9.99+3.3+15.83+3.88+28.77`) built by manually appending
`+amount` for every transaction as the user works through a bank statement.
Categories are grouped into scheduled/recurring expenses, unscheduled/variable
expenses, transfers/investments, and income, with per-category billing-day
hints (e.g. Rent billed on the 14th, Income paid on the 26th). A separate
"Yearly Tracker" sheet projects long-term net worth by age/year.

Goal: replace the manual transaction-entry workflow with a native macOS app
that ingests bank statements (CSV and PDF), categorizes each transaction
automatically, tracks budgets across pay-to-pay periods (not calendar
months), forecasts future spending with adjustable assumptions, and tracks
net worth across multiple cash/investment accounts in GBP and EUR.

## Scope (v1)

In scope:
- CSV and PDF bank statement import, multiple UK banks/cards
- Hybrid categorization (rule engine + Claude API fallback), with a review
  step before anything commits
- Duplicate detection across overlapping statement imports
- Pay-period detection (payday to payday, not calendar month)
- Forecasting: trend-based default forecast + manual adjustment, using
  recurrence rules (frequency) rather than one-off per-period numbers
- Hypothetical planning via group/entry enable-toggles and a
  confirmed-forecast vs. preview-forecast comparison (no named scenario
  branches)
- Net worth tracking across multiple accounts (cash, credit, investment),
  GBP and EUR, with manual EUR→GBP rate
- CSV export of the category × period grid for backup/reference

Out of scope (not ruled out for later, just not v1):
- Writing back into the original Numbers file
- Automatic transfer-pair matching between two tracked accounts
- Live/automatic currency rate fetching
- Multi-user support

## Architecture

Native macOS app (SwiftUI) with an internal Swift package, `BudgetCore`,
holding all non-UI logic — parsing, categorization, forecasting, persistence
— so it is testable independent of the UI layer.

Persistence: **GRDB** (SQLite) rather than SwiftData/Core Data. The core
views this app needs (category × period aggregation, confirmed-vs-preview
forecast comparison) are fundamentally SQL aggregation queries, and GRDB
gives direct, easily-tested SQL for that.

## Data model

### Categorization

- **Category** — `id`, `name`, `type` (`expense` / `transfer` / `income`).
  Seeded from the existing spreadsheet's ~45 categories. Flat and consistent
  — no fixed/variable distinction lives here; that's a forecasting concern
  (see Forecasting below).
- **Account** — a bank/card source. See Accounts & net worth below (the
  same entity serves both transaction import and net-worth tracking).
- **ImportProfile** — one per account+format. For CSV: column mapping
  (which column is date/description/amount/direction, date format,
  delimiter). For PDF: the layout-parsing config for that bank. Created via
  a short one-time wizard the first time a new source is imported, reused
  after that.
- **ImportBatch** — one row per imported file (source file name, account,
  timestamp), so an import can be reviewed/undone as a unit.
- **Transaction** — `date`, `rawDescription`, `amount`, `accountId`,
  `categoryId` (nullable until categorized), `status`
  (`pendingReview` / `confirmed`), `categorizedBy` (`rule` / `llm` /
  `manual`), `fingerprint` (hash of account + date + amount + normalized
  description, used for duplicate detection).
- **Rule** — `matchPattern` (substring or regex), `matchType`, `categoryId`,
  `priority`. Created/updated automatically whenever a transaction's
  suggested category is manually corrected during review; editable directly
  as a settings list.

### Pay periods

- **PayPeriod** — `startDate`, `endDate`, `type` (`actual` — anchored on a
  detected real income transaction — or `projected` — extrapolated forward
  from the known payday cadence). Detection: scan confirmed `income`-type
  transactions for a recurring pattern (similar amount within tolerance,
  landing every ~28–31 days); each becomes the start of an `actual` period.
  The very first period, before enough history exists, is confirmed
  manually as a one-time bootstrap. Projected periods extrapolate the same
  day-of-month (or weekday, if the real pattern shows bank-holiday/weekend
  shifting) forward to the forecast horizon.

### Forecasting

- **ForecastGroup** — `id`, `name`, `note`, `isEnabled`. A named bundle of
  forecast entries (e.g. "Detected recurring bills" — system-managed — or
  user-created ones like "New car"). Disabling a group cascades to hide all
  its entries regardless of their individual toggle.
- **ForecastEntry** — `id`, `groupId`, `categoryId`, `amount`, `frequency`
  (`once` / `weekly` / `monthly` / `annually`), `interval` (integer,
  defaults to 1 — e.g. `frequency: weekly, interval: 2` = every 2 weeks,
  `frequency: monthly, interval: 3` = every 3 months), `startDate`,
  `endDate?`, `isEnabled`, `status`
  (`auto` / `manual` / `hypothetical` / `confirmed`), `note`. One entry
  represents a recurring forecast rule, not a single period's number — it
  expands into whichever pay periods it applies to based on its frequency
  and interval, computed on demand.

Default forecast generation: for each `expense`/`transfer` category, detect
whether its transaction history is near-identical in amount and interval
(→ `auto` entry, frequency matched to the detected cadence, amount = last
actual) or variable (→ `auto` entry using a rolling average of recent
periods). Editing an auto entry's amount/frequency flips its status to
`manual`.

**No named scenario branches.** Instead, two totals are always computed per
category/period from the same entry set:
- **Confirmed forecast** (the real baseline) = enabled entries with status
  `auto`, `manual`, or `confirmed`.
- **Forecast (preview)** = Confirmed forecast **+** any currently-enabled
  `hypothetical` entries/groups.

Toggling a hypothetical group or entry on/off changes the preview total
live. "Confirming" a hypothetical entry/group flips its status to
`confirmed`, folding it into the Confirmed forecast permanently (reversible
by flipping back to `hypothetical`). A comparison panel shows Confirmed vs.
Preview side by side, per category and as totals, for periods still ahead —
this is how the user plays out "what if" planning without persisted
scenario branches.

Forecast horizon: projected periods generate through the end of the current
calendar year by default, with an in-app action to extend through next
year.

### Accounts & net worth

- **Account** — `id`, `name`, `currency` (GBP/EUR), `kind`
  (`cash` / `credit` / `investment`), `trackingMode`
  (`imported` — has a transaction ledger; v1 covers exactly two such
  accounts, the user's Lloyds current account and their AMEX credit card —
  or `manual` — balance/valuation entered by the user when they check it;
  everything else: ISAs, investment accounts, EUR accounts, savings).
- **BalanceSnapshot** — `id`, `accountId`, `date`, `balance` (native
  currency), `note`. For `manual` accounts this is simply what the user
  enters each time they check. For `imported` accounts, a snapshot acts as
  a reconciliation anchor: running balance = latest snapshot + transactions
  since. If the computed running balance ever drifts from the account's
  actual balance, that's surfaced as a warning (signals a missing or
  duplicate transaction) rather than auto-corrected.
- **ExchangeRate** — a single current EUR→GBP rate, manually entered and
  updated by the user (matches the spreadsheet's existing "Current EUR to
  GBP Rate" cell), used to convert EUR balances into the GBP net worth
  total. No historical rate tracking, no external API, in v1.

AMEX handling: AMEX's own imported transactions carry the real expense
categories; the Lloyds-side payment that settles the card each period is
categorized as a `transfer`, so spending is not double-counted. AMEX's own
balance is tracked as a liability (subtracts from net worth), not an asset.
No automatic transfer-pair matching between accounts in v1 — transfers are
tracked independently on each side, entered/updated as the user checks each
account.

Net worth view: accounts grouped by kind, each showing native balance and
GBP-converted value, rolling up to a single Net Worth figure, with a
history chart built from `BalanceSnapshot` entries over time.

## Import pipeline & categorization flow

1. Pick a file (CSV or PDF).
2. **CSV**: detect if the header row matches a known `ImportProfile`
   (by account + headers); if not, a short mapping wizard has the user
   click which column is date/description/amount/direction once, then
   saves the profile for reuse.
3. **PDF**: `PDFKit` extracts text per page; a layout parser (matched to a
   profile the same way as CSV) splits it into transaction lines using
   that bank's known pattern. Lines that can't be confidently parsed are
   surfaced in review as "couldn't auto-parse — enter manually" rather than
   silently dropped.
4. Both paths converge into normalized transaction records → fingerprint
   check against existing transactions for that account (duplicates are
   collapsed into a dismissible "skipped duplicates" list, force-importable
   if a genuine legitimate collision) → categorization.
5. Categorization: try `Rule` matches first, ordered by specificity/
   priority. Unmatched descriptions are sent to Claude (transaction
   description + category list) for a suggested category. If the API is
   unreachable or unconfigured, the transaction falls to "Uncategorized"
   for manual assignment — import never blocks on it.
6. Everything lands in a staged review list (suggested category,
   confidence, source: rule/llm/manual) for the user to bulk-confirm
   high-confidence matches and correct the rest — corrections
   create/update a `Rule`. Nothing is committed to the budget until
   reviewed.

## Views

- **Budget/forecast grid** — rows = categories (grouped Expenses /
  Transfers / Income), columns = pay periods (past = actuals, future =
  forecast). Tapping an actual cell drills into its transactions; tapping a
  forecast cell shows the `ForecastEntry` producing it.
- **Period summary** — Income, Total Expenses, Total Transfers, Money
  Remaining (Income − Expenses − Transfers) per period, using actuals where
  available and forecast otherwise.
- **Comparison panel** — Confirmed forecast vs. Preview forecast, per
  category and as totals, for future periods, with live group/entry
  toggles.
- **Review screen** — staged transactions from the current import, with
  bulk-confirm and inline category correction.
- **Net worth view** — accounts by kind, native + GBP-converted balances,
  total net worth, history chart from balance snapshots.
- **Export** — CSV export of the category × period actuals grid.

## Error handling

- Unparseable CSV/PDF rows → flagged for manual entry, never silently
  dropped.
- Duplicate transactions → caught by fingerprint, shown as a dismissible,
  expandable list; force-importable if needed.
- Claude API unreachable/unconfigured → falls to "Uncategorized," import
  proceeds.
- Unknown bank format → mapping/layout wizard triggers instead of failing.
- Reconciliation drift (computed balance ≠ actual entered balance) →
  surfaced as a warning on the account, not auto-corrected.

## Testing

`BudgetCore` unit tests (no UI dependency):
- Rule-matching engine
- CSV column-mapping parser
- PDF line-parsing per bank profile, against redacted fixture files
- Fingerprint/duplicate detection
- Payday-cadence detection, including edge cases (bank-holiday shifts,
  missed periods, insufficient history)
- Forecast-frequency expansion (`once`/`weekly`/`monthly`/`annually` with
  varying `interval` values, mapped onto period date ranges)
- Confirmed-vs-preview forecast computation

Manual verification pass on the review UI and PDF import specifically,
since layout parsing is heuristic and needs iteration against real
(anonymized) statements.
