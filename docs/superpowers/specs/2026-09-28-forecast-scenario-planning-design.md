# Forecast Scenario Planning & Management Panel — Design Spec

## Background

The Forecast rebuild (previous spec/plan, same day) shipped a calendar-year grid with a bottom `DisclosureGroup` called "Manage forecast," and a single "Add hypothetical forecast entry…" flow that creates exactly one entry per submission — building a multi-item scenario means reopening that sheet repeatedly with the same group name. `ForecastEntry.endDate: Date?` already exists in the data model but is never exposed by either entry-editing sheet. The Forecast grid has no category-group collapsing, unlike the Budget grid — the previous spec explicitly deferred it ("forecast rows are sparser").

This spec reworks that management experience: a right-side panel replaces the bottom disclosure group; a "scenario" (a non-system-managed `ForecastGroup`, no new concept) can bundle multiple income/expense items created in one flow, each with an optional end-date; exactly one scenario previews at a time via a picker, and its net-worth impact is shown explicitly, not just inferred from per-cell amber lines; confirming a scenario promotes every one of its entries at once; "Detected recurring" entries (including auto-detected ones) gain end-date editability; and the grid gains the same category-group collapsing the Budget grid already has.

## Global Constraints

- No schema or migration changes. `ForecastEntry.endDate` and `ForecastGroup` already carry everything this spec needs.
- "Confirmed" forecast still drives every grid cell's primary (bold) line and both net-worth headline stat blocks, unchanged from the previous spec — a selected scenario is additive, surfaced through the existing amber preview line per cell plus one new explicit impact figure, never by replacing the confirmed numbers.
- Exactly one scenario (or none — "None (confirmed only)," the default) can be selected for preview at a time. Selection is ephemeral view state, not persisted to the database.
- Confirming a scenario confirms every entry in it in one action. A confirmed scenario's entries behave exactly like "Detected recurring" entries from then on — they always contribute to the grid and headline, independent of selection — and the scenario stays visible in the picker (as a non-selectable, confirmed entity) rather than disappearing.
- Category groups in the grid reuse the existing `CategoryGroup`/`groupId` mechanism (`Sources/BudgetCore/Models/CategoryGroup.swift`, already populated by the Categories screen) verbatim — no new grouping concept, no new data model.
- `ForecastCalculator.confirmedTotal`'s public signature is unchanged — every existing caller (`ForecastViewModel.categoryTotal`, `confirmedNetWorthImpact`) is untouched by this spec.

## 1. BudgetCore: scenario-scoped preview

