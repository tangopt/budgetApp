# Step 6: Sharing levels and private zones — design

Builds on `2026-10-22-sync-and-access-design.md` §6 (access control), §4 (records and zones) and §3.1
(two people on one Mac). This document records what changed since then and what step 6 builds.

## 1. Intent

Before anyone else joins the household, every account must already know who owns it and how much of it
the other person may see, so private data is never shared, not even once. The member will join later
(step 7) and use an iPad mainly to import documents and do the tenancy recharges. The user wants
individual transactions private by default, net worth visible, and to open individual accounts up one
by one.

## 2. Decisions (user, 2026-10-25)

- **Default level for the user's personal accounts: Balance only** (was Category totals in the 22 October
  spec). The member sees balances and net worth, no transactions and no category totals.
- **Levels are per account,** changed only by the account's owner, at any time, from Settings ▸ Sharing.
- **Lisbon property bank account:** owned by the user (not joint) but starts at **Everything**, so the member can do
  the recharges.
- **Ownership:** every account is the user's, except one joint account (both people), which the user marks in the app.
  Joint accounts can only be Everything.
- **Property accounts and tax years start at Everything** (22 October, unchanged). The per-person area
  "tax years and income" (tax years, employment and payroll documents, HMRC pages) is at Everything for
  both people: taxes transparent.
- **The member's permissions (Layer 2):** Edit for Documents, Import and Property; View everywhere else
  (Budget & accounts, Forecast, Tax, Rules & categories, Household settings). The user (admin): Edit
  everywhere. "Nothing else for now."
- **The user will also use the iPad app on their own iPad:** the iPad build (step 8) keeps full features
  for the admin; permissions only hide or disable for the member.
- **Adding accounts on the iPad** (so the member can bring their own accounts, set their level and import
  their statements there) is a **new step after iPad import**. Not in step 6.

## 3. Goals

1. `account.ownerPersonId` (NULL = joint) on every account, set once on the Mac.
2. A sharing level per account and per person's "tax years and income" area, with the defaults above.
3. Records of an account below Everything live only in the owner's `private-<person>` zone; the
   household zone gets only the summaries the level allows (`accountBalancePoint` for Balance only and
   Category totals; `accountSummaryMonth` for Category totals), rebuilt deterministically by the owner's
   devices.
4. Changing a level moves records between zones, with the warning that lowering can't recall what the
   other person may already have.
5. `memberPermission` with the defaults above, `AccessPolicy.can(user, action, area)`, every write path
   taking an actor and checking it, and the Mac reverting incoming changes made without permission.
6. Settings ▸ Sharing on the Mac and the iPhone (own accounts with a level picker each, plus "My tax years
   and income"); lock badges on accounts below Everything; summary rows for the other person's private
   accounts in the budget drill-down and in net worth.

## 4. Non-goals

- Invites, member onboarding and the permissions grid UI (step 7). Step 6 stores the defaults and enforces
  them; the grid to change them comes with invites.
- The iPad app (step 8), iPad import (step 10), adding accounts on the iPad (new step).
- Cryptographic enforcement of Layer 2 permissions (honest limit, 22 October spec §6.2).
- Turning on real sync. That still needs its own explicit go (and the Production schema deploy).

## 5. Anti-goals

- Any record of an account below Everything ever written to the household zone, even transiently, even
  in a failed or retried batch.
- A level change that silently drops or duplicates records, or leaves a stale copy readable in the
  household zone.
- A member change that edits filed tax years (all existing filed-year guards still apply to every actor).
- Personal data in the repo: account names and the ownership mapping are entered in the app, never in
  code, tests or docs.

## 6. Constraints

- Logic in BudgetCore; Mac and iPhone share it. Records stay sealed (R15, exactly `sealed` + `keyId`);
  the private zone uses its own key (only the owner's devices hold it).
- Sync schema version bump with re-pin; migrations idempotent; timestamped backup before any real-DB
  write; the user's go before applying anything to the real database.
- Two people on one Mac (§3.1): the member's private zone is never fetched by the admin's macOS user.
- UI house rules: no figure wraps or truncates at 1100×700; edits save only on Save.

## 7. Ownership set-up (my call)

A one-time "Who owns each account?" sheet on the Mac (Settings ▸ Sharing, admin only, before any level
can be set): every account listed with Owner = the admin by default and a Joint option; Save writes
`ownerPersonId` and the default levels in one transaction. The user marks the joint account there.
Property-linked accounts default to Everything; the Lisbon property bank account is raised to Everything by the
user in the same sheet (the sheet shows each account's starting level and lets the owner change it before
saving). The member's person row already exists (tax); her accounts don't exist yet.

## 8. Testing without a second person (my call)

There's no member device yet. The sync tests use FakeCloud with two simulated users (admin and member,
each with their own private zone and key) to prove: what the member can fetch at each level, summaries
only, level changes moving records both ways, member writes reverted without permission, and nothing
below Everything ever in the household zone (an assertion over every batch).

## 9. Left to the builder

- Exact table/column names beyond `ownerPersonId`, `memberPermission`, `accountSummaryMonth`,
  `accountBalancePoint`; where the per-person area level is stored.
- How the existing write paths receive the actor (one `Actor` passed through BudgetCore services).
- Summary rebuild triggers and batching.
- The lock badge and summary-row design, matching the existing account rows.

## 10. Answers after the builder check (2026-10-25)

- **Property money in private accounts (user: option a):** transactions in property categories (and the
  property/tax rows that point at them: receipts, invoices, recharge and rent-receipt payments, tax owner
  and not-claimed marks) are always shared, even from an account below Everything. Nothing else from that
  account is shared. Every device therefore computes the same rental and Self Assessment figures.
- **Which permission an incoming change needs (my call):** by origin, not by table. Rows written by an
  import batch count as Import; recharge, rent-receipt and invoice matching count as Property; document
  links count as Documents. The member may set category and notes on transactions of Everything property
  accounts and on property-category transactions; any other transaction edit needs Budget & accounts. Each
  change carries its origin so the Mac's re-validation can judge it.
- **iPhone (my call):** shows the levels read-only in step 6 (it doesn't write yet); levels are changed on
  the Mac.
- **Balance only (my call):** publishes the balance at each pay-month end plus the current balance, never
  daily balances.
- **What a private account shows the other person (my call):** a household stub with name, bank and type;
  account numbers, IBAN, sort code, statement-check columns, import profiles, the import change log, and
  forecast/plan entries for that account stay in the owner's private zone. Transfers between a private and
  a shared account show on the shared side only.
- **Tax years and income (my call):** Everything or Hidden only; both start at Everything; the code that
  moves records when it's lowered is deferred until someone asks for it (the picker shows Hidden as "not
  available yet").
- **Real sync for the real database (user, 2026-10-25: "do an iPhone build with my real data"):** step 6
  ends with the Mac's "Turn on sync" (sync spec §8 migration: timestamped backup, ownership sheet, levels,
  upload to Production, records sealed and placed in the right zone from the first upload). It needs the
  Production schema deployed by the user in the CloudKit Console, and the user's go at the moment of the
  first upload. Then a TestFlight build lets the iPhone pull the real data.
