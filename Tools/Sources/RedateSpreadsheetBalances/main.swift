// Sources/RedateSpreadsheetBalances/main.swift
//
// One-off follow-up to CorrectSpreadsheetBalances (2026-10-15): moves the corrected spreadsheet
// balances (column M = the balance at the end of M) and the adjustments made from them from
// 00:00 on the 1st of M+1 to the last day of M, so month ends show them, and gives the
// spreadsheet accounts a 31 Dec 2019 opening (SpreadsheetBalanceRedate), all in ONE transaction
// with its verification. Refuses to run twice.
//
// The 2019 openings are the spreadsheet's column D "Value" (confirm with
//   python3 -I scripts/spreadsheet-balance-values.py "<copy of>/Budget copy.numbers" > values.json
// and its "column2019"); Lloyds Classic's is derived from its January 2020 column.
//
// Usage: swift run RedateSpreadsheetBalances <db-path> [--dry-run]
//   --dry-run  re-dates and verifies inside the transaction, prints the report, rolls back.

import Foundation
import BudgetCore
import GRDB

func usage() -> Never {
    FileHandle.standardError.write("Usage: RedateSpreadsheetBalances <db-path> [--dry-run]\n".data(using: .utf8)!)
    exit(2)
}

var dryRun = false
var paths: [String] = []
for argument in CommandLine.arguments.dropFirst() {
    switch argument {
    case "--dry-run": dryRun = true
    default:
        if argument.hasPrefix("--") { usage() }
        paths.append(argument)
    }
}
guard paths.count == 1 else { usage() }
let dbPath = paths[0]
guard FileManager.default.fileExists(atPath: dbPath) else {
    FileHandle.standardError.write("No database at \(dbPath)\n".data(using: .utf8)!)
    exit(2)
}

do {
    let manager = try DatabaseManager(path: dbPath)
    try manager.migrate()
    print("Database: \(dbPath)\(dryRun ? " (dry run — everything will be rolled back)" : "")")
    var report: SpreadsheetBalanceRedate.Report?
    try manager.dbQueue.inDatabase { db in
        try db.inTransaction {
            report = try SpreadsheetBalanceRedate.apply(db: db)
            return dryRun ? .rollback : .commit
        }
    }
    if let report { print(report.text) }
    print(dryRun ? "Dry run: rolled back." : "Committed.")
} catch let error as SpreadsheetBalanceRedate.RedateError {
    FileHandle.standardError.write("Refused (rolled back, nothing saved): \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
} catch {
    FileHandle.standardError.write("Failed (rolled back): \(error)\n".data(using: .utf8)!)
    exit(1)
}
