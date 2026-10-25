import Foundation
import GRDB

public enum AccountEditError: Error, Equatable { case emptyName, duplicateName, creditKindChange, accountNotFound }

public enum BalanceUpdateError: Error, Equatable, LocalizedError {
    /// Update balance dated on or before a recorded balance (the opening balance or a legacy
    /// statement balance): a snapshot is the balance at the end of its day, so an adjustment
    /// dated then wouldn't count after it. `date` is the earliest such balance.
    case recordedBalance(accountName: String, date: Date)

    public var errorDescription: String? {
        switch self {
        case let .recordedBalance(name, date):
            let formatter = DateFormatter()
            formatter.calendar = MonthRange.calendar
            formatter.timeZone = MonthRange.calendar.timeZone
            formatter.locale = Locale(identifier: "en_GB")
            formatter.dateFormat = "d MMM yyyy"
            return "\(name): there's a recorded balance on \(formatter.string(from: date)) — pick a later date."
        }
    }
}

public enum AccountEditing {
    /// The opening balance (entered as the amount owed for credit) is stored as the account's
    /// first snapshot dated `asOf`; without one the account starts from zero.
    /// `trackingMode` is legacy (stored, ignored by every calculation). `includeInNetWorth`:
    /// Count toward net worth (`Account.includeInNetWorth`).
    /// `owner`: who adds it. Once ownership is confirmed (`SharingSetup.isConfirmed`) the account is theirs,
    /// at their default level (`SharingDefaults`: Balance only). nil, or before the ownership sheet: joint at
    /// Everything (an account added as joint, the tools, and accounts the sheet will assign).
    @discardableResult
    public static func add(db: Database, name: String, currency: Currency, kind: AccountKind, trackingMode: AccountTrackingMode = .imported, openingBalanceEntered: Int?, asOf: Date,
                           details: AccountDetails = AccountDetails(), includeInNetWorth: Bool = true, owner: AccessActor? = nil) throws -> Account {
        let trimmed = try validatedName(db: db, name: name, excluding: nil)
        let details = try details.normalized()
        var account = Account(name: trimmed, currency: currency, kind: kind, trackingMode: trackingMode,
                              sortOrder: try AccountOrdering.orderForNewAccount(db: db), includeInNetWorth: includeInNetWorth)
        account.apply(details)
        if let owner, try SharingSetup.isConfirmed(db: db) {
            account.ownerPersonId = owner.personId
            account.sharingLevel = SharingDefaults.level(ownerPersonId: owner.personId, isPropertyLinked: false)
        }
        try account.insert(db)
        if let openingBalanceEntered {
            try BalanceUpdates.upsertSnapshot(db: db, accountId: account.id!, date: asOf, balanceMinorUnits: NetWorthCalculator.signedSnapshotBalance(enteredMinorUnits: openingBalanceEntered, accountKind: kind), note: nil)
        }
        // Its transfer category (spec 2026-10-14 §4).
        try TransferCategories.ensure(db: db)
        return account
    }

    /// Currency never changes after creation. A kind change to or from `.credit` is
    /// refused once the account has any snapshot or transaction (signs would flip).
    /// `details` nil leaves the alias and bank details as they are; otherwise they are
    /// normalised and replace them (blank fields clear) — with a region, only that region's
    /// fields plus bank name and BIC; stored values that predate a rule pass unchanged. `trackingMode` nil keeps the stored
    /// (legacy, ignored) value. `includeInNetWorth` nil keeps Count toward net worth as it is.
    public static func update(db: Database, accountId: Int64, name: String, kind: AccountKind, trackingMode: AccountTrackingMode? = nil, details: AccountDetails? = nil,
                              includeInNetWorth: Bool? = nil) throws {
        guard var account = try Account.fetchOne(db, key: accountId) else { throw AccountEditError.accountNotFound }
        let trimmed = try validatedName(db: db, name: name, excluding: accountId)
        if (account.kind == .credit) != (kind == .credit), try hasHistory(db: db, accountId: accountId) {
            throw AccountEditError.creditKindChange
        }
        account.name = trimmed
        account.kind = kind
        if let trackingMode { account.trackingMode = trackingMode }
        if let includeInNetWorth { account.includeInNetWorth = includeInNetWorth }
        if let details = try details?.normalized(existing: account) {
            account.apply(details)
        }
        try account.update(db)
        // A new name or alias renames its transfer category.
        try TransferCategories.ensure(db: db)
    }

    /// Makes `accountId` the main account (spec 2026-10-15 account-forecast §1), clearing any
    /// other; nil clears it.
    public static func setMain(db: Database, accountId: Int64?) throws {
        if let accountId, try Account.fetchOne(db, key: accountId) == nil { throw AccountEditError.accountNotFound }
        try db.execute(sql: "UPDATE account SET isMain = 0 WHERE isMain = 1")
        if let accountId {
            try db.execute(sql: "UPDATE account SET isMain = 1 WHERE id = ?", arguments: [accountId])
        }
    }

