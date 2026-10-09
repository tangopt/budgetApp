import XCTest
@testable import BudgetCore

final class ImportFinishPlanTests: XCTestCase {
    private func row(_ description: String, category: Int64?, learnRule: Bool = false) -> ImportFinishPlan.Row {
        let staged = StagedTransaction(
            parsed: ParsedTransaction(date: Date(timeIntervalSince1970: 0), rawDescription: description, amountMinorUnits: -100),
            suggestedCategoryId: nil, source: .none, confidence: 0, fingerprint: description
        )
        return ImportFinishPlan.Row(staged: staged, decision: ImportDecision(stagedId: staged.id, finalCategoryId: category, learnRule: learnRule))
    }

    func testLeavingUnconfirmedOutKeepsOnlyConfirmedRowsInReviewOrder() {
        let rows = [row("A", category: 1), row("B", category: nil), row("C", category: 2)]
        let plan = ImportFinishPlan.make(rows: rows, confirmedIds: [rows[2].staged.id, rows[0].staged.id], unconfirmed: .leaveOut)
        XCTAssertEqual(plan.staged.map(\.parsed.rawDescription), ["A", "C"])
        XCTAssertEqual(plan.decisions.map(\.stagedId), [rows[0].staged.id, rows[2].staged.id])
    }

    func testSavingUnconfirmedIncludesEveryRowWithItsDecision() {
        let rows = [row("A", category: 1, learnRule: true), row("B", category: nil), row("C", category: 3)]
        let plan = ImportFinishPlan.make(rows: rows, confirmedIds: [rows[0].staged.id], unconfirmed: .saveAsUncategorized)
        XCTAssertEqual(plan.staged.map(\.parsed.rawDescription), ["A", "B", "C"])
        // An unconfirmed row keeps a category if one was chosen (like "Save remaining").
        XCTAssertEqual(plan.decisions.map(\.finalCategoryId), [1, nil, 3])
        XCTAssertEqual(plan.decisions.map(\.learnRule), [true, false, false])
    }

    func testNothingConfirmedSavesEverythingOrNothing() {
        let rows = [row("A", category: nil), row("B", category: 2)]
        XCTAssertEqual(ImportFinishPlan.make(rows: rows, confirmedIds: [], unconfirmed: .saveAsUncategorized).staged.count, 2)
        XCTAssertTrue(ImportFinishPlan.make(rows: rows, confirmedIds: [], unconfirmed: .leaveOut).isEmpty)
    }

    func testConfirmedIdsNotInTheReviewAreIgnored() {
        let rows = [row("A", category: 1)]
        let plan = ImportFinishPlan.make(rows: rows, confirmedIds: [UUID()], unconfirmed: .leaveOut)
        XCTAssertTrue(plan.isEmpty)
    }
}
