// App/Rules/RulesViewModel.swift
import Foundation
import BudgetCore
import struct BudgetCore.Category
import GRDB

@MainActor
final class RulesViewModel: ObservableObject {
    /// The Rules page's tabs.
    enum Tab: String, CaseIterable, Hashable {
        case transactionRules = "Transaction rules"
        case importRules = "Import rules"
    }

    @Published var tab: Tab = .transactionRules
    /// A learnt import rule to select on the Import rules tab ("Show on Rules page" in an import's
    /// review); taken by the tab, then cleared.
    @Published var focusedImportRuleId: Int64?
    @Published var rules: [Rule] = []
    /// The learnt import rules ("Import rules" tab), oldest first.
    @Published var importRules: [ImportRuleRow] = []
    @Published var categories: [Category] = []
    /// Category groups and recently used categories for the rule sheet's category picker.
    @Published var categoryGroups: [CategoryGroup] = []
    @Published var recentCategoryIds: [Int64] = []

    #if SNAPSHOTS
    /// Snapshot routes only: the search text the Rules page starts with.
    var snapshotSearchText: String?
    #endif

    /// Called after a save filed uncategorised transactions (the sidebar's count).
    var onTransactionsCategorised: (() -> Void)?

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func load() throws {
        let since = Calendar.current.date(byAdding: .day, value: -90, to: AppClock.now) ?? AppClock.now
        (rules, categories, categoryGroups, recentCategoryIds, importRules) = try dbQueue.read { db in
            (
                try Rule.fetchAll(db).sorted { $0.priority > $1.priority },
                try Category.fetchAll(db),
                try CategoryGroup.fetchAll(db),
                try CategoryShortlist.recent(db: db, since: since, limit: 5),
                try ImportRuleEditing.rows(db: db)
            )
        }
    }

    // MARK: Import rules

    /// The Import rules tab with the rule `id` selected.
    func showImportRule(_ id: Int64) {
        tab = .importRules
        focusedImportRuleId = id
    }

    /// Learnt import rules are the user's to change outside an import run: written straight
    /// away, like transaction-rule edits.
    func setEnabled(importRuleId id: Int64, _ enabled: Bool) throws {
        try dbQueue.write(.rulesAndCategories) { db in try ImportRuleEditing.setEnabled(db: db, id: id, enabled) }
        try reloadImportRules()
    }

    func delete(importRuleId id: Int64) throws {
        try dbQueue.write(.rulesAndCategories) { db in try ImportRuleEditing.delete(db: db, id: id) }
        try reloadImportRules()
    }

    /// Saves the Edit Rule sheet's choice. Returns the error to show, or nil once saved.
    func update(importRuleId id: Int64, edit: ImportRuleEdit) -> String? {
        do {
            try dbQueue.write(.rulesAndCategories) { db in try ImportRuleEditing.update(db: db, id: id, edit: edit) }
        } catch ImportRuleEditError.blank {
            return "Enter a value."
        } catch ImportRuleEditError.noLetters {
            return "Enter text with at least one letter."
        } catch ImportRuleEditError.missingTarget {
            return "That record or kind no longer exists: choose another."
        } catch {
            return "Couldn't save the rule: \(error.localizedDescription)"
        }
        try? reloadImportRules()
        return nil
    }

    /// What the Edit Rule sheet needs: the rule's action as an edit, the accounts, the records a
    /// link can go to, the document kinds (custom ones included).
    func importRuleEditContext(id: Int64) throws -> ImportRuleEditContext? {
        try dbQueue.read { db in
            guard let rule = try ImportRule.fetchOne(db, key: id), let edit = ImportRuleEditing.currentEdit(rule) else { return nil }
            var current: EvidenceEntity?
            if case .link(let entity) = edit { current = entity }
            let accounts = try Account.order(Column("name").collating(.localizedCaseInsensitiveCompare), Column("id")).fetchAll(db)
                .compactMap { account in account.id.map { (id: $0, name: account.displayName) } }
            let catalog = try DocumentKindCatalog.load(db: db)
            return ImportRuleEditContext(ruleId: id, kind: rule.kind, when: rule.matchLabel, edit: edit, accounts: accounts,
                                         linkTargets: try ImportRuleEditing.linkTargets(db: db, current: current),
                                         documentKinds: catalog.all.map { (ref: $0, name: catalog.displayName($0)) })
        }
    }