    /// Count toward net worth on or off (`Account.includeInNetWorth`), e.g. from the row menu.
    public static func setIncludeInNetWorth(db: Database, accountId: Int64, _ include: Bool) throws {
        guard try Account.fetchOne(db, key: accountId) != nil else { throw AccountEditError.accountNotFound }
        try db.execute(sql: "UPDATE account SET includeInNetWorth = ? WHERE id = ?", arguments: [include, accountId])
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

    /// What Update balance did for one account.
    public struct Outcome: Equatable {
        public let accountId: Int64
        public let accountName: String
        public let currency: Currency
        /// Signed like `Transaction.amountMinorUnits`: entered balance − computed balance.
        /// 0 = the balance already matched and nothing was written.
        public let differenceMinorUnits: Int
        /// Where the difference went (nil when it was 0).
        public let role: CategoryBuiltInRole?
        public let transactionId: Int64?
    }

    /// The account's computed signed balance at the end of the stored day `asOf`
    /// (`NetWorthCalculator.balance`; 0 when it has nothing yet).
    public static func computedBalance(db: Database, accountId: Int64, asOf: Date) throws -> Int {
        let snapshots = try BalanceSnapshot.filter(Column("accountId") == accountId).fetchAll(db)
        let transactions = try Transaction.filter(Column("accountId") == accountId).fetchAll(db)
        return NetWorthCalculator.balance(accountId: accountId, at: endOfDay(asOf), snapshots: snapshots, transactions: transactions)?.native ?? 0
    }

    /// Update balance… (spec 2026-10-14 §1), single or bulk, in the caller's write transaction:
    /// for each entry, the difference between the entered balance (amount owed for credit)
    /// and the computed balance at `asOf` becomes a manual transaction dated `asOf` in the
    /// account's Manual entries batch — Market movement for investment accounts, Balance
    /// adjustment otherwise — described by the category's name, with the entry's note. A zero
    /// difference writes no transaction. No snapshot is written. Every entry, whatever its
    /// difference, records `asOf` as the account's `balanceConfirmedAt` (if later). A statement mismatch dated on or
    /// before `asOf` is cleared (`StatementCheck.clearMismatch`). Entries are applied in order, so a
    /// repeated account sees the earlier adjustment.
    public static func save(db: Database, entries: [Entry], asOf: Date) throws -> [Outcome] {
        var outcomes: [Outcome] = []
        for entry in entries {
            guard let account = try Account.fetchOne(db, key: entry.accountId) else { throw AccountEditError.accountNotFound }
            try checkDate(db: db, account: account, asOf: asOf)
            try StatementCheck.clearMismatch(db: db, accountId: entry.accountId, onOrBefore: asOf)
            try confirmBalance(db: db, accountId: entry.accountId, on: asOf)
            let actual = NetWorthCalculator.signedSnapshotBalance(enteredMinorUnits: entry.enteredMinorUnits, accountKind: account.kind)
            let difference = actual - (try computedBalance(db: db, accountId: entry.accountId, asOf: asOf))
            guard difference != 0 else {
                outcomes.append(Outcome(accountId: entry.accountId, accountName: account.displayName, currency: account.currency, differenceMinorUnits: 0, role: nil, transactionId: nil))
                continue
            }
            let role = CategoryBuiltInRole.forAccount(kind: account.kind)
            let category = try BuiltInCategories.category(db: db, role: role)
            let transaction = try ManualTransactions.add(db: db, accountId: entry.accountId, date: asOf, description: category.name,
                                                         amountMinorUnits: difference, categoryId: category.id, note: entry.note, allowBuiltIn: true)
            outcomes.append(Outcome(accountId: entry.accountId, accountName: account.displayName, currency: account.currency, differenceMinorUnits: difference, role: role, transactionId: transaction.id))
        }
        return outcomes
    }

    /// Records that the account's balance was confirmed on `day` (`Account.balanceConfirmedAt`),
    /// unless a later confirmation is already recorded.
    static func confirmBalance(db: Database, accountId: Int64, on day: Date) throws {
        try db.execute(sql: "UPDATE account SET balanceConfirmedAt = ? WHERE id = ? AND (balanceConfirmedAt IS NULL OR balanceConfirmedAt < ?)",
                       arguments: [day, accountId, day])
    }

    /// The earliest recorded balance (snapshot) of the account dated on or after `asOf`'s day,
    /// which blocks an Update balance as of `asOf`; nil when that day is free. A snapshot is
    /// the balance at the end of its day, so an adjustment dated on or before it wouldn't count.
    public static func blockingBalanceDate(db: Database, accountId: Int64, asOf: Date) throws -> Date? {
        try Date.fetchOne(db, sql: "SELECT MIN(date) FROM balanceSnapshot WHERE accountId = ? AND date >= ?",
                          arguments: [accountId, MonthRange.calendar.startOfDay(for: asOf)])
    }

    static func checkDate(db: Database, account: Account, asOf: Date) throws {
        guard let id = account.id, let blocking = try blockingBalanceDate(db: db, accountId: id, asOf: asOf) else { return }
        throw BalanceUpdateError.recordedBalance(accountName: account.displayName, date: blocking)
    }

    /// The last moment of `day`'s UTC calendar day: a stored day counts every transaction
    /// dated that day.
    static func endOfDay(_ day: Date) -> Date {
        let calendar = MonthRange.calendar
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))!.addingTimeInterval(-1)
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
