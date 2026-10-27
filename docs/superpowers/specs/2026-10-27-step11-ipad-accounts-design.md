# Step 11: Accounts on the iPad — design

Status: written 2026-10-27 for an unattended run (user, 2026-10-27: "continue steps 11 through 14 unattended").
Calls marked *(my call)* are for the user to review later. Budget ~3%.

Sources: `2026-10-22-ipad-app-design.md` ("Your own accounts can be added and edited on the iPad", sync spec §3.1,
"a private account never needs the Mac for routine use"), `2026-10-25-sharing-levels-design.md` (levels, owner rule),
step 10's iPad patterns (sidebar, document panel, button/icon system, DeviceWriter, inline refusals).

## 1. Intent

Each person can look after their own accounts from the iPad: see balances and history, add an account, edit its
details, set its sharing level, and update a manual balance — without the Mac. Statement import on the iPad is step
19 (shared import lease); until then the account screen offers "Fetch statement" (built-in browser, the bank's saved
site) whose PDF is handed to the Mac to import, as step 10 does.

## 2. Scope

- **Sidebar:** a new "Accounts" item under "Everything else" *(my call: not a top-level group)*.
- **Accounts list:** grouped as on the Mac (current, savings, credit, loans, investments, property), each row with
  name (middle-truncated), owner badge (yours / joint / other person's at its level), balance in its currency and
  GBP, last import date. Net worth total at the top. What the viewer can't see in full shows as on the iPhone
  (summary rows / balance only), never more.
- **Account detail (right panel or pushed page):** balance history chart, recent transactions (tap → transaction
  sheet with document panel), details (bank, number masked, currency, kind, tracking manual/statements), sharing
  level (owner only; the owner rule: nobody sets a level on someone else's account), "Update balance" for manual
  accounts (the 7b quick edit), "Fetch statement" (opens the saved bank site; the PDF goes through the tray and is
  sent to the Mac's waiting list).
- **Add account:** form sheet (name, kind, currency, bank, owner = me or joint *(my call: joint needs the admin's
  Mac? no — the admin's iPad can add joint; a member can add only her own)*, opening balance + date), Save only.
- **Edit details / archive:** Save-only form; archive instead of delete on the iPad *(my call: deleting accounts
  stays on the Mac)*.
- Writes through `DeviceWriter.writeCheckingFiledYears` (Budget & accounts area; sharing-level changes are
  owner-only per AccessAreaMap); inline refusals; the Mac re-validates.

## 3. Constraints

Logic in BudgetCore (reuse the Mac's account models, AccountsViewModel logic moved to BudgetCore where needed, the
iPhone's AccountsViewModel in MangoUI); fits 11"/13" portrait and landscape; no figure wraps; names truncate in the
middle; Save-only edits; filed SA years never change; private accounts never leak to the other person; tenant names
not shown. No new CloudKit record types.

## 4. Non-goals

Statement import on the iPad (step 19); rules/categories editing; account deletion on the iPad; reconciliation.
