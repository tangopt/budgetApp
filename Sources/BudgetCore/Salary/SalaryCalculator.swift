import Foundation

/// Works out a year's UK take-home pay from a salary: income tax (with the £100,000 taper and the
/// person's tax code), employee NI, student and postgraduate loans and the employee pension.
/// Pure: no database, no clock. Each figure is kept exact (pence × basis points) and rounded to
/// the penny, half up, only at the end. An estimate, not payroll: no per-period rounding.
///
/// A bonus paid once a year doesn't change the year's figures, which stay worked out on the whole year; it changes
/// the months. Those come from `payslips`: a normal month (salary only) and the month the bonus is paid in.
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
        let charges = payrollCharges(cashPay: cashPay, rules: rules, inputs: inputs)
        let employeeNI = roundHalfUp(charges.ni, 10_000)
        let studentLoan = roundHalfUp(charges.studentLoan, 10_000)
        let postgraduateLoan = roundHalfUp(charges.postgraduateLoan, 10_000)

        let employeePension = sacrifice + netPayPension + reliefAtSourcePaid
        let employerPension = inputs.employerPension.annual(on: pay)

        var takeHome = pay - employeePension - incomeTaxTotal - employeeNI - studentLoan - postgraduateLoan
        if takeHome < 0 {
            notices.append("Deductions are more than pay; take-home shown as £0")
            takeHome = 0
        }
        let deductions = incomeTaxTotal + employeeNI + studentLoan + postgraduateLoan
        let effectiveRate = pay > 0 ? roundHalfUp(deductions * 10_000, pay) : 0

        // The months: with a yearly bonus, the payslips; otherwise a twelfth of the year.
        var takeHomeMonthly = roundHalfUp(takeHome, 12)
        var normalMonth: SalaryPayslip?
        var bonusMonth: SalaryPayslip?
        var payslipsTakeHome: Int?
        if let month = inputs.bonusPayment.month, inputs.bonusPay > 0 {
            let index = taxYearMonth(month)
            let slips = payslips(inputs, rules: rules, code: code, allowance: tax.allowance, bonusIn: index)
            var salaryOnly = inputs
            salaryOnly.bonusAnnual = 0
            salaryOnly.bonusPercentBP = nil
            let normal = payslips(salaryOnly, rules: rules, code: code, allowance: tax.allowance, bonusIn: nil)[0]
            normalMonth = normal
            bonusMonth = slips[index - 1]
            takeHomeMonthly = normal.takeHome
            let total = slips.reduce(0) { $0 + $1.takeHome }
            payslipsTakeHome = total
            // Paid before March, PAYE over-collects in the bonus month and evens out over the months after.
            let after = slips[index...].reduce(0) { $0 + $1.takeHome - normal.takeHome }
            if abs(after) >= 100 {
                notices.append(after > 0 ? "PAYE refunds \(Money.format(after, currency: .gbp)) after the bonus month"
                                         : "PAYE takes \(Money.format(-after, currency: .gbp)) more after the bonus month")
            }
            if abs(total - takeHome) >= 100 {
                notices.append("NI is monthly: payslips total \(Money.format(total, currency: .gbp))")
            }
        }

        return SalaryResult(
            inputs: inputs, notices: notices, effectiveTaxYear: rules.startYear,
            personalAllowance: tax.allowance, incomeTaxByBand: tax.bands,
            incomeTax: incomeTaxTotal, employeeNI: employeeNI, studentLoan: studentLoan,
            postgraduateLoan: postgraduateLoan, employeePension: employeePension,
            employerPension: employerPension, benefitsInKindTax: benefitsInKindTax,
            takeHomeAnnual: takeHome, takeHomeMonthly: takeHomeMonthly, normalMonth: normalMonth, bonusMonth: bonusMonth,
            payslipsTakeHome: payslipsTakeHome, effectiveRateBP: effectiveRate, marginalRateBP: 0)
    }

    /// NI, student loan and postgraduate loan on `cashPay` against the yearly thresholds, each in pence × basis
    /// points. A month's charges are these on 12 × the month's pay, divided by 12 (`payslips`).
    private static func payrollCharges(cashPay: Int, rules: SalaryRules, inputs: SalaryInputs)
        -> (ni: Int, studentLoan: Int, postgraduateLoan: Int) {
        let niMain = max(0, min(cashPay, rules.niUpperEarningsLimit) - rules.niPrimaryThreshold) * rules.niMainRateBP
        let niUpper = max(0, cashPay - rules.niUpperEarningsLimit) * rules.niUpperRateBP
        let studentLoan = inputs.studentLoan.map { max(0, cashPay - rules.studentLoanThreshold($0)) * rules.studentLoanRateBP } ?? 0
        let postgraduateLoan = inputs.postgraduateLoan
            ? max(0, cashPay - rules.postgraduateLoanThreshold) * rules.postgraduateLoanRateBP : 0
        return (niMain + niUpper, studentLoan, postgraduateLoan)
    }

    // MARK: - Payslips

    /// The month of the tax year (April = 1 … March = 12) a calendar month (January = 1) falls in.
    static func taxYearMonth(_ calendarMonth: Int) -> Int { (calendarMonth + 8) % 12 + 1 }

    /// The tax year's 12 payslips, April first, with the bonus (if `bonusIn`, a tax-year month) in that one month.
    ///
    /// The PAYE basis, for a cumulative (not week 1/month 1) code:
    /// - Income tax is cumulative. Month k's is the tax on pay to date against k/12 of the allowance and of every band,
    ///   less the tax already taken; so the bonus month pays the higher rate on whatever of the bonus passes k/12 of the
    ///   basic band. Over the year it adds up to the yearly income tax. A bonus before March is over-taxed in its month
    ///   and given back over the months after, as the bands catch up. The allowance is the year's (`allowance`: the
    ///   code's, tapered above £100,000 as HMRC would code it), not tapered again month by month.
    /// - NI, student loan and postgraduate loan are per pay period: each month against a twelfth of the yearly
    ///   thresholds, nothing carried over. A bonus month above the NI upper limit pays 2% on the rest; months below a
    ///   loan threshold pay nothing. So the 12 payslips differ from the yearly figures, which use the whole year.
    /// - Pension: a percentage comes off each month's pay, the bonus included (as the yearly figure takes it off salary
    ///   plus bonus); a fixed yearly amount comes off a twelfth a month. Each method as in `compute`.
    /// - Benefits in kind are taxed through payroll, a twelfth a month.
    ///
    /// Worked in twelfths: a month's pay × 12 against the yearly thresholds (× k for cumulative tax), divided by 12
    /// at the end, so nothing is rounded before the penny.
    static func payslips(_ inputs: SalaryInputs, rules: SalaryRules, code: TaxCode, allowance: Int, bonusIn: Int?) -> [SalaryPayslip] {
        let salary = max(0, inputs.grossAnnual), bonus = inputs.bonusPay
        let benefits = max(0, inputs.benefitsInKindAnnual)
        var cumulativeCash = 0, cumulativeNetPay = 0, cumulativeReliefAtSource = 0
        var taxTaken = 0
        var slips: [SalaryPayslip] = []
        for month in 1...12 {
            // All × 12.
            let pay = salary + (month == bonusIn ? bonus * 12 : 0)
            let contribution: Int
            switch inputs.pension {
            case .percentOfGross(let bp): contribution = min(pay, max(0, roundHalfUp(pay * bp, 10_000)))
            case .fixedAnnual(let pence): contribution = min(pay, max(0, pence))
            }
            let sacrifice = inputs.pensionMethod == .salarySacrifice ? contribution : 0
            let netPayPension = inputs.pensionMethod == .netPay ? contribution : 0
            let reliefAtSourceGross = inputs.pensionMethod == .reliefAtSource ? contribution : 0
            let reliefAtSourcePaid = roundHalfUp(reliefAtSourceGross * (10_000 - rules.reliefAtSourceRateBP), 10_000)
            let cashPay = pay - sacrifice
            cumulativeCash += cashPay
            cumulativeNetPay += netPayPension
            cumulativeReliefAtSource += reliefAtSourceGross

            let tax = incomeTax(rules: rules, region: inputs.region, code: code, cashPay: cumulativeCash,
                                benefits: benefits * month, netPayPension: cumulativeNetPay,
                                reliefAtSourceGross: cumulativeReliefAtSource, scale: month, allowance: allowance)
            let taxToDate = roundHalfUp(tax.numerator, 120_000)
            let incomeTax = taxToDate - taxTaken
            taxTaken = taxToDate

            let charges = payrollCharges(cashPay: cashPay, rules: rules, inputs: inputs)
            let slip = SalaryPayslip(pay: roundHalfUp(pay, 12), incomeTax: incomeTax,
                                     employeeNI: roundHalfUp(charges.ni, 120_000),
                                     studentLoan: roundHalfUp(charges.studentLoan, 120_000),
                                     postgraduateLoan: roundHalfUp(charges.postgraduateLoan, 120_000),
                                     employeePension: roundHalfUp(sacrifice + netPayPension + reliefAtSourcePaid, 12), takeHome: 0)
            var withTakeHome = slip
            withTakeHome.takeHome = max(0, slip.pay - slip.employeePension - slip.incomeTax - slip.employeeNI
                                            - slip.studentLoan - slip.postgraduateLoan)
            slips.append(withTakeHome)
        }
        return slips
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

    /// Income tax on a year's pay; or, with `scale` k and `allowance`, on pay given × 12 against k × the yearly
    /// allowance and bands (`payslips`' tax to date in month k, × 12), with `allowance` as the allowance, not tapered.
    private static func incomeTax(rules: SalaryRules, region: SalaryRegion, code: TaxCode, cashPay: Int, benefits: Int,
                                  netPayPension: Int, reliefAtSourceGross: Int,
                                  scale: Int = 1, allowance fixedAllowance: Int? = nil) -> TaxWorking {
        let taxablePay = max(0, cashPay + benefits - netPayPension)
        let adjustedNetIncome = max(0, taxablePay - reliefAtSourceGross)
        let bands = self.bands(rules: rules, region: region, extendedBy: reliefAtSourceGross, scale: scale)

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
            var (numerator, amounts) = banded(taxablePay + addition * scale, bands)
            // The overriding limit: K-code tax can't take more than half of pay.
            let limit = taxablePay * 5_000
            let capped = numerator > limit
            if capped { numerator = limit }
            return TaxWorking(numerator: numerator, bands: amounts, allowance: 0, capped: capped)
        case .standard(let codeAllowance):
            if let fixedAllowance {
                let (numerator, amounts) = banded(max(0, taxablePay - fixedAllowance * scale), bands)
                return TaxWorking(numerator: numerator, bands: amounts, allowance: fixedAllowance, capped: false)
            }
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
    /// Limits are × `scale` (the band extension is given already scaled).
    private static func bands(rules: SalaryRules, region: SalaryRegion, extendedBy extra: Int, scale: Int = 1) -> [Band] {
        switch region {
        case .englandWalesNI:
            return [
                Band(name: "Basic", rateBP: rules.basicRateBP, upTo: rules.basicRateBand * scale + extra),
                Band(name: "Higher", rateBP: rules.higherRateBP, upTo: rules.additionalThreshold * scale + extra),
                Band(name: "Additional", rateBP: rules.additionalRateBP, upTo: nil)
            ]
        case .scotland:
            return rules.scottishBands.enumerated().map { index, band in
                Band(name: band.name, rateBP: band.rateBP, upTo: band.upToTaxable.map { index == 0 ? $0 * scale : $0 * scale + extra })
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
