import Foundation
import BudgetCore
import GRDB

/// Home's state (iPhone spec §3.2): one batched read (`DashboardInput.load`, as the Mac's `DashboardViewModel.load`),
/// then `HomeSummary.make`, the dashboard's calculators packaged for the phone. Nothing here computes a figure.
///
/// The pattern the phone's screens share: `load()` is async and reads on GRDB's reader, off the main actor, setting
/// `state` back on it; the view awaits it in `.task(id:)` (keyed on the sync's last-sync time, `reloadKey`) and in
/// `.refreshable`. Keep the model above the lock cover (owned by the tab, not by the covered content), so relocking
/// keeps what Home showed and where it was scrolled to.
@MainActor
public final class HomeViewModel: ObservableObject {
    public enum State: Equatable, Sendable {
        /// Not loaded yet.
        case idle
        /// The database holds no accounts and no transactions (before the first sync).
        case empty
        case loaded(HomeSummary)
        /// The read failed before anything was shown (`loadFailureMessage`).
        case failed(String)
    }

    /// What Home says when its read fails: a fixed sentence, never the error's own text (which can quote SQL).
    public static let loadFailureMessage = "Mango couldn't read the household's data. Pull down to try again."

    @Published public private(set) var state: State
    /// Set when a reload fails while an earlier summary stays on screen; nil after a good load.
    @Published public private(set) var errorMessage: String?

    private let dbQueue: any DatabaseReader
    private let today: () -> Date
    /// The `reloadKey` the last `reload(for:)` loaded for.
    private var loadedKey: Date?

    public init(dbQueue: any DatabaseReader, today: @escaping () -> Date) {
        self.dbQueue = dbQueue
        self.today = today
        self.state = .idle
    }

    /// Already loaded (the snapshot harness: a route renders its first frame with the data in it).
    public init(dbQueue: any DatabaseReader, today: @escaping () -> Date, preloaded state: State) {
        self.dbQueue = dbQueue
        self.today = today
        self.state = state
    }

    /// Reads and summarises off the main actor. A failed read keeps what was shown (and says so in `errorMessage`).
    public func load() async {
        let day = today()
        let reader = dbQueue
        do {
            let loaded = try await reader.read { db in try Self.read(db, today: day) }
            state = loaded
            errorMessage = nil
        } catch {
            fail()
        }
    }

    /// The same read, now (the snapshot routes, which can't await before their first frame).
    public nonisolated static func readNow(_ dbQueue: any DatabaseReader, today: Date) -> State {
        do {
            return try dbQueue.read { db in try read(db, today: today) }
        } catch {
            return .failed(loadFailureMessage)
        }
    }

    private func fail() {
        switch state {
        case .loaded, .empty:
            errorMessage = Self.loadFailureMessage
        case .idle, .failed:
            state = .failed(Self.loadFailureMessage)
        }
    }

    nonisolated private static func read(_ db: Database, today: Date) throws -> State {
        let input = try DashboardInput.load(db: db, today: today)
        guard !isEmpty(input) else { return .empty }
        return .loaded(try HomeSummary.make(input, db: db))
    }

    // MARK: Reloading after a sync

    /// What Home reloads on: the last sync's time, which moves when a sync (scheduled, background or the first
    /// download) brings changes in. Nil while there is none to go by (off, syncing, offline…).
    public nonisolated static func reloadKey(_ status: SyncStatus) -> Date? {
        switch status {
        case .idle(let lastSync), .needsAttention(_, let lastSync): lastSync
        case .off, .syncing, .waitingForKey, .offline, .unavailable, .failed: nil
        }
    }

    /// `.task(id: reloadKey)`'s body: loads the first time, then again only when the key moves to a new sync. A nil
    /// key (a sync running, offline) keeps what is shown.
    public func reload(for key: Date?) async {
        if state != .idle {
            guard let key, key != loadedKey else { return }
        }
        loadedKey = key
        await load()
    }

    /// Nothing synced yet: no account and no transaction.
    nonisolated static func isEmpty(_ input: DashboardInput) -> Bool {
        input.accounts.isEmpty && input.transactions.isEmpty
    }

    /// The snapshot route's assertion (plan Task 7 step 2): Home's net worth is the Accounts screen's
    /// (`AccountsOverview.netWorthGBP`) on the same day.
    public nonisolated static func netWorthCheck(dbQueue: any DatabaseReader, today: Date, shown: HomeSummary) throws -> (matches: Bool, line: String) {
        let overview = try dbQueue.read { db in
            AccountsOverview.make(accounts: try Account.fetchAll(db), snapshots: try BalanceSnapshot.fetchAll(db),
                                  transactions: try Transaction.fetchAll(db), rate: try ExchangeRateSetting.currentOrDefault(db: db),
                                  today: today)
        }
        let home = shown.netWorth.currentNetWorthMinorUnits
        let matches = home == overview.netWorthGBP
        let homeText = home.map { Money.format($0, currency: .gbp) } ?? "none"
        let line = "net worth on \(PhoneDateFormat.day(today)): Home \(homeText), AccountsOverview.netWorthGBP "
            + Money.format(overview.netWorthGBP, currency: .gbp) + (matches ? " (equal)" : " (DIFFERENT)")
        return (matches, line)
    }
}
