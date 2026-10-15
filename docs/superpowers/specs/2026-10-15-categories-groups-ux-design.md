# Categories Screen: Groups Behave Like Categories — Design Spec

Approved in chat 2026-10-15 ("go").

- **New group**: toolbar **+ Group** opens a sheet (SheetScaffold, same look as New category): title "New group", Name field (required, unique — reuse CategoryGroups.create errors inline), optional checkbox "Move the N selected categories into it" (only when categories are selected; unticked by default), Cancel / **Create group**. On create: the group is selected, expanded and scrolled into view. The old "untitled group + inline rename" flow is removed.
- **Selectable groups**: clicking a group row selects it (single selection; selecting a group clears category selection and vice versa); clicking its chevron only expands/collapses. Selected group opens the right side panel like a category: title = group name, transactions of all its member categories with the same year filter, count and total, Edit per transaction (reuse CategoryTransactionsPanel generalised to a set of category ids). Ungrouped / section headers are not selectable.
- **Same actions everywhere**: groups and categories share the right-click menu shape and keys: **Rename…** (Return) opens the same rename sheet as categories (replaces inline group rename), **Delete…** (⌫/⌦) with confirmation ("Delete the group “X”? Its N categories move to Ungrouped." / existing category confirmation), groups also **Add category here…**. Built-in/reserved rules unchanged (not renamable/deletable). Multiple selected categories: Delete… applies the existing per-category rules (refusals listed).
- The group row's ⋯ menu stays but appears only on hover/selection.
- Drag and drop of categories onto groups unchanged.
- Testing: BudgetCore helpers if any new (e.g. transactions for a set of categories, create group with members) with tests; app build, full suite, no warnings.
