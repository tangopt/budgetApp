import Foundation
import BudgetCore
import GRDB

/// Accounts as the phone shows them (iPhone spec §3.6): the Mac's Accounts screen's figures (`AccountsOverview.make`
/// over the same rows), the change since last December (`DashboardCalculator.changeSinceLastYearEnd`) and each
/// account's import reach (`ImportCoverage`). Nothing here computes a figure.
public struct AccountsPage: Equatable, Sendable {
    public let overview: AccountsOverview
    /// Nil without a December figure to compare with.
    public let sinceYearEnd: NetWorthSinceYearEnd?
    /// Each account's latest imported transaction (`ImportCoverage.importedThroughByAccount`); absent: none.
    public let importedThrough: [Int64: Date]
    /// The day the page was read for (the rows' "Checked n days ago").
    public let today: Date
    /// Cash, Credit, Investments (iPhone spec §3.6), empty ones left out.
    public let sections: [AccountsSection]

    /// `badges`: the viewer's own accounts shared below Everything and their level (`SharingViewer.badgeLevel`).
    public init(overview: AccountsOverview, sinceYearEnd: NetWorthSinceYearEnd?, importedThrough: [Int64: Date], today: Date,
                badges: [Int64: SharingLevel] = [:]) {
        self.overview = overview
        self.sinceYearEnd = sinceYearEnd
        self.importedThrough = importedThrough
        self.today = today
        sections = AccountsSection.order.compactMap { kind in
            overview.groups.first { $0.kind == kind }.map { group in
                AccountsSection(kind: kind, subtotalGBP: group.subtotalGBP, rows: group.rows.map { row in
                    AccountRowPresentation(row, importedThrough: importedThrough[row.id], today: today, sharing: badges[row.id])
                })
            }
        }
    }
}

/// One section of Accounts: its kind's title and the group's subtotal (`AccountGroup.subtotalGBP`, the accounts that
/// count toward net worth), then its rows in the Mac's order (`AccountOrdering`).
public struct AccountsSection: Equatable, Sendable, Identifiable {
    public let kind: AccountKind
    public let subtotalGBP: Int
    public let rows: [AccountRowPresentation]
    public var id: String { kind.rawValue }

    /// The spec's order: Cash, Credit, Investments.
    static let order: [AccountKind] = [.cash, .credit, .investment]

    public var title: String {
        switch kind {
        case .cash: "Cash"
        case .credit: "Credit"
        case .investment: "Investments"
        }
    }

    /// What VoiceOver reads for the subtotal ("Cash, balance £1,200.00").
    public var spokenSubtotal: String {
        MoneyPresentation(minorUnits: subtotalGBP, currency: .gbp, role: .balance).spoken
    }
}

/// What an account row pushes: its detail.
public struct AccountDestination: Hashable, Sendable {
    public let accountId: Int64
    public init(accountId: Int64) { self.accountId = accountId }
}

/// Accounts' state: one batched read (`DashboardInput.load`, which reads every account, snapshot and transaction as
/// the Mac's Accounts screen does), then `AccountsOverview.make` and last December's net worth.
///
/// Home's pattern: `load()` reads off the main actor and sets `state` back on it; the view awaits it in
/// `.task(id: reloadKey)` and `.refreshable`; the snapshot routes use `readNow`. Keep the model above the lock cover,
/// so relocking keeps the pushed account (`path`).
@MainActor
public final class AccountsViewModel: ObservableObject {
    public enum State: Equatable, Sendable {
        /// Not loaded yet.
        case idle
        /// No account yet (before the first sync).
        case empty
        case loaded(AccountsPage)
        /// The read failed before anything was shown (`loadFailureMessage`).
        case failed(String)

        /// The page, when loaded.
        public var page: AccountsPage? {
            if case let .loaded(page) = self { page } else { nil }
        }
    }

    /// What Accounts says when its read fails: a fixed sentence, never the error's own text.
    public static let loadFailureMessage = "Mango couldn't read the accounts. Pull down to try again."

    @Published public private(set) var state: State
    /// Set when a reload fails while an earlier page stays on screen; nil after a good load.
    @Published public private(set) var errorMessage: String?
    /// The account pushed from a row (kept here, above the lock cover, so a relock keeps it).
    @Published public var path: [AccountDestination] = []

