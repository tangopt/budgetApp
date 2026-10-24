// Sources/ApplyTaxData/main.swift
//
// One-off tax data for a property (`TaxDataPlan`): categorises the plan's uncategorised
// debits, stores the category → expense type map, records insurers' and condomínio receipts
// (linked to their debits; a debit settling several items gets one receipt per item, with its
// months — `debitAmount`), assigns payments to one person, adds HMRC filed-return rates and
// manual items the years don't have yet, stores attribution rules (a filed year's own moved
// window: `windowShiftMonths`), fetches HMRC's published
// average rates (`fetchHMRCRates`, the Trade Tariff file for the year to 31 March; only for a
// year lacking a rate, before the write), and sets a year up from its filed return (splits,
// employments, HMRC payments, statuses from Preparing and notes, sources the return left out:
// "deductible, not claimed"). Idempotent; anything contradicting the stored data, or a rate
// that couldn't be fetched, is refused and nothing is written. Then reports every tax figure
// the run moved (before → after, with the years' statuses), and each owner's rental accounts
// for the plan's `summaryYears`, as the app computes them.
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

/// Every path written is checked against the app's data folder (the process's and the real
/// home's: `TaxDataPlan.writeRefusal`).
func guardWrite(_ path: String, _ what: String) {
    if let refusal = TaxDataPlan.writeRefusal(path: path, what: what, allowAppData: allowAppData) { fail(refusal) }
}
if !dryRun {
    guardWrite(sourcePath, "the database")
    // A real run on the app's database writes one the installed app has already migrated to
    // this build (a copy is migrated here).
    do {
        if let refusal = try TaxDataPlan.migrationRefusal(path: sourcePath) { fail(refusal) }
    } catch {
        fail("Can't read the database: \(error)")
    }
}
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
        let source = try ToolDatabase.open(path: sourcePath, configuration: readOnly)
        let target = try ToolDatabase.open(path: copy.path)
        try source.backup(to: target)
        dbPath = copy.path
    } else if let backupPath {
        try ToolDatabase.open(path: sourcePath).backup(to: ToolDatabase.open(path: backupPath))
        print("Backup: \(backupPath)")
    }
    let manager = try DatabaseManager(path: dbPath)
    try manager.migrate()

    // HMRC's files, fetched before the write (only the years still lacking a rate).
    let years = try manager.dbQueue.read { db in try TaxDataPlan.yearsToFetch(db: db, plan: plan) }
    let fetched = awaitResult { await TaxDataPlan.fetchRates(years: years, fetcher: HMRCTradeTariffRateFetcher()) }

    // One transaction: a refusal rolls everything back. The tax figures before and after, in it.
    let planYears = TaxDataPlan.years(plan)
    let (outcome, before, after) = try manager.dbQueue.write { db -> (TaxDataPlan.Outcome, TaxFigures.Snapshot, TaxFigures.Snapshot) in
        let before = try TaxFigures.snapshot(db: db, years: planYears)
        let outcome = try TaxDataPlan.apply(db: db, plan: plan, fetched: fetched)
        return (outcome, before, try TaxFigures.snapshot(db: db, years: planYears))
    }
    let changes = TaxFigures.changes(from: before, to: after)
    var out = "Tax data\(dryRun ? " (dry run: nothing kept)" : "") · \(plan.property)\n"
    out += "Added \(outcome.count(.added)), already there \(outcome.count(.unchanged)), left as stored \(outcome.count(.kept))\n\n"
    out += TaxDataPlan.report(outcome)
    /// Each person's status for the year, before → after when the run changed it.
    func statusText(_ year: Int) -> String {
        let old = before.statuses[year] ?? [:], new = after.statuses[year] ?? [:]
        let names = Set(old.keys).union(new.keys).sorted()
        guard !names.isEmpty else { return "no tax year" }
        return names.map { name in
            let a = old[name]?.rawValue ?? "none", b = new[name]?.rawValue ?? "none"
            return a == b ? "\(name) \(a)" : "\(name) \(a) → \(b)"
        }.joined(separator: ", ")
    }
    out += "== Tax figures the run moved (before → after) ==\n"
    if changes.isEmpty { out += "  none\n" }
    let statusYears = Set(before.statuses.keys).union(after.statuses.keys).filter { before.statuses[$0] != after.statuses[$0] }
    for year in statusYears.sorted() where !changes.contains(where: { $0.key.startYear == year }) {
        out += "  \(UKTaxYear(startYear: year).label) [\(statusText(year))]: statuses only\n"
    }
    var lastYear: Int?
    for change in changes {
        if change.key.startYear != lastYear {
            lastYear = change.key.startYear
            out += "  \(UKTaxYear(startYear: change.key.startYear).label) [\(statusText(change.key.startYear))]\n"
        }
        out += "    \(change.key.person.padding(toLength: 9, withPad: " ", startingAt: 0)) \(change.key.field): \(change.before?.description ?? "—") → \(change.after?.description ?? "—")\n"
    }
    out += "\n"
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
