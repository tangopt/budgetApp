import Foundation
import GRDB

public enum OfferScenarioError: Error, Equatable {
    /// The salary entry the offer replaces ends before the offer's start month.
    case startAfterSalaryEnds
    /// No salary entry to replace (none chosen, or deleted from the budget) and no income category to add the offer in.
    case noSalaryEntryOrNewIncomeCategory
}

extension OfferScenarioError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .startAfterSalaryEnds:
            return "This salary ends in your forecast before the offer starts. Pick an earlier start month or another salary."
        case .noSalaryEntryOrNewIncomeCategory:
            return "There's no salary in your forecast to replace. Choose an income category to add the offer as new income."
        }
    }
}

/// A job offer as a scenario (spec 2026-10-28-step14-job-offer-forecast-design.md): a copy of the budget
/// (`Scenarios.create`) where the salary entry's copy ends the day before the start month and the offer's
/// take-home pay follows it (after any notice-period gap), the pension entry's copy becomes the offer's
/// employee plus employer pension from the start, and the one-offs are added. Every write carries the
/// scenario's id: the budget and actuals are never touched. The spec is stored in `scenario.offerInputs`.
///
/// What the builder adds is marked by a note starting `"Offer: "`; the copies it changes are the copies of
/// the spec's budget entries (`sourceEntryId`). `rebuild` puts exactly those back and applies a new spec.
public enum OfferScenarioBuilder {
    /// Notes of the entries the builder adds start with this.
    public static let notePrefix = "Offer: "

    private static let utc = MonthRange.calendar

    /// A new scenario named `name` (unique: `ScenarioError.duplicateName`) holding the offer. Nothing is
    /// created when it throws.
    @discardableResult
    public static func create(db: Database, name: String, spec: OfferScenarioSpec, now: Date = Date()) throws -> Scenario {
        var scenario: Scenario!
        try db.inSavepoint {
            let plan = try resolve(db: db, spec: spec, scenarioId: nil)
            scenario = try Scenarios.create(db: db, name: name, now: now)
            try apply(db: db, plan: plan, scenarioId: scenario.id!)
            scenario.offerInputs = try plan.spec.json()
            try scenario.update(db, columns: ["offerInputs"])
            return .commit
        }
        return scenario
    }

    /// "Edit offer…" saved: the scenario's offer entries are put back (added ones deleted, changed copies
    /// re-copied from their budget source) and `spec` applied in their place. The scenario's id, name and
    /// every other entry are kept.
    public static func rebuild(db: Database, scenarioId: Int64, spec: OfferScenarioSpec) throws {
        try db.inSavepoint {
            guard var scenario = try Scenario.fetchOne(db, key: scenarioId) else { throw ScenarioError.notFound }
            let plan = try resolve(db: db, spec: spec, scenarioId: scenarioId)
            let previous = scenario.offerInputs.flatMap(OfferScenarioSpec.decode)
            for entry in try ForecastEntry.inScenario(db, id: scenarioId) {
                if entry.scenarioChange == .added, entry.note?.hasPrefix(notePrefix) == true {
                    _ = try entry.delete(db)
                } else if let previous, entry.scenarioChange == .changed || entry.scenarioChange == .removed,
                          let source = entry.sourceEntryId, source == previous.salaryEntryId || source == previous.pensionEntryId {
                    try Scenarios.revert(db: db, scenarioId: scenarioId, entryId: entry.id!)
                }
            }
            try apply(db: db, plan: plan, scenarioId: scenarioId)
            scenario.offerInputs = try plan.spec.json()
            try scenario.update(db, columns: ["offerInputs"])
            return .commit
        }
    }

    /// The spec a scenario was built from; nil for a scenario that isn't a job offer.
    public static func spec(db: Database, scenarioId: Int64) throws -> OfferScenarioSpec? {
        try Scenario.fetchOne(db, key: scenarioId)?.offerInputs.flatMap(OfferScenarioSpec.decode)
    }

    /// The budget entries an offer can replace: enabled monthly income entries, the most recent start first.
    public static func salaryCandidates(db: Database) throws -> [ForecastEntry] {
        try ForecastEntry.fetchAll(db, sql: """
            SELECT forecastEntry.* FROM forecastEntry JOIN category ON category.id = forecastEntry.categoryId
            WHERE forecastEntry.scenarioId IS NULL AND forecastEntry.isEnabled = 1
              AND forecastEntry.frequency = ? AND category.type = ?
            ORDER BY forecastEntry.startDate DESC, forecastEntry.id DESC
            """, arguments: [ForecastFrequency.monthly.rawValue, CategoryType.income.rawValue])
    }

