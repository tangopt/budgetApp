import Foundation

/// Works out a year's UK take-home pay from a salary: income tax (with the £100,000 taper and the
/// person's tax code), employee NI, student and postgraduate loans and the employee pension.
/// Pure: no database, no clock. Each figure is kept exact (pence × basis points) and rounded to
/// the penny, half up, only at the end. An estimate, not payroll: no per-period rounding.
public enum SalaryCalculator {
    public static func calculate(_ inputs: SalaryInputs) -> SalaryResult {
        var result = compute(inputs)
        // Marginal rate: how much of an extra £100 gross doesn't reach take-home.
        var more = inputs
        more.grossAnnual = max(0, inputs.grossAnnual) + 10_000
        let gained = compute(more).takeHomeAnnual - result.takeHomeAnnual
        result.marginalRateBP = 10_000 - gained
        return result
    }

    /// `numerator / denominator` rounded to the nearest whole number, halves away from zero.
    static func roundHalfUp(_ numerator: Int, _ denominator: Int) -> Int {
        if numerator < 0 { return -roundHalfUp(-numerator, denominator) }
        return (numerator * 2 + denominator) / (denominator * 2)
    }

    // MARK: -

    private static func compute(_ inputs: SalaryInputs) -> SalaryResult {
        var notices: [String] = []
        let rules: SalaryRules
        if let exact = SalaryRules.forYear(inputs.taxYearStart) {
            rules = exact
        } else {
            let all = SalaryRules.all
            let earliest = all.min { $0.startYear < $1.startYear }!
            rules = inputs.taxYearStart < earliest.startYear ? earliest : SalaryRules.latest
            notices.append("No rules for \(UKTaxYear(startYear: inputs.taxYearStart).label); using \(rules.ukTaxYear.label)")
        }
        let (code, codeNotice) = TaxCode.parse(inputs.taxCode)
        if let codeNotice { notices.append(codeNotice) }

        // Pay and pension
        let pay = max(0, inputs.grossAnnual) + inputs.bonusPay
        let benefits = max(0, inputs.benefitsInKindAnnual)
        let requested = inputs.pension.annual(on: pay)
        let contribution = min(requested, pay)
        if requested > pay { notices.append("Pension capped at gross pay") }
        let sacrifice = inputs.pensionMethod == .salarySacrifice ? contribution : 0
        let netPayPension = inputs.pensionMethod == .netPay ? contribution : 0
        let reliefAtSourceGross = inputs.pensionMethod == .reliefAtSource ? contribution : 0
        let reliefAtSourcePaid = roundHalfUp(reliefAtSourceGross * (10_000 - rules.reliefAtSourceRateBP), 10_000)

        /// Pay that NI and loans are charged on: cash pay after salary sacrifice.
        let cashPay = pay - sacrifice

        // Income tax
        let tax = incomeTax(rules: rules, region: inputs.region, code: code,
                            cashPay: cashPay, benefits: benefits,
                            netPayPension: netPayPension, reliefAtSourceGross: reliefAtSourceGross)
        if tax.capped { notices.append("K code: tax limited to half of pay") }
        if tax.typedCodeInTaperZone { notices.append(typedCodeTaperNotice) }
        let incomeTaxTotal = roundHalfUp(tax.numerator, 10_000)
        var benefitsInKindTax = 0
        if benefits > 0 {
            let without = incomeTax(rules: rules, region: inputs.region, code: code,
                                    cashPay: cashPay, benefits: 0,
                                    netPayPension: netPayPension, reliefAtSourceGross: reliefAtSourceGross)
            benefitsInKindTax = incomeTaxTotal - roundHalfUp(without.numerator, 10_000)
        }

        // NI and loans, on cash pay
        let niMain = max(0, min(cashPay, rules.niUpperEarningsLimit) - rules.niPrimaryThreshold) * rules.niMainRateBP
        let niUpper = max(0, cashPay - rules.niUpperEarningsLimit) * rules.niUpperRateBP
        let employeeNI = roundHalfUp(niMain + niUpper, 10_000)
        let studentLoan = inputs.studentLoan.map {
            roundHalfUp(max(0, cashPay - rules.studentLoanThreshold($0)) * rules.studentLoanRateBP, 10_000)
        } ?? 0
        let postgraduateLoan = inputs.postgraduateLoan
            ? roundHalfUp(max(0, cashPay - rules.postgraduateLoanThreshold) * rules.postgraduateLoanRateBP, 10_000)
            : 0

        let employeePension = sacrifice + netPayPension + reliefAtSourcePaid
        let employerPension = inputs.employerPension.annual(on: pay)

        var takeHome = pay - employeePension - incomeTaxTotal - employeeNI - studentLoan - postgraduateLoan
        if takeHome < 0 {
            notices.append("Deductions are more than pay; take-home shown as £0")
            takeHome = 0
        }
        let deductions = incomeTaxTotal + employeeNI + studentLoan + postgraduateLoan
        let effectiveRate = pay > 0 ? roundHalfUp(deductions * 10_000, pay) : 0

        return SalaryResult(
            inputs: inputs, notices: notices, effectiveTaxYear: rules.startYear,
            personalAllowance: tax.allowance, incomeTaxByBand: tax.bands,
            incomeTax: incomeTaxTotal, employeeNI: employeeNI, studentLoan: studentLoan,
            postgraduateLoan: postgraduateLoan, employeePension: employeePension,
            employerPension: employerPension, benefitsInKindTax: benefitsInKindTax,
            takeHomeAnnual: takeHome, takeHomeMonthly: roundHalfUp(takeHome, 12),
            takeHomeWeekly: roundHalfUp(takeHome, 52), effectiveRateBP: effectiveRate, marginalRateBP: 0)
    }

