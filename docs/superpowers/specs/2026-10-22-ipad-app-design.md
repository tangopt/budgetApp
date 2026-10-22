# iPad app — design

Status: for the user's review (2026-10-22). Mockups: the "iPad" page of the design canvas
(https://claude.ai/artifact/4bdRGqbyqKA1vQPwBLCYhZ, private to the user). All figures and names in the
mockups are invented. Everything in `2026-10-22-iphone-app-design.md` applies here too unless this spec
says otherwise. Data, sync and access: `2026-10-22-sync-and-access-design.md`.

## 1. Intent

**Everything the iPhone offers, plus the routine work (user, 2026-10-21):**
- importing documents and bank statements, through the existing importer and its review;
- categorising;
- the monthly utility recharges for the tenancy.

Forecasting, scenarios, tax preparation and complex set-up (properties, bank layouts, categories,
rules editing) stay on the Mac. **Your own accounts can be added and edited on the iPad** (sync spec
§3.1), so a private account never needs the Mac for routine use: Accounts ▸ + opens a form sheet with the
Mac's fields, including the sharing level, and saves on Save. The iPad shows their results read-only where useful.

**Native iPadOS 26:** a sidebar, split views, multiple windows, drag and drop with Files and Mail,
keyboard shortcuts, the document camera, and Apple Pencil where it helps.

## 2. Navigation (mockup 1)

- **Sidebar,** mirroring the Mac's sections so both of you find things in the same place:
  - **Workflow:** Inbox (count) · Imports · Uncategorized (count)
  - **Overview:** Home · Month · Budget · Search · Accounts · one row per property
  - **Documents:** Documents · Missing evidence (count)
  - **Footer:** the signed-in person's initials and name, plus a lock button.
- **Sidebar behaviour:** in portrait or Split View it collapses to a toggle (`NavigationSplitView`,
  `.automatic`). Screens that need width (import review, categorise, recharges) collapse it themselves.
- **Toolbar:** the prominent **Import** button on every screen (menu: Choose Files…, Scan Documents,
  Photos, Paste). ⌘I opens it.
- **Multiple windows:** e.g. Imports beside Mail. A document dragged from Mail or Files onto any Budget
  window starts an import.
- **Not in the sidebar:** Forecast, Tax years, Rules, Categories and Settings.
  - Settings opens from the footer: the iPhone's settings, plus Household (admin) and Sharing.
  - Mac-only figures (e.g. the year-end forecast) appear read-only on Home.

## 3. Screens

### 3.1 Home (mockup 1)
The Mac dashboard's content in the iPad's grid. Responsive pairs follow the design system's `TwoUpRow`
rule: two cards side by side when both fit at 340 pt, stacked otherwise.
- **Freshness line:** one entry per imported account, plus "synced <n> minutes ago".
- **Net worth:** a full-width card with a Swift Charts line chart since 2020. Actuals are solid, the
  confirmed forecast dashed, with a Today rule. Touch scrubbing replaces hover.
- **This pay month** and **Needs attention**, side by side.
  - Needs attention links to Uncategorized, Recharges and Inbox.
- **Upcoming** and **Accounts**, below.

### 3.2 Month and Budget
- **Month:** the iPhone's Month screen, laid out two-column (summary left, categories right).
- **Budget (read):** the Mac's category × pay-month grid, read-only.
  - Frozen header and label column, horizontal scroll, the same row styles and tokens.
  - Tapping a cell opens its transactions in a side panel.
  - No plan editing.

### 3.3 Inbox and import review (mockup 2)
**How files arrive:**
- dragged onto any window from Files or Mail;
- the Import menu (Files, Scan Documents, Photos, Paste);
- the iPhone's share extension, which puts files in the household **Inbox**, a synced queue of
  documents waiting for import.

**The review is the Mac's design** (spec 2026-10-20), laid out for the iPad:
- **Header:** "Review import · N files", "nothing is saved until you confirm", then Cancel and
  **Confirm import**.
  - Confirm is disabled while anything is in Needs you, with the reason shown under it.
- **Left column** (400 pt):
  - a drop zone "Drop more files from Files or Mail · or Scan with the camera";
  - **Needs you** (each item with its reason);
  - **Ready** (grouped by kind, a one-line summary each);
  - **Duplicates skipped** (with what each duplicates).
- **Preview** (the rest of the width):
  - the document on the left, pinch to zoom, with the value read highlighted on the page;
  - on the right: what it was recognised as and why (incl. the learnt rule used), each figure with
    Read / Check it / Checked by you, "Filed as" with the canonical name, and "Links to" (Show opens
    the transaction in place);
  - then the recharge or record it feeds.
- **Actions:** Mark all as checked, Change kind…, Link to… (searches transactions), Leave out.
- **Statements:**
  - a balance-check failure, possible duplicates and unparsed lines are Needs-you items, as on the Mac;
  - a bank layout with no saved profile is a Needs-you item reading "set it up on the Mac" (mockup 6);
  - the rest of the batch can still be confirmed, and those files stay in the Inbox.
- **On-device model:** used exactly as on the Mac (Foundation Models on iPadOS 26), on devices that
  support it. Without it, unknown documents simply go to Needs you.
- **Confirm:**
  - needs the household import lease (sync spec §5.2) and a moment online;
  - re-checks Face ID;
  - writes one batch, runs the follow-on matching (rent receipts, recharges, transfer links, evidence),
    and records "Confirmed by <name>".
- **Imports screen:** the run history with **Undo**, which takes the lease and re-checks Face ID.
- **Private accounts:** a statement for an account at a lower sharing level is imported into its
  owner's private zone. Only its owner's devices can import it, and the review says so.

### 3.4 Categorise (mockup 3)
- **Left:** the uncategorised list, multi-select (tap circles, or a two-finger swipe down the list),
  "Select all".
- **Right:** category tiles: Suggested first, then the sections of the Mac's category picker (e.g.
  Everyday, Lisbon flat).