    // MARK: - Plan

    /// What `apply` writes, worked out (and checked) before anything is written.
    private struct Plan {
        var spec: OfferScenarioSpec
        /// The budget salary entry, when it still exists.
        var salary: ForecastEntry?
        var pension: ForecastEntry?
        var incomeCategoryId: Int64
        /// The group and account the new entries go in: the salary's, else the Planned group / Automatic.
        var groupId: Int64?
        var accountId: Int64?
        var anchorDay: Int?
        var startMonth: Date
        var offerStart: Date
        var takeHomeMonthly: Int
        var pensionMonthly: Int
    }

    private static func resolve(db: Database, spec input: OfferScenarioSpec, scenarioId: Int64?) throws -> Plan {
        var spec = input
        spec.startMonth = firstOfMonth(spec.startMonth)
        spec.noticeGapMonths = max(0, spec.noticeGapMonths)
        spec.oneOffs = spec.oneOffs.map { var oneOff = $0; oneOff.month = firstOfMonth(oneOff.month); return oneOff }

        let salary = try spec.salaryEntryId.flatMap { try ForecastEntry.budgetEntries.filter(key: $0).fetchOne(db) }
        if let salary, let end = salary.endDate, end < spec.startMonth { throw OfferScenarioError.startAfterSalaryEnds }
        let pension = try spec.pensionEntryId.flatMap { try ForecastEntry.budgetEntries.filter(key: $0).fetchOne(db) }

        let categoryId: Int64
        if let salary {
            categoryId = salary.categoryId
        } else if let id = spec.newIncomeCategoryId, let category = try Category.fetchOne(db, key: id), category.type == .income {
            categoryId = id
        } else if let scenarioId, let earlier = try previousOfferSalary(db: db, scenarioId: scenarioId) {
            // "Edit offer…" after the salary entry left the budget: the offer stays where it was.
            categoryId = earlier.categoryId
        } else {
            throw OfferScenarioError.noSalaryEntryOrNewIncomeCategory
        }

        let offer = SalaryCalculator.calculate(spec.offer)
        let offerStart = utc.date(byAdding: .month, value: spec.noticeGapMonths, to: spec.startMonth)!
        let salaryAnchor = salary.map { $0.anchorDay ?? utc.component(.day, from: $0.startDate) }
        return Plan(spec: spec, salary: salary, pension: pension, incomeCategoryId: categoryId,
                    groupId: salary?.groupId, accountId: salary?.accountId,
                    anchorDay: salaryAnchor == 1 ? nil : salaryAnchor,
                    startMonth: spec.startMonth, offerStart: offerStart, takeHomeMonthly: offer.takeHomeMonthly,
                    pensionMonthly: SalaryCalculator.roundHalfUp(offer.employeePension + offer.employerPension, 12))
    }

    /// The offer salary an earlier build of this scenario added (its note says so), if any.
    private static func previousOfferSalary(db: Database, scenarioId: Int64) throws -> ForecastEntry? {
        try ForecastEntry.inScenario(db, id: scenarioId).first { $0.scenarioChange == .added && $0.note == salaryNote }
    }

    private static let salaryNote = notePrefix + "salary"
    private static let pensionNote = notePrefix + "pension"

    // MARK: - Apply

