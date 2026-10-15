// App/Accounts/AccountsViewModel.swift
import Foundation
import BudgetCore
import struct BudgetCore.Category
import GRDB

/// What a sheet's save did. Sheets dismiss on both saved outcomes; `.failed` carries the
/// message the sheet shows itself. `.savedButReloadFailed` leaves a "Saved, but …" message
/// in the screen's `errorMessage` banner (retrying would write the change twice).
enum SaveOutcome: Equatable {
    case saved
    case savedButReloadFailed
    case failed(String)
}

@MainActor
final class AccountsViewModel: ObservableObject {
    @Published private(set) var overview: AccountsOverview?
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var rate: ExchangeRateSetting = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
    /// Defaults to the first row after a load; kept across loads while it still exists.
    @Published var selectedAccountId: Int64? {
        didSet { if selectedAccountId != oldValue { updateSelectedHistory() } }
    }
    /// The selected account's snapshots, newest first.
    @Published private(set) var selectedHistory: [BalanceSnapshot] = []
    /// The screen's banner error (load failures, "Saved, but …"). Sheets keep their own.
    @Published var errorMessage: String?
    /// What the last Update balance did, one line per account ("added a Market movement of
    /// £120.00", "balance already matches").
    @Published var balanceMessages: [String] = []

    /// Add transaction…'s category picker: read when the sheet opens (`prepareAddTransaction`);
    /// "New category…" adds to it.
    @Published private(set) var categories: [Category] = []
    @Published private(set) var categoryGroups: [CategoryGroup] = []
    @Published private(set) var recentCategoryIds: [Int64] = []
    /// Runs after Add transaction… saves (ContentView refreshes the uncategorised count).
    var onTransactionAdded: (() -> Void)?

    private var snapshots: [BalanceSnapshot] = []
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// Returns false (with `errorMessage` set) when the read fails; `overview` then keeps
    /// its previous value — nil if nothing has loaded yet. A successful load clears
    /// `errorMessage`.
    @discardableResult
    func load() -> Bool {
        do {
            let (accounts, snapshots, transactions, rate) = try dbQueue.read { db in
                (try Account.fetchAll(db), try BalanceSnapshot.fetchAll(db), try Transaction.fetchAll(db), try ExchangeRateSetting.currentOrDefault(db: db))
            }
            self.accounts = accounts.sortedForDisplay()
            self.snapshots = snapshots
            self.rate = rate
            let overview = AccountsOverview.make(accounts: accounts, snapshots: snapshots, transactions: transactions, rate: rate, today: Date())
            self.overview = overview
            let rowIds = overview.groups.flatMap(\.rows).map(\.id)
            if selectedAccountId.map(rowIds.contains) != true { selectedAccountId = rowIds.first }
            // Snapshots may have changed even when the selection didn't.
            updateSelectedHistory()
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Couldn't load accounts: \(error.localizedDescription)"
            return false
        }
    }

    var selectedRow: AccountRow? {
        overview?.groups.flatMap(\.rows).first { $0.id == selectedAccountId }
    }

    func addAccount(name: String, currency: Currency, kind: AccountKind, openingBalanceEntered: Int?, asOf: Date, details: AccountDetails) -> SaveOutcome {
        perform { db in
            let account = try AccountEditing.add(db: db, name: name, currency: currency, kind: kind, openingBalanceEntered: openingBalanceEntered, asOf: asOf, details: details)
            return account.id
        } onSuccess: { [weak self] id in
            self?.selectedAccountId = id
        }
    }

    func updateAccount(id: Int64, name: String, kind: AccountKind, details: AccountDetails) -> SaveOutcome {
        perform { db in
            try AccountEditing.update(db: db, accountId: id, name: name, kind: kind, details: details)
        }
    }

    /// Drag and drop within one kind's section: `ids` are that section's accounts in their
    /// displayed order. Saves the shared order (`AccountOrdering`) and reloads; a failure
    /// shows in the banner.
    func moveAccounts(ids: [Int64], fromOffsets: IndexSet, toOffset: Int) {
        do {
            try dbQueue.write { db in try AccountOrdering.move(db: db, ids: ids, fromOffsets: fromOffsets, toOffset: toOffset) }
        } catch {
            errorMessage = "Couldn't reorder accounts: \(error.localizedDescription)"
            return
        }
        load()
    }

    func hasHistory(_ id: Int64) -> Bool {
        (try? dbQueue.read { db in try AccountEditing.hasHistory(db: db, accountId: id) }) ?? true
    }

    /// What Update balance as of `asOf` compares against for each account: its computed
    /// signed balance at the end of that day, or the message for a recorded balance on or
    /// after it (which blocks the update). One read for all of them; absent when it fails.
    func balanceBaselines(accountIds: [Int64], asOf: Date) -> [Int64: BalanceBaseline] {
        let result = try? dbQueue.read { db -> [Int64: BalanceBaseline] in
            var baselines: [Int64: BalanceBaseline] = [:]
            for id in accountIds {
                guard let account = try Account.fetchOne(db, key: id) else { continue }
                if let blocking = try BalanceUpdates.blockingBalanceDate(db: db, accountId: id, asOf: asOf) {
                    baselines[id] = .blocked(BalanceUpdateError.recordedBalance(accountName: account.displayName, date: blocking).errorDescription ?? "Pick a later date.")
                } else {
                    baselines[id] = .computed(try BalanceUpdates.computedBalance(db: db, accountId: id, asOf: asOf))
                }
            }
            return baselines
        }
        return result ?? [:]
    }

