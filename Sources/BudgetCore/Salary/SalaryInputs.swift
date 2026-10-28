import Foundation

/// Where the person pays income tax: Scotland has its own bands; NI and student loans don't differ.
public enum SalaryRegion: String, Codable, Equatable, Sendable, CaseIterable {
    case englandWalesNI
    case scotland
}

/// How an employee pension contribution is taken.
public enum PensionMethod: String, Codable, Equatable, Sendable, CaseIterable {
    /// Taken off gross pay before tax and NI.
    case salarySacrifice
    /// Taken off pay before tax, after NI.
    case netPay
    /// Paid from take-home at 80%; the provider claims the basic-rate 20%, and the basic band is extended.
    case reliefAtSource
}

/// A pension contribution: a share of gross pay (salary + bonus), or a fixed yearly amount.
public enum PensionAmount: Codable, Equatable, Sendable {
    case percentOfGross(basisPoints: Int)
    case fixedAnnual(pence: Int)

    /// The yearly contribution on `gross` pence, never negative.
    func annual(on gross: Int) -> Int {
        switch self {
        case .percentOfGross(let bp): return max(0, SalaryCalculator.roundHalfUp(gross * bp, 10_000))
        case .fixedAnnual(let pence): return max(0, pence)
        }
    }
}

public enum StudentLoanPlan: String, Codable, Equatable, Sendable, CaseIterable {
    case plan1
    case plan2
    case plan4
    case plan5
}

/// What the person tells the salary simulator. Amounts are pence a year.
public struct SalaryInputs: Codable, Equatable, Sendable {
    public var grossAnnual: Int
    public var bonusAnnual: Int
    /// The calendar year the tax year starts in (2025 = 2025/26).
    public var taxYearStart: Int
    public var region: SalaryRegion
    public var taxCode: String
    public var pension: PensionAmount
    public var pensionMethod: PensionMethod
    public var employerPension: PensionAmount
    public var studentLoan: StudentLoanPlan?
    public var postgraduateLoan: Bool
    public var benefitsInKindAnnual: Int

    public init(grossAnnual: Int, bonusAnnual: Int = 0, taxYearStart: Int, region: SalaryRegion = .englandWalesNI,
                taxCode: String = "1257L", pension: PensionAmount = .percentOfGross(basisPoints: 0),
                pensionMethod: PensionMethod = .netPay, employerPension: PensionAmount = .percentOfGross(basisPoints: 0),
                studentLoan: StudentLoanPlan? = nil, postgraduateLoan: Bool = false, benefitsInKindAnnual: Int = 0) {
        self.grossAnnual = grossAnnual
        self.bonusAnnual = bonusAnnual
        self.taxYearStart = taxYearStart
        self.region = region
        self.taxCode = taxCode
        self.pension = pension
        self.pensionMethod = pensionMethod
        self.employerPension = employerPension
        self.studentLoan = studentLoan
        self.postgraduateLoan = postgraduateLoan
        self.benefitsInKindAnnual = benefitsInKindAnnual
    }
}

/// The income tax in one band.
public struct BandAmount: Codable, Equatable, Sendable {
    public var name: String
    public var rateBP: Int
    /// Taxable income falling in this band (pence).
    public var taxable: Int
    public var tax: Int

    public init(name: String, rateBP: Int, taxable: Int, tax: Int) {
        self.name = name
        self.rateBP = rateBP
        self.taxable = taxable
        self.tax = tax
    }
}

/// The yearly result of one salary. All amounts pence; rates basis points.
public struct SalaryResult: Codable, Equatable, Sendable {
    public var inputs: SalaryInputs
    /// Plain-English notes: fallback tax code or year, capped pension…
    public var notices: [String]
    /// The tax year whose rules were used (differs from `inputs.taxYearStart` when that year has no table).
    public var effectiveTaxYear: Int
    /// The allowance actually given (after the £100,000 taper); 0 for K, BR, D0, D1, NT and 0T codes.
    public var personalAllowance: Int
    public var incomeTaxByBand: [BandAmount]
    public var incomeTax: Int
    public var employeeNI: Int
    public var studentLoan: Int
    public var postgraduateLoan: Int
    /// What leaves the employee's pay for the pension (80% of the gross contribution for relief at source).
    public var employeePension: Int
    public var employerPension: Int
    /// The part of `incomeTax` caused by benefits in kind (already included in it).
    public var benefitsInKindTax: Int
    public var takeHomeAnnual: Int
    public var takeHomeMonthly: Int
    public var takeHomeWeekly: Int
    /// Income tax, NI and loans as a share of gross pay (salary + bonus); 0 when there is no pay.
    public var effectiveRateBP: Int
    /// How much of an extra £100 gross does not reach take-home, in basis points.
    public var marginalRateBP: Int

    /// Pence kept of each extra £1 gross, in basis points (10 000 = all of it).
    public var keepPerExtraPoundBP: Int { 10_000 - marginalRateBP }

    /// Said under the marginal rate when a percentage pension takes a share of each extra £1 too.
    public static func marginalPensionCaption(_ result: SalaryResult) -> String? {
        guard case .percentOfGross(let bp) = result.inputs.pension, bp > 0 else { return nil }
        return "Includes the pension's share of each extra £1"
    }
}
