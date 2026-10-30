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

/// When the bonus is paid.
public enum BonusPayment: Codable, Equatable, Hashable, Sendable {
    /// In one payslip a year: `month` is the calendar month, 1 (January) to 12.
    case yearly(month: Int)
    /// A twelfth in every payslip.
    case monthly

    /// What saved inputs from before this existed mean, and a new salary's default: once a year in March.
    public static let standard = BonusPayment.yearly(month: 3)

    /// The calendar month of a yearly bonus (clamped to 1–12); nil when it is spread monthly.
    public var month: Int? {
        if case .yearly(let month) = self { return min(12, max(1, month)) }
        return nil
    }

    /// What the "Bonus paid" picker offers: each month, then once a year in each calendar month.
    public static let choices: [BonusPayment] = [.monthly] + (1...12).map { .yearly(month: $0) }

    /// "Each month", or "In March".
    public var label: String {
        guard let month else { return "Each month" }
        return "In " + Self.monthNames[month - 1]
    }

    /// "Mar".
    public static func shortMonth(_ month: Int) -> String { String(monthNames[min(12, max(1, month)) - 1].prefix(3)) }

    private static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August",
                                     "September", "October", "November", "December"]
}

/// What the person tells the salary simulator. Amounts are pence a year.
public struct SalaryInputs: Codable, Equatable, Sendable {
    public var grossAnnual: Int
    public var bonusAnnual: Int
    /// The bonus as a share of `grossAnnual` (basis points), when it is given as a percentage; nil = `bonusAnnual` is
    /// the bonus (what every saved input before this existed means).
    public var bonusPercentBP: Int?
    /// When the bonus is paid; the year's figures are the same either way, the months differ.
    public var bonusPayment: BonusPayment
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
                studentLoan: StudentLoanPlan? = nil, postgraduateLoan: Bool = false, benefitsInKindAnnual: Int = 0,
                bonusPercentBP: Int? = nil, bonusPayment: BonusPayment = .standard) {
        self.bonusPercentBP = bonusPercentBP
        self.bonusPayment = bonusPayment
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

extension SalaryInputs {
    private enum CodingKeys: String, CodingKey {
        case grossAnnual, bonusAnnual, bonusPercentBP, bonusPayment, taxYearStart, region, taxCode, pension, pensionMethod,
             employerPension, studentLoan, postgraduateLoan, benefitsInKindAnnual
    }

    /// Inputs saved before `bonusPayment` existed decode as a bonus paid once a year in March.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(grossAnnual: try c.decode(Int.self, forKey: .grossAnnual),
                  bonusAnnual: try c.decode(Int.self, forKey: .bonusAnnual),
                  taxYearStart: try c.decode(Int.self, forKey: .taxYearStart),
                  region: try c.decode(SalaryRegion.self, forKey: .region),
                  taxCode: try c.decode(String.self, forKey: .taxCode),
                  pension: try c.decode(PensionAmount.self, forKey: .pension),
                  pensionMethod: try c.decode(PensionMethod.self, forKey: .pensionMethod),
                  employerPension: try c.decode(PensionAmount.self, forKey: .employerPension),
                  studentLoan: try c.decodeIfPresent(StudentLoanPlan.self, forKey: .studentLoan),
                  postgraduateLoan: try c.decode(Bool.self, forKey: .postgraduateLoan),
                  benefitsInKindAnnual: try c.decode(Int.self, forKey: .benefitsInKindAnnual),
                  bonusPercentBP: try c.decodeIfPresent(Int.self, forKey: .bonusPercentBP),
                  bonusPayment: try c.decodeIfPresent(BonusPayment.self, forKey: .bonusPayment) ?? .standard)
    }

    /// The bonus the calculation uses (pence a year, never negative): the percentage of salary when one is set, else
    /// `bonusAnnual`.
    public var bonusPay: Int {
        if let bonusPercentBP { return max(0, SalaryCalculator.roundHalfUp(max(0, grossAnnual) * max(0, bonusPercentBP), 10_000)) }
        return max(0, bonusAnnual)
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

/// One month's pay and what comes off it, on the PAYE basis. Amounts pence.
public struct SalaryPayslip: Codable, Equatable, Sendable {
    /// Salary (and bonus) paid in the month, before any deduction.
    public var pay: Int
    public var incomeTax: Int
    public var employeeNI: Int
    public var studentLoan: Int
    public var postgraduateLoan: Int
    /// What leaves pay for the pension (80% of the gross contribution for relief at source).
    public var employeePension: Int
    public var takeHome: Int

    public init(pay: Int, incomeTax: Int, employeeNI: Int, studentLoan: Int, postgraduateLoan: Int, employeePension: Int, takeHome: Int) {
        self.pay = pay
        self.incomeTax = incomeTax
        self.employeeNI = employeeNI
        self.studentLoan = studentLoan
        self.postgraduateLoan = postgraduateLoan
        self.employeePension = employeePension
        self.takeHome = takeHome
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
    /// A month without the bonus. With a yearly bonus it's the salary-only payslip (`normalMonth`'s take-home); with
    /// the bonus spread monthly, or none, a twelfth of `takeHomeAnnual`.
    public var takeHomeMonthly: Int
    /// With a yearly bonus: a payslip without it (the months before the bonus month). nil otherwise.
    public var normalMonth: SalaryPayslip?
    /// With a yearly bonus: the payslip of the month it is paid in, salary plus bonus on the PAYE basis. nil otherwise.
    public var bonusMonth: SalaryPayslip?
    /// With a yearly bonus: the take-home of the tax year's 12 payslips added up. It differs from `takeHomeAnnual`
    /// because payroll works NI and loans out month by month (`SalaryCalculator.payslips`). nil otherwise.
    public var payslipsTakeHome: Int?
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
