// Sources/SetUpLisbonProperty/main.swift
//
// One-off property set-up (plan 2026-10-16 phase 2, Task 5; PropertySetUp): creates the people
// and the property from a plan, links its accounts and category group, imports the Portal das
// Finanças receipts export, sets the tenancy's terms, matches receipts to the rent credits and
// seeds the property's evidence rules — then reports tenancies, receipts, matches, recharges,
// the deposit check, the checks and a UK tax year's summary.
//
// The plan (names, shares, terms) is a JSON data file kept outside the repository; see
// `PropertySetUp.Plan`.
//
// A real run first writes a backup next to the database
// (`<db>.pre-lisbon-setup-backup-YYYYMMDD-HHMMSS`). Unknown keys in the plan are refused.
//
// Usage: swift run SetUpLisbonProperty <db-path> --plan <plan.json> --receipts <ListaRecibos.xlsx>
//          [--dry-run] [--tax-year 2025] [--today YYYY-MM-DD]
//   --dry-run   runs on a temporary copy of the database and deletes it: <db-path> is only read.

import Foundation
import BudgetCore
import GRDB

func usage() -> Never {
    FileHandle.standardError.write("""
        Usage: SetUpLisbonProperty <db-path> --plan <plan.json> --receipts <xlsx> [--dry-run] [--tax-year YYYY] [--today YYYY-MM-DD]

        """.data(using: .utf8)!)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    exit(1)
}

var dryRun = false
var planPath: String?
var receiptsPath: String?
var taxYearText: String?
var todayText: String?
var paths: [String] = []
var remaining = Array(CommandLine.arguments.dropFirst())[...]
while let argument = remaining.popFirst() {
    switch argument {
    case "--dry-run": dryRun = true
    case "--plan": planPath = remaining.popFirst() ?? { usage() }()
    case "--receipts": receiptsPath = remaining.popFirst() ?? { usage() }()
    case "--tax-year": taxYearText = remaining.popFirst() ?? { usage() }()
    case "--today": todayText = remaining.popFirst() ?? { usage() }()
    default:
        if argument.hasPrefix("--") { usage() }
        paths.append(argument)
    }
}
guard paths.count == 1, let planPath else { usage() }
let dbPath = paths[0]
guard FileManager.default.fileExists(atPath: dbPath) else { fail("No database at \(dbPath)") }

let calendar = MonthRange.calendar
func day(_ date: Date) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
}
func eur(_ minor: Int, _ currency: Currency = .eur) -> String { Money.format(minor, currency: currency) }
func lastDigits(_ text: String?) -> String { text.map { "…" + $0.suffix(3) } ?? "—" }

let today: Date = {
    guard let todayText else { return PayCalendar.utcDay(sameDayAs: Date(), in: .current) }
    let parts = todayText.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { usage() }
    return date
}()
let taxYear = UKTaxYear(startYear: taxYearText.flatMap(Int.init) ?? UKTaxYear.containing(today).startYear)

let fileManager = FileManager.default
var temporary: URL?

