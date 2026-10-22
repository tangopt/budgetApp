// Sources/RebuildRechargesFromTracker/main.swift
//
// Rebuilds a tenancy's utility recharge history from the landlord's tracker
// (`RechargeTrackerRebuild`), as a data plan made by the recharges audit: provider rules brought
// up to the presets, misread invoices corrected, duplicates deleted, each statement's lines
// (invoices, manual and rounding lines) and its paying transfer exactly as planned. Idempotent;
// anything contradicting the stored data is refused and nothing is written; filed tax years must
// come out unchanged. Then compares every month with the tracker and the tenant's transfers, lists
// the payment suggestions left, the invoices still pending, the rental accounts per UK tax year
// before and after, and invoices whose stored text now reads as another amount.
//
// The plan is a personal data file kept outside the repository.
//
// Usage: swift run RebuildRechargesFromTracker <db> --plan <plan.json> [--library <evidence-dir>] [--report <out.txt>]
//          [--dry-run] [--allow-app-data]
//   --library         the evidence library, only read: documents without stored text are read from their files
//                     for the reading check. Nothing is written to it.
//   --dry-run         runs on a temporary copy of the database (the source opened read-only), then deletes it
//                     (also on failure): <db> is only read.
//   --allow-app-data  lets a real run write the app's own database (the user's go); without it every path
//                     written inside the app's data folder is refused.
//   --force-running   lets a real run go ahead while Budget is running (else refused: quit it first).
//   A real run first writes a backup next to the database (`<db>.pre-recharges-rebuild-backup-YYYYMMDD-HHMMSS`).

import AppKit
import Foundation
import BudgetCore
import GRDB

func usage() -> Never {
    FileHandle.standardError.write("""
        Usage: RebuildRechargesFromTracker <db> --plan <plan.json> [--library <dir>] [--report <out.txt>] [--dry-run] [--allow-app-data]
          [--force-running]

        """.data(using: .utf8)!)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    exit(1)
}

var dryRun = false, allowAppData = false, forceRunning = false
var planPath: String?, libraryPath: String?, reportPath: String?
var paths: [String] = []
var remaining = Array(CommandLine.arguments.dropFirst())[...]
while let argument = remaining.popFirst() {
    switch argument {
    case "--dry-run": dryRun = true
    case "--allow-app-data": allowAppData = true
    case "--force-running": forceRunning = true
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
let fileManager = FileManager.default
let sourcePath = normalized(paths[0])
libraryPath = libraryPath.map(normalized)
reportPath = reportPath.map(normalized)
guard fileManager.fileExists(atPath: sourcePath) else { fail("No database at \(sourcePath)") }
if let libraryPath, !fileManager.fileExists(atPath: libraryPath) { fail("No evidence library at \(libraryPath)") }

/// Every path written is checked against the app's data folder.
func guardWrite(_ path: String, _ what: String) {
    if TaxRegression.isAppDatabase(path) && !allowAppData {
        fail("Refusing to write \(what) in the app's data folder (\(path)): pass a copy, or --allow-app-data for the real run.")
    }
}
if !dryRun { guardWrite(sourcePath, "the database") }
// The app holds the database open and would overwrite or miss the rebuild.
if !dryRun && !forceRunning && AppIdentity.macBundleIdentifiers.contains(where: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }) {
    fail("Budget is running: quit it before a real run (or pass --force-running).")
}
if let reportPath {
    guardWrite(reportPath, "the report")
    if TaxRegression.isSameFile(reportPath, sourcePath) { fail("The report path is the database: pick another file.") }
}

let backupPath: String? = {
    guard !dryRun else { return nil }
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyyMMdd-HHmmss"
    let path = sourcePath + ".pre-recharges-rebuild-backup-" + stamp.string(from: Date())
    guardWrite(path, "the backup")
    if fileManager.fileExists(atPath: path) { fail("The backup \(path) already exists: try again in a second.") }
    return path
}()

let calendar = MonthRange.calendar
func day(_ date: Date) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
}
func eur(_ minor: Int) -> String { Money.format(minor, currency: .eur) }
func eur(_ minor: Int?) -> String { minor.map { Money.format($0, currency: .eur) } ?? "-" }
func pad(_ text: String, _ width: Int) -> String { text.count >= width ? text : text + String(repeating: " ", count: width - text.count) }
func lpad(_ text: String, _ width: Int) -> String { text.count >= width ? text : String(repeating: " ", count: width - text.count) + text }

