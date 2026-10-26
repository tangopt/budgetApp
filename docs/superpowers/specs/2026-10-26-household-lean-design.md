# Step 7a (lean): ready for the member, and the invite — design

Builds on `2026-10-25-sharing-levels-design.md` and `2026-10-22-sync-and-access-design.md` (§6.2, §11, §12).

## Intent
Let the member join the household safely, so she can later do the tenancy work (recharges, rent receipts, property documents) on her iPad. Lean: only what joining needs; no permissions grid, widgets, notifications or quick edits.

## Decisions (user, 2026-10-26)
- The member uses an **iPad mostly**; the admin **sets it up together with her** (no remote onboarding).
- **Documents not linked to any record stay private to their owner, unless they are property documents** (property kinds, or tagged to the property) — those are household.
- Her permissions stay at the step 6 defaults: Edit for Documents, Import and Property; View elsewhere. No grid UI.

## Goals
1. **Safety list before any invite** (step 6 carry):
   - writer identity from the server (`CKRecord.lastModifiedUserRecordID` ↔ `appUser.cloudKitUserRecordName`), never the payload's claim;
   - deletions attributed and re-validated (a member delete of something she may not edit is undone);
   - backdated clocks and reused import-run tags can't widen her rights;
   - a full re-placement sweep: any record whose placement changed for any reason (a document later linked only to a private record, a pin lost, a property category moved) leaves the household — run on every push where the inputs changed, and as a gate before an invite;
   - unlinked documents placed by the rule above;
   - the Mac re-validates only on the admin's Mac;
   - an iPhone/iPad whose iCloud account changes drops the previous user's private data and viewer;
   - removing a person who owns accounts is refused with copy (no raw constraint error);
   - BBVA import tools create accounts with the creator as owner after confirmation.
2. **Invite:** Mac Settings ▸ Household (admin): add the member (name → appUser + person link), "Invite…" creates the household zone share (CKShare, zone-wide, read-write for her as a participant) and shows the share link / sends via the system share sheet. Only after the gate in goal 1 passes.
3. **Accepting on her device:** the iPhone app (running on her iPad) accepts the share, maps her iCloud user to her appUser, sets her own lock (Face ID/passcode), pulls the household zone only (plus her own private zone, empty for now), and shows what the levels allow — read-only in 7a.
4. **Leaving / removing:** the admin can remove her from the share; her devices then drop the household data.

## Non-goals
Permissions grid, iPad-native screens, member writes from the iPad (tenancy editing comes with the iPad step), widgets, notifications, quick edits, accounts on iPad.

## Constraints
Logic in BudgetCore; sealed records; nothing below Everything ever in household (tests with the member stand-in and a real CKShare flow in FakeCloud); filed SA returns never change; no personal data in the repo; never write the real DB without backup + the user's go; the real invite happens with the user present.

## Calls left to the builder (my calls)
- Her own unlinked non-property documents (later, when she can import): her private zone — symmetric with the rule above.
- The iPhone app runs on the iPad in compatibility mode until the iPad step; no universal build in 7a.
- TestFlight: the user adds her Apple Account as an internal/external tester in App Store Connect (their action).
