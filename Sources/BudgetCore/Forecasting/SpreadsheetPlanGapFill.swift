// Sources/BudgetCore/Forecasting/SpreadsheetPlanGapFill.swift
import Foundation
import GRDB

public enum SpreadsheetPlanGapFillError: Error, Equatable {
    case missingCategories([String])
}

/// One-off: fills the months of the spreadsheet's 2026 plan (Mar–Dec) that the app's plan
/// leaves empty. A gap (app plans nothing, spreadsheet does) becomes a new confirmed entry;
/// a mismatch (both plan something, different amounts) is only reported. Idempotent: the
/// new entries fill the gaps they came from. Run inside one transaction
/// (see `Sources/FillSpreadsheetPlanGaps`).
public enum SpreadsheetPlanGapFill {
    public static let reserveName = "Remaining for expenses"
    public static let planGroupName = "Spreadsheet plan"
    public static let note = "From spreadsheet plan (2026 gap fill)"
    static let year = 2026
    static let months = Array(3...12)

    /// Signed minor units per month, Mar…Dec 2026 (nil = empty in the sheet). Income is
    /// positive, everything else negative. Source: the spreadsheet's 2026 plan.
    static let sheet: [(name: String, amounts: [Int?])] = [
        ("Rent", [-280000, -280000, -280000, -280000, -280000, -290000, -290000, -290000, -290000, -290000]),
        ("Internet", [-4500, -4500, -4500, -4500, -4500, -4500, -4500, -4500, -4500, -4500]),
        ("Gas/Electricity", [-10000, -10000, -10000, -10000, -10000, -10000, -10000, -10000, -10000, -10000]),
        ("Mobile Patricia", [-2500, -2500, -2500, -2500, -2500, -2500, -2500, -2500, -2500, -2500]),
        ("Mobile Pablo", [-2200, -2200, -2200, -2200, -2200, -2200, -2200, -2200, -2200, -2200]),
        ("NOW", [-898, -898, -898, -898, -898, -898, -898, -898, -898, -898]),
        ("Apple One", [-3695, -3695, -3695, -3695, -3695, -3695, -3695, -3695, -3695, -3695]),
        ("Netflix", [-1299, -1299, -1299, -1299, -1299, -1299, -1299, -1299, -1299, -1299]),
        ("Spotify", [-1799, -1799, -1799, -1799, -1799, -1799, -1799, -1799, -1799, -1799]),
        ("Council Tax", [nil, -36000, -35000, -35000, -35000, -35000, -35000, -35000, -35000, -35000]),
        ("TV License", [nil, nil, -18000, nil, nil, nil, nil, nil, nil, nil]),
        ("Thames Water", [-35000, nil, nil, nil, nil, nil, -35000, nil, nil, nil]),
        ("Car Payments", [-35125, -35125, -35125, -35125, -35125, -35125, -35125, -35125, -35125, -35125]),
        ("Car MOT", [nil, nil, nil, nil, nil, -15000, nil, nil, nil, nil]),
        ("Car Insurance", [nil, nil, -120000, nil, nil, nil, nil, nil, nil, nil]),
        ("Car Service", [nil, nil, -100000, nil, nil, nil, nil, nil, nil, nil]),
        ("Confirmed other SIGNIFICANT expenses", [-250000, nil, nil, nil, nil, nil, nil, nil, nil, nil]),
        ("Transfer: Santander Patricia", [-125000, -125000, -125000, -125000, -125000, -125000, -125000, -125000, -125000, -125000]),
        ("Transfer: Lloyds Joint", [-200000, -200000, -200000, -200000, -200000, -200000, -200000, -200000, -200000, -200000]),
        ("Accountant", [nil, nil, nil, nil, nil, nil, nil, nil, nil, -72000]),
        ("UK Taxes", [nil, nil, nil, nil, nil, nil, nil, nil, nil, -320000]),
        ("Remaining for expenses", [-200000, -200000, -200000, -200000, -200000, -200000, -200000, -200000, -200000, -200000]),
        ("Income", [775825, 775825, 775825, 775825, 775825, 775825, 775825, 775825, 775825, 775825]),
    ]

    public static var requiredCategoryNames: [String] { sheet.map(\.name) }

    public struct Run: Equatable {
        public let categoryId: Int64
        public let name: String
        public let amountMinorUnits: Int
        public let frequency: ForecastFrequency
        public let firstMonth: Int   // 3...12, 2026
        public let lastMonth: Int
        public let continues: Bool
        public let isReserve: Bool

        var startDate: Date { MonthRange.of(year: SpreadsheetPlanGapFill.year, month: firstMonth).start }
        var endDate: Date? { continues ? nil : MonthRange.of(year: SpreadsheetPlanGapFill.year, month: lastMonth).end }

