import Foundation
import GRDB

public enum CategoryShortlist {
    /// Category ids most used by confirmed transactions (assignable categories only) dated on or after `since`, most used first
    /// (ties: most recently used first), at most `limit`.
    public static func recent(db: Database, since: Date, limit: Int) throws -> [Int64] {
        try Int64.fetchAll(db, sql: """
            SELECT t.categoryId FROM transaction_ t
            JOIN category c ON c.id = t.categoryId
            WHERE t.status = 'confirmed' AND c.isReserved = 0 AND t.date >= ?
            GROUP BY t.categoryId
            ORDER BY COUNT(*) DESC, MAX(t.date) DESC
            LIMIT ?
            """, arguments: [since, limit])
    }
}
