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
/// Each tab keeps its own scenario choice (spec 2026-10-08-scenario-lab-tabs-design.md,
/// "Forecast screen layout"): `compareSelection`, `differencesSelection` and `gridSelection`.
///
/// Everything shown is derived here when its inputs change (a load, the horizon, a tab's
/// selection, the grid year), never in a view's `body`: the grid re-renders on its
/// own state changes only, and its horizontal scroll is tracked outside it. The comparison
/// (chart lines and summary) is computed off the main actor from value-type inputs; a newer
/// computation cancels the one in flight.
@MainActor
final class ScenarioLabViewModel: ObservableObject, GridCellPanelModel {
    /// One net worth forecast line of the Compare chart.
    struct PlanLine: Identifiable, Equatable, Sendable {
        /// "budget", or "scenario-<id>".
        let id: String
        let name: String
        /// Index into the chart palette: 0 for the Budget, a scenario's position + 1 otherwise.
        let colorIndex: Int
        let forecast: [NetWorthPoint]
    }

    /// One plan's row of the summary table.
    struct SummaryRow: Identifiable, Equatable, Sendable {
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
    /// The lab's open tab; a created or duplicated scenario switches it to the Grid.
    @Published var tab: ScenarioLabView.Tab = .compare

    /// Scenarios ticked on the Compare tab, drawn next to the Budget (always drawn).
    @Published var compareSelection: Set<Int64> = [] {
        didSet {
            guard oldValue != compareSelection, !isReading else { return }
            recomputeComparison()
        }
    }
    /// Scenarios ticked on the Differences tab (the Budget is always its first column).
    @Published var differencesSelection: Set<Int64> = [] {
        didSet {
            guard oldValue != differencesSelection, !isReading else { return }
            recomputeDifferences()
        }
    }
    /// The plan the Grid tab shows: nil = the Budget (read-only).
    @Published var gridSelection: Int64? {
        didSet {
            guard oldValue != gridSelection, !isReading else { return }
            recomputeGrid()
            recomputeYearEnds()
        }
    }
    @Published var horizon: ComparisonHorizon = .default {
        didSet {
            guard oldValue != horizon else { return }
            clampGridYear()
            recomputeComparison()
            recomputeGrid()
            yearEndsCache = [:]
            lastYearEndsKey = nil
            recomputeYearEnds()
        }
    }
    /// The Grid tab's selected years (`YearSelection`: sorted, never empty), all among
    /// `gridYears`: one shows its months, several their year totals side by side.
    @Published private(set) var gridSelectedYears: [Int]
    /// The Grid tab's first selected year: the one whose months show while only one is selected.
    var gridYear: Int { gridSelectedYears[0] }
    /// The Differences tab's ticked cells (scenario entry ids, unique across scenarios); at
    /// most one per row (`setTicked`).
    @Published var tickedDifferenceIds: Set<Int64> = []
    @Published var errorMessage: String?
    @Published var notice: Notice?

    // MARK: Loaded data

    @Published private(set) var categories: [Category] = []
    @Published private(set) var categoryGroups: [CategoryGroup] = []
    @Published private(set) var payCalendar = PayCalendar(salaryDates: [], manualCloses: [], today: Date())
    @Published private(set) var today = Date()
    /// Every transaction (net worth); `transferLinks` keeps the actuals budget-facing.
    private var transactions: [Transaction] = []
    private var transferLinks: [TransferLink] = []
    private var accounts: [Account] = []
    /// The planned item sheets' Account picker; rebuilt on load.
    private(set) var accountOptions: PlanAccountOptions = .none
    private var snapshots: [BalanceSnapshot] = []
    private var rate = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
    private var groups: [ForecastGroup] = []
    private var budgetPlan = PlanInput(entries: [], exceptions: [], groups: [])
    private var scenarioPlans: [Int64: PlanInput] = [:]
    /// The first load ticks every scenario in Compare and Differences; later loads keep the
    /// user's choice.
    private var hasLoaded = false
    /// True while `read()` prunes the selections: their recomputations run once after it.
    private var isReading = false

