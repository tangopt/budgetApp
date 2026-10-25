// App/Categories/CategoriesViewModel.swift
import Foundation
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction
import GRDB

extension CategorySection {
    var title: String {
        switch type {
        case .expense: return "Expenses"
        case .income: return "Income"
        case .transfer: return "Transfers"
        case .adjustment: return "Adjustments"
        }
    }
}

/// A Distribution donut, for its colour slots (`CategoriesViewModel.distributionColorSlots`).
enum DistributionDonutKind: Equatable {
    case expenseGroups
    /// One expense group's categories; nil = Ungrouped.
    case expenseCategories(groupId: Int64?)
    case income
}

@MainActor
final class CategoriesViewModel: ObservableObject {
    @Published private(set) var categories: [Category] = []
    @Published private(set) var groups: [CategoryGroup] = []
    /// Confirmed, categorised, budget-facing transactions (the side panel and the averages):
    /// a linked transfer counts once, as sent (`TransferLinks.budgetFacing`).
    @Published private(set) var transactions: [Transaction] = []
    /// `transactions` in GBP (`CurrencyConversion`): the averages and the distribution. The
    /// side panel lists `transactions` in each account's own currency.
    private var gbpTransactions: [Transaction] = []
    /// Non-GBP accounts at the stored rate, for the side panel's currencies and total.
    @Published private(set) var conversion = CurrencyConversion.none
    /// Linked transfers' other legs by transaction id, for the side panel and Edit transaction.
    @Published private(set) var transferCounterparts: [Int64: [TransferCounterpart]] = [:]
    /// Average monthly actual over the last 12 pay months (`CategoryStats`); absent = "—".
    @Published private(set) var averages: [Int64: Int] = [:]
    /// Every account in the order the app lists them (Edit transaction's account picker and
    /// Add the other side…).
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var payCalendar = PayCalendar(salaryDates: [], manualCloses: [], today: AppClock.now)
    /// The screen's banner error (load failures, a failed move or rename, a refused delete).
    @Published var errorMessage: String?
    /// Runs after an Edit transaction save (the uncategorised count may change).
    var onTransactionEdited: (() -> Void)?
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func load() {
        do {
            let (categories, groups, all, closes, links, counterparts, accounts, rate) = try dbQueue.read { db in
                (try Category.fetchAll(db), try CategoryGroup.fetchAll(db), try Transaction.fetchAll(db), try PayMonthClose.fetchAll(db),
                 try TransferLink.fetchAll(db), try TransferLinks.counterparts(db: db), try Account.fetchAll(db), try ExchangeRateSetting.currentOrDefault(db: db))
            }
            propertyGroupIds = (try? dbQueue.read { db in Set(try Int64.fetchAll(db, sql: "SELECT categoryGroupId FROM propertyCategoryGroup")) }) ?? []
            self.categories = categories
            self.accounts = accounts.sortedForDisplay()
            self.groups = groups
            payCalendar = PayCalendar(salaryDates: PaydaySource.paydayDates(transactions: all, categories: categories),
                                      manualCloses: closes, today: AppClock.now)
            transferCounterparts = counterparts
            transactions = TransferLinks.budgetFacing(all, links: links).filter { $0.status == .confirmed && $0.categoryId != nil }
            conversion = CurrencyConversion(accounts: accounts, rate: rate)
            gbpTransactions = conversion.toGBP(transactions)
            averages = CategoryStats.monthlyAverages(transactions: gbpTransactions, calendar: payCalendar)
        } catch {
            errorMessage = "Couldn't load categories: \(error.localizedDescription)"
        }
    }

    // MARK: Sections

    var categoryNameById: [Int64: String] {
        Dictionary(categories.compactMap { c in c.id.map { ($0, c.name) } }, uniquingKeysWith: { a, _ in a })
    }

    /// The type sections, filtered by `search` (`CategorySections.build`).
    func sections(search: String) -> [CategorySection] {
        CategorySections.build(categories: categories, groups: groups, search: search)
    }

