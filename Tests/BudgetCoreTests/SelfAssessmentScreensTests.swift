import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// What the Self Assessment tabs read (plan phase 4 Task 4). Synthetic people and amounts.
final class SelfAssessmentScreensTests: XCTestCase {
    private func pounds(_ value: Int) -> Int { value * 100 }

    func testYearPageCarriesIncomeComputationAndFiling() throws {
        let manager = try TestDatabase.migratedManager()
        try manager.dbQueue.write { db in
            var person = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &person)
            let personId = person.id!
            var employment = Employment(startYear: 2024, personId: personId, employerName: "Example Ltd", payeReference: "123/AB456")
            var document = EvidenceDocument(sha256: "p60", storedRelativePath: "p6/p60.pdf", originalFileName: "P60.pdf", byteCount: 1,
                                            kind: .p60, addedAt: Date())
            try document.insert(db)
            try Employments.save(db: db, &employment, documents: EvidenceLinkChanges(link: [document.id!]))
            var income = EmploymentIncome(employmentId: employment.id!, source: .p60, payMinorUnits: pounds(60_000), taxDeductedMinorUnits: pounds(11_000))
            try Employments.save(db: db, &income, documents: EvidenceLinkChanges())
            var payment = HMRCPayment(personId: personId, startYear: 2025, date: MonthRange.calendar.date(from: DateComponents(year: 2026, month: 1, day: 20))!,
                                      amountMinorUnits: pounds(100), kind: .firstPaymentOnAccount)
            try HMRCPayments.save(db: db, &payment, documents: EvidenceLinkChanges(), markYear: .paid)

            // A person with only an employment gets tax years too.
            let rows = try TaxOverview.rows(db: db, now: MonthRange.calendar.date(from: DateComponents(year: 2025, month: 6, day: 1))!)
            XCTAssertEqual(rows.map(\.year.startYear), [2025, 2024])
            XCTAssertEqual(rows.first?.status, .paid)

            let page = try XCTUnwrap(try TaxOverview.page(db: db, personId: personId, startYear: 2024))
            XCTAssertEqual(page.income.employments.map(\.employment.employerName), ["Example Ltd"])
            XCTAssertEqual(page.income.employments.first?.documentCount, 1)
            XCTAssertEqual(page.income.payments.map(\.kind), [.firstPaymentOnAccount])
            XCTAssertFalse(page.income.hasEvidenceRules)
            let result = try XCTUnwrap(page.selfAssessment)
            XCTAssertNil(page.selfAssessmentError)
            // £60,000 − £12,570 = £47,430: £37,700 × 20% + £9,730 × 40% = £11,432.
            XCTAssertEqual(result.calculation.incomeTaxDue, pounds(11_432))
            XCTAssertEqual(result.calculation.selfAssessmentLiability, pounds(432))
            XCTAssertEqual(result.box(.sa102, "1")?.step, "Employment 1: Example Ltd")
            XCTAssertEqual(result.box(.sa102, "1")?.copyText, "60000")
            XCTAssertEqual(result.box(.sa110, "1")?.copyText, "432.00")
            XCTAssertEqual(result.box(.sa110, "1")?.step, "Tax deducted")
            XCTAssertEqual(result.boxGroups.map(\.form), [.sa100, .sa102, .sa110])

            XCTAssertEqual(page.filing.map(\.title), ["Sign in to HMRC online", "Tailor your return", "Employment 1: Example Ltd",
                                                      "Check HMRC's calculation", "Submit the return", "Pay by 31 January"])
            XCTAssertEqual(page.filing.last?.values.first?.value, .amount(pounds(432)))
            XCTAssertEqual(page.filing.last?.deadline, UKTaxYear(startYear: 2024).deadlines.onlineReturnAndBalancingPayment)

            try PersonalIncomeEvidence.seedRules(db: db)
            XCTAssertTrue(try SelfAssessmentOverview.incomePage(db: db, startYear: 2024, personId: personId).hasEvidenceRules)
            XCTAssertEqual(try TaxOverview.page(db: db, personId: personId, startYear: 2014)?.selfAssessmentError,
                           "The UK tax rules for 2014/15 aren't in the app yet.")
        }
    }

    func testCopyText() {
        XCTAssertEqual(SelfAssessment.BoxValue.amount(1_234_567).copyText, "12345")
        XCTAssertEqual(SelfAssessment.BoxValue.amount(-50_000).copyText, "-500")
        XCTAssertEqual(SelfAssessment.BoxValue.amount(1_234_567).copyText(wholePounds: false), "12345.67")
        XCTAssertEqual(SelfAssessment.BoxValue.amount(-5).copyText(wholePounds: false), "-0.05")
        XCTAssertEqual(SelfAssessmentFiling.Value(label: "Balancing payment", box: nil, value: .amount(12_345)).copyText, "123.45")
        XCTAssertEqual(SelfAssessmentFiling.Value(label: "Pay", box: "1", value: .amount(12_345)).copyText, "123")
        XCTAssertEqual(SelfAssessment.BoxValue.text("PRT").copyText, "PRT")
        XCTAssertEqual(SelfAssessment.BoxValue.cross.copyText, "X")
        // Whether the figure shows in whole pounds follows the copy: SA110 and HMRC's calculation keep pence.
        XCTAssertTrue(SelfAssessment.Box(form: .sa106, section: "Land and property abroad", number: "14", label: "Rents", value: .amount(12_345)).isWholePounds)
        let sa110 = SelfAssessment.Box(form: .sa110, section: "Self Assessment", number: "1", label: "Total tax due", value: .amount(12_345))
        XCTAssertFalse(sa110.isWholePounds)
        XCTAssertEqual(sa110.copyText, "123.45")
        XCTAssertFalse(SelfAssessmentFiling.Value(label: "Total tax due", box: "SA110 1", value: .amount(12_345)).isWholePounds)
        XCTAssertFalse(SelfAssessmentFiling.Value(label: "Balancing payment", box: nil, value: .amount(12_345)).isWholePounds)
        XCTAssertTrue(SelfAssessmentFiling.Value(label: "Pay", box: "1", value: .amount(12_345)).isWholePounds)
    }
}
