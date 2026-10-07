import Foundation
import GRDB

public enum AccountEditError: Error, Equatable { case emptyName, duplicateName, creditKindChange, accountNotFound }

public struct ReconciliationWarning: Equatable {
    public let accountName: String
    public let driftMinorUnits: Int
    public let currency: Currency
}

public enum AccountEditing {
    @discardableResult
    public static func add(db: Database, name: String, currency: Currency, kind: AccountKind, trackingMode: AccountTrackingMode, openingBalanceEntered: Int?, asOf: Date) throws -> Account {
        let trimmed = try validatedName(db: db, name: name, excluding: nil)
        var account = Account(name: trimmed, currency: currency, kind: kind, trackingMode: trackingMode)
        try account.insert(db)
        if let openingBalanceEntered {
            try BalanceUpdates.upsertSnapshot(db: db, accountId: account.id!, date: asOf, balanceMinorUnits: NetWorthCalculator.signedSnapshotBalance(enteredMinorUnits: openingBalanceEntered, accountKind: kind), note: nil)
        }
        return account
    }

    /// Currency never changes after creation. A kind change to or from `.credit` is
    /// refused once the account has any snapshot or transaction (signs would flip).
    public static func update(db: Database, accountId: Int64, name: String, kind: AccountKind, trackingMode: AccountTrackingMode) throws {
        guard var account = try Account.fetchOne(db, key: accountId) else { throw AccountEditError.accountNotFound }
        let trimmed = try validatedName(db: db, name: name, excluding: accountId)
        if (account.kind == .credit) != (kind == .credit), try hasHistory(db: db, accountId: accountId) {
            throw AccountEditError.creditKindChange
        }
        account.name = trimmed
        account.kind = kind
        account.trackingMode = trackingMode
        try account.update(db)
    }

    public static func hasHistory(db: Database, accountId: Int64) throws -> Bool {
        let snapshots = try BalanceSnapshot.filter(Column("accountId") == accountId).fetchCount(db)
        if snapshots > 0 { return true }
        return try Transaction.filter(Column("accountId") == accountId).fetchCount(db) > 0
    }

    private static func validatedName(db: Database, name: String, excluding id: Int64?) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AccountEditError.emptyName }
        let existing = try Account.fetchAll(db)
        if existing.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw AccountEditError.duplicateName
        }
        return trimmed
    }
}

public enum BalanceUpdates {
    public struct Entry: Equatable {
        public let accountId: Int64
        public let enteredMinorUnits: Int
        public let note: String?
        public init(accountId: Int64, enteredMinorUnits: Int, note: String? = nil) {
            self.accountId = accountId
            self.enteredMinorUnits = enteredMinorUnits
            self.note = note
        }
    }

    /// One snapshot per account per day: each entry is saved dated `asOf`, replacing (value
    /// and note) any snapshot that account already has on exactly that date, otherwise
    /// inserting one — all in the caller's write transaction. Drift warnings only for
    /// `.imported` accounts: the latest snapshot strictly before `asOf` (never the one being
    /// replaced) plus transactions since, vs the new balance; they never block the save.
    public static func save(db: Database, entries: [Entry], asOf: Date) throws -> [ReconciliationWarning] {
        var warnings: [ReconciliationWarning] = []
        for entry in entries {
            guard let account = try Account.fetchOne(db, key: entry.accountId) else { throw AccountEditError.accountNotFound }
            let balance = NetWorthCalculator.signedSnapshotBalance(enteredMinorUnits: entry.enteredMinorUnits, accountKind: account.kind)
            if account.trackingMode == .imported {
                let previous = try BalanceSnapshot
                    .filter(Column("accountId") == entry.accountId && Column("date") < asOf)
                    .order(Column("date").desc, Column("id").desc)
                    .fetchOne(db)
                let transactionsSince: [Transaction]
                if let previous {
                    transactionsSince = try Transaction.filter(Column("accountId") == entry.accountId && Column("date") > previous.date).fetchAll(db)
                } else {
                    transactionsSince = try Transaction.filter(Column("accountId") == entry.accountId).fetchAll(db)
                }
                let computed = NetWorthCalculator.runningBalance(account: account, latestSnapshot: previous, transactionsSinceSnapshot: transactionsSince)
                let drift = NetWorthCalculator.reconciliationDrift(computedNativeBalanceMinorUnits: computed, actualNativeBalanceMinorUnits: balance)
                if drift != 0 {
                    warnings.append(ReconciliationWarning(accountName: account.name, driftMinorUnits: drift, currency: account.currency))
                }
            }
            try upsertSnapshot(db: db, accountId: entry.accountId, date: asOf, balanceMinorUnits: balance, note: entry.note)
        }
        return warnings
    }

    /// Updates the account's snapshot on exactly `date` (the newest, if legacy data holds
    /// several) or inserts one when there is none.
    static func upsertSnapshot(db: Database, accountId: Int64, date: Date, balanceMinorUnits: Int, note: String?) throws {
        if var existing = try BalanceSnapshot
            .filter(Column("accountId") == accountId && Column("date") == date)
            .order(Column("id").desc)
            .fetchOne(db) {
            existing.balanceMinorUnits = balanceMinorUnits
            existing.note = note
            try existing.update(db)
        } else {
            var snapshot = BalanceSnapshot(accountId: accountId, date: date, balanceMinorUnits: balanceMinorUnits, note: note)
            try snapshot.insert(db)
        }
    }
}