    private func reloadImportRules() throws {
        importRules = try dbQueue.read { db in try ImportRuleEditing.rows(db: db) }
    }

    func delete(_ rule: Rule) throws {
        _ = try dbQueue.write(.rulesAndCategories) { db in try rule.delete(db) }
        try load()
    }

    func updateCategory(_ rule: Rule, to categoryId: Int64) throws {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index].categoryId = categoryId
        try dbQueue.write(.rulesAndCategories) { db in try rules[index].update(db) }
    }

    /// The rule sheet's live preview (off the main thread); a failed read throws so the sheet
    /// can say so rather than show "Matches 0".
    func preview(pattern: String, matchType: RuleMatchType) async throws -> RulePreview {
        try await dbQueue.read { db in try Rules.preview(db: db, pattern: pattern, matchType: matchType) }
    }

    /// Saves the rule sheet: adds a rule, or edits `ruleId`'s; `done` gets the error to show, or
    /// nil once saved. Filing the uncategorised matches is one batch through the filed-year check
    /// (plan Task 14): when it would change a filed return, `gate` asks once.
    func save(ruleId: Int64?, pattern: String, matchType: RuleMatchType, categoryId: Int64, applyToUncategorised: Bool,
              gate: FiledYearGate, done: @escaping (String?) -> Void) {
        let name = categories.first { $0.id == categoryId }?.name ?? "its category"
        let edit = "Rule “\(pattern.trimmingCharacters(in: .whitespacesAndNewlines))” filed into \(name)"
        gate.run(dbQueue, area: .rulesAndCategories, edit: edit, scope: { db in
            applyToUncategorised
                ? .categorising(try Rules.uncategorisedMatchIds(db: db, pattern: pattern, matchType: matchType), as: categoryId)
                : FiledYearEditCheck.Scope()
        }, { db in
            if let ruleId {
                _ = try Rules.update(db: db, id: ruleId, pattern: pattern, matchType: matchType, categoryId: categoryId,
                                     applyToUncategorised: applyToUncategorised)
            } else {
                _ = try Rules.add(db: db, pattern: pattern, matchType: matchType, categoryId: categoryId,
                                  applyToUncategorised: applyToUncategorised)
            }
        }, done: { [weak self] result in
            switch result.failure {
            case let error as RuleSaveError: return done(error.message)
            case let error?: return done("Couldn't save the rule: \(error.localizedDescription)")
            case nil: break
            }
            try? self?.load()
            if applyToUncategorised { self?.onTransactionsCategorised?() }
            done(nil)
        })
    }

    /// The picker's "New category…": creates the category and adds it to the list.
    func createCategory(name: String, type: CategoryType, groupId: Int64?) throws -> Category {
        let category = try dbQueue.write(.rulesAndCategories) { db in try Categories.create(db: db, name: name, type: type, groupId: groupId) }
        categories.append(category)
        return category
    }
}

/// The import Edit Rule sheet's starting point.
struct ImportRuleEditContext: Identifiable {
    let ruleId: Int64
    let kind: ImportRuleKind
    let when: String
    let edit: ImportRuleEdit
    let accounts: [(id: Int64, name: String)]
    let linkTargets: [ImportRuleTarget]
    /// The built-in kinds by name, then the custom kinds by name.
    var documentKinds: [(ref: DocumentKindRef, name: String)] = []
    var id: Int64 { ruleId }
}
