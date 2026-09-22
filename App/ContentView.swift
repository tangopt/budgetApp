// App/ContentView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import GRDB

enum AppScreen: String, CaseIterable, Identifiable {
    case importReview = "Import"
    case budgetGrid = "Budget"
    case forecast = "Forecast"
    case netWorth = "Net Worth"
    case rules = "Rules"
    case accounts = "Accounts"
    case settings = "Settings"
    var id: String { rawValue }
}

struct ContentView: View {
    @ObservedObject var environment: AppEnvironment
    @State private var selection: AppScreen? = .importReview
    @State private var selectedAccount: Account?
    @State private var accounts: [Account] = []
    @State private var categories: [Category] = []

    // Each screen's view model is owned once by ContentView and handed down as a
    // stable reference, rather than reconstructed inline in the switch below on
    // every body evaluation — reconstructing inline would discard loaded state
    // (and any in-progress edits) every time ContentView's own @State changes.
    @StateObject private var importViewModel: ImportViewModel
    @StateObject private var budgetGridViewModel: BudgetGridViewModel
    @StateObject private var forecastViewModel: ForecastViewModel
    @StateObject private var netWorthViewModel: NetWorthViewModel
    @StateObject private var rulesViewModel: RulesViewModel
    @StateObject private var accountsViewModel: AccountsSettingsViewModel

    private let profileStore: ImportProfileStore

    init(environment: AppEnvironment) {
        self.environment = environment
        let profileStore = ImportProfileStore(dbQueue: environment.dbQueue)
        self.profileStore = profileStore
        let categorizer = ClaudeCategorizer(apiKeyStore: KeychainAPIKeyStore(), session: .shared)
        let categorizationService = CategorizationService(categorizer: categorizer)
        let coordinator = ImportCoordinator(dbQueue: environment.dbQueue, categorizationService: categorizationService)
        _importViewModel = StateObject(wrappedValue: ImportViewModel(dbQueue: environment.dbQueue, coordinator: coordinator, profileStore: profileStore))
        _budgetGridViewModel = StateObject(wrappedValue: BudgetGridViewModel(dbQueue: environment.dbQueue))
        _forecastViewModel = StateObject(wrappedValue: ForecastViewModel(dbQueue: environment.dbQueue))
        _netWorthViewModel = StateObject(wrappedValue: NetWorthViewModel(dbQueue: environment.dbQueue))
        _rulesViewModel = StateObject(wrappedValue: RulesViewModel(dbQueue: environment.dbQueue))
        _accountsViewModel = StateObject(wrappedValue: AccountsSettingsViewModel(dbQueue: environment.dbQueue))
    }

    /// How far ahead to project forecasted pay periods in the Budget grid and Forecast screens.
    private var forecastHorizon: Date {
        Calendar.current.date(byAdding: .month, value: 3, to: Date()) ?? Date()
    }

    var body: some View {
        NavigationSplitView {
            List(AppScreen.allCases, selection: $selection) { screen in
                Text(screen.rawValue).tag(screen)
            }
        } detail: {
            Group {
                switch selection {
                case .importReview:
                    if let account = selectedAccount {
                        ImportView(
                            viewModel: importViewModel,
                            account: account, categories: categories, profileStore: profileStore
                        )
                    } else {
                        Text("Add an account under Accounts, then pick it here to import a statement.")
                    }
                case .budgetGrid:
                    BudgetGridView(viewModel: budgetGridViewModel)
                        .onAppear { try? budgetGridViewModel.load(horizon: forecastHorizon) }
                case .forecast:
                    ForecastComparisonView(viewModel: forecastViewModel, categories: categories)
                        .onAppear { try? forecastViewModel.load(horizon: forecastHorizon) }
                case .netWorth:
                    NetWorthView(viewModel: netWorthViewModel)
                        .onAppear { try? netWorthViewModel.load() }
                case .rules:
                    RulesView(viewModel: rulesViewModel)
                        .onAppear { try? rulesViewModel.load() }
                case .accounts:
                    AccountsSettingsView(viewModel: accountsViewModel)
                case .settings, .none:
                    APIKeySettingsView()
                }
            }
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
    }

    private func refreshSharedState() {
        categories = (try? environment.dbQueue.read { db in try Category.fetchAll(db) }) ?? []
        accounts = (try? environment.dbQueue.read { db in try Account.fetchAll(db) }) ?? []
        if selectedAccount == nil || !accounts.contains(where: { $0.id == selectedAccount?.id }) {
            selectedAccount = accounts.first
        }
    }
}
