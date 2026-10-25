// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BudgetCore",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "BudgetCore", targets: ["BudgetCore"]),
        .library(name: "MangoSync", targets: ["MangoSync"]),
        .library(name: "MangoUI", targets: ["MangoUI"]),
        // Linked by the iPhone app only for its snapshot harness (`SNAPSHOTS`); see Phone/Snapshots/PhoneSnapshotRunner.swift.
        .library(name: "BudgetDemo", targets: ["BudgetDemo"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .target(name: "BudgetCore", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift")
        ]),
        // The synthetic demo database (UI snapshots, manual testing): never in the app.
        .target(name: "BudgetDemo", dependencies: ["BudgetCore", .product(name: "GRDB", package: "GRDB.swift")]),
        // CloudKit and Security pieces both apps share and BudgetCore may not import (step 4, Task 3).
        .target(name: "MangoSync", dependencies: ["BudgetCore"]),
        // The iPhone's views, design-system pieces and view models (SwiftUI), shared with the iPad later (step 4, Task 4).
        .target(name: "MangoUI", dependencies: ["BudgetCore", .product(name: "GRDB", package: "GRDB.swift")]),
        // Tests' shared databases: copies of one migrated and one demo database per process (`TestDatabase`).
        .target(name: "TestSupport", dependencies: ["BudgetCore", "BudgetDemo", .product(name: "GRDB", package: "GRDB.swift")],
                path: "Tests/TestSupport"),
        .testTarget(name: "BudgetCoreTests", dependencies: ["BudgetCore", "BudgetDemo", "TestSupport"]),
        .testTarget(name: "MangoSyncTests", dependencies: ["MangoSync", "BudgetCore"]),
        .testTarget(name: "MangoUITests", dependencies: ["MangoUI", "BudgetCore", "BudgetDemo", "TestSupport"]),
        // Builds the synthetic demo database; scripts/render-snapshots.sh builds and runs it.
        // The one-off maintenance tools live in their own package: Tools/Package.swift (`swift run --package-path Tools <Tool>`).
        .executableTarget(name: "MakeDemoDatabase", dependencies: ["BudgetCore", "BudgetDemo"])
    ]
)
