import GRDB
import Foundation

public enum TransferLinkOrigin: String, Codable, CaseIterable, Sendable {
    /// Found by `TransferMatcher`.
    case auto
    /// Linked by the user (Edit transaction → Link to transfer…).
    case manual
}

/// Two of the user's own transactions that are one transfer between their accounts (spec §6):
/// the money counts once, as sent — the incoming leg is hidden from every budget figure
/// (`Transaction.budgetFacing`). One historical monthly total (out) can link several incoming
/// legs; an incoming leg joins at most one active link.
public struct TransferLink: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var outTransactionId: Int64
    public var inTransactionId: Int64
    public var origin: TransferLinkOrigin
    /// An auto link the user unlinked: kept so auto-matching never links either leg again.
    public var isDismissed: Bool

    public init(id: Int64? = nil, outTransactionId: Int64, inTransactionId: Int64, origin: TransferLinkOrigin, isDismissed: Bool = false) {
        self.id = id
        self.outTransactionId = outTransactionId
        self.inTransactionId = inTransactionId
        self.origin = origin
        self.isDismissed = isDismissed
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "transferLink"

    /// Links that count (not dismissed).
    public static var active: QueryInterfaceRequest<TransferLink> {
        filter(Column("isDismissed") == false)
    }
}

func registerTransferLinkMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createTransferLink") { db in
        try db.create(table: "transferLink") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("outTransactionId", .integer).notNull().indexed().references("transaction_", onDelete: .cascade)
            t.column("inTransactionId", .integer).notNull().references("transaction_", onDelete: .cascade)
            t.column("origin", .text).notNull()
            t.column("isDismissed", .boolean).notNull().defaults(to: false)
        }
        // One active link per incoming leg. Dismissed links stay as markers, so a leg the user
        // unlinked can still be linked by hand.
        try db.execute(sql: "CREATE UNIQUE INDEX transferLink_activeIn ON transferLink(inTransactionId) WHERE isDismissed = 0")
        try db.execute(sql: "CREATE INDEX transferLink_in ON transferLink(inTransactionId)")
    }
}

func registerCategoryExternalTransferMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addCategoryIsExternalTransfer") { db in
        try db.alter(table: "category") { t in
            t.add(column: "isExternalTransfer", .boolean).notNull().defaults(to: false)
        }
    }
}

extension Transaction {
    /// The SQL condition keeping a transaction budget-facing: not the incoming leg of an
    /// active transfer link (spec §6 — a transfer counts once, as sent). `alias` is the
    /// transaction table's alias in the caller's query, if any.
    public static func budgetFacingCondition(alias: String? = nil) -> String {
        let id = alias.map { "\($0).id" } ?? "id"
        return "\(id) NOT IN (SELECT inTransactionId FROM transferLink WHERE isDismissed = 0)"
    }

    /// Every transaction that counts in the budget: Budget grid, Dashboard flows, plan
    /// status, history categorisation, recent categories, Uncategorized, scenario actuals,
    /// auto-forecast detection. Balances and net worth keep using every transaction.
    public static var budgetFacing: QueryInterfaceRequest<Transaction> {
        filter(sql: budgetFacingCondition())
    }
}

/// Reading and editing transfer links.
public enum TransferLinks {
    /// The in-memory twin of `Transaction.budgetFacing`, for screens that load every
    /// transaction (balances need them all) and the links once. `transactions` must be every
    /// transaction (an out leg's account is looked up among them). With `accountIds` (the
    /// Budget account filter, spec §7) only those accounts' transactions are kept, and an
    /// incoming leg is hidden only when its outgoing leg's account is selected too.
    public static func budgetFacing(_ transactions: [Transaction], links: [TransferLink], accountIds: Set<Int64>? = nil) -> [Transaction] {
        let active = links.filter { !$0.isDismissed }
        guard !active.isEmpty || accountIds != nil else { return transactions }
        let outByIn = Dictionary(active.map { ($0.inTransactionId, $0.outTransactionId) }, uniquingKeysWith: { first, _ in first })
        let accountById: [Int64: Int64] = accountIds == nil ? [:] : Dictionary(transactions.compactMap { t in t.id.map { ($0, t.accountId) } }, uniquingKeysWith: { first, _ in first })
        return transactions.filter { transaction in
            if let accountIds, !accountIds.contains(transaction.accountId) { return false }
            guard let id = transaction.id, let outId = outByIn[id] else { return true }
            guard let accountIds else { return false }
            // The sending account isn't shown: the receiving account's own leg counts.
            guard let outAccount = accountById[outId] else { return true }
            return !accountIds.contains(outAccount)
        }
    }
}