    private let dbQueue: any DatabaseReader
    private let today: () -> Date
    /// Whose accounts these are (step 6): the next load reads with it, and so do the pushed details.
    public var viewer: PhoneViewer {
        didSet { for model in detailModels.values { model.viewer = viewer } }
    }
    /// The `reloadKey` the last `reload(for:)` loaded for.
    private var loadedKey: Date?
    /// The pushed details' models, so going back and forth (or relocking) doesn't read them again.
    private var detailModels: [AccountDestination: AccountDetailModel] = [:]
    /// Counts reads, so a slower earlier read never replaces a later one.
    private var generation = 0

    public init(dbQueue: any DatabaseReader, today: @escaping () -> Date, viewer: PhoneViewer = .everyone) {
        self.dbQueue = dbQueue
        self.today = today
        self.viewer = viewer
        self.state = .idle
    }

    /// Already loaded (the snapshot harness: a route renders its first frame with the data in it).
    public init(dbQueue: any DatabaseReader, today: @escaping () -> Date, viewer: PhoneViewer = .everyone, preloaded state: State) {
        self.dbQueue = dbQueue
        self.today = today
        self.viewer = viewer
        self.state = state
    }

    /// Shows an already read page (the iPad's snapshot routes).
    public func preload(_ state: State) {
        self.state = state
    }

    /// Reads off the main actor. A failed read keeps what was shown (and says so).
    public func load() async {
        generation += 1
        let mine = generation
        let day = today()
        let reader = dbQueue
        let viewer = viewer
        do {
            let loaded = try await reader.read { db in try Self.read(db, today: day, viewer: viewer) }
            guard mine == generation else { return }
            state = loaded
            errorMessage = nil
        } catch {
            guard mine == generation else { return }
            switch state {
            case .loaded, .empty: errorMessage = Self.loadFailureMessage
            case .idle, .failed: state = .failed(Self.loadFailureMessage)
            }
        }
    }

    /// The same read, now (the snapshot routes, which can't await before their first frame).
    public nonisolated static func readNow(_ dbQueue: any DatabaseReader, today: Date, viewer: PhoneViewer = .everyone) -> State {
        do {
            return try dbQueue.read { db in try read(db, today: today, viewer: viewer) }
        } catch {
            return .failed(loadFailureMessage)
        }
    }

    nonisolated static func read(_ db: Database, today: Date, viewer: PhoneViewer = .everyone) throws -> State {
        let seer = try viewer.resolve(db: db)
        let input = try DashboardInput.load(db: db, today: today, actuals: SharedActualsSource(viewer: seer, today: today))
        guard !input.accounts.isEmpty else { return .empty }
        let overview = AccountsOverview.make(accounts: input.accounts, snapshots: input.snapshots, transactions: input.transactions,
                                             rate: input.rate, today: today)
        // As the Mac's Accounts screen: only the built-in categories matter (they're the ones left out).
        let builtIns = input.categories.filter(\.isBuiltIn)
        let importedThrough = ImportCoverage.importedThroughByAccount(transactions: input.transactions, batches: input.importBatches,
                                                                      categories: builtIns)
        return .loaded(AccountsPage(overview: overview,
                                    sinceYearEnd: DashboardCalculator.changeSinceLastYearEnd(input, netWorthMinorUnits: overview.netWorthGBP),
                                    importedThrough: importedThrough, today: today,
                                    badges: Dictionary(uniqueKeysWithValues: input.accounts.compactMap { account in
                                        account.id.flatMap { id in seer.badgeLevel(account).map { (id, $0) } }
                                    })))
    }

    // MARK: Reloading after a sync

    /// What Accounts reloads on: Home's key, the last sync's time.
    public nonisolated static func reloadKey(_ status: SyncStatus) -> Date? {
        HomeViewModel.reloadKey(status)
    }

    /// `.task(id: reloadKey)`'s body: loads the first time, then again only when a new sync has landed. Details
    /// already made (one may be on screen) read again in place, with their row's new figures.
    public func reload(for key: Date?) async {
        // A first load that failed reads again on every sync's start and end (`SyncReloadTrigger`), data or not.
        if state != .idle, !state.isFailed {
            guard let key, key != loadedKey else { return }
        }
        loadedKey = key
        await load()
        let rows = state.page?.sections.flatMap(\.rows) ?? []
        for (destination, model) in detailModels {
            await model.refresh(row: rows.first { $0.id == destination.accountId })
        }
    }

    // MARK: An account's detail

    /// The row `destination` names, as the page shows it.
    public func row(for destination: AccountDestination) -> AccountRowPresentation? {
        state.page?.sections.lazy.flatMap(\.rows).first { $0.id == destination.accountId }
    }

