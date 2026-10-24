import Foundation

/// The UK income tax rules of one tax year, England and Northern Ireland (and Wales) — not
/// Scotland (spec 2026-10-16 §4; plan phase 4 Task 2). Stored as data, one entry per year with
/// the GOV.UK pages each figure comes from, so a new year is a new entry and nothing is
/// hard-coded for a single year. Amounts are pence; rates are basis points (2 000 = 20%).
public struct UKTaxRules: Equatable, Sendable {
    /// Where a group of figures was published.
    public struct Source: Equatable, Sendable {
        /// The figures it covers ("bands", "dividends"…).
        public var covers: String
        public var url: String
        public var note: String?

        public init(covers: String, url: String, note: String? = nil) {
            self.covers = covers
            self.url = url
            self.note = note
        }
    }

    public var startYear: Int

    // Allowances
    public var personalAllowance: Int
    /// Adjusted net income above which the personal allowance goes down by £1 for every £2.
    public var personalAllowanceIncomeLimit: Int

    // Bands of taxable income (after allowances)
    /// The top of the basic rate band (£37,700 = 3 770 000).
    public var basicRateBand: Int
    /// Taxable income above which the additional rate applies (the top of the higher band).
    public var additionalRateThreshold: Int

    // Rates on non-savings, non-dividend income (employment, property, pensions)
    public var basicRate: Int
    public var higherRate: Int
    public var additionalRate: Int

    // Savings
    public var startingRateForSavings: Int
    public var startingRateForSavingsLimit: Int
    public var personalSavingsAllowanceBasic: Int
    public var personalSavingsAllowanceHigher: Int
    /// Additional-rate taxpayers have none.
    public var personalSavingsAllowanceAdditional: Int
    public var savingsBasicRate: Int
    public var savingsHigherRate: Int
    public var savingsAdditionalRate: Int

    // Dividends
    public var dividendAllowance: Int
    public var dividendOrdinaryRate: Int
    public var dividendUpperRate: Int
    public var dividendAdditionalRate: Int

    // Property
    /// The tax reduction on residential finance costs (the basic rate, 100% of costs from 2020/21).
    public var residentialFinanceCostReliefRate: Int
    /// The share (basis points) of residential finance costs still deducted as an expense: all
    /// of them to 2016/17, then 75% (2017/18), 50% (2018/19), 25% (2019/20) and none from
    /// 2020/21; the rest gets the reduction above (GOV.UK, "Changes to tax relief for
    /// residential landlords").
    public var residentialFinanceCostsDeductibleShare: Int = 0

    // Payments on account
    /// No payments on account when the year's Self Assessment liability is below this.
    public var paymentsOnAccountThreshold: Int
    /// …or when more than this share (basis points) of the year's income tax was deducted at source.
    public var paymentsOnAccountDeductedAtSourceShare: Int

    public var sources: [Source]

    public var ukTaxYear: UKTaxYear { UKTaxYear(startYear: startYear) }

    // MARK: Rules

    /// The personal allowance for an adjusted net income: reduced by £1 for every £2 above the
    /// limit (whole pounds of excess), down to nothing.
    public func personalAllowance(adjustedNetIncome income: Int) -> Int {
        let excessPounds = max(0, income - personalAllowanceIncomeLimit) / 100
        return max(0, personalAllowance - excessPounds / 2 * 100)
    }

    public enum Band: String, Codable, Sendable {
        case basic
        case higher
        case additional
    }

    /// The band the top of `taxableIncome` (after allowances) falls in.
    public func band(taxableIncome: Int) -> Band {
        if taxableIncome > additionalRateThreshold { return .additional }
        if taxableIncome > basicRateBand { return .higher }
        return .basic
    }

    /// The personal savings allowance of a taxpayer in `band`.
    public func personalSavingsAllowance(band: Band) -> Int {
        switch band {
        case .basic: return personalSavingsAllowanceBasic
        case .higher: return personalSavingsAllowanceHigher
        case .additional: return personalSavingsAllowanceAdditional
        }
    }

    /// The non-savings rate of a band.
    public func rate(_ band: Band) -> Int {
        switch band {
        case .basic: return basicRate
        case .higher: return higherRate
        case .additional: return additionalRate
        }
    }

    /// The dividend rate of a band.
    public func dividendRate(_ band: Band) -> Int {
        switch band {
        case .basic: return dividendOrdinaryRate
        case .higher: return dividendUpperRate
        case .additional: return dividendAdditionalRate
        }
    }

