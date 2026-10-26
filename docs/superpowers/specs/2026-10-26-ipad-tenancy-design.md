# Step 8 (lean): iPad screens, tenancy first — design

Builds on `2026-10-26-household-lean-design.md` (7a), `2026-10-25-sharing-levels-design.md` and the step 4 iPhone app.

## Intent
The member (Patricia) does the tenancy work on her iPad: utility bills, recharges, rent receipts, documents. The admin uses the same iPad app on his own iPad with everything his rights allow.

## Decisions (user, 2026-10-26)
- The member **can make changes on the iPad** within her permissions (Edit: Documents, Import, Property; View elsewhere). The household share becomes read-write for her; the admin's Mac re-validates every change and reverts anything outside her permissions (7a machinery).
- 7b (permissions grid, quick edits, widgets, notifications) is not a prerequisite.
- Bill stages: invoice in → linked to payment → in recharge (prep done) → sent to tenant → paid by tenant.

## Goals
1. A real iPad app: the MangoPhone target becomes universal (iPhone + iPad); on iPad a sidebar layout (NavigationSplitView), the iPhone keeps its tabs.
2. iPad screens: Property (Overview, Bills, Recharges, Rent receipts, Tenancies), Documents (library, preview/Quick Look, link/unlink, change kind), Missing evidence (with the side panel). Reuse BudgetCore read models built for the Mac (UtilityBills, MissingEvidenceDetail, TransactionDocuments, Recharges…).
3. Writes from iPad: the phone/iPad engine gains a writer mode (today read-only) — only on devices whose user has Edit on an area; every write through ActorWrite with the right area/origin; pushes to the household zone (member) or own zones (admin). The admin's Mac re-validates as built in 7a.
4. The share's participant permission becomes read-write (CloudKit), still gated by the invite audit; FakeCloud enforces the same.
5. Filed-year protection on the iPad: the same FiledYearEditCheck/EvidenceLinkGuard refusals, shown inline.
6. Fits iPad sizes (11" and 13", portrait and landscape) with no figure wraps/truncation; iPhone unchanged.

## Non-goals
Importing documents on the iPad (original step 10 — separate), categorisation screens beyond what the tenancy needs, Budget/Forecast/Tax editing on iPad, widgets/notifications.

## Constraints
Logic in BudgetCore; sealed records; privacy rules of steps 6–7a unchanged (nothing below Everything to household); filed SA returns never change; synthetic data in tests; real sync is live on the admin's devices — the iPhone/iPad builds must keep working for the admin.
