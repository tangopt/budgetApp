// App/Uncategorized/UncategorizedViewModel.swift
import Foundation
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction
import GRDB

@MainActor
final class UncategorizedViewModel: ObservableObject {
    @Published var transactions: [Transaction] = []
    @Published var categories: [Category] = []
    /// Category groups and recently used categories for the category picker.
    @Published var categoryGroups: [CategoryGroup] = []
    @Published var recentCategoryIds: [Int64] = []
    @Published var errorMessage: String?

    /// Per-row Remember choices made through a group's checkbox (absent = group default).
    @Published private var rememberChoices: [Int64: Bool] = [:]

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func load() throws {
        let since = Self.recentSince()
        (transactions, categories, categoryGroups, recentCategoryIds) = try dbQueue.read { db in
            (
                try UncategorizedTransactions.fetch(db: db),
                try Category.fetchAll(db),
                try CategoryGroup.fetchAll(db),
                try CategoryShortlist.recent(db: db, since: since, limit: 5)
            )
        }
    }

    /// The picker's Recent section covers the last 90 days.
    private static func recentSince() -> Date {
        Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
    }

    /// Merchant groups of the given transactions (the search-filtered list), in order of
    /// first appearance.
    func groups(of rows: [Transaction]) -> [ReviewGroup<Transaction>] {
        ReviewGrouping.groups(rows, scope: "uncategorized", description: \.rawDescription)
    }

    /// Whether this row of a group is ticked in the group's Remember checkbox: its own
    /// choice, or the group default (on for 2+ rows) until one is made.
    func remembers(_ transaction: Transaction, in group: ReviewGroup<Transaction>) -> Bool {
        ReviewGrouping.remembers(choice: transaction.id.flatMap { rememberChoices[$0] }, groupRowCount: group.rows.count)
    }

    func setRemember(_ remember: Bool, for transaction: Transaction) {
        guard let id = transaction.id else { return }
        rememberChoices[id] = remember
    }

    /// Assigns a category to each transaction, marks them confirmed, and learns a key rule
    /// (`RuleLearner.learn`) for those whose `remember` is true. All rows of one action go
    /// in a single database write.
    ///
    /// The write happens against locally-built copies first; `self.transactions` is only
    /// touched once that write has actually succeeded. Mutating the in-memory list before
    /// the write left the `@Published` list showing a half-assigned row whenever the write
    /// threw, since GRDB rolls back the DB transaction on error but has no way to roll back
    /// unrelated in-memory state.
    @discardableResult
    func assignCategory(_ rows: [Transaction], to categoryId: Int64, remember: (Transaction) -> Bool) -> Bool {
        errorMessage = nil
        let ids = Set(rows.compactMap(\.id))
        let targets = transactions.filter { $0.id.map(ids.contains) ?? false }
        guard !targets.isEmpty else { return false }
        let updates: [(row: Transaction, learn: Bool)] = targets.map { target in
            var updated = target
            updated.categoryId = categoryId
            updated.status = .confirmed
            updated.categorizedBy = .manual
            return (updated, remember(target))
        }
        do {
            try dbQueue.write { db in
                for update in updates {
                    try update.row.update(db)
                    if update.learn {
                        try RuleLearner.learn(description: update.row.rawDescription, categoryId: categoryId, db: db)
                    }
                }
            }
        } catch {
            errorMessage = "Couldn't assign this category: \(error.localizedDescription)"
            return false
        }
        transactions.removeAll { $0.id.map(ids.contains) ?? false }
        for id in ids { rememberChoices[id] = nil }
        // The assignment just counted towards Recent; a failed refresh keeps the old list.
        if let recent = try? dbQueue.read({ db in try CategoryShortlist.recent(db: db, since: Self.recentSince(), limit: 5) }) {
            recentCategoryIds = recent
        }
        return true
    }
}