`ForecastCalculator.previewTotal` currently blends every enabled hypothetical group together. It gains a `selectedScenarioGroupId: Int64?` parameter — hypothetical entries now count only when they belong to that specific group, not "any enabled group." Confirmed/auto/manual entries are unaffected (still gated by their own group's `isEnabled`, unrelated to selection):

```swift
public static func previewTotal(categoryId: Int64, period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup], selectedScenarioGroupId: Int64?) -> Int {
    total(categoryId: categoryId, period: period, entries: entries, groups: groups, selectedScenarioGroupId: selectedScenarioGroupId, includeHypothetical: true)
}

public static func confirmedTotal(categoryId: Int64, period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup]) -> Int {
    total(categoryId: categoryId, period: period, entries: entries, groups: groups, selectedScenarioGroupId: nil, includeHypothetical: false)
}

private static func total(categoryId: Int64, period: PayPeriod, entries: [ForecastEntry], groups: [ForecastGroup], selectedScenarioGroupId: Int64?, includeHypothetical: Bool) -> Int {
    let enabledGroupIds = Set(groups.filter(\.isEnabled).compactMap(\.id))
    return entries
        .filter { $0.categoryId == categoryId }
        .filter { $0.isEnabled }
        .filter { entry in
            switch entry.status {
            case .auto, .manual, .confirmed:
                return enabledGroupIds.contains(entry.groupId)
            case .hypothetical:
                return includeHypothetical && entry.groupId == selectedScenarioGroupId
            }
        }
        .reduce(0) { $0 + FrequencyExpander.amount(for: $1, in: period) }
}
```

`confirmedTotal`'s call passes `selectedScenarioGroupId: nil, includeHypothetical: false` — since hypothetical entries are excluded either way, the value of `selectedScenarioGroupId` is irrelevant on that path, and `confirmedTotal`'s own public signature doesn't change, so its two existing callers need no changes.

A new function computes a scenario's net-worth impact, mirroring `confirmedNetWorthImpact` but scoped to the selected scenario's preview:

```swift
/// The selected scenario's preview net effect on account balances for one period —
/// `previewTotal` (confirmed + the selected scenario's hypothetical entries) minus
/// `confirmedTotal`, summed across non-transfer categories. This is the *delta* a
/// scenario would add on top of the confirmed forecast, not a full preview total by
/// itself — `ForecastViewModel` adds it to `forecastNetWorth` to show "net worth with
/// this scenario" without a second full accumulation loop.
public static func previewNetWorthDelta(period: PayPeriod, categories: [Category], entries: [ForecastEntry], groups: [ForecastGroup], selectedScenarioGroupId: Int64?) -> Int {
    categories.reduce(0) { sum, category in
        guard category.type != .transfer, let categoryId = category.id else { return sum }
        let confirmed = confirmedTotal(categoryId: categoryId, period: period, entries: entries, groups: groups)
        let preview = previewTotal(categoryId: categoryId, period: period, entries: entries, groups: groups, selectedScenarioGroupId: selectedScenarioGroupId)
        return sum + (preview - confirmed)
    }
}
```

## 2. `ForecastViewModel`: selection state, scenario-aware methods, end-dates

```swift
/// The scenario (non-system-managed `ForecastGroup`) currently previewed in the grid
/// and headline. `nil` means "None (confirmed only)" — the default. Ephemeral: reset to
/// `nil` on every `load()`, never persisted.
@Published var selectedScenarioGroupId: Int64?
```

`previewCategoryTotal` passes `selectedScenarioGroupId` through to `ForecastCalculator.previewTotal` (both the direct-calculation path and the cache-miss fallback). `forecastTotalsCache`'s cached `preview` value becomes selection-dependent, so `recomputeForecastCaches()` must also run whenever `selectedScenarioGroupId` changes — add a `didSet` on the new property that calls it (matching how `transactions`' `didSet` already rebuilds `calendarTotals`), rather than requiring every call site to remember to call it manually.

A new headline figure — the selected scenario's impact on that year's forecast net worth, `nil` when no scenario is selected:

```swift
/// `nil` when `selectedScenarioGroupId` is nil (no scenario selected) or there's no
/// `latestRealMonth` yet. Otherwise, the selected scenario's cumulative preview delta
/// (via `previewNetWorthDelta`) summed over the same months `forecastNetWorth`
/// accumulates over — the change in year-end net worth this scenario would add.
func scenarioNetWorthImpact(atEndOf year: Int) -> Int?
```

Implemented the same way `computeForecastNetWorth` walks months from `latestRealMonth` to `year`'s December, but summing `ForecastCalculator.previewNetWorthDelta(..., selectedScenarioGroupId: selectedScenarioGroupId)` instead of `confirmedNetWorthImpact`; returns `nil` immediately if `selectedScenarioGroupId == nil`. Cached in `netWorthHeadlineCache` alongside the existing two figures (extend the cache's tuple with a third `scenarioImpact: Int?` field), rebuilt by `recomputeForecastCaches()` — which now also needs `selectedScenarioGroupId` as an input, consistent with the `didSet` above.

Scenario-level mutation methods, replacing the single-entry `addHypotheticalEntry`:

