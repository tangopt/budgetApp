// App/ContentView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import GRDB

enum AppScreen: String, CaseIterable, Identifiable {
    case importReview = "Import"
    case dashboard = "Dashboard"
    case budgetGrid = "Budget"
    case forecast = "Forecast"
    case accounts = "Accounts"
    case rules = "Rules"
    case categories = "Categories"
    case uncategorized = "Uncategorized"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .importReview: return "square.and.arrow.down"
        case .uncategorized: return "folder.badge.questionmark"
        case .dashboard: return "square.grid.2x2"
        case .budgetGrid: return "tablecells"
        case .forecast: return "chart.line.uptrend.xyaxis"
        case .rules: return "wand.and.stars"
        case .categories: return "tag"
        case .accounts: return "building.columns"
        }
    }

    /// The sidebar row's text: Uncategorized carries its count ("Uncategorized (12)").
    func sidebarTitle(uncategorizedCount: Int) -> String {
        self == .uncategorized ? "\(rawValue) (\(uncategorizedCount))" : rawValue
    }

    /// Sidebar section this screen's row is grouped under — see `ContentView.sidebarSections`,
    /// which groups `AppScreen.allCases` by this value while preserving the order each
    /// distinct value first appears in `allCases` (not alphabetically).
    var sidebarSection: String {
        switch self {
        case .importReview, .uncategorized: return "Workflow"
        case .dashboard, .budgetGrid, .forecast, .accounts: return "Overview"
        case .rules, .categories: return "Settings"
        }
    }
}

struct ContentView: View {
    @ObservedObject var environment: AppEnvironment
    @State private var selection: AppScreen? = .dashboard
    /// What the sidebar List shows as selected. A click lands here first and is then either
    /// accepted into `selection` or reverted (see `sidebarSelectionChanged`), so the
    /// sidebar highlight always matches the screen on show.
    @State private var sidebarSelection: AppScreen? = .dashboard
    /// Where the sidebar was asked to go while confirmed import rows were still unsaved;
    /// set while the "Save the N confirmed transactions?" alert is up.
    @State private var pendingSelection: AppScreen?
    @State private var showUnsavedImportAlert = false
    @State private var selectedImportAccountId: Int64?
    @State private var accounts: [Account] = []
    @State private var categories: [Category] = []
    /// Transactions still needing a category (`UncategorizedTransactions.count`): the
    /// Uncategorized sidebar row shows only while it's above zero.
    @State private var uncategorizedCount = 0
    @AppStorage("lastImportAccountId") private var lastImportAccountId = 0

    // Each screen's view model is owned once by ContentView and handed down as a
    // stable reference, rather than reconstructed inline in the switch below on
    // every body evaluation — reconstructing inline would discard loaded state
    // (and any in-progress edits) every time ContentView's own @State changes.
    @StateObject private var importViewModel: ImportViewModel
    @StateObject private var budgetGridViewModel: BudgetGridViewModel
    @StateObject private var scenarioLabViewModel: ScenarioLabViewModel
    @StateObject private var rulesViewModel: RulesViewModel
    @StateObject private var categoriesViewModel: CategoriesViewModel
    @StateObject private var uncategorizedViewModel: UncategorizedViewModel
    @StateObject private var accountsViewModel: AccountsViewModel
    @StateObject private var dashboardViewModel: DashboardViewModel

    private let profileStore: ImportProfileStore

    init(environment: AppEnvironment) {
        self.environment = environment
        let profileStore = ImportProfileStore(dbQueue: environment.dbQueue)
        self.profileStore = profileStore
        let categorizationService = CategorizationService(categorizer: OnDeviceCategorizer.systemDefault())
        let coordinator = ImportCoordinator(dbQueue: environment.dbQueue, categorizationService: categorizationService)
        _importViewModel = StateObject(wrappedValue: ImportViewModel(dbQueue: environment.dbQueue, coordinator: coordinator, profileStore: profileStore))
        _budgetGridViewModel = StateObject(wrappedValue: BudgetGridViewModel(dbQueue: environment.dbQueue))
        _scenarioLabViewModel = StateObject(wrappedValue: ScenarioLabViewModel(dbQueue: environment.dbQueue))
        _rulesViewModel = StateObject(wrappedValue: RulesViewModel(dbQueue: environment.dbQueue))
        _categoriesViewModel = StateObject(wrappedValue: CategoriesViewModel(dbQueue: environment.dbQueue))
        _uncategorizedViewModel = StateObject(wrappedValue: UncategorizedViewModel(dbQueue: environment.dbQueue))
        _accountsViewModel = StateObject(wrappedValue: AccountsViewModel(dbQueue: environment.dbQueue))
        _dashboardViewModel = StateObject(wrappedValue: DashboardViewModel(dbQueue: environment.dbQueue))
    }

