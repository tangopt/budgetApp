# Budget Polish, Account Details, Consistent Sheets — Design Spec

Requested 2026-10-13 (approved in chat).

## 1. Budget screen

- Remove the dashed "Compare… / ⌘-click years" hint card; its hint moves into each year card's `.help` tooltip ("⌘-click to compare several years").
- Remove the "Showing actuals for … only" caption bar (and its "Show all accounts" button); the account panel's ticks and its "All accounts" row are the indicator and the reset. While a filter is active, pending amounts/icons and Add planned item on empty cells stay hidden (unchanged).
- Year cards: one fixed size for every card (width and height fit the largest content, e.g. 160×78pt), content: line 1 the year in the current year font, followed for the current year by " forecast" in the caption font (the old "forecast to Dec" line is removed); line 2 the year-end net worth; line 3 the change vs the previous year-end as "↑ £24,953 · 16.4%" (green up / red down; amount in whole pounds with thousands separators; "—" when there is no previous year). Selected styling unchanged.
- Side panel (TransactionsSidePanel, used by Budget and Categories): the per-transaction "Edit…" button becomes an icon-only button (SF Symbol `pencil`, borderless, `.help("Edit transaction")`, accessibility label "Edit transaction").
- Window growth bug: collapsing/expanding the account panel must never change the window size. Find the cause first (likely the grid's ideal/min width propagating to the window when the panel toggles); fix so the window keeps its size and the grid takes the remaining width (scrolling as before). Also ensure the window can be resized back down (no oversized min width from the grid).

## 2. Account details and alias

- Migration (appended last): `account.alias TEXT NULL`, `account.sortCode TEXT NULL`, `account.accountNumber TEXT NULL`, `account.iban TEXT NULL`. Normalisation on save: trim; empty → nil; sort code stored as 6 digits and shown "30-00-00"; account number digits only (≤ 8 shown as-is); IBAN uppercase without spaces, shown in groups of 4. Light validation with inline errors: sort code 6 digits; account number 6–8 digits; IBAN 15–34 alphanumerics starting with 2 letters + 2 digits (no checksum enforcement).
- `Account.displayName` = alias if set, else name. Used everywhere an account is named in the UI: Budget account panel, side panels' transaction rows, transfer link lines ("↔ <account>"), Link to transfer… candidates, Dashboard import card/account pickers, import screens and mapping sheet titles, Review badges, Accounts list, balance sheets, freshness texts.
- Accounts screen: each row shows the display name, with the full name in secondary text under it when an alias exists; an expandable/visible details section per account shows sort code, account number, IBAN (each with a copy button) when set. The account create/edit sheets get the four new fields.

## 3. Consistent sheets, dialogs and popovers

A shared design-system component and rules, applied to every sheet/popover/dialog in the app:
- `SheetScaffold` (App/DesignSystem): title (`.title3`, semibold, leading) at the top; content; optional inline error (red, `.callout`, above the buttons); footer: Cancel (`.cancelAction`) on the left, Spacer, primary action on the right (`.borderedProminent`, `.defaultAction`, disabled until valid); destructive actions use `role: .destructive` and sit at the far left of the footer, separated from Cancel. Standard padding 20pt; minimum width 420pt (wider where content needs it); content spacing 12pt.
- Forms use `Form { … }.formStyle(.grouped)` or a two-column `Grid` with labels right-aligned (trailing) in the first column and controls leading in the second; read-only values are `LabeledContent` rows (plain text) in the same grid; text fields fill the column width.
- Popovers (note, category picker, Set category…): 12pt padding, same font sizes, primary button bottom-right.
- Alerts/confirmation dialogs: consistent titles (sentence case, no trailing period), destructive role where applicable, message text concise.
- Inventory (to update and list in the report): App/Accounts/AccountFormSheets.swift, BalanceUpdateSheets.swift, AccountsView alerts; App/Budget/EditTransactionSheet.swift, PlannedItemSheets.swift (add/edit occurrence), ReserveSheets.swift, BudgetGridView/BudgetCellPanel sheets & alerts; App/Shared/CloseMonthView.swift; App/Categories/* (rename, delete confirmation, NewCategorySheet in DesignSystem); App/DesignSystem/NoteButton.swift, CategoryPickerButton.swift (popover), NewCategorySheet.swift; App/Forecast/ScenarioChips.swift (name sheet, delete), DifferencesTab.swift (apply/undo/revert dialogs), ScenarioGridTab.swift; App/Import/* (CSVMappingWizardView, PDFLayoutWizardView, finish/cancel dialogs in ReviewView, ImportFlowHost); App/Uncategorized/*; App/ContentView.swift (unsaved-import alert); App/Dashboard/DashboardView.swift.

## Testing

BudgetCore XCTest: migration; normalisation/validation helpers for sort code, account number, IBAN; `displayName`. App: build; full suite; zero compiler warnings in our code.
