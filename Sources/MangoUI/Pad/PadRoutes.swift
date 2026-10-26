import SwiftUI
import BudgetCore

/// The iPad's snapshot routes (step 8, Task 6): rendered by `--device ipad` at the iPad window sizes.
public enum PadRoutes {
    /// The iPad window sizes the harness renders: portrait and landscape on the 11-inch and 13-inch iPads.
    public static let windowSizes: [CGSize] = [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834),
                                               CGSize(width: 1032, height: 1376), CGSize(width: 1376, height: 1032)]

    static let all: [DemoRoute] = [
        // The sidebar over Home: Home's 14 figures (the sidebar adds none).
        DemoRoute(name: "pad-root", sizes: DemoRoute.padSizes, minimumFigures: 14, pad: true) { context in
            let today = context.today
            let tabs = PhoneTabsModel(dbQueue: context.dbQueue, today: { today }, hasProperty: true, viewer: .demoAdmin,
                                      home: HomeViewModel(dbQueue: context.dbQueue, today: { today }, viewer: .demoAdmin,
                                                          preloaded: HomeViewModel.readNow(context.dbQueue, today: today)))
            return AnyView(PadRootView(tabs: tabs, syncStatus: context.syncStatus, columns: .doubleColumn))
        },
    ]
}
