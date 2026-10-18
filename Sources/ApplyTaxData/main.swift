// Sources/ApplyTaxData/main.swift
//
// One-off tax data for a property (`TaxDataPlan`): categorises the plan's uncategorised
// debits, stores the category → expense type map, records insurers' and condomínio receipts
// (linked to their debits), assigns payments to one person, adds HMRC filed-return rates and
// manual items the years don't have yet, stores attribution rules, and fetches HMRC's
// published average rates (`fetchHMRCRates`, the Trade Tariff file for the year to 31 March;
// only for a year lacking a rate, before the write). Idempotent; anything contradicting the
// stored data, or a rate that couldn't be fetched, is refused and nothing is written. Tax year
// statuses are never changed. Then reports each owner's rental accounts for the plan's
// `summaryYears`, as the app computes them.
//
// The plan is a personal data file kept outside the repository.
//
// Usage: swift run ApplyTaxData <db> --plan <plan.json> [--report <out.txt>] [--dry-run] [--allow-app-data]
//   --dry-run         runs on a temporary copy of the database (the source opened read-only), then deletes it
//                     (also on failure): <db> is only read.
//   --allow-app-data  lets a real run write the app's own database (the user's go); without it every path
//                     written inside the app's data folder is refused.
//   A real run first writes a backup next to the database (`<db>.pre-tax-data-backup-YYYYMMDD-HHMMSS`).

import Foundation
import BudgetCore
import GRDB

func usage() -> Never {
    FileHandle.standardError.write("""
        Usage: ApplyTaxData <db> --plan <plan.json> [--report <out.txt>] [--dry-run] [--allow-app-data]

        """.data(using: .utf8)!)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    exit(1)
}

var dryRun = false, allowAppData = false
var planPath: String?, reportPath: String?
var paths: [String] = []
var remaining = Array(CommandLine.arguments.dropFirst())[...]
while let argument = remaining.popFirst() {
    switch argument {
    case "--dry-run": dryRun = true
    case "--allow-app-data": allowAppData = true
    case "--plan": planPath = remaining.popFirst() ?? { usage() }()
    case "--report": reportPath = remaining.popFirst() ?? { usage() }()
    default:
        if argument.hasPrefix("--") { usage() }
        paths.append(argument)
    }
}
guard paths.count == 1, let planPath else { usage() }
/// `~` expanded and the path standardised, so the guards see what is written.
func normalized(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
}
let fileManager = FileManager.default
let sourcePath = normalized(paths[0])
reportPath = reportPath.map(normalized)
guard FileManager.default.fileExists(atPath: sourcePath) else { fail("No database at \(sourcePath)") }

/// Every path written is checked against the app's data folder.
func guardWrite(_ path: String, _ what: String) {
    if TaxRegression.isAppDatabase(path) && !allowAppData {
        fail("Refusing to write \(what) in the app's data folder (\(path)): pass a copy, or --allow-app-data for the real run.")
    }
}
if !dryRun { guardWrite(sourcePath, "the database") }
if let reportPath {
    guardWrite(reportPath, "the report")
    if TaxRegression.isSameFile(reportPath, sourcePath) { fail("The report path is the database: pick another file.") }
}

let backupPath: String? = {
    guard !dryRun else { return nil }
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyyMMdd-HHmmss"
    let path = sourcePath + ".pre-tax-data-backup-" + stamp.string(from: Date())
    guardWrite(path, "the backup")
    if fileManager.fileExists(atPath: path) { fail("The backup \(path) already exists: try again in a second.") }
    return path
}()

/// Holds an async step's value for the synchronous run.
final class AsyncBox<T>: @unchecked Sendable {
    var value: T?
}

/// Runs an async step from the synchronous run, waiting for it.
func awaitResult<T>(_ body: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = AsyncBox<T>()
    Task.detached {
        box.value = await body()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}

/// Temporary copies, removed whatever happens (nothing exits inside the run).
var temporary: [URL] = []

let result = Result<String, Error> {
    let plan = try TaxDataPlan.decodePlan(Data(contentsOf: URL(fileURLWithPath: normalized(planPath))))
    var dbPath = sourcePath
    if dryRun {
        let folder = fileManager.temporaryDirectory.appendingPathComponent("ApplyTaxData-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        temporary.append(folder)
        let copy = folder.appendingPathComponent("copy.sqlite")
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

    // HMRC's files, fetched before the write (only the years still lacking a rate).
    let years = try manager.dbQueue.read { db in try TaxDataPlan.yearsToFetch(db: db, plan: plan) }
    let fetched = awaitResult { await TaxDataPlan.fetchRates(years: years, fetcher: HMRCTradeTariffRateFetcher()) }

    // One transaction: a refusal rolls everything back.
    let outcome = try manager.dbQueue.write { db in try TaxDataPlan.apply(db: db, plan: plan, fetched: fetched) }
    var out = "Tax data\(dryRun ? " (dry run: nothing kept)" : "") · \(plan.property)\n"
    out += "Added \(outcome.count(.added)), already there \(outcome.count(.unchanged)), left as stored \(outcome.count(.kept))\n\n"
    out += TaxDataPlan.report(outcome)
    if let years = plan.summaryYears, !years.isEmpty {
        out += "== Rental accounts after applying (the app's own settings) ==\n"
        out += try manager.dbQueue.read { db in try TaxDataPlan.figures(db: db, propertyId: outcome.propertyId, years: years) }
    }
    return out
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
