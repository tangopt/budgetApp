// Sources/CorrectSpreadsheetBalances/main.swift
//
// One-off correction of the spreadsheet balances (spec 2026-10-15,
// docs/superpowers/specs/2026-10-15-spreadsheet-balance-correction-design.md): undoes the
// converted adjustments, restores the archived recorded balances with the spreadsheet ones
// replaced by corrected values, deletes the partial month's duplicate rows and converts again
// (SpreadsheetBalanceCorrection), all in ONE transaction with BalanceConversion's verification.
// Refuses to run on an already-corrected database.
//
// The corrected values come from the spreadsheet:
//   python3 -I scripts/spreadsheet-balance-values.py "<copy of>/Budget copy.numbers" > values.json
//
// Usage: swift run --package-path Tools CorrectSpreadsheetBalances <db-path> --values <values.json> [--dry-run]
//   --dry-run  corrects and verifies inside the transaction, prints the report, rolls back.

import Foundation
import BudgetCore
import GRDB

func usage() -> Never {
    FileHandle.standardError.write("Usage: swift run --package-path Tools CorrectSpreadsheetBalances <db-path> --values <values.json> [--dry-run]\n".data(using: .utf8)!)
    exit(2)
}

var dryRun = false
var valuesPath: String?
var paths: [String] = []
var remaining = Array(CommandLine.arguments.dropFirst())[...]
while let argument = remaining.popFirst() {
    switch argument {
    case "--dry-run": dryRun = true
    case "--values":
        guard let path = remaining.popFirst() else { usage() }
        valuesPath = path
    default:
        if argument.hasPrefix("--") { usage() }
        paths.append(argument)
    }
}
guard paths.count == 1, let valuesPath else { usage() }
let dbPath = paths[0]
guard FileManager.default.fileExists(atPath: dbPath) else {
    FileHandle.standardError.write("No database at \(dbPath)\n".data(using: .utf8)!)
    exit(2)
}

do {
    let input = try JSONDecoder().decode(SpreadsheetBalanceCorrection.Input.self, from: Data(contentsOf: URL(fileURLWithPath: valuesPath)))
    let manager = try DatabaseManager(path: dbPath)
    try manager.migrate()
    print("Database: \(dbPath)\(dryRun ? " (dry run — everything will be rolled back)" : "")")
    print("Values: \(valuesPath) (\(input.snapshots.count) corrected balances, \(input.deleteTransactions.count) transactions to delete)")
    var report: SpreadsheetBalanceCorrection.Report?
    try manager.dbQueue.inDatabase { db in
        try db.inTransaction {
            report = try SpreadsheetBalanceCorrection.apply(db: db, input: input)
            return dryRun ? .rollback : .commit
        }
    }
    if let report { print(report.text) }
    print(dryRun ? "Dry run: rolled back." : "Committed.")
} catch BalanceConversionError.invariantViolated(let report) {
    print(report.text)
    print("Aborted: rolled back, nothing saved.")
    exit(1)
} catch let error as SpreadsheetBalanceCorrection.CorrectionError {
    FileHandle.standardError.write("Refused (rolled back, nothing saved): \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
} catch {
    FileHandle.standardError.write("Failed (rolled back): \(error)\n".data(using: .utf8)!)
    exit(1)
}
