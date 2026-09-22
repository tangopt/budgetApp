// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BudgetCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BudgetCore", targets: ["BudgetCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .target(name: "BudgetCore", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift")
        ]),
        .testTarget(name: "BudgetCoreTests", dependencies: ["BudgetCore"])
    ]
)
