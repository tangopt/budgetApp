// Sources/BackfillRecharges/main.swift
//
// One-off history backfill of tenant utility recharges (plan phase 5 Task 4;
// `RechargeBackfill`): creates the plan's providers from presets, reads every utility invoice
// under the plan's folders into the evidence library and matches it to its bank debit,
// rebuilds the tenancy's past monthly statements from the tenant's transfers (sent and paid),
// and reports invoices, statements against the transfers' recharge parts, totals per year,
// the tracker's totals, and what netting would change per UK tax year.
//
// The plan (property, tenancy, folders, providers, tracker totals) is a personal data file
// kept outside the repository.
//
// Usage: swift run --package-path Tools BackfillRecharges <db> --plan <plan.json> [--library <evidence-dir>] [--report <out.txt>] [--dry-run]
//          [--allow-app-data]
//   --dry-run         runs on a temporary copy of the database and a temporary library, then deletes both
//                     (also on failure): <db> is only read, and --library isn't accepted.
//   --allow-app-data  lets a real run write the app's own database and evidence library (the user's go);
//                     without it every path written inside the app's data folder is refused.

import Foundation
import BudgetCore
import GRDB

func usage() -> Never {
    FileHandle.standardError.write("""
        Usage: swift run --package-path Tools BackfillRecharges <db> --plan <plan.json> [--library <dir>] [--report <out.txt>] [--dry-run] [--allow-app-data]

        """.data(using: .utf8)!)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    exit(1)
}

