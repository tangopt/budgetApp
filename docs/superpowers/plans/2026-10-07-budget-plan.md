# Budget as the Plan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Planned items (series + per-occurrence exceptions) appear in the Budget grid's open and future months as unconfirmed amounts with status icons, editable per occurrence or for all following occurrences, with exception-aware totals on every screen.

**Architecture:** A new exceptions table and one expansion function (`PlannedOccurrences`) become the only way forecast amounts are computed; `ForecastCalculator` delegates to it, so the Dashboard, both grids, reserves and the net-worth projection stay consistent. Editing rules live in BudgetCore (`PlannedItemEditing`, `PlanStatus`); the Budget grid adds display, drill-down and sheets.

**Tech Stack:** Swift 6 / SwiftUI (macOS 26), GRDB 6.29, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-07-budget-plan-design.md` — read it before any task.

## Global Constraints

- Occurrence identity: `(entryId, originalDate)`; exceptions keyed uniquely by it; `ON DELETE CASCADE` from `forecastEntry`.
- Planned items = `ForecastCalculator.confirmedEntries` (enabled, not hypothetical, enabled group). Hypothetical scenario entries never get exceptions.
- Forecast amounts belong to the **calendar** month named on them (`MonthRange.of`); actuals to the **pay** month (`PayCalendar`/`PayMonthTotals`). Month classes from `PayCalendar.monthClass`.
- Confirmed occurrence: its pay month is closed, or its category's actual that month covers the category's planned total (expense spend ≥ plan; income ≥ plan; transfers by the sign of the plan). Only unconfirmed occurrences can be edited; moves into a closed month are refused.
- Detection never updates or deletes; `.auto` is no longer produced (migration turns existing `.auto` into `.manual`).
- Money is signed `Int` minor units; money inputs use `MoneyField` / `Money.formatInput`.
- Tests: XCTest, in-memory DB `let m = try DatabaseManager(path: nil); try m.migrate()`; bare `Category`. Run `swift test --scratch-path /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/build-bp` (`--filter` while iterating). App: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -destination 'platform=macOS' -derivedDataPath /private/tmp/claude-501/-Users-pablo-dimenza-Documents-Code-budget/5fac4f61-c0c9-436b-881b-aebe445aa967/scratchpad/dd-bp build 2>&1 | tail -5`. Never both at once.
- New migrations appended last. Commit per task (author's Co-Authored-By). Never push. Never touch `~/Library/Application Support/Budget`.

---

### Task 1: Exceptions model and exception-aware totals

**Files:** create `Sources/BudgetCore/Models/PlannedOccurrenceException.swift`, `Sources/BudgetCore/Forecasting/PlannedOccurrences.swift`; modify `Sources/BudgetCore/Forecasting/ForecastCalculator.swift`, `Sources/BudgetCore/Database/DatabaseManager.swift`, `Sources/BudgetCore/Models/ForecastEntry.swift` (migration turning `.auto` into `.manual`); tests `PlannedOccurrencesTests.swift`, `ForecastCalculatorTests.swift`.

**Produces:**
- `PlannedOccurrenceException` record (`id`, `entryId`, `originalDate`, `isSkipped`, `amountMinorUnits: Int?`, `date: Date?`, `categoryId: Int64?`), table `plannedOccurrenceException`, unique `(entryId, originalDate)`, FK cascade.
- `PlannedOccurrence` and `PlannedOccurrences.occurrences(entries:exceptions:in:) -> [PlannedOccurrence]` exactly as in the spec.
- `ForecastCalculator.confirmedTotal(categoryId:period:entries:groups:exceptions:)`, `previewTotal(…exceptions:)`, `confirmedNetWorthImpact(…exceptions:)`, `previewNetWorthDelta(…exceptions:)` — `exceptions: [PlannedOccurrenceException] = []` default in this task (Task 2 removes the default after threading every caller).

```swift
public enum PlannedOccurrences {
    public static func occurrences(entries: [ForecastEntry], exceptions: [PlannedOccurrenceException], in period: PayPeriod) -> [PlannedOccurrence] {
        let byKey = Dictionary(exceptions.map { (Key(entryId: $0.entryId, date: $0.originalDate), $0) }, uniquingKeysWith: { a, _ in a })
        let entryById = Dictionary(entries.compactMap { e in e.id.map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
        var result: [PlannedOccurrence] = []
        for entry in entries {
            guard let id = entry.id else { continue }
            for original in FrequencyExpander.occurrences(for: entry, in: period) {
                let exception = byKey[Key(entryId: id, date: original)]
                if exception?.isSkipped == true { continue }
                let date = exception?.date ?? original
                guard date >= period.startDate, date <= period.endDate else { continue } // moved out
                result.append(make(entry, original: original, exception: exception))
            }
        }
        // Exceptions moved INTO the period from an original date outside it.
        for exception in exceptions where !exception.isSkipped {
            guard let moved = exception.date, moved >= period.startDate, moved <= period.endDate,
                  !(exception.originalDate >= period.startDate && exception.originalDate <= period.endDate),
                  let entry = entryById[exception.entryId] else { continue }
            // Only if the original is a real occurrence of the series.
            let probe = PayPeriod(startDate: exception.originalDate, endDate: exception.originalDate, type: .projected)
            guard FrequencyExpander.occurrences(for: entry, in: probe).contains(exception.originalDate) else { continue }
            result.append(make(entry, original: exception.originalDate, exception: exception))
        }
        return result.sorted { $0.date < $1.date }
    }
    private struct Key: Hashable { let entryId: Int64; let date: Date }
    private static func make(_ entry: ForecastEntry, original: Date, exception: PlannedOccurrenceException?) -> PlannedOccurrence {
        PlannedOccurrence(entryId: entry.id!, originalDate: original, date: exception?.date ?? original,
                          categoryId: exception?.categoryId ?? entry.categoryId,
                          amountMinorUnits: exception?.amountMinorUnits ?? entry.amountMinorUnits,
                          isException: exception != nil)
    }
}
```

`total(...)` becomes: occurrences of (confirmed [+ selected hypothetical]) entries in the period, filtered by `occurrence.categoryId == categoryId`, summed. Note an entry must be included in the expansion even when its own `categoryId` differs (re-filed occurrences), so expand all candidate entries, then filter by occurrence category.

- [ ] Step 1: failing tests — originals; skip; amount override; moved within; moved into (from previous month); moved out; re-filed category counted under the new category and not the old; weekly/monthly(interval 2)/annual; `confirmedTotal`/`confirmedNetWorthImpact` with and without exceptions; migration: `.auto` entries become `.manual`; cascade delete of exceptions with the entry.
- [ ] Step 2: run → fail. Step 3: implement. Step 4: focused + full suite green, app build. Step 5: commit "Planned occurrences: exceptions model and exception-aware totals".

---

### Task 2: Thread exceptions through every caller

**Files:** `Sources/BudgetCore/Dashboard/DashboardInput.swift`, `DashboardCalculator.swift` (`upcomingBills` uses `PlannedOccurrences` — bills appear on their moved date, under their re-filed category, skipped ones vanish), `DashboardCalculator+Flows.swift`, `DashboardCalculator+NetWorth.swift`, `Sources/BudgetCore/Forecasting/ForecastProjector.swift`, `ReservedCategories.swift`, `Sources/BudgetCore/Budget/*`; `App/Dashboard/DashboardViewModel.swift`, `App/Forecast/ForecastViewModel.swift`, `App/Budget/BudgetGridViewModel.swift`; tests.

- [ ] Add `exceptions: [PlannedOccurrenceException]` to `DashboardInput` (loaded by `DashboardViewModel`), to `ForecastProjector` functions, to `ReservedCategories.unforecastSpend`/`monthAllowances` inputs as needed; view models load `PlannedOccurrenceException.fetchAll(db)` in `load()` and pass them everywhere they call ForecastCalculator / projector. Then **remove the `= []` defaults** so the compiler proves every call site passes exceptions (tests pass `[]` explicitly or real ones).
- [ ] Tests: Dashboard current month and upcoming bills honour a skip and a move; projector honours an amount override.
- [ ] Verify: full suite, app build. Commit "Thread planned-occurrence exceptions through every screen".

---

### Task 3: Editing, plan status and detection

**Files:** create `Sources/BudgetCore/Forecasting/PlannedItemEditing.swift`, `Sources/BudgetCore/Budget/PlanStatus.swift`; modify `Sources/BudgetCore/Forecasting/AutoForecastGenerator.swift`; tests `PlannedItemEditingTests.swift`, `PlanStatusTests.swift`, `AutoForecastGeneratorTests.swift`.

**Produces:**
```swift
public struct OccurrenceChange: Equatable {
    public var amountMinorUnits: Int?; public var date: Date?; public var categoryId: Int64?
    public var frequency: ForecastFrequency?; public var interval: Int?; public var remove: Bool = false
}
public enum PlannedItemEditError: Error, Equatable { case occurrenceConfirmed, invalidDate, frequencyNeedsFollowing, notFound }
public enum PlannedItemEditing {
    public static func editOccurrence(db: Database, entryId: Int64, originalDate: Date, change: OccurrenceChange, calendar: PayCalendar) throws
    public static func editFollowing(db: Database, entryId: Int64, originalDate: Date, change: OccurrenceChange, calendar: PayCalendar) throws
    public static func isConfirmed(entry: ForecastEntry, occurrence: PlannedOccurrence, calendar: PayCalendar, monthTotals: [Int64: [Int: [Int: Int]]], entries: [ForecastEntry], groups: [ForecastGroup], exceptions: [PlannedOccurrenceException], categories: [Category]) -> Bool
}
public enum PendingState: Equatable { case none, allExpected, partial }
public enum PlanStatus {
    /// value = actual + pending; closed months: (actual, 0, .none).
    public static func cell(actual: Int, planned: Int, categoryType: CategoryType, monthClass: MonthClass) -> (value: Int, pending: Int, state: PendingState)
}
```
Rules (spec "Editing operations" and "Confirmation"): `editOccurrence` with a frequency change throws `.frequencyNeedsFollowing`; `remove` = skip; split semantics for `editFollowing` exactly as the spec; editing a `.auto` entry makes it `.manual`; confirmed occurrence → `.occurrenceConfirmed`; a date in a closed pay month → `.invalidDate`.

`AutoForecastGenerator.regenerate`: only **adds** an entry (status `.manual`) for an eligible category (not reserved, not excluded, transfers/income included as today) with no planned item at all; never updates or deletes.

- [ ] Tests: occurrence upsert (amount, date, category, skip); following split (original end date = day before; new entry values; exceptions after moved/re-keyed; schedule shift drops later exceptions; first-occurrence edit replaces the series); frequency change; remove following ends series; confirmed rejected (closed month; covered by actuals); invalid date; `.auto`→`.manual`. PlanStatus: all-expected, partial, covered, closed, income, transfer. Generator: adds only when no plan; leaves existing untouched.
- [ ] Verify; commit "Planned item editing, plan status and add-only detection".

---

### Task 4: Budget grid — plan display, drill-down, edit and add

**Files:** `App/Budget/BudgetGridViewModel.swift`, `App/Budget/BudgetGridView.swift`, `App/Budget/GridDrillDownSheet.swift`, new `App/Budget/PlannedItemSheets.swift`; `App/Forecast/ForecastView.swift` (remove the section-header "+" and its planned-item sheet; keep reserves' own add flow); `App/Forecast/ForecastViewModel.swift` (drop `addPlannedItem` if unused).

- [ ] VM: load exceptions; `cell(_ category, year, month) -> (value, pending, state)` via `PlanStatus` with pay-month actual and calendar-month planned (exception-aware) and `payCalendar.monthClass`; group/section aggregation (state: partial if any partial, else allExpected if any pending); year footnote total of pending; `occurrences(category:year:month:) -> [(PlannedOccurrence, isConfirmed: Bool, entry: ForecastEntry)]`; `editOccurrence`/`editFollowing`/`addPlannedItem` wrappers (write, reload, `SaveOutcome`-style result, errors mapped: confirmed → "This occurrence has already happened.", invalid date → "Pick a date in an open month.", frequency → "A frequency change applies to this and all following occurrences.").
- [ ] View: cells show value; pending part secondary italic with `clock` / `circle.lefthalf.filled` icon and help text ("£x actual + £y expected" / "£y expected"); current year always in the picker; year footnote "Includes £x not yet confirmed".
- [ ] Drill-down: below transactions, "Planned" list (date, amount, frequency, Confirmed/Unconfirmed); unconfirmed rows have Edit… and Remove… (Remove asks Only this / This and all following).
- [ ] Edit sheet: amount (MoneyField), date, category (same type, reserves for reserves), frequency + interval; Save → choice sheet/dialog "Only this occurrence" / "This and all following" (frequency change → only the latter); inline errors.
- [ ] Section headers Income/Expenses/Transfers: "+ Add planned item" (category, amount MoneyField, one-off or recurring weekly/monthly/annually every N, start, optional end) → `PlannedItems.add`.
- [ ] Verify: app build, full suite. Commit "Budget grid shows and edits the plan".

---

### Task 5: Check and merge (controller)

- [ ] Open the built app on a DB copy; check October (open) cells show actual + pending with icons, future months planned, drill-down edits; screenshots if possible.
- [ ] Final whole-branch review, one fix wave, merge to local `main`.
