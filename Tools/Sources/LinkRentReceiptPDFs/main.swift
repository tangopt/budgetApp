// Sources/LinkRentReceiptPDFs/main.swift
//
// One-off: links a folder of Portal das Finanças rent-receipt PDFs to their imported receipts
// (`RentReceiptPDFs`). Each PDF is read (text layer, else OCR), matched by contract and receipt
// number, and checked against the stored receipt (period, receipt date, amount, withholding,
// amount received, tenant); the agreeing ones are added to the evidence library as rent receipts
// (reused when the same file is already there) and linked to their receipt. Mismatches are
// reported and not linked. The folder is only read. Idempotent.
//
// Usage: swift run --package-path Tools LinkRentReceiptPDFs <db> --folder <dir> --library <evidence-dir> [--report <out.txt>]
//          [--dry-run] [--allow-app-data] [--force-running]
//   --dry-run         runs on a temporary copy of the database (the source opened read-only) and a
//                     temporary library, then deletes both (also on failure): <db> and --library are only read.
//   --allow-app-data  lets a real run write the app's own database and library (the user's go); without it
//                     every path written inside the app's data folder is refused.
//   --force-running   lets a real run go ahead while Budget is running (else refused: quit it first).
//   A real run first writes a backup next to the database (`<db>.pre-receipt-pdfs-backup-YYYYMMDD-HHMMSS`),
//   and writes everything in one transaction.

import AppKit
import Foundation
import BudgetCore
import GRDB

func usage() -> Never {
    FileHandle.standardError.write("""
        Usage: swift run --package-path Tools LinkRentReceiptPDFs <db> --folder <dir> --library <evidence-dir> [--report <out.txt>] [--dry-run]
          [--allow-app-data] [--force-running]

        """.data(using: .utf8)!)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    exit(1)
}

var dryRun = false, allowAppData = false, forceRunning = false
var folderPath: String?, libraryPath: String?, reportPath: String?
var paths: [String] = []
var seen: Set<String> = []
var remaining = Array(CommandLine.arguments.dropFirst())[...]
while let argument = remaining.popFirst() {
    if argument.hasPrefix("--") {
        // Each option once.
        if seen.contains(argument) { usage() }
        seen.insert(argument)
    }
    switch argument {
    case "--dry-run": dryRun = true
    case "--allow-app-data": allowAppData = true
    case "--force-running": forceRunning = true
    case "--folder": folderPath = remaining.popFirst() ?? { usage() }()
    case "--library": libraryPath = remaining.popFirst() ?? { usage() }()
    case "--report": reportPath = remaining.popFirst() ?? { usage() }()
    default:
        if argument.hasPrefix("-") { usage() }
        paths.append(argument)
    }
}
guard paths.count == 1, let folderPath, let libraryPath else { usage() }
if dryRun && (allowAppData || forceRunning) { fail("--allow-app-data and --force-running are for a real run, not --dry-run.") }

/// `~` expanded and the path standardised, so the guards see what is written.
func normalized(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
}
let fileManager = FileManager.default
let sourcePath = normalized(paths[0])
let folder = normalized(folderPath)
let library = normalized(libraryPath)
reportPath = reportPath.map(normalized)
var isDirectory: ObjCBool = false
guard fileManager.fileExists(atPath: sourcePath, isDirectory: &isDirectory), !isDirectory.boolValue else { fail("No database at \(sourcePath)") }
guard fileManager.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else { fail("No folder at \(folder)") }
if !dryRun {
    guard fileManager.fileExists(atPath: library, isDirectory: &isDirectory), isDirectory.boolValue else {
        fail("No evidence library at \(library): a real run adds to an existing library.")
    }
}

/// Whether `path` is `folder` or inside it, symbolic links resolved.
func isInside(_ path: String, _ folder: String) -> Bool {
    let target = TaxRegression.resolvedPath(path).lowercased()
    let root = TaxRegression.resolvedPath(folder).lowercased()
    return target == root || target.hasPrefix(root + "/")
}