    /// The model of the detail `destination` pushes: made once, read when it first shows.
    public func detailModel(for destination: AccountDestination) -> AccountDetailModel {
        if let model = detailModels[destination] { return model }
        let model = AccountDetailModel(dbQueue: dbQueue, accountId: destination.accountId, row: row(for: destination), today: today,
                                       viewer: viewer)
        detailModels[destination] = model
        return model
    }

    // MARK: The route's check

    /// The snapshot route's assertion (plan Task 9 step 2): the net worth and every section's subtotal shown equal
    /// the Mac's Accounts screen's (`AccountsOverview.netWorthGBP`, `AccountGroup.subtotalGBP`), read afresh the way
    /// the Mac reads them; the change is against `DashboardCalculator.yearEndNetWorth(year − 1, includeForecast: false)`.
    public nonisolated static func figuresCheck(dbQueue: any DatabaseReader, today: Date, shown: AccountsPage) throws -> (matches: Bool, line: String) {
        let (overview, december) = try dbQueue.read { db in
            (AccountsOverview.make(accounts: try Account.fetchAll(db), snapshots: try BalanceSnapshot.fetchAll(db),
                                   transactions: try Transaction.fetchAll(db), rate: try ExchangeRateSetting.currentOrDefault(db: db),
                                   today: today),
             DashboardCalculator.yearEndNetWorth(try DashboardInput.load(db: db, today: today),
                                                 year: MonthRange.components(of: today).year - 1, includeForecast: false))
        }
        func money(_ minorUnits: Int) -> String { Money.format(minorUnits, currency: .gbp) }
        var matches = shown.overview.netWorthGBP == overview.netWorthGBP
        var parts = ["net worth \(money(shown.overview.netWorthGBP))" + (matches ? "" : " (Mac \(money(overview.netWorthGBP)))")]
        for section in shown.sections {
            let subtotal = overview.groups.first { $0.kind == section.kind }?.subtotalGBP
            let equal = subtotal == section.subtotalGBP
            matches = matches && equal
            parts.append("\(section.title) \(money(section.subtotalGBP))" + (equal ? "" : " (Mac \(subtotal.map(money) ?? "none"))"))
        }
        let shownKinds = Set(shown.sections.map(\.kind))
        if shownKinds != Set(overview.groups.map(\.kind)) {
            matches = false
            parts.append("sections differ from the Mac's groups")
        }
        let expectedChange = december.map { overview.netWorthGBP - $0.valueMinorUnits }
        let changeEqual = shown.sinceYearEnd?.changeMinorUnits == expectedChange
        matches = matches && changeEqual
        parts.append("since December \(shown.sinceYearEnd.map { money($0.changeMinorUnits) } ?? "none")"
                     + (changeEqual ? "" : " (expected \(expectedChange.map(money) ?? "none"))"))
        let line = "accounts on \(PhoneDateFormat.day(today)): " + parts.joined(separator: ", ")
            + (matches ? " (equal to AccountsOverview / AccountGroup.subtotalGBP)" : " (DIFFERENT)")
        return (matches, line)
    }
}

/// Accounts' words that aren't a row's.
public enum AccountsCopy {
    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = MonthRange.calendar
        formatter.timeZone = MonthRange.calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    /// "Since December 2025".
    public static func sinceLabel(_ since: NetWorthSinceYearEnd) -> String {
        "Since " + monthFormatter.string(from: MonthRange.of(year: since.year, month: 12).start)
    }

    /// The compact header's second line: "+£7,960.00 since December 2025" (the change, then the base month).
    public static func sinceCaption(_ since: NetWorthSinceYearEnd) -> String {
        let change = MoneyPresentation(minorUnits: since.changeMinorUnits, currency: .gbp, role: .income).text
        return "\(since.changeMinorUnits > 0 ? "+" : "")\(change) since" + sinceLabel(since).dropFirst("Since".count)
    }

    /// A stale account's amber line (the Mac's rule, `BalanceStaleness`). Updating it from the phone comes in step 6.
    public static let needsUpdate = "Needs an update"
    /// An account left out of net worth (its balance isn't in the subtotal).
    public static let notInNetWorth = "Not in net worth"
    public static let emptyTitle = "No accounts yet"
    public static let emptyMessage = "The household's accounts show here once they sync from the Mac."
}

extension AccountsViewModel.State: ScreenLoadState {}