    private static func apply(db: Database, plan: Plan, scenarioId: Int64) throws {
        // Salary: the copy ends the day before the start month (or, starting on or after it, the whole
        // series is replaced), and the offer's take-home follows after the gap.
        if let salary = plan.salary, var copy = try copy(of: salary, db: db, scenarioId: scenarioId) {
            try endOrRemove(db: db, &copy, before: plan.startMonth)
        }
        try add(db: db, scenarioId: scenarioId, categoryId: plan.incomeCategoryId, groupId: plan.groupId,
                accountId: plan.accountId, amount: plan.takeHomeMonthly, frequency: .monthly, start: plan.offerStart,
                anchorDay: plan.anchorDay, note: salaryNote)

        // Pension: employee plus employer contributions a month, keeping the entry's sign.
        if let pension = plan.pension, var copy = try copy(of: pension, db: db, scenarioId: scenarioId),
           copy.endDate.map({ $0 >= plan.startMonth }) ?? true {
            let amount = copy.amountMinorUnits < 0 ? -plan.pensionMonthly : plan.pensionMonthly
            if copy.startDate >= plan.startMonth {
                // Starts within the new job: the copy itself takes the new amount (from the offer's salary on).
                try dropExceptions(db: db, entryId: copy.id!, from: plan.startMonth)
                copy.amountMinorUnits = amount
                if copy.startDate < plan.offerStart {
                    copy.anchorDay = copy.anchorDay ?? utc.component(.day, from: copy.startDate)
                    copy.startDate = plan.offerStart
                    if copy.anchorDay == 1 { copy.anchorDay = nil }
                }
                copy.scenarioChange = .changed
                try copy.update(db)
            } else {
                try endOrRemove(db: db, &copy, before: plan.startMonth)
                if plan.pensionMonthly != 0 {
                    let anchor = pension.anchorDay ?? utc.component(.day, from: pension.startDate)
                    try add(db: db, scenarioId: scenarioId, categoryId: copy.categoryId, groupId: copy.groupId,
                            accountId: copy.accountId, amount: amount, frequency: copy.frequency, start: plan.offerStart,
                            anchorDay: anchor == 1 ? nil : anchor, note: pensionNote, interval: copy.interval)
                }
            }
        }

        for oneOff in plan.spec.oneOffs {
            try add(db: db, scenarioId: scenarioId, categoryId: plan.incomeCategoryId, groupId: plan.groupId,
                    accountId: plan.accountId, amount: oneOff.amountMinorUnits, frequency: .once, start: oneOff.month,
                    anchorDay: nil, note: notePrefix + oneOff.label)
        }
    }

    /// The scenario's copy of a budget entry: its unchanged copy if any, else a changed one; nil when the
    /// scenario has none (a budget entry added since and not yet refreshed in) or removes it.
    private static func copy(of entry: ForecastEntry, db: Database, scenarioId: Int64) throws -> ForecastEntry? {
        let copies = try ForecastEntry.inScenario(db, id: scenarioId).filter { $0.sourceEntryId == entry.id && $0.scenarioChange != .added }
        return copies.first { $0.scenarioChange == nil } ?? copies.first { $0.scenarioChange == .changed }
    }

    /// Ends `copy` the day before `month` (marked `changed`), or, when it doesn't start before `month`,
    /// leaves it as a disabled `removed` tombstone, as `PlannedItemEditing.editFollowing` does. Its
    /// exceptions from `month` on go with the series they belonged to.
    private static func endOrRemove(db: Database, _ copy: inout ForecastEntry, before month: Date) throws {
        try dropExceptions(db: db, entryId: copy.id!, from: month)
        if copy.startDate >= month {
            copy.isEnabled = false
            copy.scenarioChange = .removed
        } else {
            let dayBefore = utc.date(byAdding: .day, value: -1, to: month)!
            copy.endDate = min(copy.endDate ?? dayBefore, dayBefore)
            copy.scenarioChange = .changed
        }
        try copy.update(db)
    }

    private static func dropExceptions(db: Database, entryId: Int64, from date: Date) throws {
        _ = try PlannedOccurrenceException.filter(Column("entryId") == entryId && Column("originalDate") >= date).deleteAll(db)
    }

    /// An `added` confirmed entry in the scenario: in `groupId` when known, else through `PlannedItems.add`
    /// (the Planned group).
    private static func add(db: Database, scenarioId: Int64, categoryId: Int64, groupId: Int64?, accountId: Int64?,
                            amount: Int, frequency: ForecastFrequency, start: Date, anchorDay: Int?, note: String,
                            interval: Int = 1) throws {
        var entry: ForecastEntry
        if let groupId {
            entry = ForecastEntry(groupId: groupId, categoryId: categoryId, amountMinorUnits: amount, frequency: frequency,
                                  interval: interval, startDate: start, endDate: nil, isEnabled: true, status: .confirmed,
                                  note: note, anchorDay: anchorDay, scenarioId: scenarioId, scenarioChange: .added, accountId: accountId)
            try entry.insert(db)
        } else {
            entry = try PlannedItems.add(db: db, categoryId: categoryId, amountMinorUnits: amount, frequency: frequency, interval: interval,
                                         startDate: start, endDate: nil, scenarioId: scenarioId, accountId: accountId)
            entry.note = note
            entry.anchorDay = anchorDay
            try entry.update(db)
        }
    }

    private static func firstOfMonth(_ date: Date) -> Date {
        let (year, month) = MonthRange.components(of: date)
        return utc.date(from: DateComponents(year: year, month: month, day: 1))!
    }
}
