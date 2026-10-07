// Sources/FillSpreadsheetPlanGaps/main.swift
//
// One-time gap fill: the spreadsheet's 2026 plan (Mar–Dec) for months the app's plan leaves
// empty. Idempotent. Usage: FillSpreadsheetPlanGaps <path-to-budget.sqlite> [--dry-run]

import Foundation
import BudgetCore
import GRDB

let arguments = Array(CommandLine.arguments.dropFirst())
let dryRun = arguments.contains("--dry-run")
guard let path = arguments.first(where: { !$0.hasPrefix("--") }) else {
    print("Usage: FillSpreadsheetPlanGaps <path-to-budget.sqlite> [--dry-run]")
    exit(2)
}
print("Database: \(path)\(dryRun ? " (dry run)" : "")")

let manager = try DatabaseManager(path: path)
try manager.migrate()

var lines: [String] = []
var mismatches: [String] = []
do {
    try manager.dbQueue.inTransaction { db in
        let plan = try SpreadsheetPlanGapFill.plan(db: db)
        mismatches = plan.mismatches
        lines = try SpreadsheetPlanGapFill.apply(db: db, plan: plan)
        return dryRun ? .rollback : .commit
    }
} catch let error as SpreadsheetPlanGapFillError {
    print("Aborted, nothing written: \(error)")
    exit(1)
}
print("Gaps filled:")
print(lines.isEmpty ? "  none" : lines.map { "  " + $0 }.joined(separator: "\n"))
print("Mismatches (report only):")
print(mismatches.isEmpty ? "  none" : mismatches.map { "  " + $0 }.joined(separator: "\n"))
if dryRun { print("Dry run — nothing written.") }