    /// Whether payments on account are due for the next year: not when the year's Self
    /// Assessment liability (after tax deducted at source) is below the threshold, nor when
    /// more than 80% of the year's income tax was deducted at source (PAYE and other tax taken
    /// off before the income was paid). `totalIncomeTax` is the tax due after reliefs and
    /// credits such as Foreign Tax Credit Relief, which reduce the liability but aren't tax
    /// deducted at source.
    public func paymentsOnAccountDue(selfAssessmentLiability: Int, totalIncomeTax: Int) -> Bool {
        guard selfAssessmentLiability >= paymentsOnAccountThreshold else { return false }
        let deductedAtSource = max(0, totalIncomeTax - selfAssessmentLiability)
        return deductedAtSource * 10_000 <= totalIncomeTax * paymentsOnAccountDeductedAtSourceShare
    }

    /// Each of the two payments on account: half the year's Self Assessment liability, pence
    /// rounded down; zero when none are due.
    public func paymentOnAccount(selfAssessmentLiability: Int, totalIncomeTax: Int) -> Int {
        paymentsOnAccountDue(selfAssessmentLiability: selfAssessmentLiability, totalIncomeTax: totalIncomeTax) ? selfAssessmentLiability / 2 : 0
    }

    /// `amount` × `rate` (basis points), pence rounded down as HMRC's calculation does.
    public static func apply(_ rate: Int, to amount: Int) -> Int {
        amount * rate / 10_000
    }

    // MARK: Data

    /// The years the app knows, earliest first.
    public static var knownYears: [Int] { all.map(\.startYear) }

    /// The rules of the year starting in `startYear`; `nil` for a year not entered yet.
    public static func forYear(_ startYear: Int) -> UKTaxRules? {
        all.first { $0.startYear == startYear }
    }

    private static func pounds(_ value: Int) -> Int { value * 100 }

    // GOV.UK sources (checked 2026-10-16).
    static let annexBudget2020 = "https://assets.publishing.service.gov.uk/government/uploads/system/uploads/attachment_data/file/872424/Annex_A_-_rates_and_allowances.pdf"
    static let annexBudget2021 = "https://www.gov.uk/government/publications/budget-2021-overview-of-tax-legislation-and-rates-ootlar/annex-a-rates-and-allowances"
    static let annexAutumnBudget2021 = "https://www.gov.uk/government/publications/autumn-budget-2021-overview-of-tax-legislation-and-rates-ootlar/annex-a-rates-and-allowances"
    static let annexAutumnStatement2023 = "https://www.gov.uk/government/publications/autumn-statement-2023-overview-of-tax-legislation-and-rates-ootlar/annex-a-rates-and-allowances"
    static let annexBudget2025 = "https://www.gov.uk/government/publications/budget-2025-overview-of-tax-legislation-and-rates-ootlar/annex-a-rates-and-allowances"
    static let ratesCurrentAndPast = "https://www.gov.uk/government/publications/rates-and-allowances-income-tax/income-tax-rates-and-allowances-current-and-past"
    static let financeCosts = "https://www.gov.uk/guidance/changes-to-tax-relief-for-residential-landlords-how-its-worked-out-including-case-studies"
    static let paymentsOnAccount = "https://www.gov.uk/understand-self-assessment-bill/payments-on-account"

    static func commonSources(_ annex: String, note: String? = nil) -> [Source] {
        [
            Source(covers: "Allowances, bands, rates, savings and dividends", url: annex, note: note),
            Source(covers: "Residential finance costs: 20% basic rate reduction on 100% of costs from 2020/21", url: financeCosts),
            Source(covers: "Payments on account: not due under £1,000 or when over 80% was deducted at source", url: paymentsOnAccount)
        ]
    }

    static func year(_ startYear: Int, personalAllowance: Int = 12_570, basicRateBand: Int = 37_700, additionalRateThreshold: Int,
                     dividendAllowance: Int, dividendRates: (Int, Int, Int), personalSavingsAllowance: (Int, Int) = (1_000, 500),
                     financeCostsDeductibleShare: Int = 0, sources: [Source]) -> UKTaxRules {
        UKTaxRules(startYear: startYear, personalAllowance: pounds(personalAllowance), personalAllowanceIncomeLimit: pounds(100_000),
                   basicRateBand: pounds(basicRateBand), additionalRateThreshold: pounds(additionalRateThreshold),
                   basicRate: 2_000, higherRate: 4_000, additionalRate: 4_500,
                   startingRateForSavings: 0, startingRateForSavingsLimit: pounds(5_000),
                   personalSavingsAllowanceBasic: pounds(personalSavingsAllowance.0), personalSavingsAllowanceHigher: pounds(personalSavingsAllowance.1),
                   personalSavingsAllowanceAdditional: 0,
                   savingsBasicRate: 2_000, savingsHigherRate: 4_000, savingsAdditionalRate: 4_500,
                   dividendAllowance: pounds(dividendAllowance), dividendOrdinaryRate: dividendRates.0, dividendUpperRate: dividendRates.1,
                   dividendAdditionalRate: dividendRates.2, residentialFinanceCostReliefRate: 2_000,
                   residentialFinanceCostsDeductibleShare: financeCostsDeductibleShare,
                   paymentsOnAccountThreshold: pounds(1_000), paymentsOnAccountDeductedAtSourceShare: 8_000, sources: sources)
    }

