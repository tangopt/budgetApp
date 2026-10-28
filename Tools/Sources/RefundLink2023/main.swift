// Sources/RefundLink2023/main.swift
//
// One-off (2026-10-28): the SIMAR water refund of 2023-11-29 (BBVA transaction 3960, +€13.51) is the
// payment of SIMAR's credit note, utility invoice 141 (-€13.51, issued 2023-11-08, on the November
// 2023 recharge statement). Linked as the app links a refund credit: the invoice records it
// as its payment (the transaction keeps its category: Utilities (94) would move a filed 2023/24 figure) (`UtilityInvoiceIntake.record`, the invoice's document becoming the transaction's
// evidence). Expected effect: Recharges 2023 difference -€13.99 -> -€0.48 (rounding only).
// One transaction; every filed person-year 2020/21-2024/25 is computed again and any moved line or
// total aborts everything. Idempotent: a second run changes nothing.
//
// Usage: swift run --package-path Tools RefundLink2023 --db <path> [--allow-app-data] [--apply] [--force-running]
//   Without --apply: a dry run on a temporary copy (the database itself is only read).
//   --apply           writes, after a backup next to the database (`<db>.pre-refundlink-2023-backup-YYYYMMDD-HHMMSS`).
//   --allow-app-data  lets the tool open the app's own database.
//   --force-running   lets --apply go ahead while Mango is running (else refused).

import AppKit
import Foundation
import BudgetCore
import GRDB

func usage() -> Never {
    FileHandle.standardError.write("Usage: swift run --package-path Tools RefundLink2023 --db <path> [--allow-app-data] [--apply] [--force-running]\n".data(using: .utf8)!)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    exit(1)
}

struct Refused: Error, CustomStringConvertible {
    let description: String
}

var apply = false, allowAppData = false, forceRunning = false
var databasePath: String?
var remaining = Array(CommandLine.arguments.dropFirst())[...]
while let argument = remaining.popFirst() {
    switch argument {
    case "--apply": apply = true
    case "--allow-app-data": allowAppData = true
    case "--force-running": forceRunning = true
    case "--db": databasePath = remaining.popFirst() ?? { usage() }()
    default: usage()
    }
}
guard let databasePath else { usage() }

let fileManager = FileManager.default
let sourcePath = URL(fileURLWithPath: (databasePath as NSString).expandingTildeInPath).standardizedFileURL.path
guard fileManager.fileExists(atPath: sourcePath) else { fail("No database at \(sourcePath)") }
if TaxRegression.isAppData(sourcePath) && !allowAppData {
    fail("Refusing to open the app's own database (\(sourcePath)): pass a copy, or --allow-app-data.")
}
if apply && !forceRunning && AppIdentity.macBundleIdentifiers.contains(where: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }) {
    fail("Mango is running: quit it before --apply (or pass --force-running).")
}

// MARK: - The plan

let filedYears = 2020...2024
let propertyId: Int64 = 1
let rechargeYear = 2023
let transactionId: Int64 = 3960
let invoiceId: Int64 = 141
let amount = 1351
let transactionDay = "2023-11-29"
let invoiceDay = "2023-11-08"
/// Recharges 2023 difference, expected before and after (cents).
let expectedBefore = -1399, expectedAfter = -48

let day: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

// MARK: - Figures

/// Every figure of a person-year that reaches a return: each line's whole / person / not
/// claimed amounts (native, pounds-native, GBP) and the totals.
func fingerprint(_ result: RentalAccounts.Result) -> [String] {
    func amount(_ a: RentalAccounts.Amount) -> String { "\(a.native)|\(a.gbpNative)|\(a.gbp.map(String.init) ?? "nil")" }
    var rows = result.allLines.map { line in
        "\(line.expenseType.rawValue): whole \(amount(line.whole)) amount \(amount(line.amount)) notClaimed \(amount(line.notClaimed))"
    }
    let t = result.totals
    rows.append("totals: income \(amount(t.income)) expenses \(amount(t.expenses)) profit \(amount(t.profit)) finance \(amount(t.financeCosts)) foreignTax \(amount(t.foreignTax))")
    return rows
}

