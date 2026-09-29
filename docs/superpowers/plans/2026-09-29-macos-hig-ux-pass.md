# macOS HIG UX Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the app's navigation shell and two list screens in line with macOS Human Interface Guidelines — sidebar icons and grouping, a window title that tracks the selected screen, a real toolbar button instead of a hand-positioned one, and search on the two list-heavy screens.

**Architecture:** Pure SwiftUI presentation changes to 4 existing files. No `BudgetCore` changes, no view-model logic changes, no new files.

**Tech Stack:** Swift 5.10+, SwiftUI, XCTest (unchanged — this plan adds no new test targets; see Global Constraints).

**Spec:** [docs/superpowers/specs/2026-09-29-macos-hig-ux-pass-design.md](../specs/2026-09-29-macos-hig-ux-pass-design.md)

## Global Constraints

- No `BudgetCore` changes, no view-model changes, no new files. Every task modifies exactly one existing `App/` SwiftUI file.
- `App/Accounts/AccountsSettingsView.swift` and `App/Categories/CategoriesView.swift` are explicitly untouched — their inline "Add account"/"Add Group" buttons submit an adjacent `Form`/`TextField`, not a standalone page action, so they stay exactly as they are.
- No hardcoded colors anywhere in this pass — none of these changes need one (icons are `systemImage` names, not colors; text stays whatever color it already was).
- This is presentation-layer-only work with no `BudgetCore` surface, so there is no unit test step in any task — each task's own verification is a full Debug build plus reading the diff for correctness. The plan's final verification (after all tasks) is a live manual walkthrough of every screen, described under Task 4's "Final Verification" section below.
- Existing user-facing labels (`AppScreen.rawValue` values: "Import", "Budget", "Forecast", "Net Worth", "Rules", "Categories", "Uncategorized", "Accounts") do not change — only icons and grouping are added around them.

---

## Task 1: `ContentView` — sidebar icons, grouping, dynamic window title

**Files:**
- Modify: `App/ContentView.swift`

**Interfaces:**
- Consumes: nothing from other tasks (this task is fully independent).
- Produces: nothing later tasks depend on — Tasks 2-4 each touch a different file and don't reference anything this task adds.

- [ ] **Step 1: Add `systemImage` and `sidebarSection` to `AppScreen`**

Replace the `AppScreen` enum (currently lines 7-16 of `App/ContentView.swift`) with:

```swift
enum AppScreen: String, CaseIterable, Identifiable {
    case importReview = "Import"
    case budgetGrid = "Budget"
    case forecast = "Forecast"
    case netWorth = "Net Worth"
    case rules = "Rules"
    case categories = "Categories"
    case uncategorized = "Uncategorized"
    case accounts = "Accounts"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .importReview: return "square.and.arrow.down"
        case .uncategorized: return "folder.badge.questionmark"
        case .budgetGrid: return "tablecells"
        case .forecast: return "chart.line.uptrend.xyaxis"
        case .netWorth: return "banknote"
        case .rules: return "wand.and.stars"
        case .categories: return "tag"
        case .accounts: return "building.columns"
        }
    }

    /// Sidebar section this screen's row is grouped under — see `ContentView.sidebarSections`,
    /// which groups `AppScreen.allCases` by this value while preserving the order each
    /// distinct value first appears in `allCases` (not alphabetically).
    var sidebarSection: String {
        switch self {
        case .importReview, .uncategorized: return "Workflow"
        case .budgetGrid, .forecast, .netWorth: return "Overview"
        case .rules, .categories, .accounts: return "Settings"
        }
    }
}
```

- [ ] **Step 2: Add a `sidebarSections` computed property to `ContentView`**

Add this new computed property to `ContentView`, right after the `forecastHorizon` computed property (currently ending around line 62, just before `var body: some View {`):

```swift
    /// `AppScreen.allCases` grouped by `sidebarSection`, one entry per distinct section
    /// value in the order that value first appears in `allCases` — not alphabetically, so
    /// "Workflow" → "Overview" → "Settings" (driven by `.importReview` being first in
    /// `allCases`, `.budgetGrid` being the first `.sidebarSection == "Overview"` case, etc.)
    /// stays stable regardless of where a section's later members (e.g. `.uncategorized`)
    /// happen to sit in `allCases`' own declaration order.
    private var sidebarSections: [(name: String, screens: [AppScreen])] {
        var order: [String] = []
        var grouped: [String: [AppScreen]] = [:]
        for screen in AppScreen.allCases {
            let section = screen.sidebarSection
            if grouped[section] == nil {
                order.append(section)
            }
            grouped[section, default: []].append(screen)
        }
        return order.map { (name: $0, screens: grouped[$0] ?? []) }
    }
```

- [ ] **Step 3: Replace the sidebar `List` with a sectioned, icon-labeled one**

