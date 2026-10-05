// Sources/BudgetCore/Forecasting/ForecastPlanSeeder.swift
import Foundation
import GRDB

public enum ForecastPlanSeederError: Error, Equatable {
    case missingCategories([String])
    case nameTakenByOrdinaryCategory(String)
}

/// One-off: brings the spreadsheet's 2026 plan into the forecast — the £2,000/month
/// "Remaining for expenses" reserve, the planned items the app never imported, and
/// corrected amounts for three auto-detected entries. Idempotent; run it inside one
/// transaction (see `Sources/SeedForecastPlan`).
public enum ForecastPlanSeeder {
    public static let reserveName = "Remaining for expenses"
    public static let planGroupName = "Spreadsheet plan"
    public static let note = "From spreadsheet plan"

    struct Item {
        let name: String
        let amountMinorUnits: Int
        let frequency: ForecastFrequency
        let interval: Int
        let year: Int
        let month: Int
    }

    /// Day-to-day spending the reserve stands in for (no planned amounts of its own).
    static let coveredByReserve = [
        "Groceries", "Eating Out", "Delivery", "Meals/Drinks", "Commute / Public Transport",
        "Car Parking Permit", "Car Parking", "Car Tolls", "Car Charge", "Car Gas", "Car Fines",
        "Car Maintenance/Accessories", "Sport", "Holidays / Travel / Events",
        "House Decor / Move Expenses", "Optician", "Confirmed other expenses",
        "Confirmed other SIGNIFICANT expenses"
    ]

    static let becomeExpenses = ["UK Taxes", "Accountant"]

    static let planned = [
        Item(name: "Car Payments", amountMinorUnits: -35_125, frequency: .monthly, interval: 1, year: 2026, month: 10),
        Item(name: "Council Tax", amountMinorUnits: -35_000, frequency: .monthly, interval: 1, year: 2026, month: 10),
        Item(name: "Transfer: Lloyds Joint", amountMinorUnits: -200_000, frequency: .monthly, interval: 1, year: 2026, month: 10),
        Item(name: "UK Taxes", amountMinorUnits: -320_000, frequency: .annually, interval: 1, year: 2026, month: 12),
        Item(name: "Accountant", amountMinorUnits: -72_000, frequency: .annually, interval: 1, year: 2026, month: 12),
        Item(name: "Car Insurance", amountMinorUnits: -120_000, frequency: .annually, interval: 1, year: 2027, month: 5),
        Item(name: "Car Service", amountMinorUnits: -100_000, frequency: .annually, interval: 1, year: 2027, month: 5),
        Item(name: "Car MOT", amountMinorUnits: -15_000, frequency: .annually, interval: 1, year: 2027, month: 8),
        Item(name: "Car Tax", amountMinorUnits: -19_500, frequency: .annually, interval: 1, year: 2027, month: 1)
    ]

    /// Auto-detected entries whose amounts the spreadsheet plan corrects.
    static let corrections = [
        Item(name: "Rent", amountMinorUnits: -290_000, frequency: .monthly, interval: 1, year: 2026, month: 10),
        Item(name: "TV License", amountMinorUnits: -18_000, frequency: .annually, interval: 1, year: 2027, month: 5),
        Item(name: "Thames Water", amountMinorUnits: -35_000, frequency: .monthly, interval: 6, year: 2027, month: 3)
    ]

    static let reserveItem = Item(name: reserveName, amountMinorUnits: -200_000, frequency: .monthly, interval: 1, year: 2026, month: 10)

    public static var requiredCategoryNames: [String] {
        var seen = Set<String>()
        return (coveredByReserve + becomeExpenses + planned.map(\.name) + corrections.map(\.name)).filter { seen.insert($0).inserted }
    }