```swift
struct ScenarioItem {
    let categoryId: Int64
    let amountMinorUnits: Int
    let frequency: ForecastFrequency
    let interval: Int
    let startDate: Date
    let endDate: Date?
}

/// Creates a new scenario (a non-system-managed `ForecastGroup`) with one or more
/// hypothetical entries in a single write. `items` must be non-empty — the UI enforces
/// this (Save is disabled with zero items), so this is a precondition, not a runtime
/// error path.
func createScenario(name: String, items: [ScenarioItem]) {
    try? dbQueue.write { db in
        var group = ForecastGroup(name: name, note: nil, isEnabled: true, isSystemManaged: false)
        try group.insert(db)
        for item in items {
            var entry = ForecastEntry(groupId: group.id!, categoryId: item.categoryId, amountMinorUnits: item.amountMinorUnits, frequency: item.frequency, interval: item.interval, startDate: item.startDate, endDate: item.endDate, isEnabled: true, status: .hypothetical, note: nil)
            try entry.insert(db)
        }
    }
    groups = (try? dbQueue.read { db in try ForecastGroup.fetchAll(db) }) ?? groups
    entries = (try? dbQueue.read { db in try ForecastEntry.fetchAll(db) }) ?? entries
    recomputeForecastCaches()
}

/// Adds one more item to an existing scenario group.
func addItem(to group: ForecastGroup, _ item: ScenarioItem) {
    try? dbQueue.write { db in
        var entry = ForecastEntry(groupId: group.id!, categoryId: item.categoryId, amountMinorUnits: item.amountMinorUnits, frequency: item.frequency, interval: item.interval, startDate: item.startDate, endDate: item.endDate, isEnabled: true, status: .hypothetical, note: nil)
        try entry.insert(db)
    }
    entries = (try? dbQueue.read { db in try ForecastEntry.fetchAll(db) }) ?? entries
    recomputeForecastCaches()
}

/// Confirms every entry in `group` at once — a scenario is the unit the user thinks in,
/// so confirming happens at that level, not per-entry. Write-first: each entry is
/// updated in the same transaction, and `entries` is only mutated once the whole write
/// succeeds, mirroring `updateEntry`'s discipline. Deselects the scenario afterward
/// (`selectedScenarioGroupId = nil` if it was selected) since a confirmed scenario is no
/// longer a "preview" — it's already part of the confirmed forecast.
@discardableResult
func confirmScenario(_ group: ForecastGroup) -> Bool {
    errorMessage = nil
    let indices = entries.indices.filter { entries[$0].groupId == group.id }
    guard !indices.isEmpty else { return false }
    var updated = entries
    for i in indices { updated[i].status = .confirmed }
    do {
        try dbQueue.write { db in
            for i in indices { try updated[i].update(db) }
        }
    } catch {
        errorMessage = "Couldn't confirm this scenario: \(error.localizedDescription)"
        return false
    }
    entries = updated
    if selectedScenarioGroupId == group.id { selectedScenarioGroupId = nil }
    recomputeForecastCaches()
    return true
}
```

`updateEntry` gains an `endDate: Date?` parameter (threaded straight through to the updated entry, no other change to its logic):

```swift
@discardableResult
func updateEntry(_ entry: ForecastEntry, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, endDate: Date?) -> Bool
```

`addHypotheticalEntry` is removed (superseded by `createScenario`/`addItem`). `toggleEntry`/`toggleGroup` are unchanged in signature — `toggleGroup` still exists for "Detected recurring"'s on/off toggle; it's simply no longer called for scenario groups from the UI (nothing stops it from still working if called, but the new panel never calls it on a non-system-managed group — scenario inclusion is governed by confirmation/selection instead).

## 3. Screen layout: right-side panel

`ForecastView.body`'s top-level structure changes from one scrolling `VStack` to a `HStack` with the existing content on the left and a new fixed-width panel on the right:

```swift
var body: some View {
    HStack(alignment: .top, spacing: 0) {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                netWorthHeadline
                yearPicker
                gridSection // the existing frozen-header grid VStack, unchanged internally except for category-group rows (section 5)
            }
            .padding()
        }
        Divider()
        scenarioPanel
            .frame(width: 280)
    }
}
```

`manageForecastSection`/`manageExpanded`/the `DisclosureGroup` are removed entirely — replaced by `scenarioPanel`, a `ScrollView(.vertical)` (the panel can also outgrow the window height once a scenario has several items) containing three stacked sections:

**a. Scenario picker.** A "None (confirmed only)" row plus one row per non-system-managed `ForecastGroup`, each showing its name and (for a confirmed scenario) a "confirmed" badge instead of being selectable:

```swift
private var scenarioPicker: some View {
    VStack(alignment: .leading, spacing: 4) {
        Text("Scenario").font(.caption).foregroundStyle(.secondary)
        scenarioRow(name: "None (confirmed only)", isSelected: viewModel.selectedScenarioGroupId == nil, badge: nil) {
            viewModel.selectedScenarioGroupId = nil
        }
        ForEach(viewModel.groups.filter { !$0.isSystemManaged }) { group in
            let isConfirmed = viewModel.entries.contains { $0.groupId == group.id && $0.status == .confirmed }
            scenarioRow(name: group.name, isSelected: viewModel.selectedScenarioGroupId == group.id, badge: isConfirmed ? "confirmed" : nil) {
                guard !isConfirmed else { return } // a confirmed scenario isn't selectable — it's already always-on
                viewModel.selectedScenarioGroupId = group.id
            }
        }
        Button("+ New scenario…") { showNewScenarioSheet = true }
            .buttonStyle(.plain).font(.caption).padding(.top, 4)
    }
}
```

