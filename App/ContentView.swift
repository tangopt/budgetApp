// App/ContentView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction
import GRDB

enum AppScreen: String, CaseIterable, Identifiable {
    case importReview = "Import"
    /// The document importer: reading, review and the import history.
    case imports = "Imports"
    case dashboard = "Dashboard"
    case search = "Search"
    case budgetGrid = "Budget"
    case forecast = "Forecast"
    case accounts = "Accounts"
    /// One sidebar row per property (`ContentView.sidebarRows`); "Property" while there is none.
    case property = "Property"
    case taxYears = "Tax years"
    case documents = "Documents"
    case missingEvidence = "Missing evidence"
    case rules = "Rules"
    case categories = "Categories"
    case uncategorized = "Uncategorized"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .importReview: return "square.and.arrow.down"
        case .imports: return "tray.and.arrow.down"
        case .uncategorized: return "folder.badge.questionmark"
        case .dashboard: return "square.grid.2x2"
        case .search: return "magnifyingglass"
        case .budgetGrid: return "tablecells"
        case .forecast: return "chart.line.uptrend.xyaxis"
        case .rules: return "wand.and.stars"
        case .categories: return "tag"
        case .accounts: return "building.columns"
        case .property: return "house"
        case .taxYears: return "doc.text"
        case .documents: return "doc.on.doc"
        case .missingEvidence: return "checklist"
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
        case .importReview, .imports, .uncategorized: return "Workflow"
        case .dashboard, .search, .budgetGrid, .forecast, .accounts, .property: return "Overview"
        case .taxYears, .documents, .missingEvidence: return "Tax"
        case .rules, .categories: return "Settings"
        }
    }
}

/// A sidebar row: a screen, or one property's page.
enum SidebarItem: Hashable {
    case screen(AppScreen)
    case property(Int64)
}

struct ContentView: View {
    @ObservedObject var environment: AppEnvironment
    @State private var selection: AppScreen? = .dashboard
    /// What the sidebar List shows as selected. A click lands here first and is then either
    /// accepted into `selection` or reverted (see `sidebarSelectionChanged`), so the
    /// sidebar highlight always matches the screen on show.
    @State private var sidebarSelection: SidebarItem? = .screen(.dashboard)
    /// The properties listed in the sidebar (Overview, after Accounts).
    @State private var properties: [Property] = []
    /// The split view's columns, toggled by the toolbar's own sidebar button (the system one
    /// can't drop its glass capsule).
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Where the sidebar was asked to go while confirmed import rows were still unsaved;
    /// set while the "Save the N confirmed transactions?" alert is up.
    @State private var pendingSelection: AppScreen?
    /// The property row asked for with `pendingSelection` (applied on Save / Discard).
    @State private var pendingPropertyId: Int64?
    @State private var showUnsavedImportAlert = false
    @State private var selectedImportAccountId: Int64?
    @State private var accounts: [Account] = []
    @State private var categories: [Category] = []
    /// Transactions still needing a category (`UncategorizedTransactions.count`): the
    /// Uncategorized sidebar row shows only while it's above zero.
    @State private var uncategorizedCount = 0
    @AppStorage("lastImportAccountId") private var lastImportAccountId = 0
    /// Show in Budget has just loaded the Budget grid's data (so its appearance needn't).
    @State private var budgetGridJustLoaded = false
    /// Files are being dragged over the window (the import drop target's outline).
    @State private var importDropTargeted = false
    @Environment(\.theme) private var theme

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
    /// Kept for the app session: the search, its filters and sort survive navigation.
    @StateObject private var searchViewModel: SearchViewModel
    /// Kept for the app session, like Search: the document search and filters survive navigation.
    @StateObject private var documentsViewModel: DocumentsViewModel
    /// Kept for the app session: the period and filters survive navigation.
    @StateObject private var missingEvidenceViewModel: MissingEvidenceViewModel
    /// The property page on show (`propertyId`), kept for the session like the others. Held,
    /// not observed: the page observes it, so its frequent changes (a side panel opening, a
    /// receipt selected) redraw the page alone rather than the whole window. The window's
    /// title follows its property's name (`propertyName`).
    @State private var propertyViewModel: PropertyViewModel
    /// The property page's name, for the window's title.
    @State private var propertyName: String?
    /// Kept for the app session: the year on show and its tab survive navigation.
    @StateObject private var taxYearsViewModel: TaxYearsViewModel

