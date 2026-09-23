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
    func assignCategory(_ transaction: Transaction, to categoryId: Int64) throws {
        guard let index = transactions.firstIndex(where: { $0.id == transaction.id }) else { return }
        transactions[index].categoryId = categoryId
        transactions[index].status = .confirmed
        try dbQueue.write { db in
            try transactions[index].update(db)
            try RuleLearner.learnFromCorrection(description: transactions[index].rawDescription, categoryId: categoryId, db: db)
        }
        transactions.remove(at: index)
    }
}
