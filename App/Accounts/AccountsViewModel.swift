// App/Accounts/AccountsViewModel.swift
import Foundation
import BudgetCore
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
    /// Reconciliation warnings from the last balance save.
    @Published var warnings: [String] = []

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
            self.accounts = accounts
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

    func addAccount(name: String, currency: Currency, kind: AccountKind, trackingMode: AccountTrackingMode, openingBalanceEntered: Int?, asOf: Date) -> SaveOutcome {
        perform { db in
            let account = try AccountEditing.add(db: db, name: name, currency: currency, kind: kind, trackingMode: trackingMode, openingBalanceEntered: openingBalanceEntered, asOf: asOf)
            return account.id
        } onSuccess: { [weak self] id in
            self?.selectedAccountId = id
        }
    }

    func updateAccount(id: Int64, name: String, kind: AccountKind, trackingMode: AccountTrackingMode) -> SaveOutcome {
        perform { db in
            try AccountEditing.update(db: db, accountId: id, name: name, kind: kind, trackingMode: trackingMode)
        }
    }

    func hasHistory(_ id: Int64) -> Bool {
        (try? dbQueue.read { db in try AccountEditing.hasHistory(db: db, accountId: id) }) ?? true
    }

    func saveBalances(_ entries: [BalanceUpdates.Entry], asOf: Date) -> SaveOutcome {
        perform { db in
            try BalanceUpdates.save(db: db, entries: entries, asOf: asOf)
        } onSuccess: { [weak self] result in
            self?.warnings = result.map {
                "\($0.accountName): entered balance differs from the computed running balance by \(Money.format($0.driftMinorUnits, currency: $0.currency)) — check for a missing or duplicate transaction."
            }
        }
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
