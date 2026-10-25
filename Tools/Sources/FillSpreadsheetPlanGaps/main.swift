// Sources/FillSpreadsheetPlanGaps/main.swift
//
// One-time gap fill: the spreadsheet's 2026 plan (Mar–Dec) for months the app's plan leaves
// empty. Idempotent.
// Usage: FillSpreadsheetPlanGaps <path-to-budget.sqlite> [--names <names.json>] [--dry-run]
//   --names  a JSON object mapping the sheet's default category names ("Mobile 1") to the
//            database's own, when they differ (a personal data file kept outside the repository).

import Foundation
import BudgetCore
import GRDB

var arguments = Array(CommandLine.arguments.dropFirst())
let dryRun = arguments.contains("--dry-run")
var categoryNames: [String: String] = [:]
if let index = arguments.firstIndex(of: "--names") {
    guard index + 1 < arguments.count,
          let names = try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]))) else {
        print("--names needs a JSON object file: {\"Mobile 1\": \"<your category>\", …}")
        exit(2)
    }
    categoryNames = names
    arguments.removeSubrange(index...(index + 1))
}
guard let path = arguments.first(where: { !$0.hasPrefix("--") }) else {
    print("Usage: swift run --package-path Tools FillSpreadsheetPlanGaps <path-to-budget.sqlite> [--names <names.json>] [--dry-run]")
    exit(2)
}
print("Database: \(path)\(dryRun ? " (dry run)" : "")")

let manager = try DatabaseManager(path: path)
try manager.migrate()

var lines: [String] = []
var mismatches: [String] = []
do {
    try manager.dbQueue.inTransaction { db in
        let plan = try SpreadsheetPlanGapFill.plan(db: db, categoryNames: categoryNames)
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
