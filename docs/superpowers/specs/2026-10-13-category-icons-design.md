# Category Icons — Design Spec

Requested 2026-10-13.

- `category.iconName TEXT NULL` (migration appended last): an SF Symbol name chosen by the user. Nil → the type's generic symbol used today (`CategoryType.symbolName`). Colour is unchanged: by type (expense red, income green, transfer blue) via `CategoryBadge`.
- Icon picker: from the Categories screen (right-click → "Change icon…", and clicking the badge on a row) a popover with a searchable grid of a curated set of ~80 finance-relevant SF Symbols grouped by theme (Home & bills, Food & drink, Transport & car, Shopping, Leisure & travel, Health, Money & transfers, Work & income, Kids & pets, Other), plus "Use default" (clears to the type icon). Validate that every curated symbol exists (NSImage(systemSymbolName:) non-nil) in a test or at load (skip missing).
- `CategoryBadge` takes the category's icon (iconName ?? type symbol). Show it wherever a category badge/icon appears: Categories screen rows, Budget grid category rows, side panels' transaction rows (category), category picker rows, review/uncategorized rows if they show a badge.
- Categories screen: replace the magic-wand icon with a small secondary text label "No auto-forecast" (help: "Not detected automatically for the plan"); keep the external-transfer indicator as a small text label "Not matched" (help unchanged).
- BudgetCore: `Categories.setIcon(db:id:iconName:)` (trim, empty → nil), tested.
