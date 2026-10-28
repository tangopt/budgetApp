import Foundation

/// The UK payroll rules the salary simulator needs for one tax year: income tax (rest of the UK
/// and Scotland), employee Class 1 NI, student and postgraduate loans and pension relief at
/// source. Stored as data, one entry per year, with the GOV.UK pages each group comes from.
/// Amounts are pence; rates are basis points (2 000 = 20%). Values that could not be confirmed
/// offline are named in `checkedFields` for the user to confirm before relying on them.
public struct SalaryRules: Equatable, Sendable {
    /// One Scottish income tax band, as taxable income above the personal allowance.
    public struct ScottishBand: Equatable, Sendable {
        /// The top of the band in taxable income (pence); nil for the top band.
        public var upToTaxable: Int?
        public var rateBP: Int
        public var name: String

        public init(upToTaxable: Int?, rateBP: Int, name: String) {
            self.upToTaxable = upToTaxable
            self.rateBP = rateBP
            self.name = name
        }
    }

    public var startYear: Int

    // Personal allowance and its taper
    public var personalAllowance: Int
    /// Adjusted net income above which the allowance is withdrawn.
    public var taperThreshold: Int
    /// £1 of allowance lost (numerator) per £2 of income above the threshold (denominator).
    public var taperRateNumerator: Int
    public var taperRateDenominator: Int

    // England, Wales and Northern Ireland bands (taxable income after the allowance)
    public var basicRateBand: Int
    /// Taxable income above which the additional rate applies.
    public var additionalThreshold: Int
    public var basicRateBP: Int
    public var higherRateBP: Int
    public var additionalRateBP: Int

    // Scotland
    public var scottishBands: [ScottishBand]

    // Employee Class 1 NI (yearly figures)
    public var niPrimaryThreshold: Int
    public var niUpperEarningsLimit: Int
    public var niMainRateBP: Int
    public var niUpperRateBP: Int

    // Student loans (yearly thresholds)
    public var studentLoanPlan1Threshold: Int
    public var studentLoanPlan2Threshold: Int
    public var studentLoanPlan4Threshold: Int
    public var studentLoanPlan5Threshold: Int
    public var studentLoanRateBP: Int
    public var postgraduateLoanThreshold: Int
    public var postgraduateLoanRateBP: Int

    // Pensions
    /// The basic-rate relief a relief-at-source provider claims (the employee pays the rest).
    public var reliefAtSourceRateBP: Int

    public var sources: [UKTaxRules.Source]
    /// Property names whose values are marked `check: true`: not confirmed against GOV.UK offline.
    public var checkedFields: [String]

    public var ukTaxYear: UKTaxYear { UKTaxYear(startYear: startYear) }

    public func studentLoanThreshold(_ plan: StudentLoanPlan) -> Int {
        switch plan {
        case .plan1: return studentLoanPlan1Threshold
        case .plan2: return studentLoanPlan2Threshold
        case .plan4: return studentLoanPlan4Threshold
        case .plan5: return studentLoanPlan5Threshold
        }
    }

    // MARK: Table

    public static var all: [SalaryRules] { [y2025, y2026] }

    public static var latest: SalaryRules { all.max { $0.startYear < $1.startYear }! }

    public static func forYear(_ start: Int) -> SalaryRules? {
        all.first { $0.startYear == start }
    }

    static let incomeTaxRates = "https://www.gov.uk/income-tax-rates"
    static let scottishIncomeTax = "https://www.gov.uk/scottish-income-tax"
    static let employers2025 = "https://www.gov.uk/guidance/rates-and-thresholds-for-employers-2025-to-2026"
    static let employers2026 = "https://www.gov.uk/guidance/rates-and-thresholds-for-employers-2026-to-2027"
    static let studentLoanThresholds = "https://www.gov.uk/guidance/repayment-and-interest-rate-thresholds-for-student-and-postgraduate-loans"
    static let pensionTaxRelief = "https://www.gov.uk/tax-on-your-private-pension/pension-tax-relief"

    /// Every value property, for tables where nothing could be confirmed.
    static let allValueFields = [
        "personalAllowance", "taperThreshold", "taperRateNumerator", "taperRateDenominator",
        "basicRateBand", "additionalThreshold", "basicRateBP", "higherRateBP", "additionalRateBP",
        "scottishBands",
        "niPrimaryThreshold", "niUpperEarningsLimit", "niMainRateBP", "niUpperRateBP",
        "studentLoanPlan1Threshold", "studentLoanPlan2Threshold", "studentLoanPlan4Threshold",
        "studentLoanPlan5Threshold", "studentLoanRateBP", "postgraduateLoanThreshold", "postgraduateLoanRateBP",
        "reliefAtSourceRateBP"
    ]

