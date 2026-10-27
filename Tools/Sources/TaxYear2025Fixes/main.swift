// Sources/TaxYear2025Fixes/main.swift
//
// One-off (the user's decisions of 2026-10-27) for UK tax year 2025/26, Lisbon property:
//  1. Utilities and recharges stay out of the tax years, as on the filed returns: the recharge
//     netting mode "not deductible" for 2025/26 and for every year without its own mode
//     (`RechargeNetting.set`). The SIMAR refunds 4177 and 4299 move from "Confirmed other
//     expenses" (42) to Utilities (94) (`TransactionEditing.setCategory`) and become the payments
//     of their credit-note invoices 194 and 222 (`UtilityInvoiceIntake.record`, as the app links a
//     refund: the invoice's document becomes the transaction's evidence).
//  2. Contents insurance 2025-10-13 (tx 4191, €56.44): not claimed under "Any other expense" in
//     2025/26 (`TaxNotClaimedSources.set`) and claimed instead as a whole-property insurance
//     manual item for 2025/26 (cash basis: the whole payment in the year paid), with the
//     payment's documents linked to it.
// Everything is written in one transaction through BudgetCore (sync triggers record each row,
// stamped with the household admin as writer). Before committing, every filed person-year
// 2020/21–2024/25 is computed again: any line or total that moved aborts everything.
// Idempotent: a second run changes nothing.
//
// Usage: swift run --package-path Tools TaxYear2025Fixes --db <path> [--allow-app-data] [--apply] [--force-running]
//   Without --apply: a dry run on a temporary copy (the database itself is only read).
//   --apply           writes, after a backup next to the database (`<db>.pre-taxfix-2025-backup-YYYYMMDD-HHMMSS`).
//   --allow-app-data  lets the tool open the app's own database (the user's go).
//   --force-running   lets --apply go ahead while Mango is running (else refused).

import AppKit
import Foundation
import BudgetCore
import GRDB

func usage() -> Never {
    FileHandle.standardError.write("Usage: swift run --package-path Tools TaxYear2025Fixes --db <path> [--allow-app-data] [--apply] [--force-running]\n".data(using: .utf8)!)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    exit(1)
}

struct Refused: Error, CustomStringConvertible {
    let description: String
}

var apply = false, allowAppData = false, forceRunning = false
var databasePath: String?
var remaining = Array(CommandLine.arguments.dropFirst())[...]
while let argument = remaining.popFirst() {
    switch argument {
    case "--apply": apply = true
    case "--allow-app-data": allowAppData = true
    case "--force-running": forceRunning = true
    case "--db": databasePath = remaining.popFirst() ?? { usage() }()
    default: usage()
    }
}
guard let databasePath else { usage() }

let fileManager = FileManager.default
let sourcePath = URL(fileURLWithPath: (databasePath as NSString).expandingTildeInPath).standardizedFileURL.path
guard fileManager.fileExists(atPath: sourcePath) else { fail("No database at \(sourcePath)") }
if TaxRegression.isAppData(sourcePath) && !allowAppData {
    fail("Refusing to open the app's own database (\(sourcePath)): pass a copy, or --allow-app-data.")
}
if apply && !forceRunning && AppIdentity.macBundleIdentifiers.contains(where: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }) {
    fail("Mango is running: quit it before --apply (or pass --force-running).")
}

// MARK: - The plan

let targetYear = 2025
let filedYears = 2020...2024
let propertyId: Int64 = 1
let utilitiesCategory: Int64 = 94
let otherExpensesCategory: Int64 = 42
/// (transaction, its credit-note invoice, signed amount in cents, day).
let refunds: [(transactionId: Int64, invoiceId: Int64, amount: Int, day: String)] = [
    (4177, 194, 1492, "2025-08-29"),
    (4299, 222, 1368, "2026-08-28")
]
let insuranceTransaction: Int64 = 4191
let insuranceCategory: Int64 = 89
let insuranceAmount = 5644
let insuranceDay = "2025-10-13"
let insuranceLabel = "Contents insurance 2025-10-13 (cash basis: the whole payment in the year paid)"
let decisionNote = "User's decision 2026-10-27"

let day: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

// MARK: - Figures