    private let profileStore: ImportProfileStore
    /// The snapshot harness only: the screen to open on and the state to set up on it.
    private let snapshotSetup: SnapshotSetup?

    init(environment: AppEnvironment, snapshotSetup: SnapshotSetup? = nil) {
        self.environment = environment
        self.snapshotSetup = snapshotSetup
        if let screen = snapshotSetup?.screen {
            _selection = State(initialValue: screen)
            _sidebarSelection = State(initialValue: .screen(screen))
        }
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
        _searchViewModel = StateObject(wrappedValue: SearchViewModel(dbQueue: environment.dbQueue))
        _documentsViewModel = StateObject(wrappedValue: DocumentsViewModel(dbQueue: environment.dbQueue, library: environment.evidenceLibrary))
        _missingEvidenceViewModel = StateObject(wrappedValue: MissingEvidenceViewModel(dbQueue: environment.dbQueue, library: environment.evidenceLibrary))
        _propertyViewModel = State(initialValue: PropertyViewModel(dbQueue: environment.dbQueue, library: environment.evidenceLibrary,
                                                                                     indexAutoFetch: environment.interestIndexAutoFetch))
        _taxYearsViewModel = StateObject(wrappedValue: TaxYearsViewModel(dbQueue: environment.dbQueue, library: environment.evidenceLibrary,
                                                                               rateAutoFetch: environment.hmrcRateAutoFetch))
    }

