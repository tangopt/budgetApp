import SwiftUI
import BudgetCore
import GRDB

/// Home's snapshot routes (plan step 4, Task 7): `home` (the demo on its day), `home-empty` (an empty database, as
/// before the first sync) and `home-stale_data` (the demo read `staleDays` later, so the freshness line is amber).
public enum HomeRoutes {
    /// How many days after the demo's day `home-stale_data` reads it: past `HomeSummary.freshnessAmberDays`.
    public static let staleDays = 30

    public static func staleToday(from today: Date) -> Date {
        MonthRange.calendar.date(byAdding: .day, value: staleDays, to: today)!
    }

    /// The demo's Home measures 14 figures in every render (the stack isn't lazy, so the probe sees all of it even in
    /// the first-screen window): Net worth 3 (figure, change, year end), This pay month 4, Needs attention 2 counts,
    /// Upcoming 5. At least 7 sit below the first screen at default size.
    static let all: [DemoRoute] = [
        DemoRoute(name: "home", minimumFigures: 14, figuresBelowFold: 7,
                  check: { context in try netWorthCheck(context) }) { context in
            home(context.dbQueue, today: context.today, status: context.syncStatus)
        },
        DemoRoute(name: "home-empty", minimumFigures: 0) { context in
            // A migrated database with nothing in it, in memory: never the phone's own.
            let empty: DatabaseQueue
            do {
                let manager = try DatabaseManager(path: nil)
                try manager.migrate()
                empty = manager.dbQueue
            } catch {
                return AnyView(Text("Couldn't build an empty database: \(error.localizedDescription)"))
            }
            return home(empty, today: context.today, status: .idle(lastSync: nil))
        },
        DemoRoute(name: "home-stale_data", minimumFigures: 14, figuresBelowFold: 7) { context in
            home(context.dbQueue, today: staleToday(from: context.today), status: context.syncStatus)
        },
    ]

    @MainActor
    private static func home(_ dbQueue: DatabaseQueue, today: Date, status: SyncStatus) -> AnyView {
        let model = HomeViewModel(dbQueue: dbQueue, today: { today }, preloaded: HomeViewModel.readNow(dbQueue, today: today))
        return AnyView(HomeView(model: model, syncStatus: status, onRefresh: {}, onSettings: {}, now: { today }))
    }

    /// Home's net worth equals `AccountsOverview.netWorthGBP` on the demo's day; throws when it doesn't.
    @MainActor
    private static func netWorthCheck(_ context: PhoneDemoContext) throws -> String {
        guard case let .loaded(summary) = HomeViewModel.readNow(context.dbQueue, today: context.today) else {
            throw DemoRouteCheckFailure(message: "home: the demo didn't load")
        }
        let check = try HomeViewModel.netWorthCheck(dbQueue: context.dbQueue, today: context.today, shown: summary)
        guard check.matches else { throw DemoRouteCheckFailure(message: "home: \(check.line)") }
        return "home: \(check.line)"
    }
}
