import Foundation
import BudgetCore
import GRDB
import struct BudgetCore.Property

/// Every thing the iPad's Calendar offers (step 10, Task 15), each answering what the Mac's Calendar tab shows. The
/// Calendar writes nothing, so nothing here is an edit.
public enum PadCalendarAction: String, CaseIterable, Sendable {
    /// The next twelve months as an agenda grouped by month.
    case agenda
    /// A small month grid, a day tappable (new on the iPad).
    case monthGrid
    /// Obligations still to come, or those already past.
    case upcomingOrPast
    /// The agenda narrowed to a tapped day.
    case filterByDay
    /// An obligation's side card: kind, date, expected amount and what it is.
    case selectObligation

    public var title: String {
        switch self {
        case .agenda: "Agenda"
        case .monthGrid: "Month"
        case .upcomingOrPast: "Upcoming and past"
        case .filterByDay: "Filter by day"
        case .selectObligation: "Obligation details"
        }
    }

    /// What the Mac's Calendar tab shows, by the words it uses, and what answers each here. `testEveryMacMoneyAndCalendarCapabilityListed`
    /// keeps the list whole.
    static let macActions: [(mac: String, pad: PadCalendarAction)] = [
        ("The next twelve months", .agenda),
        ("A panel for each month", .agenda),
        ("Day, what, expected amount", .agenda),
        ("≈ an estimate from the property's history", .agenda),
        ("A pill for a deadline without an amount", .selectObligation),
        ("The month's expected total", .agenda),
        ("Nothing due: link the accounts in Profile", .agenda),
    ]
}

/// The property's obligations for the iPad's Calendar: the next twelve months (and the twelve behind), as the Mac's
/// `PropertyCalendar.obligations` reads them, placed by `PropertyCalendarGrid` into an agenda and a month grid. Nothing
/// here computes a figure; the screen only switches what it shows and what is selected.
@MainActor
public final class PadCalendarModel: ObservableObject {
    public enum Layout: String, CaseIterable, Identifiable, Sendable {
        case agenda = "Agenda", month = "Month"
        public var id: String { rawValue }
    }

    public enum Range: String, CaseIterable, Identifiable, Sendable {
        case upcoming = "Upcoming", past = "Past"
        public var id: String { rawValue }
    }

    public struct Snapshot: Equatable, Sendable {
        public var today: Date
        /// Due from today on, within twelve months.
        public var upcoming: [PropertyObligation]
        /// Dated in the twelve months up to today.
        public var past: [PropertyObligation]

        public static let empty = Snapshot(today: Date(timeIntervalSince1970: 0), upcoming: [], past: [])
    }

    @Published public private(set) var snapshot: Snapshot = .empty
    @Published public var layout: Layout = .agenda
    @Published public var range: Range = .upcoming {
        didSet { if range != oldValue { selectedDay = nil; selectedId = nil } }
    }
    /// The month the grid shows (its first day).
    @Published public var shownMonth: Date = MonthRange.calendar.startOfDay(for: Date())
    /// A day tapped on the grid: the agenda lists only that day.
    @Published public var selectedDay: Date?
    @Published public var selectedId: String?

    public let property: PadPropertyModel
    private let dbQueue: any DatabaseReader
    private let today: () -> Date
    private var generation = 0
    private var isPreloaded = false

    public init(property: PadPropertyModel, dbQueue: any DatabaseReader, today: @escaping () -> Date) {
        self.property = property
        self.dbQueue = dbQueue
        self.today = today
        shownMonth = Self.monthStart(MonthRange.calendar.startOfDay(for: today()))
    }

    // MARK: Reading

    public func preload(_ snapshot: Snapshot) {
        self.snapshot = snapshot
        shownMonth = Self.monthStart(snapshot.today)
        isPreloaded = true
    }

    public func reload() async {
        guard !isPreloaded else { return }
        generation += 1
        let mine = generation
        guard let propertyId = property.property?.id else {
            snapshot = .empty
            return
        }
        let day = MonthRange.calendar.startOfDay(for: today())
        let reader = dbQueue
        guard let read = try? await reader.read({ db in try Self.read(db, propertyId: propertyId, today: day) }), mine == generation else { return }
        snapshot = read
        if let id = selectedId, !(read.upcoming + read.past).contains(where: { $0.id == id }) { selectedId = nil }
    }

    public nonisolated static func readNow(_ dbQueue: any DatabaseReader, propertyId: Int64?, today: Date) -> Snapshot {
        guard let propertyId else { return .empty }
        let day = MonthRange.calendar.startOfDay(for: today)
        return (try? dbQueue.read { db in try read(db, propertyId: propertyId, today: day) }) ?? .empty
    }

    /// The Mac's read: twelve months from today (`today` is already the stored UTC day), and the twelve behind.
    nonisolated static func read(_ db: Database, propertyId: Int64, today: Date) throws -> Snapshot {
        let calendar = MonthRange.calendar
        let end = calendar.date(byAdding: .month, value: 12, to: today)!
        let start = calendar.date(byAdding: .month, value: -12, to: today)!
        return Snapshot(today: today,
                        upcoming: try PropertyCalendar.obligations(db: db, propertyId: propertyId, from: today, to: end, today: today),
                        past: try PropertyCalendar.obligations(db: db, propertyId: propertyId, from: start, to: today, today: today))
    }

    // MARK: What is shown