var dryRun = false, allowAppData = false
var planPath: String?, libraryPath: String?, reportPath: String?
var paths: [String] = []
var remaining = Array(CommandLine.arguments.dropFirst())[...]
while let argument = remaining.popFirst() {
    switch argument {
    case "--dry-run": dryRun = true
    case "--allow-app-data": allowAppData = true
    case "--plan": planPath = remaining.popFirst() ?? { usage() }()
    case "--library": libraryPath = remaining.popFirst() ?? { usage() }()
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
let sourcePath = normalized(paths[0])
libraryPath = libraryPath.map(normalized)
reportPath = reportPath.map(normalized)
guard FileManager.default.fileExists(atPath: sourcePath) else { fail("No database at \(sourcePath)") }
if dryRun && libraryPath != nil { fail("--library isn't used by a dry run (it always uses a temporary library): leave it out.") }
if !dryRun && libraryPath == nil { fail("A real run needs --library (the evidence library the documents go into).") }

/// Every path written is checked against the app's data folder.
func guardWrite(_ path: String, _ what: String) {
    if TaxRegression.isAppDatabase(path) && !allowAppData {
        fail("Refusing to write \(what) in the app's data folder (\(path)): pass a copy, or --allow-app-data for the real run.")
    }
}
if !dryRun { guardWrite(sourcePath, "the database") }
if let libraryPath { guardWrite(libraryPath, "the evidence library") }
if let reportPath {
    guardWrite(reportPath, "the report")
    if TaxRegression.isSameFile(reportPath, sourcePath) { fail("The report path is the database: pick another file.") }
}

let fileManager = FileManager.default
let calendar = MonthRange.calendar
func day(_ date: Date) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
}
func month(_ date: Date) -> String { String(day(date).prefix(7)) }
func eur(_ minor: Int) -> String { Money.format(minor, currency: .eur) }
func pad(_ text: String, _ width: Int) -> String { text.count >= width ? text : text + String(repeating: " ", count: width - text.count) }
func lpad(_ text: String, _ width: Int) -> String { text.count >= width ? text : String(repeating: " ", count: width - text.count) + text }

let backupPath: String? = {
    guard !dryRun else { return nil }
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyyMMdd-HHmmss"
    let path = sourcePath + ".pre-recharges-backfill-backup-" + stamp.string(from: Date())
    guardWrite(path, "the backup")
    return path
}()

/// Temporary copies, removed whatever happens (nothing exits inside the run).
var temporary: [URL] = []

let result = Result<String, Error> {
    let plan = try RechargeBackfill.decodePlan(Data(contentsOf: URL(fileURLWithPath: planPath)))
    let since = try RechargeBackfill.day(plan.since)

    var dbPath = sourcePath
    var libraryURL = libraryPath.map { URL(fileURLWithPath: $0) }
    if dryRun {
        let folder = fileManager.temporaryDirectory.appendingPathComponent("BackfillRecharges-\(UUID().uuidString)", isDirectory: true)
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
        libraryURL = folder.appendingPathComponent("Evidence", isDirectory: true)
    } else if let backupPath {
        try ToolDatabase.open(path: sourcePath).backup(to: ToolDatabase.open(path: backupPath))
        print("Backup: \(backupPath)")
    }
    let manager = try DatabaseManager(path: dbPath)
    try manager.migrate()
    let library = EvidenceLibrary(root: libraryURL!, database: manager.dbQueue)

    let (propertyId, tenancy, providers) = try manager.dbQueue.write { db -> (Int64, Tenancy, [UtilityProvider]) in
        guard let property = try Property.filter(sql: "name = ? COLLATE NOCASE", arguments: [plan.property]).fetchOne(db) else {
            throw RechargeBackfill.BackfillError.propertyNotFound(plan.property)
        }
        let tenancies = try Tenancies.all(db: db, propertyId: property.id!)
        guard let tenancy = tenancies.first(where: { plan.tenancyContract != nil && $0.contractNumber == plan.tenancyContract })
                ?? tenancies.first(where: { plan.tenancyReference != nil && $0.referenceLabel == plan.tenancyReference }) else {
            throw RechargeBackfill.BackfillError.tenancyNotFound
        }
        let providers = try RechargeBackfill.ensureProviders(db: db, propertyId: property.id!, plan: plan)
        _ = try RentReceiptMatching.match(db: db, propertyId: property.id!)
        return (property.id!, tenancy, providers)
    }

    var out = "Recharges history backfill\(dryRun ? " (dry run: nothing kept)" : "")\n"
    out += "Tenancy \(tenancy.referenceLabel), since \(plan.since); providers: \(providers.map(\.name).joined(separator: ", "))\n\n"

    // Filed years: kept as filed by automatic netting.
    if let years = plan.filedTaxYears, !years.isEmpty {
        let marked = try manager.dbQueue.write { db in try RechargeBackfill.markFiledYears(db: db, propertyId: propertyId, years: years) }
        out += "== Filed tax years ==\n"
        for entry in marked {
            let change = entry.previous == entry.status ? "already \(entry.status.rawValue)" : "\(entry.previous?.rawValue ?? "no record") → \(entry.status.rawValue)"
            out += "\(entry.taxYear.label) \(entry.person): \(change)\n"
        }
        out += "\n"
    }

    // Invoices.
    let folders = plan.invoiceFolders.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    let files = RechargeBackfill.candidateFiles(in: folders, providers: providers)
    let outcomes = try RechargeBackfill.intake(files: files, library: library, propertyId: propertyId)
    let providerName = Dictionary(uniqueKeysWithValues: providers.map { ($0.id!, $0.name) })
    let recorded = outcomes.filter { if case .recorded = $0.status { return true } else { return false } }
    let matched = outcomes.filter { $0.status == .recorded(matched: true) }
    out += "== Invoices ==\n"
    out += "Files read: \(outcomes.count); recorded \(recorded.count) (matched to the bank \(matched.count), unmatched \(recorded.count - matched.count)); "
    out += "duplicates \(outcomes.filter { $0.status == .duplicate }.count); skipped \(outcomes.filter { $0.status == .skipped }.count); "
    out += "read with OCR \(outcomes.filter(\.usedOCR).count)\n"
    for provider in providers {
        let mine = recorded.filter { $0.reading.providerId == provider.id }
        out += "  \(pad(provider.name, 26)) \(mine.count) recorded, \(mine.filter { $0.status == .recorded(matched: true) }.count) matched, total \(eur(mine.compactMap(\.reading.amountMinorUnits).reduce(0, +)))\n"
    }
    let reasons = Dictionary(grouping: outcomes.filter { $0.reason != nil }, by: { $0.reason! })
    for (reason, items) in reasons.sorted(by: { $0.key < $1.key }) {
        out += "  \(reason): \(items.count)\n"
        for item in items {
            let what = [item.reading.providerId.flatMap { providerName[$0] }, item.reading.issueDate.map(day),
                        item.reading.amountMinorUnits.map(eur)].compactMap { $0 }.joined(separator: " · ")
            out += "    \(item.file)\(what.isEmpty ? "" : " — \(what)")\n"
        }
    }

    // Statements.
    let statements = try manager.dbQueue.write { db in try RechargeBackfill.rebuildStatements(db: db, tenancyId: tenancy.id!, since: since) }
    out += "\n== Statements (month · lines · total · transfer's recharge part · linked · difference · how) ==\n"
    for s in statements {
        out += "\(month(s.month))  \(lpad("\(s.lineCount)", 2))  \(lpad(eur(s.totalMinorUnits), 10))  \(lpad(eur(s.rechargePartMinorUnits), 10)) "
        out += "(\(day(s.creditDate)))  \(lpad(eur(s.linkedMinorUnits), 10))  \(lpad(eur(s.rechargePartMinorUnits - s.linkedMinorUnits), 9))  \(s.explanation)\n"
    }
    let exact = statements.filter { (s: RechargeBackfill.StatementOutcome) -> Bool in
        s.linkedMinorUnits == s.rechargePartMinorUnits && s.totalMinorUnits == s.rechargePartMinorUnits
    }.count
    out += "Transfers with a recharge part: \(statements.count); explained exactly by invoices: \(exact)\n"

    // Pending and unmatched rent credits.
    let (pending, unmatchedCredits) = try manager.dbQueue.read { db in
        (try Recharges.pendingLines(db: db, tenancyId: tenancy.id!, through: PayCalendar.utcDay(sameDayAs: Date(), in: .current)),
         try RentReceiptMatching.unmatchedCredits(db: db, propertyId: propertyId).filter { $0.date >= since })
    }
    out += "Invoices of the tenancy not on any statement yet: \(pending.count), \(eur(pending.reduce(0) { $0 + $1.amountMinorUnits }))\n"
    for line in pending { out += "  \(day(line.rechargeDate)) \(providerName[line.invoice.providerId] ?? "") \(eur(line.amountMinorUnits))\n" }
    out += "Rent credits since \(plan.since) matching no rent receipt (not considered): \(unmatchedCredits.count)\n"
    for credit in unmatchedCredits { out += "  \(day(credit.date)) \(eur(credit.amountMinorUnits))\n" }

    // Totals per calendar year.
    out += "\n== Per calendar year (statement month / transfer date) ==\n"
    out += "year   invoices on statements   transfers' recharge parts   linked   tracker\n"
    let years = Set(statements.map { calendar.component(.year, from: $0.month) }).union(plan.trackerTotals?.keys.compactMap(Int.init) ?? []).sorted()
    for year in years {
        let byMonth = statements.filter { calendar.component(.year, from: $0.month) == year }
        let byCredit = statements.filter { calendar.component(.year, from: $0.creditDate) == year }
        let tracker = plan.trackerTotals?[String(year)].map(eur) ?? "—"
        out += "\(year)   \(lpad(eur(byMonth.reduce(0) { $0 + $1.totalMinorUnits }), 12))   \(lpad(eur(byCredit.reduce(0) { $0 + $1.rechargePartMinorUnits }), 12))   "
        out += "\(lpad(eur(byCredit.reduce(0) { $0 + $1.linkedMinorUnits }), 10))   \(lpad(tracker, 10))\n"
    }
    out += "(Tracker totals: its rows by date year, as given in the plan; refunds negative.)\n"

    // Netting per UK tax year.
    let firstYear = UKTaxYear.containing(since).startYear
    let lastYear = UKTaxYear.containing(PayCalendar.utcDay(sameDayAs: Date(), in: .current)).startYear
    let impacts = try manager.dbQueue.write { db in
        try RechargeBackfill.nettingImpact(db: db, propertyId: propertyId, years: (firstYear...lastYear).map(UKTaxYear.init(startYear:)))
    }
    out += "\n== Netting per UK tax year (whole property, EUR; profit change is the person's) ==\n"
    for impact in impacts {
        let status = impact.status?.rawValue ?? "no record"
        let mode = impact.automaticMode?.rawValue ?? "none (each category on its line, as filed)"
        out += "\(impact.taxYear.label) \(impact.person) [tax year record: \(status)] automatic mode now: \(mode)\n"
        out += "  utilities paid \(eur(impact.utilitiesPaid)), recharges received \(eur(impact.rechargesReceived))\n"
        out += "  before phase 5:  Utilities line \(eur(impact.automaticUtilities)), not deductible \(eur(impact.automaticNotDeductible)), income \(eur(impact.automaticIncome))\n"
        out += "  if netted:       Utilities line \(eur(impact.nettedUtilities)), not deductible \(eur(impact.nettedNotDeductible)), income \(eur(impact.nettedIncome))\n"
        out += "  profit change applied automatically (vs before phase 5): \(eur(impact.automaticChange))\n"
        out += "  profit change if the year's netting were set: \(eur(impact.profitChange))\n"
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