- **Filing:**
  - tap a tile, or drag the selection (or one row) onto it;
  - each filing is an explicit action with an **Undo** toast;
  - with a hardware keyboard, the number keys 1–9 pick the suggested tiles and ⌘Z undoes.
- **"Make a rule for these descriptions"** (on by default when every selected row has the same merchant
  key): creates or updates categorisation rules, as on the Mac.
- **Pencil:** Scribble in the search field and in the note field. No other Pencil gestures here.

### 3.5 Monthly recharge (mockups 4 and 5)
The property page has Overview · Tenancy · Recharges · Mortgage · Calendar as a segmented control.
**Recharges:**
- **Months list:** each month with its status: Collecting invoices / Ready to send / Sent / Paid
  <date>.
- **The month's statement:**
  - **Steps:** 1 Invoices in → 2 Send to tenant → 3 Paid with the rent.
  - **Lines:** provider badge, provider and invoice number, period, the debit it matched (date), amount.
  - **Total to recharge.**
  - **The invoice PDFs** as thumbnails (Quick Look on tap), with "Drag an invoice in from Files or Mail
    to add it".
  - **Add invoice** goes through the importer, pre-set to "utility invoice for this tenancy" (the Mac's
    shortcut rule).
  - A missing expected invoice (a provider debit without an invoice) shows as an amber line "EDP debit
    16 Oct · invoice missing", with Scan / Choose file.
- **Prepare email:**
  - opens the system Mail sheet (`MFMailComposeViewController`) addressed to the tenant;
  - subject and body come from the tenancy's template (Portuguese or English, the same text the Mac
    uses, `RechargeEmail` in BudgetCore);
  - the lines are listed and the PDFs attached.
  - When Mail returns `.sent`, the month moves to Sent and records who sent it and when. Cancel or a
    draft leaves it Ready.
