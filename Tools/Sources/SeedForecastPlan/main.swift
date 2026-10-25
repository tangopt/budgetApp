// Sources/SeedForecastPlan/main.swift
//
// One-time seed (spec: docs/superpowers/specs/2026-10-05-reserved-forecast-categories-design.md):
// the spreadsheet's £2,000/month "Remaining for expenses" reserve, its planned items and
// corrected amounts. Idempotent. Usage: SeedForecastPlan <path-to-budget.sqlite> [--dry-run]

import Foundation
import BudgetCore
import GRDB

let arguments = Array(CommandLine.arguments.dropFirst())
let dryRun = arguments.contains("--dry-run")
guard let path = arguments.first(where: { !$0.hasPrefix("--") }) else {
    print("Usage: SeedForecastPlan <path-to-budget.sqlite> [--dry-run]")
    exit(2)
}
print("Database: \(path)\(dryRun ? " (dry run)" : "")")

let manager = try DatabaseManager(path: path)
try manager.migrate()

var lines: [String] = []
do {
    try manager.dbQueue.inTransaction { db in
        lines = try ForecastPlanSeeder.apply(db: db)
        return dryRun ? .rollback : .commit
    }
} catch let error as ForecastPlanSeederError {
    print("Aborted, nothing written: \(error)")
    exit(1)
}
print(lines.isEmpty ? "No changes." : lines.map { "  " + $0 }.joined(separator: "\n"))
if dryRun { print("Dry run — nothing written.") }
