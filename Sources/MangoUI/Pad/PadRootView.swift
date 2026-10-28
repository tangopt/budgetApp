import SwiftUI
import BudgetCore

/// The iPad's unlocked app (step 8, Task 6; step 10, Task 3): the sidebar (`PadSidebar`: Home, Month, Accounts, Search;
/// Property; Everything else; collapsible to an icon rail; footer with the person, sync and Settings) and the selected
/// screen as its detail. Home, Month and Search reuse the iPhone's views over the same
/// `PhoneTabsModel`; the others, This month (`PadThisMonthView`) included, are the iPad's own screens. The lock cover, banners and Settings sheet are the app's, as
/// on iPhone.
///
/// Bills & recharges is one screen (`PadBillsAndRechargesView`, step 10 Task 11) and Tenancies another
/// (`PadTenanciesScreen`, Task 13, rent receipts included), each with the document panel. Evidence is the tax year's (`PadEvidenceView`, Task 14); Money and Calendar are Task 15's
/// (`PadMoneyView`, `PadCalendarView`); Checks and Profile Task 16's (`PadChecksView`, `PadProfileView`, mortgage terms included). Property's edits go through the tabs' `padWrite`, Documents' and Evidence's links through
/// `padDocumentWrite` (Evidence's "Mark not available" through `padWrite`).
///
/// The built-in browser (step 10, Task 5; `browser`, nil with demo data) is presented over everything when a screen
/// asks for it (`\.padBrowser`) or a PDF is shared into Mango.
public struct PadRootView: View {
    @ObservedObject var tabs: PhoneTabsModel
    @ObservedObject private var documents: PadDocumentsModel
    @ObservedObject private var evidence: PadEvidenceModel
    let syncStatus: SyncStatus
    let lastSync: Date?
    let isDemo: Bool
    let waitingChanges: Int
    let browser: BrowserModel?
    let onRefresh: () async -> Void
    let onSettings: () -> Void
    @State private var selection: PadSection
    @State private var userName = "You"
    @State private var ownSalary = SalaryComparisonViewModel()
    /// A salary simulator to show instead of the iPad's own (the snapshot routes').
    private let salary: SalaryComparisonViewModel?
    @SceneStorage("padSidebarCollapsed") private var sidebarCollapsed = false

    /// `columns` is kept for the snapshot routes' sake and no longer used: the sidebar is the app's own.
    /// `waitingChanges`: this iPad's changes the server hasn't taken yet, in the zones it pushes to
    /// (`SyncWaitingChanges`). `browser`: the built-in browser; ignored with demo data, where it is hidden.
    public init(tabs: PhoneTabsModel, syncStatus: SyncStatus, lastSync: Date? = nil, isDemo: Bool = false,
                initialSelection: PadSection = .home, sidebarCollapsed: Bool = false,
                waitingChanges: Int = 0, browser: BrowserModel? = nil, salary: SalaryComparisonViewModel? = nil, columns: NavigationSplitViewVisibility = .automatic,
                onRefresh: @escaping () async -> Void = {}, onSettings: @escaping () -> Void = {}) {
        self.tabs = tabs
        documents = tabs.padDocuments
        evidence = tabs.padEvidence
        self.syncStatus = syncStatus
        self.lastSync = lastSync
        self.isDemo = isDemo
        self.waitingChanges = waitingChanges
        self.browser = isDemo ? nil : browser
        let shown = self.browser
        tabs.padThisMonth.trayItems = { shown?.tray.items() ?? [] }
        self.onRefresh = onRefresh
        self.onSettings = onSettings
        _selection = State(initialValue: initialSelection)
        self.salary = salary
        _sidebarCollapsed = SceneStorage(wrappedValue: sidebarCollapsed, "padSidebarCollapsed")
    }