func owners(_ db: Database) throws -> [(id: Int64, name: String)] {
    let ids = Array(Set(try Properties.owners(db: db, propertyId: propertyId).map(\.personId))).sorted()
    return try ids.map { id in (id, try Person.fetchOne(db, key: id)?.name ?? "person \(id)") }
}

func filedFigures(_ db: Database) throws -> [String: [String]] {
    var figures: [String: [String]] = [:]
    for year in filedYears {
        for owner in try owners(db) {
            let result = try RentalAccounts.compute(db: db, taxYear: UKTaxYear(startYear: year), personId: owner.id, propertyId: propertyId)
            figures["\(UKTaxYear(startYear: year).label) · \(owner.name)"] = fingerprint(result)
        }
    }
    return figures
}

/// The tenancy whose November 2023 statement carries the credit note.
func tenancyId(_ db: Database) throws -> Int64 {
    guard let id = try Int64.fetchOne(db, sql: """
        SELECT s.tenancyId FROM rechargeStatement s JOIN rechargeLine l ON l.statementId = s.id WHERE l.invoiceId = ?
        """, arguments: [invoiceId]) else { throw Refused(description: "Invoice \(invoiceId) is on no recharge statement") }
    return id
}

func difference(_ db: Database) throws -> Int {
    try Recharges.yearFigures(db: db, tenancyId: try tenancyId(db))[rechargeYear]?.difference ?? 0
}

func euro(_ cents: Int) -> String { Money.format(cents, currency: .eur) }

func applyChanges(_ db: Database) throws -> [String] {
    var log: [String] = []
    guard let transaction = try Transaction.fetchOne(db, key: transactionId) else { throw Refused(description: "Transaction \(transactionId) is missing") }
    guard transaction.amountMinorUnits == amount, day.string(from: transaction.date) == transactionDay else {
        throw Refused(description: "Transaction \(transactionId) is \(transaction.amountMinorUnits) on \(day.string(from: transaction.date)), expected \(amount) on \(transactionDay)")
    }
    guard var invoice = try UtilityInvoice.fetchOne(db, key: invoiceId) else { throw Refused(description: "Invoice \(invoiceId) is missing") }
    guard invoice.amountMinorUnits == -amount, day.string(from: invoice.issueDate) == invoiceDay else {
        throw Refused(description: "Invoice \(invoiceId) is \(invoice.amountMinorUnits) issued \(day.string(from: invoice.issueDate)), expected the credit note \(-amount) of \(invoiceDay)")
    }
        // The category stays as it is: moving the refund from Confirmed other expenses (42) to Utilities (94)
    // moves the filed 2023/24 "not deductible" line by €13.51 (checked on the copy), and filed figures must not move.
    log.append("= Transaction \(transactionId): category stays \(transaction.categoryId.map(String.init) ?? "none") (recategorising would move a filed 2023/24 figure)")
    if invoice.transactionId == transactionId {
        log.append("= Invoice \(invoiceId): already paid by transaction \(transactionId)")
        return log
    }
    guard invoice.transactionId == nil else {
        throw Refused(description: "Invoice \(invoiceId) is linked to transaction \(invoice.transactionId!), expected none")
    }
    let provider = try UtilityProvider.fetchOne(db, key: invoice.providerId)
    let candidates = try UtilityInvoiceIntake.paymentCandidates(db: db, propertyId: propertyId, provider: provider,
                                                                 amountMinorUnits: invoice.amountMinorUnits, issueDate: invoice.issueDate,
                                                                 excludingInvoice: invoice.id)
    guard candidates.contains(where: { $0.id == transactionId }) else {
        throw Refused(description: "Transaction \(transactionId) is not a payment candidate of invoice \(invoiceId)")
    }
    invoice.transactionId = transactionId
    try UtilityInvoiceIntake.record(db: db, &invoice)
    log.append("+ Invoice \(invoiceId) (\(invoice.invoiceNumber ?? "no number")): refund paid by transaction \(transactionId)\(invoice.documentId.map { ", document \($0) linked to it" } ?? "")")
    return log
}

