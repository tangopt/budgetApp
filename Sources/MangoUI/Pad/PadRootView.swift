import SwiftUI
import BudgetCore

/// The iPad's unlocked app (step 8, Task 6): a sidebar (Home · Month · Accounts · Search; Property; Documents) and
/// the selected screen as its detail. Home, Month, Accounts, Search and Property's Overview reuse the iPhone's
/// views over the same `PhoneTabsModel`; the others are the iPad's own screens (Tasks 7-10). The lock cover, banners
/// and Settings sheet are the app's, as on iPhone.
///
/// Property's edits (Bills, Recharges, Rent receipts) go through the tabs' `padWrite` (the device writer, Task 8);
/// Documents' and Missing evidence's through `padDocumentWrite` (Task 10).
public struct PadRootView: View {
    @ObservedObject var tabs: PhoneTabsModel
    let syncStatus: SyncStatus
    let lastSync: Date?
    let isDemo: Bool
    let onRefresh: () async -> Void
    let onSettings: () -> Void
    @State private var selection: PadSection?
    @State private var visibility: NavigationSplitViewVisibility = .automatic

    public init(tabs: PhoneTabsModel, syncStatus: SyncStatus, lastSync: Date? = nil, isDemo: Bool = false,
                initialSelection: PadSection = .home,
                columns: NavigationSplitViewVisibility = .automatic, onRefresh: @escaping () async -> Void = {},
                onSettings: @escaping () -> Void = {}) {
        self.tabs = tabs
        self.syncStatus = syncStatus
        self.lastSync = lastSync
        self.isDemo = isDemo
        self.onRefresh = onRefresh
        self.onSettings = onSettings
        _selection = State(initialValue: initialSelection)
        _visibility = State(initialValue: columns)
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            List(selection: $selection) {
                ForEach(PadSection.groups(hasProperty: tabs.hasProperty), id: \.title) { group in
                    if let title = group.title {
                        Section(title) { rows(group) }
                    } else {
                        rows(group)
                    }
                }
            }
            .navigationTitle("Mango")
        } detail: {
            detail(selection ?? .home)
                .environment(\.showsDemoData, isDemo)
                .environment(\.documentPanelSource, tabs.padDocuments.panelSource)
        }
        .task(id: SyncReloadTrigger(syncStatus)) {
            await tabs.reload(for: PhoneTabsModel.reloadKey(syncStatus))
        }
        .onChange(of: tabs.pendingLink, initial: true) { _, link in
            // A widget's link (also one that arrived before this view did).
            guard let link else { return }
            selection = PadSection(link: link)
            tabs.consumePendingLink()
        }
        .onChange(of: tabs.hasProperty) { _, has in
            if !has, let current = selection, PadSection.propertySections.contains(current) { selection = .home }
        }
    }

    private func rows(_ group: PadSection.Group) -> some View {
        ForEach(group.sections, id: \.self) { section in
            Label(section.title, systemImage: section.systemImage).tag(section)
        }
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
        case .propertyOverview:
            PadOverviewView(model: tabs.property, syncStatus: syncStatus, onRefresh: onRefresh)
                .offlineBanner(syncStatus, lastSync: lastSync)
        case .tenancies:
            PadTenanciesView(model: tabs.padProperty, syncStatus: syncStatus)
                .offlineBanner(syncStatus, lastSync: lastSync)
        case .bills:
            PadBillsView(model: tabs.padProperty, actions: tabs.padBillActions, write: tabs.padWrite, syncStatus: syncStatus)
                .offlineBanner(syncStatus, lastSync: lastSync)
        case .recharges:
            PadRechargesView(model: tabs.padRecharges, property: tabs.padProperty, write: tabs.padWrite, syncStatus: syncStatus)
                .offlineBanner(syncStatus, lastSync: lastSync)
        case .rentReceipts:
            PadRentReceiptsView(model: tabs.padRentReceipts, property: tabs.padProperty, write: tabs.padWrite, syncStatus: syncStatus)
                .offlineBanner(syncStatus, lastSync: lastSync)
        case .documents:
            PadDocumentsView(model: tabs.padDocuments, actions: tabs.padDocumentActions, write: tabs.padDocumentWrite, syncStatus: syncStatus)
                .offlineBanner(syncStatus, lastSync: lastSync)
        case .missingEvidence:
            PadMissingEvidenceView(model: tabs.padMissingEvidence, write: tabs.padDocumentWrite, syncStatus: syncStatus)
                .offlineBanner(syncStatus, lastSync: lastSync)
        }
    }
}

extension PadSection {
    static let propertySections: Set<PadSection> = [.propertyOverview, .bills, .recharges, .rentReceipts, .tenancies]
}
