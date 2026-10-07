// App/Accounts/AccountsViewModel.swift
import Foundation
import BudgetCore
import GRDB

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
    @Published var errorMessage: String?
    /// Reconciliation warnings from the last balance save.
    @Published var warnings: [String] = []

    private var snapshots: [BalanceSnapshot] = []
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// Returns false (with `errorMessage` set) when the read fails; `overview` then keeps
    /// its previous value — nil if nothing has loaded yet.
    @discardableResult
    func load() -> Bool {
        do {
            let (accounts, snapshots, transactions, rate) = try dbQueue.read { db in
                (try Account.fetchAll(db), try BalanceSnapshot.fetchAll(db), try Transaction.fetchAll(db), try ExchangeRateSetting.currentOrDefault(db: db))
            }
            self.accounts = accounts
            self.snapshots = snapshots
            self.rate = rate
            let overview = AccountsOverview.make(accounts: accounts, snapshots: snapshots, transactions: transactions, rate: rate, today: Date())
            self.overview = overview
            let rowIds = overview.groups.flatMap(\.rows).map(\.id)
            if selectedAccountId.map(rowIds.contains) != true { selectedAccountId = rowIds.first }
            // Snapshots may have changed even when the selection didn't.
            updateSelectedHistory()
            return true
        } catch {
            errorMessage = "Couldn't load accounts: \(error.localizedDescription)"
            return false
        }
    }

    var selectedRow: AccountRow? {
        overview?.groups.flatMap(\.rows).first { $0.id == selectedAccountId }
    }

    @discardableResult
    func addAccount(name: String, currency: Currency, kind: AccountKind, trackingMode: AccountTrackingMode, openingBalanceEntered: Int?, asOf: Date) -> Bool {
        perform { db in
            let account = try AccountEditing.add(db: db, name: name, currency: currency, kind: kind, trackingMode: trackingMode, openingBalanceEntered: openingBalanceEntered, asOf: asOf)
            return account.id
        } onSuccess: { [weak self] id in
            self?.selectedAccountId = id
        }
    }

    @discardableResult
    func updateAccount(id: Int64, name: String, kind: AccountKind, trackingMode: AccountTrackingMode) -> Bool {
        perform { db in
            try AccountEditing.update(db: db, accountId: id, name: name, kind: kind, trackingMode: trackingMode)
        }
    }

    func hasHistory(_ id: Int64) -> Bool {
        (try? dbQueue.read { db in try AccountEditing.hasHistory(db: db, accountId: id) }) ?? true
    }

    @discardableResult
    func saveBalances(_ entries: [BalanceUpdates.Entry], asOf: Date) -> Bool {
        perform { db in
            try BalanceUpdates.save(db: db, entries: entries, asOf: asOf)
        } onSuccess: { [weak self] result in
            self?.warnings = result.map {
                "\($0.accountName): entered balance differs from the computed running balance by \(Money.format($0.driftMinorUnits, currency: $0.currency)) — check for a missing or duplicate transaction."
            }
        }
    }

    /// Write first, then reload; any error lands in `errorMessage` and returns false. A
    /// failed reload after a successful write also returns false, with a message saying the
    /// change was saved, so callers don't carry on as if the screen were up to date.
    private func perform<T>(_ write: (Database) throws -> T, onSuccess: ((T) -> Void)? = nil) -> Bool {
        errorMessage = nil
        do {
            let result = try dbQueue.write { db in try write(db) }
            let reloaded = load()
            onSuccess?(result)
            if !reloaded {
                errorMessage = "Saved, but " + (errorMessage.map { $0.prefix(1).lowercased() + $0.dropFirst() } ?? "couldn't reload accounts.")
                return false
            }
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    private func updateSelectedHistory() {
        selectedHistory = snapshots
            .filter { $0.accountId == selectedAccountId }
            .sorted { $0.date != $1.date ? $0.date > $1.date : ($0.id ?? 0) > ($1.id ?? 0) }
    }

    static func message(for error: Error) -> String {
        switch error as? AccountEditError {
        case .emptyName: return "Enter a name."
        case .duplicateName: return "An account with that name already exists."
        case .creditKindChange: return "Can't change to or from credit once the account has balances or transactions."
        case .accountNotFound: return "That account no longer exists."
        case nil: return "Couldn't save: \(error.localizedDescription)"
        }
    }
}
