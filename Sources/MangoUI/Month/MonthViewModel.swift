import Foundation
import BudgetCore
import GRDB

/// Month's state (iPhone spec §3.3): one batched read (`DashboardInput.load`), then `PayMonthReview.make` for the
/// month shown. Nothing here computes a figure. ‹ › move through the pay calendar's months, from the month of the
/// first transaction to the current one; the segment stays as the month changes.
///
/// Home's pattern: `load()` reads off the main actor and sets `state` back on it; the view awaits it in
/// `.task(id: reloadKey)` and `.refreshable`; the snapshot routes use `readNow`. Keep the model above the lock cover,
/// so relocking keeps the month, the segment and the pushed transactions.
@MainActor
public final class MonthViewModel: ObservableObject {
    public enum State: Equatable, Sendable {
        /// Not loaded yet.
        case idle
        case loaded(MonthPage)
        /// The read failed before anything was shown (`loadFailureMessage`).
        case failed(String)
    }

    /// What Month says when its read fails: a fixed sentence, never the error's own text.
    public static let loadFailureMessage = "Mango couldn't read this month. Pull down to try again."

    @Published public private(set) var state: State
    /// Set when a reload fails while an earlier month stays on screen; nil after a good load.
    @Published public private(set) var errorMessage: String?
    @Published public var segment: MonthSegment
    /// The transactions pushed from a row (kept here, above the lock cover, so a relock keeps them).
    @Published public var path: [MonthRowDestination] = []
    /// The iPad: the category whose transactions the side panel shows (the iPhone pushes them on `path`).
    @Published public var panelDestination: MonthRowDestination?

    private let dbQueue: any DatabaseReader
    private let today: () -> Date
    /// Whose figures Month shows (step 6): the next load reads with it, and so do the pushed lists.
    public var viewer: PhoneViewer {
        didSet { for model in transactionModels.values { model.viewer = viewer } }
    }
    /// The month asked for; nil = the current pay month.
    private var requested: PayMonth?
    /// The `reloadKey` the last `reload(for:)` loaded for.
    private var loadedKey: Date?
    /// The pushed lists' models, so going back and forth (or relocking) doesn't read them again.
    private var transactionModels: [MonthRowDestination: MonthTransactionsModel] = [:]
    /// Counts reads, so a slower earlier read (two quick taps on ‹) never replaces a later one.
    private var generation = 0

    public init(dbQueue: any DatabaseReader, today: @escaping () -> Date, viewer: PhoneViewer = .everyone, segment: MonthSegment = .spending) {
        self.dbQueue = dbQueue
        self.today = today
        self.viewer = viewer
        self.segment = segment
        self.state = .idle
    }

    /// Already loaded (the snapshot harness: a route renders its first frame with the data in it).
    public init(dbQueue: any DatabaseReader, today: @escaping () -> Date, viewer: PhoneViewer = .everyone, segment: MonthSegment = .spending,
                preloaded state: State) {
        self.dbQueue = dbQueue
        self.today = today
        self.viewer = viewer
        self.segment = segment
        self.state = state
        if case let .loaded(page) = state { requested = page.review.month }
    }

    /// Reads the month asked for off the main actor. A failed read keeps what was shown (and says so).
    public func load() async {
        generation += 1
        let mine = generation
        let day = today()
        let month = requested
        let reader = dbQueue
        let viewer = viewer
        do {
            let page = try await reader.read { db in try Self.read(db, today: day, month: month, viewer: viewer) }
            guard mine == generation else { return }
            state = .loaded(page)
            errorMessage = nil
        } catch {
            guard mine == generation else { return }
            switch state {
            case .loaded: errorMessage = Self.loadFailureMessage
            case .idle, .failed: state = .failed(Self.loadFailureMessage)
            }
        }
    }

    /// The same read, now (the snapshot routes, which can't await before their first frame). `month` nil: the
    /// current pay month.
    public nonisolated static func readNow(_ dbQueue: any DatabaseReader, today: Date, month: PayMonth? = nil,
                                           viewer: PhoneViewer = .everyone) -> State {
        do {
            return .loaded(try dbQueue.read { db in try read(db, today: today, month: month, viewer: viewer) })
        } catch {
            return .failed(loadFailureMessage)
        }
    }

