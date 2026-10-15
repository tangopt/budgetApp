# Transaction Search — Design Spec

Approved in chat 2026-10-15 ("go").

- **Entry**: sidebar item **Search** (magnifyingglass) and ⌘F from anywhere (menu command) selecting it and focusing the search field.
- **Query**: free text, case-insensitive, matches description (raw and display), note and category name; a numeric token (e.g. "12.99", "£12.99", "-12.99") also matches the absolute amount exactly.
- **Filters** (bar under the field, compact menus/pickers): Date (This month, This year, Last 12 months, All time, Custom range — calendar dates), Amount (min/max on absolute value; direction Any / Money in / Money out), Accounts (multi), Categories (multi; groups select all members; includes Uncategorised), Flags (Unreviewed, Manual entries, Linked transfers, Has note). All transactions (not only budget-facing) are searchable; linked incoming legs included.
- **Results**: SwiftUI Table — Date, Description (+ note icon), Category (icon + name), Account (displayName), Amount (signed, colored); sortable columns; default newest first; multi-select. Summary bar: count, total in, total out, net.
- **Actions**: double-click / pencil → existing Edit transaction sheet (and its Add the other side/link features); multi-select **Set category…** (existing CategoryPickerButton incl. New category…; Remember checkbox learns rules like Uncategorized); context menu **Show in Budget** → selects Budget, the transaction's year, opens its category/month cell side panel.
- State kept while the app runs (view model owned by AppEnvironment/ContentView).
- BudgetCore: pure tested `TransactionSearch` (criteria struct → filtered/sorted results + totals) over in-memory transactions/categories/accounts/links; App: SearchView + view model; reload after edits/imports.
- Tests: each criterion, combinations, amount token parsing, group selection, Uncategorised, flags, totals; app build, full suite, no warnings.