- **Paid:** when the tenant's next transfer is imported, the property shows the proposed split (rent
  receipt + recharge). Accepting it (iPad, Mac, or the iPhone's prompt) marks the month Paid. Rejecting
  it lets you pick the transfer manually.
- **Recharge logic** (which invoices belong to which month, netting against Utilities for tax) is
  unchanged in BudgetCore.

### 3.6 Documents and Missing evidence
- **Documents:** browse and search the library (Quick Look preview, metadata, links).
  - **Pencil markup** (`PKCanvasView` over the PDF) is saved as a **new copy** linked to the same
    records, never on the original. The original's hash stays the evidence.
- **Missing evidence:** the Mac's checklist, grouped by source.
  - Each item has **Scan** (document camera) and **Choose file**. Both open the importer pre-set to that
    item, so the result is filed and linked like any import.
  - "Not available" with a reason works as on the Mac.

### 3.7 Tenancy, Mortgage, Calendar
Read-only views of the Mac's tabs:
- **Tenancy:** rent history, receipts; a receipt PDF can be attached through the importer.
- **Mortgage:** loan chart, rate history.
- **Calendar:** obligations.

Property set-up and mortgage terms are edited on the Mac.

### 3.8 States (mockup 6)
- **Importing on another device:** "Importing on <device>". Review continues; Confirm opens when the
  lease is free; "Notify me when it's free".
- **Offline during an import:** an amber card saying review works offline but confirming needs a moment
  online. The review is kept.
- **Needs the Mac:** a new bank layout, with "Confirm the rest".
- **Document not on this iPad:** a placeholder with the size and Download. It is kept after the first
  open; Settings ▸ Storage frees space.
- **The iPhone's states** (iCloud unavailable, member join, empty states, permission None/View) apply
  unchanged.

## 4. Design rules

- **Layout:** the Mac's design-system rules adapted to touch:
  - 16 pt screen padding, 12 pt between blocks;
  - cards with 14 pt padding, corner 16, a separator stroke;
  - the three table styles as on the Mac (the grid, native list tables, summary tables);
  - side panels docked beside tables, never over them.
- **Sizes:** everything is tested at 11" and 13" landscape and portrait, in Split View at ⅓ and ½.
  Below 700 pt wide the iPad uses the iPhone's layouts (compact size class).
- **Unchanged from the iPhone and Mac:** no figure wraps or truncates; edits save only on Save; Undo
  toasts for direct actions.
- **Keyboard:**
  - ⌘I Import, ⌘F Search, ⌘Z Undo, ⌘⏎ Confirm import (when enabled), ⌃⌘L Lock (as on the Mac);
  - every shortcut is listed in the ⌘ overlay.
- **Pointer:** hover effects on rows and tiles, as on the Mac.

## 5. Architecture

- **The same iOS target as the iPhone** (`BudgetPhone`, universal). It switches layouts by size class
  and idiom: one app, one App Store Connect record, one TestFlight build.
- **The importer's presentation** is new iOS SwiftUI in `BudgetUIKit`. Its model is
  `ImportCenterModel`'s logic, moved from the Mac app into BudgetCore wherever it isn't
  presentation-only.
  - **Prerequisite refactor:** whatever in `App/DocumentImport` decides rather than displays moves to
    BudgetCore first, so both apps share it. Tests come with it.
- **Recharge email:** `MFMailComposeViewController` here, `NSSharingService` on the Mac. Both are fed by
  the same BudgetCore `RechargeEmail` draft (recipients, subject, body, attachment URLs).

## 6. Test plan

- **BudgetCore:** the moved import-centre logic keeps its existing tests. Added:
  - the lease interplay (review allowed, confirm refused while held elsewhere);
  - Inbox queue handling;
  - recharge state transitions driven by Mail results.
- **iOS snapshot harness:** every screen above, both orientations, 11" and 13", Split View ½, light and
  dark, and a zero-wrap report.
- **UI tests:**
  - drag-and-drop import of the demo samples, then confirm;
  - a Needs-you item blocks Confirm;
  - categorise by drag, then Undo;
  - recharge: add invoice → Prepare email (mocked composer returns `.sent`) → Sent → accept split →
    Paid.
- **Rehearsal:** import the same demo batch on the iPad and on the Mac, then compare the resulting
  databases after sync (identical records, links and canonical names).
