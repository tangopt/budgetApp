import XCTest
import GRDB
@testable import BudgetCore

/// The Missing evidence screen's observation must outlive the screen's disappear while a sheet
/// (Rules…) is open, and must reflect rule add / edit / delete as they happen.
final class ObservationDemandTests: XCTestCase {
    func testSheetClaimKeepsObservationWhileScreenDisappears() {
        var demand = ObservationDemand()
        XCTAssertFalse(demand.isWanted)
        demand.set("screen", wanted: true)
        demand.set("rules", wanted: true)
        XCTAssertTrue(demand.set("screen", wanted: false), "the open Rules sheet still needs it")
        XCTAssertFalse(demand.set("rules", wanted: false), "screen gone and sheet closed: nothing is observed")
    }

    func testClaimsAreIdempotent() {
        var demand = ObservationDemand()
        demand.set("screen", wanted: true)
        demand.set("screen", wanted: true)
        XCTAssertFalse(demand.set("screen", wanted: false))
    }

    /// The same observation the view model runs: rules in, add / edit / delete seen at once.
    func testRulesObservationFollowsAddEditDelete() async throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let queue = manager.dbQueue
        var seen: [[String]] = []
        let values = ValueObservation.tracking { db in try EvidenceRequirements.all(db: db).map(\.name) }
            .removeDuplicates().values(in: queue)
        let task = Task { for try await names in values { seen.append(names) } }
        func settle(_ count: Int) async throws {
            for _ in 0..<200 where seen.count < count { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(seen.count, count)
        }
        try await settle(1)
        var rule = EvidenceRequirement(name: "Rule A", scope: .single(entity: .account(1)), kinds: [])
        try await queue.write { db in try EvidenceRequirements.save(db: db, &rule) }
        try await settle(2)
        rule.name = "Rule B"
        try await queue.write { db in try EvidenceRequirements.save(db: db, &rule) }
        try await settle(3)
        _ = try await queue.write { [id = rule.id!] db in try EvidenceRequirements.delete(db: db, id: id) }
        try await settle(4)
        task.cancel()
        XCTAssertEqual(seen, [[], ["Rule A"], ["Rule B"], []])
    }
}
