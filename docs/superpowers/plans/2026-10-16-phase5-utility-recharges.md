# Phase 5 — Tenant Utility Recharges — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Spec:** `docs/superpowers/specs/2026-10-16-property-and-uk-tax-design.md` §6.4, §8 — read it first. Builds on phases 1–2.

## Global Constraints
As phase 1 (scratch suffix `-p5`). The user's tracker `~/Documents/Personal/Casa/Lisboa/Aluguer/4to Aluguer/Despesas/Despesas-novo.numbers` and invoices are read-only references.

### Task 1: Recharge model and rules (BudgetCore)
Tables: `utilityProvider` (name, kind electricity/gas/water, account/contract ref, BBVA description pattern), `utilityInvoice` (provider, invoice no., period start/end, issue date, amount, document, linked BBVA debit), `rechargeStatement` (tenancy, month, total, status draft/sent/paid, sentAt, paid-by credit link), `rechargeLine` (statement, invoice, amount). Rules: each month's statement includes invoices issued (or debited) since the last statement; the tenant's next transfer pays rent + recharge → split the credit into rent (receipt) + recharge (statement), netting recharges against Utilities in the property view and tax. Study the tracker read-only to mirror the user's current calculation (report it). Commit "Recharges: providers, invoices, monthly statements".

### Task 2: Invoice intake (BudgetCore + App)
Add utility invoices (drag & drop / from the Lisboa folder scan): extract provider, invoice no., period, amount (phase 1 analyzer + provider rules), match to the BBVA debit, attach as evidence. Missing-evidence rule: one invoice per utility debit. Commit "Recharges: invoice intake and matching".

### Task 3: Monthly statement and email draft (App)
Recharges screen per tenancy: months list with status; build the month's statement (lines, total, attachments); "Prepare email" opens a draft in Mail (NSSharingService / mailto with attachments via NSSharingService composeEmail) addressed to the tenant with the agreed text (Portuguese/English template), the statement summary and invoice PDFs attached; mark sent; when the next tenant credit arrives, propose the rent/recharge split and mark paid. Commit "Recharges: monthly statement and email".

### Task 4: History backfill (dry run, controller)
One-off tool to build past statements from the tracker + invoices + BBVA debits/credits since 2023 (dry run on a copy; real run waits for the user's go).

### Task 5: Final review, merge, push, install (controller)