    /// 2025/26.
    public static let y2025 = SalaryRules(
        startYear: 2025,
        personalAllowance: 1_257_000, taperThreshold: 10_000_000, taperRateNumerator: 1, taperRateDenominator: 2,
        basicRateBand: 3_770_000, additionalThreshold: 12_514_000,
        basicRateBP: 2_000, higherRateBP: 4_000, additionalRateBP: 4_500,
        // £12,571–£15,397 starter, –£27,491 basic, –£43,662 intermediate, –£75,000 higher,
        // –£125,140 advanced, above that top; as taxable income above the £12,570 allowance.
        scottishBands: [
            ScottishBand(upToTaxable: 282_700, rateBP: 1_900, name: "Starter"),
            ScottishBand(upToTaxable: 1_492_100, rateBP: 2_000, name: "Basic"),
            ScottishBand(upToTaxable: 3_109_200, rateBP: 2_100, name: "Intermediate"),
            ScottishBand(upToTaxable: 6_243_000, rateBP: 4_200, name: "Higher"),
            ScottishBand(upToTaxable: 12_514_000, rateBP: 4_500, name: "Advanced"),
            ScottishBand(upToTaxable: nil, rateBP: 4_800, name: "Top")
        ],
        niPrimaryThreshold: 1_257_000, niUpperEarningsLimit: 5_027_000, niMainRateBP: 800, niUpperRateBP: 200,
        studentLoanPlan1Threshold: 2_606_500, studentLoanPlan2Threshold: 2_847_000,
        studentLoanPlan4Threshold: 3_274_500, studentLoanPlan5Threshold: 2_500_000, studentLoanRateBP: 900,
        postgraduateLoanThreshold: 2_100_000, postgraduateLoanRateBP: 600,
        reliefAtSourceRateBP: 2_000,
        sources: [
            .init(covers: "Personal allowance, taper, England/Wales/NI bands and rates", url: incomeTaxRates),
            .init(covers: "Scottish bands and rates", url: scottishIncomeTax),
            .init(covers: "Class 1 employee NI thresholds and rates", url: employers2025),
            .init(covers: "Student and postgraduate loan thresholds and rates", url: studentLoanThresholds,
                  note: "Also listed on the employers' rates and thresholds page"),
            .init(covers: "Relief at source at the 20% basic rate", url: pensionTaxRelief)
        ],
        checkedFields: ["scottishBands", "studentLoanPlan4Threshold", "studentLoanPlan5Threshold"]
    )

    /// 2026/27. Income tax and NI thresholds are frozen, so they repeat 2025/26; the whole year is
    /// marked to check.
    public static let y2026 = SalaryRules(
        startYear: 2026,
        personalAllowance: 1_257_000, taperThreshold: 10_000_000, taperRateNumerator: 1, taperRateDenominator: 2,
        basicRateBand: 3_770_000, additionalThreshold: 12_514_000,
        basicRateBP: 2_000, higherRateBP: 4_000, additionalRateBP: 4_500,
        // Scottish Budget 2026-27: starter to £16,537, basic to £29,526, the rest frozen
        // (intermediate to £43,662, higher to £75,000, advanced to £125,140).
        scottishBands: [
            ScottishBand(upToTaxable: 396_700, rateBP: 1_900, name: "Starter"),
            ScottishBand(upToTaxable: 1_695_600, rateBP: 2_000, name: "Basic"),
            ScottishBand(upToTaxable: 3_109_200, rateBP: 2_100, name: "Intermediate"),
            ScottishBand(upToTaxable: 6_243_000, rateBP: 4_200, name: "Higher"),
            ScottishBand(upToTaxable: 12_514_000, rateBP: 4_500, name: "Advanced"),
            ScottishBand(upToTaxable: nil, rateBP: 4_800, name: "Top")
        ],
        niPrimaryThreshold: 1_257_000, niUpperEarningsLimit: 5_027_000, niMainRateBP: 800, niUpperRateBP: 200,
        studentLoanPlan1Threshold: 2_690_000, studentLoanPlan2Threshold: 2_938_500,
        studentLoanPlan4Threshold: 3_379_500, studentLoanPlan5Threshold: 2_500_000, studentLoanRateBP: 900,
        postgraduateLoanThreshold: 2_100_000, postgraduateLoanRateBP: 600,
        reliefAtSourceRateBP: 2_000,
        sources: [
            .init(covers: "Personal allowance, taper, England/Wales/NI bands and rates", url: incomeTaxRates,
                  note: "Thresholds frozen; assumed equal to 2025/26"),
            .init(covers: "Scottish bands and rates", url: scottishIncomeTax),
            .init(covers: "Class 1 employee NI thresholds and rates", url: employers2026,
                  note: "Assumed unchanged from 2025/26"),
            .init(covers: "Student and postgraduate loan thresholds and rates", url: studentLoanThresholds),
            .init(covers: "Relief at source at the 20% basic rate", url: pensionTaxRelief)
        ],
        checkedFields: allValueFields
    )
}
