import XCTest
@testable import BudgetCore

/// The Differences tab's matrix builder (spec 2026-10-08-scenario-lab-tabs-design.md): pure,
/// rows keyed by budget source id or added entry, one cell per scenario.
final class DifferenceMatrixTests: XCTestCase {
    private func diff(_ id: Int64, _ kind: ScenarioChange, _ category: String, source: Int64? = nil, sourceSummary: String? = nil, summary: String = "s") -> ScenarioDifference {
        ScenarioDifference(id: id, kind: kind, categoryName: category, summary: summary, fieldChanges: [], sourceEntryId: source, sourceSummary: sourceSummary)
    }

    func testTwoScenariosChangingTheSameBudgetItemShareOneRow() {
        let rows = DifferenceMatrix.rows(differences: [
            (scenarioId: 1, differences: [diff(10, .changed, "Car", source: 5, sourceSummary: "budget car")]),
            (scenarioId: 2, differences: [diff(20, .removed, "Car", source: 5, sourceSummary: "budget car")]),
        ])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "source-5")
        XCTAssertEqual(rows[0].categoryName, "Car")
        XCTAssertFalse(rows[0].isAdded)
        XCTAssertEqual(rows[0].budgetSummary, "budget car")
        XCTAssertEqual(rows[0].cells[1]?.id, 10)
        XCTAssertEqual(rows[0].cells[2]?.kind, .removed)
    }

    func testAnAddedEntryGetsItsOwnRowWithOnlyItsScenarioCell() {
        let rows = DifferenceMatrix.rows(differences: [
            (scenarioId: 1, differences: [diff(10, .added, "Gym")]),
            (scenarioId: 2, differences: []),
        ])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "added-1-10")
        XCTAssertTrue(rows[0].isAdded)
        XCTAssertNil(rows[0].budgetSummary)
        XCTAssertEqual(Array(rows[0].cells.keys), [1])
    }

    func testRowsSortByCategoryNameThenId() {
        let rows = DifferenceMatrix.rows(differences: [
            (scenarioId: 1, differences: [
                diff(10, .changed, "Rent", source: 1, sourceSummary: "r"),
                diff(11, .added, "Car"),
                diff(12, .changed, "Car", source: 9, sourceSummary: "c"),
                diff(13, .added, "Apples"),
            ]),
        ])
        XCTAssertEqual(rows.map(\.categoryName), ["Apples", "Car", "Car", "Rent"])
        XCTAssertEqual(rows.map(\.id), ["added-1-13", "added-1-11", "source-9", "source-1"])
    }

    func testNoDifferencesNoRows() {
        XCTAssertEqual(DifferenceMatrix.rows(differences: [(scenarioId: 1, differences: [])]), [])
    }
}