    public var body: some View {
        GeometryReader { proxy in
            let state = PadSidebarState(isCollapsed: sidebarCollapsed).effective(
                width: proxy.size.width, height: proxy.size.height,
                panelOpen: (selection == .documents && documents.selectedId != nil) || (selection == .billsAndRecharges && tabs.padBills.selectedBillId != nil) || (selection == .tenancies && tabs.padTenancies.selectedReceiptId != nil) || (selection == .evidence && evidence.selectedItemId != nil) || (selection == .money && tabs.padMoney.panel != nil))
            HStack(spacing: 0) {
                PadSidebar(state: state, selection: $selection, hasProperty: tabs.showsPropertySections, userName: userName, avatar: nil,
                           sync: SyncSidebarStatus.make(isRunning: syncStatus != .off, status: syncStatus, progress: nil, refusal: nil),
                           waitingChanges: waitingChanges, onToggle: { sidebarCollapsed.toggle() }, onSettings: onSettings)
                Divider()
                detail(selection)
                    .environment(\.showsDemoData, isDemo)
                    .environment(\.usesPadPage, true)
                    .environment(\.documentPanelSource, tabs.padDocuments.panelSource)
                    .environment(\.padBrowser, browser)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(.snappy(duration: 0.2), value: state)
        }
        .task(id: SyncReloadTrigger(syncStatus)) {
            await tabs.reload(for: PhoneTabsModel.reloadKey(syncStatus))
        }
        .task(id: tabs.viewer) {
            if let name = await tabs.viewerName() { userName = name }
        }
        .onChange(of: tabs.pendingLink, initial: true) { _, link in
            // A widget's link (also one that arrived before this view did).
            guard let link else { return }
            selection = PadSection(link: link)
            tabs.consumePendingLink()
        }
        .onChange(of: tabs.showsPropertySections) { _, shows in
            if !shows, selection.requiresProperty { selection = .home }
        }
        .modifier(BrowserPresentation(browser: browser))
    }

    @ViewBuilder
    private func detail(_ section: PadSection) -> some View {
        if section.requiresProperty, !tabs.showsPropertySections {
            // No property, or no View on Property: nothing of it shows.
            Color.clear
        } else {
            sectionDetail(section)
        }
    }

    @ViewBuilder
    private func sectionDetail(_ section: PadSection) -> some View {
        switch section {
        case .home:
            HomeView(model: tabs.home, syncStatus: syncStatus, onRefresh: onRefresh, onSettings: onSettings)
                .offlineBanner(syncStatus, lastSync: lastSync)
        case .month:
            MonthView(model: tabs.month, syncStatus: syncStatus, onRefresh: onRefresh)
                .offlineBanner(syncStatus, lastSync: lastSync)
        case .accounts:
            PadAccountsView(model: tabs.padAccounts, write: tabs.padAccountWrite, syncStatus: syncStatus, onRefresh: onRefresh,
                            onAdd: { tabs.padAccounts.openAddForm() },
                            onEdit: { id in Task { await tabs.padAccounts.openEditForm(accountId: id) } })
                .environment(\.quickEdit, tabs.quickEdit)
                .offlineBanner(syncStatus, lastSync: lastSync)
        case .search:
            SearchView(model: tabs.search, syncStatus: syncStatus, onRefresh: onRefresh)
                .offlineBanner(syncStatus, lastSync: lastSync)
        case .thisMonth:
            PadThisMonthView(model: tabs.padThisMonth, property: tabs.padProperty, write: tabs.padWrite, syncStatus: syncStatus,
                             go: open)
                .offlineBanner(syncStatus, lastSync: lastSync)
        case .tenancies:
            PadTenanciesScreen(model: tabs.padTenancies, property: tabs.padProperty, write: tabs.padWrite, syncStatus: syncStatus,
                               showDocument: showDocument)
                .environment(\.quickEdit, tabs.quickEdit)
                .offlineBanner(syncStatus, lastSync: lastSync)
        case .billsAndRecharges:
            PadBillsAndRechargesView(model: tabs.padBills, property: tabs.padProperty, write: tabs.padWrite, syncStatus: syncStatus)
                .offlineBanner(syncStatus, lastSync: lastSync)
        case .documents:
            PadDocumentsView(model: tabs.padDocuments, actions: tabs.padDocumentActions, write: tabs.padDocumentWrite, syncStatus: syncStatus)
                .offlineBanner(syncStatus, lastSync: lastSync)
        case .salary:
            NavigationStack { SalarySimulatorScreen(viewModel: salary ?? ownSalary) }
        case .evidence:
            PadEvidenceView(model: tabs.padEvidence, write: tabs.padDocumentWrite, syncStatus: syncStatus,
                            showBills: { selection = .billsAndRecharges })
                .offlineBanner(syncStatus, lastSync: lastSync)
        case .money:
            PadMoneyView(model: tabs.padMoney, write: tabs.padDocumentWrite, syncStatus: syncStatus, showDocument: showDocument)
                .environment(\.quickEdit, tabs.quickEdit)
                .offlineBanner(syncStatus, lastSync: lastSync)
        case .calendar:
            PadCalendarView(model: tabs.padCalendar, syncStatus: syncStatus)
                .offlineBanner(syncStatus, lastSync: lastSync)
        case .checks:
            PadChecksView(model: tabs.padChecks, write: tabs.padWrite, syncStatus: syncStatus, showEvidence: { selection = .evidence })
                .environment(\.quickEdit, tabs.quickEdit)
                .offlineBanner(syncStatus, lastSync: lastSync)
        case .profile:
            PadProfileView(model: tabs.padProfile, write: tabs.padWrite, syncStatus: syncStatus, showDocument: showDocument)
                .offlineBanner(syncStatus, lastSync: lastSync)
        }
    }

    /// Tenancies' and Profile's Show in Documents: the Documents screen with that document selected.
    private func showDocument(_ id: Int64) {
        tabs.padDocuments.selectedId = id
        selection = .documents
    }

    /// Where This month's actions go.
    private func open(_ destination: PadDestination) {
        switch destination {
        case .billsAndRecharges, .recharges:
            selection = .billsAndRecharges
        case .prepareEmail(let statementId):
            selection = .billsAndRecharges
            tabs.padBills.emailStatementId = statementId
        case .evidence:
            selection = .evidence
        case .site, .check:
            break
        }
    }
}

/// The built-in browser over the whole iPad window, while `browser.isPresented`.
private struct BrowserPresentation: ViewModifier {
    let browser: BrowserModel?

    func body(content: Content) -> some View {
        if let browser {
            @Bindable var browser = browser
            content
                #if canImport(UIKit)
                .fullScreenCover(isPresented: $browser.isPresented) {
                    BrowserView(model: browser, onDone: { browser.isPresented = false })
                }
                #else
                .sheet(isPresented: $browser.isPresented) {
                    BrowserView(model: browser, onDone: { browser.isPresented = false })
                }
                #endif
        } else {
            content
        }
    }
}
