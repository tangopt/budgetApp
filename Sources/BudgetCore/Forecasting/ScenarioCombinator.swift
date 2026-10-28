import Foundation

/// A scenario to combine: its id, its name and its plan as loaded
/// (`ForecastEntry.inScenario`, tombstones included, with their exceptions and the groups).
public struct ScenarioPlan: Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let plan: PlanInput

    public init(id: Int64, name: String, plan: PlanInput) {
        self.id = id
        self.name = name
        self.plan = plan
    }
}

/// Two scenarios that both change (or remove) the same budget entry: the later one's
/// version is used. `categoryId` is the budget entry's category.
public struct ScenarioOverlap: Equatable, Sendable {
    public let sourceEntryId: Int64
    public let categoryId: Int64
    public let earlierScenarioId: Int64
    public let laterScenarioId: Int64

    public init(sourceEntryId: Int64, categoryId: Int64, earlierScenarioId: Int64, laterScenarioId: Int64) {
        self.sourceEntryId = sourceEntryId
        self.categoryId = categoryId
        self.earlierScenarioId = earlierScenarioId
        self.laterScenarioId = laterScenarioId
    }
}

/// The budget with several scenarios applied: the plan to compare, the overlaps found on the
/// way, and which scenario each of its non-budget entries came from (entry id → scenario id;
/// the budget's own entries are absent).
public struct CombinedPlan: Equatable, Sendable {
    public let plan: PlanInput
    public let overlaps: [ScenarioOverlap]
    public let contributions: [Int64: Int64]

    public init(plan: PlanInput, overlaps: [ScenarioOverlap], contributions: [Int64: Int64]) {
        self.plan = plan
        self.overlaps = overlaps
        self.contributions = contributions
    }
}

/// Combines scenarios onto the budget (spec 2026-10-28-step17-scenario-comparison-design.md).
/// Pure. Scenarios apply in list order; each one's changes (`scenarioChange != nil`) apply to
/// the budget: an added entry is appended, a changed entry or a removed tombstone takes its
/// budget source's place. When two scenarios change the same source the later one wins and
/// the overlap is reported. Unchanged copies, and their edited occurrences, count for nothing
/// (as in `Scenarios.differences`).
public enum ScenarioCombinator {
    public static func combine(budget: PlanInput, scenarios: [ScenarioPlan]) -> CombinedPlan {
        var entries = budget.entries
        // Entry id → its index in `entries`, for the budget's entries.
        var budgetIndex: [Int64: Int] = [:]
        for (index, entry) in entries.enumerated() {
            if let id = entry.id { budgetIndex[id] = index }
        }
        var touchedBy: [Int64: Int64] = [:] // source id → the scenario now standing for it
        var contributions: [Int64: Int64] = [:]
        var overlaps: [ScenarioOverlap] = []

        for scenario in scenarios {
            for entry in scenario.plan.entries {
                guard let change = entry.scenarioChange else { continue }
                if change != .added, let source = entry.sourceEntryId, let index = budgetIndex[source] {
                    if let earlier = touchedBy[source] {
                        if earlier != scenario.id {
                            overlaps.append(ScenarioOverlap(sourceEntryId: source, categoryId: budget.entries[index].categoryId,
                                                            earlierScenarioId: earlier, laterScenarioId: scenario.id))
                        }
                        if let replaced = entries[index].id { contributions[replaced] = nil }
                    }
                    entries[index] = entry
                    touchedBy[source] = scenario.id
                } else {
                    // Added, or a change whose source has left the budget: kept as an addition.
                    entries.append(entry)
                }
                if let id = entry.id { contributions[id] = scenario.id }
            }
        }

        // Exceptions follow their entries: a standing budget entry keeps its own, an entry
        // taken from a scenario brings that scenario's.
        let standingBudgetIds = Set(budgetIndex.keys.filter { touchedBy[$0] == nil })
        var exceptions = budget.exceptions.filter { standingBudgetIds.contains($0.entryId) }
        for scenario in scenarios {
            exceptions += scenario.plan.exceptions.filter { contributions[$0.entryId] == scenario.id }
        }

        var groups = budget.groups
        var groupIds = Set(groups.compactMap(\.id))
        for scenario in scenarios {
            for group in scenario.plan.groups {
                guard let id = group.id, !groupIds.contains(id) else { continue }
                groups.append(group)
                groupIds.insert(id)
            }
        }

        return CombinedPlan(plan: PlanInput(entries: entries, exceptions: exceptions, groups: groups),
                            overlaps: overlaps, contributions: contributions)
    }

    /// "Buy a car and Salary +10% both change 'Groceries'; the later one is used".
    public static func overlapNotice(_ overlap: ScenarioOverlap, scenarioNames: [Int64: String], categoryNames: [Int64: String]) -> String {
        let earlier = scenarioNames[overlap.earlierScenarioId] ?? "A scenario"
        let later = scenarioNames[overlap.laterScenarioId] ?? "another scenario"
        let item = categoryNames[overlap.categoryId].map { "'\($0)'" } ?? "an item"
        return "\(earlier) and \(later) both change \(item); the later one is used"
    }
}
