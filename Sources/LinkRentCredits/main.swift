// Sources/LinkRentCredits/main.swift
//
// One-off: links the rent credits (tenant transfers) to their evidence (`RentCreditEvidence`).
// Run it after the earlier-BBVA import (ImportBBVAEarlierStatements), so its credits are there.
// In ONE transaction, for every property with tenancies:
//   1. unpaid rent receipts are matched to credits (`RentReceiptMatching.match`), by amount and
//      then by date (transfers carrying recharges);
//   2. every receipt's Portal das Finanças PDF is linked to the credits that paid it (role
//      "Rent receipt"), so the transaction shows its paperclip;
//   3. the BBVA "TRANSFERÊNCIA RECEBIDA" advices — the library's and the --folder ones not yet in
//      it (added as bank transfer proofs) — are linked to their credits by date, amount and the
//      statement reference (role "Payment proof").
// The folders are only read. Idempotent: a second run links nothing new.
//
// Usage: swift run LinkRentCredits <db> --library <evidence-dir> [--folder <dir>]... [--report <out.txt>]
//          [--dry-run] [--allow-app-data] [--force-running]
//   --dry-run         runs on a temporary copy of the database (the source opened read-only) and a
//                     temporary library, then deletes both (also on failure): <db> and --library are only read.
//   --allow-app-data  lets a real run write the app's own database and library (the user's go); without it
//                     every path written inside the app's data folder is refused.
//   --force-running   lets a real run go ahead while Budget is running (else refused: quit it first).
//   A real run first writes a backup next to the database (`<db>.pre-rent-links-backup-YYYYMMDD-HHMMSS`),
//   and writes everything in one transaction.

import AppKit
import Foundation
import BudgetCore
import GRDB

func usage() -> Never {
    FileHandle.standardError.write("""
        Usage: LinkRentCredits <db> --library <evidence-dir> [--folder <dir>]... [--report <out.txt>] [--dry-run]
          [--allow-app-data] [--force-running]

        """.data(using: .utf8)!)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    exit(1)
}

var dryRun = false, allowAppData = false, forceRunning = false
var folderPaths: [String] = [], libraryPath: String?, reportPath: String?
var paths: [String] = []
var seen: Set<String> = []
var remaining = Array(CommandLine.arguments.dropFirst())[...]
while let argument = remaining.popFirst() {
    if argument.hasPrefix("--") {
        // Each option once (--folder may repeat).
        if seen.contains(argument) && argument != "--folder" { usage() }
        seen.insert(argument)
    }
    switch argument {
    case "--dry-run": dryRun = true
    case "--allow-app-data": allowAppData = true
    case "--force-running": forceRunning = true
    case "--folder": folderPaths.append(remaining.popFirst() ?? { usage() }())
    case "--library": libraryPath = remaining.popFirst() ?? { usage() }()
    case "--report": reportPath = remaining.popFirst() ?? { usage() }()
    default:
        if argument.hasPrefix("-") { usage() }
        paths.append(argument)
    }
}
guard paths.count == 1, let libraryPath else { usage() }
if dryRun && (allowAppData || forceRunning) { fail("--allow-app-data and --force-running are for a real run, not --dry-run.") }

/// `~` expanded and the path standardised, so the guards see what is written.
func normalized(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
}
let fileManager = FileManager.default
let sourcePath = normalized(paths[0])
let folders = folderPaths.map(normalized)
let library = normalized(libraryPath)
reportPath = reportPath.map(normalized)
var isDirectory: ObjCBool = false
guard fileManager.fileExists(atPath: sourcePath, isDirectory: &isDirectory), !isDirectory.boolValue else { fail("No database at \(sourcePath)") }
for folder in folders {
    guard fileManager.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else { fail("No folder at \(folder)") }
}
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

/// Every path written is checked against the app's data folder, and the advice folders.
func guardWrite(_ path: String, _ what: String) {
    if TaxRegression.isAppData(path) && !allowAppData {
        fail("Refusing to write \(what) in the app's data folder (\(path)): pass a copy, or --allow-app-data for the real run.")
    }
    for folder in folders where isInside(path, folder) {
        fail("Refusing to write \(what) inside the folder \(folder): it is only read.")
    }
}
if !dryRun {
    guardWrite(sourcePath, "the database")
    guardWrite(library, "the evidence library")
    for folder in folders where isInside(folder, library) { fail("The folder \(folder) is inside the library: pick the user's own folder.") }
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
    let path = sourcePath + ".pre-rent-links-backup-" + stamp.string(from: Date())
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
    // Read every PDF first: the folders are only read.
    var files: [RentCreditEvidence.AdviceInput] = []
    var otherFiles = 0
    for folder in folders {
        for url in try RentReceiptPDFs.pdfs(in: URL(fileURLWithPath: folder, isDirectory: true)) {
            let input = try autoreleasepool { try RentReceiptPDFs.read(url) }
            guard let text = input.text, let advice = RentCreditEvidence.parseAdvice(text) else {
                otherFiles += 1
                continue
            }
            files.append(RentCreditEvidence.AdviceInput(source: .file(url), name: url.lastPathComponent, sha256: input.sha256,
                                                        advice: advice, text: text, textStatus: input.textStatus))
        }
    }

    var dbPath = sourcePath
    var libraryRoot = URL(fileURLWithPath: library, isDirectory: true)
    if dryRun {
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("LinkRentCredits-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        temporary.append(scratch)
        let copy = scratch.appendingPathComponent("copy.sqlite")
        // The source is only read.
        var readOnly = Configuration()
        readOnly.readonly = true
        let source = try DatabaseQueue(path: sourcePath, configuration: readOnly)
        let target = try DatabaseQueue(path: copy.path)
        try source.backup(to: target)
        dbPath = copy.path
        libraryRoot = scratch.appendingPathComponent("Evidence", isDirectory: true)
    } else if let backupPath {
        try DatabaseQueue(path: sourcePath).backup(to: DatabaseQueue(path: backupPath))
        print("Backup: \(backupPath)")
    }
    let manager = try DatabaseManager(path: dbPath)
    try manager.migrate()
    let evidence = EvidenceLibrary(root: libraryRoot, database: manager.dbQueue)

    // One transaction: matching and links together; a failure rolls everything back.
    let out = try manager.dbQueue.write { db -> String in
        let run = try RentCreditEvidence.run(db: db, library: evidence, files: files, otherFiles: otherFiles)
        placed = run.properties.flatMap(\.applied.placedFiles)
        return try RentCreditEvidence.report(db: db, run)
    }
    committed = true

    var header = "Rent credit links\(dryRun ? " (dry run: temporary copy and library, nothing kept)" : "")\n"
    header += "Database: \(sourcePath)\nLibrary: \(dryRun ? "temporary (real: \(library))" : library)\n"
    header += "Folders: \(folders.isEmpty ? "none" : folders.joined(separator: ", "))\n\n"
    return header + out
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