/// Every figure of a person-year that reaches a return: each line's whole / person / not
/// claimed amounts (native, pounds-native, GBP) and the totals.
func fingerprint(_ result: RentalAccounts.Result) -> [String] {
    func amount(_ a: RentalAccounts.Amount) -> String { "\(a.native)|\(a.gbpNative)|\(a.gbp.map(String.init) ?? "nil")" }
    var rows = result.allLines.map { line in
        "\(line.expenseType.rawValue): whole \(amount(line.whole)) amount \(amount(line.amount)) notClaimed \(amount(line.notClaimed))"
    }
    let t = result.totals
    rows.append("totals: income \(amount(t.income)) expenses \(amount(t.expenses)) profit \(amount(t.profit)) finance \(amount(t.financeCosts)) foreignTax \(amount(t.foreignTax))")
    return rows
}

func owners(_ db: Database) throws -> [(id: Int64, name: String)] {
    let ids = Array(Set(try Properties.owners(db: db, propertyId: propertyId).map(\.personId))).sorted()
    return try ids.map { id in (id, try Person.fetchOne(db, key: id)?.name ?? "person \(id)") }
}

func filedFigures(_ db: Database) throws -> [String: [String]] {
    var figures: [String: [String]] = [:]
    for year in filedYears {
        for owner in try owners(db) {
            let result = try RentalAccounts.compute(db: db, taxYear: UKTaxYear(startYear: year), personId: owner.id, propertyId: propertyId)
            figures["\(UKTaxYear(startYear: year).label) · \(owner.name)"] = fingerprint(result)
        }
    }
    return figures
}

func describeYear(_ db: Database) throws -> String {
    var out = ""
    for owner in try owners(db) {
        let result = try RentalAccounts.compute(db: db, taxYear: UKTaxYear(startYear: targetYear), personId: owner.id, propertyId: propertyId)
        out += "  \(UKTaxYear(startYear: targetYear).label) · \(owner.name)  (netting: \(result.utilityNetting.mode?.rawValue ?? "automatic: none"))\n"
        for line in result.allLines where line.amount != .zero || line.notClaimed != .zero || line.whole != .zero {
            let gbp = line.amount.gbp.map { Money.format($0, currency: .gbp) } ?? "no rate"
            var row = "    \(line.label.padding(toLength: 44, withPad: " ", startingAt: 0)) \(Money.format(line.amount.native, currency: .eur).leftPad(12))  \(gbp.leftPad(11))"
            if line.amount.gbpNative != 0 { row += "  (incl. \(Money.format(line.amount.gbpNative, currency: .gbp)) in GBP)" }
            if line.notClaimed != .zero { row += "  · not claimed \(Money.format(line.notClaimed.native, currency: .eur))" }
            out += row + "\n"
        }
        let t = result.totals
        out += "    Totals: income \(Money.format(t.income.native, currency: .eur)) / \(t.income.gbp.map { Money.format($0, currency: .gbp) } ?? "?")"
            + ", expenses \(Money.format(t.expenses.native, currency: .eur)) / \(t.expenses.gbp.map { Money.format($0, currency: .gbp) } ?? "?")"
            + ", profit \(Money.format(t.profit.native, currency: .eur)) / \(t.profit.gbp.map { Money.format($0, currency: .gbp) } ?? "?")\n"
    }
    return out
}

extension String {
    func leftPad(_ width: Int) -> String { count >= width ? self : String(repeating: " ", count: width - count) + self }
}

// MARK: - The changes