        public var logLine: String {
            let pounds = Money.format(amountMinorUnits, currency: .gbp)
            if frequency == .once { return "\(name): \(pounds) once \(label(firstMonth))" }
            if continues { return "\(name): \(pounds) monthly from \(label(firstMonth)) (continues)" }
            return "\(name): \(pounds) monthly \(label(firstMonth))…\(label(lastMonth))"
        }
    }

    public struct GapFillPlan: Equatable {
        public let runs: [Run]
        public let mismatches: [String]
    }

    static func label(_ month: Int) -> String { String(format: "%d-%02d", year, month) }

    /// Pure computation: reads the database, writes nothing.
    public static func plan(db: Database) throws -> GapFillPlan {
        var categories: [String: Category] = [:]
        for category in try Category.fetchAll(db) { categories[category.name] = category }
        let missing = requiredCategoryNames.filter { categories[$0] == nil }
        guard missing.isEmpty else { throw SpreadsheetPlanGapFillError.missingCategories(missing) }

        let entries = try ForecastEntry.budget(db)
        let groups = try ForecastGroup.fetchAll(db)
        let exceptions = try PlannedOccurrenceException.fetchAll(db)
        func planned(_ categoryId: Int64, year: Int, month: Int) -> Int {
            let range = MonthRange.of(year: year, month: month)
            return ForecastCalculator.confirmedTotal(categoryId: categoryId, period: PayPeriod(startDate: range.start, endDate: range.end, type: .projected), entries: entries, groups: groups, exceptions: exceptions)
        }

        var runs: [Run] = []
        var mismatches: [String] = []
        for row in sheet {
            let category = categories[row.name]!
            let id = category.id!
            let app = months.map { planned(id, year: year, month: $0) }
            let hasJanuaryPlan = planned(id, year: year + 1, month: 1) != 0

            // Gaps → runs of consecutive months with the same sheet amount.
            var current: (amount: Int, first: Int, last: Int)?
            func flush() {
                guard let run = current else { return }
                let single = run.first == run.last
                let continues = !single && run.last == 12 && !hasJanuaryPlan
                runs.append(Run(categoryId: id, name: row.name, amountMinorUnits: run.amount, frequency: single ? .once : .monthly, firstMonth: run.first, lastMonth: run.last, continues: continues, isReserve: category.isReserved))
                current = nil
            }
            for (index, month) in months.enumerated() {
                if app[index] == 0, let amount = row.amounts[index], amount != 0 {
                    if let run = current, run.amount == amount, run.last == month - 1 {
                        current = (amount, run.first, month)
                    } else {
                        flush()
                        current = (amount, month, month)
                    }
                } else {
                    flush()
                }
            }
            flush()

            // Mismatches (and app-only months) → runs of identical (app, sheet) pairs.
            var group: (app: Int, sheet: Int?, first: Int, last: Int)?
            func flushMismatch() {
                guard let g = group else { return }
                let span = g.first == g.last ? label(g.first) : "\(label(g.first))…\(label(g.last))"
                let sheetText = g.sheet.map { Money.format($0, currency: .gbp) } ?? "none"
                mismatches.append("\(row.name): plan \(Money.format(g.app, currency: .gbp)) vs spreadsheet \(sheetText) (\(span)) — not changed")
                group = nil
            }
            for (index, month) in months.enumerated() {
                let sheetAmount = row.amounts[index]
                if app[index] != 0, (sheetAmount ?? 0) != app[index] {
                    if let g = group, g.app == app[index], g.sheet == sheetAmount, g.last == month - 1 {
                        group = (g.app, g.sheet, g.first, month)
                    } else {
                        flushMismatch()
                        group = (app[index], sheetAmount, month, month)
                    }
                } else {
                    flushMismatch()
                }
            }
            flushMismatch()
        }
        return GapFillPlan(runs: runs, mismatches: mismatches)
    }

    /// Inserts the planned runs; returns one log line per new entry.
    public static func apply(db: Database, plan: GapFillPlan) throws -> [String] {
        var planGroup: ForecastGroup?
        var log: [String] = []
        for run in plan.runs {
            let groupId: Int64
            if run.isReserve {
                groupId = try ReservedCategories.ensureGroup(db: db).id!
            } else {
                if planGroup == nil { planGroup = try ensurePlanGroup(db: db) }
                groupId = planGroup!.id!
            }
            var entry = ForecastEntry(groupId: groupId, categoryId: run.categoryId, amountMinorUnits: run.amountMinorUnits, frequency: run.frequency, interval: 1, startDate: run.startDate, endDate: run.endDate, isEnabled: true, status: .confirmed, note: note)
            try entry.insert(db)
            log.append(run.logLine)
        }
        return log
    }

    private static func ensurePlanGroup(db: Database) throws -> ForecastGroup {
        if let existing = try ForecastGroup.filter(Column("name") == planGroupName).fetchOne(db) { return existing }
        var group = ForecastGroup(name: planGroupName, note: "Planned amounts from the original spreadsheet", isEnabled: true, isSystemManaged: false)
        try group.insert(db)
        return group
    }
}
