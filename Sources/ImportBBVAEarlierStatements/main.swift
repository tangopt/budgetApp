// Sources/ImportBBVAEarlierStatements/main.swift
//
// One-off import of BBVA Portugal monthly statements ("extrato global" PDFs) from before the
// history already in the app (`BBVAEarlierHistoryImport`): the current account's rows in a new
// batch, the mortgage instalments (legs and interest) and fund subscriptions (legs and monthly
// values), the tenant deposit, then the plan's tax steps (receipts kept on their own linked,
// manual items replaced by the rows), utility invoices linked and rent receipts matched — in
// ONE transaction, verified (every month end against the statements, today's balances
// unchanged, filed tax years unchanged) or rolled back. Re-running is refused (nothing written).
//
// The plan is a personal data file kept outside the repository; the statements are only read.
//
// Usage: swift run ImportBBVAEarlierStatements <db> --plan <plan.json> --statements <folder> [--report <out.txt>]
//          [--dry-run] [--allow-app-data] [--force-running]
//   --dry-run         runs on a temporary copy of the database (the source opened read-only), then deletes it
//                     (also on failure): <db> is only read.
//   --allow-app-data  lets a real run write the app's own database (the user's go); without it every path
//                     written inside the app's data folder is refused.
//   --force-running   lets a real run go ahead while Budget is running (else refused: quit it first).
//   A real run first writes a backup next to the database (`<db>.pre-bbva-earlier-backup-YYYYMMDD-HHMMSS`).

import AppKit
import CoreGraphics
import Foundation
import BudgetCore
import GRDB

func usage() -> Never {
    FileHandle.standardError.write("""
        Usage: ImportBBVAEarlierStatements <db> --plan <plan.json> --statements <folder> [--report <out.txt>] [--dry-run]
          [--allow-app-data] [--force-running]

        """.data(using: .utf8)!)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    exit(1)
}

var dryRun = false, allowAppData = false, forceRunning = false
var planPath: String?, statementsPath: String?, reportPath: String?
var paths: [String] = []
var remaining = Array(CommandLine.arguments.dropFirst())[...]
while let argument = remaining.popFirst() {
    switch argument {
    case "--dry-run": dryRun = true
    case "--allow-app-data": allowAppData = true
    case "--force-running": forceRunning = true
    case "--plan": planPath = remaining.popFirst() ?? { usage() }()
    case "--statements": statementsPath = remaining.popFirst() ?? { usage() }()
    case "--report": reportPath = remaining.popFirst() ?? { usage() }()
    default:
        if argument.hasPrefix("--") { usage() }
        paths.append(argument)
    }
}
guard paths.count == 1, let planPath, let statementsPath else { usage() }
/// `~` expanded and the path standardised, so the guards see what is written.
func normalized(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
}
let fileManager = FileManager.default
let sourcePath = normalized(paths[0])
let folder = normalized(statementsPath)
reportPath = reportPath.map(normalized)
guard fileManager.fileExists(atPath: sourcePath) else { fail("No database at \(sourcePath)") }
var isDirectory: ObjCBool = false
guard fileManager.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else { fail("No statements folder at \(folder)") }

/// Every path written is checked against the app's data folder.
func guardWrite(_ path: String, _ what: String) {
    if TaxRegression.isAppDatabase(path) && !allowAppData {
        fail("Refusing to write \(what) in the app's data folder (\(path)): pass a copy, or --allow-app-data for the real run.")
    }
}
if !dryRun { guardWrite(sourcePath, "the database") }
// The app holds the database open and would overwrite or miss the import.
if !dryRun && !forceRunning && !NSRunningApplication.runningApplications(withBundleIdentifier: "com.personal.budget").isEmpty {
    fail("Budget is running: quit it before a real run (or pass --force-running).")
}
if let reportPath {
    guardWrite(reportPath, "the report")
    if TaxRegression.isSameFile(reportPath, sourcePath) { fail("The report path is the database: pick another file.") }
}