    /// Update balance… (single or bulk): each difference becomes an adjustment transaction
    /// (`BalanceUpdates.save`); `balanceMessages` says what happened per account.
    func saveBalances(_ entries: [BalanceUpdates.Entry], asOf: Date) -> SaveOutcome {
        perform { db in
            try BalanceUpdates.save(db: db, entries: entries, asOf: asOf)
        } onSuccess: { [weak self] outcomes in
            self?.balanceMessages = outcomes.map(Self.message(for:))
        }
    }

    static func message(for outcome: BalanceUpdates.Outcome) -> String {
        guard let role = outcome.role, outcome.differenceMinorUnits != 0 else {
            return "\(outcome.accountName): balance already matches — nothing added."
        }
        let amount = Money.format(outcome.differenceMinorUnits, currency: outcome.currency)
        return "\(outcome.accountName): added a \(role.defaultName.lowercased()) of \(outcome.differenceMinorUnits > 0 ? "+" : "")\(amount)."
    }

    /// Write first, then reload. A failed write returns `.failed` with a message for the
    /// sheet and leaves the screen's `errorMessage` alone. A failed reload after a successful
    /// write returns `.savedButReloadFailed` with a "Saved, but …" banner message, so the
    /// sheet closes instead of inviting a retry that would save the change twice.
    private func perform<T>(_ write: (Database) throws -> T, onSuccess: ((T) -> Void)? = nil) -> SaveOutcome {
        let result: T
        do {
            result = try dbQueue.write { db in try write(db) }
        } catch {
            return .failed(Self.message(for: error))
        }
        let reloaded = load()
        onSuccess?(result)
        guard reloaded else {
            errorMessage = "Saved, but " + (errorMessage.map { $0.prefix(1).lowercased() + $0.dropFirst() } ?? "couldn't reload accounts.")
            return .savedButReloadFailed
        }
        return .saved
    }

    // MARK: Add transaction… (spec 2026-10-14 §2)

    /// Reads the categories, groups and recent categories for Add transaction…'s picker;
    /// a failed read leaves the picker with what it had.
    func prepareAddTransaction() {
        let since = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        if let (categories, groups) = try? dbQueue.read({ db in (try Category.fetchAll(db), try CategoryGroup.fetchAll(db)) }) {
            self.categories = categories
            categoryGroups = groups
        }
        recentCategoryIds = (try? dbQueue.read { db in try CategoryShortlist.recent(db: db, since: since, limit: 5) }) ?? []
    }

    /// The picker's "New category…": creates the category and re-reads the list.
    func createCategory(name: String, type: CategoryType, groupId: Int64?) throws -> Category {
        let category = try dbQueue.write { db in try Categories.create(db: db, name: name, type: type, groupId: groupId) }
        if let reloaded = try? dbQueue.read({ db in try Category.fetchAll(db) }) {
            categories = reloaded
        } else {
            categories.append(category)
        }
        return category
    }

    /// Add transaction…'s save (`ManualTransactions.add`), then the screen reloads (an
    /// imported account's balance includes it) and `onTransactionAdded` runs.
    func addTransaction(_ input: ManualTransactionInput) -> SaveOutcome {
        do {
            try dbQueue.write { db in
                _ = try ManualTransactions.add(db: db, accountId: input.accountId, date: input.date, description: input.description,
                                               amountMinorUnits: input.amountMinorUnits, categoryId: input.categoryId, note: input.note)
            }
        } catch {
            return .failed(ManualFormat.errorMessage(for: error))
        }
        let reloaded = load()
        onTransactionAdded?()
        guard reloaded else {
            errorMessage = "Saved, but " + (errorMessage.map { $0.prefix(1).lowercased() + $0.dropFirst() } ?? "couldn't reload accounts.")
            return .savedButReloadFailed
        }
        return .saved
    }

    private func updateSelectedHistory() {
        selectedHistory = snapshots
            .filter { $0.accountId == selectedAccountId }
            .sorted { $0.date != $1.date ? $0.date > $1.date : ($0.id ?? 0) > ($1.id ?? 0) }
    }

    static func message(for error: Error) -> String {
        if let detailsError = error as? AccountDetailsError { return detailsError.errorDescription ?? "Check the account details." }
        if let balanceError = error as? BalanceUpdateError { return balanceError.errorDescription ?? "Pick a later day." }
        switch error as? AccountEditError {
        case .emptyName: return "Enter a name."
        case .duplicateName: return "An account with that name already exists."
        case .creditKindChange: return "Can't change to or from credit once the account has balances or transactions."
        case .accountNotFound: return "That account no longer exists."
        case nil: return "Couldn't save: \(error.localizedDescription)"
        }
    }
}