    public static func apply(db: Database) throws -> [String] {
        var categories: [String: Category] = [:]
        for category in try Category.fetchAll(db) { categories[category.name] = category }
        let missing = requiredCategoryNames.filter { categories[$0] == nil }
        guard missing.isEmpty else { throw ForecastPlanSeederError.missingCategories(missing) }
        if let clash = categories[reserveName], !clash.isReserved {
            throw ForecastPlanSeederError.nameTakenByOrdinaryCategory(reserveName)
        }

        var log: [String] = []

        // 1. UK Taxes and Accountant are money leaving, not moving between own accounts.
        for name in becomeExpenses where categories[name]!.type != .expense {
            try db.execute(sql: "UPDATE category SET type = 'expense' WHERE id = ?", arguments: [categories[name]!.id!])
            log.append("\(name): transfer → expense")
        }

        // 2. The reserve and its allowance.
        let reserve = try categories[reserveName] ?? ReservedCategories.create(db: db, name: reserveName)
        if categories[reserveName] == nil { log.append("Created reserve \(reserveName)") }
        if try ForecastEntry.filter(Column("categoryId") == reserve.id!).fetchCount(db) == 0 {
            let group = try ReservedCategories.ensureGroup(db: db)
            try insert(reserveItem, categoryId: reserve.id!, groupId: group.id!, db: db)
            log.append("\(reserveName): \(describe(reserveItem))")
        }

        // 3. Everything the reserve covers, plus every planned item, is kept out of the
        //    auto-forecast (the reserve or the plan entry is maintained by hand).
        for name in coveredByReserve + planned.map(\.name) {
            let category = categories[name]!
            let autoCount = try ForecastEntry.filter(Column("categoryId") == category.id! && Column("status") == ForecastEntryStatus.auto.rawValue).fetchCount(db)
            guard !category.excludeFromAutoForecast || autoCount > 0 else { continue }
            let deleted = try ReservedCategories.setExcludedFromAutoForecast(db: db, categoryId: category.id!, true)
            log.append("\(name): excluded from auto-forecast" + (deleted > 0 ? " (removed \(deleted) auto entr\(deleted == 1 ? "y" : "ies"))" : ""))
        }

        // 4. Planned items missing from the forecast.
        var planGroup: ForecastGroup?
        for item in planned {
            let categoryId = categories[item.name]!.id!
            let exists = try ForecastEntry.filter(Column("categoryId") == categoryId && Column("note") == note).fetchCount(db) > 0
            guard !exists else { continue }
            if planGroup == nil { planGroup = try ensurePlanGroup(db: db) }
            try insert(item, categoryId: categoryId, groupId: planGroup!.id!, db: db)
            log.append("\(item.name): \(describe(item))")
        }

        // 5. Corrections: update the auto-detected entry in place and make it manual, so
        //    the auto-forecast keeps it; add one to the plan group if there is none.
        let detected = try ForecastGroup.filter(Column("name") == "Detected recurring").fetchOne(db)
        for item in corrections {
            let categoryId = categories[item.name]!.id!
            let start = startDate(item)
            if let groupId = detected?.id,
               var entry = try ForecastEntry.filter(Column("categoryId") == categoryId && Column("groupId") == groupId).fetchOne(db) {
                let matches = entry.amountMinorUnits == item.amountMinorUnits && entry.frequency == item.frequency && entry.interval == item.interval && entry.startDate == start && entry.status == .manual
                guard !matches else { continue }
                entry.amountMinorUnits = item.amountMinorUnits
                entry.frequency = item.frequency
                entry.interval = item.interval
                entry.startDate = start
                entry.endDate = nil
                entry.status = .manual
                entry.note = note
                try entry.update(db)
                log.append("\(item.name): corrected to \(describe(item))")
            } else if try ForecastEntry.filter(Column("categoryId") == categoryId && Column("note") == note).fetchCount(db) == 0 {
                if planGroup == nil { planGroup = try ensurePlanGroup(db: db) }
                try insert(item, categoryId: categoryId, groupId: planGroup!.id!, db: db)
                log.append("\(item.name): \(describe(item))")
            }
        }
        return log
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func startDate(_ item: Item) -> Date {
        calendar.date(from: DateComponents(year: item.year, month: item.month, day: 1))!
    }

    private static func ensurePlanGroup(db: Database) throws -> ForecastGroup {
        if let existing = try ForecastGroup.filter(Column("name") == planGroupName).fetchOne(db) { return existing }
        var group = ForecastGroup(name: planGroupName, note: "Planned amounts from the original spreadsheet", isEnabled: true, isSystemManaged: false)
        try group.insert(db)
        return group
    }

    private static func insert(_ item: Item, categoryId: Int64, groupId: Int64, db: Database) throws {
        var entry = ForecastEntry(groupId: groupId, categoryId: categoryId, amountMinorUnits: item.amountMinorUnits, frequency: item.frequency, interval: item.interval, startDate: startDate(item), endDate: nil, isEnabled: true, status: .confirmed, note: note)
        try entry.insert(db)
    }

    private static func describe(_ item: Item) -> String {
        let pounds = Money.format(item.amountMinorUnits, currency: .gbp)
        let every = item.interval == 1 ? item.frequency.rawValue : "every \(item.interval) months"
        return "\(pounds) \(every) from \(item.year)-\(String(format: "%02d", item.month))"
    }
}