    /// How far ahead to project forecasted pay periods in the Budget grid (the Forecast
    /// screen's scenario lab has its own horizon picker).
    private var forecastHorizon: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let year = calendar.component(.year, from: Date())
        var components = DateComponents(); components.year = year; components.month = 12; components.day = 31
        return calendar.date(from: components) ?? Date()
    }

    /// Whether the screen has a sidebar row right now (spec §6): Import only while an
    /// import is staging or in review, Uncategorized only while something needs a category.
    private func isInSidebar(_ screen: AppScreen) -> Bool {
        switch screen {
        case .importReview: return importViewModel.isStaging || importViewModel.isReviewing
        case .uncategorized: return uncategorizedCount > 0
        default: return true
        }
    }

    /// The visible `AppScreen.allCases` grouped by `sidebarSection`, one entry per distinct
    /// section value in the order that value first appears in `allCases` — not
    /// alphabetically, so "Workflow" → "Overview" → "Settings" (driven by `.importReview`
    /// being first in `allCases`, `.dashboard` being the first `.sidebarSection ==
    /// "Overview"` case, etc.) stays stable regardless of where a section's later members
    /// (e.g. `.uncategorized`) happen to sit in `allCases`' own declaration order. A section
    /// with no visible screens (Workflow, when there's nothing to import or assign) is left
    /// out, header and all.
    private var sidebarSections: [(name: String, screens: [AppScreen])] {
        var order: [String] = []
        var grouped: [String: [AppScreen]] = [:]
        for screen in AppScreen.allCases where isInSidebar(screen) {
            let section = screen.sidebarSection
            if grouped[section] == nil {
                order.append(section)
            }
            grouped[section, default: []].append(screen)
        }
        return order.map { (name: $0, screens: grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $sidebarSelection) {
                ForEach(sidebarSections, id: \.name) { section in
                    Section(section.name) {
                        ForEach(section.screens) { screen in
                            Label(screen.sidebarTitle(uncategorizedCount: uncategorizedCount), systemImage: screen.systemImage).tag(screen)
                        }
                    }
                }
            }
        } detail: {
            Group {
                switch selection {
                case .dashboard:
                    DashboardView(
                        viewModel: dashboardViewModel, importViewModel: importViewModel,
                        accounts: accounts, selectedImportAccountId: $selectedImportAccountId,
                        profileStore: profileStore, navigate: { selection = $0 }
                    )
                    .onAppear { dashboardViewModel.load() }
                case .importReview:
                    // Account and file are picked on the Dashboard's import card (spec §6).
                    ImportView(viewModel: importViewModel)
                case .budgetGrid:
                    BudgetGridView(viewModel: budgetGridViewModel)
                        .onAppear { try? budgetGridViewModel.load(horizon: forecastHorizon) }
                case .forecast:
                    ScenarioLabView(viewModel: scenarioLabViewModel)
                        .onAppear { scenarioLabViewModel.load() }
                case .rules:
                    RulesView(viewModel: rulesViewModel)
                        .onAppear { try? rulesViewModel.load() }
                case .categories:
                    CategoriesView(viewModel: categoriesViewModel)
                case .uncategorized:
                    UncategorizedView(viewModel: uncategorizedViewModel)
                        .onAppear { try? uncategorizedViewModel.load() }
                case .accounts:
                    AccountsView(viewModel: accountsViewModel, environment: environment,
                                 importViewModel: importViewModel, profileStore: profileStore,
                                 navigate: { selection = $0 })
                        .onAppear { accountsViewModel.load() }
                case .none:
                    Text("Select a screen from the sidebar.")
                }
            }
            .navigationTitle(selection?.rawValue ?? "Budget")
        }
        .alert(
            "Save the \(importViewModel.confirmedCount) confirmed transaction\(importViewModel.confirmedCount == 1 ? "" : "s")?",
            isPresented: $showUnsavedImportAlert
        ) {
            Button("Save") {
                // Saves only the confirmed rows; on failure stay on the review to show why.
                if importViewModel.finish(unconfirmed: .leaveOut) { selection = pendingSelection }
            }
            Button("Discard", role: .destructive) {
                importViewModel.cancel()
                selection = pendingSelection
            }
            Button("Keep reviewing", role: .cancel) {}
        } message: {
            Text("Nothing from this import has been saved yet. Unconfirmed transactions aren't saved either way.")
        }
        // A CSV for another account (spec 2026-10-15 §5), from the Dashboard or Accounts screen.
        .alert(
            "This statement looks like it's for a different account",
            isPresented: Binding(get: { importViewModel.accountMismatch != nil }, set: { if !$0 { importViewModel.accountMismatch = nil } }),
            presenting: importViewModel.accountMismatch
        ) { prompt in
            Button("Cancel", role: .cancel) { importViewModel.accountMismatch = nil }
                .keyboardShortcut(.defaultAction)
            Button("Import anyway") { Task { await importViewModel.importAnyway(prompt) } }
        } message: { prompt in
            Text(prompt.message)
        }
        .onAppear {
            // An Edit transaction save (Budget grid, Categories panel) can add or clear an uncategorised one.
            budgetGridViewModel.onTransactionEdited = { refreshUncategorizedCount() }
            categoriesViewModel.onTransactionEdited = { refreshUncategorizedCount() }
            accountsViewModel.onTransactionAdded = { refreshUncategorizedCount() }
            refreshSharedState()
        }
        .onChange(of: importViewModel.isStaging) { _, staging in
            // Staging starts from the Dashboard's import card or the Accounts screen: follow
            // it to the Import screen, which has just appeared in the sidebar.
            if staging { selection = .importReview } else { importActivityChanged() }
        }
        .onChange(of: importViewModel.isReviewing) { importActivityChanged() }
        .onChange(of: uncategorizedViewModel.transactions) {
            // Assigning on the Uncategorized screen removes rows; the last one hides the
            // screen and returns to the Dashboard.
            refreshUncategorizedCount()
        }
        .onChange(of: sidebarSelection) { _, newValue in sidebarSelectionChanged(to: newValue) }
        .onChange(of: selection) {
            // Screens can also be changed in code (the Dashboard's links, the alert below).
            if sidebarSelection != selection { sidebarSelection = selection }
            // Re-read accounts/categories on every navigation so a newly-added
            // account (via the Accounts screen) or category shows up immediately
            // in the Dashboard's import picker and the Forecast/Budget category lists,
            // without requiring an app relaunch. This also refreshes the uncategorised
            // count, then falls back to the Dashboard if the new screen has no row.
            refreshSharedState()
        }
        .onChange(of: accountsViewModel.accounts) {
            refreshSharedState()
        }
        .onChange(of: selectedImportAccountId) {
            if let id = selectedImportAccountId { lastImportAccountId = Int(id) }
        }
        .onChange(of: environment.exchangeRateBanner) {
            // The EUR rate refreshes asynchronously after launch; the dashboard's net worth
            // and forecast figures (and the Accounts screen's GBP totals) depend on it, so
            // recompute whichever of them is on screen.
            if selection == .dashboard { dashboardViewModel.load() }
            if selection == .accounts { accountsViewModel.load() }
        }
    }

    /// The sidebar's selection, guarded: leaving the Import screen while confirmed rows are
    /// unsaved asks first (confirming no longer saves anything — Finish import does). A
    /// refused click is reverted on the next runloop turn, since the sidebar's outline view
    /// keeps the clicked row highlighted if the change is just ignored.
    private func sidebarSelectionChanged(to newValue: AppScreen?) {
        guard newValue != selection else { return }
        if selection == .importReview, importViewModel.isReviewing, importViewModel.confirmedCount > 0 {
            pendingSelection = newValue
            showUnsavedImportAlert = true
            DispatchQueue.main.async { sidebarSelection = selection }
        } else {
            selection = newValue
        }
    }

    /// An import finished, was cancelled, or failed to stage: the Import row leaves the
    /// sidebar (back to the Dashboard if it was showing), and a saved import may have added
    /// uncategorised transactions.
    private func importActivityChanged() {
        refreshUncategorizedCount()
    }

    private func refreshUncategorizedCount() {
        // A failed read keeps the last count rather than hiding the row.
        if let count = try? environment.dbQueue.read({ db in try UncategorizedTransactions.count(db: db) }) {
            uncategorizedCount = count
        }
        // Also covers the import ending (`importActivityChanged`).
        ensureSelectionInSidebar()
    }

    /// A selection whose row isn't in the sidebar (the import ended, the last uncategorised
    /// transaction was assigned) falls back to the Dashboard.
    private func ensureSelectionInSidebar() {
        // SwiftUI's List may nil the selection when the selected row disappears.
        guard let selection else { self.selection = .dashboard; return }
        if !isInSidebar(selection) { self.selection = .dashboard }
    }

    private var selectedImportAccount: Account? {
        accounts.first { $0.id == selectedImportAccountId }
    }

    private func refreshSharedState() {
        categories = (try? environment.dbQueue.read { db in try Category.fetchAll(db) }.filter(\.isAssignable)) ?? []
        accounts = (try? environment.dbQueue.read { db in try Account.fetchAll(db) })?.sortedForDisplay() ?? []
        refreshUncategorizedCount()
        // Keep the user's choice across navigation; otherwise default to the last-used
        // account (remembered across launches), then the first account.
        if selectedImportAccount == nil {
            selectedImportAccountId = accounts.first { Int($0.id ?? -1) == lastImportAccountId }?.id ?? accounts.first?.id
        }
    }
}