/// Temporary copies, removed whatever happens (nothing exits inside the run).
var temporary: [URL] = []

let result = Result<String, Error> {
    let plan = try RechargeTrackerRebuild.decodePlan(Data(contentsOf: URL(fileURLWithPath: normalized(planPath))))
    var dbPath = sourcePath
    if dryRun {
        let folder = fileManager.temporaryDirectory.appendingPathComponent("RebuildRecharges-\(UUID().uuidString)", isDirectory: true)
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

    // One transaction: a refusal rolls everything back.
    let outcome = try manager.dbQueue.write { db in try RechargeTrackerRebuild.apply(db: db, plan: plan) }

    var out = "Recharges rebuilt from the tracker\(dryRun ? " (dry run: nothing kept)" : "")\n"
    out += "Plan \(normalized(planPath)), \(plan.statements.count) statements; tenancy \(outcome.tenancyId)\n"
    out += "Added \(outcome.count(.added)), changed \(outcome.count(.changed)), deleted \(outcome.count(.deleted)), "
        + "already as planned \(outcome.count(.unchanged))\n\n"

    out += "== Changes ==\n"
    for action in outcome.actions where action.change != .unchanged {
        out += "  \(pad(action.change.rawValue, 9)) \(pad(action.subject, 26)) \(action.detail)\n"
    }
    let unchanged = outcome.actions.filter { $0.change == .unchanged }
    if !unchanged.isEmpty {
        out += "  already as planned: " + unchanged.map(\.subject).joined(separator: ", ") + "\n"
    }

    try manager.dbQueue.read { db in
        // Every month against the tracker and the tenant's transfers.
        let checks = try RechargeTrackerRebuild.compare(db: db, plan: plan)
        out += "\n== Months against the tracker and the tenant's transfers ==\n"
        out += "month    " + lpad("tracker", 11) + lpad("app−tracker", 13) + lpad("tenant paid", 13) + lpad("app total", 12) + lpad("linked", 11)
            + "  status  result\n"
        for check in checks {
            let difference = (check.appTotalMinorUnits ?? 0) - check.trackerMinorUnits
            out += pad(check.month, 9) + lpad(eur(check.trackerMinorUnits), 11) + lpad(difference == 0 ? "" : eur(difference), 13)
                + lpad(eur(check.tenantPaidMinorUnits), 13) + lpad(eur(check.appTotalMinorUnits), 12) + lpad(eur(check.linkedMinorUnits), 11)
                + "  " + pad(check.status?.rawValue ?? "-", 6) + "  " + (check.matches ? "MATCH" : "MISMATCH: \(check.problem ?? "")") + "\n"
        }
        let paid = checks.filter { $0.plannedStatus == .paid }
        let pending = checks.filter { $0.plannedStatus == .sent }
        out += "Paid months matching: \(paid.filter(\.matches).count) of \(paid.count); pending months as planned: "
            + "\(pending.filter(\.matches).count) of \(pending.count)"
            + (pending.isEmpty ? "" : " (" + pending.map { "\($0.month) \(eur($0.appTotalMinorUnits)) owed" }.joined(separator: ", ") + ")") + "\n"
        let rounded = checks.filter { $0.roundingMinorUnits != 0 }
        if !rounded.isEmpty {
            out += "Cent differences, settled by rounding lines (the tenant's transfer against the lines):\n"
            for check in rounded {
                let typo = check.lineVersusTrackerMinorUnits
                out += "  \(check.month) rounding \(check.roundingMinorUnits > 0 ? "+" : "")\(eur(check.roundingMinorUnits))"
                    + (typo == 0 ? ": the transfer differs from the tracker rows" : ": a tracker row differs from its invoice by \(eur(typo)); the tenant paid the tracker")
                    + "\n"
            }
        }
        out += "Totals: tracker rows \(eur(checks.map(\.trackerMinorUnits).reduce(0, +))), rounding \(eur(rounded.map(\.roundingMinorUnits).reduce(0, +))), "
            + "tenant paid \(eur(checks.compactMap(\.tenantPaidMinorUnits).reduce(0, +)))\n"

        // What the Recharges tab would still offer.
        let suggestions = try Recharges.paymentSuggestions(db: db, propertyId: outcome.propertyId)
        out += "\n== Suggested payments left ==\n"
        if suggestions.isEmpty { out += "  none\n" }
        for suggestion in suggestions {
            out += "  \(day(suggestion.statement.month).prefix(7)) ← tx \(suggestion.transaction.id!) \(day(suggestion.transaction.date)) "
                + "\(eur(suggestion.amountMinorUnits)) (difference \(eur(suggestion.differenceMinorUnits)))\n"
        }
        let owed = try Recharges.statements(db: db, tenancyId: outcome.tenancyId).filter { $0.status == .sent }
        for statement in owed {
            out += "  open: \(day(statement.month).prefix(7)) \(eur(try Recharges.outstanding(db: db, statementId: statement.id!))) owed, sent \(statement.sentAt.map(day) ?? "-")\n"
        }

        let far = calendar.date(byAdding: .year, value: 5, to: Date())!
        let pendingLines = try Recharges.pendingLines(db: db, tenancyId: outcome.tenancyId, through: far)
        out += "\n== Invoices of the tenancy on no statement ==\n"
        if pendingLines.isEmpty { out += "  none\n" }
        for line in pendingLines {
            out += "  invoice \(line.invoice.id!) issued \(day(line.invoice.issueDate)), recharge date \(day(line.rechargeDate)) \(eur(line.amountMinorUnits))\n"
        }

        // The rental accounts per year, before and after.
        out += "\n== Rental accounts per UK tax year (the app's own settings), before → after ==\n"
        for (old, new) in zip(outcome.before, outcome.after) {
            let filed = old.isFiled ? "filed" : "open"
            out += "\(old.taxYear.label) \(pad(old.person, 18)) \(filed)"
            if old == new {
                out += ": unchanged (recharges received \(eur(new.rechargesReceived)), utilities line \(eur(new.utilitiesLine)), "
                    + "profit \(eur(new.profit)))\n"
                continue
            }
            out += ", netting \(new.mode?.rawValue ?? "none")\n"
            out += "    recharges received \(eur(old.rechargesReceived)) → \(eur(new.rechargesReceived)) (\(eur(new.rechargesReceived - old.rechargesReceived)))\n"
            out += "    utilities paid \(eur(new.utilitiesPaid)); utilities line \(eur(old.utilitiesLine)) → \(eur(new.utilitiesLine)); "
                + "not deductible \(eur(old.notDeductible)) → \(eur(new.notDeductible)); income \(eur(old.income)) → \(eur(new.income))\n"
            out += "    profit \(eur(old.profit)) → \(eur(new.profit)) (\(new.profit - old.profit >= 0 ? "+" : "")\(eur(new.profit - old.profit)))\n"
        }

        // Invoices whose text reads as another amount with the (merged) rules.
        let library = libraryPath.map { EvidenceLibrary(root: URL(fileURLWithPath: $0), database: manager.dbQueue) }
        let rereads = try RechargeTrackerRebuild.rereads(db: db, propertyId: outcome.propertyId) { document in
            if let text = document.extractedText { return text }
            guard let library else { return nil }
            return EvidenceTextExtractor.extract(from: library.fileURL(for: document)).text
        }
        out += "\n== Invoices whose text now reads as another amount (not changed) ==\n"
        if rereads.isEmpty { out += "  none\n" }
        for reread in rereads {
            out += "  invoice \(reread.invoiceId) \(pad(reread.provider, 24)) \(day(reread.issueDate)) recorded \(lpad(eur(reread.recordedMinorUnits), 9)) "
                + "reads \(lpad(eur(reread.readMinorUnits), 9))\(reread.onStatement ? " (on a statement)" : "")\n"
        }
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