    // MARK: Derived

    /// The actual net worth months, shared by every plan.
    @Published private(set) var actualLine: [NetWorthPoint] = []
    @Published private(set) var lines: [PlanLine] = []
    @Published private(set) var summaries: [SummaryRow] = []
    /// True while the comparison is being computed (the previous results stay shown).
    @Published private(set) var isComputingComparison = false
    private var comparisonTask: Task<Void, Never>?
    /// The Differences tab's scenario columns: the ticked scenarios, in list order.
    @Published private(set) var differencesScenarios: [Scenario] = []
    /// The Differences tab's rows (`DifferenceMatrix`) for `differencesScenarios`.
    @Published private(set) var differenceRows: [DifferenceMatrix.Row] = []
    /// Differences applied by an un-undone apply (any ticked scenario's): shown as "Applied",
    /// not tickable.
    @Published private(set) var appliedDifferenceIds: Set<Int64> = []
    /// The ticked scenarios with an apply to undo, in list order.
    @Published private(set) var undoableScenarios: [Scenario] = []
    /// By scenario entry id: an added / changed difference's first occurrence in an open pay
    /// month, which its Edit… opens. Missing = no Edit….
    @Published private(set) var editableOccurrences: [Int64: PlannedRow] = [:]
    /// By scenario id: the budget entries it holds an unchanged copy of (a row's cell shows
    /// the budget's version there; "—" when the scenario doesn't have the item).
    @Published private(set) var unchangedCopies: [Int64: Set<Int64>] = [:]
    /// The Grid tab's plan for each selected year (`ScenarioComparison.grid`): its cells by
    /// category id then month, and its Totals block.
    @Published private(set) var yearGrids: [Int: ScenarioGrid] = [:]
    /// The Grid tab's plan for `gridYear`.
    var grid: ScenarioGrid { yearGrids[gridYear] ?? .empty }
    /// The Grid tab's plan's cells for `gridYear`, by category id then month.
    var gridCells: [Int64: [Int: ScenarioGridCell]] { grid.cells }
    /// Each plan's grid by plan (0 = the Budget) and year, so switching the Grid tab's plan or
    /// year back is instant; emptied by every load.
    private var gridCache: [String: ScenarioGrid] = [:]
    /// The Grid tab's plan's net worth at each year's end (`ScenarioComparison.yearEndNetWorths`),
    /// for the year cards: from the year before today's to the horizon's.
    @Published private(set) var gridYearEnds: [Int: Int] = [:]
    /// `gridYearEnds` by plan (0 = the Budget); emptied by every load and horizon change.
    private var yearEndsCache: [Int64: [Int: Int]] = [:]
    private var yearEndsTask: Task<Void, Never>?
    /// The plan (0 = the Budget) `gridYearEnds` currently shows; nil after a horizon change.
    private var lastYearEndsKey: Int64?
    /// Each plan's effective entries (`ForecastCalculator.planEntries`) by plan (0 = the
    /// Budget): the occurrences' plan, asked for every category by a Totals panel; emptied by
    /// every load.
    private var planEntriesCache: [Int64: [ForecastEntry]] = [:]
    /// The actuals every plan's grid shares (`ScenarioComparison.gridActuals`), rebuilt on load:
    /// the side panel's transactions and the Totals block's counted transfers.
    private var gridActuals = ScenarioGridActuals.empty
    /// Linked transfers' other legs by transaction id, for the side panel.
    @Published private(set) var transferCounterparts: [Int64: [TransferCounterpart]] = [:]

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
        _gridSelectedYears = Published(initialValue: [MonthRange.components(of: Date()).year])
    }

    /// A comparison still computing when the lab goes away is cancelled.
    isolated deinit {
        comparisonTask?.cancel()
        yearEndsTask?.cancel()
    }

    /// The Grid tab's scenario (nil while the Budget is selected).
    var gridScenario: Scenario? { scenarios.first { $0.id == gridSelection } }

