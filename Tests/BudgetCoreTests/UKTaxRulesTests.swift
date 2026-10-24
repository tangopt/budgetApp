import XCTest
@testable import BudgetCore

/// The UK rules by year (plan phase 4 Task 2) against the figures GOV.UK publishes
/// (England and Northern Ireland). Amounts pence, rates basis points.
final class UKTaxRulesTests: XCTestCase {
    private func rules(_ year: Int) throws -> UKTaxRules { try XCTUnwrap(UKTaxRules.forYear(year)) }

    func testEveryYearFrom2015To2026IsKnownOnce() {
        XCTAssertEqual(UKTaxRules.knownYears, Array(2015...2026))
        XCTAssertNil(UKTaxRules.forYear(2014))
        XCTAssertNil(UKTaxRules.forYear(2027))
    }

    /// 2015/16 to 2019/20 (the years of a Worldwide Disclosure Facility disclosure): the
    /// allowances and bands of each year, and the phased restriction of residential finance
    /// costs — fully deductible to 2016/17, then 75%, 50% and 25% deductible, the rest getting
    /// the 20% reduction; nothing deductible from 2020/21.
    func testEarlierYearsAllowancesBandsAndFinanceCostPhasing() throws {
        let expected: [(Int, Int, Int, Int)] = [
            (2015, 10_600, 31_785, 10_000), (2016, 11_000, 32_000, 10_000), (2017, 11_500, 33_500, 7_500),
            (2018, 11_850, 34_500, 5_000), (2019, 12_500, 37_500, 2_500)
        ]
        for (year, allowance, band, share) in expected {
            let r = try rules(year)
            XCTAssertEqual(r.personalAllowance, allowance * 100, "\(year)")
            XCTAssertEqual(r.basicRateBand, band * 100, "\(year)")
            XCTAssertEqual(r.additionalRateThreshold, 15_000_000, "\(year)")
            XCTAssertEqual(r.residentialFinanceCostsDeductibleShare, share, "\(year)")
            XCTAssertEqual(r.residentialFinanceCostReliefRate, 2_000, "\(year)")
        }
        for year in 2020...2026 { XCTAssertEqual(try rules(year).residentialFinanceCostsDeductibleShare, 0, "\(year)") }
        // No personal savings allowance before 2016/17; the dividend allowance £5,000 in 2016/17 and 2017/18, £2,000 from 2018/19.
        XCTAssertEqual(try rules(2015).personalSavingsAllowance(band: .basic), 0)
        XCTAssertEqual(try rules(2016).personalSavingsAllowance(band: .basic), 100_000)
        XCTAssertEqual(try rules(2015).dividendAllowance, 0)
        XCTAssertEqual(try rules(2016).dividendAllowance, 500_000)
        XCTAssertEqual(try rules(2017).dividendAllowance, 500_000)
        XCTAssertEqual(try rules(2018).dividendAllowance, 200_000)
        XCTAssertEqual(try rules(2019).dividendAllowance, 200_000)
    }

    func testPersonalAllowanceAndBands() throws {
        let y2020 = try rules(2020)
        XCTAssertEqual(y2020.personalAllowance, 1_250_000)
        XCTAssertEqual(y2020.basicRateBand, 3_750_000)
        XCTAssertEqual(y2020.additionalRateThreshold, 15_000_000)
        for year in 2021...2022 {
            let r = try rules(year)
            XCTAssertEqual(r.personalAllowance, 1_257_000, "\(year)")
            XCTAssertEqual(r.basicRateBand, 3_770_000, "\(year)")
            XCTAssertEqual(r.additionalRateThreshold, 15_000_000, "\(year)")
        }
        for year in 2023...2026 {
            let r = try rules(year)
            XCTAssertEqual(r.personalAllowance, 1_257_000, "\(year)")
            XCTAssertEqual(r.basicRateBand, 3_770_000, "\(year)")
            XCTAssertEqual(r.additionalRateThreshold, 12_514_000, "\(year)")
        }
        for r in UKTaxRules.all {
            XCTAssertEqual(r.personalAllowanceIncomeLimit, 10_000_000, "\(r.startYear)")
            XCTAssertEqual([r.basicRate, r.higherRate, r.additionalRate], [2_000, 4_000, 4_500], "\(r.startYear)")
            XCTAssertEqual([r.savingsBasicRate, r.savingsHigherRate, r.savingsAdditionalRate], [2_000, 4_000, 4_500], "\(r.startYear)")
        }
    }

