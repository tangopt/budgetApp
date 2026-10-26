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
    /// What the search field holds; reaches `criteria.text` after a short pause in typing.
    @Published var queryText = "" {
        didSet { if queryText != oldValue { scheduleQuery() } }
    }
    /// The table's sort (its column and direction), kept for the session like the filters.
    @Published var sortOrder: [KeyPathComparator<TransactionSearch.Row>] = [KeyPathComparator(\TransactionSearch.Row.date, order: .reverse)] {
        didSet { if sortOrder != oldValue { refreshResults() } }
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
    /// Set category… through the filed-year check (plan Task 14); its question shows on the screen.
    let filedYearGate = FiledYearGate()
    /// Bumped by ⌘F: the screen focuses its search field.
    @Published private(set) var focusRequest = 0
    /// Runs after a save here (the uncategorised count may change).
    var onTransactionEdited: (() -> Void)?

    private var index = TransactionSearch.Index(TransactionSearch.Input(transactions: [], categories: [], accounts: [], links: [], eurToGbpRate: 1))
    private var eurToGbpRate = 1.0
    private var transactionsById: [Int64: Transaction] = [:]
    private var queryTask: Task<Void, Never>?
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func requestFocus() { focusRequest += 1 }

    /// Re-reads everything (on appear, and after every save here).
    func load() {
        do {
            let since = Calendar.current.date(byAdding: .day, value: -90, to: AppClock.now) ?? AppClock.now
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
            eurToGbpRate = rate
            transactionsById = Dictionary(transactions.compactMap { t in t.id.map { ($0, t) } }, uniquingKeysWith: { a, _ in a })
            index = TransactionSearch.Index(TransactionSearch.Input(transactions: transactions, categories: categories, accounts: accounts,
                                                                    links: links, eurToGbpRate: rate))
            refreshResults()
        } catch {
            errorMessage = "Couldn't load transactions: \(error.localizedDescription)"
        }
    }

    /// Typing waits ~150 ms for a pause before searching; clearing applies at once.
    private func scheduleQuery() {
        queryTask?.cancel()
        let text = queryText
        guard !text.isEmpty else {
            criteria.text = ""
            return
        }
        queryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.criteria.text = text
        }
    }

    private func refreshResults() {
        let matches = TransactionSearch.rows(index, criteria: criteria, now: AppClock.now)
        let (key, ascending) = Self.sort(sortOrder)
        rows = key == .date && !ascending ? matches : TransactionSearch.sorted(matches, by: key, ascending: ascending)
        // Without an account filter a linked transfer counts once, as on the Budget grid.
        totals = TransactionSearch.totals(rows, eurToGbpRate: eurToGbpRate, countsTransfersOnce: criteria.accountIds.isEmpty)
    }

    /// The table's first sort comparator as a `TransactionSearch` column and direction.
    private static func sort(_ order: [KeyPathComparator<TransactionSearch.Row>]) -> (TransactionSearch.SortKey, Bool) {
        guard let first = order.first else { return (.date, false) }
        let key: TransactionSearch.SortKey
        switch first.keyPath {
        case \TransactionSearch.Row.description: key = .description
        case \TransactionSearch.Row.categoryName: key = .category
        case \TransactionSearch.Row.accountName: key = .account
        case \TransactionSearch.Row.amountMinorUnits: key = .amount
        default: key = .date
        }
        return (key, first.order == .forward)
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
        criteria = TransactionSearch.Criteria(text: criteria.text)
    }

    /// A transaction another screen asked to show (Show where it lives): the screen selects
    /// its row and scrolls to it once listed, then clears this.
    @Published var revealId: Int64?

    /// Show where it lives: narrows the search to the transaction's day and account (the
    /// filter bar shows it; Reset widens it again) and asks the screen to select its row.
    func reveal(_ shown: Transaction) {
        guard let id = shown.id else { return }
        // As stored now: the caller's copy may predate an edit of its day or account.
        let transaction = (try? dbQueue.read { db in try Transaction.fetchOne(db, key: id) }) ?? shown
        queryTask?.cancel()
        queryText = ""
        criteria = TransactionSearch.Criteria(date: .custom(from: transaction.date, to: transaction.date),
                                              accountIds: [transaction.accountId])
        revealId = id
    }

    // MARK: Actions

    func transaction(id: Int64) -> Transaction? {
        rows.first { $0.id == id }?.transaction
    }

    /// The transaction whose Budget cell Show in Budget opens: the outgoing leg for an active
    /// link's incoming leg (hidden from the budget; the transfer counts as sent). Nil when
    /// that one has no category with a cell (uncategorised, a reserve).
    func budgetTransaction(forRowId id: Int64) -> Transaction? {
        guard let row = rows.first(where: { $0.id == id }) else { return nil }
        let target = row.outgoingTransactionId.flatMap { transactionsById[$0] } ?? row.transaction
        guard let categoryId = target.categoryId, categories.contains(where: { $0.id == categoryId && !$0.isReserved }) else { return nil }
        return target
    }

    func createCategory(name: String, type: CategoryType, groupId: Int64?) throws -> Category {
        let category = try dbQueue.write(.rulesAndCategories) { db in try Categories.create(db: db, name: name, type: type, groupId: groupId) }
        load()
        return category
    }

    /// Set category… for the selected rows; with `remember`, learns a rule per description
    /// (`TransactionEditing.setCategory`: balance adjustments and market movements are left
    /// alone, and transfer legs never teach a rule). Through the filed-year check, off the main
    /// thread: when it would change a filed return, `filedYearGate` asks once for all the rows.
    func setCategory(ids: [Int64], categoryId: Int64, remember: Bool) {
        guard !ids.isEmpty else { return }
        errorMessage = nil
        let edit = FiledYearEditNames.categorised(categoryId, categories: categories)
        filedYearGate.run(dbQueue, area: .budgetAndAccounts, edit: edit, scope: .categorising(ids, as: categoryId), { db in
            try TransactionEditing.setCategory(db: db, ids: ids, categoryId: categoryId, remember: remember)
        }, done: { [weak self] outcome in
            guard let self else { return }
            let result: SetCategoryResult
            switch outcome {
            case .success(let saved): result = saved
            case .failure(let error as LocalizedError) where error.errorDescription != nil:
                self.errorMessage = error.errorDescription
                return
            case .failure(let error):
                self.errorMessage = "Couldn't set the category: \(error.localizedDescription)"
                return
            }
            self.load()
            if result.skippedBuiltInCount > 0 {
                let count = result.skippedBuiltInCount
                self.errorMessage = "\(count) balance adjustment\(count == 1 ? " was" : "s were") left as \(count == 1 ? "it was" : "they were"): their category is set by the Accounts screen."
            }
            self.onTransactionEdited?()
        })
    }

    /// The Edit transaction sheet's Save (`TransactionEditing.save`), then reload; an edit that
    /// would change a filed return asks first (`FiledYearEditCheck`, plan Task 14).
    func saveTransactionEdit(id: Int64, changes: TransactionEditChanges, gate: FiledYearGate, done: @escaping (SaveOutcome) -> Void) {
        let edit = FiledYearEditNames.transactionEdit(changes, transactionId: id)
        checkedWrite(edit: edit, scope: .transactionEdit(id: id, changes: changes), gate: gate, done: done) { db in
            try TransactionEditing.save(db: db, id: id, changes: changes)
        }
    }

    var manualActions: ManualTransactionActions {
        ManualTransactionActions(
            accounts: accounts,
            delete: { [unowned self] id, gate, done in
                checkedWrite(edit: { _ in "Deleted" }, scope: FiledYearEditCheck.Scope(transactionIds: [id]), gate: gate, done: done) { db in
                    try ManualTransactions.delete(db: db, id: id)
                }
            }
        )
    }

    var transferActions: TransferLinkActions {
        TransferLinkActions.make(dbQueue: dbQueue, accounts: accounts, counterparts: { [unowned self] in transferCounterparts[$0] ?? [] })
    }

    private func manualWrite(_ write: (Database) throws -> Void) -> SaveOutcome {
        do {
            try dbQueue.write(.budgetAndAccounts) { db in try write(db) }
        } catch {
            return .failed(ManualFormat.errorMessage(for: error))
        }
        return afterManualWrite()
    }

    /// A transaction write through the filed-year check (off the main thread; a question shows on
    /// `gate`), then as `manualWrite`. Nothing is reloaded while the question waits.
    private func checkedWrite(edit: @escaping (Database) throws -> String, scope: FiledYearEditCheck.Scope, gate: FiledYearGate,
                              done: @escaping (SaveOutcome) -> Void, _ apply: @escaping (Database) throws -> Void) {
        gate.run(dbQueue, area: .budgetAndAccounts, edit: edit, scope: { _ in scope }, apply) { [weak self] result in
            if let error = result.failure { return done(.failed(ManualFormat.errorMessage(for: error))) }
            done(self?.afterManualWrite() ?? .saved)
        }
    }

    private func afterManualWrite() -> SaveOutcome {
        errorMessage = nil
        load()
        onTransactionEdited?()
        return errorMessage == nil ? .saved : .savedButReloadFailed
    }
}
