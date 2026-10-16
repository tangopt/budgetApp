# Phase 3 — Tax Years, Attribution Rules, Rental Accounts, Accountant Template — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Spec:** `docs/superpowers/specs/2026-10-16-property-and-uk-tax-design.md` §0, §2, §4, §6.2 — read it first. Builds on phases 1–2.

## Global Constraints
As phase 1 (scratch suffix `-p3`). Regression data (personal) lives in `~/Documents/Personal/Documentos/Tax/_app-import/history.csv` and the filed packs; tests use synthetic fixtures; regression checks run as a one-off tool on a DB copy, never committed with real figures.

### Task 1: Tax year model and settings (BudgetCore)
Tables: `taxYear` (UK year start e.g. 2024 = 2024/25, person, status preparing/ready/filed/paid, HMRC average rates per currency (EUR, USD later), notes), `taxYearSplit` (tax year, person, property, expense type → share %, default from ownership; history can differ), `taxAttributionRule` (expense type → rule: byRentPeriod, byDebitMonth, byQuotaMonth, apportionByCover, previousCalendarYear, byDate; per tax year override), `taxManualItem` (tax year, person, kind e.g. accountancy GBP / postage / other, amount + currency, document links), `hmrcRate` (year, currency, average rate, source, fetchedAt). Expense types map from the property's categories (Rental income, Mortgage interest, Condomínio → service charge, Building/Contents insurance, IMI → council tax, PT accountant / UK accountant → accountancy, Legal fees, Repairs, Other, Utilities). Seed rules from the workbook. HMRC rates: prefill 2020/21–2024/25 from filed returns' implied rates (data from the user's files, entered by the data step), API to set/fetch (HMRC exchange-rate publication; manual override). Commit "Tax: years, splits, attribution rules, HMRC rates".

### Task 2: Rental accounts engine (BudgetCore)
`RentalAccounts.compute(taxYear, person, property)` → lines (rent by month Apr–Mar from rent receipts by rent period; expenses per type via the attribution rule from transactions (insurance apportioned by cover months from linked documents' periods or the transaction note; IMI = previous calendar year's IMI; service charge by quota months; mortgage interest = Mortgage interest rows by instalment month); manual items; split per taxYearSplit), each line with its sources (transaction ids / receipt ids / manual items) and rule explanation; totals in EUR and GBP at the year's HMRC rate; GBP-native items separate; finance costs (mortgage interest) reported separately for the residential finance cost relief; FTCR input: PT tax for calendar year N (from PT tax transactions + documents) per person. Tests with synthetic data for every rule. Commit "Tax: rental accounts engine".

### Task 3: Accountant template export (BudgetCore + App)
Write the accountant's .xlsx template (per person) — sheets "Rental accounts – yyyy.yy" and "Other information" — reproducing the layout of `Template - 2024.25 - <person>.xlsx` (read the real template's structure read-only from `~/Documents/Personal/Documentos/Tax/IRS UK/SA 2024:25/` to mirror cell positions; never commit it). Use an XLSX writer that works on iOS (or write the minimal OOXML ourselves). Plus a rental-accounts PDF summary. Commit "Tax: accountant template export".

### Task 4: Tax UI (App)
Sidebar "Tax" → tax years list (per person, status, deadlines) → year page: Rental accounts (lines with drill-down to transactions/receipts/documents, rule explanations, EUR/GBP), Settings (HMRC rate, splits, rules), Manual items, Missing evidence (phase 1 view filtered to the year), Export (accountant template, rental accounts PDF, evidence pack folder/zip). Commit "Tax screens: years and rental accounts".

### Task 5: Regression tool (dry run, controller)
One-off `TaxRegression <db copy> --history <history.csv>`: computes rental accounts for 2023/24 and 2024/25 (both people) from the stored records + entered settings (splits as reported, HMRC rates) and compares line by line with the filed figures; reports differences and their causes (e.g. records not yet in the app: rent receipts/evidence, pre-2023 transactions). Only on a copy.

### Task 6: Final review, merge, push, install (controller)
