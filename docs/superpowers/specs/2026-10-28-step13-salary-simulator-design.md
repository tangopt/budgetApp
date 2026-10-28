# Step 13: UK take-home salary simulator — design

Status: written 2026-10-28 for an unattended run (the backlog note said "needs a design chat first"; the user asked to
run steps 11–14 unattended, so the calls below are mine, marked *(my call)*, for the user to review). Budget ~5%.

## 1. Intent

The user (backlog, 2026-10-26): "a UK take-home salary simulator based on existing UK rules, allow comparing between
2 salaries. Its own feature, available on iPad and iPhone (and Mac)." Typical use: weighing a job offer against the
current job, or a raise, in net monthly terms.

## 2. Inputs (per salary, two side by side: "Current" and "Offer" *(my call)*)

- Gross annual salary; annual bonus (taxed in the month paid; shown annualised *(my call)*).
- Tax year (current UK year by default; the next year when its rates are in the table).
- Region: England, Wales & Northern Ireland, or Scotland (income tax bands differ; NI doesn't).
- Tax code: default 1257L; free-text override (K codes and BR/D0/D1/NT supported for display, simple parsing).
- Pension: % of gross or fixed amount; method — salary sacrifice (reduces gross for tax and NI), net pay
  (reduces taxable pay, not NI), relief at source (taken from net pay, basic-rate relief added to the pot); employer
  contribution shown separately (not take-home).
- Student loan: none / Plan 1 / Plan 2 / Plan 4 / Plan 5 / Postgraduate (can combine Postgraduate with one plan).
- Benefits in kind: annual taxable value (P11D, e.g. private medical, company car) — adds to taxable pay, not cash.
- Prefill "Current" from the user's own data *(my call)*: latest payslip/P60 figures for the signed-in person
  (gross, pension, tax code) when available; the person can edit; nothing saves back.

## 3. Outputs

Per salary: take-home per year, per month (and per week *(my call)*); breakdown — income tax by band, employee NI,
student loan, pension (employee), BIK effect; personal allowance after taper (over £100k); effective rate and
marginal rate (including the 60% zone between £100k and £125,140); employer pension. Comparison column:
difference per month and per year, and "of each extra £1 gross you keep £x". A small bar chart: where the money goes.

## 4. Rules data

A versioned table in BudgetCore per tax year and region (bands, rates, personal allowance and taper, NI thresholds
and rates, student loan thresholds and rates) with the source (GOV.UK page) noted per value. Ship 2025/26 and
2026/27 *(my call)*; values the build can't verify against GOV.UK are marked "check" in the table and listed in the
step's report for the user to confirm before relying on them. Monthly payroll rounding is out of scope: annual
calculation, divided by 12 *(my call)*.

## 5. Where it lives

- iPhone: Home ▸ a "Salary" tool reachable from Settings ▸ Tools *(my call)*; iPad: sidebar "Everything else ▸
  Salary simulator"; Mac: a "Salary simulator" item in the sidebar's tools group (next to Forecast) *(my call)*.
- Inputs saved per device as drafts (not synced; personal) *(my call)* so a comparison survives relaunch.

## 6. Constraints

Logic and rules in BudgetCore (pure, heavily unit-tested against worked examples from GOV.UK and HMRC's own
calculators — at least 12 cases across regions, pension methods, the taper, student loans and Scotland); thin views
on all three platforms; no figure wraps; names truncate in the middle; nothing synced; no effect on budget or tax
figures (step 14 links it to Forecast). Not tax advice: a one-line note says it's an estimate.

## 7. Non-goals

Self-employment, dividends, savings interest, marriage allowance, child benefit charge *(my call: listed as future
options)*; payroll-exact monthly figures.
