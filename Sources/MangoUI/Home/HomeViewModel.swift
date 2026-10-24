import Foundation
import BudgetCore
import GRDB

/// Home's state (iPhone spec §3.2): one batched read (`DashboardInput.load`, as the Mac's `DashboardViewModel.load`),
/// then `HomeSummary.make`, the dashboard's calculators packaged for the phone. Nothing here computes a figure.
///
/// Keep it above the lock cover (owned by the tab, not by the covered content), so relocking keeps what Home showed
/// and where it was scrolled to.
@MainActor
public final class HomeViewModel: ObservableObject {
    public enum State: Equatable {
        /// Not loaded yet.
        case idle
        /// The database holds no accounts and no transactions (before the first sync).
        case empty
        case loaded(HomeSummary)
        /// The read failed before anything was shown.
        case failed(String)
    }

    @Published public private(set) var state: State = .idle
    /// The last load's failure while an earlier summary stays on screen; nil after a good load.
    @Published public private(set) var errorMessage: String?

    private let dbQueue: any DatabaseReader
    private let today: () -> Date

    public init(dbQueue: any DatabaseReader, today: @escaping () -> Date) {
        self.dbQueue = dbQueue
        self.today = today
    }

    /// Reads and summarises. A failed read keeps what was shown (and says so in `errorMessage`).
    public func load() {
        let day = today()
        do {
            let loaded: State = try dbQueue.read { db in
                let input = try DashboardInput.load(db: db, today: day)
                guard !Self.isEmpty(input) else { return .empty }
                return .loaded(try HomeSummary.make(input, db: db))
            }
            state = loaded
            errorMessage = nil
        } catch {
            let message = "Couldn't load Home: \(error.localizedDescription)"
            switch state {
            case .loaded, .empty:
                errorMessage = message
            case .idle, .failed:
                state = .failed(message)
            }
        }
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
