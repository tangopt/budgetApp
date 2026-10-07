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
    @State private var selectedImportAccountId: Int64?
    @State private var accounts: [Account] = []
    @State private var categories: [Category] = []
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

    /// `AppScreen.allCases` grouped by `sidebarSection`, one entry per distinct section
    /// value in the order that value first appears in `allCases` — not alphabetically, so
    /// "Workflow" → "Overview" → "Settings" (driven by `.importReview` being first in
    /// `allCases`, `.dashboard` being the first `.sidebarSection == "Overview"` case, etc.)
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

    var body: some View {
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
                    if accounts.isEmpty {
                        Text("Add an account under Accounts, then pick it here to import a statement.")
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            Picker("Import into", selection: $selectedImportAccountId) {
                                ForEach(accounts) { account in
                                    Text("\(account.name) (\(account.currency.rawValue.uppercased()))").tag(Int64?.some(account.id!))
                                }
                            }
                            .frame(maxWidth: 360)
                            .padding([.horizontal, .top])
                            // The staged rows belong to the account they were staged for;
                            // switching mid-review would be misleading.
                            .disabled(importViewModel.isReviewing)
                            NonGBPImportCaption(account: selectedImportAccount)
                                .padding(.horizontal)
                            if let account = selectedImportAccount {
                                ImportView(
                                    viewModel: importViewModel,
                                    account: account, categories: categories, profileStore: profileStore
                                )
                            }
                        }
                    }
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
                    AccountsView(viewModel: accountsViewModel, environment: environment)
                        .onAppear { accountsViewModel.load() }
                case .none:
                    Text("Select a screen from the sidebar.")
                }
            }
            .navigationTitle(selection?.rawValue ?? "Budget")
        }
        .onAppear {
            refreshSharedState()
        }
        .onChange(of: selection) { _ in
            // Re-read accounts/categories on every navigation so a newly-added
            // account (via the Accounts screen) or category shows up immediately
            // in Import's account picker and the Forecast/Budget category lists,
            // without requiring an app relaunch.
            refreshSharedState()
        }
        .onChange(of: accountsViewModel.accounts) { _ in
            refreshSharedState()
        }
        .onChange(of: selectedImportAccountId) { _ in
            if let id = selectedImportAccountId { lastImportAccountId = Int(id) }
        }
        .onChange(of: environment.exchangeRateBanner) { _ in
            // The EUR rate refreshes asynchronously after launch; the dashboard's net worth
            // and forecast figures (and the Accounts screen's GBP totals) depend on it, so
            // recompute whichever of them is on screen.
            if selection == .dashboard { dashboardViewModel.load() }
            if selection == .accounts { accountsViewModel.load() }
        }
    }

    private var selectedImportAccount: Account? {
        accounts.first { $0.id == selectedImportAccountId }
    }

    private func refreshSharedState() {
        categories = (try? environment.dbQueue.read { db in try Category.fetchAll(db) }.filter(\.isAssignable)) ?? []
        accounts = (try? environment.dbQueue.read { db in try Account.fetchAll(db) }) ?? []
        // Keep the user's choice across navigation; otherwise default to the last-used
        // account (remembered across launches), then the first account.
        if selectedImportAccount == nil {
            selectedImportAccountId = accounts.first { Int($0.id ?? -1) == lastImportAccountId }?.id ?? accounts.first?.id
        }
    }
}