    /// The grid's calendar: the stored (UTC) days, the weeks starting on the device's first weekday.
    public var calendar: Calendar {
        var calendar = MonthRange.calendar
        calendar.firstWeekday = Calendar.current.firstWeekday
        return calendar
    }

    /// The agenda for the chosen range: months with something due, narrowed to `selectedDay` when one is tapped.
    public var agenda: [PropertyCalendarGrid.AgendaMonth] {
        let items = range == .upcoming ? snapshot.upcoming : snapshot.past
        let narrowed = selectedDay.map { day in items.filter { calendar.isDate($0.date, inSameDayAs: day) } } ?? items
        return PropertyCalendarGrid.agenda(narrowed, from: snapshot.today, months: range == .upcoming ? 12 : -12, calendar: calendar)
    }

    /// The month grid: every obligation read, upcoming or past, on its day.
    public var gridDays: [PropertyCalendarGrid.GridDay] {
        PropertyCalendarGrid.month(shownMonth, items: snapshot.past + snapshot.upcoming, calendar: calendar)
    }

    public var isEmpty: Bool { snapshot.upcoming.isEmpty && snapshot.past.isEmpty }

    public var selected: PropertyObligation? {
        guard let selectedId else { return nil }
        return (snapshot.upcoming + snapshot.past).first { $0.id == selectedId }
    }

    public func select(_ obligation: PropertyObligation) { selectedId = obligation.id }
    public func closeCard() { selectedId = nil }

    /// Taps a grid day: it narrows the list to the day (tapping it again lifts the filter), and selects its only obligation.
    public func tap(_ day: PropertyCalendarGrid.GridDay) {
        if selectedDay.map({ calendar.isDate($0, inSameDayAs: day.date) }) == true {
            selectedDay = nil
            return
        }
        range = day.date < snapshot.today ? .past : .upcoming
        selectedDay = day.date
        selectedId = day.items.count == 1 ? day.items[0].id : nil
        if !day.isInMonth { shownMonth = Self.monthStart(day.date) }
    }

    /// What is due in the month the grid shows (or on the tapped day), in date order, under the grid.
    public var shownMonthItems: [PropertyObligation] {
        let all = (snapshot.past + snapshot.upcoming).sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        if let day = selectedDay { return all.filter { calendar.isDate($0.date, inSameDayAs: day) } }
        return all.filter { calendar.isDate($0.date, equalTo: shownMonth, toGranularity: .month) }
    }

    public func shiftMonth(by months: Int) {
        shownMonth = MonthRange.calendar.date(byAdding: .month, value: months, to: shownMonth)!
    }

    public func showToday() {
        shownMonth = Self.monthStart(snapshot.today)
        selectedDay = nil
    }

    private nonisolated static func monthStart(_ date: Date) -> Date {
        MonthRange.calendar.dateInterval(of: .month, for: date)?.start ?? date
    }

    // MARK: Words

    /// The kind as a pill: a tax deadline, a rate revision, a renewal, or what the cost is.
    public nonisolated static func kindName(_ kind: PropertyObligationKind) -> String {
        switch kind {
        case .imiInstalment: "Property tax"
        case .ptIncomeTaxReturn: "Tax return"
        case .ukSelfAssessmentJanuary, .ukSelfAssessmentJuly: "Tax deadline"
        case .mortgageRateReset: "Rate revision"
        case .mortgageInstalment: "Mortgage"
        case .insuranceRenewal: "Renewal"
        case .recurringCost: "Recurring cost"
        }
    }

    public nonisolated static func symbol(_ kind: PropertyObligationKind) -> String {
        switch kind {
        case .imiInstalment: "building.columns"
        case .ptIncomeTaxReturn, .ukSelfAssessmentJanuary, .ukSelfAssessmentJuly: "doc.text"
        case .mortgageRateReset: "percent"
        case .mortgageInstalment: "house"
        case .insuranceRenewal: "shield"
        case .recurringCost: "repeat"
        }
    }

    /// The obligation's title for a row, as the Mac shortens the Self Assessment deadlines.
    public nonisolated static func shortTitle(_ obligation: PropertyObligation) -> String {
        switch obligation.kind {
        case .ukSelfAssessmentJanuary:
            let year = MonthRange.components(of: obligation.date).year
            return "UK SA \(UKTaxYear(startYear: year - 2).label) return"
        case .ukSelfAssessmentJuly: return "UK SA 2nd payment"
        default: return obligation.title
        }
    }

    /// What the obligation is, for its card.
    public nonisolated static func explanation(_ obligation: PropertyObligation) -> String {
        switch obligation.kind {
        case .imiInstalment: "A Portuguese property tax instalment (May, August and November). The amount is last year's, when there is one."
        case .ptIncomeTaxReturn: "The Portuguese income tax return (IRS), due by 30 June for the year before."
        case .ukSelfAssessmentJanuary: "The UK Self Assessment return, the balancing payment and the first payment on account, due on 31 January."
        case .ukSelfAssessmentJuly: "The second payment on account for UK Self Assessment, due on 31 July."
        case .mortgageRateReset: "The mortgage's variable rate is revised on this day."
        case .mortgageInstalment: "A mortgage instalment, projected from the payments already made."
        case .insuranceRenewal: "The insurance cover ends and is due for renewal."
        case .recurringCost: "A cost that recurs in the property's history, expected again about now."
        }
    }
}