/// Every path written is checked against the app's data folder, and the receipts folder.
func guardWrite(_ path: String, _ what: String) {
    if TaxRegression.isAppData(path) && !allowAppData {
        fail("Refusing to write \(what) in the app's data folder (\(path)): pass a copy, or --allow-app-data for the real run.")
    }
    if isInside(path, folder) { fail("Refusing to write \(what) inside the receipts folder (\(path)): it is only read.") }
}
if !dryRun {
    guardWrite(sourcePath, "the database")
    guardWrite(library, "the evidence library")
    if isInside(folder, library) { fail("The receipts folder is inside the library: pick the user's own folder.") }
}
// The app holds the database open and would overwrite or miss the links.
if !dryRun && !forceRunning && AppIdentity.macBundleIdentifiers.contains(where: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }) {
    fail("Mango is running: quit it before a real run (or pass --force-running).")
}
if let reportPath {
    guardWrite(reportPath, "the report")
    if TaxRegression.isSameFile(reportPath, sourcePath) { fail("The report path is the database: pick another file.") }
    if isInside(reportPath, library) { fail("The report path is inside the library: pick another file.") }
}

let backupPath: String? = {
    guard !dryRun else { return nil }
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyyMMdd-HHmmss"
    let path = sourcePath + ".pre-receipt-pdfs-backup-" + stamp.string(from: Date())
    guardWrite(path, "the backup")
    if fileManager.fileExists(atPath: path) { fail("The backup \(path) already exists: try again in a second.") }
    return path
}()

/// Temporary copies, removed whatever happens (nothing exits inside the run).
var temporary: [URL] = []
/// Library files placed by the run, removed if its transaction doesn't commit.
var placed: [URL] = []
var committed = false

let result = Result<String, Error> {
    // Read every PDF first: the folder is only read.
    let urls = try RentReceiptPDFs.pdfs(in: URL(fileURLWithPath: folder, isDirectory: true))
    guard !urls.isEmpty else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: folder]) }
    let inputs = try urls.map { url in try autoreleasepool { try RentReceiptPDFs.read(url) } }

    var dbPath = sourcePath
    var libraryRoot = URL(fileURLWithPath: library, isDirectory: true)
    if dryRun {
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("LinkRentReceiptPDFs-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        temporary.append(scratch)
        let copy = scratch.appendingPathComponent("copy.sqlite")
        // The source is only read.
        var readOnly = Configuration()
        readOnly.readonly = true
        let source = try ToolDatabase.open(path: sourcePath, configuration: readOnly)
        let target = try ToolDatabase.open(path: copy.path)
        try source.backup(to: target)
        dbPath = copy.path
        libraryRoot = scratch.appendingPathComponent("Evidence", isDirectory: true)
    } else if let backupPath {
        try ToolDatabase.open(path: sourcePath).backup(to: ToolDatabase.open(path: backupPath))
        print("Backup: \(backupPath)")
    }
    let manager = try DatabaseManager(path: dbPath)
    try manager.migrate()
    let evidence = EvidenceLibrary(root: libraryRoot, database: manager.dbQueue)

    // One transaction: plan and links together; a failure rolls everything back.
    let (plan, applied) = try manager.dbQueue.write { db -> (RentReceiptPDFs.Plan, RentReceiptPDFs.Applied) in
        let plan = try RentReceiptPDFs.plan(db: db, inputs: inputs)
        let applied = try RentReceiptPDFs.apply(db: db, plan: plan, inputs: inputs, library: evidence)
        placed = applied.placedFiles
        return (plan, applied)
    }
    committed = true

    var out = "Rent receipt PDFs\(dryRun ? " (dry run: temporary copy and library, nothing kept)" : "")\n"
    out += "Folder: \(folder)\nDatabase: \(sourcePath)\nLibrary: \(dryRun ? "temporary (real: \(library))" : library)\n\n"
    out += RentReceiptPDFs.report(plan, applied: applied)
    return out
}

if !committed {
    for url in placed { try? fileManager.removeItem(at: url) }
}
for url in temporary { try? fileManager.removeItem(at: url) }
switch result {
case .success(let out):
    print(out)
    if let reportPath {
        do { try out.write(toFile: reportPath, atomically: true, encoding: .utf8) } catch { fail("Couldn't write the report: \(error)") }
    }
case .failure(let error):
    fail("Failed: \(error)")
}
