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
    /// Property is absent while the database has no property row (spec §3.9, permission None's analogue; ruling for
    /// step 4).
    @Published public private(set) var hasProperty: Bool

    public let home: HomeViewModel
    public let month: MonthViewModel
    public let accounts: AccountsViewModel
    public let property: PropertyViewModel
    public let search: SearchViewModel

    private let dbQueue: any DatabaseReader
    private var loadedKey: Date?

    /// `hasProperty`: what `hasProperty(_:)` read when the database opened. `home`: an already loaded Home (the
    /// snapshot harness's `tabs` route).
    public init(dbQueue: any DatabaseReader, today: @escaping () -> Date, hasProperty: Bool, home: HomeViewModel? = nil) {
        self.dbQueue = dbQueue
        self.hasProperty = hasProperty
        self.home = home ?? HomeViewModel(dbQueue: dbQueue, today: today)
        month = MonthViewModel(dbQueue: dbQueue, today: today)
        accounts = AccountsViewModel(dbQueue: dbQueue, today: today)
        property = PropertyViewModel(dbQueue: dbQueue, today: today)
        search = SearchViewModel(dbQueue: dbQueue, today: today)
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
}

/// The unlocked app: Home · Month · Accounts · Property, and Search as the iOS 26 search tab. Shown inside the lock
/// cover; `model` lives above it. Every tab reloads itself when `syncStatus`'s last sync moves.
public struct PhoneTabs: View {
    @ObservedObject var model: PhoneTabsModel
    let syncStatus: SyncStatus
    let onRefresh: () async -> Void
    let onSettings: () -> Void

    public init(model: PhoneTabsModel, syncStatus: SyncStatus, onRefresh: @escaping () async -> Void,
                onSettings: @escaping () -> Void) {
        self.model = model
        self.syncStatus = syncStatus
        self.onRefresh = onRefresh
        self.onSettings = onSettings
    }

    public var body: some View {
        TabView(selection: $model.selection) {
            Tab("Home", systemImage: "house", value: PhoneTab.home) {
                HomeView(model: model.home, syncStatus: syncStatus, onRefresh: onRefresh, onSettings: onSettings)
            }
            Tab("Month", systemImage: "calendar", value: PhoneTab.month) {
                MonthView(model: model.month, syncStatus: syncStatus, onRefresh: onRefresh)
            }
            Tab("Accounts", systemImage: "building.columns", value: PhoneTab.accounts) {
                AccountsView(model: model.accounts, syncStatus: syncStatus, onRefresh: onRefresh)
            }
            if model.hasProperty {
                Tab("Property", systemImage: "building.2", value: PhoneTab.property) {
                    PropertyView(model: model.property, syncStatus: syncStatus, onRefresh: onRefresh)
                }
            }
            Tab(value: PhoneTab.search, role: .search) {
                SearchView(model: model.search, syncStatus: syncStatus, onRefresh: onRefresh)
            }
        }
        .task(id: PhoneTabsModel.reloadKey(syncStatus)) {
            await model.reload(for: PhoneTabsModel.reloadKey(syncStatus))
        }
    }
}