// MARK: - Run

do {
    var target = sourcePath
    var scratch: String?
    if apply {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let backupPath = sourcePath + ".pre-refundlink-2023-backup-" + stamp.string(from: Date())
        if fileManager.fileExists(atPath: backupPath) { fail("The backup \(backupPath) already exists: try again in a second.") }
        var readOnly = Configuration()
        readOnly.readonly = true
        try ToolDatabase.open(path: sourcePath, configuration: readOnly).backup(to: ToolDatabase.open(path: backupPath))
        print("Backup: \(backupPath)")
    } else {
        let path = NSTemporaryDirectory() + "refundlink-2023-dryrun-\(UUID().uuidString).sqlite"
        var readOnly = Configuration()
        readOnly.readonly = true
        try ToolDatabase.open(path: sourcePath, configuration: readOnly).backup(to: ToolDatabase.open(path: path))
        scratch = path
        target = path
    }
    defer { if let scratch { for suffix in ["", "-wal", "-shm"] { try? fileManager.removeItem(atPath: scratch + suffix) } } }
    let queue = try ToolDatabase.open(path: target)
    print("Refund link 2023 (SIMAR credit note 141 <- transaction 3960)\(apply ? "" : " (dry run on a temporary copy: nothing written to the database)")\nDatabase: \(sourcePath)\n")
    let pendingBefore = try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncPending") ?? 0 }
    let report = try queue.write { db -> String in
        let before = try filedFigures(db)
        let differenceBefore = try difference(db)
        let log = try applyChanges(db)
        let differenceAfter = try difference(db)
        let after = try filedFigures(db)
        var moved: [String] = []
        for key in before.keys.sorted() where before[key] != after[key] {
            let old = before[key] ?? [], new = after[key] ?? []
            moved.append("\(key):\n" + zip(old, new).filter { $0 != $1 }.map { "    was \($0)\n    now \($1)" }.joined(separator: "\n"))
        }
        guard moved.isEmpty else {
            throw Refused(description: "A filed year's figures would change: nothing written.\n" + moved.joined(separator: "\n"))
        }
        let changed = log.contains { $0.hasPrefix("+") }
        guard differenceAfter == (changed ? expectedAfter : differenceBefore), !changed || differenceBefore == expectedBefore else {
            throw Refused(description: "Recharges \(rechargeYear) difference went \(euro(differenceBefore)) → \(euro(differenceAfter)), expected \(euro(expectedBefore)) → \(euro(expectedAfter)): nothing written.")
        }
        return "Changes:\n" + log.map { "  " + $0 }.joined(separator: "\n")
            + "\n\nFiled years 2020/21–2024/25: \(before.count) person-years, every line and total unchanged.\n"
            + "Recharges \(rechargeYear) difference: \(euro(differenceBefore)) → \(euro(differenceAfter))"
    }
    print(report)
    let pending = try queue.read { db in
        try Row.fetchAll(db, sql: "SELECT tableName, kind, COUNT(*) AS n FROM syncPending GROUP BY tableName, kind ORDER BY tableName, kind")
    }
    let pendingAfter = pending.reduce(0) { $0 + ($1["n"] as Int) }
    print("\nsyncPending: \(pendingBefore) → \(pendingAfter) rows")
    for row in pending { print("  \(row["tableName"] as String) \(row["kind"] as String): \(row["n"] as Int)") }
    if !apply { print("\nRun again with --apply to write them.") }
} catch {
    fail("Failed: \(error)")
}
