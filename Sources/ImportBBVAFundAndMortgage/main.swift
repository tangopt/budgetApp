// Sources/ImportBBVAFundAndMortgage/main.swift
//
// One-off import of the BBVA Portugal retirement fund and mortgage (BBVAFundMortgageImport), from
// the JSON the extraction writes outside the app (statement fund values and loan outstanding,
// the December 2022 consolidated statement's openings, the instalment notices' splits): creates
// "BBVA retirement fund" (investment) and "BBVA mortgage" (credit, not in net worth), files the
// BBVA subscription and instalment rows as transfers to them with linked legs, records the
// fund's values and the mortgage interest, renames "Mortgage" to "Mortgage interest" and moves
// its learned rule — all in ONE transaction, verified against the statements. Refuses to run twice.
//
// Usage: swift run ImportBBVAFundAndMortgage <db-path> --data <fund_mortgage.json> [--dry-run]
//   --dry-run  imports and verifies inside the transaction, prints the report, rolls back.

import Foundation
import BudgetCore
import GRDB

func usage() -> Never {
    FileHandle.standardError.write("Usage: ImportBBVAFundAndMortgage <db-path> --data <fund_mortgage.json> [--dry-run]\n".data(using: .utf8)!)
    exit(2)
}

var dryRun = false
var dataPath: String?
var paths: [String] = []
var remaining = Array(CommandLine.arguments.dropFirst())[...]
while let argument = remaining.popFirst() {
    switch argument {
    case "--dry-run": dryRun = true
    case "--data":
        guard let path = remaining.popFirst() else { usage() }
        dataPath = path
    default:
        if argument.hasPrefix("--") { usage() }
        paths.append(argument)
    }
}
guard paths.count == 1, let dataPath else { usage() }
let dbPath = paths[0]
for path in [dbPath, dataPath] where !FileManager.default.fileExists(atPath: path) {
    FileHandle.standardError.write("No file at \(path)\n".data(using: .utf8)!)
    exit(2)
}

do {
    let input = try BBVAFundMortgageImport.parseInput(json: try Data(contentsOf: URL(fileURLWithPath: dataPath)))
    let manager = try DatabaseManager(path: dbPath)
    try manager.migrate()
    print("Database: \(dbPath)\(dryRun ? " (dry run — everything will be rolled back)" : "")")
    print("Input: \(input.fundValues.count) fund values, \(input.fundSubscriptionCount) subscriptions, \(input.statements.count) loan statements, \(input.instalments.count) instalments")
    var report: BBVAFundMortgageImport.Report?
    try manager.dbQueue.inDatabase { db in
        try db.inTransaction {
            report = try BBVAFundMortgageImport.apply(db: db, input: input)
            return dryRun ? .rollback : .commit
        }
    }
    if let report { print(report.text) }
    print(dryRun ? "Dry run: rolled back." : "Committed.")
} catch let error as BBVAFundMortgageImport.ImportError {
    FileHandle.standardError.write("Refused (rolled back, nothing saved): \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
} catch {
    FileHandle.standardError.write("Failed (rolled back): \(error)\n".data(using: .utf8)!)
    exit(1)
}
