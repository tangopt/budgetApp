import Foundation
import BudgetCore

/// Whether this iPhone lets Mango send notifications (the system's answer; `notDetermined` until asked in Settings).
public enum NotificationAuthorization: Equatable, Sendable {
    case granted, denied, notDetermined
}

/// The notification center, as the scheduler sees it. The app's is `UNUserNotificationCenter`; tests use an in-memory
/// fake and never touch the real one.
public protocol NotificationCenterClient: Sendable {
    func authorizationStatus() async -> NotificationAuthorization
    /// Asks the system for permission (the prompt appears only the first time). Called only from Settings.
    func requestAuthorization() async -> Bool
    /// Every pending request: id → its words (`PlannedNotification.content`).
    func pendingContent() async -> [String: String]
    func add(_ notification: PlannedNotification) async throws
    func remove(ids: [String]) async
}

/// Every notification id this iPhone has ever handed to the notification center, so a reminder that already fired is
/// not sent again. Per device: `UserDefaults` never syncs.
public struct LedgerStore: @unchecked Sendable {
    public static let defaultsKey = "phone.notificationLedger"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var ids: Set<String> {
        Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    public func insert(_ added: [String]) {
        guard !added.isEmpty else { return }
        defaults.set(Array(ids.union(added)).sorted(), forKey: Self.defaultsKey)
    }
}

/// Runs the notification center's operations one after another (each waits for the one before), so a clear is never
/// overtaken by a refresh that started before it.
@MainActor
public final class NotificationOperations {
    private var last: Task<Void, Never>?

    public init() {}

    @discardableResult
    public func enqueue(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = last
        let task = Task {
            await previous?.value
            await operation()
        }
        last = task
        return task
    }
}

/// Keeps the notification center equal to the plan (step 7b spec §2.4).
public enum NotificationScheduler {
    /// The key a scheduled notification's `userInfo` carries its tab link under (`WidgetLink`'s URL string).
    public static let linkKey = "link"

    /// `userInfo` for a notification that opens `link` when tapped.
    public static func userInfo(for link: PhoneTabLink) -> [String: String] {
        [linkKey: WidgetLink.url(for: link).absoluteString]
    }

    /// The tab a tapped notification opens; nil for anything else.
    public static func link(fromUserInfo userInfo: [AnyHashable: Any]) -> PhoneTabLink? {
        guard let text = userInfo[linkKey] as? String, let url = URL(string: text) else { return nil }
        return WidgetLink.tab(from: url)
    }

    /// Does nothing unless the person has allowed notifications (and never asks). Otherwise removes pending
    /// reminders no longer planned, replaces pending ones whose words changed, and adds the planned ones that are
    /// neither pending nor already handed over. Stops as soon as `isCurrent` says a later refresh or a clear has
    /// replaced this one (checked before every change).
    public static func refresh(plan: [PlannedNotification], client: any NotificationCenterClient, ledger: LedgerStore,
                               isCurrent: @escaping @MainActor @Sendable () -> Bool = { true }) async {
        guard await client.authorizationStatus() == .granted else { return }
        let reconciliation = NotificationReconciler.reconcile(planned: plan, pending: await client.pendingContent(), ledger: ledger.ids)
        guard await isCurrent() else { return }
        if !reconciliation.remove.isEmpty { await client.remove(ids: reconciliation.remove) }
        var added: [String] = []
        defer { ledger.insert(added) }
        for notification in reconciliation.add {
            guard await isCurrent() else { return }
            do {
                try await client.add(notification)
                added.append(notification.id)
            } catch {
                continue
            }
        }
    }

    /// Removes everything pending (no one's figures stay scheduled once no iCloud user is bound to this iPhone).
    public static func clear(client: any NotificationCenterClient) async {
        let pending = await client.pendingContent()
        if !pending.isEmpty { await client.remove(ids: pending.keys.sorted()) }
    }
}
