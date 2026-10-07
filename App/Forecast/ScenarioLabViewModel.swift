// App/Forecast/ScenarioLabViewModel.swift
import Foundation
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction
import GRDB

/// The Forecast screen as the scenario lab (spec 2026-10-08-scenario-lab-design.md,
/// "Forecast screen"): the budget and its scenarios, compared over a horizon, with a
/// scenario's differences applied to the budget (and undone) and its plan edited in a grid.
///
/// Everything shown is derived here when its inputs change (a load, the horizon, the compared
/// set, the selection, the grid year), never in a view's `body`: the grid re-renders on its
/// own state changes only, and its horizontal scroll is tracked outside it.
@MainActor
final class ScenarioLabViewModel: ObservableObject {
    /// One net worth forecast line of the Compare chart.
    struct PlanLine: Identifiable, Equatable {
        /// "budget", or "scenario-<id>".
        let id: String
        let name: String
        /// Index into the chart palette: 0 for the Budget, a scenario's position + 1 otherwise.
        let colorIndex: Int
        let forecast: [NetWorthPoint]
    }

    /// One plan's row of the summary table.
    struct SummaryRow: Identifiable, Equatable {
        let id: String
        let name: String
        let isBudget: Bool
        let years: [PlanYearSummary]
    }

    /// A result to show once (refresh report, apply / undo outcome).
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let lines: [String]
    }

    // MARK: Lab state

    @Published private(set) var scenarios: [Scenario] = []
    /// The plan the Differences and Grid tabs show: nil = the Budget.
    @Published var selectedScenarioId: Int64? {
        didSet {
            guard oldValue != selectedScenarioId else { return }
            tickedDifferenceIds = []
            recomputeSelection()
        }
    }
    /// Scenarios drawn on the Compare tab next to the Budget.
    @Published private(set) var comparedIds: Set<Int64> = []
    @Published var horizon: ComparisonHorizon = .default {
        didSet {
            guard oldValue != horizon else { return }
            clampGridYear()
            recomputeComparison()
            recomputeGrid()
        }
    }
    /// The Grid tab's year, one of `gridYears`.
    @Published var gridYear: Int {
        didSet {
            guard oldValue != gridYear else { return }
            recomputeGrid()
        }
    }
    @Published var tickedDifferenceIds: Set<Int64> = []
    @Published var errorMessage: String?
    @Published var notice: Notice?

    // MARK: Loaded data

    @Published private(set) var categories: [Category] = []
    @Published private(set) var categoryGroups: [CategoryGroup] = []
    @Published private(set) var payCalendar = PayCalendar(salaryDates: [], manualCloses: [], today: Date())
    @Published private(set) var today = Date()
    private var transactions: [Transaction] = []
    private var accounts: [Account] = []
    private var snapshots: [BalanceSnapshot] = []
    private var rate = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
    private var groups: [ForecastGroup] = []
    private var budgetPlan = PlanInput(entries: [], exceptions: [], groups: [])
    private var scenarioPlans: [Int64: PlanInput] = [:]
    /// The first load compares every scenario; later loads keep the user's choice.
    private var hasLoaded = false

    // MARK: Derived

    /// The actual net worth months, shared by every plan.
    @Published private(set) var actualLine: [NetWorthPoint] = []
    @Published private(set) var lines: [PlanLine] = []
    @Published private(set) var summaries: [SummaryRow] = []
    /// The selected scenario's differences (empty for the Budget).
    @Published private(set) var differences: [ScenarioDifference] = []
    @Published private(set) var canUndo = false
    /// The selected scenario's differences applied by an un-undone apply: shown as
    /// "Applied", not tickable.
    @Published private(set) var appliedDifferenceIds: Set<Int64> = []
    /// The selected plan's cells for `gridYear`, by category id then month.
    @Published private(set) var gridCells: [Int64: [Int: ScenarioGridCell]] = [:]

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
        _gridYear = Published(initialValue: MonthRange.components(of: Date()).year)
    }

    var selectedScenario: Scenario? { scenarios.first { $0.id == selectedScenarioId } }

    /// The Grid tab's years: today's to the horizon's.
    var gridYears: [Int] { horizon.years(today: today) }

    var reserves: [Category] { categories.filter(\.isReserved).sorted { $0.name < $1.name } }

    /// The scope edits go to: the selected scenario (nil while the Budget is selected, which
    /// the lab shows read-only).
    var editScope: PlanScope? {
        guard let scenario = selectedScenario, let id = scenario.id else { return nil }
        return .scenario(id: id, name: scenario.name)
    }

    // MARK: Loading

    func load() {
        do {
            try read()
        } catch {
            errorMessage = "Couldn't load the forecast: \(error.localizedDescription)"
            return
        }
        recomputeComparison()
        recomputeSelection()
    }

    /// Everything the lab reads, in one database read.
    private struct Loaded {
        var manualCloses: [PayMonthClose]
        var categories: [Category]
        var categoryGroups: [CategoryGroup]
        var transactions: [Transaction]
        var accounts: [Account]
        var snapshots: [BalanceSnapshot]
        var rate: ExchangeRateSetting
        var groups: [ForecastGroup]
        var scenarios: [Scenario]
        var budgetPlan: PlanInput
        var scenarioPlans: [Int64: PlanInput]
    }

    private func read() throws {
        let loaded = try dbQueue.read { db -> Loaded in
            let groups = try ForecastGroup.fetchAll(db)
            let scenarios = try Scenario.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
            let exceptions = Dictionary(grouping: try PlannedOccurrenceException.fetchAll(db), by: \.entryId)
            func plan(_ entries: [ForecastEntry]) -> PlanInput {
                PlanInput(entries: entries, exceptions: entries.flatMap { exceptions[$0.id!] ?? [] }, groups: groups)
            }
            var plans: [Int64: PlanInput] = [:]
            for scenario in scenarios {
                plans[scenario.id!] = plan(try ForecastEntry.inScenario(db, id: scenario.id!))
            }
            return Loaded(manualCloses: try PayMonthClose.fetchAll(db), categories: try Category.fetchAll(db),
                          categoryGroups: try CategoryGroup.fetchAll(db), transactions: try Transaction.fetchAll(db),
                          accounts: try Account.fetchAll(db), snapshots: try BalanceSnapshot.fetchAll(db),
                          rate: try ExchangeRateSetting.currentOrDefault(db: db), groups: groups, scenarios: scenarios,
                          budgetPlan: plan(try ForecastEntry.budget(db)), scenarioPlans: plans)
        }
        categories = loaded.categories
        categoryGroups = loaded.categoryGroups
        transactions = loaded.transactions
        accounts = loaded.accounts
        snapshots = loaded.snapshots
        rate = loaded.rate
        groups = loaded.groups
        scenarios = loaded.scenarios
        budgetPlan = loaded.budgetPlan
        scenarioPlans = loaded.scenarioPlans
        today = Date()
        // As the Dashboard builds it: today never earlier than the latest transaction.
        payCalendar = PayCalendar.forData(transactions: transactions, categories: categories, manualCloses: loaded.manualCloses, today: today)
        let ids = Set(scenarios.compactMap(\.id))
        if !hasLoaded {
            comparedIds = ids
            hasLoaded = true
        } else {
            comparedIds.formIntersection(ids)
        }
        if let selected = selectedScenarioId, !ids.contains(selected) { selectedScenarioId = nil }
        clampGridYear()
    }

    private func clampGridYear() {
        let years = gridYears
        if !years.contains(gridYear) { gridYear = years.contains(MonthRange.components(of: today).year) ? MonthRange.components(of: today).year : (years.first ?? gridYear) }
    }

    private var comparisonData: ComparisonData {
        let end = horizon.endMonth(today: today)
        return ComparisonData(today: today, accounts: accounts, snapshots: snapshots, transactions: transactions, categories: categories,
                              rate: rate, payCalendar: payCalendar, horizonYear: end.year, horizonMonth: end.month)
    }

    /// The selected plan's entries and exceptions (the Budget's when none is selected).
    private var selectedPlan: PlanInput {
        selectedScenarioId.flatMap { scenarioPlans[$0] } ?? budgetPlan
    }

    // MARK: Derivations

    private func recomputeComparison() {
        let data = comparisonData
        let budgetSeries = ScenarioComparison.netWorthSeries(data, plan: budgetPlan)
        var newLines = [PlanLine(id: "budget", name: "Budget", colorIndex: 0, forecast: budgetSeries.forecast)]
        // Each plan's net worth series once, shared by its chart line and its summary row.
        var rows = [SummaryRow(id: "budget", name: "Budget", isBudget: true,
                               years: ScenarioComparison.yearSummaries(data, plan: budgetPlan, series: budgetSeries, budgetSeries: budgetSeries))]
        for (index, scenario) in scenarios.enumerated() {
            guard let id = scenario.id, comparedIds.contains(id), let plan = scenarioPlans[id] else { continue }
            let series = ScenarioComparison.netWorthSeries(data, plan: plan)
            newLines.append(PlanLine(id: "scenario-\(id)", name: scenario.name, colorIndex: index + 1, forecast: series.forecast))
            rows.append(SummaryRow(id: "scenario-\(id)", name: scenario.name, isBudget: false,
                                   years: ScenarioComparison.yearSummaries(data, plan: plan, series: series, budgetSeries: budgetSeries)))
        }
        actualLine = budgetSeries.actual
        lines = newLines
        summaries = rows
    }

    private func recomputeSelection() {
        if let id = selectedScenarioId {
            do {
                (differences, canUndo, appliedDifferenceIds) = try dbQueue.read { db in
                    (try Scenarios.differences(db: db, scenarioId: id), try ScenarioApply.canUndo(db: db, scenarioId: id),
                     try ScenarioApply.appliedDifferenceIds(db: db, scenarioId: id))
                }
            } catch {
                differences = []
                canUndo = false
                appliedDifferenceIds = []
                errorMessage = "Couldn't read this scenario's differences: \(error.localizedDescription)"
            }
        } else {
            differences = []
            canUndo = false
            appliedDifferenceIds = []
        }
        tickedDifferenceIds.formIntersection(tickableDifferences.map(\.id))
        recomputeGrid()
    }

    private func recomputeGrid() {
        gridCells = ScenarioComparison.gridCells(comparisonData, scenario: selectedPlan, budget: budgetPlan, year: gridYear)
    }

    // MARK: Comparing

    func isCompared(_ scenario: Scenario) -> Bool {
        scenario.id.map(comparedIds.contains) ?? false
    }

    func setCompared(_ scenario: Scenario, _ compared: Bool) {
        guard let id = scenario.id else { return }
        if compared { comparedIds.insert(id) } else { comparedIds.remove(id) }
        recomputeComparison()
    }

    // MARK: Scenario operations

    /// A new scenario copying the budget, then selected and compared.
    func createScenario(name: String) -> SaveOutcome {
        var created: Scenario?
        let outcome = perform { db in created = try Scenarios.create(db: db, name: name) }
        if outcome == .saved, let id = created?.id { show(id) }
        return outcome
    }

    func duplicate(_ scenario: Scenario, name: String) -> SaveOutcome {
        guard let id = scenario.id else { return .failed("This scenario no longer exists.") }
        var created: Scenario?
        let outcome = perform { db in created = try Scenarios.duplicate(db: db, scenarioId: id, name: name) }
        if outcome == .saved, let newId = created?.id { show(newId) }
        return outcome
    }

    func rename(_ scenario: Scenario, to name: String) -> SaveOutcome {
        guard let id = scenario.id else { return .failed("This scenario no longer exists.") }
        return perform { db in try Scenarios.rename(db: db, scenarioId: id, to: name) }
    }

    func delete(_ scenario: Scenario) {
        guard let id = scenario.id else { return }
        if case .failed(let message) = perform({ db in try Scenarios.delete(db: db, scenarioId: id) }) { errorMessage = message }
    }

    /// "Refresh from budget", then the report as a notice.
    func refresh(_ scenario: Scenario) {
        guard let id = scenario.id else { return }
        var report = RefreshReport()
        if case .failed(let message) = perform({ db in report = try Scenarios.refresh(db: db, scenarioId: id) }) {
            errorMessage = message
            return
        }
        notice = Notice(title: "“\(scenario.name)” refreshed from the budget", lines: Self.lines(for: report))
    }

    static func lines(for report: RefreshReport) -> [String] {
        var lines: [String] = []
        if report.reapplied.isEmpty && report.couldNotReapply.isEmpty {
            lines.append("The budget was copied again. The scenario had no changes to re-apply.")
        }
        if !report.reapplied.isEmpty { lines.append("Re-applied: \(report.reapplied.joined(separator: ", "))") }
        lines += report.couldNotReapply
        if !report.sourceChanged.isEmpty {
            lines.append("Changed in the budget since the copy (check them): \(report.sourceChanged.joined(separator: ", "))")
        }
        return lines
    }

    // MARK: Apply and undo

    /// The differences not yet applied (by an un-undone apply), in list order.
    var tickableDifferences: [ScenarioDifference] {
        differences.filter { !appliedDifferenceIds.contains($0.id) }
    }

    /// The ticked differences, in list order.
    var tickedDifferences: [ScenarioDifference] {
        differences.filter { tickedDifferenceIds.contains($0.id) }
    }

    /// Applies the ticked differences to the budget from the current pay month, then shows
    /// what wasn't applied (or "Nothing to apply").
    func applyTicked() {
        // Reload first: the pay calendar (so the boundary) and the budget as they are now.
        do {
            try read()
        } catch {
            errorMessage = "Couldn't reload the forecast before applying: \(error.localizedDescription)"
            return
        }
        recomputeComparison()
        recomputeSelection()
        guard let scenario = selectedScenario, let id = scenario.id else { return }
        let ids = tickedDifferences.map(\.id)
        guard !ids.isEmpty else { return }
        var application: ScenarioApplication?
        let calendar = payCalendar
        if case .failed(let message) = perform({ db in application = try ScenarioApply.apply(db: db, scenarioId: id, differenceIds: ids, calendar: calendar) }) {
            errorMessage = message
            return
        }
        tickedDifferenceIds = []
        guard let application else { return }
        if application.appliedNothing {
            notice = Notice(title: "Nothing to apply", lines: application.skipped)
        } else {
            let applied = application.decodedJournal?.operations.count ?? ids.count
            let skipped = application.skipped
            notice = Notice(title: "Applied \(applied) item\(applied == 1 ? "" : "s") to the budget",
                            lines: skipped.isEmpty ? ["They're ordinary planned items now: edit them in the Budget grid."] : ["Not applied:"] + skipped)
        }
    }

    func undoLastApply() {
        guard let id = selectedScenarioId else { return }
        var report = UndoReport()
        if case .failed(let message) = perform({ db in report = try ScenarioApply.undoLast(db: db, scenarioId: id) }) {
            errorMessage = message
            return
        }
        var lines: [String] = []
        if !report.restored.isEmpty { lines.append("Restored: \(report.restored.joined(separator: ", "))") }
        lines += report.warnings
        notice = Notice(title: "Undid the last apply", lines: lines)
    }

    // MARK: Editing a scenario's plan

    /// The selected scenario's effective plan (`ForecastCalculator.planEntries`).
    var scenarioPlanEntries: [ForecastEntry] {
        guard let id = selectedScenarioId, let plan = scenarioPlans[id] else { return [] }
        return ForecastCalculator.planEntries(entries: plan.entries, groups: plan.groups)
    }

    /// The selected scenario's occurrences under `category` in the calendar month (empty for
    /// the Budget, which the lab doesn't edit). Only closed months lock a scenario occurrence.
    func occurrences(category: Category, year: Int, month: Int) -> [PlannedRow] {
        guard let categoryId = category.id, let id = selectedScenarioId, let plan = scenarioPlans[id] else { return [] }
        return PlannedRow.rows(categoryId: categoryId, year: year, month: month, plan: scenarioPlanEntries, exceptions: plan.exceptions) { entry, occurrence in
            PlannedItemEditing.isLocked(entry: entry, occurrence: occurrence, calendar: payCalendar, monthTotals: [:],
                                        entries: budgetPlan.entries, groups: groups, exceptions: budgetPlan.exceptions, categories: categories)
        }
    }

    var planEditActions: PlanEditActions {
        PlanEditActions(
            editOccurrence: { [unowned self] occurrence, change in
                perform { [payCalendar] db in
                    try PlannedItemEditing.editOccurrence(db: db, entryId: occurrence.entryId, originalDate: occurrence.originalDate, change: change, calendar: payCalendar)
                }
            },
            editFollowing: { [unowned self] occurrence, change in
                perform { [payCalendar] db in
                    try PlannedItemEditing.editFollowing(db: db, entryId: occurrence.entryId, originalDate: occurrence.originalDate, change: change, calendar: payCalendar)
                }
            })
    }

    /// A new item in the selected scenario (`PlannedItems.add(…, scenarioId:)`).
    func addPlannedItem(_ category: PlannedItemCategory, type: CategoryType, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date?) -> SaveOutcome {
        guard let scenarioId = selectedScenarioId else { return .failed("Select a scenario to add items to it.") }
        return perform { db in
            switch category {
            case .existing(let id):
                _ = try PlannedItems.add(db: db, categoryId: id, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, startDate: startDate, endDate: endDate, scenarioId: scenarioId)
            case .new(let name):
                _ = try PlannedItems.add(db: db, newCategoryName: name, type: type, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, startDate: startDate, endDate: endDate, scenarioId: scenarioId)
            }
        }
    }

    /// A reserve allowance in the selected scenario (`ReservedCategories.addAllowance`); a new
    /// reserve is a global category, created in the same write.
    func addReserveAllowance(_ target: ReserveTarget, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date?) -> SaveOutcome {
        guard let scenarioId = selectedScenarioId else { return .failed("Select a scenario to add allowances to it.") }
        return perform { db in
            let reserveId: Int64
            switch target {
            case .existing(let reserve):
                guard let id = reserve.id else { throw ReservedCategoryError.notReserved }
                reserveId = id
            case .new(let name):
                reserveId = try ReservedCategories.create(db: db, name: name).id!
            }
            _ = try ReservedCategories.addAllowance(db: db, reserveId: reserveId, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, startDate: startDate, endDate: endDate, scenarioId: scenarioId)
        }
    }

    // MARK: Helpers

    /// Selects and compares a just-created scenario (after the reload that fetched it).
    private func show(_ id: Int64) {
        comparedIds.insert(id)
        selectedScenarioId = id
        recomputeComparison()
    }

    /// Write first, then reload. A failed write returns `.failed` with a message for the
    /// sheet; a failed reload after a successful write returns `.savedButReloadFailed` with a
    /// "Saved, but …" banner, so the sheet closes instead of inviting a retry.
    private func perform(_ write: (Database) throws -> Void) -> SaveOutcome {
        errorMessage = nil
        do {
            try dbQueue.write { db in try write(db) }
        } catch {
            return .failed(PlanFormat.errorMessage(for: error))
        }
        do {
            try read()
        } catch {
            errorMessage = "Saved, but couldn't reload the forecast: \(error.localizedDescription)"
            return .savedButReloadFailed
        }
        recomputeComparison()
        recomputeSelection()
        return .saved
    }
}
