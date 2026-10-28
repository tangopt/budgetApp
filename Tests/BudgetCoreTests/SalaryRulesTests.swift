import XCTest
@testable import BudgetCore

final class SalaryRulesTests: XCTestCase {
    func testTablesExistFor2025And2026() {
        XCTAssertEqual(SalaryRules.forYear(2025)?.startYear, 2025)
        XCTAssertEqual(SalaryRules.forYear(2026)?.startYear, 2026)
        XCTAssertEqual(SalaryRules.latest.startYear, 2026)
        XCTAssertEqual(SalaryRules.all.map(\.startYear), [2025, 2026])
        // 2025/26 headline figures (GOV.UK income-tax-rates, employers' rates and thresholds).
        let rules = SalaryRules.forYear(2025)!
        XCTAssertEqual(rules.personalAllowance, 1_257_000)
        XCTAssertEqual(rules.basicRateBand, 3_770_000)
        XCTAssertEqual(rules.additionalThreshold, 12_514_000)
        XCTAssertEqual(rules.niPrimaryThreshold, 1_257_000)
        XCTAssertEqual(rules.niUpperEarningsLimit, 5_027_000)
        XCTAssertEqual(rules.studentLoanPlan2Threshold, 2_847_000)
    }

    func testEveryTableHasSources() {
        for rules in SalaryRules.all {
            XCTAssertFalse(rules.sources.isEmpty, "\(rules.startYear)")
            for source in rules.sources {
                XCTAssertTrue(source.url.hasPrefix("https://www.gov.uk/"), source.url)
            }
        }
    }

    func testCheckedFieldsListed() {
        let rules = SalaryRules.forYear(2026)!
        XCTAssertFalse(rules.checkedFields.isEmpty)
        for table in SalaryRules.all {
            let names = Set(Mirror(reflecting: table).children.compactMap(\.label))
            for field in table.checkedFields {
                XCTAssertTrue(names.contains(field), "\(table.startYear): \(field) is not a property")
            }
        }
        XCTAssertEqual(Set(SalaryRules.forYear(2025)!.checkedFields),
                       ["scottishBands", "studentLoanPlan4Threshold", "studentLoanPlan5Threshold"])
    }

    func testUnknownYearIsNil() {
        XCTAssertNil(SalaryRules.forYear(2024))
        XCTAssertNil(SalaryRules.forYear(2031))
    }
}