    func testSavingsAndDividends() throws {
        let recent = UKTaxRules.all.filter { $0.startYear >= 2020 }
        for r in UKTaxRules.all {
            XCTAssertEqual(r.startingRateForSavings, 0)
            XCTAssertEqual(r.startingRateForSavingsLimit, 500_000)
        }
        for r in recent {
            XCTAssertEqual(r.personalSavingsAllowance(band: .basic), 100_000)
            XCTAssertEqual(r.personalSavingsAllowance(band: .higher), 50_000)
            XCTAssertEqual(r.personalSavingsAllowance(band: .additional), 0)
        }
        let allowances = recent.map { $0.dividendAllowance }
        XCTAssertEqual(allowances, [200_000, 200_000, 200_000, 100_000, 50_000, 50_000, 50_000])
        let rates = recent.map { [$0.dividendOrdinaryRate, $0.dividendUpperRate, $0.dividendAdditionalRate] }
        XCTAssertEqual(rates, [[750, 3_250, 3_810], [750, 3_250, 3_810], [875, 3_375, 3_935], [875, 3_375, 3_935],
                               [875, 3_375, 3_935], [875, 3_375, 3_935], [1_075, 3_575, 3_935]])
    }

    func testFinanceCostsAndPaymentsOnAccount() throws {
        for r in UKTaxRules.all {
            XCTAssertEqual(r.residentialFinanceCostReliefRate, 2_000)
            XCTAssertEqual(r.paymentsOnAccountThreshold, 100_000)
            XCTAssertEqual(r.paymentsOnAccountDeductedAtSourceShare, 8_000)
            XCTAssertFalse(r.sources.isEmpty)
            XCTAssertTrue(r.sources.allSatisfy { $0.url.hasPrefix("https://") && $0.url.contains("gov.uk") })
        }
        let r = try rules(2024)
        // Under £1,000 owed through Self Assessment: none.
        XCTAssertFalse(r.paymentsOnAccountDue(selfAssessmentLiability: 99_999, totalIncomeTax: 200_000))
        XCTAssertEqual(r.paymentOnAccount(selfAssessmentLiability: 99_999, totalIncomeTax: 200_000), 0)
        // Over 80% deducted at source: none (£10,000 of £50,000 through SA = 80% at source, still due).
        XCTAssertFalse(r.paymentsOnAccountDue(selfAssessmentLiability: 900_000, totalIncomeTax: 5_000_000))
        XCTAssertTrue(r.paymentsOnAccountDue(selfAssessmentLiability: 1_000_000, totalIncomeTax: 5_000_000))
        XCTAssertEqual(r.paymentOnAccount(selfAssessmentLiability: 1_000_001, totalIncomeTax: 5_000_000), 500_000)
    }

    func testPersonalAllowanceTaperAndBands() throws {
        let r = try rules(2024)
        XCTAssertEqual(r.personalAllowance(adjustedNetIncome: 10_000_000), 1_257_000)
        XCTAssertEqual(r.personalAllowance(adjustedNetIncome: 10_000_300), 1_256_900) // £3 over: £1 less
        XCTAssertEqual(r.personalAllowance(adjustedNetIncome: 11_000_000), 757_000)
        XCTAssertEqual(r.personalAllowance(adjustedNetIncome: 12_514_000), 0)
        XCTAssertEqual(r.personalAllowance(adjustedNetIncome: 20_000_000), 0)
        XCTAssertEqual(try rules(2020).personalAllowance(adjustedNetIncome: 12_500_000), 0)

        XCTAssertEqual(r.band(taxableIncome: 3_770_000), .basic)
        XCTAssertEqual(r.band(taxableIncome: 3_770_001), .higher)
        XCTAssertEqual(r.band(taxableIncome: 12_514_001), .additional)
        XCTAssertEqual(r.rate(.higher), 4_000)
        XCTAssertEqual(r.dividendRate(.basic), 875)
        XCTAssertEqual(UKTaxRules.apply(2_000, to: 123_457), 24_691)
    }
}
