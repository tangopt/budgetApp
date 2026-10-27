import SwiftUI
import BudgetCore

/// The iPad's unlocked app (step 8, Task 6): a sidebar (Home · Month · Accounts · Search; Property; Documents) and
/// the selected screen as its detail. Home, Month, Accounts, Search and Property's Overview reuse the iPhone's
/// views over the same `PhoneTabsModel`; the other destinations are placeholders until their iPad screens land
/// (`PadPlaceholder`, replaced by Tasks 7-10). The lock cover, banners and Settings sheet are the app's, as on iPhone.
///
/// The plan's `writer: DeviceWriter` parameter arrives with the engine tasks; the first screen that writes adds it.
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
        }
        .task(id: SyncReloadTrigger(syncStatus)) {
            await tabs.reload(for: PhoneTabsModel.reloadKey(syncStatus))
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
            PadBillsView(model: tabs.padProperty, syncStatus: syncStatus)
                .offlineBanner(syncStatus, lastSync: lastSync)
        case .documents:
            PadDocumentsView(model: tabs.padDocuments, syncStatus: syncStatus)
                .offlineBanner(syncStatus, lastSync: lastSync)
        case .recharges, .rentReceipts, .missingEvidence:
            PadPlaceholder(section: section)
        }
    }
}

extension PadSection {
    static let propertySections: Set<PadSection> = [.propertyOverview, .bills, .recharges, .rentReceipts, .tenancies]
}

/// A destination whose iPad screen isn't built yet (Tasks 7-10 replace each).
struct PadPlaceholder: View {
    let section: PadSection

    var body: some View {
        NavigationStack {
            ContentUnavailableView(section.title, systemImage: section.systemImage,
                                   description: Text("This screen is coming to the iPad."))
                .navigationTitle(section.title)
        }
    }
}
