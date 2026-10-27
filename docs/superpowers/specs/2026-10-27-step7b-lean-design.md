# Step 7b (lean): permissions grid, iPhone quick edits, widgets, notifications — design

Status: written 2026-10-27 from the approved October specs; the calls marked *(my call)* are open to the
user's correction. Budget: about 6% of the weekly limit. If it runs short, notifications and then widgets
drop out (user, 2026-10-26), in that order.

Sources this argues from (already approved, not repeated here):
- `2026-10-22-iphone-app-design.md` §1 (quick edits), §3.8 (widgets and notifications), §4 (design rules);
- `2026-10-22-sync-and-access-design.md` §5.1 (field merge), §6.3 (permissions grid), §12 (lock-screen leaks);
- `2026-10-25-sharing-levels-design.md` §2 (default permissions);
- `2026-10-26-ipad-tenancy-design.md` (DeviceWriter, refusals inline, the Mac re-validates).

## 1. Intent

Finish the household's everyday reach: the admin can tune what Patricia may do; either of them can make
the small fixes on the go from an iPhone; the home and lock screens show where the month stands without
opening Mango; and Mango nudges when rent is late or a bill or tax payment is close.

## 2. Scope

### 2.1 Permissions grid (Mac, Settings ▸ Household)
- Per member, a grid: rows are `AccessArea.fixedAreas` plus one Tax row per person ("Tax — <name>");
  one None/View/Edit segmented picker per row. Stored in `memberPermission` (exists), synced, enforced
  by the existing AccessPolicy / Mac re-validation. No new enforcement.
- The admin's own row is not shown (the admin edits everything). Only the admin sees the grid.
- Edits save only on **Save**; **Cancel** discards. "Reset to defaults" restores
  `MemberPermissions.defaultLevel`.
- Lowering a level never deletes the member's data; it only limits later writes and what the phone/iPad
  show (View hides edit controls; None hides the area), as the iPhone spec §3.9 says.
- **Household settings** at Edit for a member is not offered *(my call)*: inviting and removing stay
  admin-only. The picker for that row offers None/View.

### 2.2 iPhone quick edits (iPhone only; iPad keeps its step 8 screens)
Through the step 8 `DeviceWriter` (filed-year refusals inline, the Mac re-validates):
- **Categorise a transaction** from Month or Search: category picker in a sheet, Save/Cancel.
- **Quick sort:** a card-per-transaction queue of uncategorised transactions in the current pay month,
  newest first; each card's category buttons are the explicit save, with an "Undo" toast (iPhone spec §4).
- **Note** on a transaction, in the same sheet as the category.
- **Update a manual balance** on an account that has no statement import (Accounts ▸ account ▸ "Update
  balance"), Save/Cancel.
- Each needs Edit on the area that `AccessAreaMap` assigns; without it the control is hidden, not disabled.
- Deferred *(my call, to fit the budget)*: receipt photo (needs document creation on the phone → step 10
  with iPad import) and accepting a rent/recharge split (the split proposals belong with the recharge
  work on iPad/Mac).

### 2.3 Widgets (iPhone, also iPad home screen since the target is universal)
- A widget extension and the App Group `group.ubberninja.mango`. The app writes a small snapshot JSON
  to the group container after each sync and on unlock; the widget only reads it. BudgetCore builds the
  snapshot (`WidgetSnapshot`), so it is tested there.
- Kinds: **Net worth** (small), **Left this pay month** (small), **Payday in N days** (lock-screen
  circular). Medium "Upcoming" is dropped *(my call)*.
- Every figure is `.privacySensitive()`. A per-device setting, "Show figures on the lock screen", off by
  default. The snapshot respects sharing levels: it is built for the device's viewer, so it never holds
  what the viewer can't see.
- Tapping a widget opens the matching tab (Home / Month).

### 2.4 Notifications (iPhone and iPad, local only)
- Scheduled by the app from synced data after each sync and on launch; no push server. BudgetCore
  computes the due list (`NotificationPlanner`, pure, tested); the app schedules it with
  `UNUserNotificationCenter`, replacing the previous set.
- Triggers, all on by default, each switchable in Settings ▸ Notifications:
  - rent not seen 5 days after it was due;
  - a bill or obligation due in 3 days;
  - a tax payment due in 7 days;
  - no statement imported for 14 days (admin only).
- Dropped *(my call)*: "split proposed", "recharge ready to send" and "import on another device" — they
  depend on deferred work or on push.
- Text never contains amounts unless "Show figures on the lock screen" is on. Quiet for areas where the
  viewer has None.
- Asking permission: only when the person first turns on a notification in Settings, never at launch.

## 3. Non-goals
Receipt photos, split acceptance, push notifications, medium widgets, Mac widgets, Mac notifications,
key rotation on removal (step 15), import on iPad (step 10).

## 4. Anti-goals
- A widget, notification or lock screen ever showing a private account's figures to the other person.
- A permission change that silently deletes or moves data.
- Quick edits that bypass the filed-year check.

## 5. Constraints
- Logic in BudgetCore (snapshot builder, planner, grid model); thin views.
- Mac fits 1100×700; no figure wraps or truncates; names truncate in the middle; edits save only on
  Save or explicit buttons.
- The widget extension needs a new bundle id (`ubberninja.mango.ios.widgets`) and the App Group on both
  app and extension; signing is automatic with the App Manager key at archive time. Nothing personal
  (team id, emails) committed.
- No new CloudKit record types (memberPermission already syncs), so no Production schema deploy.

## 6. Left to the builder
Layout details within the iPhone spec's mockups; widget visuals; the exact copy of notification text
(short, plain, no amounts when locked).
