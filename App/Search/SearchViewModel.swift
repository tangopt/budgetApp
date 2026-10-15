// App/Search/SearchViewModel.swift
import Foundation
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction
import GRDB

/// The Search screen (spec 2026-10-15): every transaction, filtered by `criteria`
/// (`TransactionSearch`). Owned by ContentView, so the query, filters and sort last while the
/// app runs.
@MainActor
final class SearchViewModel: ObservableObject {
    @Published var criteria = TransactionSearch.Criteria() {
        didSet { if criteria != oldValue { refreshResults() } }
    }
    @Published var sortKey: TransactionSearch.SortKey = .date {
        didSet { if sortKey != oldValue { refreshResults() } }
    }
    @Published var sortAscending = false {
        didSet { if sortAscending != oldValue { refreshResults() } }
    }
    /// The matches, sorted, and their totals: rebuilt when the data, criteria or sort change.
    @Published private(set) var rows: [TransactionSearch.Row] = []
    @Published private(set) var totals = TransactionSearch.Totals(count: 0, inMinorUnits: 0, outMinorUnits: 0)
    @Published private(set) var categories: [Category] = []
    @Published private(set) var groups: [CategoryGroup] = []
    /// Every account in the order the app lists them.
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var transferCounterparts: [Int64: [TransferCounterpart]] = [:]
    @Published private(set) var recentCategoryIds: [Int64] = []
    @Published var errorMessage: String?
    /// Bumped by ⌘F: the screen focuses its search field.
    @Published private(set) var focusRequest = 0
    /// Runs after a save here (the uncategorised count may change).
    var onTransactionEdited: (() -> Void)?

    private var input = TransactionSearch.Input(transactions: [], categories: [], accounts: [], links: [], eurToGbpRate: 1)
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func requestFocus() { focusRequest += 1 }

    /// Re-reads everything (on appear, and after every save here).
    func load() {
        do {
            let since = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
            let (transactions, categories, groups, accounts, links, counterparts, rate, recent) = try dbQueue.read { db in
                (try Transaction.fetchAll(db), try Category.fetchAll(db), try CategoryGroup.fetchAll(db), try Account.fetchAll(db),
                 try TransferLink.fetchAll(db), try TransferLinks.counterparts(db: db),
                 try ExchangeRateSetting.currentOrDefault(db: db).eurToGbpRate,
                 try CategoryShortlist.recent(db: db, since: since, limit: 5))
            }
            self.categories = categories
            self.groups = groups
            self.accounts = accounts.sortedForDisplay()
            transferCounterparts = counterparts
            recentCategoryIds = recent
            input = TransactionSearch.Input(transactions: transactions, categories: categories, accounts: accounts, links: links, eurToGbpRate: rate)
            refreshResults()
        } catch {
            errorMessage = "Couldn't load transactions: \(error.localizedDescription)"
        }
    }

    private func refreshResults() {
        let matches = TransactionSearch.rows(input, criteria: criteria)
        rows = sortKey == .date && !sortAscending ? matches : TransactionSearch.sorted(matches, by: sortKey, ascending: sortAscending)
        totals = TransactionSearch.totals(rows, eurToGbpRate: input.eurToGbpRate)
    }

    // MARK: Filters

    /// Every category but reserves (which never hold transactions): what the Categories filter lists.
    var filterCategories: [Category] {
        categories.filter { !$0.isReserved }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Groups with at least one listed member, by name.
    var filterGroups: [CategoryGroup] {
        let assignable = filterCategories
        return groups.filter { group in assignable.contains { $0.groupId == group.id } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func memberIds(ofGroup group: CategoryGroup) -> Set<Int64> {
        guard let id = group.id else { return [] }
        return TransactionSearch.memberIds(ofGroupId: id, categories: filterCategories)
    }

    func resetFilters() {
        let text = criteria.text
        criteria = TransactionSearch.Criteria(text: text)
    }

    // MARK: Actions

    func transaction(id: Int64) -> Transaction? {
        rows.first { $0.id == id }?.transaction
    }

    func createCategory(name: String, type: CategoryType, groupId: Int64?) throws -> Category {
        let category = try dbQueue.write { db in try Categories.create(db: db, name: name, type: type, groupId: groupId) }
        load()
        return category
    }

    /// Set category… for the selected rows; with `remember`, learns a rule per description.
    func setCategory(ids: [Int64], categoryId: Int64, remember: Bool) {
        guard !ids.isEmpty else { return }
        errorMessage = nil
        do {
            try dbQueue.write { db in try TransactionEditing.setCategory(db: db, ids: ids, categoryId: categoryId, remember: remember) }
        } catch {
            errorMessage = "Couldn't set the category: \(error.localizedDescription)"
            return
        }
        load()
        onTransactionEdited?()
    }

    /// The Edit transaction sheet's Save (`TransactionEditing.save`), then reload.
    func saveTransactionEdit(id: Int64, changes: TransactionEditChanges) -> SaveOutcome {
        manualWrite { db in try TransactionEditing.save(db: db, id: id, changes: changes) }
    }

    var manualActions: ManualTransactionActions {
        ManualTransactionActions(
            accounts: accounts,
            delete: { [unowned self] id in manualWrite { db in try ManualTransactions.delete(db: db, id: id) } }
        )
    }

    var transferActions: TransferLinkActions {
        TransferLinkActions.make(dbQueue: dbQueue, accounts: accounts, counterparts: { [unowned self] in transferCounterparts[$0] ?? [] })
    }

    private func manualWrite(_ write: (Database) throws -> Void) -> SaveOutcome {
        do {
            try dbQueue.write { db in try write(db) }
        } catch {
            return .failed(ManualFormat.errorMessage(for: error))
        }
        errorMessage = nil
        load()
        onTransactionEdited?()
        return errorMessage == nil ? .saved : .savedButReloadFailed
    }
}
