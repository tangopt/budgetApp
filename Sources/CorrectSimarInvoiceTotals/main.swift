// Sources/CorrectSimarInvoiceTotals/main.swift
//
// One-off: the municipal-water (SIMAR) records the first import made from the 2017–2022
// invoices hold the invoice summary's first line (the water charge) instead of the invoice's
// total, which is what was charged and debited (`UtilityInvoiceTotalCorrection`). Sets each such
// record's amount to its document's total, only where the reader takes that total with
// certainty, the record equals the summary's first line, and the record has no debit linked and
// no recharge line. Prints every change (record id, issue date, old → new).
//
// Usage: swift run CorrectSimarInvoiceTotals --db <path> [--allow-app-data] [--apply] [--force-running]
//   Without --apply: a dry run; the database is opened read-only and nothing is written.
//   --apply           writes the changes, in one transaction, after a backup next to the database
//                     (`<db>.pre-simar-totals-backup-YYYYMMDD-HHMMSS`).
//   --allow-app-data  lets the tool open the app's own database (the user's go); without it a
//                     database inside the app's data folder is refused — pass a copy.
//   --force-running   lets --apply go ahead while Budget is running (else refused: quit it first).

import AppKit
import Foundation
import BudgetCore
import GRDB

func usage() -> Never {
    FileHandle.standardError.write("""
        Usage: CorrectSimarInvoiceTotals --db <path> [--allow-app-data] [--apply] [--force-running]

        """.data(using: .utf8)!)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    exit(1)
}

var apply = false, allowAppData = false, forceRunning = false
var databasePath: String?
var seen: Set<String> = []
var remaining = Array(CommandLine.arguments.dropFirst())[...]
while let argument = remaining.popFirst() {
    if seen.contains(argument) { usage() }
    seen.insert(argument)
    switch argument {
    case "--apply": apply = true
    case "--allow-app-data": allowAppData = true
    case "--force-running": forceRunning = true
    case "--db": databasePath = remaining.popFirst() ?? { usage() }()
    default: usage()
    }
}
guard let databasePath else { usage() }
if forceRunning && !apply { fail("--force-running is for --apply.") }

/// `~` expanded and the path standardised, so the guards see what is opened.
func normalized(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
}
let fileManager = FileManager.default
let sourcePath = normalized(databasePath)
var isDirectory: ObjCBool = false
guard fileManager.fileExists(atPath: sourcePath, isDirectory: &isDirectory), !isDirectory.boolValue else { fail("No database at \(sourcePath)") }
if TaxRegression.isAppData(sourcePath) && !allowAppData {
    fail("Refusing to open the app's own database (\(sourcePath)): pass a copy, or --allow-app-data.")
}
// The app holds the database open and would overwrite or miss the change.
if apply && !forceRunning && AppIdentity.macBundleIdentifiers.contains(where: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }) {
    fail("Budget is running: quit it before --apply (or pass --force-running).")
}

let day: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

func describe(_ changes: [UtilityInvoiceTotalCorrection.Change]) -> String {
    changes.map { change in
        "  #\(change.invoiceId)  \(day.string(from: change.issueDate))  "
            + "\(Money.format(change.oldMinorUnits, currency: .eur)) → \(Money.format(change.newMinorUnits, currency: .eur))"
    }.joined(separator: "\n")
}

do {
    var configuration = Configuration()
    configuration.readonly = !apply
    if apply {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.calendar = Calendar(identifier: .gregorian)
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let backupPath = sourcePath + ".pre-simar-totals-backup-" + stamp.string(from: Date())
        if fileManager.fileExists(atPath: backupPath) { fail("The backup \(backupPath) already exists: try again in a second.") }
        try DatabaseQueue(path: sourcePath).backup(to: DatabaseQueue(path: backupPath))
        print("Backup: \(backupPath)")
    }
    let queue = try DatabaseQueue(path: sourcePath, configuration: configuration)
    let providers = try queue.read { db in try UtilityInvoiceTotalCorrection.simarProviderIds(db: db) }
    guard providers.count == 1, let providerId = providers.first else {
        fail("Expected one SIMAR provider, found \(providers.count): nothing done.")
    }
    print("SIMAR invoice totals\(apply ? "" : " (dry run: nothing written)")\nDatabase: \(sourcePath)\n")
    if apply {
        // One transaction: the plan is made and written together; any record changed since
        // aborts everything.
        let changes = try queue.write { db -> [UtilityInvoiceTotalCorrection.Change] in
            let changes = try UtilityInvoiceTotalCorrection.plan(db: db, providerId: providerId)
            try UtilityInvoiceTotalCorrection.apply(db: db, changes)
            return changes
        }
        print(changes.isEmpty ? "Nothing to correct." : "Corrected \(changes.count) records:\n\(describe(changes))")
    } else {
        let changes = try queue.read { db in try UtilityInvoiceTotalCorrection.plan(db: db, providerId: providerId) }
        print(changes.isEmpty ? "Nothing to correct." : "Would correct \(changes.count) records:\n\(describe(changes))\n\nRun again with --apply to write them.")
    }
} catch {
    fail("Failed: \(error)")
}
