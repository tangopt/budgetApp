// Sources/ConvertBalances/main.swift
//
// One-off conversion (spec 2026-10-14 §3): per account, the earliest recorded balance stays
// as the opening balance; every later one becomes an adjustment transaction (Balance
// adjustment / Market movement) for the difference from the computed balance, then moves to
// the balanceSnapshotArchive table. Verified in the same transaction (BalanceConversion):
// any invariant violation aborts with a rollback.
//
// Usage: swift run ConvertBalances <db-path> [--dry-run]
//   --dry-run  converts and verifies inside a transaction, prints the report, rolls back.

import Foundation
import BudgetCore
import GRDB

let arguments = Array(CommandLine.arguments.dropFirst())
let dryRun = arguments.contains("--dry-run")
let paths = arguments.filter { $0 != "--dry-run" }
guard paths.count == 1, arguments.count == paths.count + (dryRun ? 1 : 0) else {
    FileHandle.standardError.write("Usage: ConvertBalances <db-path> [--dry-run]\n".data(using: .utf8)!)
    exit(2)
}
let dbPath = paths[0]
guard FileManager.default.fileExists(atPath: dbPath) else {
    FileHandle.standardError.write("No database at \(dbPath)\n".data(using: .utf8)!)
    exit(2)
}

do {
    let manager = try DatabaseManager(path: dbPath)
    try manager.migrate()
    print("Database: \(dbPath)\(dryRun ? " (dry run — nothing will be saved)" : "")")
    var report: BalanceConversion.Report?
    try manager.dbQueue.inDatabase { db in
        try db.inTransaction {
            report = try BalanceConversion.convert(db: db)
            return dryRun ? .rollback : .commit
        }
    }
    if let report {
        print(report.text)
        if report.isNoOp {
            print("Nothing to convert.")
        } else {
            print(dryRun ? "Dry run: rolled back." : "Committed.")
        }
    }
} catch BalanceConversionError.invariantViolated(let report) {
    print(report.text)
    print("Aborted: rolled back, nothing saved.")
    exit(1)
} catch {
    FileHandle.standardError.write("Failed (rolled back): \(error)\n".data(using: .utf8)!)
    exit(1)
}
