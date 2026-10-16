# Phase 4 — Personal Income Imports and Self Assessment Computation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Spec:** `docs/superpowers/specs/2026-10-16-property-and-uk-tax-design.md` §0, §4 — read it first. Builds on phases 1–3. eToro/T212 deferred.

## Global Constraints
As phase 1 (scratch suffix `-p4`). Tax rules (allowances, bands, rates, thresholds) are data per tax year with sources noted; never hard-code a single year.

### Task 1: Personal income records and imports (BudgetCore)
Tables: `employment` (tax year, person, employer, PAYE ref, start/end), `employmentIncome` (pay, tax deducted, from P60 / P45 / payslips), `benefitInKind` (P11D items: type, cash equivalent), `otherIncome` (UK interest, dividends, other; future), `pensionContribution` (relief at source / net pay; future), `hmrcPayment` (date, amount, type balancing/POA/refund, document). PDF import for P60, P45, P11D: extract form fields/text (P60s may be image-only → OCR via Vision on macOS/iOS; else manual entry with document attached), user confirms; links the PDF as evidence. Tests with synthetic PDFs. Commit "Tax: employment income, benefits, HMRC payments, P60/P45/P11D import".

### Task 2: Tax rules data (BudgetCore)
`UKTaxRules` per tax year 2020/21 → 2026/27: personal allowance and taper threshold, basic/higher/additional bands and rates (England), dividend and savings allowances/rates, residential finance cost credit rate, payments-on-account threshold rules. Stored as data with source notes; tests assert published values. Commit "Tax: UK rules by year".

### Task 3: SA computation (BudgetCore)
`SelfAssessment.compute(taxYear, person)`: employment (SA102 boxes), foreign property (SA106 F4/F5 boxes incl. 14, 15, 17, 18/24, 24.1 finance costs), FTCR (SA106 F1/F6 per source, limited to UK tax on that income — compute marginal UK tax on the foreign income), SA100 summary, SA110 tax calculation (income tax by band, finance-cost credit, FTCR, tax deducted, balancing payment, payments on account for next year), every step explained. Tests: synthetic cases + structure mirroring the user's two 2024/25 SA302s shapes (high earner with PA fully tapered; basic-rate taxpayer with FTCR capped). Commit "Tax: Self Assessment computation".

### Task 4: SA outputs and filing checklist (App)
Year page tabs: Income (employment/benefits/payments with documents), Return (SA100/SA102/SA106 box values grouped like HMRC online, copy buttons), Calculation (SA110 explained), Filing (HMRC online step-by-step checklist with values; deadlines; status → filed/paid with HMRC payment records). Commit "Tax screens: Self Assessment".

### Task 5: Full regression (dry run, controller)
Extend `TaxRegression` to compare SA box values and liabilities for 2023/24 and 2024/25 with the filed SA302s (both people). 2025/26 marked ready only when regression passes and missing evidence is resolved/waived.

### Task 6: Final review, merge, push, install (controller)