    /// How far ahead to project forecasted pay periods in the Budget grid (the Forecast
    /// screen's scenario lab has its own horizon picker).
    private var forecastHorizon: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let year = calendar.component(.year, from: AppClock.now)
        var components = DateComponents(); components.year = year; components.month = 12; components.day = 31
        return calendar.date(from: components) ?? AppClock.now
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
    /// alphabetically, so "Workflow" → "Overview" → "Tax" → "Settings" (driven by `.importReview`
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
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $sidebarSelection) {
                ForEach(sidebarSections, id: \.name) { section in
                    Section(section.name) {
                        ForEach(section.screens) { screen in
                            if screen == .property, !properties.isEmpty {
                                ForEach(properties) { property in
                                    Label(property.name, systemImage: screen.systemImage).tag(SidebarItem.property(property.id!))
                                }
                            } else {
                                Label(screen.sidebarTitle(uncategorizedCount: uncategorizedCount), systemImage: screen.systemImage)
                                    .tag(SidebarItem.screen(screen))
                            }
                        }
                    }
                }
            }
            // The sidebar's selection keeps the system accent whatever the theme.
            .tint(nil)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SidebarSettingsButton()
            }
            // The whole column, title bar and Settings button included: without it the sidebar is
            // the content area's colour in dark mode (see `SidebarMaterial`).
            .background { SidebarMaterial().ignoresSafeArea() }
            // Replaced by the borderless toggle below.
            .toolbar(removing: .sidebarToggle)
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
                case .search:
                    SearchView(viewModel: searchViewModel, showInBudget: showInBudget)
                case .importReview:
                    // Account and file are picked on the Dashboard's import card (spec §6).
                    ImportView(viewModel: importViewModel)
                case .imports:
                    ImportsScreen(center: environment.importCenter)
                case .budgetGrid:
                    BudgetGridView(viewModel: budgetGridViewModel)
                        .onAppear {
                            if budgetGridJustLoaded { budgetGridJustLoaded = false } else { try? budgetGridViewModel.load(horizon: forecastHorizon) }
                        }
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
                case .taxYears:
                    TaxYearsView(viewModel: taxYearsViewModel, missingEvidenceViewModel: missingEvidenceViewModel, openTransaction: openTransaction)
                case .documents:
                    DocumentsView(viewModel: documentsViewModel, openTransaction: openTransaction)
                case .missingEvidence:
                    MissingEvidenceView(viewModel: missingEvidenceViewModel, openTransaction: openTransaction)
                case .property:
                    PropertyView(viewModel: propertyViewModel, openTransaction: openTransaction, openMissingEvidence: { id, name in
                        missingEvidenceViewModel.propertyFilter = .init(propertyId: id, name: name)
                        selection = .missingEvidence
                    }, showDocument: { id in
                        documentsViewModel.reveal(id)
                        selection = .documents
                    })
                case .none:
                    Text("Select a screen from the sidebar.")
                }
            }
            .navigationTitle(selection == .property ? (propertyName ?? "Property") : (selection?.rawValue ?? "Budget"))
            .onReceive(propertyViewModel.$snapshot) { snapshot in
                if snapshot.property?.name != propertyName { propertyName = snapshot.property?.name }
            }
            // Files and folders dropped anywhere on a screen go to the document importer
            // (a screen's own drop target, e.g. Documents', takes its drops first).
            .overlay {
                if importDropTargeted {
                    // The Documents drop zone's outline (no design-system token for it).
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(theme.accent, lineWidth: 2)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                environment.importCenter.start(files, intent: .none, entryPoint: "Drop")
                return true
            } isTargeted: { importDropTargeted = $0 }
            // The theme's window colour behind every screen (clear for Classic).
            .background(theme.windowBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    SidebarToggleButton(columnVisibility: $columnVisibility)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) {
                    Button { documentImport.pickFiles(.none, "Toolbar") } label: {
                        Label("Import…", systemImage: "square.and.arrow.down.on.square")
                    }
                    .buttonStyle(.borderless)
                    .help("Import documents (⇧⌘I)")
                    .accessibilityLabel("Import documents")
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .environment(\.documentImport, documentImport)
        .alert(
            "Save the \(importViewModel.confirmedCount) confirmed transaction\(importViewModel.confirmedCount == 1 ? "" : "s")?",
            isPresented: $showUnsavedImportAlert
        ) {
            Button("Save") {
                // Saves only the confirmed rows; on failure stay on the review to show why.
                if importViewModel.finish(unconfirmed: .leaveOut) { applyPendingSelection() }
            }
            Button("Discard", role: .destructive) {
                importViewModel.cancel()
                applyPendingSelection()
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
            searchViewModel.onTransactionEdited = { refreshUncategorizedCount() }
            rulesViewModel.onTransactionsCategorised = { refreshUncategorizedCount() }
            propertyViewModel.onPropertiesChanged = { id in refreshProperties(select: id) }
            environment.importCenter.onShow = { sidebarSelectionChanged(to: .screen(.imports)) }
            environment.importCenter.onDataChanged = { documentImportChangedData() }
            refreshSharedState()
            snapshotSetup?.prepare(SnapshotScreenModels(
                dashboard: dashboardViewModel, budgetGrid: budgetGridViewModel, scenarioLab: scenarioLabViewModel,
                accounts: accountsViewModel, categories: categoriesViewModel, search: searchViewModel,
                documents: documentsViewModel, missingEvidence: missingEvidenceViewModel, property: propertyViewModel,
                taxYears: taxYearsViewModel, rules: rulesViewModel, uncategorized: uncategorizedViewModel,
                importReview: importViewModel))
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
        // ⌘F (Edit ▸ Search Transactions) in this window: the Search screen, its field focused.
        .focusedSceneValue(\.transactionSearch, TransactionSearchAction {
            sidebarSelectionChanged(to: .screen(.search))
            searchViewModel.requestFocus()
        })
        // File ▸ Import… (⇧⌘I) in this window.
        .focusedSceneValue(\.documentImport, documentImport)
        .onChange(of: selection) {
            // Screens can also be changed in code (the Dashboard's links, the alert below).
            if sidebarSelection != currentSidebarItem { sidebarSelection = currentSidebarItem }
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

    /// The window's document importer: File ▸ Import…, the toolbar button, screens' shortcuts.
    private var documentImport: DocumentImportAction {
        DocumentImportAction.forCenter(environment.importCenter)
    }

    /// A document import was applied or undone: what it may have changed is read again.
    private func documentImportChangedData() {
        refreshSharedState()
        if selection == .dashboard { dashboardViewModel.load() }
        if selection == .accounts { accountsViewModel.load() }
    }

    /// Search's Show in Budget: the Budget grid on the transaction's pay year, with its
    /// category/month cell's side panel open.
    private func showInBudget(_ transaction: Transaction) {
        guard let categoryId = transaction.categoryId else { return }
        // Fresh data first, so the pay calendar places the transaction's month; the grid's
        // own appearance then skips its load.
        try? budgetGridViewModel.load(horizon: forecastHorizon)
        budgetGridViewModel.reveal(categoryId: categoryId, date: transaction.date, accountId: transaction.accountId)
        budgetGridJustLoaded = true
        selection = .budgetGrid
    }

    /// Show where it lives (Property, Recharges, Tax sources, Documents, Missing evidence):
    /// the Search screen narrowed to the transaction's day and account, its row selected and
    /// scrolled to, whatever its category or account (the Budget grid's cells don't list
    /// transfers, uncategorised or non-budget transactions, nor point at one row).
    private func openTransaction(_ transaction: Transaction) {
        searchViewModel.reveal(transaction)
        selection = .search
    }

    /// The sidebar's selection, guarded: leaving the Import screen while confirmed rows are
    /// unsaved asks first (confirming no longer saves anything — Finish import does). A
    /// refused click is reverted on the next runloop turn, since the sidebar's outline view
    /// keeps the clicked row highlighted if the change is just ignored.
    private func sidebarSelectionChanged(to item: SidebarItem?) {
        guard item != currentSidebarItem else { return }
        let newValue: AppScreen?
        switch item {
        case let .screen(screen): newValue = screen
        case .property: newValue = .property
        case nil: newValue = nil
        }
        if selection == .importReview, importViewModel.isReviewing, importViewModel.confirmedCount > 0 {
            pendingSelection = newValue
            if case let .property(id) = item { pendingPropertyId = id } else { pendingPropertyId = nil }
            showUnsavedImportAlert = true
            DispatchQueue.main.async { sidebarSelection = currentSidebarItem }
        } else {
            if case let .property(id) = item { propertyViewModel.propertyId = id }
            if selection == newValue {
                // Another property: the screen stays, the row follows.
                sidebarSelection = currentSidebarItem
            }
            selection = newValue
        }
    }

    private func applyPendingSelection() {
        if let id = pendingPropertyId { propertyViewModel.propertyId = id }
        pendingPropertyId = nil
        selection = pendingSelection
    }

    /// The sidebar row of the screen on show.
    private var currentSidebarItem: SidebarItem? {
        guard let selection else { return nil }
        if selection == .property, let id = propertyViewModel.propertyId, properties.contains(where: { $0.id == id }) {
            return .property(id)
        }
        return .screen(selection)
    }

    /// Re-reads the sidebar's properties; `select` (a property just added) is shown.
    private func refreshProperties(select: Int64? = nil) {
        properties = (try? environment.dbQueue.read { db in try Properties.all(db: db) }) ?? []
        if let select {
            propertyViewModel.propertyId = select
            selection = .property
        } else if !properties.contains(where: { $0.id == propertyViewModel.propertyId }) {
            propertyViewModel.propertyId = properties.first?.id
        }
        if sidebarSelection != currentSidebarItem { sidebarSelection = currentSidebarItem }
    }

    /// An import finished, was cancelled, or failed to stage: the Import row leaves the
    /// sidebar (back to the Dashboard if it was showing), and a saved import may have added
    /// uncategorised transactions.
    private func importActivityChanged() {
        refreshUncategorizedCount()
        // A finished (or discarded) import: the screen on show re-reads, so each account's
        // "Imported up to" date reflects what was just saved.
        guard !importViewModel.isStaging, !importViewModel.isReviewing else { return }
        if selection == .dashboard { dashboardViewModel.load() }
        if selection == .accounts { accountsViewModel.load() }
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
        refreshProperties()
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


/// The sidebar's foot: opens the Settings window (also Budget ▸ Settings…, ⌘,).
private struct SidebarSettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            openSettings()
        } label: {
            Image(systemName: "gearshape")
                .imageScale(.large)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Settings")
        .accessibilityLabel("Settings")
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }
}

/// The window's Hide/Show sidebar button: the system toggle's job (⌃⌘S included) without
/// its glass capsule.
private struct SidebarToggleButton: View {
    @Binding var columnVisibility: NavigationSplitViewVisibility

    private var sidebarShown: Bool { columnVisibility != .detailOnly }

    var body: some View {
        Button {
            withAnimation { columnVisibility = sidebarShown ? .detailOnly : .all }
        } label: {
            Image(systemName: "sidebar.left")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("s", modifiers: [.control, .command])
        .help(sidebarShown ? "Hide sidebar" : "Show sidebar")
        .accessibilityLabel(sidebarShown ? "Hide sidebar" : "Show sidebar")
    }
}
