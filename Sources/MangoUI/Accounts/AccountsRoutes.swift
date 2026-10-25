import SwiftUI
import BudgetCore
import GRDB

/// Accounts' snapshot routes (plan step 4, Task 9): `accounts` (the demo on its day), `account-detail` (the demo's
/// first cash account: chart and recent transactions) and `accounts-empty` (an empty database, before the first sync).
public enum AccountsRoutes {
    /// The demo's Accounts measures 17 figures in every render (net worth and its change, 3 subtotals, 8 balances, 4
    /// pounds equivalents), 7 below the first screen at default size; the detail 21 (the balance and 20 amounts), 16
    /// below it. The captions' days aren't figures the probe measures (they may wrap between words, never inside a day).
    static let all: [DemoRoute] = [
        DemoRoute(name: "accounts", minimumFigures: 17, figuresBelowFold: 6,
                  check: { context in try figuresCheck(context) }) { context in
            accounts(context.dbQueue, today: context.today, status: context.syncStatus)
        },
        DemoRoute(name: "account-detail", minimumFigures: 21, figuresBelowFold: 14) { context in
            detail(context)
        },
        DemoRoute(name: "accounts-empty", minimumFigures: 0) { context in
            let empty: DatabaseQueue
            do {
                let manager = try DatabaseManager(path: nil)
                try manager.migrate()
                empty = manager.dbQueue
            } catch {
                return AnyView(Text("Couldn't build an empty database: \(error.localizedDescription)"))
            }
            return accounts(empty, today: context.today, status: .idle(lastSync: nil))
        },
    ]

    @MainActor
    private static func accounts(_ dbQueue: DatabaseQueue, today: Date, status: SyncStatus) -> AnyView {
        let model = AccountsViewModel(dbQueue: dbQueue, today: { today }, preloaded: AccountsViewModel.readNow(dbQueue, today: today))
        return AnyView(AccountsView(model: model, syncStatus: status))
    }

    /// The first cash account (the demo's everyday current account), pushed.
    @MainActor
    private static func detail(_ context: PhoneDemoContext) -> AnyView {
        guard let page = AccountsViewModel.readNow(context.dbQueue, today: context.today).page,
              let row = page.sections.first?.rows.first else {
            return AnyView(Text("The demo's accounts didn't load"))
        }
        let today = context.today
        let model = AccountDetailModel(dbQueue: context.dbQueue, accountId: row.id, row: row, today: { today },
                                       preloaded: AccountDetailModel.readNow(context.dbQueue, accountId: row.id, today: today))
        return AnyView(NavigationStack { AccountDetailView(model: model) })
    }

    /// The net worth, the change since December and every section's subtotal equal the Mac's; throws when they don't.
    @MainActor
    private static func figuresCheck(_ context: PhoneDemoContext) throws -> String {
        guard let page = AccountsViewModel.readNow(context.dbQueue, today: context.today).page else {
            throw DemoRouteCheckFailure(message: "accounts: the demo didn't load")
        }
        let check = try AccountsViewModel.figuresCheck(dbQueue: context.dbQueue, today: context.today, shown: page)
        guard check.matches else { throw DemoRouteCheckFailure(message: "accounts: \(check.line)") }
        return "accounts: \(check.line)"
    }
}
