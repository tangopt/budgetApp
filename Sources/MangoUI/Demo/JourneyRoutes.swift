import SwiftUI
import BudgetCore
import GRDB

/// Redesign step 7: the three journeys as snapshot route sequences, one route per step, so a walk through reads as a
/// folder of PNGs in order (`journey-recharge-1-statement`, `-2-fetch`, ...). Each step reuses the screen an earlier
/// step already renders (the same `make`), so a journey can't drift from the screen it shows.
///  - Recharge (iPad, Patricia's month): the BBVA statement imported, the bills fetched in the built-in browser,
///    Check & link, the statement in Bills & recharges, Prepare email, the tenant's payment matched.
///  - Quick check (iPhone, Pablo): Home, Month, a category's transactions, one transaction, categorise in place.
///  - Evidence (iPad): Documents ▸ Missing, the site opened, a suggested document attached, the item linked.
public enum JourneyRoutes {
    static var all: [DemoRoute] { recharge + quickCheck + evidence }

    private static func reuse(_ source: String, as name: String, minimumFigures: Int? = nil) -> DemoRoute {
        guard let route = (DemoRoutes.base + PadRoutes.all).first(where: { $0.name == source }) else {
            return DemoRoute(name: name, minimumFigures: 0, pad: true) { _ in AnyView(Text("Journey step: no route named \(source)")) }
        }
        return DemoRoute(name: name, sizes: route.sizes, minimumFigures: minimumFigures ?? route.minimumFigures,
                         figuresBelowFold: route.figuresBelowFold, pad: route.pad, make: route.make)
    }

    static var recharge: [DemoRoute] {
        [
            reuse("pad-import-statement", as: "journey-recharge-1-statement"),
            reuse("pad-browser", as: "journey-recharge-2-fetch"),
            reuse("pad-check-utility", as: "journey-recharge-3-check"),
            reuse("pad-bills-panel", as: "journey-recharge-4-bills"),
            reuse("pad-prepare-email", as: "journey-recharge-5-email"),
            // The tenant's payment matched: the latest bill that reached "paid by tenant" open in the panel.
            DemoRoute(name: "journey-recharge-6-matched", sizes: DemoRoute.padSizes, minimumFigures: 8, pad: true) { context in
                let tabs = PadRoutes.billsTabs(context, selecting: { $0.stage == .paidByTenant })
                return AnyView(PadRootView(tabs: tabs, syncStatus: context.syncStatus, initialSelection: .billsAndRecharges,
                                           columns: .doubleColumn))
            },
        ]
    }

    static var quickCheck: [DemoRoute] {
        [
            reuse("home", as: "journey-quick-1-home"),
            reuse("month", as: "journey-quick-2-month"),
            reuse("month-transactions", as: "journey-quick-3-category"),
            DemoRoute(name: "journey-quick-4-transaction", minimumFigures: 2) { context in QuickEditRoutes.readSheet(context) },
            reuse("quick-edit-sheet", as: "journey-quick-5-categorise"),
        ]
    }

    static var evidence: [DemoRoute] {
        [
            reuse("pad-evidence", as: "journey-evidence-1-missing"),
            reuse("pad-browser", as: "journey-evidence-2-site"),
            reuse("pad-evidence-panel", as: "journey-evidence-3-attach"),
            // Linked: the library with the document the item took open, its "Linked to" line the item that is now resolved.
            reuse("pad-document-panel", as: "journey-evidence-4-linked"),
        ]
    }
}
