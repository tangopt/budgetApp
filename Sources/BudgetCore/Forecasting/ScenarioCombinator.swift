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
/// Pure. Scenarios apply in list order. A scenario's changes to one budget entry are taken as a
/// whole: the changed copy or removed tombstone of that entry (`scenarioChange` with its
/// `sourceEntryId`), plus every entry the scenario adds in the same category that starts after
/// that copy ends (a series continued at a new amount, as `PlannedItemEditing.editFollowing` and
/// `OfferScenarioBuilder` write it: the copy ends, an added entry follows). They take the budget
/// entry's place; when a later scenario also changes it, the later one's set replaces the
/// earlier's and the overlap is reported. Other added entries are appended, an addition equal
/// to one an earlier scenario made (a duplicated scenario's copy) only once. Unchanged copies,
/// and their edited occurrences, count for nothing (as in `Scenarios.differences`).
public enum ScenarioCombinator {
    public static func combine(budget: PlanInput, scenarios: [ScenarioPlan]) -> CombinedPlan {
        var budgetIds = Set<Int64>()
        for entry in budget.entries { if let id = entry.id { budgetIds.insert(id) } }
        // Budget entry id → the scenario standing for it and the entries it uses there.
        var replacements: [Int64: (scenarioId: Int64, entries: [ForecastEntry])] = [:]
        // Additions not tied to a budget entry, in order.
        var additions: [(scenarioId: Int64, entry: ForecastEntry)] = []
        var overlaps: [ScenarioOverlap] = []

        for scenario in scenarios {
            let changes = scenario.plan.entries.filter { $0.scenarioChange != nil }
            // This scenario's changed copies / tombstones of budget entries, by source.
            var sets: [Int64: [ForecastEntry]] = [:]
            var order: [Int64] = []
            var loose: [ForecastEntry] = []
            for entry in changes where entry.scenarioChange != .added {
                if let source = entry.sourceEntryId, budgetIds.contains(source) {
                    if sets[source] == nil { order.append(source) }
                    sets[source, default: []].append(entry)
                } else {
                    loose.append(entry) // a change whose source has left the budget: kept as an addition
                }
            }
            for entry in changes where entry.scenarioChange == .added {
                if let source = continuedSource(of: entry, sets: sets, order: order) {
                    sets[source]?.append(entry)
                } else {
                    loose.append(entry)
                }
            }
            for source in order {
                if let earlier = replacements[source], earlier.scenarioId != scenario.id,
                   let categoryId = budget.entries.first(where: { $0.id == source })?.categoryId {
                    overlaps.append(ScenarioOverlap(sourceEntryId: source, categoryId: categoryId,
                                                    earlierScenarioId: earlier.scenarioId, laterScenarioId: scenario.id))
                }
                replacements[source] = (scenario.id, sets[source] ?? [])
            }
            for entry in scenario.plan.entries where loose.contains(entry) {
                if let index = additions.firstIndex(where: { $0.scenarioId != scenario.id && sameAddition($0.entry, entry) }) {
                    additions[index] = (scenario.id, entry) // the later one's (its exceptions come with it)
                } else {
                    additions.append((scenario.id, entry))
                }
            }
        }

        var entries: [ForecastEntry] = []
        var contributions: [Int64: Int64] = [:]
        for entry in budget.entries {
            if let id = entry.id, let replacement = replacements[id] {
                entries += replacement.entries
                for used in replacement.entries { if let usedId = used.id { contributions[usedId] = replacement.scenarioId } }
            } else {
                entries.append(entry)
            }
        }
        for addition in additions {
            entries.append(addition.entry)
            if let id = addition.entry.id { contributions[id] = addition.scenarioId }
        }

        // Exceptions follow their entries: a standing budget entry keeps its own, an entry
        // taken from a scenario brings that scenario's.
        let standingBudgetIds = budgetIds.subtracting(replacements.keys)
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

    /// The budget entry an added entry continues: one whose copy this scenario ends (or removes)
    /// before the addition starts, in the same category; the latest-ending such copy wins.
    private static func continuedSource(of added: ForecastEntry, sets: [Int64: [ForecastEntry]], order: [Int64]) -> Int64? {
        var best: (source: Int64, end: Date)?
        for source in order {
            for copy in sets[source] ?? [] where copy.scenarioChange != .added && copy.categoryId == added.categoryId {
                let end: Date
                if copy.scenarioChange == .removed {
                    end = .distantPast
                } else if let copyEnd = copy.endDate, copyEnd < added.startDate {
                    end = copyEnd
                } else {
                    continue
                }
                if best.map({ end > $0.end }) ?? true { best = (source, end) }
            }
        }
        return best?.source
    }

    /// Two additions that plan the same thing: everything but their id, scenario and note equal.
    private static func sameAddition(_ a: ForecastEntry, _ b: ForecastEntry) -> Bool {
        a.scenarioChange == .added && b.scenarioChange == .added
            && a.groupId == b.groupId && a.categoryId == b.categoryId && a.amountMinorUnits == b.amountMinorUnits
            && a.frequency == b.frequency && a.interval == b.interval && a.startDate == b.startDate && a.endDate == b.endDate
            && a.isEnabled == b.isEnabled && a.anchorDay == b.anchorDay && a.accountId == b.accountId
    }

    /// "Buy a car and Salary +10% both change 'Groceries'; the later one is used".
    public static func overlapNotice(_ overlap: ScenarioOverlap, scenarioNames: [Int64: String], categoryNames: [Int64: String]) -> String {
        let earlier = scenarioNames[overlap.earlierScenarioId] ?? "A scenario"
        let later = scenarioNames[overlap.laterScenarioId] ?? "another scenario"
        let item = categoryNames[overlap.categoryId].map { "'\($0)'" } ?? "an item"
        return "\(earlier) and \(later) both change \(item); the later one is used"
    }
}
