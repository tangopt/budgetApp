// Sources/ConvertBalances/main.swift
//
// One-off conversion (spec 2026-10-14 §3): per account, the earliest recorded balance stays
// as the opening balance; every later one becomes an adjustment transaction (Balance
// adjustment / Market movement) for the difference from the computed balance, then moves to
// the balanceSnapshotArchive table. Verified in the same transaction (BalanceConversion):
// any invariant violation aborts with a rollback.
//
// With --apply-transfer-categories, the same transaction then (spec 2026-10-14 §4) ties each
// --tie category to its account, gives every account a transfer category
// (TransferCategories.ensure) and files every linked transfer's legs under the other account's
// (TransferCategories.applyToExistingLinks), printing what moved.
//
// Usage: swift run ConvertBalances <db-path> [--dry-run] [--apply-transfer-categories [--tie "<category>=<account name or alias>"]...]
//   --dry-run  converts and verifies inside a transaction, prints the report, rolls back.

import Foundation
import BudgetCore
import GRDB
import struct BudgetCore.Category

func usage() -> Never {
    FileHandle.standardError.write("Usage: ConvertBalances <db-path> [--dry-run] [--apply-transfer-categories [--tie \"<category>=<account name or alias>\"]...]\n".data(using: .utf8)!)
    exit(2)
}

var dryRun = false
var applyTransferCategories = false
var ties: [(category: String, account: String)] = []
var paths: [String] = []
var remaining = Array(CommandLine.arguments.dropFirst())[...]
while let argument = remaining.popFirst() {
    switch argument {
    case "--dry-run": dryRun = true
    case "--apply-transfer-categories": applyTransferCategories = true
    case "--tie":
        guard let spec = remaining.popFirst(), let separator = spec.lastIndex(of: "=") else { usage() }
        ties.append((String(spec[..<separator]), String(spec[spec.index(after: separator)...])))
    default:
        if argument.hasPrefix("--") { usage() }
        paths.append(argument)
    }
}
guard paths.count == 1, ties.isEmpty || applyTransferCategories else { usage() }
let dbPath = paths[0]
guard FileManager.default.fileExists(atPath: dbPath) else {
    FileHandle.standardError.write("No database at \(dbPath)\n".data(using: .utf8)!)
    exit(2)
}

enum TieError: Error, CustomStringConvertible {
    case categoryNotFound(String), accountNotFound(String)
    var description: String {
        switch self {
        case .categoryNotFound(let name): return "No category named “\(name)”."
        case .accountNotFound(let name): return "No account named or aliased “\(name)”."
        }
    }
}

do {
    let manager = try DatabaseManager(path: dbPath)
    try manager.migrate()
    print("Database: \(dbPath)\(dryRun ? " (dry run — the conversion will be rolled back)" : "")")
    print("Migrations applied (outside the conversion's transaction; the app applies them anyway).")
    var report: BalanceConversion.Report?
    var transferLog: [String] = []
    var transferReport: TransferCategories.Report?
    try manager.dbQueue.inDatabase { db in
        try db.inTransaction {
            report = try BalanceConversion.convert(db: db)
            if applyTransferCategories {
                let accounts = try Account.fetchAll(db)
                for tie in ties {
                    guard let category = try Category.filter(Column("name") == tie.category).fetchOne(db), let categoryId = category.id else {
                        throw TieError.categoryNotFound(tie.category)
                    }
                    guard let account = accounts.first(where: { $0.name == tie.account || $0.alias == tie.account }), let accountId = account.id else {
                        throw TieError.accountNotFound(tie.account)
                    }
                    // The account's tie moves here; an unused category it leaves (say one the
                    // app created at launch) is deleted.
                    if let previous = try TransferCategories.category(db: db, forAccountId: accountId), let previousId = previous.id, previousId != categoryId {
                        try TransferCategories.setLinkedAccount(db: db, categoryId: previousId, accountId: nil)
                        do {
                            try Categories.delete(db: db, id: previousId)
                            transferLog.append("Deleted the unused “\(previous.name)” (was tied to \(account.name))")
                        } catch CategoryEditError.inUse {
                            transferLog.append("Untied “\(previous.name)” from \(account.name) (in use, kept)")
                        }
                    }
                    try TransferCategories.setLinkedAccount(db: db, categoryId: categoryId, accountId: accountId)
                    let tiedName = try Category.fetchOne(db, key: categoryId)?.name ?? tie.category
                    transferLog.append("Tied “\(tie.category)” to \(account.name)\(tiedName == tie.category ? "" : ", renamed “\(tiedName)”")")
                }
                transferLog += try TransferCategories.ensure(db: db)
                transferReport = try TransferCategories.applyToExistingLinks(db: db)
            }
            return dryRun ? .rollback : .commit
        }
    }
    if let report {
        print(report.text)
        if report.isNoOp { print("Nothing to convert.") }
    }
    if applyTransferCategories {
        print(transferLog.isEmpty ? "Transfer categories: every account already has one." : transferLog.joined(separator: "\n"))
        if let transferReport { print(transferReport.text) }
    }
    if report?.isNoOp == false || applyTransferCategories {
        print(dryRun ? "Dry run: rolled back." : "Committed.")
    }
} catch BalanceConversionError.invariantViolated(let report) {
    print(report.text)
    print("Aborted: rolled back, nothing saved.")
    exit(1)
} catch {
    FileHandle.standardError.write("Failed (rolled back): \(error)\n".data(using: .utf8)!)
    exit(1)
}
