import SwiftUI
import BudgetCore

/// The iPad's unlocked app (step 8, Task 6; step 10, Task 3): the sidebar (`PadSidebar`: Home, Month, Accounts, Search;
/// Property; Everything else; collapsible to an icon rail; footer with the person, sync and Settings) and the selected
/// screen as its detail. Home, Month, Accounts and Search reuse the iPhone's views over the same
/// `PhoneTabsModel`; the others, This month (`PadThisMonthView`) included, are the iPad's own screens. The lock cover, banners and Settings sheet are the app's, as
/// on iPhone.
///
/// Sections whose screens later tasks build: Bills & recharges shows the step 8 Bills / Recharges / Rent receipts
/// screens behind a picker (`PadLegacyTab`), Evidence the step 8 Missing evidence screen; Money, Calendar, Checks and
/// Profile are placeholders. Property's edits go through the tabs' `padWrite`, Documents' and Evidence's through
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
    @State private var legacyTab: PadLegacyTab
    @State private var userName = "You"
    @SceneStorage("padSidebarCollapsed") private var sidebarCollapsed = false

    /// `columns` is kept for the snapshot routes' sake and no longer used: the sidebar is the app's own.
    /// `waitingChanges`: this iPad's changes the server hasn't taken yet, in the zones it pushes to
    /// (`SyncWaitingChanges`). `browser`: the built-in browser; ignored with demo data, where it is hidden.
    public init(tabs: PhoneTabsModel, syncStatus: SyncStatus, lastSync: Date? = nil, isDemo: Bool = false,
                initialSelection: PadSection = .home, legacyTab: PadLegacyTab = .bills, sidebarCollapsed: Bool = false,
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
        _legacyTab = State(initialValue: legacyTab)
        _sidebarCollapsed = SceneStorage(wrappedValue: sidebarCollapsed, "padSidebarCollapsed")
    }

    public var body: some View {
        GeometryReader { proxy in
            let state = PadSidebarState(isCollapsed: sidebarCollapsed).effective(
                width: proxy.size.width, height: proxy.size.height,
                panelOpen: (selection == .documents && documents.selectedId != nil) || (selection == .evidence && evidence.selectedItemId != nil))
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
            PadTenanciesView(model: tabs.padProperty, syncStatus: syncStatus)
                .offlineBanner(syncStatus, lastSync: lastSync)
        case .billsAndRecharges:
            legacyBills
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

    /// Where This month's actions go.
    private func open(_ destination: PadDestination) {
        switch destination {
        case .billsAndRecharges:
            legacyTab = .bills
            selection = .billsAndRecharges
        case .recharges:
            legacyTab = .recharges
            selection = .billsAndRecharges
        case .evidence:
            selection = .evidence
        case .site, .check:
            break
        }
    }

    /// Bills & recharges until Task 11: the step 8 screens behind a picker.
    private var legacyBills: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $legacyTab) {
                ForEach(PadLegacyTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 16).padding(.vertical, 8)
            Group {
                switch legacyTab {
                case .bills:
                    PadBillsView(model: tabs.padProperty, actions: tabs.padBillActions, write: tabs.padWrite, syncStatus: syncStatus)
                case .recharges:
                    PadRechargesView(model: tabs.padRecharges, property: tabs.padProperty, write: tabs.padWrite, syncStatus: syncStatus)
                case .rentReceipts:
                    PadRentReceiptsView(model: tabs.padRentReceipts, property: tabs.padProperty, write: tabs.padWrite, syncStatus: syncStatus)
                }
            }
            .offlineBanner(syncStatus, lastSync: lastSync)
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
