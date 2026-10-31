import SwiftUI
import BudgetCore
import GRDB

/// What a demo route renders from: the demo database (opened read-only by the snapshot harness), the day the demo
/// takes as today, and the sync status to show.
public struct PhoneDemoContext {
    public let dbQueue: DatabaseQueue
    public let today: Date
    public let syncStatus: SyncStatus

    public init(dbQueue: DatabaseQueue, today: Date, syncStatus: SyncStatus) {
        self.dbQueue = dbQueue
        self.today = today
        self.syncStatus = syncStatus
    }
}

/// One screen or state the phone's snapshot harness renders (iPhone spec §6): its name (the PNGs' prefix), the
/// Dynamic Type sizes to render it at, and how to build it from the demo; and how much the probe must see in it,
/// so a render whose measuring broke can't pass as "0 violations".
public struct DemoRoute {
    public let name: String
    public let sizes: [DynamicTypeSize]
    /// Figures every render must measure (default 1).
    public let minimumFigures: Int
    /// Figures the full-height render must measure below the first screen (852 pt).
    public let figuresBelowFold: Int
    /// What the route asserts about its figures (Home: its net worth is the Accounts screen's), run once before the
    /// renders: the line it returns goes in the report; a throw fails the run.
    public let check: (@MainActor (PhoneDemoContext) throws -> String)?
    public let make: @MainActor (PhoneDemoContext) -> AnyView
    /// An iPad route: rendered only by the iPad harness (`--device ipad`), at the iPad window sizes; the iPhone run
    /// skips it, and every other route is the iPhone's.
    public let pad: Bool

    /// Default (`.large`), the largest size short of the accessibility sizes (`.xxxLarge`), where figures must still
    /// sit beside their labels, and `.accessibility3`, where rows stack (iPhone spec §4; fix round 1).
    public static let standardSizes: [DynamicTypeSize] = [.large, .xxxLarge, .accessibility3]

    /// An iPad route's sizes: default and `.xxxLarge` (the sidebar and detail still hold their figures there).
    public static let padSizes: [DynamicTypeSize] = [.large, .xxxLarge]

    public init(name: String, sizes: [DynamicTypeSize] = DemoRoute.standardSizes, minimumFigures: Int = 1,
                figuresBelowFold: Int = 0, pad: Bool = false, check: (@MainActor (PhoneDemoContext) throws -> String)? = nil,
                make: @escaping @MainActor (PhoneDemoContext) -> AnyView) {
        self.name = name
        self.sizes = sizes
        self.minimumFigures = minimumFigures
        self.figuresBelowFold = figuresBelowFold
        self.check = check
        self.make = make
        self.pad = pad
    }

    /// Why a render doesn't count (it measured too little), or nil. `full`: the full-height render.
    public func coverageProblem(render: WrapProbeRegistry.Render, full: Bool) -> String? {
        if render.checked < minimumFigures {
            return "\(render.name): \(render.checked) figures checked (needs at least \(minimumFigures))"
        }
        if full, render.belowFold < figuresBelowFold {
            return "\(render.name): \(render.belowFold) figures below the fold (needs at least \(figuresBelowFold))"
        }
        return nil
    }
}

/// A route's check that didn't hold.
public struct DemoRouteCheckFailure: Error, CustomStringConvertible {
    public let message: String
    public init(message: String) { self.message = message }
    public var description: String { message }
}

/// The routes the harness renders, in order. Each later screen adds its routes here.
public enum DemoRoutes {
    public static var all: [DemoRoute] { base + JourneyRoutes.all }

    /// Every route but the journeys (which reuse these).
    static let base: [DemoRoute] = [
        DemoRoute(name: "gallery", sizes: DemoRoute.standardSizes + [.accessibility5], minimumFigures: 10) { _ in
            AnyView(DesignSystemGallery())
        },
        // A long figure below the first screen: the full-height render must measure it.
        DemoRoute(name: "gallery-fold", figuresBelowFold: 1) { _ in AnyView(DesignSystemGalleryFold()) },
    ] + HomeRoutes.all + MonthRoutes.all + AccountsRoutes.all + PropertyRoutes.all
        + SearchRoutes.all + QuickEditRoutes.all + SyncRoutes.all + SharingRoutes.all + OutputsSettingsRoutes.all + JoinRoutes.all + PadRoutes.all + SalaryRoutes.all + ImportRoutes.all
}

