// Sources/ReclassifyNewKinds/main.swift
//
// One-off: before the "Repair bill" and "Stamp duty" kinds existed, those documents were filed as
// `other`. Files each `other` document whose text (or, text telling nothing, original file name)
// shows it to be one of them under the new kind, with a canonical name of the new type; and, with
// --repairs-kinds, narrows each evidence rule on a Repairs category that accepts any document to
// those kinds (`NewKindsReclassification`). Documents of any other kind, transactions, figures and
// tax years are never touched. Library files are stored by content hash and never renamed, so the
// library folder isn't touched. Prints every change.
//
// Usage: swift run ReclassifyNewKinds --db <path> [--repairs-kinds repairInvoice,other] [--allow-app-data] [--apply] [--force-running]
//   Before running: launch the updated Mango once (it migrates the database: the tool reads columns
//   those migrations add), then quit it before --apply.
//   Without --apply: a dry run; the database is opened read-only and nothing is written.
//   --apply           writes the plan just printed, in one transaction, after a backup next to the
//                     database (`<db>.pre-new-kinds-backup-YYYYMMDD-HHMMSS`); refused while Mango
//                     runs, and refused (nothing written) if the database changed since the plan.
//   --allow-app-data  lets the tool open the app's own database (the user's go); without it a
//                     database inside the app's data folder is refused — pass a copy.
//   --force-running   lets --apply go ahead while Mango is running (else refused: quit it first).

import AppKit
import Foundation
import BudgetCore
import GRDB

func usage() -> Never {
    FileHandle.standardError.write("""
        Usage: ReclassifyNewKinds --db <path> [--repairs-kinds repairInvoice,other] [--allow-app-data] [--apply] [--force-running]

        Launch the updated Mango once (migrations) before running; quit it before --apply.

        """.data(using: .utf8)!)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    exit(1)
}

var apply = false, allowAppData = false, forceRunning = false
var databasePath: String?
var repairsRuleKinds: [DocumentKind]?
var seen: Set<String> = []
var remaining = Array(CommandLine.arguments.dropFirst())[...]
while let argument = remaining.popFirst() {
    if seen.contains(argument) { usage() }
    seen.insert(argument)
    switch argument {
    case "--apply": apply = true
    case "--allow-app-data": allowAppData = true
    case "--force-running": forceRunning = true
    case "--db", "--database":
        if databasePath != nil { usage() }
        databasePath = remaining.popFirst() ?? { usage() }()
    case "--repairs-kinds":
        let names = (remaining.popFirst() ?? { usage() }()).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let kinds = names.compactMap(DocumentKind.init(rawValue:))
        if kinds.isEmpty || kinds.count != names.count { fail("--repairs-kinds: unknown kind in \(names.joined(separator: ","))") }
        repairsRuleKinds = kinds
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

/// The Mac app running (not the iPhone simulator's Mango): it holds the database open and would
/// overwrite or miss the change. By bundle id (either, as the other tools check); a copy started
/// some other way is still caught by its executable path.
func macAppIsRunning() -> Bool {
    if AppIdentity.macBundleIdentifiers.contains(where: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }) {
        return true
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", #"/Mango\.app/Contents/MacOS/Mango$"#]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { fail("Couldn't check whether Mango is running: \(error)") }
    process.waitUntilExit()
    return process.terminationStatus == 0
}
if apply && !forceRunning && macAppIsRunning() { fail("Mango is running: quit it before --apply (or pass --force-running).") }

func describe(_ plan: NewKindsReclassification.Plan) -> String {
    var lines: [String] = []
    lines.append("Documents to file under a new kind: \(plan.documents.count)")
    for change in plan.documents {
        lines.append("  #\(change.documentId)  \(change.originalFileName)  → \(change.newKind.displayName)  [by \(change.reason == .text ? "text" : "file name")]")
        lines.append("      \(change.oldCanonicalName ?? "(no name)") → \(change.newCanonicalName)")
    }
    lines.append("Evidence rules to change: \(plan.requirements.count)\(repairsRuleKinds == nil ? " (no --repairs-kinds: rules left alone)" : "")")
    for change in plan.requirements {
        func kinds(_ list: [DocumentKind]) -> String { list.isEmpty ? "any document" : list.map(\.displayName).joined(separator: ", ") }
        lines.append("  #\(change.requirementId)  \(change.name): \(kinds(change.oldKinds)) → \(kinds(change.newKinds))")
    }
    return lines.joined(separator: "\n")
}

do {
    var configuration = Configuration()
    configuration.readonly = !apply
    // The app's connection settings (the sync triggers' recursive_triggers), as every tool opens it.
    let queue = try ToolDatabase.open(path: sourcePath, configuration: configuration)
    print("New kinds (Repair bill, Stamp duty)\(apply ? "" : " (dry run: nothing written)")\nDatabase: \(sourcePath)\n")
    let plan = try queue.read { db in try NewKindsReclassification.plan(db: db, repairsRuleKinds: repairsRuleKinds) }
    print(describe(plan))
    if plan.isEmpty { print("\nNothing to change."); exit(0) }
    guard apply else { print("\nRun again with --apply to write them."); exit(0) }

    let stamp = DateFormatter()
    stamp.locale = Locale(identifier: "en_US_POSIX")
    stamp.calendar = Calendar(identifier: .gregorian)
    stamp.dateFormat = "yyyyMMdd-HHmmss"
    let backupPath = sourcePath + ".pre-new-kinds-backup-" + stamp.string(from: Date())
    if fileManager.fileExists(atPath: backupPath) { fail("The backup \(backupPath) already exists: try again in a second.") }
    let backup = try DatabaseQueue(path: backupPath)
    try queue.backup(to: backup)
    try backup.close()
    print("\nBackup: \(backupPath)")
    // One transaction: refused, nothing written, if anything changed since the plan above.
    try queue.write { db in try NewKindsReclassification.applyIfCurrent(plan, db: db, repairsRuleKinds: repairsRuleKinds) }
    print("Written.")
} catch {
    fail("Failed: \(error.localizedDescription)")
}
