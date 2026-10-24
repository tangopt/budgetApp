import XCTest
import CryptoKit
import GRDB
@testable import BudgetCore

/// The simulator's demo key hand-over (plan step 4 Task 12): `MANGO_DEMO_HOUSEHOLD_KEY` is 64 hex characters, or
/// nothing is stored. Synthetic keys only.
final class DemoHouseholdKeyTests: XCTestCase {
    func testSixtyFourHexCharactersAreAKey() throws {
        let hex = String(repeating: "0f", count: 32)
        let key = try XCTUnwrap(DemoHouseholdKey.parse(hex))
        XCTAssertEqual(key.withUnsafeBytes { Data($0) }, Data(repeating: 0x0f, count: 32))
        // Upper case and surrounding whitespace are fine.
        XCTAssertNotNil(DemoHouseholdKey.parse("  " + String(repeating: "AB", count: 32) + "\n"))
    }

    func testAnythingElseIsRefused() {
        for bad in ["", "abc", String(repeating: "0", count: 63), String(repeating: "0", count: 66),
                    String(repeating: "zz", count: 32), String(repeating: "0f", count: 31) + " 0"] {
            XCTAssertNil(DemoHouseholdKey.parse(bad), bad)
        }
    }

    /// The phone's sync device id: made once, kept in `localSetting` (never synced), the same on every read.
    func testPhoneDeviceIdIsMadeOnceAndKept() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let first = try manager.dbQueue.write { db in try LocalSetting.phoneDeviceId(db) }
        let second = try manager.dbQueue.write { db in try LocalSetting.phoneDeviceId(db) }
        XCTAssertEqual(first, second)
        XCTAssertNotNil(UUID(uuidString: first))
        let pending = try manager.dbQueue.read { db in try SyncChangeTracker.pending(db: db) }
        XCTAssertEqual(pending, [], "a local setting is never sent")
    }
}
