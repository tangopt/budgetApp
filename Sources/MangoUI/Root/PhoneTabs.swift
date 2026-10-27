import Combine
import SwiftUI
import BudgetCore
import GRDB
import struct BudgetCore.Property

/// The phone's tabs (iPhone spec §2).
public enum PhoneTab: Hashable, Sendable {
    case home, month, accounts, property, search
}

/// Every tab's view model and the selected tab, made once when the database opens and kept above the lock cover, so
/// a relock keeps each tab's month, pushed screens, query and open sheet.
@MainActor
public final class PhoneTabsModel: ObservableObject {
    @Published public var selection: PhoneTab = .home
    /// A widget's link not yet shown by the iPad's sidebar (`PadRootView` takes it and clears it).
    @Published public private(set) var pendingLink: PhoneTabLink?
    /// Property is absent while the database has no property row (spec §3.9, permission None's analogue; ruling for
    /// step 4).
    @Published public private(set) var hasProperty: Bool

    public let home: HomeViewModel
    public let month: MonthViewModel
    public let accounts: AccountsViewModel
    public let property: PropertyViewModel
    public let search: SearchViewModel
    /// The iPad's Property screens (tenancies, bills); unused on the iPhone.
    public let padProperty: PadPropertyModel
    /// The iPad's Documents library; its `open` is set once sync can download a document on demand.
    public let padDocuments: PadDocumentsModel
    /// The iPad's Property edits (step 8, Task 8), through the device writer (nil: demo data, nothing offered).
    public let padWrite: PadWriteModel
    /// Bills & recharges (step 10, Task 11): the grid, the statements and their actions.
    public let padBills: PadBillsAndRechargesModel
    /// Tenancies (step 10, Task 13): the tenancy's details, its rent receipts and their actions.
    public let padTenancies: PadTenanciesModel
    /// Money (step 10, Task 15): the period's figures and transactions; a document linked or unlinked goes through `padDocumentWrite`.
    public let padMoney: PadMoneyModel
    /// Calendar (step 10, Task 15): the obligations as an agenda and a month grid; reads only.
    public let padCalendar: PadCalendarModel
    /// The iPad's Documents and Evidence edits (step 8, Task 10), through the device writer in Documents.
    public let padDocumentWrite: PadWriteModel
    public let padDocumentActions: PadDocumentActions
    /// Evidence for the tax year (step 10, Task 14): links through `padDocumentWrite`, "Mark not available" through `padWrite`.
    public let padEvidence: PadEvidenceModel
    /// The iPad's This-month checklist (step 10, Task 10); its edit (Confirm match) goes through `padWrite`.
    public let padThisMonth: PadThisMonthModel
    /// The iPhone's quick edits (step 7b): categorise, note, Quick sort, Update balance; nothing offered with no writer.
    public let quickEdit: QuickEditModel

    private let dbQueue: any DatabaseReader
    private var loadedKey: Date?
    /// The iCloud user's record names followed (`follow(recordNames:)`), and the reload the latest one asked for.
    private var following: AnyCancellable?
    private var viewerReload: Task<Void, Never>?

    /// Whose figures the tabs show (step 6): demo data's admin, or this iPhone's iCloud user.
    public private(set) var viewer: PhoneViewer

