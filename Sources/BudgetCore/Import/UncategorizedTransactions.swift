import GRDB

/// Every transaction that still needs a category — either it has none at all, or it was
/// saved as `pendingReview`. Shared by the Uncategorized screen's view model (and unit
/// tested here, independent of any UI).
public enum UncategorizedTransactions {
    public static func fetch(db: Database) throws -> [Transaction] {
        try Transaction
            .filter(Column("categoryId") == nil || Column("status") == TransactionStatus.pendingReview.rawValue)
            .order(Column("date").desc)
            .fetchAll(db)
    }
}
