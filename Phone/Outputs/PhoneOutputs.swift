import Foundation
import SwiftUI
import WidgetKit
import BudgetCore
import MangoUI
import GRDB
import OSLog

/// What this iPhone shows outside the app (step 7b): the widget's snapshot (`WidgetSnapshot`, Home's own figures for
/// the device's viewer) and the output settings (`PhoneOutputSettings`). Both live in the App Group
/// (`PhoneAppGroup.identifier`) so the widget reads them; in a build without the group (unsigned) there is no store and
/// nothing is written, and the settings fall back to the app's own `UserDefaults`.
///
/// The reminders (`NotificationPlanner`) are planned in the same refreshes and handed to the notification center only
/// once the person has allowed notifications in Settings ▸ Notifications; Mango never asks at launch.
///
/// `refresh(viewer:)` after a sync that moved `lastSync`, on unlock and on returning to the foreground; `clear()` on
/// demo data and when no iCloud user is bound to this device (signed out, changed, removed from the household).
@MainActor
final class PhoneOutputs: ObservableObject {
    static let shared = PhoneOutputs()

    /// Settings ▸ Widgets binds to it; a change is kept and the snapshot written again.
    @Published var settings: PhoneOutputSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save(to: defaults)
            if let viewer = lastViewer { refresh(viewer: viewer) }
        }
    }

    /// What the system allows, for Settings ▸ Notifications.
    @Published private(set) var notificationAccess: NotificationAuthorization = .notDetermined
    /// A tapped reminder's tab, until the root opens it.
    @Published var pendingLink: PhoneTabLink?

    private let center: any NotificationCenterClient
    private let ledger: LedgerStore
    private let store: (any WidgetSnapshotStore)?
    private let defaults: UserDefaults
    private var dbQueue: (any DatabaseReader)?
    private var today: () -> Date = { Date() }
    private var isDemo = false
    /// The viewer the latest refresh was for: a settings change writes the snapshot again for it.
    private var lastViewer: PhoneViewer?
    /// Counts refreshes and clears: a build that finishes after a later one is dropped.
    private var generation = 0

    private static let log = Logger(subsystem: "ubberninja.mango.ios", category: "Widgets")

    init(store: (any WidgetSnapshotStore)? = PhoneOutputs.appGroupStore(), defaults: UserDefaults = PhoneOutputs.appGroupDefaults(),
         center: any NotificationCenterClient = SystemNotificationCenter()) {
        self.store = store
        self.defaults = defaults
        self.center = center
        ledger = LedgerStore(defaults: .standard)
        settings = PhoneOutputSettings.load(from: defaults)
    }

    /// The App Group's folder, or nil when this build has no group (unsigned): no snapshot is written.
    nonisolated static func appGroupStore() -> (any WidgetSnapshotStore)? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: PhoneAppGroup.identifier) else {
            return nil
        }
        return FileWidgetSnapshotStore(directory: container)
    }

    /// The App Group's defaults; the app's own when this build has no group.
    nonisolated static func appGroupDefaults() -> UserDefaults {
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: PhoneAppGroup.identifier) != nil,
              let suite = UserDefaults(suiteName: PhoneAppGroup.identifier) else { return .standard }
        return suite
    }

    /// The database the snapshot reads (the phone's own, or demo data's, which only clears it).
    func attach(dbQueue: any DatabaseReader, today: @escaping () -> Date, isDemo: Bool) {
        self.dbQueue = dbQueue
        self.today = today
        self.isDemo = isDemo
        if isDemo { clear() }
    }

    /// Builds the snapshot for `viewer` off the main thread (the database's read), writes it, and asks the widgets to reload; clears it
    /// instead when `WidgetSnapshotPolicy` says so.
    func refresh(viewer: PhoneViewer) {
        let bound: Bool = if case .iCloudUser(let recordName?) = viewer { !recordName.isEmpty } else { false }
        guard !WidgetSnapshotPolicy.shouldClear(isDemo: isDemo, viewerBound: bound) else { return clear() }
        guard let dbQueue else { return }
        lastViewer = viewer
        generation += 1
        let (generation, settings, day) = (self.generation, self.settings, today())
        scheduleNotifications(dbQueue: dbQueue, viewer: viewer, settings: settings, day: day, generation: generation)
        guard let store else { return }
        Task {
            let snapshot: WidgetSnapshot?
            do {
                snapshot = try await dbQueue.read { db in try WidgetSnapshot.make(db: db, viewer: viewer, today: day, settings: settings) }
            } catch {
                Self.log.error("Widgets: the snapshot couldn't be built (\(String(describing: type(of: error)), privacy: .public))")
                return
            }
            // Checked and written in one step on the main actor, so a clear meanwhile is never undone (a small file).
            guard generation == self.generation else { return }
            // Nothing synced yet: no snapshot (a stale one goes).
            guard let snapshot else { return clear() }
            do {
                try store.write(snapshot)
            } catch {
                Self.log.error("Widgets: the snapshot couldn't be written (\(String(describing: type(of: error)), privacy: .public))")
                return
            }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Plans the reminders for `viewer` and brings the notification center to the plan; nothing unless allowed.
    private func scheduleNotifications(dbQueue: any DatabaseReader, viewer: PhoneViewer, settings: PhoneOutputSettings, day: Date,
                                       generation: Int) {
        let (center, ledger) = (center, ledger)
        Task {
            let access = await center.authorizationStatus()
            notificationAccess = access
            guard access == .granted else { return }
            let plan: [PlannedNotification]
            do {
                plan = try await dbQueue.read { db in
                    try NotificationPlanner.plan(db: db, viewer: viewer, today: day, now: Date(), settings: settings)
                }
            } catch {
                Self.log.error("Notifications: the plan couldn't be built (\(String(describing: type(of: error)), privacy: .public))")
                return
            }
            guard generation == self.generation else { return }
            await NotificationScheduler.refresh(plan: plan, client: center, ledger: ledger)
        }
    }

    /// Re-reads what the system allows (Settings opens, the app returns to the foreground).
    func refreshNotificationAccess() async {
        notificationAccess = await center.authorizationStatus()
    }

    /// "Allow notifications": the only place Mango asks. Plans at once when the answer is yes.
    func allowNotifications() async {
        _ = await center.requestAuthorization()
        notificationAccess = await center.authorizationStatus()
        if notificationAccess == .granted, let viewer = lastViewer { refresh(viewer: viewer) }
    }

    /// Deletes the snapshot (the widget then shows nothing of anyone's) and asks the widgets to reload.
    func clear() {
        generation += 1
        lastViewer = nil
        let center = center
        Task { await NotificationScheduler.clear(client: center) }
        guard let store else { return }
        do {
            try store.clear()
        } catch {
            Self.log.error("Widgets: the snapshot couldn't be removed (\(String(describing: type(of: error)), privacy: .public))")
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
