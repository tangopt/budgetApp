import XCTest
import GRDB
@testable import BudgetCore

final class CategoryShortlistTests: XCTestCase {
    func testRecentOrdersByUseCountWithinWindowAndHonoursLimit() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in try CategorySeeder.seedDefaults(db) }
        let now = Date()
        let day: TimeInterval = 86_400
        let (a, b, c) = try manager.dbQueue.write { db -> (Int64, Int64, Int64) in
            var account = Account(name: "A", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "x.csv", importedAt: now)
            try batch.insert(db)
            let cats = try Category.fetchAll(db).filter(\.isAssignable).prefix(3).map { $0.id! }
            var n = 0
            func add(_ cat: Int64?, daysAgo: Double) throws {
                n += 1
                var t = Transaction(importBatchId: batch.id!, accountId: account.id!, date: now.addingTimeInterval(-daysAgo * day), rawDescription: "T\(n)", amountMinorUnits: -100, categoryId: cat, status: .confirmed, categorizedBy: .manual, fingerprint: "f\(n)")
                try t.insert(db)
            }
            try add(cats[0], daysAgo: 1); try add(cats[0], daysAgo: 2); try add(cats[0], daysAgo: 3)
            try add(cats[1], daysAgo: 1); try add(cats[1], daysAgo: 5)
            try add(cats[2], daysAgo: 10)
            for _ in 0..<5 { try add(cats[2], daysAgo: 200) }   // outside the window
            try add(nil, daysAgo: 1)
            return (cats[0], cats[1], cats[2])
        }
        let since = now.addingTimeInterval(-90 * day)
        let all = try manager.dbQueue.read { db in try CategoryShortlist.recent(db: db, since: since, limit: 5) }
        XCTAssertEqual(all, [a, b, c])
        let two = try manager.dbQueue.read { db in try CategoryShortlist.recent(db: db, since: since, limit: 2) }
        XCTAssertEqual(two, [a, b])
    }
}
