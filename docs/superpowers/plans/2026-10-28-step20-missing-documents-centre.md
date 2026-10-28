# Step 20: Missing documents centre — plan

Spec: docs/superpowers/specs/2026-10-28-step20-missing-documents-centre-design.md

## Task 1: BudgetCore `MissingDocuments`
One query (`Sources/BudgetCore/Evidence/MissingDocuments.swift`) over the existing demand sources, no new rules:
evidence items per tax year (`TaxYearEvidence.areas`), tenancy utility payments with no invoice (`UtilityBills`,
missing-invoice stage), documents waiting for their payment (`WaitingDocuments`). Rows grouped by area (Tax,
Tenancy, Property), filters (area, tax year, calendar year, due soon / overdue, search), oldest-due-first sort,
Not expected = the evidence waiver (reversible), access areas via `TaxYearEvidence.Visibility`, filed years
read-only, tenancy rows labelled by the tenancy's name. Tests: `MissingDocumentsTests`.

## Task 2: Mac page
Sidebar item "Missing documents" (Workflow section) with a badge; filters, icon-button row actions (Attach file…,
Open site, Not expected), a Not expected panel; the Dashboard Tax & documents tile links here; the per-tax-year
evidence tab gets a link into the centre filtered to that year.

## Task 3: iPad
`PadEvidenceModel` reads through `MissingDocuments` (the year's evidence areas plus the tenancy and waiting rows);
page titled "Missing documents"; small view change (one section for the extra rows).