do {
    let plan = try PropertySetUp.decodePlan(Data(contentsOf: URL(fileURLWithPath: planPath)))
    let rows = try receiptsPath.map { try RentReceiptsExport.parse(xlsx: Data(contentsOf: URL(fileURLWithPath: $0))) }

    var workingDB = dbPath
    if dryRun {
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("SetUpLisbonProperty-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        temporary = scratch
        workingDB = scratch.appendingPathComponent("copy.sqlite").path
        let source = try ToolDatabase.open(path: dbPath, configuration: { var c = Configuration(); c.readonly = true; return c }())
        try source.backup(to: try ToolDatabase.open(path: workingDB))
    } else {
        // A real run keeps a copy of the database as it was first.
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let backupPath = "\(dbPath).pre-lisbon-setup-backup-\(stamp.string(from: Date()))"
        let source = try ToolDatabase.open(path: dbPath, configuration: { var c = Configuration(); c.readonly = true; return c }())
        try source.backup(to: try ToolDatabase.open(path: backupPath))
        print("Backup: \(backupPath)")
    }
    let manager = try DatabaseManager(path: workingDB)
    try manager.migrate()
    print("Database: \(dbPath)\(dryRun ? " (dry run on a temporary copy — nothing is kept)" : "")")
    print("Receipts in the export: \(rows?.count ?? 0)")

    let outcome = try manager.dbQueue.write { db in try PropertySetUp.run(db: db, plan: plan, receiptRows: rows) }
    let propertyId = outcome.propertyId
    let report = try manager.dbQueue.read { db -> String in
        var lines: [String] = []
        let property = try Property.fetchOne(db, key: propertyId)!
        let currency = property.currency
        lines.append("Property: \(outcome.createdProperty ? "created" : "updated") (\(property.country), \(currency.rawValue.uppercased()))")
        lines.append("People created: \(outcome.createdPeople.count); owners: "
                     + (try Properties.owners(db: db, propertyId: propertyId).map { "\(Double($0.shareBasisPoints) / 100)%" }.joined(separator: " / ")))
        lines.append("Accounts: " + (try Properties.accounts(db: db, propertyId: propertyId).map { "\($0.role.rawValue)" }.joined(separator: ", "))
                     + "; category groups: \(try Properties.categoryGroupIds(db: db, propertyId: propertyId).count)")
        if let r = outcome.receiptsImport {
            lines.append("Import: tenancies created \(r.createdTenancies.count), updated \(r.updatedTenancies.count); receipts new \(r.createdReceipts), "
                         + "updated \(r.updatedReceipts), unchanged \(r.unchangedReceipts), cancelled \(r.cancelledReceipts); "
                         + "not in export \(r.missingFromExport.count); property descriptions \(r.propertyDescriptions.count)")
        }

        lines.append("")
        lines.append("Tenancies:")
        for (index, tenancy) in try Tenancies.all(db: db, propertyId: propertyId).enumerated() {
            let receipts = try RentReceipts.receipts(db: db, tenancyId: tenancy.id!, includeCancelled: true)
            let rents = try Tenancies.rents(db: db, tenancyId: tenancy.id!)
                .map { "\(eur($0.monthlyAmountMinorUnits, currency)) from \(day($0.fromDate))" }.joined(separator: ", ")
            lines.append("  T\(index + 1) contract \(lastDigits(tenancy.contractNumber)): \(day(tenancy.startDate)) – \(tenancy.endDate.map(day) ?? "open"); "
                         + "\(receipts.count) receipts (\(receipts.filter { $0.status == .cancelled }.count) cancelled); "
                         + "advance \(tenancy.advanceRentMonths), deposit \(tenancy.depositMonths); rent: \(rents.isEmpty ? "—" : rents)")
            if let derived = outcome.derivedRents[tenancy.id!] {
                lines.append("     rent per whole-month receipts: "
                             + derived.map { "\(eur($0.monthlyAmountMinorUnits, currency)) from \(day($0.fromDate))" }.joined(separator: ", "))
            }
        }

        lines.append("")
        let payments = try RentReceiptPayment.active.fetchAll(db)
        let issued = try RentReceipt.filter(Column("status") == RentReceiptStatus.issued.rawValue).fetchCount(db)
        lines.append("Matching: \(outcome.matching.created.count) links made this run; \(payments.count) active links; "
                     + "\(issued - outcome.matching.unmatchedReceipts.count) of \(issued) issued receipts fully paid")
        lines.append("  Unmatched receipts: \(outcome.matching.unmatchedReceipts.count)")
        for receipt in outcome.matching.unmatchedReceipts.prefix(15) {
            lines.append("    receipt \(receipt.receiptNumber) \(day(receipt.periodStart))–\(day(receipt.periodEnd)) "
                         + "\(eur(receipt.amountReceivedMinorUnits, currency)) received \(receipt.receiptDate.map(day) ?? "—")")
        }
        lines.append("  Unmatched rent credits: \(outcome.matching.unmatchedCredits.count)")
        for credit in outcome.matching.unmatchedCredits.prefix(15) {
            lines.append("    \(day(credit.date)) \(eur(credit.amountMinorUnits, currency))")
        }

        lines.append("")
        lines.append("Recharges/other on matched credits, by calendar year of the credit:")
        let rows = try Row.fetchAll(db, sql: """
            SELECT strftime('%Y', t.date) AS year, SUM(p.otherMinorUnits) AS other, COUNT(*) AS n
            FROM rentReceiptPayment p JOIN transaction_ t ON t.id = p.transactionId
            WHERE p.isDismissed = 0 GROUP BY year ORDER BY year
            """)
        for row in rows { lines.append("  \(row["year"] as String): \(eur(row["other"] as Int, currency)) over \(row["n"] as Int) links") }

        let checks = try PropertyChecks.run(db: db, propertyId: propertyId, period: taxYear.interval, today: today)
        lines.append("")
        lines.append("Checks for \(taxYear.label) (as of \(day(today))): \(checks.issueCount) issue(s)")
        if let deposit = checks.deposit {
            lines.append("  Deposit held \(eur(deposit.heldMinorUnits, currency)) on \(day(deposit.date)); expected deposit \(eur(deposit.expectedDepositMinorUnits, currency)), "
                         + "with advance \(eur(deposit.expectedWithAdvanceMinorUnits, currency)) → "
                         + (deposit.matchedInterpretation.map { "matches \($0.rawValue)" } ?? "off by \(eur(deposit.differenceMinorUnits, currency))"))
        } else {
            lines.append("  Deposit: no check (no deposit account or no tenancy running)")
        }
        lines.append("  Months without a receipt: " + (checks.monthsWithoutReceipt.isEmpty ? "none"
            : checks.monthsWithoutReceipt.map { String(day($0.month.start).prefix(7)) }.joined(separator: ", ")))
        lines.append("  Receipts without a credit: \(checks.receiptsWithoutCredit.map(\.receiptNumber).joined(separator: ", "))")
        lines.append("  Credits without a receipt: \(checks.creditsWithoutReceipt.map { "\(day($0.date)) \(eur($0.amountMinorUnits, currency))" }.joined(separator: ", "))")
        lines.append("  Recurring costs overdue: " + (checks.missingRecurringCosts.isEmpty ? "none"
            : checks.missingRecurringCosts.map { "\($0.pattern.title) (expected \(day($0.expectedDate)))" }.joined(separator: ", ")))

        let summary = try PropertyFinance.summary(db: db, propertyId: propertyId, period: .ukTaxYear(taxYear), today: today)
        let t = summary.totals
        func both(_ amount: PropertyAmount) -> String { "\(eur(amount.native, currency)) (\(eur(amount.gbp, .gbp)))" }
        lines.append("")
        lines.append("Summary \(taxYear.label) (GBP at \(summary.eurToGbpRate)):")
        lines.append("  Rent per receipts \(both(t.rentPerReceipts)); rent credits \(both(t.rentCredits)); recharges \(both(t.recharges)); rent received \(both(t.rentReceived))")
        lines.append("  Income \(both(t.income)); costs \(both(t.costs)); mortgage interest \(both(t.mortgageInterest)) (outside costs \(both(t.interestOutsideCosts)))")
        lines.append("  Capital repaid \(both(t.mortgageCapital)); net cash flow \(both(t.netCashFlow))")
        lines.append("  Outstanding loan \(both(summary.outstandingLoan)); deposit held \(both(summary.depositHeld))")
        lines.append("  Costs by category: " + summary.costsByCategory.map { "\($0.name) \(eur($0.amount.native, currency))" }.joined(separator: "; "))
        lines.append("")
        lines.append("Evidence rules seeded: \(outcome.seededRules.count)")
        return lines.joined(separator: "\n")
    }
    print(report)
    print(dryRun ? "Dry run: temporary copy discarded." : "Done.")
    if let temporary { try? fileManager.removeItem(at: temporary) }
} catch {
    if let temporary { try? fileManager.removeItem(at: temporary) }
    fail("Failed: \(error)")
}
