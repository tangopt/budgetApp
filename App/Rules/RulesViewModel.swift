// App/Rules/RulesViewModel.swift
import Foundation
import BudgetCore
import struct BudgetCore.Category
import GRDB

@MainActor
final class RulesViewModel: ObservableObject {
    @Published var rules: [Rule] = []
    @Published var categories: [Category] = []

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func load() throws {
        rules = try dbQueue.read { db in try Rule.fetchAll(db).sorted { $0.priority > $1.priority } }
        categories = try dbQueue.read { db in try Category.fetchAll(db) }
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
}
