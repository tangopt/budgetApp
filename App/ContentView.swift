// App/ContentView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction
import GRDB

enum AppScreen: String, CaseIterable, Identifiable {
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
    case salary = "UK Salary Calculator"
    case rules = "Rules"
    case categories = "Categories"
    case uncategorized = "Uncategorized"
    /// Everything Mango expects a document for and has none: tax, tenancy and property (step 20).
    case missingDocuments = "Missing documents"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .imports: return "tray.and.arrow.down"
        case .uncategorized: return "folder.badge.questionmark"
        case .dashboard: return "square.grid.2x2"
        case .search: return "magnifyingglass"
        case .budgetGrid: return "tablecells"
        case .forecast: return "chart.line.uptrend.xyaxis"
        case .salary: return "sterlingsign.circle"
        case .rules: return "wand.and.stars"
        case .categories: return "tag"
        case .accounts: return "building.columns"
        case .property: return "house"
        case .taxYears: return "doc.text"
        case .documents: return "doc.on.doc"
        case .missingEvidence: return "checklist"
        case .missingDocuments: return "doc.badge.ellipsis"
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
        case .imports, .uncategorized, .missingDocuments: return "Workflow"
        case .dashboard, .search, .budgetGrid, .forecast, .accounts, .property: return "Overview"
        case .taxYears, .documents, .missingEvidence, .salary: return "Tax"
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
    /// This view's window, which the importer brings forward (Settings ▸ Scan Now).
    @State private var windowHolder = WindowHolder()
    /// What the sidebar List shows as selected. A click lands here first and is then either
    /// accepted into `selection` or reverted (see `sidebarSelectionChanged`), so the
    /// sidebar highlight always matches the screen on show.
    @State private var sidebarSelection: SidebarItem? = .screen(.dashboard)
    /// The properties listed in the sidebar (Overview, after Accounts).
    @State private var properties: [Property] = []
    /// The split view's columns, toggled by the toolbar's own sidebar button (the system one
    /// can't drop its glass capsule).
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selectedImportAccountId: Int64?
    @State private var accounts: [Account] = []
    @State private var categories: [Category] = []
    /// Transactions still needing a category (`UncategorizedTransactions.count`): the
    /// Uncategorized sidebar row shows only while it's above zero.
    @State private var uncategorizedCount = 0
    /// An import is being read, reviewed or applied (`ImportCenterModel.phase`): the Imports
    /// sidebar row shows only then, or while its screen is on show.
    @State private var importActive = false
    @AppStorage("lastImportAccountId") private var lastImportAccountId = 0
    /// Show in Budget has just loaded the Budget grid's data (so its appearance needn't).
    @State private var budgetGridJustLoaded = false
    /// Files are being dragged over the window (the import drop target's outline).
    @State private var importDropTargeted = false
    @Environment(\.theme) private var theme
    /// The lock screen covers this window (`lockOverlay`).
    @Environment(\.isLockCovered) private var lockCovered

    // Each screen's view model is owned once by ContentView and handed down as a
    // stable reference, rather than reconstructed inline in the switch below on
    // every body evaluation — reconstructing inline would discard loaded state
    // (and any in-progress edits) every time ContentView's own @State changes.
    @StateObject private var budgetGridViewModel: BudgetGridViewModel
    @StateObject private var scenarioLabViewModel: ScenarioLabViewModel
    /// Kept on this device between launches (`SalaryDraftStore`), except in the snapshot build.
    @State private var salaryViewModel: SalaryComparisonViewModel
    @StateObject private var rulesViewModel: RulesViewModel
    @StateObject private var categoriesViewModel: CategoriesViewModel
    @StateObject private var uncategorizedViewModel: UncategorizedViewModel
    @StateObject private var accountsViewModel: AccountsViewModel
    @StateObject private var dashboardViewModel: DashboardViewModel
    /// Kept for the app session: the search, its filters and sort survive navigation.
    @StateObject private var searchViewModel: SearchViewModel
    /// Kept for the app session, like Search: the document search and filters survive navigation.
    @StateObject private var documentsViewModel: DocumentsViewModel
    /// The custom kinds' names, for every screen that shows a document's kind.
    @StateObject private var documentKindsModel: DocumentKindsModel
    /// Kept for the app session: the period and filters survive navigation.
    @StateObject private var missingEvidenceViewModel: MissingEvidenceViewModel
    /// The Missing documents centre; also counts for the sidebar badge.
    @StateObject private var missingDocumentsViewModel: MissingDocumentsViewModel
    /// The property page on show (`propertyId`), kept for the session like the others. Held,
    /// not observed: the page observes it, so its frequent changes (a side panel opening, a
    /// receipt selected) redraw the page alone rather than the whole window. The window's
    /// title follows its property's name (`propertyName`).
    @State private var propertyViewModel: PropertyViewModel
    /// The property page's name, for the window's title.
    @State private var propertyName: String?
    /// Kept for the app session: the year on show and its tab survive navigation.
    @StateObject private var taxYearsViewModel: TaxYearsViewModel

