# Step 12: Mac Dashboard review — design

Status: written 2026-10-27 for an unattended run (user: "continue steps 11 through 14 unattended"). The original
request (2026-10-24) said "proposal first, user decides"; running unattended, this document is the proposal AND the
build, with every addition removable from Settings so the user decides by keeping or hiding *(my call)*. Budget ~3%.

## 1. Intent

The Dashboard predates property, tax, evidence, documents and the iPad routine. Review it and add the components
worth a glance on the Mac's landing page, without making it busier than it needs to be.

## 2. Review of what's there (keep / change)

Keep: data freshness + import launcher, net worth since 2020 with forecast, YoY bars, current month, year at a
glance, top categories, needs attention, upcoming bills, accounts. Change *(my calls)*: "Needs attention" absorbs
the new property/tax/evidence signals (one list, not new cards each); data freshness shows "N waiting for the Mac
to import" (files sent from the iPad) with an Import button.

## 3. New components (each a card; Settings ▸ Appearance ▸ Dashboard cards: show/hide each)

1. **Tax year position** — current UK tax year: estimated tax due / refund per person, payments on account due next
   (date, amount), status (Not filed / Filed / Paid), link to Tax years.
2. **Property month** — for each tenancy (tenancy name, never the tenant's name): This-month checklist progress
   (N of 4), rent this month (received / late), recharge statement status, link to Recharges.
3. **Evidence and documents** — missing evidence count for the current tax year (tax items only), documents
   waiting for their payment (step 9), documents linked automatically since the last visit (with a link to
   Documents).
4. **Mortgage** — outstanding balance, next instalment (date, amount), rate and next review date.
Order on the page *(my call)*: freshness → current month → tax year position → property month → evidence and
documents → net worth → the rest as today; mortgage after accounts.

## 4. Constraints

Logic in BudgetCore read models (reuse TaxYear figures, ThisMonthChecklist, MissingEvidence tax-figures filter,
WaitingDocuments, mortgage models); the view only renders. Fits 1100×700 with vertical scroll; no figure wraps;
names truncate in the middle; no edits on the Dashboard except links and the import button. Card visibility is a
per-device setting (not synced). Tenant names never shown.

## 5. Non-goals

iPhone/iPad dashboard changes; new charts beyond what exists; widget redesign (step 18).
