// swift-tools-version:5.10
import PackageDescription

// One-off and maintenance tools (imports, data fixes, regressions, rehearsals), kept out of the root package so a
// plain `swift build` / `swift test` doesn't relink them on every BudgetCore change (step 5, Task 6).
// Run one with `swift run --package-path Tools <Tool> …` from the repository root.
// They use only BudgetCore's public API; each opens databases through `ToolDatabase`
// (guarded by ToolDatabaseTests in the root package, which scans Tools/Sources).
// MakeDemoDatabase stays in the root package: scripts/render-snapshots.sh builds it.
let core: Target.Dependency = .product(name: "BudgetCore", package: "BudgetCore")
let grdb: Target.Dependency = .product(name: "GRDB", package: "GRDB.swift")

let package = Package(
    name: "MangoTools",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(name: "BudgetCore", path: ".."),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .executableTarget(name: "MigrateHistory", dependencies: [core]),
        .executableTarget(name: "MigrateAccountBalances", dependencies: [core]),
        .executableTarget(name: "ConvertBalances", dependencies: [core, grdb]),
        .executableTarget(name: "SeedCategoryGroups", dependencies: [core]),
        .executableTarget(name: "SeedForecastPlan", dependencies: [core, grdb]),
        .executableTarget(name: "FillSpreadsheetPlanGaps", dependencies: [core, grdb]),
        .executableTarget(name: "CorrectSpreadsheetBalances", dependencies: [core, grdb]),
        .executableTarget(name: "RedateSpreadsheetBalances", dependencies: [core, grdb]),
        .executableTarget(name: "ImportBBVAHistory", dependencies: [core, grdb]),
        .executableTarget(name: "ImportBBVAFundAndMortgage", dependencies: [core, grdb]),
        .executableTarget(name: "ImportExistingEvidence", dependencies: [core, grdb]),
        .executableTarget(name: "SetUpLisbonProperty", dependencies: [core, grdb]),
        .executableTarget(name: "TaxRegression", dependencies: [core, grdb]),
        .executableTarget(name: "SelfAssessmentRegression", dependencies: [core, grdb]),
        .executableTarget(name: "BackfillRecharges", dependencies: [core, grdb]),
        .executableTarget(name: "ApplyTaxData", dependencies: [core, grdb]),
        .executableTarget(name: "RebuildRechargesFromTracker", dependencies: [core, grdb]),
        .executableTarget(name: "LinkRentReceiptPDFs", dependencies: [core, grdb]),
        .executableTarget(name: "LinkRentCredits", dependencies: [core, grdb]),
        .executableTarget(name: "MortgageRateValidation", dependencies: [core, grdb]),
        .executableTarget(name: "ImportBBVAEarlierStatements", dependencies: [core, grdb]),
        .executableTarget(name: "ImportDryRun", dependencies: [core]),
        .executableTarget(name: "ImportRehearsal", dependencies: [core]),
        .executableTarget(name: "SyncRehearsal", dependencies: [core]),
        .executableTarget(name: "CorrectSimarInvoiceTotals", dependencies: [core, grdb]),
        .executableTarget(name: "ReclassifyMortgageReceipts", dependencies: [core, grdb]),
        .executableTarget(name: "ReclassifyNewKinds", dependencies: [core, grdb]),
        .executableTarget(name: "ImportTaxArchive", dependencies: [core, grdb]),
        .executableTarget(name: "TaxYear2025Fixes", dependencies: [core, grdb])
    ]
)