    /// Said when a typed code meets income above the taper threshold (the code may already be lowered).
    public static let typedCodeTaperNotice = "Your code is used as given; above £100,000 HMRC usually lowers it already"

    private struct TaxWorking {
        /// Tax in pence × basis points (divide by 10 000 for pence).
        var numerator: Int
        var bands: [BandAmount]
        var allowance: Int
        var capped: Bool
        /// A typed (non-default) allowance code with adjusted net income above the taper threshold.
        var typedCodeInTaperZone = false
    }

    private struct Band {
        var name: String
        var rateBP: Int
        /// Top of the band in taxable income; nil for the top band.
        var upTo: Int?
    }

    private static func incomeTax(rules: SalaryRules, region: SalaryRegion, code: TaxCode, cashPay: Int, benefits: Int,
                                  netPayPension: Int, reliefAtSourceGross: Int) -> TaxWorking {
        let taxablePay = max(0, cashPay + benefits - netPayPension)
        let adjustedNetIncome = max(0, taxablePay - reliefAtSourceGross)
        let bands = self.bands(rules: rules, region: region, extendedBy: reliefAtSourceGross)

        func flat(_ name: String, _ rate: Int) -> TaxWorking {
            let numerator = taxablePay * rate
            return TaxWorking(numerator: numerator,
                              bands: [BandAmount(name: name, rateBP: rate, taxable: taxablePay, tax: roundHalfUp(numerator, 10_000))],
                              allowance: 0, capped: false)
        }
        func rate(named name: String) -> Int { bands.first { $0.name == name }!.rateBP }

        // BR, D0 and D1 are flat second-job codes: relief-at-source band extension doesn't change them.
        switch code.kind {
        case .nt:
            return TaxWorking(numerator: 0, bands: [], allowance: 0, capped: false)
        case .br:
            return flat("Basic", rate(named: "Basic"))
        case .d0:
            return region == .scotland ? flat("Intermediate", rate(named: "Intermediate")) : flat("Higher", rate(named: "Higher"))
        case .d1:
            return region == .scotland ? flat("Higher", rate(named: "Higher")) : flat("Additional", rate(named: "Additional"))
        case .zeroT:
            let (numerator, amounts) = banded(taxablePay, bands)
            return TaxWorking(numerator: numerator, bands: amounts, allowance: 0, capped: false)
        case .k(let addition):
            var (numerator, amounts) = banded(taxablePay + addition, bands)
            // The overriding limit: K-code tax can't take more than half of pay.
            let limit = taxablePay * 5_000
            let capped = numerator > limit
            if capped { numerator = limit }
            return TaxWorking(numerator: numerator, bands: amounts, allowance: 0, capped: capped)
        case .standard(let codeAllowance):
            let excessPounds = max(0, adjustedNetIncome - rules.taperThreshold) / 100
            let reduction = excessPounds * rules.taperRateNumerator / rules.taperRateDenominator * 100
            let taperedAllowance = max(0, rules.personalAllowance - reduction)
            // A typed code from HMRC already carries the taper (and any other adjustment): never taper it twice,
            // but never give more than the tapered table allowance either (an offer that rises past £100,000).
            let allowance = code.isDefault ? taperedAllowance : min(codeAllowance, taperedAllowance)
            let (numerator, amounts) = banded(max(0, taxablePay - allowance), bands)
            return TaxWorking(numerator: numerator, bands: amounts, allowance: allowance, capped: false,
                              typedCodeInTaperZone: !code.isDefault && reduction > 0)
        }
    }

    /// The bands of the region, as taxable income. Relief-at-source contributions push every
    /// limit above the starter (Scotland) or basic (rest of the UK) rate up by the gross amount.
    private static func bands(rules: SalaryRules, region: SalaryRegion, extendedBy extra: Int) -> [Band] {
        switch region {
        case .englandWalesNI:
            return [
                Band(name: "Basic", rateBP: rules.basicRateBP, upTo: rules.basicRateBand + extra),
                Band(name: "Higher", rateBP: rules.higherRateBP, upTo: rules.additionalThreshold + extra),
                Band(name: "Additional", rateBP: rules.additionalRateBP, upTo: nil)
            ]
        case .scotland:
            return rules.scottishBands.enumerated().map { index, band in
                Band(name: band.name, rateBP: band.rateBP, upTo: band.upToTaxable.map { index == 0 ? $0 : $0 + extra })
            }
        }
    }

    private static func banded(_ taxable: Int, _ bands: [Band]) -> (numerator: Int, amounts: [BandAmount]) {
        var numerator = 0
        var amounts: [BandAmount] = []
        var floor = 0
        for band in bands where taxable > floor {
            let top = band.upTo.map { min(taxable, $0) } ?? taxable
            let slice = top - floor
            guard slice > 0 else { floor = band.upTo ?? floor; continue }
            numerator += slice * band.rateBP
            amounts.append(BandAmount(name: band.name, rateBP: band.rateBP, taxable: slice,
                                      tax: roundHalfUp(slice * band.rateBP, 10_000)))
            floor = top
        }
        return (numerator, amounts)
    }
}
