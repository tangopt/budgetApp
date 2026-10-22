# iPhone app — design

Status: for the user's review (2026-10-22). Mockups: the "iPhone" page of the design canvas
(https://claude.ai/artifact/4bdRGqbyqKA1vQPwBLCYhZ, private to the user). All figures and names in the
mockups are invented. Data, sync, access and identity: `2026-10-22-sync-and-access-design.md` and
`2026-10-21-authentication-design.md`. Where each feature lives: `2026-10-22-companion-apps-overview.md`.

## 1. Intent

**Mostly information, plus the quick touches you'd do on the go (user, 2026-10-21).**
- **Read:** how the household is doing (net worth, this pay month, accounts, the flat, what's coming up).
- **Quick edits:** categorise a transaction, add a note, attach a receipt photo, accept a rent/recharge
  split, update a manual balance.
- **Nothing heavy:** no imports, rules, planning or tax.
- **Native iOS 26, not a shrunk Mac app:** tab bar, large titles, sheets with detents, swipe actions,
  the system search tab, Dynamic Type, widgets and notifications.

## 2. Navigation

- **Tab bar:** Home · Month · Accounts · Property, with **Search** as the iOS 26 separate search tab
  (`Tab(role: .search)`).
- **The avatar on Home** (top right) opens a Settings sheet:
  - Lock now;
  - Sharing (my accounts' levels);
  - Notifications;
  - Appearance and theme;
  - Security status (ADP);
  - About and sync status.
- **Deep links** from widgets and notifications open the matching tab and screen.
  - A notification about something the person has no permission for opens Home with an inline message.
- **Property tab:** with one property it shows that property directly. With more, it becomes a list.

## 3. Screens (one per mockup)

### 3.1 Locked (mockup 1)
- **Layout:** app icon, "Budget is locked", one line saying what's hidden, then "Unlock with Face ID"
  (prominent) and "Use iPhone passcode".
- **When it locks** (auth spec §10 as amended in sync spec §11.2): on launch, after 5 minutes in the
  background, and on demand from Settings.
- **Re-checks:** Face ID is asked again before accepting a split or changing a sharing level.
- **Content underneath is never rendered** while locked. The snapshot in the app switcher is blurred.

### 3.2 Home (mockup 2)
Stacked cards in this order:
1. **Freshness line:** "Data through <date> · imported on <device>, <when>". Shows amber if over 14
   days.
2. **Net worth:**
   - the figure and its change since last month;
   - a sparkline with the confirmed forecast dashed;
   - the year-end forecast.
3. **This pay month:**
   - left to spend out of planned spending, and days to payday;
   - a bar with the still-expected bills hatched (the dashboard's blend rule, `MonthBlend`).
4. **Needs attention:** uncategorised transactions ("Sort ›" opens Quick sort), recharge ready (says
   where to do it), Inbox items, sync problems.
5. **Upcoming:** the next bills and obligations: the forecast's upcoming bills, IMI, insurance, SA
   payments on account.

Figures come from the same BudgetCore calculators as the Mac dashboard (`DashboardCalculator`), so they
can't disagree. Pull to refresh asks CloudKit for changes.

### 3.3 Month (mockup 3)
- **Header:** the pay month with ‹ › to move between months, and its date range (payday to payday).
- **Summary grid:** Income · Spent so far · Still expected · Left to spend, coloured by the money roles
  of the design system.
- **Segments:** Spending | Income | Transfers.
- **Category rows:**
  - badge, name, "actual / plan" and a progress bar;
  - "£x left" or "£x over plan", the over-plan rows in the expense colour;
  - tapping a row opens its transactions;
  - private accounts at "Category totals" contribute a line "<account> (<owner>) · details private".
- **Read only.** Plans are edited on the Mac.

### 3.4 Search and activity (mockup 4)
- **Search field:** in the bottom search tab. It matches description, amount ("24.99", ">100") and
  category.
- **Filters as tokens:** Uncategorised · account · period.
- **Results:** grouped by day, with each day's total.
  - Rows show a category badge, description, "account · category" and the amount.
  - Uncategorised rows show an amber "?" badge.
- **Quick sort card:** "Categorise the N new ones, one at a time". It opens a card stack: one
  transaction per card, the suggested categories as large buttons, "Skip", and the step "3 of 4".
- **Swipe actions on a row:** leading "Categorise"; trailing "Note".

### 3.5 Transaction (mockup 5)
A sheet (large detent) with **Cancel / Save. Edits save only on Save.**
- **Header:** amount, description, account and date.
- **Category:**
  - the suggested categories as chips, with the history reason under them ("3 earlier CAFE NERO
    payments are Eating out");
  - "All categories…" opens a searchable picker in the same sections as the Mac's.
- **"Always file <merchant> here":** creates or updates a categorisation rule on Save, as the Mac's
  Uncategorized screen does.
- **Note.**
- **Receipt:**
  - "Scan receipt" (VisionKit document camera) or "Choose file".
  - The document is attached to this transaction as evidence and flagged "From iPhone, not reviewed".
  - The next import review on the iPad or Mac files it properly: canonical name, kind, figures.
- **Not on iPhone:** split, transfer link, delete. The sheet says "More on iPad or Mac".

### 3.6 Accounts (mockup 6)
- **Header:** net worth today and the change on last December.
- **Sections:** Cash / Credit / Investments, each with its subtotal.
- **Rows:**
  - two lines: name over "Imported · through <date>" or "Checked <n> days ago";
  - an amber "tap to update" when a manual account is over 30 days old;
  - non-GBP rows show the native figure with the GBP equivalent beneath.
- **Tapping a manual account** opens "Update balance": a money field, a date (default today) and
  Cancel/Save. It writes a balance snapshot exactly as the Mac's Update balances does.
- **Tapping an imported account** shows its recent transactions and its balance chart.
- **Accounts at a lower sharing level:** Balance-only accounts show a lock badge and no transactions.
  Hidden accounts are absent.

### 3.7 Property (mockup 7)
- **Title:** the property's name, plus "Let since <date> · contract to <date>".
- **This month card:**
  - rent and its status (Received <date> / Expected / Late);
  - receipt status;
  - the last recharge and its status (Paid / Sent / Ready to send).
- **Split prompt:** when a tenant transfer arrived and the app has proposed a rent + recharge split,
  "Split it" (re-checks Face ID) or "Not now". This is the one property action on iPhone.
- **Mortgage:** next instalment, outstanding balance, a repaid bar, the rate and its next review.
- **Coming up:** IMI, condomínio, insurance and tax dates.

### 3.8 Widgets and notifications (mockup 8)
**Widgets** (WidgetKit, App Group container, read-only snapshot written by the app after each sync):
- **Small:** Net worth; Left this pay month.
- **Medium:** Upcoming (3 lines).
- **Lock screen (accessory):** circular "left" and "payday in N days".
- **Privacy:** every figure is `.privacySensitive()`, so on a locked device it shows "••••". A setting
  allows figures on the lock screen.

**Notifications** are local, scheduled from synced data; there is no push server. CKSyncEngine's silent
pushes wake the app, which recomputes and schedules them. Defaults are in brackets, and each is
switchable:
- tenant transfer arrived, split proposed (on);
- recharge ready to send (on);
- rent not seen 5 days after it was due (on);
- a bill or obligation in 3 days (on);
- a tax payment due in 7 days (on);
- no statement imported for 14 days (on);
- an import on another device needs you (off on iPhone).

The text never contains amounts while the device is locked, unless allowed.

### 3.9 States (mockup 9)
- **First run on the member's iPhone:**
  - open the share link, then "<Admin> shared the household's Budget with you", then Accept;
  - download progress in records, with "documents download when opened";
  - then the Face ID set-up prompt.
- **First run on the admin's iPhone:** sign in to iCloud if needed; the household downloads with no
  invite.
- **Offline:** an amber inline banner at the top of every tab: "Offline · showing data from <time>.
  Your N changes will sync when you're back online."
- **iCloud signed out or unavailable:** a full-screen explanation with "Open Settings". Local data stays
  readable.
- **Empty states:** search with no results; no transactions in a month; no property; nothing upcoming.
  Each is one sentence and at most one action, as in the design system.
- **Permission None** on an area: its tab or card is absent. **View:** edit controls are hidden, not
  disabled.

## 4. Design rules carried over from the Mac

- **No figure ever wraps or truncates.** Money uses tabular digits and scales down (minimum scale 0.7)
  instead of wrapping, the iOS equivalent of `figureText`. Tested at the largest Dynamic Type size
  without accessibility sizes. At accessibility sizes, rows stack the amount under the label.
- **Money roles, colours and signs:** as in the ui-polish spec §1.4. Theme tokens come from
  `ThemeCatalog`: the same 15 themes in light and dark, mapped to iOS system colours where Classic uses
  them.
- **Edits save only on Save.** Quick sort's per-card buttons are the exception: each tap is the
  explicit save, with an "Undo" toast.
- **Touch targets** are at least 44 pt. Icons come from SF Symbols. VoiceOver reads each amount with its
  role ("spent 24 pounds 99").

## 5. Architecture

- **New target `BudgetPhone`:**
  - in a multiplatform `Budget` project, generated by XcodeGen from `project.yml`;
  - an iOS application target sharing `BudgetCore`;
  - a widget extension and a share extension (the Inbox);
  - App Group `group.com.personal.budget` for the widget snapshot and the share extension's queue.
- **Shared SwiftUI code** for iPhone and iPad (cards, rows, money text, sheets) lives in a new local
  package `BudgetUIKit`, used by both iOS apps. The Mac app keeps its own views.
- **View models are thin.** All figures come from BudgetCore calculators. The App layer may not compute
  totals.

## 6. Test plan

- **BudgetCore:**
  - the widget snapshot builder (redaction flags, figures);
  - the notification scheduler (each trigger, quiet when the permission is None or the account is
    hidden);
  - the Quick sort queue order.
- **Snapshot harness for iOS:** renders every screen above from the demo database, in light and dark, at
  default and largest non-accessibility text size. A wrap probe like the Mac's must report zero wrapped
  or truncated figures.
- **UI tests:**
  - lock and unlock;
  - categorise and Save;
  - Cancel discards;
  - update balance;
  - accept split (re-check prompt).
- **Manual:** member onboarding with two Apple Accounts on a development container.
