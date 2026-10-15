import Foundation
import GRDB

/// A statement's closing balance: the balance at the end of `date` (UTC midnight of the
/// statement's last transaction day), signed like the account's balance.
public struct StatementClosing: Equatable, Sendable {
    public let date: Date
    public let balanceMinorUnits: Int

    public init(date: Date, balanceMinorUnits: Int) {
        self.date = date
        self.balanceMinorUnits = balanceMinorUnits
    }
}

/// The statement says one closing balance, the app computes another.
public struct StatementMismatch: Equatable, Sendable {
    public let date: Date
    public let statementMinorUnits: Int
    public let computedMinorUnits: Int

    public init(date: Date, statementMinorUnits: Int, computedMinorUnits: Int) {
        self.date = date
        self.statementMinorUnits = statementMinorUnits
        self.computedMinorUnits = computedMinorUnits
    }

    /// statement − computed: the adjustment (signed like a transaction amount) that would
    /// make the balance match.
    public var differenceMinorUnits: Int { statementMinorUnits - computedMinorUnits }
}

public enum StatementCheckResult: Equatable, Sendable {
    case matches(StatementClosing)
    case mismatch(StatementMismatch)

    public var mismatch: StatementMismatch? {
        if case .mismatch(let mismatch) = self { return mismatch }
        return nil
    }
}

/// What Finish import does with a statement's closing balance: always checks it (and records
/// the outcome on the account); adds an adjustment only when the user ticked it.
public struct StatementFinish: Equatable, Sendable {
    public let closing: StatementClosing
    public let addAdjustment: Bool

    public init(closing: StatementClosing, addAdjustment: Bool) {
        self.closing = closing
        self.addAdjustment = addAdjustment
    }
}

public struct StatementFinishOutcome: Equatable, Sendable {
    /// The check after the rows were saved and before any adjustment.
    public let check: StatementCheckResult
    /// The adjustment Finish import added (only when ticked and mismatched).
    public let adjustmentTransactionId: Int64?
}

/// Statement imports (spec 2026-10-14 §2): the statement's closing balance is checked against
/// the account's computed balance — never stored as a balance snapshot.
public enum StatementCheck {
    /// The account's computed balance at the end of the closing day — saved transactions
    /// (less `excludingTransactionIds`, the manual entries the import replaces) plus the
    /// `stagedRows` that will be saved — against the statement's closing balance. Uses the
    /// balance rule (`NetWorthCalculator.balance`), so rows dated on or before a recorded
    /// balance in force don't count; 0 when the account has nothing yet.
    public static func compare(db: Database, accountId: Int64, closing: StatementClosing,
                               stagedRows: [(date: Date, amountMinorUnits: Int)],
                               excludingTransactionIds: Set<Int64> = []) throws -> StatementCheckResult {
        let snapshots = try BalanceSnapshot.filter(Column("accountId") == accountId).fetchAll(db)
        let saved = try Transaction.filter(Column("accountId") == accountId).fetchAll(db)
            .filter { $0.id.map { !excludingTransactionIds.contains($0) } ?? true }
        let pending = stagedRows.map {
            Transaction(importBatchId: 0, accountId: accountId, date: $0.date, rawDescription: "", amountMinorUnits: $0.amountMinorUnits,
                        categoryId: nil, status: .pendingReview, categorizedBy: .none, fingerprint: "")
        }
        let computed = NetWorthCalculator.balance(accountId: accountId, at: BalanceUpdates.endOfDay(closing.date),
                                                  snapshots: snapshots, transactions: saved + pending)?.native ?? 0
        guard computed != closing.balanceMinorUnits else { return .matches(closing) }
        return .mismatch(StatementMismatch(date: closing.date, statementMinorUnits: closing.balanceMinorUnits, computedMinorUnits: computed))
    }

    /// The recorded balance (snapshot) on or after the closing day that would stop an
    /// adjustment dated then from counting (`BalanceUpdates.blockingBalanceDate`); nil when
    /// an adjustment can be added.
    public static func adjustmentBlockedBy(db: Database, accountId: Int64, closingDate: Date) throws -> Date? {
        try BalanceUpdates.blockingBalanceDate(db: db, accountId: accountId, asOf: closingDate)
    }

    /// Finish import's statement step, in the commit's write after the rows are saved: checks
    /// the closing balance against what's now saved; when mismatched and `addAdjustment`, adds
    /// the difference dated on the closing date (Balance adjustment, or Market movement for an
    /// investment account); then records the outcome on the account (`record`).
    static func finish(db: Database, accountId: Int64, sourceFileName: String, statement: StatementFinish) throws -> StatementFinishOutcome {
        let check = try compare(db: db, accountId: accountId, closing: statement.closing, stagedRows: [])
        var adjustmentId: Int64?
        if let mismatch = check.mismatch, statement.addAdjustment {
            guard let account = try Account.fetchOne(db, key: accountId) else { throw AccountEditError.accountNotFound }
            try BalanceUpdates.checkDate(db: db, account: account, asOf: statement.closing.date)
            let category = try BuiltInCategories.category(db: db, role: CategoryBuiltInRole.forAccount(kind: account.kind))
            adjustmentId = try ManualTransactions.add(db: db, accountId: accountId, date: statement.closing.date, description: category.name,
                                                      amountMinorUnits: mismatch.differenceMinorUnits, categoryId: category.id,
                                                      note: "To match the statement closing balance (\(sourceFileName))", allowBuiltIn: true).id
        }
        try record(db: db, accountId: accountId, date: statement.closing.date,
                   mismatchMinorUnits: adjustmentId == nil ? check.mismatch?.differenceMinorUnits : nil)
        return StatementFinishOutcome(check: check, adjustmentTransactionId: adjustmentId)
    }

    /// Records a statement check's outcome on the account (`nil`: it matched or was adjusted),
    /// unless the account already holds a mismatch dated after `date` — the latest statement's
    /// outcome is the one shown.
    static func record(db: Database, accountId: Int64, date: Date, mismatchMinorUnits: Int?) throws {
        guard var account = try Account.fetchOne(db, key: accountId) else { return }
        if let stored = account.statementMismatchDate, stored > date { return }
        account.statementMismatchMinorUnits = mismatchMinorUnits
        account.statementMismatchDate = mismatchMinorUnits == nil ? nil : date
        try account.update(db)
    }

    /// Update balance as of `asOf` sets the balance by hand, so it resolves a statement
    /// mismatch dated on or before that day.
    static func clearMismatch(db: Database, accountId: Int64, onOrBefore asOf: Date) throws {
        guard var account = try Account.fetchOne(db, key: accountId), let stored = account.statementMismatchDate,
              stored <= BalanceUpdates.endOfDay(asOf) else { return }
        account.statementMismatchMinorUnits = nil
        account.statementMismatchDate = nil
        try account.update(db)
    }
}
