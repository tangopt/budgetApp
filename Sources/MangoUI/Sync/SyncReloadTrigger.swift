import Foundation
import BudgetCore

/// What each screen's `.task(id:)` is keyed on: the reload key (the last sync's time, `HomeViewModel.reloadKey`) and
/// whether a sync is running. So the task runs again when a sync lands new data (the key moves), and also when any
/// sync starts or ends: a screen whose first load failed reads again then, even after a sync that brought nothing
/// (offline, waiting for the key); a screen that shows data keeps it until the key moves.
public struct SyncReloadTrigger: Hashable, Sendable {
    public let key: Date?
    public let syncing: Bool

    public init(_ status: SyncStatus) {
        key = HomeViewModel.reloadKey(status)
        if case .syncing = status { syncing = true } else { syncing = false }
    }
}
