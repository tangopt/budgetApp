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

/// A screen's load state, as `reload(for:)` asks it: a first load that failed reads again on every sync's start and
/// end. The five tabs' states conform (each has `case failed(String)`).
protocol ScreenLoadState {
    var isFailed: Bool { get }
}

extension ScreenLoadState {
    var isFailed: Bool {
        // Every conforming state spells its failure `.failed(String)`: an enum case's payload is a child labelled
        // with the case's name.
        Mirror(reflecting: self).children.first?.label == "failed"
    }
}
