import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

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

    /// Missing evidence ▸ Tax years: the tab (one model with the standalone screen) appears before the standalone
    /// screen disappears; its observation (the year's tax-figures-only list) must keep running.
    func testIncomingScreenKeepsObservationWhenOutgoingScreenReleasesAfterIt() {
        var demand = ObservationDemand()
        let standalone = ObservationDemand.screenClaim(), tab = ObservationDemand.screenClaim()
        XCTAssertNotEqual(standalone, tab)
        demand.set(standalone, wanted: true)
        demand.set(tab, wanted: true)
        XCTAssertTrue(demand.set(standalone, wanted: false), "the Tax years tab still needs it")
        XCTAssertFalse(demand.set(tab, wanted: false))
    }

    func testClaimsAreIdempotent() {
        var demand = ObservationDemand()
        demand.set("screen", wanted: true)
        demand.set("screen", wanted: true)
        XCTAssertFalse(demand.set("screen", wanted: false))
    }

    /// The same observation the view model runs: rules in, add / edit / delete seen at once.
    func testRulesObservationFollowsAddEditDelete() async throws {
        let manager = try TestDatabase.migratedManager()
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