// A re-run writes nothing, not even a backup; a real run needs the database as the installed
// app (built from this code) left it: no migration this build would still run, none it doesn't know.
do {
    var readOnly = Configuration()
    readOnly.readonly = true
    let plan = try BBVAEarlierHistoryImport.decodePlan(Data(contentsOf: URL(fileURLWithPath: normalized(planPath))))
    let source = try DatabaseQueue(path: sourcePath, configuration: readOnly)
    let applied = (try? source.read { db in try BBVAEarlierHistoryImport.isApplied(db: db, plan: plan) }) ?? false
    if applied {
        print("Already applied: batch “\(plan.batchName)” exists. Nothing written.")
        exit(0)
    }
    if !dryRun {
        let status = try DatabaseManager(path: sourcePath).migrationStatus()
        if !status.pending.isEmpty || !status.unknown.isEmpty {
            fail("The database isn't at this build's version (pending: \(status.pending.joined(separator: ", ")); unknown: \(status.unknown.joined(separator: ", "))). "
                 + "Merge, install the app (scripts/install-app.sh) and open it once, then run again.")
        }
    }
} catch {
    fail("Can't read the plan or the database: \(error)")
}

let backupPath: String? = {
    guard !dryRun else { return nil }
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyyMMdd-HHmmss"
    let path = sourcePath + ".pre-bbva-earlier-backup-" + stamp.string(from: Date())
    guardWrite(path, "the backup")
    if fileManager.fileExists(atPath: path) { fail("The backup \(path) already exists: try again in a second.") }
    return path
}()

/// Temporary copies, removed whatever happens (nothing exits inside the run).
var temporary: [URL] = []

let result = Result<String, Error> {
    let plan = try BBVAEarlierHistoryImport.decodePlan(Data(contentsOf: URL(fileURLWithPath: normalized(planPath))))

    // The statements, only read.
    let files = try fileManager.contentsOfDirectory(atPath: folder).filter { $0.lowercased().hasSuffix(".pdf") }.sorted()
    guard !files.isEmpty else { throw BBVAEarlierHistoryImport.ImportError.badInput("no PDF in \(folder)") }
    var statements: [(file: String, statement: BBVAStatementParser.Statement)] = []
    for file in files {
        let url = URL(fileURLWithPath: folder).appendingPathComponent(file)
        guard let document = CGPDFDocument(url as CFURL) else { throw BBVAEarlierHistoryImport.ImportError.badInput("can't open \(file)") }
        statements.append((file, try BBVAStatementParser.parse(PDFGlyphTextExtractor.text(of: document, maxPages: 50))))
    }
    statements.sort { $0.statement.periodStart < $1.statement.periodStart }

    var dbPath = sourcePath
    if dryRun {
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("ImportBBVAEarlier-\(UUID().uuidString)", isDirectory: true)
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
    } else if let backupPath {
        try DatabaseQueue(path: sourcePath).backup(to: DatabaseQueue(path: backupPath))
        print("Backup: \(backupPath)")
    }
    let manager = try DatabaseManager(path: dbPath)
    try manager.migrate()

    // One transaction: a refusal or a failed check rolls everything back.
    let report = try manager.dbQueue.write { db in
        try BBVAEarlierHistoryImport.apply(db: db, statements: statements.map(\.statement), plan: plan)
    }

    var out = "BBVA earlier statements imported\(dryRun ? " (DRY RUN on a temporary copy: nothing kept)" : "")\n"
    out += "Database \(sourcePath)\nPlan \(normalized(planPath)); batch “\(plan.batchName)”\nStatements \(folder):\n"
    for (file, statement) in statements {
        out += "  \(statement.label) ← \(file) (\(statement.movements.count) rows)\n"
    }
    out += BBVAEarlierHistoryImport.text(report) + "\n"
    return out
}

for url in temporary { try? fileManager.removeItem(at: url) }
switch result {
case .success(let out):
    print(out)
    if let reportPath {
        do { try out.write(toFile: reportPath, atomically: true, encoding: .utf8) } catch { fail("Couldn't write the report: \(error)") }
    }
case .failure(let error as BBVAEarlierHistoryImport.ImportError):
    if let reportPath { try? error.localizedDescription.write(toFile: reportPath, atomically: true, encoding: .utf8) }
    fail("Refused (rolled back, nothing saved): \(error.localizedDescription)")
case .failure(let error):
    fail("Failed (rolled back, nothing saved): \(error)")
}
