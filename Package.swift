// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BudgetCore",
    platforms: [.macOS("26.0")],
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
        // The synthetic demo database (UI snapshots, manual testing): never in the app.
        .target(name: "BudgetDemo", dependencies: ["BudgetCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "BudgetCoreTests", dependencies: ["BudgetCore", "BudgetDemo"]),
        .executableTarget(name: "MigrateHistory", dependencies: ["BudgetCore"]),
        .executableTarget(name: "MigrateAccountBalances", dependencies: ["BudgetCore"]),
        .executableTarget(name: "ConvertBalances", dependencies: ["BudgetCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "SeedCategoryGroups", dependencies: ["BudgetCore"]),
        .executableTarget(name: "SeedForecastPlan", dependencies: ["BudgetCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "FillSpreadsheetPlanGaps", dependencies: ["BudgetCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "CorrectSpreadsheetBalances", dependencies: ["BudgetCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "RedateSpreadsheetBalances", dependencies: ["BudgetCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "ImportBBVAHistory", dependencies: ["BudgetCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "ImportBBVAFundAndMortgage", dependencies: ["BudgetCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "ImportExistingEvidence", dependencies: ["BudgetCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "SetUpLisbonProperty", dependencies: ["BudgetCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "TaxRegression", dependencies: ["BudgetCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "SelfAssessmentRegression", dependencies: ["BudgetCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "BackfillRecharges", dependencies: ["BudgetCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "ApplyTaxData", dependencies: ["BudgetCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "RebuildRechargesFromTracker", dependencies: ["BudgetCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "LinkRentReceiptPDFs", dependencies: ["BudgetCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "MortgageRateValidation", dependencies: ["BudgetCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "ImportBBVAEarlierStatements", dependencies: ["BudgetCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "MakeDemoDatabase", dependencies: ["BudgetCore", "BudgetDemo"])
    ]
)
