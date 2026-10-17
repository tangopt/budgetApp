import XCTest
import GRDB
@testable import BudgetCore

/// The Self Assessment regression (plan phase 4 Task 5) on synthetic forms and figures.
final class SelfAssessmentRegressionTests: XCTestCase {
    func testImportsTheFormsComputesAndCompares() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SARegression-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = EvidenceLibrary(root: root, database: manager.dbQueue)
        let personId = try manager.dbQueue.write { db -> Int64 in
            var person = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &person)
            return person.id!
        }

        let p60 = PayrollFormTestPDFs.textPDF(PayrollFormTestPDFs.p60RowLayout, name: "p60.pdf")
        let (extraction, imported) = try SelfAssessmentRegression.importForm(library: library, url: p60, personId: personId, startYear: 2024, kind: .p60)
        XCTAssertEqual(extraction.payMinorUnits, 4_567_890)
        XCTAssertTrue(imported.linkedDocument)
        try manager.dbQueue.write { db in
            try SelfAssessmentRegression.record(db: db, payment: .init(date: "2025-01-31", amount: "100.00", kind: "firstPaymentOnAccount",
                                                                       startYear: 2024, reference: nil), personId: personId)
            // Recording it again replaces it.
            try SelfAssessmentRegression.record(db: db, payment: .init(date: "2025-01-31", amount: "100.00", kind: "firstPaymentOnAccount",
                                                                       startYear: 2024, reference: nil), personId: personId)
            XCTAssertEqual(try HMRCPayment.fetchCount(db), 1)
            XCTAssertThrowsError(try SelfAssessmentRegression.record(db: db, payment: .init(date: "2025-13-99", amount: "1", kind: "refund", startYear: 2024,
                                                                                            reference: nil), personId: personId))
        }
        let result = try manager.dbQueue.read { db in try SelfAssessment.compute(db: db, startYear: 2024, personId: personId) }
        // £45,678 pay (rounded down), £6,544 tax (rounded up): £33,108 × 20% = £6,621.60.
        let rows = try SelfAssessmentRegression.compare(person: "Person A", result: result, filed: [
            "sa102.1": "45678", "sa102.2": "6544", "calc.incomeTaxDue": "6621.60", "calc.taxDeducted": "6544",
            "sa110.1": "77.60", "calc.balancingPayment": "-22.40", "calc.nextPaymentOnAccount": "0", "sa106.14": "1"
        ])
        XCTAssertEqual(rows.map(\.field), ["sa102.1", "sa102.2", "sa106.14", "calc.incomeTaxDue", "calc.taxDeducted", "sa110.1",
                                           "calc.balancingPayment", "calc.nextPaymentOnAccount"])
        XCTAssertEqual(rows.filter { !$0.matches }.map(\.field), ["sa106.14"])
        XCTAssertNil(rows.first { $0.field == "sa106.14" }?.app)
        let report = SelfAssessmentRegression.report(rows, results: ["2024|Person A": result])
        XCTAssertTrue(report.contains("== 2024/25 · Person A =="))
        XCTAssertTrue(report.contains("*SA106 box 14 rents"))
        XCTAssertThrowsError(try SelfAssessmentRegression.compare(person: "A", result: result, filed: ["sa102.1": "abc"]))
    }

    func testPropertyBoxesIncludingTheFTCRTotal() throws {
        let rules = UKTaxRules.forYear(2024)!
        let result = SelfAssessment.calculate(.init(startYear: 2024, employments: [.init(employerName: "Example Ltd", pay: 2_000_000, taxDeducted: 148_600)],
                                                    properties: [.init(name: "Property A", country: "PT", income: 1_000_000, expenses: 100_000,
                                                                       financeCosts: 200_000, foreignTax: 250_000)]), rules: rules)
        XCTAssertEqual(SelfAssessmentRegression.appValue("sa106.F1.2", result: result), 140_000)
        XCTAssertEqual(SelfAssessmentRegression.appValue("sa106.15", result: result), 100)
        XCTAssertEqual(SelfAssessmentRegression.appValue("sa106.C", result: result), 250_000)
        XCTAssertEqual(SelfAssessmentRegression.appValue("sa106.24.1", result: result), 200_000)
        XCTAssertEqual(result.box(.sa106, "2", section: "Foreign Tax Credit Relief")?.step, "Income Tax due after tax reductions")
    }
}
