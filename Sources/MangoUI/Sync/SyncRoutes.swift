import SwiftUI
import BudgetCore
import GRDB

/// The sync states' snapshot routes (plan step 4 Task 12): Home waiting for the household key (an empty database,
/// as before the key arrives: Review Focus 2), Home offline (the banner over the demo), the iCloud explanation, the
/// first download and Settings.
public enum SyncRoutes {
    static let all: [DemoRoute] = [
        DemoRoute(name: "home-waiting_for_key", minimumFigures: 0) { context in
            guard let empty = emptyDatabase() else { return AnyView(Text("Couldn't build an empty database")) }
            return home(empty, today: context.today, status: .waitingForKey(since: context.today.addingTimeInterval(-600)),
                        lastSync: nil)
        },
        // The same 14 figures as `home`, under the banner.
        DemoRoute(name: "home-offline", minimumFigures: 14, figuresBelowFold: 7) { context in
            home(context.dbQueue, today: context.today,
                 status: .offline(since: context.today.addingTimeInterval(-900), retryAt: context.today.addingTimeInterval(120)),
                 lastSync: context.today.addingTimeInterval(-2 * 3_600))
        },
        DemoRoute(name: "icloud-unavailable", minimumFigures: 0) { _ in
            AnyView(ICloudUnavailableView(state: .noAccount, onOpenSettings: {}, onShowLocal: {}))
        },
        DemoRoute(name: "first-download", minimumFigures: 0) { _ in
            AnyView(FirstDownloadView(received: 1_284))
        },
        DemoRoute(name: "settings", minimumFigures: 0) { context in
            let today = context.today
            return AnyView(SettingsSheet(appearance: .constant(.system), themeId: .constant(PhoneTheme.classic.id),
                                         iCloud: .available, keyHeld: true,
                                         status: .idle(lastSync: today.addingTimeInterval(-300)),
                                         version: SettingsCopy.version(marketing: "0.2.0", build: "1"), now: { today },
                                         onLockNow: {}, onSyncNow: {}))
        },
    ]

    /// A migrated database with nothing in it, in memory: never the phone's own.
    private static func emptyDatabase() -> DatabaseQueue? {
        do {
            let manager = try DatabaseManager(path: nil)
            try manager.migrate()
            return manager.dbQueue
        } catch {
            return nil
        }
    }

    @MainActor
    private static func home(_ dbQueue: DatabaseQueue, today: Date, status: SyncStatus, lastSync: Date?) -> AnyView {
        let model = HomeViewModel(dbQueue: dbQueue, today: { today }, preloaded: HomeViewModel.readNow(dbQueue, today: today))
        return AnyView(HomeView(model: model, syncStatus: status, onRefresh: {}, onSettings: {}, now: { today })
            .offlineBanner(status, lastSync: lastSync, now: { today }))
    }
}
