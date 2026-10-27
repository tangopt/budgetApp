# iPad property redesign (step 10, absorbs "import on iPad") — design

Status: agreed with the user 2026-10-27 through two rounds of mockups and three revision passes.
Mockups (private to the user): https://claude.ai/artifact/LYkavz9HeMh59PvtCojPNh — boards 1–11. The mockups
are the reference for layout; this document is the reference for behaviour. Figures and names in the mockups
are invented.

Builds on: step 8 (`2026-10-26-ipad-tenancy-design.md`: DeviceWriter, inline refusals, the Mac re-validates),
7b (quick edits, permissions grid), the Mac Recharges tab with the bills tracker merged in (5918d09, dfe2d85).

## 1. Intent

The iPad is where the member (Patricia) runs the flat's month and gathers the tax year's evidence. Today the
iPad property screens are a thin subset of the Mac's and not useful. The user wants:
- **The monthly routine automated as far as possible** (user, 2026-10-27): check last month's recharge was paid
  (BBVA), fetch this month's utility bills from the providers' websites, get the charges into the bills grid,
  prepare and send the tenant's email.
- **Every Mac property feature on the iPad**, redesigned to be simpler and touch-first, not shrunk Mac screens.
- **One consistent way to fetch documents from websites**, because most documents come from websites
  (utility providers, BBVA, Portal das Finanças, HMRC…).
- **Evidence for the whole tax year**, gathered through the year on the iPad.

## 2. The user's decisions (2026-10-27)

1. **This month** is a new first Property screen: a four-step checklist for the selected tenancy —
   (1) last month's recharge paid (BBVA statement fetched, tenant transfer matched; confirm when not exact),
   (2) this month's bills (per provider: fetched/checked/missing, with Open site or Check),
   (3) charges in the bills grid (automatic once bills are checked),
   (4) email the tenant (statement built from the bills, drafted email with PDFs; she reads, sends, it's marked
   sent). Side column: this month's other items (rent receipt, condomínio), evidence count, downloads waiting.
2. **Fetch from a website**: a built-in browser with a strip of saved sites (BBVA, each utility provider,
   Portal das Finanças, condomínio, "+ Add site"). Sign-in uses the **Passwords app** (AutoFill, Face ID);
   Mango never sees or stores passwords. **Every PDF downloaded there lands in a Downloads tray**, not in Files.
   BBVA statements can be fetched this way too.
3. **Nothing goes in unchecked**: each download is checked and linked like any import on the Mac — kind,
   provider, property, period, amount, dates (fields read from the PDF are marked "read"), the matching payment
   ("Paid by", suggested, changeable), and for utility bills the tenant's share and the recharge statement it
   joins. Saves only on Save. A BBVA statement in the tray goes through statement import. This replaces the
   old step 10 "import on the iPad".
4. **Bills & recharges is one screen** (as on the Mac): the provider × month bills grid coloured by stage
   (expected · invoice in · linked to payment · in a statement · sent · paid by tenant), and the statements list
   below with "Prepare email" on the draft. Tapping a bill opens the document panel.
5. **All other Property pages stay and are redesigned**: Tenancies, Money, Calendar, Checks, Profile — every
   Mac capability kept (secondary actions in panels or a More menu). Specifics:
   - Tenancies: tenancy details, rent receipts by month; the selected receipt in the document panel with one
     line "Rent paid: tenant transfer of €X on <date> · BBVA · Change" (no separate Receipt PDF or Paid-by
     panes). "Fetch from Portal das Finanças" opens the built-in browser.
   - Checks: per recurring cost "Not expected any more" with Undo — no separate "not expected" list.
   - Calendar: agenda of the next 12 months plus a small month grid (new on iPad; the Mac has no month view).
   - Money: month list → transaction in the document panel; charges and the full figures table reachable.
6. **Evidence is the tax year's**, not the flat's: a tax-year switch, items grouped by area (employment &
   income, UK tax, pension & gifts, the Lisbon flat — rent receipts, IMI, condomínio, insurance, repairs), each
   with why it's needed, Open site (built-in browser) and Link existing document. **Utility bills are not
   evidence**: they belong only to Bills & recharges. Evidence sits under "Everything else", not Property.
7. **One document panel everywhere** a document appears (Bills, Money, Tenancies, Evidence, Documents):
   right side, ~380 pt; header with close; thumbnail; "Open full view" and "Download/Share"; details (Kind,
   From, Period, Amount, Date, Linked to); then any screen-specific block. **Open full view** is a modal with
   the full document, pages, zoom, Share/Download and Show details.
8. **Sidebar**: Mango glyph (the fruit drawing, not the app icon) at the top; collapsible to an icon rail;
   footer with the user's avatar and name only (no access level), sync status ("Synced 2 min ago" /
   "N changes waiting"), and Settings.
9. **Buttons**: one system — primary, secondary, text link, destructive, small. **Actions inside list rows are
   icon buttons** with a fixed vocabulary: open site = globe, link document = paperclip, check = magnifier,
   email = envelope, not expected = bell-slash, download = tray-arrow; each has an accessibility label.
10. **The tenant's personal name** appears only on Tenancies and in the recharge email; everywhere else the
    tenancy's name.

## 3. Constraints

- Logic in BudgetCore (checklist state, matching, statement building already exist on the Mac — reuse them;
  the checklist is computed, never stored).
- Writes through `DeviceWriter.writeCheckingFiledYears`; refusals inline; the Mac re-validates. Patricia's
  permissions (7b grid) decide what's editable; hidden, not disabled, when not.
- Built-in browser: WKWebView with `WKDownload` capture into an app-private tray (file protection
  `completeUntilFirstUserAuthentication`, excluded from backup); AutoFill from Passwords works in WKWebView —
  verify with a spike before building. Saved sites are household data (synced); no cookies or credentials leave
  the device.
- The tray syncs nothing until a file is checked and saved (then it's a normal document/import).
- Fits 11" and 13" iPad, portrait and landscape; no figure wraps; names truncate in the middle; Save-only edits.
- The Mac is unchanged by this step.

## 4. Non-goals

Mac redesign; iPhone changes; scraping or auto-login to websites; automatic email sending without review.

## 5. Left to the builder

Exact layout within the mockups, portrait arrangements, icon drawings (SF Symbols equivalents), copy.

## 6. Size

Estimate ~9% of the weekly limit (largest parts: built-in browser + tray + check-and-link, This month, the
shared document panel, the six redesigned pages). A browser spike (~0.5%) comes first and can change the plan.
