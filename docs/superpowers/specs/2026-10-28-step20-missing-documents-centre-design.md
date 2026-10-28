# Step 20: Missing documents centre — design

Status: 2026-10-28. User: "rebuild it as a centre to gather missing documents across tax and tenancy, not tied to a
tax year". Calls marked *(my call)*; written unattended. Budget ~3%.

## Behaviour
- The hidden Mac page **Missing evidence** becomes **Missing documents** and returns to the sidebar (Workflow
  section *(my call)*). The iPad's Missing evidence page uses the same model.
- One list of everything Mango expects a document for and doesn't have, from every source: tax years (evidence
  demand per open and filed year — filed years read-only), tenancy (utility bills for recharges, rent receipts,
  contract/inventory), property (insurance, council tax/IMI, mortgage statements), and waiting documents (step 9).
- Grouped by **area** (Tax · Tenancy · Property) with filters: area, tax year / calendar year, "due soon / overdue",
  and a search. Default sort: oldest due first *(my call)*.
- Each row: what's missing, period, where it's usually found (saved site if any), amount if known; icon buttons:
  **Attach file…**, **Open site** (saved site), **Not expected** (with reason; reversible in a "Not expected" panel,
  as on iPad Checks). Attaching links the document exactly as the per-year evidence page does.
- Badge count in the sidebar; the Dashboard's Tax & documents tile links here.
- The per-tax-year evidence page stays; it's this centre filtered to that year.

## Constraints
Aggregation in BudgetCore (one `MissingDocuments` query over the existing demand sources — no duplicated rules),
tested; respects access areas (members see only their areas); tenant's personal name never shown (tenancy name
only); filed years' figures unchanged; Mac fits 1100×700, names truncate in the middle, no figure wraps.
