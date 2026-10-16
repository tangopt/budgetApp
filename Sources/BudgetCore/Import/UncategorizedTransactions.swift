import GRDB

/// Every transaction that still needs a category — either it has none at all, or it was
/// saved as `pendingReview` — and is budget-facing (a transfer's incoming leg, counted once as
/// sent, never needs one: `Transaction.budgetFacing`). Shared by the Uncategorized screen's view model (and unit
/// tested here, independent of any UI).
public enum UncategorizedTransactions {
    public static func fetch(db: Database) throws -> [Transaction] {
        try request.order(Column("date").desc).fetchAll(db)
    }

    /// How many `fetch` would return, for the sidebar's "Uncategorized (N)" label.
    public static func count(db: Database) throws -> Int {
        try request.fetchCount(db)
    }

    static var request: QueryInterfaceRequest<Transaction> {
        Transaction.budgetFacing.filter(Column("categoryId") == nil || Column("status") == TransactionStatus.pendingReview.rawValue)
    }
}
