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
/// Dynamic Type sizes to render it at, and how to build it from the demo.
public struct DemoRoute {
    public let name: String
    public let sizes: [DynamicTypeSize]
    public let make: @MainActor (PhoneDemoContext) -> AnyView

    /// Default (`.large`) and the largest size short of the accessibility sizes (`.xxxLarge`), where figures must
    /// still fit on one line (iPhone spec §4).
    public static let standardSizes: [DynamicTypeSize] = [.large, .xxxLarge]

    public init(name: String, sizes: [DynamicTypeSize] = DemoRoute.standardSizes,
                make: @escaping @MainActor (PhoneDemoContext) -> AnyView) {
        self.name = name
        self.sizes = sizes
        self.make = make
    }
}

/// The routes the harness renders, in order. Each later screen adds its routes here.
public enum DemoRoutes {
    public static let all: [DemoRoute] = [
        DemoRoute(name: "gallery") { _ in AnyView(DesignSystemGallery()) },
    ]
}
