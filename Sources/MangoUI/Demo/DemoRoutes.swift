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
    public let make: @MainActor (PhoneDemoContext) -> AnyView

    /// Default (`.large`), the largest size short of the accessibility sizes (`.xxxLarge`), where figures must still
    /// sit beside their labels, and `.accessibility3`, where rows stack (iPhone spec §4; fix round 1).
    public static let standardSizes: [DynamicTypeSize] = [.large, .xxxLarge, .accessibility3]

    public init(name: String, sizes: [DynamicTypeSize] = DemoRoute.standardSizes, minimumFigures: Int = 1,
                figuresBelowFold: Int = 0, make: @escaping @MainActor (PhoneDemoContext) -> AnyView) {
        self.name = name
        self.sizes = sizes
        self.minimumFigures = minimumFigures
        self.figuresBelowFold = figuresBelowFold
        self.make = make
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

/// The routes the harness renders, in order. Each later screen adds its routes here.
public enum DemoRoutes {
    public static let all: [DemoRoute] = [
        DemoRoute(name: "gallery", sizes: DemoRoute.standardSizes + [.accessibility5], minimumFigures: 10) { _ in
            AnyView(DesignSystemGallery())
        },
        // A long figure below the first screen: the full-height render must measure it.
        DemoRoute(name: "gallery-fold", figuresBelowFold: 1) { _ in AnyView(DesignSystemGalleryFold()) },
    ]
}
