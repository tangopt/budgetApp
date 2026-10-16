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
    /// Linked transfers' other legs by transaction id, for the side panel and Edit transaction.
    @Published private(set) var transferCounterparts: [Int64: [TransferCounterpart]] = [:]
    /// Average monthly actual over the last 12 pay months (`CategoryStats`); absent = "—".
    @Published private(set) var averages: [Int64: Int] = [:]
    /// Every account in the order the app lists them (Edit transaction's account picker and
    /// Add the other side…).
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var payCalendar = PayCalendar(salaryDates: [], manualCloses: [], today: Date())
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
            let (categories, groups, all, closes, links, counterparts, accounts) = try dbQueue.read { db in
                (try Category.fetchAll(db), try CategoryGroup.fetchAll(db), try Transaction.fetchAll(db), try PayMonthClose.fetchAll(db),
                 try TransferLink.fetchAll(db), try TransferLinks.counterparts(db: db), try Account.fetchAll(db))
            }
            self.categories = categories
            self.accounts = accounts.sortedForDisplay()
            self.groups = groups
            payCalendar = PayCalendar(salaryDates: PaydaySource.paydayDates(transactions: all, categories: categories),
                                      manualCloses: closes, today: Date())
            transferCounterparts = counterparts
            transactions = TransferLinks.budgetFacing(all, links: links).filter { $0.status == .confirmed && $0.categoryId != nil }
            averages = CategoryStats.monthlyAverages(transactions: transactions, calendar: payCalendar)
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
    func createGroup(name: String, type: CategoryType, moving categoryIds: [Int64]) throws -> CategoryGroup {
        let group = try dbQueue.write { db in try CategoryGroups.create(db: db, name: name, type: type, moving: categoryIds) }
        errorMessage = nil
        load()
        return group
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

    func deleteGroup(id: Int64) {
        write("Couldn't delete the group") { db in try CategoryGroups.delete(db: db, id: id) }
    }

    // MARK: Categories

    /// The New category sheet's save.
    func createCategory(name: String, type: CategoryType, groupId: Int64?) throws -> Category {
        let category = try dbQueue.write { db in try Categories.create(db: db, name: name, type: type, groupId: groupId) }
        load()
        return category
    }

    /// The Rename… sheet's save: a blank or taken name keeps the sheet open with the message.
    func renameCategory(id: Int64, to name: String) -> SaveOutcome {
        do {
            try dbQueue.write { db in try Categories.rename(db: db, id: id, name: name) }
        } catch {
            return .failed(error.localizedDescription)
        }
        load()
        return .saved
    }

    func move(ids: [Int64], toGroupId groupId: Int64?) {
        let ids = ids.filter { id in categories.contains { $0.id == id && !$0.isReserved && !$0.isBuiltIn } }
        guard !ids.isEmpty else { return }
        write("Couldn't move the categories") { db in try Categories.move(db: db, ids: ids, toGroupId: groupId) }
    }

    /// Deletes each category in turn under `Categories.delete`'s rules; the refusals ("Rent
    /// has 73 transactions …") are listed in the banner, one per line.
    func deleteCategories(ids: [Int64]) {
        errorMessage = nil
        var refusals: [String] = []
        for id in ids {
            do {
                try dbQueue.write { db in try Categories.delete(db: db, id: id) }
            } catch let error as CategoryEditError {
                refusals.append(error.localizedDescription)
            } catch {
                refusals.append("Couldn't delete the category: \(error.localizedDescription)")
            }
        }
        load()
        if !refusals.isEmpty {
            errorMessage = ([errorMessage].compactMap { $0 } + refusals).joined(separator: "\n")
        }
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
        CategoryDistribution.compute(year: year, transactions: transactions, categories: categories, groups: groups, calendar: payCalendar)
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
    /// (no rule learned), then reload. A refusal writes nothing.
    func saveTransactionEdit(id: Int64, changes: TransactionEditChanges) -> SaveOutcome {
        manualWrite { db in try TransactionEditing.save(db: db, id: id, changes: changes) }
    }

    /// Edit transaction's Delete… for a transaction added by hand (`ManualTransactions.delete`), then reload.
    var manualActions: ManualTransactionActions {
        ManualTransactionActions(
            accounts: accounts,
            delete: { [unowned self] id in manualWrite { db in try ManualTransactions.delete(db: db, id: id) } }
        )
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

    /// Edit transaction's transfer row: linked legs, Link to transfer…'s candidates and Add
    /// the other side…'s accounts (the changes are written by Save).
    var transferActions: TransferLinkActions {
        TransferLinkActions.make(dbQueue: dbQueue, accounts: accounts, counterparts: { [unowned self] in transferCounterparts[$0] ?? [] })
    }

    /// The Edit transaction picker's Recent section: the last 90 days' most used
    /// categories. A failed read only costs the section.
    func recentCategoryIds() -> [Int64] {
        let since = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        return (try? dbQueue.read { db in try CategoryShortlist.recent(db: db, since: since, limit: 5) }) ?? []
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