    /// Who the screens last read their data for: another person signing in reads them again.
    @State private var shownForUserId: Int64?
    private let profileStore: ImportProfileStore
    /// The snapshot harness only: the screen to open on and the state to set up on it.
    private let snapshotSetup: SnapshotSetup?

    init(environment: AppEnvironment, snapshotSetup: SnapshotSetup? = nil) {
        self.environment = environment
        self.snapshotSetup = snapshotSetup
        _shownForUserId = State(initialValue: environment.session.currentAppUserId)
        // The prefill is the signed-in person's own latest pay, read when the screen opens (nobody while locked).
        let salary = SalaryComparisonViewModel(store: SnapshotMode.isActive ? nil : SalaryDraftStore())
        salary.loadPrefill = { [dbQueue = environment.dbQueue, session = environment.session] in
            guard let personId = await session.currentUser?.personId else { return (nil, nil) }
            let inputs = try? await dbQueue.read { try SalaryPrefill.latest(db: $0, personId: personId, today: AppClock.now) }
            return (personId, inputs)
        }
        _salaryViewModel = State(initialValue: salary)
        if let screen = snapshotSetup?.screen {
            _selection = State(initialValue: screen)
            _sidebarSelection = State(initialValue: .screen(screen))
        }
        let profileStore = ImportProfileStore(dbQueue: environment.dbQueue)
        self.profileStore = profileStore
        _budgetGridViewModel = StateObject(wrappedValue: BudgetGridViewModel(dbQueue: environment.dbQueue))
        _scenarioLabViewModel = StateObject(wrappedValue: ScenarioLabViewModel(dbQueue: environment.dbQueue))
        _rulesViewModel = StateObject(wrappedValue: RulesViewModel(dbQueue: environment.dbQueue))
        _categoriesViewModel = StateObject(wrappedValue: CategoriesViewModel(dbQueue: environment.dbQueue))
        _uncategorizedViewModel = StateObject(wrappedValue: UncategorizedViewModel(dbQueue: environment.dbQueue))
        _accountsViewModel = StateObject(wrappedValue: AccountsViewModel(dbQueue: environment.dbQueue))
        _dashboardViewModel = StateObject(wrappedValue: DashboardViewModel(dbQueue: environment.dbQueue))
        _searchViewModel = StateObject(wrappedValue: SearchViewModel(dbQueue: environment.dbQueue))
        _documentsViewModel = StateObject(wrappedValue: DocumentsViewModel(dbQueue: environment.dbQueue, library: environment.evidenceLibrary))
        _documentKindsModel = StateObject(wrappedValue: DocumentKindsModel(dbQueue: environment.dbQueue))
        _missingEvidenceViewModel = StateObject(wrappedValue: MissingEvidenceViewModel(dbQueue: environment.dbQueue, library: environment.evidenceLibrary))
        _missingDocumentsViewModel = StateObject(wrappedValue: MissingDocumentsViewModel(dbQueue: environment.dbQueue))
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

    /// Whether the screen has a sidebar row right now (spec §6): Uncategorized only while
    /// something needs a category, Imports only while an import is active (imports start from
    /// elsewhere) or its screen is on show, so a result stays up until the user moves on.
    private func isInSidebar(_ screen: AppScreen) -> Bool {
        switch screen {
        case .imports: return importActive || selection == .imports
        case .uncategorized: return uncategorizedCount > 0
        // The per-record checklist stays reachable from Tax years and a property's Checks; Missing documents is the sidebar's.
        case .missingEvidence: return selection == .missingEvidence
        default: return true
        }
    }

    /// The visible `AppScreen.allCases` grouped by `sidebarSection`, one entry per distinct
    /// section value in the order that value first appears in `allCases` — not
    /// alphabetically, so "Workflow" → "Overview" → "Tax" → "Settings" (driven by `.imports`
    /// being first in `allCases`, `.dashboard` being the first `.sidebarSection ==
    /// "Overview"` case, etc.) stays stable regardless of where a section's later members
    /// (e.g. `.uncategorized`) happen to sit in `allCases`' own declaration order. A section
    /// with no visible screens (Workflow, when there's no import active and nothing to assign) is left
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
                                    .badge(screen == .missingDocuments ? missingDocumentsViewModel.result.missingCount : 0)
                                    .tag(SidebarItem.screen(screen))
                            }
                        }
                    }
                }
            }
            // The sidebar's selection keeps the system accent whatever the theme.
            .tint(nil)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    SidebarSyncRow(realSync: environment.realSync)
                    SidebarFooter(session: environment.session)
                }
            }
            // The whole column, title bar and Settings button included: without it the sidebar is
            // the content area's colour in dark mode (see `SidebarMaterial`).
            .background { SidebarMaterial().ignoresSafeArea() }
            // Replaced by the borderless toggle below.
            .toolbar(removing: .sidebarToggle)
            // The sidebar column is hosted apart from the window's root, so the lock overlay's own hiding
            // doesn't reach it: it hides itself while covered, and takes no clicks, focus or VoiceOver.
            .lockCoverHidden(lockCovered)
            // Wide enough for "UK Salary Calculator" and "Missing documents" with its badge.
            .navigationSplitViewColumnWidth(min: 200, ideal: 210)
        } detail: {
            Group {
                switch selection {
                case .dashboard:
                    DashboardView(
                        viewModel: dashboardViewModel, importCenter: environment.importCenter,
                        accounts: accounts, selectedImportAccountId: $selectedImportAccountId,
                        navigate: { selection = $0 }
                    )
                    .onAppear { dashboardViewModel.load() }
                case .search:
                    SearchView(viewModel: searchViewModel, showInBudget: showInBudget)
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
                case .salary:
                    SalarySimulatorView(model: salaryViewModel, forecast: scenarioLabViewModel,
                                        openForecast: { selection = .forecast })
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
                                 profileStore: profileStore,
                                 navigate: { selection = $0 })
                        .onAppear { accountsViewModel.load() }
                case .taxYears:
                    TaxYearsView(viewModel: taxYearsViewModel, missingEvidenceViewModel: missingEvidenceViewModel, openTransaction: openTransaction)
                        .environment(\.openMissingDocuments, { startYear in
                            missingDocumentsViewModel.area = nil
                            missingDocumentsViewModel.year = .taxYear(startYear)
                            selection = .missingDocuments
                        })
                case .documents:
                    DocumentsView(viewModel: documentsViewModel, openTransaction: openTransaction)
                case .missingDocuments:
                    MissingDocumentsView(viewModel: missingDocumentsViewModel, openProperty: { id in
                        refreshProperties(select: id)
                    })
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
            // "Mango" while covered: the screen's name would say what's under the lock.
            .navigationTitle(lockCovered ? "Mango" : selection == .property ? (propertyName ?? "Property") : (selection?.rawValue ?? "Mango"))
            .onReceive(propertyViewModel.$snapshot) { snapshot in
                if snapshot.property?.name != propertyName { propertyName = snapshot.property?.name }
            }
            // Files and folders dropped anywhere on a screen go to the document importer
            // (a screen's own drop target, e.g. Documents', takes its drops first).
            .modifier(ImportDropOutline(isTargeted: importDropTargeted))
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                // Nothing reaches the importer while Mango is locked or a step after signing in is open.
                guard !files.isEmpty, environment.session.canActOnData else { return false }
                environment.importCenter.start(files, intent: .none, entryPoint: "Drop")
                return true
            } isTargeted: { importDropTargeted = $0 }
            // The theme's window colour behind every screen (clear for Classic).
            .background(theme.windowBackground.ignoresSafeArea())
            .toolbar { // lock-cover: the window's own items, hidden in place (lockCoverHidden)
                // Hidden and inert while the lock screen covers the window, but still there: a toolbar that
                // empties or goes changes the window's frame, and the window must keep its size through a lock.
                ToolbarItem(placement: .navigation) {
                    SidebarToggleButton(columnVisibility: $columnVisibility)
                        .lockCoverHidden(lockCovered)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) {
                    Button { documentImport.pickFiles(.none, "Toolbar") } label: {
                        Label("Import…", systemImage: "square.and.arrow.down.on.square")
                    }
                    .buttonStyle(.borderless)
                    .help("Import documents (⇧⌘I)")
                    .accessibilityLabel("Import documents")
                    .lockCoverHidden(lockCovered)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .environment(\.documentImport, documentImport)
        .environment(\.documentKinds, documentKindsModel.catalog)
        // A kind created, renamed or merged: the waiting files are read again against the new names.
        .onChange(of: documentKindsModel.catalog.customKinds) { environment.importCenter.refreshWaiting() }
        .background(WindowReader { windowHolder.window = $0 })
        .onAppear {
            // An Edit transaction save (Budget grid, Categories panel) can add or clear an uncategorised one.
            budgetGridViewModel.onTransactionEdited = { refreshUncategorizedCount() }
            categoriesViewModel.onTransactionEdited = { refreshUncategorizedCount() }
            accountsViewModel.onTransactionAdded = { refreshUncategorizedCount() }
            searchViewModel.onTransactionEdited = { refreshUncategorizedCount() }
            rulesViewModel.onTransactionsCategorised = { refreshUncategorizedCount() }
            propertyViewModel.onPropertiesChanged = { id in refreshProperties(select: id) }
            environment.importCenter.onShow = { sidebarSelectionChanged(to: .screen(.imports)) }
            environment.importCenter.onBringForward = { [windowHolder] in
                NSApp.activate()
                windowHolder.window?.makeKeyAndOrderFront(nil)
            }
            environment.importCenter.onDataChanged = { documentImportChangedData() }
            environment.importCenter.onShowImportRule = { id in
                rulesViewModel.showImportRule(id)
                sidebarSelectionChanged(to: .screen(.rules))
            }
            refreshSharedState()
            missingDocumentsViewModel.claim("sidebar")
            snapshotSetup?.prepare(SnapshotScreenModels(
                dashboard: dashboardViewModel, budgetGrid: budgetGridViewModel, scenarioLab: scenarioLabViewModel, salary: salaryViewModel,
                accounts: accountsViewModel, categories: categoriesViewModel, search: searchViewModel,
                documents: documentsViewModel, missingEvidence: missingEvidenceViewModel, missingDocuments: missingDocumentsViewModel, property: propertyViewModel,
                taxYears: taxYearsViewModel, rules: rulesViewModel, uncategorized: uncategorizedViewModel))
        }
        .onChange(of: uncategorizedViewModel.transactions) {
            // Assigning on the Uncategorized screen removes rows; the last one hides the
            // screen and returns to the Dashboard.
            refreshUncategorizedCount()
        }
        .onChange(of: sidebarSelection) { _, newValue in sidebarSelectionChanged(to: newValue) }
        .onChange(of: scenarioLabViewModel.offerToEdit) { _, request in
            guard let request else { return }
            scenarioLabViewModel.offerToEdit = nil
            salaryViewModel.beginOfferEdit(request)
            selection = .salary
        }
        // Someone else signed in: the screens show what they can see (`SharedActualsSource`), so the one on show
        // reads again; the others read on appearing.
        .onReceive(environment.session.$state.compactMap(\.signedInId).removeDuplicates()) { id in
            // Unlocked as the same person: the Dashboard read while locked (its review cards empty) reads again.
            guard id != shownForUserId else {
                if selection == .dashboard { dashboardViewModel.load() }
                return
            }
            // Someone else signed in: the salary draft and the last person's pay go.
            if shownForUserId != nil { salaryViewModel.forget() }
            Task { await salaryViewModel.refreshPrefill() }
            shownForUserId = id
            reloadSharedFigures()
        }
        // Owners or a level changed in Settings ▸ Sharing (another window): the screen on show reads again.
        .onReceive(NotificationCenter.default.publisher(for: .sharingChanged)) { _ in reloadSharedFigures() }
        // Observes the phase alone, so the window isn't redrawn by every progress tick.
        .onReceive(environment.importCenter.$phase.map(Self.isActiveImport).removeDuplicates()) { importActive = $0 }
        // ⌘F (Edit ▸ Search Transactions) and File ▸ Import… (⇧⌘I) in this window, only while signed in.
        .modifier(SignedInCommands(session: environment.session, search: TransactionSearchAction {
            sidebarSelectionChanged(to: .screen(.search))
            searchViewModel.requestFocus()
        }, documentImport: documentImport))
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

    private static func isActiveImport(_ phase: ImportCenterModel.Phase) -> Bool {
        switch phase {
        case .reading, .review, .applying: return true
        case .idle, .finished, .failed: return false
        }
    }

    /// The window's document importer: File ▸ Import…, the toolbar button, screens' shortcuts.
    private var documentImport: DocumentImportAction {
        DocumentImportAction.forCenter(environment.importCenter)
    }

    /// The screen on show, read again as the person signed in sees it now (someone else signed in, or a level changed).
    private func reloadSharedFigures() {
        switch selection {
        case .dashboard: dashboardViewModel.load()
        case .accounts: accountsViewModel.load()
        case .budgetGrid: try? budgetGridViewModel.load(horizon: forecastHorizon)
        case .forecast: scenarioLabViewModel.load()
        case .categories: categoriesViewModel.load()
        default: break
        }
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

    /// The sidebar's selection (or a screen asked for in code, e.g. the importer showing the
    /// Imports screen): the screen on show, and the property row with it.
    private func sidebarSelectionChanged(to item: SidebarItem?) {
        guard item != currentSidebarItem else { return }
        let newValue: AppScreen?
        switch item {
        case let .screen(screen): newValue = screen
        case .property: newValue = .property
        case nil: newValue = nil
        }
        if case let .property(id) = item { propertyViewModel.propertyId = id }
        if selection == newValue {
            // Another property: the screen stays, the row follows.
            sidebarSelection = currentSidebarItem
        }
        selection = newValue
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

    private func refreshUncategorizedCount() {
        // A failed read keeps the last count rather than hiding the row.
        if let count = try? environment.dbQueue.read({ db in try UncategorizedTransactions.count(db: db) }) {
            uncategorizedCount = count
        }
        ensureSelectionInSidebar()
    }

    /// A selection whose row isn't in the sidebar (the last uncategorised transaction was
    /// assigned) falls back to the Dashboard.
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

/// The window's menu actions, published only while someone is signed in and nothing covers the window
/// (locked, or the new password after a recovery key, the Touch ID offer): a covered window's menus do nothing.
private struct SignedInCommands: ViewModifier {
    @ObservedObject var session: SessionModel
    let search: TransactionSearchAction
    let documentImport: DocumentImportAction

    func body(content: Content) -> some View {
        let usable = session.canActOnData
        content
            .focusedSceneValue(\.transactionSearch, usable ? search : nil)
            .focusedSceneValue(\.documentImport, usable ? documentImport : nil)
    }
}

/// The sidebar's foot: who is signed in (their initials), the lock button (auth spec §6) and Settings.
private struct SidebarFooter: View {
    @ObservedObject var session: SessionModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 8) {
            // Initials only: the sidebar is narrow, and the name is in the help.
            if let user = session.currentUser {
                UserAvatar(name: user.displayName, size: 24)
                    .help("Signed in as \(user.displayName)")
                    .accessibilityElement()
                    .accessibilityLabel("Signed in as \(user.displayName)")
            }
            Spacer(minLength: 4)
            Button { session.lock() } label: {
                Image(systemName: "lock")
                    .imageScale(.large)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Lock Mango (⌃⌘L)")
            .accessibilityLabel("Lock")
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .imageScale(.large)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }
}

/// The window's Hide/Show sidebar button: the system toggle's job (⌃⌘S included) without
/// its glass capsule.
private struct SidebarToggleButton: View {
    @Binding var columnVisibility: NavigationSplitViewVisibility
    /// Read here too: toolbar content may not inherit the root's `disabled`, and ⌃⌘S must not bring the
    /// sidebar column back while the lock screen covers the window.
    @Environment(\.isLockCovered) private var lockCovered

    private var sidebarShown: Bool { columnVisibility != .detailOnly }

    var body: some View {
        Button {
            guard !lockCovered else { return }
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
