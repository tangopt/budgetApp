// Sources/ImportBBVAHistory/main.swift
//
// One-off import of the BBVA Portugal current account's history (statements 2023-01 to
// 2026-09), already parsed and classified outside the app into a CSV plus a monthly summary
// (statement opening/closing balances). Creates the "BBVA" account (alias "BBVA PT", EUR) with
// its opening balance, the "Lisbon" category group and categories, commits every row through
// the import commit, learns conservative rules and verifies every month-end balance against
// the statements (BBVAHistoryImport) — all in ONE transaction. Refuses to run twice. Also
// creates the "Tenant deposit held" liability: the deposit returned is a transfer to it.
//
// Usage: swift run --package-path Tools ImportBBVAHistory <db-path> --csv <classified.csv> [--summary <monthly_summary.csv>]
//          [--deposit-opening <amount> --deposit-date <yyyy-mm-dd>] [--split-deposit <dd/MM/yyyy>:<amount>]… [--dry-run]
//   --summary          defaults to monthly_summary.csv next to the classified CSV.
//   --deposit-opening  the deposit liability's balance at the end of --deposit-date, signed
//                      (negative = owed, e.g. -3400.00); without it the liability starts at zero.
//   --split-deposit    the rent_received credit booked that day is split: <amount> of it is the
//                      deposit received (a transfer from the liability), the rest rent. Repeatable.
//   --dry-run  imports and verifies inside the transaction, prints the report, rolls back.

import Foundation
import BudgetCore
import GRDB

func usage() -> Never {
    FileHandle.standardError.write("""
        Usage: swift run --package-path Tools ImportBBVAHistory <db-path> --csv <classified.csv> [--summary <monthly_summary.csv>]
                 [--deposit-opening <amount> --deposit-date <yyyy-mm-dd>] [--split-deposit <dd/MM/yyyy>:<amount>]… [--dry-run]

        """.data(using: .utf8)!)
    exit(2)
}

var dryRun = false
var csvPath: String?
var summaryPath: String?
var depositOpening: Int?
var depositDate: Date?
var splits: [BBVAHistoryImport.DepositSplit] = []
var paths: [String] = []
var remaining = Array(CommandLine.arguments.dropFirst())[...]
while let argument = remaining.popFirst() {
    switch argument {
    case "--dry-run": dryRun = true
    case "--csv":
        guard let path = remaining.popFirst() else { usage() }
        csvPath = path
    case "--summary":
        guard let path = remaining.popFirst() else { usage() }
        summaryPath = path
    case "--deposit-opening":
        guard let text = remaining.popFirst(), let amount = BBVAHistoryImport.minorUnits(text) else { usage() }
        depositOpening = amount
    case "--deposit-date":
        let parts = remaining.popFirst()?.split(separator: "-").compactMap { Int($0) } ?? []
        guard parts.count == 3, let date = MonthRange.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { usage() }
        depositDate = date
    case "--split-deposit":
        let parts = remaining.popFirst()?.split(separator: ":").map(String.init) ?? []
        guard parts.count == 2, let date = BBVAHistoryImport.parseDay(parts[0]), let amount = BBVAHistoryImport.minorUnits(parts[1]) else { usage() }
        splits.append(BBVAHistoryImport.DepositSplit(date: date, depositMinorUnits: amount))
    default:
        if argument.hasPrefix("--") { usage() }
        paths.append(argument)
    }
}
guard paths.count == 1, let csvPath, (depositOpening == nil) == (depositDate == nil) else { usage() }
let dbPath = paths[0]
let summary = summaryPath ?? URL(fileURLWithPath: csvPath).deletingLastPathComponent().appendingPathComponent("monthly_summary.csv").path
for path in [dbPath, csvPath, summary] where !FileManager.default.fileExists(atPath: path) {
    FileHandle.standardError.write("No file at \(path)\n".data(using: .utf8)!)
    exit(2)
}

do {
    let input = BBVAHistoryImport.Input(
        rows: try BBVAHistoryImport.parseClassifiedCSV(String(contentsOfFile: csvPath, encoding: .utf8)),
        months: try BBVAHistoryImport.parseMonthlySummary(String(contentsOfFile: summary, encoding: .utf8)),
        depositOpening: depositOpening.flatMap { amount in depositDate.map { (amount, $0) } }, depositSplits: splits)
    let manager = try DatabaseManager(path: dbPath)
    try manager.migrate()
    print("Database: \(dbPath)\(dryRun ? " (dry run — everything will be rolled back)" : "")")
    print("Input: \(input.rows.count) rows, \(input.months.count) statement months (\(input.months.first!.label) … \(input.months.last!.label))")
    var report: BBVAHistoryImport.Report?
    try manager.dbQueue.inDatabase { db in
        try db.inTransaction {
            report = try BBVAHistoryImport.apply(db: db, input: input)
            return dryRun ? .rollback : .commit
        }
    }
    if let report { print(report.text) }
    print(dryRun ? "Dry run: rolled back." : "Committed.")
} catch let error as BBVAHistoryImport.ImportError {
    FileHandle.standardError.write("Refused (rolled back, nothing saved): \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
} catch {
    FileHandle.standardError.write("Failed (rolled back): \(error)\n".data(using: .utf8)!)
    exit(1)
}