Replace this block (currently the first part of `var body`):

```swift
        NavigationSplitView {
            List(AppScreen.allCases, selection: $selection) { screen in
                Text(screen.rawValue).tag(screen)
            }
        } detail: {
```

with:

```swift
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(sidebarSections, id: \.name) { section in
                    Section(section.name) {
                        ForEach(section.screens) { screen in
                            Label(screen.rawValue, systemImage: screen.systemImage).tag(screen)
                        }
                    }
                }
            }
        } detail: {
```

- [ ] **Step 4: Add a dynamic window title**

The `detail:` closure currently ends with (matching the end of the `Group { switch selection { ... } }` block, right before the closing `}` of the `detail:` trailing closure and the `.onAppear` that follows):

```swift
                case .none:
                    Text("Select a screen from the sidebar.")
                }
            }
        }
        .onAppear {
```

Replace it with:

```swift
                case .none:
                    Text("Select a screen from the sidebar.")
                }
            }
            .navigationTitle(selection?.rawValue ?? "Budget")
        }
        .onAppear {
```

(Only the `.navigationTitle(...)` line is new — everything else here is unchanged context, shown so the insertion point is unambiguous.)

- [ ] **Step 5: Build**

Run: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -configuration Debug build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

If this project's `.build`/DerivedData shows unrelated Swift compiler errors mentioning duplicate `" 2.swift"` files inside a `GRDB.swift` checkout path, that's a known local environment issue (this project lives under an iCloud-synced folder, and concurrent builds can duplicate the SPM dependency checkout) — not something this task's changes caused. Fix it with `rm -rf .build` (safe: it's gitignored SPM cache) and rebuild once, in isolation (no other build/test command running at the same time), before concluding a build failure is real.

- [ ] **Step 6: Commit**

```bash
git add App/ContentView.swift
git commit -m "Add sidebar icons, section grouping, and a dynamic window title"
```

---

## Task 2: `BudgetGridView` — Export CSV button into a real toolbar

**Files:**
- Modify: `App/Budget/BudgetGridView.swift`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Move the Export CSV button into `.toolbar`**

Replace this block (currently the start of `var body`, lines 123-134):

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button("Export CSV…") {
                    exportDocument = CSVDocument(text: BudgetGridExporter.export(categories: viewModel.categories, periods: viewModel.periods, transactions: viewModel.transactions))
                    showExporter = true
                }
            }

            yearPicker
```

with:

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            yearPicker
```

Then, in the same file, find this modifier (currently line 206-207):

```swift
        .padding()
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .commaSeparatedText, defaultFilename: "budget-export") { _ in }
```

and add the new `.toolbar` modifier right after `.padding()` and before `.fileExporter(...)`:

```swift
        .padding()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Export CSV…") {
                    exportDocument = CSVDocument(text: BudgetGridExporter.export(categories: viewModel.categories, periods: viewModel.periods, transactions: viewModel.transactions))
                    showExporter = true
                }
            }
        }
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .commaSeparatedText, defaultFilename: "budget-export") { _ in }
```

Note: the button's closure body is copied verbatim from the block removed in the first replacement above — same behavior (build `exportDocument`, set `showExporter = true`), only its position changed.

- [ ] **Step 2: Build**

Run: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -configuration Debug build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/Budget/BudgetGridView.swift
git commit -m "Move Budget's Export CSV button into a real toolbar item"
```

---

## Task 3: `UncategorizedView` — search

**Files:**
- Modify: `App/Uncategorized/UncategorizedView.swift`

**Interfaces:**
- Consumes: `UncategorizedViewModel.transactions: [Transaction]` (existing, unchanged), `Transaction.rawDescription: String` (existing, unchanged).
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Add search state and a filtered-list computed property**

Replace the full current file content with:

```swift
// App/Uncategorized/UncategorizedView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction

struct UncategorizedView: View {
    @ObservedObject var viewModel: UncategorizedViewModel
    @State private var searchText = ""

