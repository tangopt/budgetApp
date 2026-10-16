// App/Rules/RulesViewModel.swift
import Foundation
import BudgetCore
import struct BudgetCore.Category
import GRDB

@MainActor
final class RulesViewModel: ObservableObject {
    @Published var rules: [Rule] = []
    @Published var categories: [Category] = []
    /// Category groups and recently used categories for the rule sheet's category picker.
    @Published var categoryGroups: [CategoryGroup] = []
    @Published var recentCategoryIds: [Int64] = []

    /// Called after a save filed uncategorised transactions (the sidebar's count).
    var onTransactionsCategorised: (() -> Void)?

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func load() throws {
        let since = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        (rules, categories, categoryGroups, recentCategoryIds) = try dbQueue.read { db in
            (
                try Rule.fetchAll(db).sorted { $0.priority > $1.priority },
                try Category.fetchAll(db),
                try CategoryGroup.fetchAll(db),
                try CategoryShortlist.recent(db: db, since: since, limit: 5)
            )
        }
    }

    func delete(_ rule: Rule) throws {
        _ = try dbQueue.write { db in try rule.delete(db) }
        try load()
    }

    func updateCategory(_ rule: Rule, to categoryId: Int64) throws {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index].categoryId = categoryId
        try dbQueue.write { db in try rules[index].update(db) }
    }

    /// The rule sheet's live preview (off the main thread); a failed read throws so the sheet
    /// can say so rather than show "Matches 0".
    func preview(pattern: String, matchType: RuleMatchType) async throws -> RulePreview {
        try await dbQueue.read { db in try Rules.preview(db: db, pattern: pattern, matchType: matchType) }
    }

    /// Saves the rule sheet: adds a rule, or edits `ruleId`'s. Returns the error to show, or
    /// nil once saved.
    func save(ruleId: Int64?, pattern: String, matchType: RuleMatchType, categoryId: Int64, applyToUncategorised: Bool) -> String? {
        do {
            _ = try dbQueue.write { db in
                if let ruleId {
                    try Rules.update(db: db, id: ruleId, pattern: pattern, matchType: matchType, categoryId: categoryId,
                                     applyToUncategorised: applyToUncategorised)
                } else {
                    try Rules.add(db: db, pattern: pattern, matchType: matchType, categoryId: categoryId,
                                  applyToUncategorised: applyToUncategorised)
                }
            }
        } catch let error as RuleSaveError {
            return error.message
        } catch {
            return "Couldn't save the rule: \(error.localizedDescription)"
        }
        try? load()
        if applyToUncategorised { onTransactionsCategorised?() }
        return nil
    }

    /// The picker's "New category…": creates the category and adds it to the list.
    func createCategory(name: String, type: CategoryType, groupId: Int64?) throws -> Category {
        let category = try dbQueue.write { db in try Categories.create(db: db, name: name, type: type, groupId: groupId) }
        categories.append(category)
        return category
    }
}
