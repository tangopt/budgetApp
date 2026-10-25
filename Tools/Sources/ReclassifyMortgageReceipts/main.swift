// Sources/ReclassifyMortgageReceipts/main.swift
//
// One-off: before the "Mortgage receipt" kind existed, the bank's instalment receipts ("Prestacao -
// Recibo n/480", the payment receipt for the debit on its date) were filed as mortgage notices.
// Files each mortgage notice whose text (or, text telling nothing, original file name) marks it as
// a receipt under the new kind, with the receipt's canonical name; and adds the receipt kind to
// every evidence rule that accepts a notice (`MortgageReceiptReclassification`). Library files are
// stored by content hash and never renamed, so the library folder isn't touched. Prints every change.
//
// Usage: swift run ReclassifyMortgageReceipts --db <path> [--allow-app-data] [--apply] [--force-running]
//   Without --apply: a dry run; the database is opened read-only and nothing is written.
//   --apply           writes the changes, in one transaction, after a backup next to the database
//                     (`<db>.pre-mortgage-receipts-backup-YYYYMMDD-HHMMSS`).
//   --allow-app-data  lets the tool open the app's own database (the user's go); without it a
//                     database inside the app's data folder is refused — pass a copy.
//   --force-running   lets --apply go ahead while Mango is running (else refused: quit it first).

import AppKit
import Foundation
import BudgetCore
import GRDB

func usage() -> Never {
    FileHandle.standardError.write("""
        Usage: ReclassifyMortgageReceipts --db <path> [--allow-app-data] [--apply] [--force-running]

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
    fail("Mango is running: quit it before --apply (or pass --force-running).")
}

func describe(_ plan: MortgageReceiptReclassification.Plan) -> String {
    var lines: [String] = []
    lines.append("Documents to file as mortgage receipts: \(plan.documents.count)")
    for change in plan.documents {
        lines.append("  #\(change.documentId)  \(change.originalFileName)  [by \(change.reason == .text ? "text" : "file name")]")
        lines.append("      \(change.oldCanonicalName ?? "(no name)") → \(change.newCanonicalName)")
    }
    lines.append("Evidence rules to accept a mortgage receipt too: \(plan.requirements.count)")
    for change in plan.requirements {
        lines.append("  #\(change.requirementId)  \(change.name): \(change.oldKinds.map(\.displayName).joined(separator: ", "))"
                     + " → \(change.newKinds.map(\.displayName).joined(separator: ", "))")
    }
    return lines.joined(separator: "\n")
}

do {
    var configuration = Configuration()
    configuration.readonly = !apply
    if apply {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.calendar = Calendar(identifier: .gregorian)
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let backupPath = sourcePath + ".pre-mortgage-receipts-backup-" + stamp.string(from: Date())
        if fileManager.fileExists(atPath: backupPath) { fail("The backup \(backupPath) already exists: try again in a second.") }
        try ToolDatabase.open(path: sourcePath).backup(to: ToolDatabase.open(path: backupPath))
        print("Backup: \(backupPath)")
    }
    let queue = try ToolDatabase.open(path: sourcePath, configuration: configuration)
    print("Mortgage receipts\(apply ? "" : " (dry run: nothing written)")\nDatabase: \(sourcePath)\n")
    if apply {
        // One transaction: the plan is made and written together.
        let plan = try queue.write { db -> MortgageReceiptReclassification.Plan in
            let plan = try MortgageReceiptReclassification.plan(db: db)
            try MortgageReceiptReclassification.apply(db: db, plan)
            return plan
        }
        print(plan.isEmpty ? "Nothing to change." : "Written.\n\(describe(plan))")
    } else {
        let plan = try queue.read { db in try MortgageReceiptReclassification.plan(db: db) }
        print(plan.isEmpty ? "Nothing to change." : "\(describe(plan))\n\nRun again with --apply to write them.")
    }
} catch {
    fail("Failed: \(error)")
}
