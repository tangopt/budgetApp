import XCTest
import GRDB
@testable import BudgetCore
import BudgetDemo
@testable import MangoUI
import TestSupport

@MainActor
final class PadPropertyTests: XCTestCase {
    private func demo() throws -> (DatabaseQueue, Date) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pad-prop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("demo.sqlite").path
        try DemoDatabase.build(at: path, evidenceRoot: folder.appendingPathComponent("Evidence"))
        return (try DatabaseQueue(path: path), DemoDatabase.defaultAsOf)
    }

    func testBillsGridMatchesMacReadModel() async throws {
        let (db, today) = try demo()
        let model = PadPropertyModel(dbQueue: db, today: { today })
        await model.reload()
        let tenancyId = try XCTUnwrap(model.selectedTenancyId)
        let propertyId = try XCTUnwrap(model.property?.id)
        let expected = try await db.read { try UtilityBills.read(db: $0, propertyId: propertyId, tenancyId: tenancyId) }
        XCTAssertEqual(model.bills, expected)
        XCTAssertFalse(expected.bills.isEmpty)
    }

    func testCurrentTenancySelectedFirst() async throws {
        let (db, today) = try demo()
        let model = PadPropertyModel(dbQueue: db, today: { today })
        await model.reload()
        let first = try XCTUnwrap(model.tenancies.first)
        XCTAssertTrue(first.startDate <= today && (first.endDate.map { $0 >= today } ?? true))
        XCTAssertEqual(model.selectedTenancyId, first.id)
        // Every later tenancy starts no later than the current one's order puts it.
        let rest = model.tenancies.dropFirst().map(\.startDate)
        XCTAssertEqual(rest, rest.sorted(by: >))
    }
}
