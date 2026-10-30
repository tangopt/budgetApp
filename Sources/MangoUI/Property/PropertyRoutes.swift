import SwiftUI
import BudgetCore
import GRDB

/// Property's snapshot routes (plan step 4, Task 10): `property` (the demo's flat on its day, shown directly),
/// `property-no_mortgage` (the same flat with its mortgage account unlinked, in an in-memory copy of the demo) and
/// `property-empty` (an empty database: "No property set up").
public enum PropertyRoutes {
    /// The demo's flat measures 15 figures in every render (rent, the recharge, the next instalment, owed in euros
    /// and pounds, the share repaid, the rate, the review's day and 7 obligations), 8 below the first screen at default
    /// size; without its mortgage 9 (rent, recharge, 7 obligations), 3 below it.
    static let all: [DemoRoute] = [
        DemoRoute(name: "property", minimumFigures: 15, figuresBelowFold: 7,
                  check: { context in try figuresCheck(context.dbQueue, today: context.today, route: "property") }) { context in
            property(context.dbQueue, today: context.today, status: context.syncStatus)
        },
        DemoRoute(name: "property-no_mortgage", minimumFigures: 9, figuresBelowFold: 3,
                  check: { context in
                      try figuresCheck(try withoutMortgage(context.dbQueue), today: context.today, route: "property-no_mortgage",
                                       expectMortgage: false)
                  }) { context in
            do {
                return property(try withoutMortgage(context.dbQueue), today: context.today, status: context.syncStatus)
            } catch {
                return AnyView(Text("Couldn't copy the demo: \(error.localizedDescription)"))
            }
        },
        DemoRoute(name: "property-empty", minimumFigures: 0) { context in
            let empty: DatabaseQueue
            do {
                let manager = try DatabaseManager(path: nil)
                try manager.migrate()
                empty = manager.dbQueue
            } catch {
                return AnyView(Text("Couldn't build an empty database: \(error.localizedDescription)"))
            }
            return property(empty, today: context.today, status: .idle(lastSync: nil))
        },
    ]

    @MainActor
    private static func property(_ dbQueue: DatabaseQueue, today: Date, status: SyncStatus) -> AnyView {
        let model = PropertyViewModel(dbQueue: dbQueue, today: { today }, preloaded: PropertyViewModel.readNow(dbQueue, today: today))
        return AnyView(PropertyView(model: model, syncStatus: status))
    }

    /// An in-memory copy of the demo with every mortgage account unlinked from its property (the demo itself is
    /// opened read-only and never changes).
    static func withoutMortgage(_ demo: DatabaseQueue) throws -> DatabaseQueue {
        let copy = try DatabaseQueue()
        try demo.backup(to: copy)
        try copy.write { db in
            for property in try Properties.all(db: db) {
                guard let id = property.id else { continue }
                for link in try Properties.accounts(db: db, propertyId: id, role: .mortgage) {
                    _ = try Properties.removeAccount(db: db, propertyId: id, accountId: link.accountId)
                }
            }
        }
        return copy
    }

    /// Every figure shown equals the Mac's (`PropertyViewModel.figuresCheck`); throws when one doesn't, or when the
    /// route's mortgage card isn't what it should be.
    @MainActor
    private static func figuresCheck(_ dbQueue: DatabaseQueue, today: Date, route: String, expectMortgage: Bool = true) throws -> String {
        guard let page = PropertyViewModel.readNow(dbQueue, today: today).page, let glance = page.single else {
            throw DemoRouteCheckFailure(message: "\(route): the demo's one property didn't load")
        }
        guard (glance.mortgage != nil) == expectMortgage else {
            throw DemoRouteCheckFailure(message: "\(route): expected \(expectMortgage ? "a" : "no") mortgage")
        }
        let check = try PropertyViewModel.figuresCheck(dbQueue: dbQueue, today: today, shown: page)
        guard check.matches else { throw DemoRouteCheckFailure(message: "\(route): \(check.line)") }
        return "\(route): \(check.line)"
    }
}
