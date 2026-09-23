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
    var id: String { rawValue }
}

struct ContentView: View {
    @ObservedObject var environment: AppEnvironment
    @State private var selection: AppScreen? = .importReview
    @State private var selectedImportAccountId: Int64?
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
        let categorizationService = CategorizationService(categorizer: OnDeviceCategorizer.systemDefault())
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
                    if importableAccounts.isEmpty {
                        Text("Add an account with tracking mode \"imported\" under Accounts, then pick it here to import a statement.")
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            Picker("Import into", selection: $selectedImportAccountId) {
                                ForEach(importableAccounts) { account in
                                    Text("\(account.name) (\(account.currency.rawValue.uppercased()))").tag(Int64?.some(account.id!))
                                }
                            }
                            .frame(maxWidth: 360)
                            .padding([.horizontal, .top])
                            // The staged rows belong to the account they were staged for;
                            // switching mid-review would be misleading.
                            .disabled(importViewModel.isReviewing)
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
                case .none:
                    Text("Select a screen from the sidebar.")
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

    /// Only `.imported` accounts receive statement imports; `.manual` accounts are
    /// balance-only (updated from the Net Worth screen).
    private var importableAccounts: [Account] {
        accounts.filter { $0.trackingMode == .imported }
    }

    private var selectedImportAccount: Account? {
        importableAccounts.first { $0.id == selectedImportAccountId }
    }

    private func refreshSharedState() {
        categories = (try? environment.dbQueue.read { db in try Category.fetchAll(db) }) ?? []
        accounts = (try? environment.dbQueue.read { db in try Account.fetchAll(db) }) ?? []
        // Keep the user's choice across navigation; fall back to the first importable
        // account only when nothing (valid) is selected yet.
        if selectedImportAccount == nil {
            selectedImportAccountId = importableAccounts.first?.id
        }
    }
}
