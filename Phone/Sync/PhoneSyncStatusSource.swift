import Foundation
import BudgetCore

/// Where the tabs read the sync status from, and what pull to refresh asks. A placeholder until Task 12's
/// `PhoneSyncController` replaces it: sync isn't running on the phone yet, so the status is `.off` and a refresh asks
/// for nothing (each tab still reads its own data again).
@MainActor
final class PhoneSyncStatusSource: ObservableObject {
    @Published private(set) var status: SyncStatus = .off

    /// Pull to refresh: asks for changes and waits for them (Task 12). Nothing to ask yet.
    func refresh() async {}
}
