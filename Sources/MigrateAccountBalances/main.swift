// Sources/MigrateAccountBalances/main.swift
//
// One-time migration: the original historical-transaction migration
// (MigrateHistory) only carried over category-level spending/income into a
// single synthetic account. The source spreadsheet ("Budget copy.numbers")
// separately tracked six real bank/investment accounts with their own
// month-by-month balances — that section was never migrated, so Net Worth
// showed £0.00 for everything.
//
// This script:
// 1. Deletes the transactions dated after the spreadsheet's own "last
//    updated" cutoff (2026-02) — those months were the user's manual
//    forecast of expected recurring costs, not real imported activity, and
//    shouldn't be counted as confirmed actuals.
// 2. Renames the existing synthetic account to "Lloyds Classic" (it already
//    holds the real day-to-day transaction history) and creates the other
//    five real accounts.
// 3. Backfills a monthly BalanceSnapshot per account from the spreadsheet's
//    real (non-forecast) balance history, Jan 2020 - Feb 2026.
// 4. Regenerates the app's own auto-forecast from the now-real-only
//    transaction history, so the Forecast screen still reflects expected
//    recurring costs going forward instead of the deleted spreadsheet guesses.
//
// Usage: swift run MigrateAccountBalances [path/to/account_balances_real.json]

import Foundation
import BudgetCore
import GRDB

struct BalancePoint: Decodable {
    let date: String
    let balance: Double
}

struct AccountSeries: Decodable {
    let currency: String
    let kind: String
    let series: [BalancePoint]
}

let jsonPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/account_balances_real.json"
let jsonURL = URL(fileURLWithPath: jsonPath)
let accountSeries = try JSONDecoder().decode([String: AccountSeries].self, from: Data(contentsOf: jsonURL))
print("Loaded \(accountSeries.count) account balance series from \(jsonPath)")

let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Budget", isDirectory: true)
let dbPath = appSupport.appendingPathComponent("budget.sqlite").path
print("Database: \(dbPath)")

let manager = try DatabaseManager(path: dbPath)
try manager.migrate()

var utcCalendar = Calendar(identifier: .gregorian)
utcCalendar.timeZone = TimeZone(identifier: "UTC")!

let dateFormatter = DateFormatter()
dateFormatter.dateFormat = "yyyy-MM-dd"
dateFormatter.timeZone = TimeZone(identifier: "UTC")
dateFormatter.calendar = utcCalendar

// The last real month in the source spreadsheet (it was last refreshed
// 2026-02-16); anything dated on or after March 2026 was the user's own
// forward-looking guess at recurring costs, not real transaction history.
let forecastCutoff = utcCalendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!

try manager.dbQueue.write { db in
    let fictionalTransactions = try Transaction.fetchAll(db).filter { $0.date >= forecastCutoff }
    for transaction in fictionalTransactions {
        try transaction.delete(db)
    }
    print("Deleted \(fictionalTransactions.count) transactions dated on/after \(dateFormatter.string(from: forecastCutoff)) (spreadsheet forecast rows, not real activity).")

    guard var lloydsClassic = try Account.filter(Column("name") == "Historical (Numbers import)").fetchOne(db) else {
        fatalError("Expected the existing 'Historical (Numbers import)' account from the original migration - not found.")
    }
    lloydsClassic.name = "Lloyds Classic"
    try lloydsClassic.update(db)
    print("Renamed account #\(lloydsClassic.id!) to 'Lloyds Classic'.")

    var accountsByName: [String: Account] = ["Lloyds Classic": lloydsClassic]

    for (name, series) in accountSeries where name != "Lloyds Classic" {
        guard let currency = Currency(rawValue: series.currency), let kind = AccountKind(rawValue: series.kind) else {
            fatalError("Unknown currency/kind for \(name): \(series.currency)/\(series.kind)")
        }
        var account = Account(name: name, currency: currency, kind: kind, trackingMode: .manual)
        try account.insert(db)
        accountsByName[name] = account
        print("Created account '\(name)' (\(series.kind), \(series.currency)).")
    }

    var snapshotsInserted = 0
    for (name, series) in accountSeries {
        guard let account = accountsByName[name] else { continue }
        for point in series.series {
            guard let date = dateFormatter.date(from: point.date) else { continue }
            let minorUnits = Int((point.balance * 100).rounded())
            var snapshot = BalanceSnapshot(accountId: account.id!, date: date, balanceMinorUnits: minorUnits, note: "Numbers import")
            try snapshot.insert(db)
            snapshotsInserted += 1
        }
    }
    print("Inserted \(snapshotsInserted) balance snapshots across \(accountSeries.count) accounts.")
}

print("Regenerating auto-forecast from the now-real-only transaction history...")
try manager.dbQueue.write { db in try AutoForecastGenerator.refresh(db: db) }
print("Done.")
