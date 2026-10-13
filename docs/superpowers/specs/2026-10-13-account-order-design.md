# Account Order — Design Spec

Requested 2026-10-13.

- Default order of accounts everywhere they are listed: alphabetical by `displayName` (`Account.displayNameOrder`), replacing the Accounts screen's GBP-balance order.
- The user can reorder accounts by drag and drop on the Accounts screen list and in the Budget account panel (AccountFilterPanel); both use the same stored order, which also drives the Budget grid's account/balance rows, account pickers (import card), and any other account list.
- Storage: `account.sortOrder INTEGER NULL` (migration appended last). Accounts with a sortOrder come first in ascending order; accounts without one follow alphabetically by displayName. The first drag assigns sortOrder to every account in the current displayed order (0…n-1), then moves the dragged one. New accounts get no sortOrder (appear alphabetically after ordered ones) — or append at the end once any order exists (choose: append at end = max+1).
- BudgetCore: `AccountOrdering.sorted(_ accounts:)` and `AccountOrdering.move(db:ids:toOffset:)` (tested): stable, renumbers 0…n-1.
- "All accounts" stays first in the Budget panel and is not draggable. Reserves/other lists unaffected.