    nonisolated static func read(_ db: Database, today: Date, month: PayMonth?, viewer: PhoneViewer = .everyone) throws -> MonthPage {
        let input = try DashboardInput.load(db: db, today: today, actuals: try viewer.actuals(db: db, today: today))
        let calendar = input.payCalendar
        let current = calendar.current
        let firstDay = input.transactions.map(\.date).min()
        let first = min(firstDay.map(calendar.month(containing:)) ?? current, current)
        let shown = min(max(month ?? current, first), current)
        return MonthPage(review: PayMonthReview.make(month: shown, input: input), months: first...current)
    }

    // MARK: ‹ ›

    private var page: MonthPage? {
        if case let .loaded(page) = state { page } else { nil }
    }

    public var canShowPrevious: Bool {
        guard let page else { return false }
        return page.review.month > page.months.lowerBound
    }

    public var canShowNext: Bool {
        guard let page else { return false }
        return page.review.month < page.months.upperBound
    }

    public func showPrevious() async {
        guard canShowPrevious, let page else { return }
        requested = page.review.month.previous
        panelDestination = nil
        await load()
    }

    public func showNext() async {
        guard canShowNext, let page else { return }
        requested = page.review.month.next
        panelDestination = nil
        await load()
    }

    // MARK: Reloading after a sync

    /// What Month reloads on: Home's key, the last sync's time.
    public nonisolated static func reloadKey(_ status: SyncStatus) -> Date? {
        HomeViewModel.reloadKey(status)
    }

    /// `.task(id: reloadKey)`'s body: loads the first time, then again only when a new sync has landed.
    public func reload(for key: Date?) async {
        // A first load that failed reads again on every sync's start and end (`SyncReloadTrigger`), data or not.
        if state != .idle, !state.isFailed {
            guard let key, key != loadedKey else { return }
        }
        loadedKey = key
        await load()
        await refreshTransactionLists()
    }

    /// Lists already made (one may be on screen) read again in place, with their row's new figures.
    public func refreshTransactionLists() async {
        let rows = page?.review.rows ?? []
        for (destination, model) in transactionModels {
            await model.refresh(row: rows.first { $0.id == destination.row.id && page?.review.range == destination.range })
        }
    }

    // MARK: A row's transactions

    /// The model of the list `destination` pushes: made once, read when it first shows.
    public func transactionsModel(for destination: MonthRowDestination) -> MonthTransactionsModel {
        if let model = transactionModels[destination] { return model }
        let model = MonthTransactionsModel(dbQueue: dbQueue, row: destination.row, range: destination.range, viewer: viewer, today: today)
        transactionModels[destination] = model
        return model
    }

    // MARK: The route's check

    /// The snapshot route's assertion (plan Task 8 step 2): the summary grid's four figures are
    /// `PayMonthReview.make`'s for the same month, read afresh.
    public nonisolated static func summaryCheck(dbQueue: any DatabaseReader, today: Date, shown: MonthPage) throws -> (matches: Bool, line: String) {
        let month = shown.review.month
        let fresh = try dbQueue.read { db in PayMonthReview.make(month: month, input: try DashboardInput.load(db: db, today: today)) }
        let tiles = MonthSummaryTile.tiles(shown.review)
        let expected = [fresh.incomeMinorUnits, fresh.spentMinorUnits, fresh.stillExpectedMinorUnits, fresh.leftToSpendMinorUnits]
        let matches = tiles.map(\.minorUnits) == expected
        let shownText = zip(tiles, expected).map { tile, value in
            "\(tile.label) \(Money.format(tile.minorUnits, currency: .gbp))"
                + (tile.minorUnits == value ? "" : " (review \(Money.format(value, currency: .gbp)))")
        }
        let line = "\(MonthCopy.title(month)): " + shownText.joined(separator: ", ")
            + (matches ? " (equal to PayMonthReview.make)" : " (DIFFERENT)")
        return (matches, line)
    }
}

extension MonthViewModel.State: ScreenLoadState {}
