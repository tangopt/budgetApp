// Sources/MigrateHistory/main.swift
//
// One-time migration: reads category-level monthly totals extracted from the
// original "Budget copy.numbers" spreadsheet (2020-2026) and inserts one
// synthetic Transaction per category per month into the real app database,
// so historical spending data isn't lost when moving off the spreadsheet.
//
// Each spreadsheet cell was a hand-typed sum of many individual purchases
// with no per-transaction merchant or date — there's no way to recover real
// transaction-level detail. Per row, the category name itself is used as the
// synthetic merchant/description, and the transaction date is the midpoint
// of the month the cell reports on.
//
// Usage: swift run MigrateHistory [path/to/historical_transactions.json]

import Foundation
import BudgetCore
import GRDB

struct HistoricalEntry: Decodable {
    let category: String
    let type: String
    let year: Int
    let month: Int
    let amount: Double
}

let jsonPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/historical_transactions.json"
let jsonURL = URL(fileURLWithPath: jsonPath)
let entries = try JSONDecoder().decode([HistoricalEntry].self, from: Data(contentsOf: jsonURL))
print("Loaded \(entries.count) historical entries from \(jsonPath)")

let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Budget", isDirectory: true)
try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
let dbPath = appSupport.appendingPathComponent("budget.sqlite").path
print("Database: \(dbPath)")

let manager = try DatabaseManager(path: dbPath)
try manager.migrate()
try manager.dbQueue.write { db in try CategorySeeder.seedDefaults(db) }

var utcCalendar = Calendar(identifier: .gregorian)
utcCalendar.timeZone = TimeZone(identifier: "UTC")!

func midpointDate(year: Int, month: Int) -> Date {
    let range = utcCalendar.range(of: .day, in: .month, for: utcCalendar.date(from: DateComponents(year: year, month: month, day: 1))!)!
    let midDay = (range.count + 1) / 2
    return utcCalendar.date(from: DateComponents(year: year, month: month, day: midDay))!
}

var inserted = 0
var skippedDuplicate = 0
var skippedUnknownCategory = 0

try manager.dbQueue.write { db in
    let historicalAccount: Account
    if let existing = try Account.filter(Column("name") == "Historical (Numbers import)").fetchOne(db) {
        historicalAccount = existing
    } else {
        var account = Account(name: "Historical (Numbers import)", currency: .gbp, kind: .cash, trackingMode: .manual)
        try account.insert(db)
        historicalAccount = account
    }

    var batch = ImportBatch(accountId: historicalAccount.id!, sourceFileName: "Budget copy.numbers", importedAt: Date())
    try batch.insert(db)

    let categories = try Category.fetchAll(db)
    let categoryByName = Dictionary(uniqueKeysWithValues: categories.map { ($0.name, $0) })

    for entry in entries {
        guard let category = categoryByName[entry.category] else {
            skippedUnknownCategory += 1
            print("  ! no category found for '\(entry.category)', skipping")
            continue
        }

        let magnitude = Int((entry.amount * 100).rounded())
        let signedAmount = category.type == .income ? magnitude : -magnitude
        let date = midpointDate(year: entry.year, month: entry.month)
        let fingerprint = TransactionFingerprint.compute(
            accountId: historicalAccount.id!,
            date: date,
            amountMinorUnits: signedAmount,
            description: category.name
        )

        var transaction = Transaction(
            importBatchId: batch.id!,
            accountId: historicalAccount.id!,
            date: date,
            rawDescription: category.name,
            amountMinorUnits: signedAmount,
            categoryId: category.id,
            status: .confirmed,
            categorizedBy: .manual,
            fingerprint: fingerprint
        )

        do {
            try transaction.insert(db)
            inserted += 1
        } catch {
            skippedDuplicate += 1
        }
    }
}

print("Inserted \(inserted) historical transactions.")
print("Skipped \(skippedDuplicate) already-migrated duplicates, \(skippedUnknownCategory) unmatched categories.")

print("Regenerating default forecast from historical + any existing data...")
try manager.dbQueue.write { db in try AutoForecastGenerator.refresh(db: db) }
print("Done.")
