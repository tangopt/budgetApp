import Foundation
import BudgetCore
import GRDB

/// What Property shows (iPhone spec §3.7): every property's `PropertyGlance`, by name. One property is shown
/// directly; several are a list, each row pushing its property. Nothing here computes a figure.
public struct PropertyPage: Equatable, Sendable {
    public var glances: [PropertyGlance]
    /// The day the page was read for.
    public let today: Date

    public init(glances: [PropertyGlance], today: Date) {
        self.glances = glances
        self.today = today
    }

    /// The one property, shown directly; nil when there are several.
    public var single: PropertyGlance? {
        glances.count == 1 ? glances[0] : nil
    }
}

/// What a property row pushes (several properties): that property.
public struct PropertyDestination: Hashable, Sendable {
    public let propertyId: Int64
    public init(propertyId: Int64) { self.propertyId = propertyId }
}

/// Property's state: one read of `PropertyGlance.all`, which reads the Mac's property calculators.
///
/// Home's pattern: `load()` reads off the main actor and sets `state` back on it; the view awaits it in
/// `.task(id: reloadKey)` and `.refreshable`; the snapshot routes use `readNow`. Keep the model above the lock cover,
/// so relocking keeps the pushed property (`path`).
@MainActor
public final class PropertyViewModel: ObservableObject {
    public enum State: Equatable, Sendable {
        /// Not loaded yet.
        case idle
        /// No property set up (or none synced yet).
        case empty
        case loaded(PropertyPage)
        /// The read failed before anything was shown (`loadFailureMessage`).
        case failed(String)

        /// The page, when loaded.
        public var page: PropertyPage? {
            if case let .loaded(page) = self { page } else { nil }
        }
    }

    /// What Property says when its read fails: a fixed sentence, never the error's own text.
    public static let loadFailureMessage = "Mango couldn't read the property. Pull down to try again."

    @Published public private(set) var state: State
    /// Set when a reload fails while an earlier page stays on screen; nil after a good load.
    @Published public private(set) var errorMessage: String?
    /// The property pushed from the list (kept here, above the lock cover, so a relock keeps it).
    @Published public var path: [PropertyDestination] = []

    private let dbQueue: any DatabaseReader
    private let today: () -> Date
    /// The `reloadKey` the last `reload(for:)` loaded for.
    private var loadedKey: Date?
    /// Counts reads, so a slower earlier read never replaces a later one.
    private var generation = 0

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

