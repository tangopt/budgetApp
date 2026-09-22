import XCTest
import GRDB
@testable import BudgetCore

final class ForecastModelsTests: XCTestCase {
    func testInsertGroupAndEntry() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try manager.dbQueue.write { db in try CategorySeeder.seedDefaults(db) }
        let rent = try manager.dbQueue.read { db in try Category.filter(Column("name") == "Rent").fetchOne(db)! }

        var group = ForecastGroup(name: "Detected recurring", note: nil, isEnabled: true, isSystemManaged: true)
        try manager.dbQueue.write { db in try group.insert(db) }

        var entry = ForecastEntry(
            groupId: group.id!, categoryId: rent.id!, amountMinorUnits: 280000,
            frequency: .monthly, interval: 1, startDate: Date(), endDate: nil,
            isEnabled: true, status: .auto, note: nil
        )
        try manager.dbQueue.write { db in try entry.insert(db) }

        let fetched = try manager.dbQueue.read { db in try ForecastEntry.fetchOne(db) }
        XCTAssertEqual(fetched?.amountMinorUnits, 280000)
        XCTAssertEqual(fetched?.frequency, .monthly)
        XCTAssertEqual(fetched?.status, .auto)
    }
}
