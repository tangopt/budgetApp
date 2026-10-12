# Import Review v2 — Design Spec

## Overview

Requested 2026-10-12 after the first 7-month CSV import (660 rows): too many wrong suggestions land in "Ready", groups are incomplete, single rows can't "Remember", categories can't be created during import, transactions have no notes and can't be edited after import, and the long single list is hard to work through. Also the Import and Uncategorized sidebar items should only appear when there is something to do.

## Findings (verified on the user's data, 2026-10-12)

- The user's 1,634 historical transactions come from the spreadsheet import; their `rawDescription` is the category name ("Rent", "Spotify"), so history suggestions never match bank descriptions. Only 12 rules exist. So most suggestions come from the on-device model, and `ReviewPartitioning` puts any suggestion with confidence ≥ 0.6 in "Ready".
- Groups split for two reasons: (1) partitioning is per row, so one merchant's rows land in both sections; (2) Lloyds truncates descriptions at 18 characters, giving variants such as "SAINSBURYS S/MKTS"/"SAINSBURYS S/MKT", "OMNICOM"/"OMNICOM MANAGEMENT", "RINGGO"/"RINGGO PARKING", "POD POINT"/"POD POINT LTD", "AMERICAN EXP"/"AMERICAN EXPRESS"; Amazon purchases ("AMAZON* NQ7KP7EB5") are each their own key.

## 1. Ready only when sure (BudgetCore)

`ReviewPartitioning`: a row is **ready** only when its suggestion came from a rule (`.rule`) or from history (`.history`, which already requires ≥ 2 past transactions and ≥ 70%). Model suggestions (`.llm`) always go to **Needs your attention**, with the suggested category pre-selected. Partitioning is **by group**: a group (same review key, see §2) is ready only if every row in it is ready; otherwise all its rows are in Needs your attention.

## 2. Complete groups (BudgetCore)

A new **review key** used for grouping in Review and Uncategorized (learning and rule matching keep `MerchantKey`):
- Start from `MerchantKey.make(description)`; drop trailing generic tokens (LTD, LIMITED, PLC, CO, INC, LLC, UK, GB) when something remains.
- Processor-only descriptions group under the processor name: e.g. every "AMAZON* <code>" → "AMAZON", "PAYPAL *<code>" → "PAYPAL". Such groups default **Remember off** (purchases differ).
- Truncation merge, computed over the set of keys in one review: when key B starts with key A and A is at least 5 characters, A's rows join B's group (the longer key is the group name; chains resolve to the longest). A word-boundary prefix (B starts with A + " ") always joins. A mid-word prefix joins when A has two or more words (the real Lloyds truncations are 15–17 characters), or, for a one-word A, when at least one description that produced A is at the truncation length (≥ 18 characters), so "SHELL UK" (key SHELL) does not join "SHELLEYS CAFE". Examples: "SAINSBURYS S/MKT" → "SAINSBURYS S/MKTS"; "OMNICOM" → "OMNICOM MANAGEMENT"; "OMNICOM MAN LTD" → "OMNICOM MANAGEMENT"; "RINGGO" → "RINGGO PARKING"; "AMERICAN EXP 3773" → "AMERICAN EXPRESS"; "POD POINT LTD" → (trailing generic dropped) "POD POINT". When A is a prefix of several different longer keys (e.g. "OMNICOM" of "OMNICOM MANAGEMENT" and "OMNICOM STAFF DINI"), A joins the one with the most rows.
- Branches stay separate (GAILS KINGSTON vs GAILS PUTNEY; SAINSBURYS PETROL vs SAINSBURYS S/MKTS) since they are not prefixes of each other.
- Pure, tested: `ReviewKey.groupKeys(descriptions: [String]) -> [String]` (same order, one key per description).

## 3. Remember on single rows

