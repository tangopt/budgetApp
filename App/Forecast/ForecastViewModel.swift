// App/Forecast/ForecastViewModel.swift
import Foundation
import BudgetCore
import GRDB

@MainActor
final class ForecastViewModel: ObservableObject {
    @Published var groups: [ForecastGroup] = []
    @Published var entries: [ForecastEntry] = []
    @Published var periods: [PayPeriod] = []

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func load(horizon: Date) throws {
        groups = try dbQueue.read { db in try ForecastGroup.fetchAll(db) }
        entries = try dbQueue.read { db in try ForecastEntry.fetchAll(db) }
        let incomeDates = try dbQueue.read { db -> [Date] in
            let incomeCategoryIds = try Category.filter(Column("type") == CategoryType.income.rawValue).fetchAll(db).compactMap(\.id)
            return try Date.fetchAll(db, sql: "SELECT date FROM transaction_ WHERE categoryId IN (\(incomeCategoryIds.map(String.init).joined(separator: ","))) AND status = 'confirmed' ORDER BY date")
        }
        var allPeriods = PayPeriodDetector.generateActualPeriods(incomeDates: incomeDates)
        if let cadence = PayPeriodDetector.detectCadence(incomeDates: incomeDates) {
            allPeriods += PayPeriodDetector.generateProjectedPeriods(cadence: cadence, horizon: horizon)
        }
        periods = allPeriods
    }

    func toggleGroup(_ group: ForecastGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].isEnabled.toggle()
        try? dbQueue.write { db in try groups[index].update(db) }
    }

    func toggleEntry(_ entry: ForecastEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].isEnabled.toggle()
        try? dbQueue.write { db in try entries[index].update(db) }
    }

    func confirm(_ entry: ForecastEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].status = .confirmed
        try? dbQueue.write { db in try entries[index].update(db) }
    }

    func confirmedTotal(categoryId: Int64, period: PayPeriod) -> Int {
        ForecastCalculator.confirmedTotal(categoryId: categoryId, period: period, entries: entries, groups: groups)
    }

    func previewTotal(categoryId: Int64, period: PayPeriod) -> Int {
        ForecastCalculator.previewTotal(categoryId: categoryId, period: period, entries: entries, groups: groups)
    }

    func addHypotheticalEntry(groupName: String, categoryId: Int64, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date) {
        try? dbQueue.write { db in
            let group: ForecastGroup
            if let existing = try ForecastGroup.filter(Column("name") == groupName).fetchOne(db) {
                group = existing
            } else {
                var newGroup = ForecastGroup(name: groupName, note: nil, isEnabled: true, isSystemManaged: false)
                try newGroup.insert(db)
                group = newGroup
            }
            var entry = ForecastEntry(groupId: group.id!, categoryId: categoryId, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, startDate: startDate, endDate: nil, isEnabled: true, status: .hypothetical, note: nil)
            try entry.insert(db)
        }
        groups = (try? dbQueue.read { db in try ForecastGroup.fetchAll(db) }) ?? groups
        entries = (try? dbQueue.read { db in try ForecastEntry.fetchAll(db) }) ?? entries
    }
}