    /// Reserves, read-only here (managed on the Budget grid).
    func reserves(search: String) -> [Category] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return categories.filter { $0.isReserved && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Groups

    /// The New group sheet's save: the group of `type`, with `categoryIds` moved into it, in
    /// one write (a refused name or a built-in member creates nothing).
    /// Through the filed-year check: moving a property's categories out of its group moves rental figures.
    func createGroup(name: String, type: CategoryType, moving categoryIds: [Int64], gate: FiledYearGate,
                     done: @escaping (Result<CategoryGroup, Error>) -> Void) {
        gate.run(dbQueue, edit: "Categories moved to a new group \(name)", scope: { db in try .categories(db: db, ids: categoryIds) }, { db in
            try CategoryGroups.create(db: db, name: name, type: type, moving: categoryIds)
        }, done: { [weak self] result in
            if case .success = result {
                self?.errorMessage = nil
                self?.load()
            }
            done(result)
        })
    }

    /// The Rename… sheet's save: a blank or taken name keeps the sheet open with the message.
    func renameGroup(id: Int64, to name: String) -> SaveOutcome {
        do {
            try dbQueue.write { db in try CategoryGroups.rename(db: db, id: id, name: name) }
        } catch {
            return .failed(error.localizedDescription)
        }
        load()
        return .saved
    }

    /// The group's (non-reserve) categories, of every type.
    func members(ofGroupId id: Int64) -> [Category] {
        categories.filter { $0.groupId == id && !$0.isReserved }
    }

    /// Through the filed-year check: a property's group's categories leave the rental accounts.
    func deleteGroup(id: Int64) {
        let name = groups.first { $0.id == id }?.name ?? "a group"
        checked("Couldn't delete the group", edit: "Group \(name) deleted",
                scope: { db in try .categories(db: db, groupIds: [id]) }) { db in try CategoryGroups.delete(db: db, id: id) }
    }

    // MARK: Categories

    /// The New category sheet's save.
    func createCategory(name: String, type: CategoryType, groupId: Int64?) throws -> Category {
        let category = try dbQueue.write { db in try Categories.create(db: db, name: name, type: type, groupId: groupId) }
        load()
        return category
    }

    /// The Rename… sheet's save: a blank or taken name keeps the sheet open with the message. A
    /// property's category (its name can suggest its tax line) is renamed through the filed-year
    /// check instead: the sheet closes and the screen asks when it would change a filed return.
    func renameCategory(id: Int64, to name: String) -> SaveOutcome {
        let isPropertyCategory = categories.first { $0.id == id }?.groupId.map(propertyGroupIds.contains) ?? false
        if isPropertyCategory {
            let old = categories.first { $0.id == id }?.name ?? "a category"
            checked("Couldn't rename the category", edit: "Category \(old) renamed \(name)",
                    scope: { db in try .categories(db: db, ids: [id]) }) { db in try Categories.rename(db: db, id: id, name: name) }
            return .saved
        }
        do {
            try dbQueue.write { db in try Categories.rename(db: db, id: id, name: name) }
        } catch {
            return .failed(error.localizedDescription)
        }
        load()
        return .saved
    }

    /// Through the filed-year check: into or out of a property's group moves rental figures.
    func move(ids: [Int64], toGroupId groupId: Int64?) {
        let ids = ids.filter { id in categories.contains { $0.id == id && !$0.isReserved && !$0.isBuiltIn } }
        guard !ids.isEmpty else { return }
        let target = groupId.flatMap { id in groups.first { $0.id == id }?.name } ?? "Ungrouped"
        checked("Couldn't move the categories", edit: "Categories moved to \(target)",
                scope: { db in try .categories(db: db, ids: ids, groupIds: groupId.map { [$0] } ?? []) }) { db in
            try Categories.move(db: db, ids: ids, toGroupId: groupId)
        }
    }

    /// Deletes each category in turn under `Categories.delete`'s rules; the refusals ("Rent
    /// has 73 transactions …") are listed in the banner, one per line. One write through the
    /// filed-year check (a property's category's transactions leave the rental accounts).
    func deleteCategories(ids: [Int64]) {
        let names = ids.compactMap { id in categories.first { $0.id == id }?.name }
        checked("Couldn't delete the category", edit: "Categor\(names.count == 1 ? "y" : "ies") \(names.joined(separator: ", ")) deleted",
                scope: { db in try .categories(db: db, ids: ids) }, { db -> [String] in
            var refusals: [String] = []
            for id in ids {
                try db.inSavepoint {
                    do {
                        try Categories.delete(db: db, id: id)
                        return .commit
                    } catch let error as CategoryEditError {
                        refusals.append(error.localizedDescription)
                        return .rollback
                    }
                }
            }
            return refusals
        }, done: { [weak self] refusals in
            guard let self, !refusals.isEmpty else { return }
            self.errorMessage = ([self.errorMessage].compactMap { $0 } + refusals).joined(separator: "\n")
        })
    }


    /// "Covered by a reserve": the auto-forecast leaves this category alone (and its
    /// existing auto entries are removed when turning this on).
    func setExcludedFromAutoForecast(id: Int64, excluded: Bool) {
        write("Couldn't change the auto-forecast setting") { db in
            try ReservedCategories.setExcludedFromAutoForecast(db: db, categoryId: id, excluded)
        }
    }

    /// The category's own icon; nil goes back to the type's generic one.
    func setIcon(id: Int64, iconName: String?) {
        write("Couldn't change the icon") { db in
            try Categories.setIcon(db: db, id: id, iconName: iconName)
        }
    }

    /// "Money goes to an account you don't import — never match" (spec §6): turning it on
    /// unlinks the category's automatic transfer links.
    func setExternalTransfer(id: Int64, external: Bool) {
        write("Couldn't change the transfer setting") { db in
            try TransferLinks.setExternalTransfer(db: db, categoryId: id, external)
        }
    }

    /// The account a transfer category is linked to (spec 2026-10-14 §4), if any.
    func linkedAccount(of category: Category) -> Account? {
        guard let accountId = category.transferAccountId else { return nil }
        return accounts.first { $0.id == accountId }
    }

    /// The category linked to `accountId`, if any.
    func linkedCategory(forAccountId accountId: Int64?) -> Category? {
        guard let accountId else { return nil }
        return categories.first { $0.transferAccountId == accountId }
    }

    /// Linked account: ties the transfer category to the account (renamed "Transfer:
    /// <account>" when that name is free).
    func setLinkedAccount(id: Int64, accountId: Int64) {
        write("Couldn't change the linked account") { db in
            try TransferCategories.setLinkedAccount(db: db, categoryId: id, accountId: accountId)
        }
    }

    // MARK: Side panel

    /// The pay-month year a transaction belongs to (as on the Budget grid).
    func payYear(of transaction: Transaction) -> Int {
        payCalendar.month(containing: transaction.date).year
    }

    /// The confirmed transactions of the categories in `ids` (one category, or a group's
    /// members) in the pay-month `year` (nil = all years).
    func transactions(forCategoryIds ids: Set<Int64>, year: Int?) -> [Transaction] {
        transactions.filter { $0.categoryId.map(ids.contains) == true && (year == nil || payYear(of: $0) == year) }
    }

    /// The years the panel's filter offers: the current one, then any with transactions, newest first.
    func years(forCategoryIds ids: Set<Int64>) -> [Int] {
        var years = Set(transactions.filter { $0.categoryId.map(ids.contains) == true }.map(payYear(of:)))
        years.insert(payCalendar.current.year)
        return years.sorted(by: >)
    }

    // MARK: Distribution

    /// The Distribution panel's figures for the pay-month `year` (nil = all years): the
    /// Budget grid's actuals basis (`CategoryDistribution`; `transactions` are budget-facing).
    func distribution(year: Int?) -> CategoryDistribution {
        CategoryDistribution.compute(year: year, transactions: gbpTransactions, categories: categories, groups: groups, calendar: payCalendar)
    }

    /// The Distribution panel's year filter: the current year (the default), then any with
    /// income or expense actuals, newest first.
    var distributionYears: [Int] {
        let flowIds = Set(categories.filter { $0.type.isFlow }.compactMap(\.id))
        var years = Set(transactions.filter { $0.categoryId.map(flowIds.contains) == true }.map(payYear(of:)))
        years.insert(payCalendar.current.year)
        return years.sorted(by: >)
    }

    /// Each possible slice's palette slot in a Distribution donut, by slice id, so an entity
    /// keeps its colour whatever the year or its rank: the groups donut slots Ungrouped
    /// first, then every group by id; a group's donut (`groupId`, nil = Ungrouped) every
    /// expense category of that group by id; the income donut every income category by id.
    func distributionColorSlots(_ donut: DistributionDonutKind) -> [String: Int] {
        let ids: [String]
        let groupIds = Set(groups.compactMap(\.id))
        let assignable = categories.filter { !$0.isReserved }
        switch donut {
        case .expenseGroups:
            ids = ["g-ungrouped"] + groups.compactMap(\.id).sorted().map { "g-\($0)" }
        case .expenseCategories(let groupId):
            ids = assignable.filter { category in
                category.type == .expense && (category.groupId.flatMap { groupIds.contains($0) ? $0 : nil }) == groupId
            }.compactMap(\.id).sorted().map { "c-\($0)" }
        case .income:
            ids = assignable.filter { $0.type == .income }.compactMap(\.id).sorted().map { "c-\($0)" }
        }
        return Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// The Edit transaction sheet's Save: category and note (or a manual transaction's
    /// fields) and the pending transfer change, in one write via `TransactionEditing.save`
    /// (no rule learned), then reload. A refusal writes nothing; an edit that would change a
    /// filed return asks first (`FiledYearEditCheck`, plan Task 14).
    func saveTransactionEdit(id: Int64, changes: TransactionEditChanges, gate: FiledYearGate, done: @escaping (SaveOutcome) -> Void) {
        let edit = FiledYearEditNames.transactionEdit(changes, transactionId: id)
        checkedWrite(edit: edit, scope: .transactionEdit(id: id, changes: changes), gate: gate, done: done) { db in
            try TransactionEditing.save(db: db, id: id, changes: changes)
        }
    }

    /// Edit transaction's Delete… for a transaction added by hand (`ManualTransactions.delete`), then reload.
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

    private func manualWrite(_ write: (Database) throws -> Void) -> SaveOutcome {
        do {
            try dbQueue.write { db in try write(db) }
        } catch {
            return .failed(ManualFormat.errorMessage(for: error))
        }
        return afterManualWrite()
    }

    /// A transaction write through the filed-year check (off the main thread; a question shows on
    /// `gate`), then as `manualWrite`. Nothing is reloaded while the question waits.
    private func checkedWrite(edit: @escaping (Database) throws -> String, scope: FiledYearEditCheck.Scope, gate: FiledYearGate,
                              done: @escaping (SaveOutcome) -> Void, _ apply: @escaping (Database) throws -> Void) {
        gate.run(dbQueue, edit: edit, scope: { _ in scope }, apply) { [weak self] result in
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

    /// Edit transaction's transfer row: linked legs, Link to transfer…'s candidates and Add
    /// the other side…'s accounts (the changes are written by Save).
    var transferActions: TransferLinkActions {
        TransferLinkActions.make(dbQueue: dbQueue, accounts: accounts, counterparts: { [unowned self] in transferCounterparts[$0] ?? [] })
    }

    /// The Edit transaction picker's Recent section: the last 90 days' most used
    /// categories. A failed read only costs the section.
    func recentCategoryIds() -> [Int64] {
        let since = Calendar.current.date(byAdding: .day, value: -90, to: AppClock.now) ?? AppClock.now
        return (try? dbQueue.read { db in try CategoryShortlist.recent(db: db, since: since, limit: 5) }) ?? []
    }

    /// The category groups a property has (a rename of their categories goes through the check).
    private var propertyGroupIds: Set<Int64> = []

    /// The screen's structure edits through the filed-year check (plan Task 14); its question shows on the screen.
    let filedYearGate = FiledYearGate()

    /// `change` through the filed-year check, off the main thread; then reloads (and `done`), or sets
    /// `errorMessage` ("<prefix>: …"). Cancel writes and changes nothing.
    private func checked<T>(_ prefix: String, edit: String, scope: @escaping (Database) throws -> FiledYearEditCheck.Scope,
                            _ change: @escaping (Database) throws -> T, done: ((T) -> Void)? = nil) {
        errorMessage = nil
        filedYearGate.run(dbQueue, edit: edit, scope: scope, change) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                self.load()
                done?(value)
            case .failure(let error as LocalizedError) where error.errorDescription != nil:
                self.errorMessage = error.errorDescription
            case .failure(let error):
                self.errorMessage = "\(prefix): \(error.localizedDescription)"
            }
        }
    }

    /// Writes, then reloads; on failure sets `errorMessage` ("<prefix>: …") and returns false.
    @discardableResult
    private func write(_ prefix: String, _ change: (Database) throws -> Void) -> Bool {
        errorMessage = nil
        do {
            try dbQueue.write { db in try change(db) }
        } catch let error as LocalizedError where error.errorDescription != nil {
            errorMessage = error.errorDescription
            return false
        } catch {
            errorMessage = "\(prefix): \(error.localizedDescription)"
            return false
        }
        load()
        return true
    }
}