    /// Reads off the main actor. A failed read keeps what was shown (and says so).
    public func load() async {
        generation += 1
        let mine = generation
        let day = today()
        let reader = dbQueue
        do {
            let loaded = try await reader.read { db in try Self.read(db, today: day) }
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
    public nonisolated static func readNow(_ dbQueue: any DatabaseReader, today: Date) -> State {
        do {
            return try dbQueue.read { db in try read(db, today: today) }
        } catch {
            return .failed(loadFailureMessage)
        }
    }

    nonisolated static func read(_ db: Database, today: Date) throws -> State {
        let glances = try PropertyGlance.all(db: db, today: today)
        return glances.isEmpty ? .empty : .loaded(PropertyPage(glances: glances, today: today))
    }

    // MARK: Reloading after a sync

    /// What Property reloads on: Home's key, the last sync's time.
    public nonisolated static func reloadKey(_ status: SyncStatus) -> Date? {
        HomeViewModel.reloadKey(status)
    }

    /// `.task(id: reloadKey)`'s body: loads the first time, then again only when a new sync has landed. A pushed
    /// property reads its glance from the page, so it refreshes in place.
    public func reload(for key: Date?) async {
        // A first load that failed reads again on every sync's start and end (`SyncReloadTrigger`), data or not.
        if state != .idle, !state.isFailed {
            guard let key, key != loadedKey else { return }
        }
        loadedKey = key
        await load()
    }

    /// The glance `destination` names, as the page holds it; nil once it's gone.
    public func glance(for destination: PropertyDestination) -> PropertyGlance? {
        state.page?.glances.first { $0.property.id == destination.propertyId }
    }

    // MARK: The route's check

    /// The snapshot route's assertion (plan Task 10): for every property, the figures shown equal the Mac's, read
    /// afresh the Mac's way: this month's rent is the rent line of `PropertyFinance.monthBreakdown` (when received);
    /// the mortgage owed, in euros and pounds, is `PropertySummary.outstandingLoan` (`PropertyFinance.summary` to the
    /// end of today); the progress is `MortgageHistory.progress`; the next instalment, rate and review are
    /// `MortgageRate.status`'s; coming up is `PropertyCalendar.obligations` over the next `PropertyGlance.comingUpDays`.
    public nonisolated static func figuresCheck(dbQueue: any DatabaseReader, today: Date, shown: PropertyPage) throws -> (matches: Bool, line: String) {
        var matches = true
        var parts: [String] = []
        func note(_ label: String, _ shownText: String, _ equal: Bool, mac: String) {
            matches = matches && equal
            parts.append("\(label) \(shownText)" + (equal ? "" : " (Mac \(mac))"))
        }
        let calendar = MonthRange.calendar
        let day = calendar.startOfDay(for: today)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: day)!
        let comingUpEnd = calendar.date(byAdding: .day, value: PropertyGlance.comingUpDays, to: day)!
        let (year, month) = MonthRange.components(of: day)
        let monthStart = MonthRange.of(year: year, month: month).start
        let thisMonth = DateInterval(start: monthStart, end: calendar.date(byAdding: .month, value: 1, to: monthStart)!)
        let properties = try dbQueue.read { db in try Properties.all(db: db) }
        if properties.compactMap(\.id) != shown.glances.compactMap(\.property.id) {
            matches = false
            parts.append("properties differ from the Mac's")
        }
        for glance in shown.glances {
            guard let id = glance.property.id else { continue }
            let currency = glance.property.currency
            func money(_ minorUnits: Int?, _ in: Currency? = nil) -> String {
                minorUnits.map { Money.format($0, currency: `in` ?? currency) } ?? "none"
            }
            typealias Mac = (rentLine: PropertyFlowLine?, summary: PropertySummary, terms: PropertyMortgageTerms,
                             status: MortgageRate.Status?, obligations: [PropertyObligation])
            let mac = try dbQueue.read { db -> Mac in
                (rentLine: try PropertyFinance.monthBreakdown(db: db, propertyId: id, interval: thisMonth).group(.rent)?.lines
                    .filter { $0.counted.native > 0 }.last,
                 summary: try PropertyFinance.summary(db: db, propertyId: id,
                                                      period: .custom(DateInterval(start: monthStart, end: endOfToday)),
                                                      today: today),
                 terms: try MortgageTerms.terms(db: db, propertyId: id),
                 status: try MortgageRate.status(db: db, propertyId: id, today: today),
                 obligations: try PropertyCalendar.obligations(db: db, propertyId: id, from: day,
                                                               to: comingUpEnd, today: day))
            }
            parts.append(glance.property.name + ":")
            if case .received = glance.rent {
                let expected = mac.rentLine?.counted.native
                note("rent", money(glance.rentMinorUnits), glance.rentMinorUnits == expected, mac: money(expected))
            }
            if let mortgage = glance.mortgage {
                let owed = mac.summary.outstandingLoan
                note("owed", money(mortgage.outstandingMinorUnits), mortgage.outstandingMinorUnits == owed.native, mac: money(owed.native))
                note("owed in pounds", money(mortgage.outstandingGBPMinorUnits, .gbp), mortgage.outstandingGBPMinorUnits == owed.gbp,
                     mac: money(owed.gbp, .gbp))
                let progress = MortgageHistory.progress(terms: mac.terms, owedMinorUnits: owed.native, today: today)
                note("repaid", mortgage.progress.map { "\($0.percent)%" } ?? "none", mortgage.progress == progress,
                     mac: progress.map { "\($0.percent)%" } ?? "none")
                note("next instalment", money(mortgage.nextInstalmentMinorUnits),
                     mortgage.nextInstalmentMinorUnits == mac.status?.nextInstalmentMinorUnits
                        && mortgage.nextInstalmentDate == mac.status?.nextDue
                        && mortgage.ratePercent == mac.status?.current?.ratePercent
                        && mortgage.nextReview == mac.status?.nextRevision,
                     mac: money(mac.status?.nextInstalmentMinorUnits))
            } else {
                note("no mortgage", "", mac.status == nil, mac: "has one")
            }
            note("coming up", "\(glance.comingUp.count)", glance.comingUp == mac.obligations, mac: "\(mac.obligations.count)")
        }
        let line = "property on \(PhoneDateFormat.day(today)): " + parts.joined(separator: " ")
            + (matches ? " (equal to PropertyFinance / PropertySummary / MortgageRate / PropertyCalendar)" : " (DIFFERENT)")
        return (matches, line)
    }
}

/// Property's words: statuses, captions and what VoiceOver reads. Wording only: the figures are `PropertyGlance`'s.
public enum PropertyCopy {
    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = MonthRange.calendar
        formatter.timeZone = MonthRange.calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    /// "Let since 1 Aug 2024 · contract to 31 Jul 2027" (iPhone spec §3.7); "· no end date" for an open tenancy.
    public static func tenancyLine(_ glance: PropertyGlance) -> String {
        guard let since = glance.letSince else { return "Not let at the moment" }
        let start = "Let since \(PhoneDateFormat.day(since))"
        guard let to = glance.contractTo else { return start + " · no end date" }
        return start + " · contract to \(PhoneDateFormat.day(to))"
    }