    /// A plan's chart series index (`Theme.series`): 0 for the Budget (nil), a scenario's position + 1.
    func colorIndex(of scenarioId: Int64?) -> Int {
        guard let scenarioId, let index = scenarios.firstIndex(where: { $0.id == scenarioId }) else { return 0 }
        return index + 1
    }

    /// The Grid tab's years: today's to the horizon's.
    var gridYears: [Int] { horizon.years(today: today) }

    var reserves: [Category] { categories.filter(\.isReserved).sorted { $0.name < $1.name } }

    /// The scope the Grid tab's edits go to: its scenario (nil while the Budget is selected,
    /// which the lab shows read-only).
    var editScope: PlanScope? {
        guard let scenario = gridScenario, let id = scenario.id else { return nil }
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
        recomputeDifferences()
        recomputeGrid()
        recomputeYearEnds()
    }

    /// Everything the lab reads, in one database read.
    private struct Loaded {
        var manualCloses: [PayMonthClose]
        var categories: [Category]
        var categoryGroups: [CategoryGroup]
        var transactions: [Transaction]
        var transferLinks: [TransferLink]
        var transferCounterparts: [Int64: [TransferCounterpart]]
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
                          transferLinks: try TransferLink.fetchAll(db), transferCounterparts: try TransferLinks.counterparts(db: db), accounts: try Account.fetchAll(db), snapshots: try BalanceSnapshot.fetchAll(db),
                          rate: try ExchangeRateSetting.currentOrDefault(db: db), groups: groups, scenarios: scenarios,
                          budgetPlan: plan(try ForecastEntry.budget(db)), scenarioPlans: plans)
        }
        categories = loaded.categories
        categoryGroups = loaded.categoryGroups
        transactions = loaded.transactions
        transferLinks = loaded.transferLinks
        transferCounterparts = loaded.transferCounterparts
        accounts = loaded.accounts
        snapshots = loaded.snapshots
        rate = loaded.rate
        conversion = CurrencyConversion(accounts: accounts, rate: rate)
        groups = loaded.groups
        scenarios = loaded.scenarios
        budgetPlan = loaded.budgetPlan
        scenarioPlans = loaded.scenarioPlans
        today = Date()
        // As the Dashboard builds it: today never earlier than the latest transaction.
        payCalendar = PayCalendar.forData(transactions: transactions, categories: categories, manualCloses: loaded.manualCloses, today: today)
        gridActuals = ScenarioComparison.gridActuals(comparisonData)
        gridCache = [:]
        yearEndsCache = [:]
        planEntriesCache = [:]
        categoryById = Dictionary(categories.compactMap { category in category.id.map { ($0, category) } }, uniquingKeysWith: { a, _ in a })
        categoryNameById = categoryById.mapValues(\.name)
        accountNameById = Dictionary(accounts.compactMap { account in account.id.map { ($0, account.displayName) } }, uniquingKeysWith: { a, _ in a })
        // Planned items' accounts for the Account picker (spec 2026-10-15 §2), as the Budget infers them.
        accountOptions = PlanAccountOptions(accounts: accounts.sortedForDisplay(),
                                            itemAccounts: PlannedItemAccounts(categories: categories, budgetTransactions: TransferLinks.budgetFacing(transactions, links: transferLinks), calendar: payCalendar,
                                                                                mainAccountId: accounts.mainAccountId))
        // A deleted scenario leaves every tab's selection; the callers recompute after.
        let ids = Set(scenarios.compactMap(\.id))
        isReading = true
        defer { isReading = false }
        if !hasLoaded {
            compareSelection = ids
            differencesSelection = ids
            hasLoaded = true
        } else {
            compareSelection.formIntersection(ids)
            differencesSelection.formIntersection(ids)
        }
        if let selected = gridSelection, !ids.contains(selected) { gridSelection = nil }
        clampGridYear()
    }

    private func clampGridYear() {
        let clamped = YearSelection.clamped(gridSelectedYears, to: gridYears, preferred: MonthRange.components(of: today).year)
        if clamped != gridSelectedYears { gridSelectedYears = clamped }
    }

    /// A plain click on a Grid year card: shows just that year.
    func selectGridYear(_ year: Int) {
        guard gridSelectedYears != [year] else { return }
        gridSelectedYears = [year]
        recomputeGrid()
    }

    /// A ⌘-click on a Grid year card: adds or removes the year (the last one stays).
    func toggleGridYear(_ year: Int) {
        let toggled = YearSelection.toggled(gridSelectedYears, year)
        guard toggled != gridSelectedYears else { return }
        gridSelectedYears = toggled
        recomputeGrid()
    }

    private var comparisonData: ComparisonData {
        let end = horizon.endMonth(today: today)
        return ComparisonData(today: today, accounts: accounts, snapshots: snapshots, transactions: transactions, transferLinks: transferLinks, categories: categories,
                              rate: rate, payCalendar: payCalendar, horizonYear: end.year, horizonMonth: end.month)
    }

    /// The Grid tab's plan's entries and exceptions (the Budget's when none is selected).
    private var gridPlan: PlanInput {
        gridSelection.flatMap { scenarioPlans[$0] } ?? budgetPlan
    }

    // MARK: Derivations

    /// A compared scenario, as the comparison computation takes it.
    private struct ComparedPlan: Sendable {
        let id: Int64
        let name: String
        let colorIndex: Int
        let plan: PlanInput
    }

    private struct ComparisonResult: Sendable {
        let actualLine: [NetWorthPoint]
        let lines: [PlanLine]
        let summaries: [SummaryRow]
    }

    /// Starts computing the comparison off the main actor, cancelling any computation still
    /// running; its results are published on the main actor unless a newer one started.
    private func recomputeComparison() {
        comparisonTask?.cancel()
        let data = comparisonData
        let budget = budgetPlan
        let compared: [ComparedPlan] = scenarios.enumerated().compactMap { index, scenario in
            guard let id = scenario.id, compareSelection.contains(id), let plan = scenarioPlans[id] else { return nil }
            return ComparedPlan(id: id, name: scenario.name, colorIndex: index + 1, plan: plan)
        }
        isComputingComparison = true
        comparisonTask = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) { Self.computeComparison(data, budget: budget, compared: compared) }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let result, let self else { return }
            actualLine = result.actualLine
            lines = result.lines
            summaries = result.summaries
            isComputingComparison = false
        }
    }

    /// Chart lines and summary rows for the Budget and the compared scenarios: the actual
    /// line once for every plan, each plan's series once (shared by its line and its row).
    /// Nil when cancelled.
    nonisolated private static func computeComparison(_ data: ComparisonData, budget: PlanInput, compared: [ComparedPlan]) -> ComparisonResult? {
        let actuals = ScenarioComparison.actuals(data)
        let budgetSeries = ScenarioComparison.netWorthSeries(data, plan: budget, actuals: actuals)
        var lines = [PlanLine(id: "budget", name: "Budget", colorIndex: 0, forecast: budgetSeries.forecast)]
        var rows = [SummaryRow(id: "budget", name: "Budget", isBudget: true,
                               years: ScenarioComparison.yearSummaries(data, plan: budget, series: budgetSeries, budgetSeries: budgetSeries))]
        for scenario in compared {
            if Task.isCancelled { return nil }
            let series = ScenarioComparison.netWorthSeries(data, plan: scenario.plan, actuals: actuals)
            lines.append(PlanLine(id: "scenario-\(scenario.id)", name: scenario.name, colorIndex: scenario.colorIndex, forecast: series.forecast))
            rows.append(SummaryRow(id: "scenario-\(scenario.id)", name: scenario.name, isBudget: false,
                                   years: ScenarioComparison.yearSummaries(data, plan: scenario.plan, series: series, budgetSeries: budgetSeries)))
        }
        return Task.isCancelled ? nil : ComparisonResult(actualLine: budgetSeries.actual, lines: lines, summaries: rows)
    }

    /// Loads the ticked scenarios' differences into the Differences matrix, with what each
    /// cell offers (applied, Edit…, the budget's version); ticks no longer tickable are dropped.
    private func recomputeDifferences() {
        let ticked = scenarios.filter { $0.id.map(differencesSelection.contains) ?? false }
        differencesScenarios = ticked
        do {
            let loaded = try dbQueue.read { db in
                try ticked.compactMap(\.id).map { id in
                    (id: id, differences: try Scenarios.differences(db: db, scenarioId: id),
                     canUndo: try ScenarioApply.canUndo(db: db, scenarioId: id),
                     applied: try ScenarioApply.appliedDifferenceIds(db: db, scenarioId: id))
                }
            }
            differenceRows = DifferenceMatrix.rows(differences: loaded.map { (scenarioId: $0.id, differences: $0.differences) })
            appliedDifferenceIds = loaded.reduce(into: Set<Int64>()) { $0.formUnion($1.applied) }
            let undoable = Set(loaded.filter(\.canUndo).map(\.id))
            undoableScenarios = ticked.filter { $0.id.map(undoable.contains) ?? false }
        } catch {
            differenceRows = []
            appliedDifferenceIds = []
            undoableScenarios = []
            errorMessage = "Couldn't read the scenarios' differences: \(error.localizedDescription)"
        }
        var copies: [Int64: Set<Int64>] = [:]
        for id in ticked.compactMap(\.id) {
            copies[id] = Set(scenarioPlans[id]?.entries.filter { $0.scenarioChange == nil }.compactMap(\.sourceEntryId) ?? [])
        }
        unchangedCopies = copies
        editableOccurrences = firstOpenOccurrences()
        tickedDifferenceIds.formIntersection(tickableDifferenceIds)
    }

    /// Each added / changed, not applied cell's first occurrence in an open (not closed) pay
    /// month (only closed months lock a scenario occurrence), searched from its series' start
    /// to its end, or two years past today (its start, if later) for an open-ended series.
    private func firstOpenOccurrences() -> [Int64: PlannedRow] {
        var result: [Int64: PlannedRow] = [:]
        for row in differenceRows {
            for (scenarioId, difference) in row.cells where difference.kind != .removed && !appliedDifferenceIds.contains(difference.id) {
                guard let plan = scenarioPlans[scenarioId],
                      let entry = ForecastCalculator.planEntries(entries: plan.entries.filter { $0.id == difference.id }, groups: plan.groups).first
                else { continue }
                guard let end = entry.endDate ?? MonthRange.calendar.date(byAdding: .year, value: 2, to: max(entry.startDate, today)),
                      entry.startDate <= end
                else { continue }
                let first = PlannedOccurrences.occurrences(entries: [entry], exceptions: plan.exceptions.filter { $0.entryId == difference.id },
                                                           in: PayPeriod(startDate: entry.startDate, endDate: end, type: .projected))
                    .filter { occurrence in
                        let (year, month) = MonthRange.components(of: occurrence.date)
                        return !payCalendar.isClosed(PayMonth(year: year, month: month))
                    }
                    .min { $0.date < $1.date }
                if let first { result[difference.id] = PlannedRow(occurrence: first, isConfirmed: false, entry: entry) }
            }
        }
        return result
    }

    private func recomputeGrid() {
        var grids: [Int: ScenarioGrid] = [:]
        for year in gridSelectedYears {
            let key = "\(gridSelection ?? 0)-\(year)"
            if let cached = gridCache[key] {
                grids[year] = cached
            } else {
                let computed = ScenarioComparison.grid(comparisonData, actuals: gridActuals, scenario: gridPlan, budget: budgetPlan, year: year)
                gridCache[key] = computed
                grids[year] = computed
            }
        }
        yearGrids = grids
    }

    /// Works out the Grid tab's plan's year-end net worths off the main actor (cached per plan),
    /// cancelling any computation still running.
    private func recomputeYearEnds() {
        yearEndsTask?.cancel()
        let key = gridSelection ?? 0
        if let cached = yearEndsCache[key] {
            gridYearEnds = cached
            lastYearEndsKey = key
            return
        }
        // Another plan's (or another horizon's) figures must never show while this one's compute.
        if lastYearEndsKey != key {
            gridYearEnds = [:]
            lastYearEndsKey = key
        }
        let data = comparisonData
        let plan = gridPlan
        yearEndsTask = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) { () -> [Int: Int]? in
                let series = ScenarioComparison.netWorthSeries(data, plan: plan, actuals: ScenarioComparison.actuals(data))
                return Task.isCancelled ? nil : ScenarioComparison.yearEndNetWorths(data, series: series)
            }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let result, let self else { return }
            yearEndsCache[key] = result
            gridYearEnds = result
        }
    }

    /// `year`'s year-end net worth less the previous year's on the Grid tab's plan, in minor
    /// units; nil when either is missing.
    func gridYearEndChange(_ year: Int) -> Int? {
        guard let value = gridYearEnds[year], let previous = gridYearEnds[year - 1] else { return nil }
        return value - previous
    }

    /// `gridYearEndChange` as a fraction of the previous year-end's magnitude; nil when either
    /// is missing or the previous is zero.
    func gridYearEndChangePercent(_ year: Int) -> Double? {
        guard let value = gridYearEnds[year], let previous = gridYearEnds[year - 1], previous != 0 else { return nil }
        return Double(value - previous) / Double(abs(previous))
    }

    // MARK: Scenario operations

    /// A new scenario copying the budget, then ticked in Compare and Differences and opened in the Grid.
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

    // MARK: Differences: tick, apply, undo, revert

    /// The cells that can be ticked: every difference not yet applied.
    private var tickableDifferenceIds: Set<Int64> {
        Set(differenceRows.flatMap { $0.cells.values.map(\.id) }).subtracting(appliedDifferenceIds)
    }

    /// Ticks or unticks a cell; ticking unticks the row's other cells, so two versions of one
    /// budget item never go to the budget together.
    func setTicked(_ ticked: Bool, _ difference: ScenarioDifference, in row: DifferenceMatrix.Row) {
        if ticked {
            tickedDifferenceIds.subtract(row.cells.values.map(\.id))
            tickedDifferenceIds.insert(difference.id)
        } else {
            tickedDifferenceIds.remove(difference.id)
        }
    }

    /// The ticked differences by scenario, in column then row order (scenarios with none left out).
    var tickedByScenario: [(scenario: Scenario, differences: [ScenarioDifference])] {
        differencesScenarios.compactMap { scenario in
            guard let id = scenario.id else { return nil }
            let ticked = differenceRows.compactMap { $0.cells[id] }.filter { tickedDifferenceIds.contains($0.id) }
            return ticked.isEmpty ? nil : (scenario, ticked)
        }
    }

    /// Applies the ticked differences to the budget from the current pay month, each
    /// scenario's with `ScenarioApply.apply`, all in one write; then shows what wasn't applied
    /// (or "Nothing to apply").
    func applyTicked() {
        // Reload what the apply needs, as it is now: the pay calendar (so the boundary) and
        // the differences and applied ids (dropping ticks no longer tickable). The write's own
        // reload then refreshes everything, the comparison recomputing in the background.
        let calendar: PayCalendar
        do {
            let fresh = try dbQueue.read { db in
                (closes: try PayMonthClose.fetchAll(db), transactions: try Transaction.fetchAll(db), categories: try Category.fetchAll(db))
            }
            calendar = PayCalendar.forData(transactions: fresh.transactions, categories: fresh.categories, manualCloses: fresh.closes, today: Date())
        } catch {
            errorMessage = "Couldn't reload the forecast before applying: \(error.localizedDescription)"
            return
        }
        recomputeDifferences()
        let groups = tickedByScenario.compactMap { group in group.scenario.id.map { (id: $0, name: group.scenario.name, ids: group.differences.map(\.id)) } }
        guard !groups.isEmpty else { return }
        var applications: [(name: String, application: ScenarioApplication)] = []
        if case .failed(let message) = perform({ db in
            applications = try groups.map { group in
                (group.name, try ScenarioApply.apply(db: db, scenarioId: group.id, differenceIds: group.ids, calendar: calendar))
            }
        }) {
            errorMessage = message
            return
        }
        tickedDifferenceIds = []
        guard !applications.isEmpty else { return }
        // Skipped items are prefixed with their scenario when several were applied.
        let skipped = applications.flatMap { name, application in
            application.skipped.map { applications.count > 1 ? "\(name): \($0)" : $0 }
        }
        let applied = applications.reduce(0) { total, item in
            total + (item.application.appliedNothing ? 0 : item.application.decodedJournal?.operations.count ?? 0)
        }
        if applied == 0 {
            notice = Notice(title: "Nothing to apply", lines: skipped)
        } else {
            notice = Notice(title: "Applied \(applied) item\(applied == 1 ? "" : "s") to the budget",
                            lines: skipped.isEmpty ? ["They're ordinary planned items now: edit them in the Budget grid."] : ["Not applied:"] + skipped)
        }
    }

    /// Undoes `scenario`'s latest apply, then shows what was restored.
    func undoLastApply(_ scenario: Scenario) {
        guard let id = scenario.id else { return }
        var report = UndoReport()
        if case .failed(let message) = perform({ db in report = try ScenarioApply.undoLast(db: db, scenarioId: id) }) {
            errorMessage = message
            return
        }
        var lines: [String] = []
        if !report.restored.isEmpty { lines.append("Restored: \(report.restored.joined(separator: ", "))") }
        lines += report.warnings
        notice = Notice(title: "Undid the last apply from “\(scenario.name)”", lines: lines)
    }

    /// Puts one differing item of `scenario` back to the budget's version (`Scenarios.revert`).
    func revert(_ difference: ScenarioDifference, in scenario: Scenario) {
        guard let id = scenario.id else { return }
        if case .failed(let message) = perform({ db in try Scenarios.revert(db: db, scenarioId: id, entryId: difference.id) }) {
            errorMessage = message
        }
    }

    // MARK: Editing a scenario's plan

    /// The Grid tab's scenario's effective plan (`ForecastCalculator.planEntries`).
    var scenarioPlanEntries: [ForecastEntry] {
        guard let id = gridSelection, let plan = scenarioPlans[id] else { return [] }
        return ForecastCalculator.planEntries(entries: plan.entries, groups: plan.groups)
    }

    /// The Grid tab's plan's effective entries, memoised per plan.
    private var gridPlanEntries: [ForecastEntry] {
        let key = gridSelection ?? 0
        if let cached = planEntriesCache[key] { return cached }
        let plan = gridPlan
        let entries = ForecastCalculator.planEntries(entries: plan.entries, groups: plan.groups)
        planEntriesCache[key] = entries
        return entries
    }

    /// The Grid tab's plan's occurrences under `category` in the calendar month: the scenario's
    /// (only closed months lock a scenario occurrence), or the Budget's, shown read-only
    /// (locked as the Budget grid locks them).
    func occurrences(category: Category, year: Int, month: Int) -> [PlannedRow] {
        guard let categoryId = category.id else { return [] }
        let plan = gridPlan
        let monthTotals = gridSelection == nil ? gridActuals.monthTotals : [:]
        return PlannedRow.rows(categoryId: categoryId, year: year, month: month, plan: gridPlanEntries,
                               exceptions: plan.exceptions, accounts: accounts.isEmpty ? nil : accountOptions) { entry, occurrence in
            PlannedItemEditing.isLocked(entry: entry, occurrence: occurrence, calendar: payCalendar, monthTotals: monthTotals,
                                        entries: budgetPlan.entries, groups: groups, exceptions: budgetPlan.exceptions, categories: categories)
        }
    }

    // MARK: The Grid tab's side panel (`GridCellPanelModel`)

    /// The confirmed, budget-facing transactions of any of `categoryIds` in `start...end`
    /// (every account): what a cell's actual sums, whichever plan is shown.
    func transactions(forCategoryIds categoryIds: Set<Int64>, from startDate: Date, to endDate: Date) -> [Transaction] {
        gridActuals.budgetFacing.filter { $0.categoryId.map(categoryIds.contains) == true && $0.status == .confirmed && $0.date >= startDate && $0.date <= endDate }
    }

    /// The transactions in `start...end` a Totals row sums (`BudgetTotals.Row.includes`).
    func totalsTransactions(_ row: BudgetTotals.Row, from startDate: Date, to endDate: Date) -> [Transaction] {
        let byId = categoryById
        return gridActuals.budgetFacing.filter { transaction in
            guard transaction.status == .confirmed, transaction.date >= startDate, transaction.date <= endDate,
                  let category = transaction.categoryId.flatMap({ byId[$0] }) else { return false }
            return row.includes(category, amount: transaction.amountMinorUnits, countedTransfer: transaction.id.map(gridActuals.countedTransferIds.contains) ?? false)
        }
    }

    /// The plan's occurrences in the calendar month a Totals row includes, by date (reserves
    /// left out: `totalsReserved` shows them as one line).
    func totalsOccurrences(_ row: BudgetTotals.Row, year: Int, month: Int) -> [PlannedRow] {
        // Marked: money to or from an account left out of net worth counts.
        categories.markingNetWorthExclusions(accounts: accounts).filter { $0.type != .adjustment && !$0.isReserved }
            .flatMap { category in
                let counted = BudgetTotals.countsPlannedTransfer(category, accountIds: nil)
                return occurrences(category: category, year: year, month: month).filter {
                    row.includes(category, amount: $0.occurrence.amountMinorUnits, countedTransfer: counted || $0.source != nil)
                }
            }
            .sorted { $0.occurrence.date < $1.occurrence.date }
    }

    /// The Total reserved cell's month (what's left of the allowances; 0 for Total in, and
    /// outside the shown years).
    func totalsReserved(_ row: BudgetTotals.Row, year: Int, month: Int) -> Int {
        guard row != .totalIn, let cells = yearGrids[year]?.cells else { return 0 }
        return reserves.compactMap(\.id).reduce(0) { $0 + (cells[$1]?[month]?.value ?? 0) }
    }

    /// Non-GBP accounts at the stored rate, for the side panel; rebuilt on load.
    private(set) var conversion = CurrencyConversion.none
    /// Categories and account names by id, for the side panel; rebuilt on load.
    private(set) var categoryById: [Int64: Category] = [:]
    private(set) var categoryNameById: [Int64: String] = [:]
    private(set) var accountNameById: [Int64: String] = [:]

    var planAccountOptions: PlanAccountOptions { accountOptions }
    var panelShowsPlan: Bool { true }
    var panelPlanIsScenario: Bool { gridSelection != nil }
    var panelAllowsPlanEditing: Bool { editScope != nil }

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

    /// A new item in the Grid tab's scenario (`PlannedItems.add(…, scenarioId:)`).
    func addPlannedItem(_ category: PlannedItemCategory, type: CategoryType, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date?, accountId: Int64?) -> SaveOutcome {
        guard let scenarioId = gridSelection else { return .failed("Select a scenario to add items to it.") }
        return perform { db in
            switch category {
            case .existing(let id):
                _ = try PlannedItems.add(db: db, categoryId: id, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, startDate: startDate, endDate: endDate, scenarioId: scenarioId, accountId: accountId)
            case .new(let name):
                _ = try PlannedItems.add(db: db, newCategoryName: name, type: type, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, startDate: startDate, endDate: endDate, scenarioId: scenarioId, accountId: accountId)
            }
        }
    }

    /// A reserve allowance in the Grid tab's scenario (`ReservedCategories.addAllowance`); a new
    /// reserve is a global category, created in the same write.
    func addReserveAllowance(_ target: ReserveTarget, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date?) -> SaveOutcome {
        guard let scenarioId = gridSelection else { return .failed("Select a scenario to add allowances to it.") }
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

    /// Ticks a just-created scenario in Compare and Differences and opens it in the Grid
    /// (after the reload that fetched it); each selection's `didSet` recomputes its tab.
    private func show(_ id: Int64) {
        compareSelection.insert(id)
        differencesSelection.insert(id)
        gridSelection = id
        tab = .grid
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
        recomputeDifferences()
        recomputeGrid()
        recomputeYearEnds()
        return .saved
    }
}
