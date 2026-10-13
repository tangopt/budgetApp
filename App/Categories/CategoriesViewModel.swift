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
        }
    }
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
            let (categories, groups, all, closes, links, counterparts) = try dbQueue.read { db in
                (try Category.fetchAll(db), try CategoryGroup.fetchAll(db), try Transaction.fetchAll(db), try PayMonthClose.fetchAll(db),
                 try TransferLink.fetchAll(db), try TransferLinks.counterparts(db: db))
            }
            self.categories = categories
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

    /// "+ Group": an untitled group, returned so the screen can put it in inline edit.
    func createGroup() -> CategoryGroup? {
        errorMessage = nil
        do {
            let group = try dbQueue.write { db in try CategoryGroups.createUntitled(db: db) }
            load()
            return group
        } catch {
            errorMessage = "Couldn't create the group: \(error.localizedDescription)"
            return nil
        }
    }

    /// Inline rename; returns false (with `errorMessage` set) to keep the field editing.
    @discardableResult
    func renameGroup(id: Int64, to name: String) -> Bool {
        write("Couldn't rename the group") { db in try CategoryGroups.rename(db: db, id: id, name: name) }
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
        let ids = ids.filter { id in categories.contains { $0.id == id && !$0.isReserved } }
        guard !ids.isEmpty else { return }
        write("Couldn't move the categories") { db in try Categories.move(db: db, ids: ids, toGroupId: groupId) }
    }

    /// A refused delete ("Rent has 73 transactions …") shows as the banner message.
    func deleteCategory(id: Int64) {
        errorMessage = nil
        do {
            try dbQueue.write { db in try Categories.delete(db: db, id: id) }
        } catch let error as CategoryEditError {
            errorMessage = error.localizedDescription
            return
        } catch {
            errorMessage = "Couldn't delete the category: \(error.localizedDescription)"
            return
        }
        load()
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

    // MARK: Side panel

    /// The pay-month year a transaction belongs to (as on the Budget grid).
    func payYear(of transaction: Transaction) -> Int {
        payCalendar.month(containing: transaction.date).year
    }

    /// The category's confirmed transactions in the pay-month `year` (nil = all years).
    func transactions(forCategoryId id: Int64, year: Int?) -> [Transaction] {
        transactions.filter { $0.categoryId == id && (year == nil || payYear(of: $0) == year) }
    }

    /// The years the panel's filter offers: the current one, then any with transactions, newest first.
    func years(forCategoryId id: Int64) -> [Int] {
        var years = Set(transactions.filter { $0.categoryId == id }.map(payYear(of:)))
        years.insert(payCalendar.current.year)
        return years.sorted(by: >)
    }

    /// The Edit transaction sheet's save: category and note (no rule learned), then reload.
    func editTransaction(id: Int64, categoryId: Int64?, note: String?) -> SaveOutcome {
        do {
            try dbQueue.write { db in try TransactionEditing.update(db: db, id: id, categoryId: categoryId, note: note) }
        } catch {
            return .failed(error.localizedDescription)
        }
        load()
        onTransactionEdited?()
        return .saved
    }

    /// Edit transaction's Unlink / Link to transfer… (spec §6), each followed by a reload.
    var transferActions: TransferLinkActions {
        TransferLinkActions.make(dbQueue: dbQueue, counterparts: { [unowned self] in transferCounterparts[$0] ?? [] }) { [unowned self] in
            errorMessage = nil
            load()
            onTransactionEdited?()
            return errorMessage == nil
        }
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