Every single row in Review shows the Remember checkbox, like groups, **ticked by default** (the user's choice, 2026-10-12); the user can untick it, and an explicit choice always wins. Groups and multi-row Set category… also default on; processor-name groups (§2) default off, single-row ones included. The resolved value drives both the checkbox and `ImportDecision.learnRule` (existing `ReviewGrouping.remembers`). Same on the Uncategorized screen, where picking a single row's category learns a rule unless its checkbox was unticked first.

Commit learns a rule for a row when Remember is on, it has a final category, and either the user changed the suggestion or the suggestion did not come from a rule — so confirming a correct model or history guess teaches it, and the next import needn't guess again.

## 4. New category from the picker

`CategoryPickerButton`'s popover gets a **New category…** row at the bottom (also reachable by typing a name with no match: "Create "<query>"…"). It opens a small sheet: name (prefilled with the query), type (expense / income / transfer; preselected from the amount's sign: out → expense, in → income), optional category group. On save the category is created (BudgetCore `Categories.create(db:name:type:groupId:)` — trimmed, unique name, never reserved; throws a readable error on duplicates) and selected for the row/group/selection that opened the picker. Available wherever the picker is used (Review, Uncategorized, Edit transaction).

## 5. Transaction notes and editing

- Migration (appended last): `transaction_.note TEXT NULL`. `Transaction.note: String?`. `StagedTransaction`/`ReviewRow` carry an optional note; `ImportDecision` gains `note: String?` (default nil); commit stores it.
- Review and Uncategorized rows: a note button (`note.text` icon, filled when a note exists) opens a small popover text field; single rows only (not group rows).
- **Edit transaction** sheet: from the Budget grid drill-down's transaction list (and the Uncategorized list), each transaction has Edit…: category (CategoryPickerButton, incl. New category…), note, and a read-only date/description/amount. Saving updates the transaction (`categorizedBy = .manual`, `status = .confirmed` when the category is changed to one; a note-only edit keeps both) via BudgetCore `TransactionEditing.update(db:id:categoryId:note:)`; no rule learning from this sheet. Rows with a note show the note icon in lists.

## 6. Sidebar: Import and Uncategorized only when needed

- **Import** sidebar item is shown only while an import is staging or in review (`ImportViewModel.isStaging || isReviewing`). Starting an import from the Dashboard card selects it automatically. Finishing or cancelling the import removes it and returns to the Dashboard. The unsaved-confirmed-rows guard is unchanged. The Import screen's account/file picking moves fully to the Dashboard import card; "Edit column mapping…" moves to the Dashboard card (menu) for accounts with a CSV profile.
- **Uncategorized** sidebar item is shown only when the uncategorised count > 0, labelled "Uncategorized (N)". When the last one is assigned while on that screen, return to the Dashboard. The count refreshes after imports, edits and assignments.

## 7. Review in three lists

The review shows a segmented tab bar: **Needs your attention (N)**, **Ready to confirm (N)**, **Confirmed (N)**, each a separate list with its own selection, grouping (§2), and Set category…. The notices, progress caption and Cancel import / Finish import stay pinned above the tabs.
- Needs your attention: rows/groups with picker, Remember, note, Confirm.
- Ready to confirm: same, plus **Confirm all** (marks every ready row confirmed).
- Confirmed: dimmed rows/groups with category and Undo (back to their original list).
- Opens on Needs your attention, or Ready to confirm if Needs is empty; when a tab empties, the view switches to the next non-empty one.
- Return-to-confirm and ⌘Return (Finish import) keep working.

## Testing

BudgetCore XCTest: partitioning (model suggestions never ready; group partitioning); `ReviewKey.groupKeys` (all examples above, branches separate, processor names, ambiguous prefix → most rows); Remember default (single rows on, processor groups off); commit learning (accepted model suggestion learns, unchanged rule suggestion does not); `Categories.create` (type, group, duplicate error, trimmed, not reserved); migration + note round trip through commit; `TransactionEditing.update`. App: build; full suite.