    /// Received <date> / Expected <date> / Late (iPhone spec §3.7); nil without a tenancy.
    public static func rentStatus(_ status: PropertyGlance.RentStatus) -> String? {
        switch status {
        case let .received(day): "Received \(PhoneDateFormat.day(day))"
        case let .expected(day): "Expected \(PhoneDateFormat.day(day))"
        case let .late(since): "Late · due \(PhoneDateFormat.day(since))"
        case .none: nil
        }
    }

    /// Rent in is income once received; until then it's only what's due.
    public static func rentRole(_ status: PropertyGlance.RentStatus) -> MoneyRole {
        if case .received = status { .income } else { .neutral }
    }

    public static func isLate(_ status: PropertyGlance.RentStatus) -> Bool {
        if case .late = status { true } else { false }
    }

    public static func receipt(_ status: PropertyGlance.ReceiptStatus) -> String? {
        switch status {
        case .issued: "Issued"
        case .pending: "Not issued yet"
        case .none: nil
        }
    }

    public static func recharge(_ status: PropertyGlance.RechargeStatus) -> String {
        switch status {
        case .paid: "Paid"
        case .sent: "Sent"
        case .readyToSend: "Ready to send"
        case .none: "Nothing to send"
        }
    }

    /// "September 2026 · Ready to send"; nil without a statement.
    public static func rechargeCaption(_ glance: PropertyGlance) -> String? {
        guard let status = glance.lastRecharge else { return nil }
        let month = glance.lastRechargeMonth.map { monthFormatter.string(from: $0) + " · " } ?? ""
        return month + recharge(status)
    }

    /// "25%": the share repaid, rounded down (`MortgageHistory.Progress.percent`).
    public static func repaid(_ progress: MortgageHistory.Progress) -> String { "\(progress.percent)%" }

    public static func spokenRepaid(_ progress: MortgageHistory.Progress) -> String { "\(progress.percent) percent repaid" }

    /// "Instalment 26 of 360"; nil before the first.
    public static func instalment(_ progress: MortgageHistory.Progress) -> String? {
        guard let number = progress.instalmentNumber else { return nil }
        return progress.totalInstalments.map { "Instalment \(number) of \($0)" } ?? "Instalment \(number)"
    }

    /// The rate as the Mac writes it (`MortgageRate.percent`).
    public static func rate(_ percent: Double) -> String { MortgageRate.percent(percent) }

    /// "1 Nov 2026", with "· est." for an estimate.
    public static func comingUpCaption(_ obligation: PropertyObligation) -> String {
        PhoneDateFormat.day(obligation.date) + (obligation.isEstimate ? " · est." : "")
    }

    /// "Mortgage instalment, 1 Nov 2026, estimated, due €700.00".
    public static func comingUpSpoken(_ obligation: PropertyObligation, currency: Currency) -> String {
        var parts = [obligation.title, PhoneDateFormat.day(obligation.date)]
        if obligation.isEstimate { parts.append("estimated") }
        parts.append(obligation.expectedMinorUnits.map {
            MoneyPresentation(minorUnits: $0, currency: obligation.currency ?? currency, role: .due).spoken
        } ?? "amount not known")
        return parts.joined(separator: ", ")
    }

    public static let nothingComingUp = "Nothing due in the next \(PropertyGlance.comingUpDays) days."
    public static let notLet = "No tenancy runs today."
    public static let amountNotKnown = "Amount not known"
    public static let emptyTitle = "No property set up"
    public static let emptyMessage = "A property set up on the Mac shows here once it syncs."
}

extension PropertyViewModel.State: ScreenLoadState {}
