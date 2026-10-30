import SwiftUI
import BudgetCore
import GRDB

/// The quick edits' snapshot routes (step 7b, Task 5): the edit sheet over the demo's boiler repair (`quick-edit-sheet`),
/// the same with a filed-year refusal (`quick-edit-refusal`), Quick sort over the demo's uncategorised rows
/// (`quick-sort`) and Update balance on a manual account (`update-balance`); `quick-edit-sheet-pad` is the edit sheet
/// in the iPad windows. Written as the demo's admin; a render writes nothing.
public enum QuickEditRoutes {
    static let all: [DemoRoute] = [
        DemoRoute(name: "quick-edit-sheet", minimumFigures: 2) { context in editSheet(context, refusal: nil) },
        DemoRoute(name: "quick-edit-refusal", minimumFigures: 2) { context in
            editSheet(context, refusal: DeviceWriteCopy.filedYear(years: ["2024/25"]))
        },
        DemoRoute(name: "quick-sort", minimumFigures: 2) { context in
            let today = context.today
            let model = model(context)
            let (queue, lists) = QuickEditModel.readNow(context.dbQueue, today: today, viewer: .demoAdmin)
            model.preload(lists: lists, queue: queue)
            return AnyView(NavigationStack { QuickSortContent(model: model).mangoNavigationTitle("Sort uncategorised").navigationBarTitleDisplayModeInline() })
        },
        DemoRoute(name: "update-balance", minimumFigures: 0) { context in
            let account = try? context.dbQueue.read { db in
                try Account.filter(Column("trackingMode") == AccountTrackingMode.manual.rawValue).order(Column("sortOrder")).fetchOne(db)
            }
            guard let account, let id = account.id else { return AnyView(Text("The demo has no manual account")) }
            return AnyView(UpdateBalanceSheet(accountId: id, accountName: account.displayName, currency: account.currency,
                                              today: context.today, model: model(context)))
        },
        DemoRoute(name: "quick-edit-sheet-pad", sizes: DemoRoute.padSizes, minimumFigures: 2, pad: true) { context in
            editSheet(context, refusal: nil)
        },
    ]

    @MainActor
    private static func model(_ context: PhoneDemoContext) -> QuickEditModel {
        let today = context.today
        return QuickEditModel(writer: DeviceWriter(db: context.dbQueue, viewer: { .demoAdmin }, afterWrite: {}), dbQueue: context.dbQueue,
                              today: { today })
    }

    @MainActor
    private static func editSheet(_ context: PhoneDemoContext, refusal: String?) -> AnyView {
        guard let row = SearchRoutes.detailRow(context) else { return AnyView(Text("The demo's boiler repair didn't load")) }
        let model = model(context)
        model.preload(lists: QuickEditModel.readListsNow(context.dbQueue), refusal: refusal)
        return AnyView(TransactionEditSheet(row: row, model: model))
    }
}
