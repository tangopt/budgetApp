import SwiftUI
import BudgetCore
import GRDB

/// Search's snapshot routes (plan step 4, Task 11): `search` (nothing typed: the newest days), `search-results` (the
/// Uncategorised token: the demo's five waiting rows with the amber "?"), `search-amount` (">100" this month),
/// `search-empty` ("Nothing matches"), `transaction-detail` (the demo's boiler repair, in euros, with its note) and
/// `tabs` (the tab bar on Home).
public enum SearchRoutes {
    /// What `search-amount` types.
    static let amountQuery = ">100"
    /// What `search-empty` types.
    static let emptyQuery = "zzqx"

    /// Figures: `search` lists whole days up to 20 rows (each row's amount, each day's date and total); the
    /// uncategorised five fall on five days (5 rows + 10 day figures); the detail's amount and date.
    static let all: [DemoRoute] = [
        DemoRoute(name: "search", minimumFigures: 26, figuresBelowFold: 10) { context in
            search(context, query: "", tokens: [])
        },
        DemoRoute(name: "search-results", minimumFigures: 15,
                  check: { context in try dayTotalsCheck(context, route: "search-results", query: "", tokens: [.uncategorised]) }) { context in
            search(context, query: "", tokens: [.uncategorised])
        },
        DemoRoute(name: "search-amount", minimumFigures: 6,
                  check: { context in
                      try dayTotalsCheck(context, route: "search-amount", query: amountQuery, tokens: [.period(.thisMonth)])
                  }) { context in
            search(context, query: amountQuery, tokens: [.period(.thisMonth)])
        },
        DemoRoute(name: "search-empty", minimumFigures: 0) { context in
            search(context, query: emptyQuery, tokens: [])
        },
        DemoRoute(name: "transaction-detail", minimumFigures: 2) { context in
            guard let row = detailRow(context) else { return AnyView(Text("The demo's boiler repair didn't load")) }
            return AnyView(TransactionDetailSheet(row: row))
        },
        DemoRoute(name: "tabs", minimumFigures: 14) { context in
            let today = context.today
            let tabs = PhoneTabsModel(dbQueue: context.dbQueue, today: { today }, hasProperty: true,
                                      home: HomeViewModel(dbQueue: context.dbQueue, today: { today },
                                                          preloaded: HomeViewModel.readNow(context.dbQueue, today: today)))
            return AnyView(PhoneTabs(model: tabs, syncStatus: context.syncStatus, onRefresh: {}, onSettings: {}))
        },
    ]

    @MainActor
    private static func search(_ context: PhoneDemoContext, query: String, tokens: [SearchToken]) -> AnyView {
        let today = context.today
        let model = SearchViewModel(dbQueue: context.dbQueue, today: { today }, query: query, tokens: tokens,
                                    preloaded: SearchViewModel.readNow(context.dbQueue))
        return AnyView(SearchView(model: model, syncStatus: context.syncStatus))
    }

    /// The demo's boiler repair (euros, a note).
    @MainActor
    static func detailRow(_ context: PhoneDemoContext) -> TransactionSearch.Row? {
        guard let data = SearchViewModel.readNow(context.dbQueue) else { return nil }
        return TransactionSearch.rows(data.index, criteria: TransactionSearch.Criteria(text: "boiler repair"), now: context.today).first
    }

    /// Each day shown is `TransactionSearch.totals` over that day's matches (`SearchViewModel.dayTotalsCheck`).
    @MainActor
    private static func dayTotalsCheck(_ context: PhoneDemoContext, route: String, query: String, tokens: [SearchToken]) throws -> String {
        let today = context.today
        let model = SearchViewModel(dbQueue: context.dbQueue, today: { today }, query: query, tokens: tokens,
                                    preloaded: SearchViewModel.readNow(context.dbQueue))
        let check = try SearchViewModel.dayTotalsCheck(dbQueue: context.dbQueue, today: today, criteria: model.criteria, shown: model.results)
        guard check.matches else { throw DemoRouteCheckFailure(message: "\(route): \(check.line)") }
        return "\(route): \(check.line)"
    }
}