    /// `hasProperty`: what `hasProperty(_:)` read when the database opened. `home`: an already loaded Home (the
    /// snapshot harness's `tabs` route).
    public init(dbQueue: any DatabaseReader, today: @escaping () -> Date, hasProperty: Bool, viewer: PhoneViewer = .everyone,
                home: HomeViewModel? = nil, writer: DeviceWriter? = nil) {
        self.dbQueue = dbQueue
        self.hasProperty = hasProperty
        self.viewer = viewer
        self.home = home ?? HomeViewModel(dbQueue: dbQueue, today: today, viewer: viewer)
        month = MonthViewModel(dbQueue: dbQueue, today: today, viewer: viewer)
        accounts = AccountsViewModel(dbQueue: dbQueue, today: today, viewer: viewer)
        property = PropertyViewModel(dbQueue: dbQueue, today: today)
        search = SearchViewModel(dbQueue: dbQueue, today: today)
        padProperty = PadPropertyModel(dbQueue: dbQueue, today: today)
        padDocuments = PadDocumentsModel(dbQueue: dbQueue)
        padWrite = PadWriteModel(writer: writer)
        padBills = PadBillsAndRechargesModel(property: padProperty, write: padWrite, dbQueue: dbQueue, today: today)
        padTenancies = PadTenanciesModel(property: padProperty, write: padWrite, dbQueue: dbQueue, today: today)
        padDocumentWrite = PadWriteModel(writer: writer, area: .documents)
        padDocumentActions = PadDocumentActions(documents: padDocuments, write: padDocumentWrite, dbQueue: dbQueue)
        padMoney = PadMoneyModel(property: padProperty, write: padDocumentWrite, dbQueue: dbQueue, today: today)
        padCalendar = PadCalendarModel(property: padProperty, dbQueue: dbQueue, today: today)
        padEvidence = PadEvidenceModel(write: padDocumentWrite, propertyWrite: padWrite, dbQueue: dbQueue, today: today)
        padThisMonth = PadThisMonthModel(property: padProperty, write: padWrite, dbQueue: dbQueue, today: today)
        quickEdit = QuickEditModel(writer: writer, dbQueue: dbQueue, today: today)
        quickEdit.viewer = viewer
        // After an edit saves, what it moved is read again: the figures, the lists, the queue.
        quickEdit.onChange = { [weak self] in await self?.reloadAfterEdit() }
    }

    /// Whether the database has a property row, read off the main actor; nil when the read fails (the tab then stays
    /// as it was).
    public nonisolated static func hasProperty(_ reader: any DatabaseReader) async -> Bool? {
        try? await reader.read { db in try Property.fetchCount(db) > 0 }
    }

    /// After a sync: reads again whether there's a property; leaving Property for Home if it went.
    public func reload(for key: Date?) async {
        guard key != loadedKey else { return }
        loadedKey = key
        guard let has = await Self.hasProperty(dbQueue) else { return }
        hasProperty = has
        if !has, selection == .property { selection = .home }
    }

    public nonisolated static func reloadKey(_ status: SyncStatus) -> Date? {
        HomeViewModel.reloadKey(status)
    }

    /// The signed-in person's name, for the iPad sidebar's footer; nil when the viewer is nobody in particular.
    public func viewerName() async -> String? {
        let viewer = viewer
        return try? await dbQueue.read { db in
            guard let id = try viewer.resolve(db: db).personId else { return nil }
            return try Person.fetchOne(db, key: id)?.name
        }
    }

    /// Follows this iPhone's iCloud user as sync reads it (`PhoneSyncController.$viewerRecordName`, on the main actor):
    /// the name already read first, then each change. This model lives above the lock cover, which keeps the content
    /// out of the view tree while locked, and the app launches locked: a view's `onChange` there never saw a name read
    /// before unlocking change, so the tabs kept the unnamed viewer. Held here, nothing read while locked is missed.
    public func follow<Names: Publisher>(recordNames: Names) where Names.Output == String?, Names.Failure == Never {
        following = recordNames.sink { [weak self] name in
            MainActor.assumeIsolated { self?.followed(name) }
        }
    }

    /// This iPhone's iCloud user became known (or changed): the screens that read through the viewer read again.
    private func followed(_ recordName: String?) {
        guard assignViewer(.iCloudUser(recordName: recordName)) else { return }
        viewerReload?.cancel()
        viewerReload = Task { [weak self] in await self?.reloadViewerScreens() }
    }

    /// Sets the viewer on every screen that reads through it; false when it is already the one.
    private func assignViewer(_ viewer: PhoneViewer) -> Bool {
        guard viewer != self.viewer else { return false }
        self.viewer = viewer
        home.viewer = viewer
        month.viewer = viewer
        accounts.viewer = viewer
        quickEdit.viewer = viewer
        return true
    }