    /// The earlier years' figures (GOV.UK "Income Tax rates and allowances: current and past"),
    /// with the phasing of the finance cost restriction.
    static func earlierSources(deductible: String) -> [Source] {
        [
            Source(covers: "Allowances, bands, rates, savings and dividends", url: ratesCurrentAndPast),
            Source(covers: "Residential finance costs: \(deductible)", url: financeCosts),
            Source(covers: "Payments on account: not due under £1,000 or when over 80% was deducted at source", url: paymentsOnAccount)
        ]
    }

    /// 2015/16 to 2026/27. Scotland's bands differ and are not here. Before 2016/17 there was
    /// no personal savings allowance and dividends carried a 10% tax credit instead of an
    /// allowance (the credit isn't modelled: no dividends have been computed for those years).
    public static let all: [UKTaxRules] = [
        year(2015, personalAllowance: 10_600, basicRateBand: 31_785, additionalRateThreshold: 150_000, dividendAllowance: 0,
             dividendRates: (1_000, 3_250, 3_750), personalSavingsAllowance: (0, 0), financeCostsDeductibleShare: 10_000,
             sources: earlierSources(deductible: "all deductible as an expense (restriction starts 2017/18)")),
        year(2016, personalAllowance: 11_000, basicRateBand: 32_000, additionalRateThreshold: 150_000, dividendAllowance: 5_000,
             dividendRates: (750, 3_250, 3_810), financeCostsDeductibleShare: 10_000,
             sources: earlierSources(deductible: "all deductible as an expense (restriction starts 2017/18)")),
        year(2017, personalAllowance: 11_500, basicRateBand: 33_500, additionalRateThreshold: 150_000, dividendAllowance: 5_000,
             dividendRates: (750, 3_250, 3_810), financeCostsDeductibleShare: 7_500,
             sources: earlierSources(deductible: "75% deductible, 25% gets the 20% reduction")),
        year(2018, personalAllowance: 11_850, basicRateBand: 34_500, additionalRateThreshold: 150_000, dividendAllowance: 2_000,
             dividendRates: (750, 3_250, 3_810), financeCostsDeductibleShare: 5_000,
             sources: earlierSources(deductible: "50% deductible, 50% gets the 20% reduction")),
        year(2019, personalAllowance: 12_500, basicRateBand: 37_500, additionalRateThreshold: 150_000, dividendAllowance: 2_000,
             dividendRates: (750, 3_250, 3_810), financeCostsDeductibleShare: 2_500,
             sources: earlierSources(deductible: "25% deductible, 75% gets the 20% reduction")),
        year(2020, personalAllowance: 12_500, basicRateBand: 37_500, additionalRateThreshold: 150_000, dividendAllowance: 2_000,
             dividendRates: (750, 3_250, 3_810),
             sources: commonSources(annexBudget2020) + [Source(covers: "Personal allowance £12,500, savings and dividend allowances", url: annexBudget2021)]),
        year(2021, additionalRateThreshold: 150_000, dividendAllowance: 2_000, dividendRates: (750, 3_250, 3_810),
             sources: commonSources(annexAutumnBudget2021) + [Source(covers: "Allowances and dividend rates", url: annexBudget2021)]),
        year(2022, additionalRateThreshold: 150_000, dividendAllowance: 2_000, dividendRates: (875, 3_375, 3_935),
             sources: commonSources(annexAutumnBudget2021, note: "Dividend rates up 1.25 points from April 2022")),
        year(2023, additionalRateThreshold: 125_140, dividendAllowance: 1_000, dividendRates: (875, 3_375, 3_935),
             sources: commonSources(annexAutumnStatement2023, note: "Additional rate threshold lowered to £125,140; dividend allowance £1,000")
                + [Source(covers: "Bands and dividends", url: ratesCurrentAndPast)]),
        year(2024, additionalRateThreshold: 125_140, dividendAllowance: 500, dividendRates: (875, 3_375, 3_935),
             sources: commonSources(annexAutumnStatement2023, note: "Dividend allowance £500") + [Source(covers: "Bands and dividends", url: ratesCurrentAndPast)]),
        year(2025, additionalRateThreshold: 125_140, dividendAllowance: 500, dividendRates: (875, 3_375, 3_935),
             sources: commonSources(annexBudget2025) + [Source(covers: "Bands and dividends", url: ratesCurrentAndPast)]),
        year(2026, additionalRateThreshold: 125_140, dividendAllowance: 500, dividendRates: (1_075, 3_575, 3_935),
             sources: commonSources(annexBudget2025, note: "Dividend ordinary and upper rates up 2 points from April 2026")
                + [Source(covers: "Bands and dividends", url: ratesCurrentAndPast)])
    ]
}