    /// `viewModel.transactions` filtered by a case-insensitive substring match against
    /// `rawDescription`. An empty `searchText` (the default) matches everything, so
    /// existing behavior is unchanged until the user actually types.
    private var filteredTransactions: [Transaction] {
        guard !searchText.isEmpty else { return viewModel.transactions }
        return viewModel.transactions.filter { $0.rawDescription.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            Group {
                if viewModel.transactions.isEmpty {
                    VStack(spacing: 8) {
                        Text("Nothing uncategorized").font(.headline)
                        Text("Every committed transaction has a category. If you expected something here, check Import.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filteredTransactions) { transaction in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(transaction.rawDescription)
                                Text(transaction.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            MoneyText(minorUnits: transaction.amountMinorUnits)
                            categoryPicker(for: transaction).frame(width: 200)
                        }
                    }
                }
            }
        }
        .padding()
        .searchable(text: $searchText, prompt: "Search descriptions")
    }

    private func categoryPicker(for transaction: Transaction) -> some View {
        Picker("", selection: Binding<Int64?>(
            get: { transaction.categoryId },
            set: { newValue in
                guard let newValue else { return }
                viewModel.assignCategory(transaction, to: newValue)
            }
        )) {
            Text("Uncategorized").tag(Int64?.none)
            ForEach(viewModel.categories) { category in Text(category.name).tag(Int64?.some(category.id!)) }
        }
        .labelsHidden()
    }
}
```

The only changes from the current file: the new `searchText` state, the new `filteredTransactions` computed property, `List(viewModel.transactions)` → `List(filteredTransactions)`, and the new `.searchable(...)` modifier. Everything else — `errorMessage` handling, the empty state, `categoryPicker(for:)` — is unchanged.

- [ ] **Step 2: Build**

Run: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -configuration Debug build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/Uncategorized/UncategorizedView.swift
git commit -m "Add search to the Uncategorized screen"
```

---

## Task 4: `RulesView` — search

**Files:**
- Modify: `App/Rules/RulesView.swift`

**Interfaces:**
- Consumes: `RulesViewModel.rules: [Rule]` (`App/Rules/RulesViewModel.swift:9`, existing, unchanged), `Rule.matchPattern: String` (existing, unchanged).
- Produces: nothing later tasks depend on. This is the last task in this plan.

- [ ] **Step 1: Add search state and a filtered-rules computed property**

Replace the full current file content (currently 29 lines) with:

```swift
// App/Rules/RulesView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

struct RulesView: View {
    @ObservedObject var viewModel: RulesViewModel
    @State private var searchText = ""

    /// `viewModel.rules` filtered by a case-insensitive substring match against
    /// `matchPattern`. An empty `searchText` (the default) matches everything, so
    /// existing behavior is unchanged until the user actually types.
    private var filteredRules: [Rule] {
        guard !searchText.isEmpty else { return viewModel.rules }
        return viewModel.rules.filter { $0.matchPattern.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        Table(filteredRules) {
            TableColumn("Pattern") { rule in Text(rule.matchPattern) }
            TableColumn("Type") { rule in Text(rule.matchType.rawValue) }
            TableColumn("Category") { rule in
                Picker("", selection: Binding(
                    get: { rule.categoryId },
                    set: { newValue in try? viewModel.updateCategory(rule, to: newValue) }
                )) {
                    ForEach(viewModel.categories) { category in Text(category.name).tag(category.id!) }
                }
                .labelsHidden()
            }
            TableColumn("Priority") { rule in Text("\(rule.priority)") }
            TableColumn("") { rule in
                Button("Delete") { try? viewModel.delete(rule) }
            }
        }
        .padding()
        .searchable(text: $searchText, prompt: "Search patterns")
    }
}
```

The only changes from the current file: the new `searchText` state, the new `filteredRules` computed property, `Table(viewModel.rules)` → `Table(filteredRules)`, and the new `.searchable(...)` modifier. Every `TableColumn` is unchanged.

- [ ] **Step 2: Build**

Run: `xcodegen generate && xcodebuild -project Budget.xcodeproj -scheme Budget -configuration Debug build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/Rules/RulesView.swift
git commit -m "Add search to the Rules screen"
```

### Final Verification (after this task, once all 4 tasks are complete)

This plan has no automated test coverage (pure SwiftUI presentation, no `BudgetCore` surface — see Global Constraints). Once all 4 tasks are committed, do one live manual walkthrough of the running app, launched fresh (kill any stale running instance first):

- Every one of the 8 sidebar rows shows its icon, and the three sections ("Workflow": Import, Uncategorized; "Overview": Budget, Forecast, Net Worth; "Settings": Rules, Categories, Accounts) appear in that order with the same screens in the same relative order as before this plan.
- Selecting each of the 8 screens updates the window's title bar to match that screen's name.
- On the Budget screen, "Export CSV…" now appears in the toolbar (top-right, next to the window controls) instead of inline in the content, and clicking it still opens the same save panel as before.
- On the Uncategorized screen (with at least one uncategorized transaction present), typing into the new search field filters the list by description, and clearing it shows everything again.
- On the Rules screen (with at least one rule present), typing into the new search field filters the table by pattern, and clearing it shows everything again.
- Every screen still looks correct in both light and dark mode (toggle via System Settings or `defaults write -g NSRequiresAquaSystemAppearance -bool false` / Xcode's environment overrides, whichever is available).
- Accounts and Categories screens are visually unchanged (no toolbar/search added to either, per the Global Constraints) — confirm their "Add account"/"Add Group" flows still work exactly as before.