/// Step 7b's Settings ▸ Notifications in its own list (the section sits low in Settings; `settings-widgets` shows the
/// whole sheet with it).
public enum OutputsSettingsRoutes {
    static let all: [DemoRoute] = [
        // The admin before being asked: the "Allow notifications" row and all four reminders.
        DemoRoute(name: "settings-notifications", minimumFigures: 0) { _ in
            AnyView(NavigationStack {
                List { NotificationsSection(settings: .constant(PhoneOutputSettings()), authorization: .notDetermined, isAdmin: true, onAllow: {}) }
            })
        },
        // A member whose system setting is off: three reminders and the note.
        DemoRoute(name: "settings-notifications-denied", minimumFigures: 0) { _ in
            AnyView(NavigationStack {
                List {
                    NotificationsSection(settings: .constant(PhoneOutputSettings(notifications: [.billDue])), authorization: .denied,
                                         isAdmin: false, onAllow: {})
                }
            })
        },
    ]
}

/// Step 6's routes (Task 11): Settings' read-only Sharing section as the demo's admin (A); Accounts with A's lock
/// badges; and a Month row's list ending with a private account's line, as an iPhone reads it before the household
/// has named its iCloud user (only Everything and joint accounts in full: A's Category totals card is a line).
public enum SharingRoutes {
    static let all: [DemoRoute] = [
        DemoRoute(name: "settings-sharing", minimumFigures: 0) { context in
            let today = context.today
            let sharing = (try? context.dbQueue.read { db in try SharingSectionState.read(db, viewer: .demoAdmin) }) ?? .notNamed
            return AnyView(SettingsSheet(appearance: .constant(.system), themeSetId: .constant(ThemeSet.defaultID),
                                         iCloud: .available, keyHeld: true,
                                         status: .idle(lastSync: today.addingTimeInterval(-300)),
                                         version: SettingsCopy.version(marketing: "0.2.0", build: "1"), now: { today },
                                         onLockNow: {}, onSyncNow: {}, sharing: sharing,
                                         salary: SalaryRoutes.demoModel(today: today), personName: "A", title: "Me"))
        },
        // The `accounts` route's 17 figures, with A's badges.
        DemoRoute(name: "accounts-sharing_badges", minimumFigures: 17, figuresBelowFold: 6) { context in
            let today = context.today
            let model = AccountsViewModel(dbQueue: context.dbQueue, today: { today }, viewer: .demoAdmin,
                                          preloaded: AccountsViewModel.readNow(context.dbQueue, today: today, viewer: .demoAdmin))
            return AnyView(AccountsView(model: model, syncStatus: context.syncStatus))
        },
        // In the demo the card is the only account in its spending rows, so the list is the line's one figure.
        DemoRoute(name: "month-private_lines", minimumFigures: 1) { context in
            privateLines(context)
        },
    ]

    /// The current month's spending row with a private line and the most transactions, and its list, for a viewer
    /// not yet named.
    @MainActor
    private static func privateLines(_ context: PhoneDemoContext) -> AnyView {
        let viewer = PhoneViewer.iCloudUser(recordName: nil)
        guard case let .loaded(page) = MonthViewModel.readNow(context.dbQueue, today: context.today, viewer: viewer) else {
            return AnyView(Text("The demo's month didn't load"))
        }
        let lists = page.rows(.spending).map { row in
            (row: row, state: MonthTransactionsModel.readNow(context.dbQueue, row: row, range: page.review.range, viewer: viewer, today: context.today),
             lines: MonthTransactionsModel.privateLinesNow(context.dbQueue, row: row, range: page.review.range, viewer: viewer, today: context.today))
        }.filter { !$0.lines.isEmpty }
        func count(_ state: MonthTransactionsModel.State) -> Int {
            if case let .loaded(days) = state { days.reduce(0) { $0 + $1.rows.count } } else { 0 }
        }
        guard let chosen = lists.max(by: { count($0.state) < count($1.state) }) else {
            return AnyView(Text("The demo's month has no private line"))
        }
        let today = context.today
        let model = MonthTransactionsModel(dbQueue: context.dbQueue, row: chosen.row, range: page.review.range, viewer: viewer,
                                           today: { today }, preloaded: chosen.state, privateLines: chosen.lines)
        return AnyView(NavigationStack { MonthTransactionsView(model: model) })
    }
}