    /// After a quick edit saved, once the screens have read again: the app's outputs (widget snapshot, reminders).
    public var afterEdit: (@MainActor () -> Void)?

    /// After a quick edit: the screens that show transactions read again, the open lists in place, then `afterEdit`.
    private func reloadAfterEdit() async {
        await reloadViewerScreens()
        await search.load()
        await month.refreshTransactionLists()
        await quickEdit.load()
        afterEdit?()
    }

    private func reloadViewerScreens() async {
        await home.load()
        await month.load()
        await accounts.load()
    }

    /// A widget's link: the iPhone's tab, and the iPad's sidebar section through `pendingLink`.
    public func open(_ link: PhoneTabLink) {
        selection = link == .home ? .home : .month
        pendingLink = link
    }

    /// The iPad's sidebar has shown `pendingLink`.
    public func consumePendingLink() {
        pendingLink = nil
    }

    /// On a lock: closes the tabs' sheets in their state too (the cover window dismisses them in UIKit, which a
    /// binding doesn't always see), so nothing re-presents after unlocking and a row opens again.
    public func dismissSheets() {
        search.detail = nil
        quickEdit.dismissSheets()
    }
}

/// The unlocked app: Home · Month · Accounts · Property, and Search as the iOS 26 search tab. Shown inside the lock
/// cover; `model` lives above it. Every tab reloads itself when `syncStatus`'s last sync moves, and shows the
/// offline banner at its top while offline (with the data's age, from `lastSync`).
public struct PhoneTabs: View {
    @ObservedObject var model: PhoneTabsModel
    let syncStatus: SyncStatus
    let lastSync: Date?
    let onRefresh: () async -> Void
    let onSettings: () -> Void
    /// Demo data ("Try with demo data"): `DemoBanner` over every screen.
    let isDemo: Bool

    public init(model: PhoneTabsModel, syncStatus: SyncStatus, lastSync: Date? = nil, isDemo: Bool = false,
                onRefresh: @escaping () async -> Void, onSettings: @escaping () -> Void) {
        self.model = model
        self.isDemo = isDemo
        self.syncStatus = syncStatus
        self.lastSync = lastSync
        self.onRefresh = onRefresh
        self.onSettings = onSettings
    }

    public var body: some View {
        TabView(selection: $model.selection) {
            Tab("Home", systemImage: "house", value: PhoneTab.home) {
                HomeView(model: model.home, syncStatus: syncStatus, onRefresh: onRefresh, onSettings: onSettings)
                    .offlineBanner(syncStatus, lastSync: lastSync)
            }
            Tab("Month", systemImage: "calendar", value: PhoneTab.month) {
                MonthView(model: model.month, syncStatus: syncStatus, onRefresh: onRefresh)
                    .offlineBanner(syncStatus, lastSync: lastSync)
            }
            Tab("Accounts", systemImage: "building.columns", value: PhoneTab.accounts) {
                AccountsView(model: model.accounts, syncStatus: syncStatus, onRefresh: onRefresh)
                    .offlineBanner(syncStatus, lastSync: lastSync)
            }
            if model.hasProperty {
                Tab("Property", systemImage: "building.2", value: PhoneTab.property) {
                    PropertyView(model: model.property, syncStatus: syncStatus, onRefresh: onRefresh)
                        .offlineBanner(syncStatus, lastSync: lastSync)
                }
            }
            Tab(value: PhoneTab.search, role: .search) {
                SearchView(model: model.search, syncStatus: syncStatus, onRefresh: onRefresh)
                    .offlineBanner(syncStatus, lastSync: lastSync)
            }
        }
        // Each screen shows it under its navigation bar (`offlineBannerSlot`, `demoBannerSlot`).
        .environment(\.showsDemoData, isDemo)
        .environment(\.quickEdit, model.quickEdit)
        .task(id: SyncReloadTrigger(syncStatus)) {
            await model.reload(for: PhoneTabsModel.reloadKey(syncStatus))
        }
    }
}
