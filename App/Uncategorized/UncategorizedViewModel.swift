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
    @Published var errorMessage: String?

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func load() throws {
        transactions = try dbQueue.read { db in try UncategorizedTransactions.fetch(db: db) }
        categories = try dbQueue.read { db in try Category.fetchAll(db) }
    }

    /// Assigns a category, marks the transaction confirmed, and learns a rule from the
    /// correction — same behavior `RuleLearner` already provides during import review.
    ///
    /// The write happens against a locally-built copy first; `self.transactions` is only
    /// touched (both the categoryId/status update and the removal) once that write has
    /// actually succeeded. Doing the local mutation before the write — as an earlier version
    /// of this method did — left the `@Published` list showing a half-assigned row (new
    /// category selected, but not removed from "needs a category") whenever the write threw,
    /// since GRDB rolls back the DB transaction on error but has no way to roll back
    /// unrelated in-memory state.
    @discardableResult
    func assignCategory(_ transaction: Transaction, to categoryId: Int64) -> Bool {
        errorMessage = nil
        guard let index = transactions.firstIndex(where: { $0.id == transaction.id }) else { return false }
        var updated = transactions[index]
        updated.categoryId = categoryId
        updated.status = .confirmed
        do {
            try dbQueue.write { db in
                try updated.update(db)
                try RuleLearner.learnFromCorrection(description: updated.rawDescription, categoryId: categoryId, db: db)
            }
        } catch {
            errorMessage = "Couldn't assign this category: \(error.localizedDescription)"
            return false
        }
        transactions.remove(at: index)
        return true
    }
}
