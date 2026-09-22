import XCTest
import GRDB
@testable import BudgetCore

final class PayPeriodModelTests: XCTestCase {
    func testInsertAndFetchPayPeriod() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        var period = PayPeriod(startDate: Date(timeIntervalSince1970: 0), endDate: Date(timeIntervalSince1970: 2_500_000), type: .actual)
        try manager.dbQueue.write { db in try period.insert(db) }
        let fetched = try manager.dbQueue.read { db in try PayPeriod.fetchOne(db) }
        XCTAssertEqual(fetched?.type, .actual)
    }
}