func applyChanges(_ db: Database) throws -> [String] {
    var log: [String] = []

    // 1a. Recharge netting: not deductible for 2025/26 and every year without its own mode.
    for startYear in [targetYear, nil] as [Int?] {
        let label = startYear.map { UKTaxYear(startYear: $0).label } ?? "every other year"
        let stored = try RechargeNettingRule.filter(startYear.map { Column("startYear") == $0 } ?? Column("startYear") == nil).fetchOne(db)
        if stored?.mode == .notDeductible {
            log.append("= Recharge netting \(label): already not deductible")
        } else {
            try RechargeNetting.set(db: db, startYear: startYear, mode: .notDeductible,
                                    notes: "\(decisionNote): utilities are not deductible and recharges are monthly, outside the tax years")
            log.append("+ Recharge netting \(label): \(stored?.mode.rawValue ?? "automatic") → notDeductible")
        }
    }

    // 1b. SIMAR refunds: Utilities, linked to their credit notes.
    for refund in refunds {
        guard let transaction = try Transaction.fetchOne(db, key: refund.transactionId) else { throw Refused(description: "Transaction \(refund.transactionId) is missing") }
        guard transaction.amountMinorUnits == refund.amount, day.string(from: transaction.date) == refund.day else {
            throw Refused(description: "Transaction \(refund.transactionId) is \(transaction.amountMinorUnits) on \(day.string(from: transaction.date)), expected \(refund.amount) on \(refund.day)")
        }
        switch transaction.categoryId {
        case utilitiesCategory:
            log.append("= Transaction \(refund.transactionId): already Utilities")
        case otherExpensesCategory:
            try TransactionEditing.setCategory(db: db, ids: [refund.transactionId], categoryId: utilitiesCategory, remember: false)
            log.append("+ Transaction \(refund.transactionId) (\(refund.day), \(Money.format(refund.amount, currency: .eur))): Confirmed other expenses → Utilities")
        default:
            throw Refused(description: "Transaction \(refund.transactionId) is in category \(transaction.categoryId.map(String.init) ?? "none"), expected 42 or 94")
        }
        guard var invoice = try UtilityInvoice.fetchOne(db, key: refund.invoiceId) else { throw Refused(description: "Invoice \(refund.invoiceId) is missing") }
        guard invoice.amountMinorUnits == -refund.amount else {
            throw Refused(description: "Invoice \(refund.invoiceId) is \(invoice.amountMinorUnits), expected the credit note \(-refund.amount)")
        }
        if invoice.transactionId == refund.transactionId {
            log.append("= Invoice \(refund.invoiceId): already paid by transaction \(refund.transactionId)")
            continue
        }
        guard invoice.transactionId == nil else {
            throw Refused(description: "Invoice \(refund.invoiceId) is linked to transaction \(invoice.transactionId!), expected none")
        }
        let provider = try UtilityProvider.fetchOne(db, key: invoice.providerId)
        let candidates = try UtilityInvoiceIntake.paymentCandidates(db: db, propertyId: propertyId, provider: provider,
                                                                     amountMinorUnits: invoice.amountMinorUnits, issueDate: invoice.issueDate,
                                                                     excludingInvoice: invoice.id)
        guard candidates.contains(where: { $0.id == refund.transactionId }) else {
            throw Refused(description: "Transaction \(refund.transactionId) is not a payment candidate of invoice \(refund.invoiceId)")
        }
        invoice.transactionId = refund.transactionId
        try UtilityInvoiceIntake.record(db: db, &invoice)
        log.append("+ Invoice \(refund.invoiceId) (\(invoice.invoiceNumber ?? "no number")): refund paid by transaction \(refund.transactionId)\(invoice.documentId.map { ", document \($0) linked to it" } ?? "")")
    }

    // 2. Contents insurance: off "Any other expense", onto the insurance line, for 2025/26 only.
    guard let payment = try Transaction.fetchOne(db, key: insuranceTransaction),
          payment.amountMinorUnits == -insuranceAmount, payment.categoryId == insuranceCategory,
          day.string(from: payment.date) == insuranceDay else {
        throw Refused(description: "Transaction \(insuranceTransaction) is not the €56.44 contents insurance of \(insuranceDay) in category 89")
    }
    if try TaxNotClaimed.filter(Column("startYear") == targetYear && Column("transactionId") == insuranceTransaction).fetchCount(db) > 0 {
        log.append("= Transaction \(insuranceTransaction): already not claimed in 2025/26")
    } else {
        try TaxNotClaimedSources.set(db: db, startYear: targetYear, reference: .transaction(insuranceTransaction), notClaimed: true,
                                     notes: "\(decisionNote): claimed on the insurance line instead (manual item, cash basis)")
        log.append("+ Transaction \(insuranceTransaction): not claimed under Any other expense in 2025/26")
    }
    let existing = try TaxManualItem.filter(Column("startYear") == targetYear && Column("propertyId") == propertyId
                                            && Column("expenseType") == TaxExpenseType.insurance.rawValue
                                            && Column("amountMinorUnits") == insuranceAmount).fetchAll(db)
        .filter { $0.date.map(day.string(from:)) == insuranceDay }
    var item: TaxManualItem
    if let found = existing.first {
        item = found
        log.append("= Insurance manual item \(found.id!): already there")
    } else {
        let firstOwner = try owners(db).first!.id
        item = TaxManualItem(startYear: targetYear, personId: firstOwner, propertyId: propertyId, expenseType: .insurance,
                             label: insuranceLabel, amountMinorUnits: insuranceAmount, currency: .eur, date: payment.date,
                             isWholeProperty: true,
                             notes: "\(decisionNote): the bank debit is transaction \(insuranceTransaction), not claimed under Any other expense this year")
        try TaxManualItems.save(db: db, &item)
        log.append("+ Insurance manual item \(item.id!): 2025/26, whole property, \(Money.format(insuranceAmount, currency: .eur)), \(insuranceDay)")
    }
    let documents = try DocumentLink.filter(Column("entityType") == "transaction" && Column("entityId") == insuranceTransaction)
        .fetchAll(db).map(\.documentId)
    var linked = 0
    for documentId in documents.sorted() {
        let already = try DocumentLink.filter(Column("entityType") == "taxManualItem" && Column("entityId") == item.id!
                                              && Column("documentId") == documentId).fetchCount(db) > 0
        if !already {
            try EvidenceLinks.link(db: db, documentId: documentId, to: .taxManualItem(item.id!))
            linked += 1
        }
    }
    log.append(linked == 0 ? "= Manual item documents: already linked (\(documents.count))" : "+ Manual item: linked \(linked) documents of transaction \(insuranceTransaction)")
    return log
}