(`scenarioRow` is a small private helper rendering one tappable row — name, selection highlight matching the year-picker chip's existing `Color.accentColor.opacity(0.15)`/stroke convention, and an optional trailing badge `Text`.)

**b. Selected scenario's items.** Shown only when `selectedScenarioGroupId != nil` and the scenario isn't yet confirmed: lists `viewModel.entries.filter { $0.groupId == selectedScenarioGroupId }`, each row showing the category name, signed amount, frequency, and — when set — the end-date ("ends MMMM yyyy", reusing a date formatter in the same style as `ForecastView.monthLabel`), with an "Edit…" button opening the existing edit sheet. Below the list: "+ Add item…" (opens the item-add sheet, section 4) and "Confirm scenario" (calls `viewModel.confirmScenario(group)`).

Also shown here, when a scenario is selected: the scenario's net-worth impact, using `scenarioNetWorthImpact(atEndOf:)` for the currently-selected year —

```swift
if let impact = viewModel.scenarioNetWorthImpact(atEndOf: selectedYear), impact != 0 {
    HStack(spacing: 4) {
        Text("With this scenario:").font(.caption).foregroundStyle(.secondary)
        MoneyText(minorUnits: impact, font: .caption.bold(), tint: .orange)
        Text("by Dec \(String(selectedYear))").font(.caption).foregroundStyle(.secondary)
    }
}
```

**c. Detected recurring.** The system-managed group's own on/off `Toggle` (via `viewModel.toggleGroup`, unchanged), followed by its entries — each a row with the category name, "auto"/"manual" status label, end-date when set, and "Edit…" (same edit sheet as scenario items, section 4) — mirroring what `manageForecastSection` already showed for this group, just relocated.

## 4. Add/edit sheets: multi-item creation and end-dates

`NewForecastEntryView` is replaced by `ScenarioItemFormView`, used both for a brand-new scenario's first item and for adding a further item to an existing one:

```swift
struct ScenarioItemFormView: View {
    enum Mode {
        case newScenario
        case addItem(to: ForecastGroup)
    }
    let mode: Mode
    let categories: [Category]
    let onSave: (String?, ScenarioItem) -> Void // scenario name only non-nil for .newScenario

    @State private var scenarioName = "New scenario"
    @State private var categoryId: Int64?
    @State private var amountPounds = ""
    @State private var frequency: ForecastFrequency = .monthly
    @State private var interval = 1
    @State private var startDate = Date()
    @State private var hasEndDate = false
    @State private var endDate = Date()

    var body: some View {
        Form {
            if case .newScenario = mode {
                TextField("Scenario name", text: $scenarioName)
            }
            Picker("Category", selection: $categoryId) {
                Text("Select…").tag(Int64?.none)
                ForEach(categories) { category in Text(category.name).tag(Int64?.some(category.id!)) }
            }
            TextField("Amount (£, positive number)", text: $amountPounds)
            Picker("Frequency", selection: $frequency) {
                ForEach(ForecastFrequency.allCases, id: \.self) { freq in Text(freq.rawValue).tag(freq) }
            }
            Stepper("Every \(interval) \(frequency.rawValue)", value: $interval, in: 1...12)
            DatePicker("Starting", selection: $startDate, displayedComponents: .date)
            Toggle("Ends on a specific date", isOn: $hasEndDate)
            if hasEndDate {
                DatePicker("Ends", selection: $endDate, displayedComponents: .date)
            }
            Button("Save") {
                guard let categoryId, let minorUnits = Money.parseMinorUnits(amountPounds) else { return }
                let category = categories.first { $0.id == categoryId }
                let signedMinorUnits = category?.type == .income ? abs(minorUnits) : -abs(minorUnits)
                let item = ScenarioItem(categoryId: categoryId, amountMinorUnits: signedMinorUnits, frequency: frequency, interval: interval, startDate: startDate, endDate: hasEndDate ? endDate : nil)
                let name: String? = { if case .newScenario = mode { return scenarioName }; return nil }()
                onSave(name, item)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
```

Using `Money.parseMinorUnits` instead of `Int(pounds * 100)` (which truncates fractional pennies — an existing, separately-noted issue in the sheet this replaces) is a natural byproduct of writing this form fresh against the same pattern `EditForecastEntryView` already uses, not a special-cased fix.

`EditForecastEntryView` gains the same `hasEndDate`/`endDate` `@State` pair and `Toggle`/`DatePicker` pair (initialized from `entry.endDate` — `_hasEndDate = State(initialValue: entry.endDate != nil)`, `_endDate = State(initialValue: entry.endDate ?? Date())`), and its `onSave` closure gains an `endDate: Date?` parameter threaded through to `updateEntry`. `hasChanges` also compares the resolved end-date against `entry.endDate`.

`ForecastView` wires two sheets instead of one:

```swift
@State private var showNewScenarioSheet = false
@State private var addingItemTo: ForecastGroup?
@State private var editingEntry: ForecastEntry?
```

```swift
.sheet(isPresented: $showNewScenarioSheet) {
    ScenarioItemFormView(mode: .newScenario, categories: viewModel.categories) { name, item in
        viewModel.createScenario(name: name ?? "New scenario", items: [item])
        showNewScenarioSheet = false
    }
}
.sheet(item: $addingItemTo) { group in
    ScenarioItemFormView(mode: .addItem(to: group), categories: viewModel.categories) { _, item in
        viewModel.addItem(to: group, item)
        addingItemTo = nil
    }
}
.sheet(item: $editingEntry) { entry in
    EditForecastEntryView(entry: entry) { amountMinorUnits, frequency, interval, endDate in
        viewModel.updateEntry(entry, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, endDate: endDate)
        editingEntry = nil
    }
}
```

(`ForecastGroup` already conforms to `Identifiable` via its `id: Int64?` — `.sheet(item:)` needs `Identifiable`, satisfied.)

## 5. Category groups in the grid

`ForecastView`'s row model gains the same two cases `BudgetGridView.GridRowKind` already has, built the same way:

```swift
private enum ForecastRowKind: Identifiable {
    case sectionHeader(String)
    case category(Category)
    case groupHeader(CategoryGroup, categories: [Category])
    case groupChild(Category)
    // id: same pattern as BudgetGridView.GridRowKind.id
}
```

`allRows`'s `section(_:_:)` helper is rewritten to match `BudgetGridView.rowKinds(for:)` exactly: categories sharing a non-nil `groupId` collapse into one `.groupHeader` row (first-seen order), expanding to `.groupChild` rows when the group's id is in a new `@State private var expandedGroupIds: Set<Int64> = []` (same name and shape as `BudgetGridView`'s). `viewModel.categoryGroups: [CategoryGroup]` is a new published property on `ForecastViewModel`, fetched in `load()` exactly like `BudgetGridViewModel.categoryGroups` already is.

`rowLabel`/`rowCells` gain `.groupHeader`/`.groupChild` cases mirroring `BudgetGridView`'s: a disclosure-triangle button with `Color.orange.opacity(0.10)` background for the header row (summing member categories' `categoryTotal`/`previewCategoryTotal`, bold, two-line if any member is two-line), and an indented (200pt label, 28pt leading padding) row for each expanded child, identical in cell behavior to a plain `.category` row.

## Testing

- New `ForecastCalculatorTests` cases for `previewTotal`'s `selectedScenarioGroupId` parameter: a hypothetical entry in the selected group counts, one in a different (unselected) group doesn't, `nil` selection excludes all hypotheticals (matches today's "no scenario active" baseline).
- New `ForecastCalculatorTests` case for `previewNetWorthDelta`: a selected scenario's income/expense entries net correctly, excludes transfers, returns 0 when nothing is selected.
- `ForecastViewModel`/`ForecastView` changes are App-target, untested by `swift test` per this codebase's established convention (no App-target suite exists) — verified by manual/live walkthrough: creating a multi-item scenario, selecting it and seeing the grid's amber lines and the new impact figure change, switching selection to "None" and seeing them revert, confirming a scenario and seeing it become always-on and no longer selectable, adding an end-date to a detected-recurring entry and seeing it stop contributing to months past that date, and category-group expand/collapse in the Forecast grid.

## Out of scope

- Side-by-side scenario comparison, or more than one scenario active simultaneously — explicitly decided against in favor of "one active at a time."
- Any change to the Budget grid, Dashboard, or Net Worth screens.
- Per-item enable/disable toggling within a scenario (a scenario's items are an all-or-nothing bundle you select, add to, or confirm — not individually toggled the way "Detected recurring" entries still are).
- Deleting a scenario or an individual item — not requested; existing `toggleGroup`/`toggleEntry` remain available as an implicit "turn it off" for Detected recurring, but scenarios have no delete affordance in this pass.
- Auto-detecting an end-date for a recurring entry (e.g. inferring a subscription has lapsed) — "detected recurring…should also have an end-date" is UI editability, not a change to `AutoForecastGenerator`'s detection algorithm.
