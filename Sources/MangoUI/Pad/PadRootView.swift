import SwiftUI
import BudgetCore

/// The iPad's unlocked app (step 8, Task 6; step 10, Task 3): the sidebar (`PadSidebar`: Home, Month, Accounts, Search;
/// Property; Everything else; collapsible to an icon rail; footer with the person, sync and Settings) and the selected
/// screen as its detail. Home, Month, Accounts and Search reuse the iPhone's views over the same
/// `PhoneTabsModel`; the others, This month (`PadThisMonthView`) included, are the iPad's own screens. The lock cover, banners and Settings sheet are the app's, as
/// on iPhone.
///
/// Bills & recharges is one screen (`PadBillsAndRechargesView`, step 10 Task 11) and Tenancies another
/// (`PadTenanciesScreen`, Task 13, rent receipts included), each with the document panel. Evidence is the step 8 Missing evidence screen; Money,
/// Calendar, Checks and Profile are placeholders. Property's edits go through the tabs' `padWrite`, Documents' and Evidence's through
/// `padDocumentWrite`.
///
/// The built-in browser (step 10, Task 5; `browser`, nil with demo data) is presented over everything when a screen
/// asks for it (`\.padBrowser`) or a PDF is shared into Mango.
public struct PadRootView: View {
    @ObservedObject var tabs: PhoneTabsModel
    @ObservedObject private var documents: PadDocumentsModel
    @ObservedObject private var evidence: PadMissingEvidenceModel
    let syncStatus: SyncStatus
    let lastSync: Date?
    let isDemo: Bool
    let waitingChanges: Int
    let browser: BrowserModel?
    let onRefresh: () async -> Void
    let onSettings: () -> Void
    @State private var selection: PadSection
    @State private var userName = "You"
    @SceneStorage("padSidebarCollapsed") private var sidebarCollapsed = false

    /// `columns` is kept for the snapshot routes' sake and no longer used: the sidebar is the app's own.
    /// `waitingChanges`: this iPad's changes the server hasn't taken yet, in the zones it pushes to
    /// (`SyncWaitingChanges`). `browser`: the built-in browser; ignored with demo data, where it is hidden.
    public init(tabs: PhoneTabsModel, syncStatus: SyncStatus, lastSync: Date? = nil, isDemo: Bool = false,
                initialSelection: PadSection = .home, sidebarCollapsed: Bool = false,
                waitingChanges: Int = 0, browser: BrowserModel? = nil, columns: NavigationSplitViewVisibility = .automatic,
                onRefresh: @escaping () async -> Void = {}, onSettings: @escaping () -> Void = {}) {
        self.tabs = tabs
        documents = tabs.padDocuments
        evidence = tabs.padMissingEvidence
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
        _sidebarCollapsed = SceneStorage(wrappedValue: sidebarCollapsed, "padSidebarCollapsed")
    }

    public var body: some View {
        GeometryReader { proxy in
            let state = PadSidebarState(isCollapsed: sidebarCollapsed).effective(
                width: proxy.size.width, height: proxy.size.height,
                panelOpen: (selection == .documents && documents.selectedId != nil) || (selection == .billsAndRecharges && tabs.padBills.selectedBillId != nil) || (selection == .tenancies && tabs.padTenancies.selectedReceiptId != nil) || (selection == .evidence && evidence.selectedItemId != nil))
            HStack(spacing: 0) {
                PadSidebar(state: state, selection: $selection, hasProperty: tabs.hasProperty, userName: userName, avatar: nil,
                           sync: SyncSidebarStatus.make(isRunning: syncStatus != .off, status: syncStatus, progress: nil, refusal: nil),
                           waitingChanges: waitingChanges, onToggle: { sidebarCollapsed.toggle() }, onSettings: onSettings)
                Divider()
                detail(selection)
                    .environment(\.showsDemoData, isDemo)
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
        .onChange(of: tabs.hasProperty) { _, has in
            if !has, selection.requiresProperty { selection = .home }
        }
        .modifier(BrowserPresentation(browser: browser))
    }

    @ViewBuilder
    private func detail(_ section: PadSection) -> some View {
        switch section {
        case .home:
            HomeView(model: tabs.home, syncStatus: syncStatus, onRefresh: onRefresh, onSettings: onSettings)
                .offlineBanner(syncStatus, lastSync: lastSync)
        case .month:
            MonthView(model: tabs.month, syncStatus: syncStatus, onRefresh: onRefresh)
                .offlineBanner(syncStatus, lastSync: lastSync)
        case .accounts:
            AccountsView(model: tabs.accounts, syncStatus: syncStatus, onRefresh: onRefresh)
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
        case .evidence:
            PadMissingEvidenceView(model: tabs.padMissingEvidence, write: tabs.padDocumentWrite, syncStatus: syncStatus)
                .offlineBanner(syncStatus, lastSync: lastSync)
        case .money, .calendar, .checks, .profile:
            PlaceholderPadScreen(section: section)
        }
    }

    /// Tenancies' Show in Documents: the Documents screen with that document selected.
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