// MARK: - Run

do {
    var target = sourcePath
    var scratch: String?
    if apply {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let backupPath = sourcePath + ".pre-taxfix-2025-backup-" + stamp.string(from: Date())
        if fileManager.fileExists(atPath: backupPath) { fail("The backup \(backupPath) already exists: try again in a second.") }
        var readOnly = Configuration()
        readOnly.readonly = true
        try ToolDatabase.open(path: sourcePath, configuration: readOnly).backup(to: ToolDatabase.open(path: backupPath))
        print("Backup: \(backupPath)")
    } else {
        // Dry run: the same changes on a temporary copy.
        let path = NSTemporaryDirectory() + "taxfix-2025-dryrun-\(UUID().uuidString).sqlite"
        var readOnly = Configuration()
        readOnly.readonly = true
        try ToolDatabase.open(path: sourcePath, configuration: readOnly).backup(to: ToolDatabase.open(path: path))
        scratch = path
        target = path
    }
    defer { if let scratch { for suffix in ["", "-wal", "-shm"] { try? fileManager.removeItem(atPath: scratch + suffix) } } }
    let queue = try ToolDatabase.open(path: target)
    print("UK tax year 2025/26 fixes\(apply ? "" : " (dry run on a temporary copy: nothing written to the database)")\nDatabase: \(sourcePath)\n")
    let pendingBefore = try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncPending") ?? 0 }
    let report = try queue.write { db -> String in
        let before = try filedFigures(db)
        let yearBefore = try describeYear(db)
        let log = try applyChanges(db)
        let after = try filedFigures(db)
        var moved: [String] = []
        for key in before.keys.sorted() where before[key] != after[key] {
            let old = before[key] ?? [], new = after[key] ?? []
            moved.append("\(key):\n" + zip(old, new).filter { $0 != $1 }.map { "    was \($0)\n    now \($1)" }.joined(separator: "\n"))
        }
        guard moved.isEmpty else {
            throw Refused(description: "A filed year's figures would change: nothing written.\n" + moved.joined(separator: "\n"))
        }
        return "Changes:\n" + log.map { "  " + $0 }.joined(separator: "\n")
            + "\n\nFiled years 2020/21–2024/25: \(before.count) person-years, every line and total unchanged.\n"
            + "\n2025/26 before:\n" + yearBefore + "\n2025/26 after:\n" + (try describeYear(db))
    }
    print(report)
    let pending = try queue.read { db in
        try Row.fetchAll(db, sql: "SELECT tableName, kind, COUNT(*) AS n FROM syncPending GROUP BY tableName, kind ORDER BY tableName, kind")
    }
    let pendingAfter = pending.reduce(0) { $0 + ($1["n"] as Int) }
    print("\nsyncPending: \(pendingBefore) → \(pendingAfter) rows")
    for row in pending { print("  \(row["tableName"] as String) \(row["kind"] as String): \(row["n"] as Int)") }
    if !apply { print("\nRun again with --apply to write them.") }
} catch {
    fail("Failed: \(error)")
}
