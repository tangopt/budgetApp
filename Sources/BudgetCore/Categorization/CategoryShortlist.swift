import Foundation
import GRDB

public enum CategoryShortlist {
    /// Category ids most used by transactions dated on or after `since`, most used first
    /// (ties: most recently used first), at most `limit`.
    public static func recent(db: Database, since: Date, limit: Int) throws -> [Int64] {
        try Int64.fetchAll(db, sql: """
            SELECT categoryId FROM transaction_
            WHERE categoryId IS NOT NULL AND date >= ?
            GROUP BY categoryId
            ORDER BY COUNT(*) DESC, MAX(date) DESC
            LIMIT ?
            """, arguments: [since, limit])
    }
}
