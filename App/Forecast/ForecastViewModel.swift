// App/Forecast/ForecastViewModel.swift
import Foundation
import BudgetCore
import GRDB

@MainActor
final class ForecastViewModel: ObservableObject {
    @Published var groups: [ForecastGroup] = []
    @Published var entries: [ForecastEntry] = []
    @Published var periods: [PayPeriod] = []
    @Published private(set) var horizon: Date = ForecastViewModel.endOfYear(yearsFromNow: 0)
    @Published var errorMessage: String?

    private let dbQueue: DatabaseQueue
    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    private static func endOfYear(yearsFromNow: Int) -> Date {
        let year = calendar.component(.year, from: Date()) + yearsFromNow
        var components = DateComponents(); components.year = year; components.month = 12; components.day = 31
        return calendar.date(from: components) ?? Date()
    }

    func load() throws {
        groups = try dbQueue.read { db in try ForecastGroup.fetchAll(db) }
        entries = try dbQueue.read { db in try ForecastEntry.fetchAll(db) }
        // Paydays come from the salary category only (not Bonus/refunds) — see PaydaySource.
        let paydayDates = try dbQueue.read { db in try PaydaySource.paydayDates(db: db) }
        periods = PayPeriodDetector.allPeriods(incomeDates: paydayDates, horizon: horizon)
    }

    /// Pushes the horizon to the end of next year and reloads — a one-way ratchet for
    /// this session; it doesn't reset back to the current year automatically.
    func extendHorizonToNextYear() {
        horizon = Self.endOfYear(yearsFromNow: 1)
        try? load()
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

    /// Edits an entry's amount/frequency/interval. If it was auto-detected, this promotes
    /// it to `.manual` so a future `AutoForecastGenerator.refresh` won't silently
    /// overwrite the edit — mirrors the generator's own skip-on-manual-tuning behavior.
    ///
    /// The write happens against a locally-built copy first; `entries` is only mutated
    /// once that write has actually succeeded (same shape as
    /// `BudgetGridViewModel.recategorize` / `UncategorizedViewModel.assignCategory`), so a
    /// failed write surfaces in `errorMessage` instead of leaving the UI showing an edit
    /// that was never persisted.
    @discardableResult
    func updateEntry(_ entry: ForecastEntry, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int) -> Bool {
        errorMessage = nil
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return false }
        var updated = entries[index]
        updated.amountMinorUnits = amountMinorUnits
        updated.frequency = frequency
        updated.interval = interval
        if updated.status == .auto {
            updated.status = .manual
        }
        do {
            try dbQueue.write { db in try updated.update(db) }
        } catch {
            errorMessage = "Couldn't save the change: \(error.localizedDescription)"
            return false
        }
        entries[index] = updated
        return true
    }

    /// Moves a confirmed entry back to `.hypothetical` (preview-only). Write-first,
    /// mutate-on-success, like `updateEntry`.
    @discardableResult
    func unconfirm(_ entry: ForecastEntry) -> Bool {
        errorMessage = nil
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return false }
        var updated = entries[index]
        updated.status = .hypothetical
        do {
            try dbQueue.write { db in try updated.update(db) }
        } catch {
            errorMessage = "Couldn't un-confirm this entry: \(error.localizedDescription)"
            return false
        }
        entries[index] = updated
        return true
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
