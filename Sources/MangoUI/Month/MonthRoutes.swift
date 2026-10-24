import SwiftUI
import BudgetCore
import GRDB

/// Month's snapshot routes (plan step 4, Task 8): `month` (the demo's current pay month, Spending), `month-income`
/// (the same month on Income), `month-empty` (an empty database: a projected month with no rows) and
/// `month-transactions` (the list the month's largest spending row opens).
public enum MonthRoutes {
    /// The demo's October 2026 measures 42 figures at default size (the grid's 4, then 19 spending rows' "actual /
    /// plan" and status), 31 of them below the first screen; Income 9; the busiest row's list (Groceries) 8: 4 days
    /// and 4 amounts. The minimums leave a little room for the demo to change.
    static let all: [DemoRoute] = [
        DemoRoute(name: "month", minimumFigures: 40, figuresBelowFold: 25,
                  check: { context in try summaryCheck(context) }) { context in
            month(context.dbQueue, today: context.today, status: context.syncStatus, segment: .spending)
        },
        DemoRoute(name: "month-income", minimumFigures: 8) { context in
            month(context.dbQueue, today: context.today, status: context.syncStatus, segment: .income)
        },
        // The summary grid's four figures, at zero.
        DemoRoute(name: "month-empty", minimumFigures: 4) { context in
            let empty: DatabaseQueue
            do {
                let manager = try DatabaseManager(path: nil)
                try manager.migrate()
                empty = manager.dbQueue
            } catch {
                return AnyView(Text("Couldn't build an empty database: \(error.localizedDescription)"))
            }
            return month(empty, today: context.today, status: .idle(lastSync: nil), segment: .spending)
        },
        DemoRoute(name: "month-transactions", minimumFigures: 6) { context in
            transactions(context)
        },
    ]

    @MainActor
    private static func month(_ dbQueue: DatabaseQueue, today: Date, status: SyncStatus, segment: MonthSegment) -> AnyView {
        let model = MonthViewModel(dbQueue: dbQueue, today: { today }, segment: segment,
                                   preloaded: MonthViewModel.readNow(dbQueue, today: today))
        return AnyView(MonthView(model: model, syncStatus: status))
    }

    /// The current month's spending row with the most transactions, and its list.
    @MainActor
    private static func transactions(_ context: PhoneDemoContext) -> AnyView {
        guard case let .loaded(page) = MonthViewModel.readNow(context.dbQueue, today: context.today) else {
            return AnyView(Text("The demo's month didn't load"))
        }
        let lists = page.rows(.spending).map { row in
            (row: row, state: MonthTransactionsModel.readNow(context.dbQueue, row: row, range: page.review.range))
        }
        func count(_ state: MonthTransactionsModel.State) -> Int {
            if case let .loaded(days) = state { days.reduce(0) { $0 + $1.rows.count } } else { 0 }
        }
        guard let busiest = lists.max(by: { count($0.state) < count($1.state) }) else {
            return AnyView(Text("The demo's month has no spending"))
        }
        let model = MonthTransactionsModel(dbQueue: context.dbQueue, row: busiest.row, range: page.review.range,
                                           preloaded: busiest.state)
        return AnyView(NavigationStack { MonthTransactionsView(model: model) })
    }

    /// The summary grid's four figures equal `PayMonthReview.make` for the same month; throws when they don't.
    @MainActor
    private static func summaryCheck(_ context: PhoneDemoContext) throws -> String {
        guard case let .loaded(page) = MonthViewModel.readNow(context.dbQueue, today: context.today) else {
            throw DemoRouteCheckFailure(message: "month: the demo didn't load")
        }
        let check = try MonthViewModel.summaryCheck(dbQueue: context.dbQueue, today: context.today, shown: page)
        guard check.matches else { throw DemoRouteCheckFailure(message: "month: \(check.line)") }
        return "month: \(check.line)"
    }
}
