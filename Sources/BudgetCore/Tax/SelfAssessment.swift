import GRDB
import Foundation

/// A person's Self Assessment for a UK tax year (spec 2026-10-16 §4; plan phase 4 Task 3):
/// the SA102 (employment), SA106 (land and property abroad, with Foreign Tax Credit Relief)
/// and SA100 box values, and the SA110 calculation — income tax by band, the residential
/// finance cost reduction, FTCR per source limited to the UK tax on that income, tax deducted,
/// the balancing payment and the payments on account for the next year — every step explained.
///
/// `calculate` is pure (inputs in GBP pence, rules for the year); `compute` gathers the inputs
/// from the records (employments, rental accounts, other income, pensions, HMRC payments) and
/// works out the amounts brought forward from the years before.
public enum SelfAssessment {
    // MARK: Inputs

    public struct EmploymentInput: Equatable, Sendable {
        public var employmentId: Int64?
        public var employerName: String
        public var payeReference: String?
        /// SA102 box 1, pence.
        public var pay: Int
        /// SA102 box 2 (negative for a refund), pence.
        public var taxDeducted: Int
        /// SA102 boxes 9–16, pence by box.
        public var benefitsByBox: [Int: Int]

        public init(employmentId: Int64? = nil, employerName: String, payeReference: String? = nil, pay: Int, taxDeducted: Int,
                    benefitsByBox: [Int: Int] = [:]) {
            self.employmentId = employmentId
            self.employerName = employerName
            self.payeReference = payeReference
            self.pay = pay
            self.taxDeducted = taxDeducted
            self.benefitsByBox = benefitsByBox
        }

        public var benefits: Int { benefitsByBox.values.reduce(0, +) }
        public var total: Int { pay + benefits }
    }

    /// One overseas let property, the person's share, in GBP pence.
    public struct PropertyInput: Equatable, Sendable {
        public var propertyId: Int64?
        public var name: String
        /// ISO 3166-1 alpha-2 ("PT").
        public var country: String
        public var income: Int
        /// Allowable expenses (finance costs excluded).
        public var expenses: Int
        public var financeCosts: Int
        /// Foreign tax paid on the income (the FTCR claim).
        public var foreignTax: Int
        /// Income and expenses on the accruals ("traditional accounting") basis rather than the
        /// cash basis: SA106 box 14.2. The rental accounts attribute rent by rent period and
        /// costs by the periods they cover, so they're traditional.
        public var usesTraditionalAccounting: Bool

        public init(propertyId: Int64? = nil, name: String, country: String, income: Int, expenses: Int, financeCosts: Int, foreignTax: Int,
                    usesTraditionalAccounting: Bool = false) {
            self.propertyId = propertyId
            self.name = name
            self.country = country
            self.income = income
            self.expenses = expenses
            self.financeCosts = financeCosts
            self.foreignTax = foreignTax
            self.usesTraditionalAccounting = usesTraditionalAccounting
        }

        /// SA106 box 18 / 24: income less expenses (no allowances or adjustments yet).
        public var profit: Int { income - expenses }
    }

    public struct Inputs: Equatable, Sendable {
        public var startYear: Int
        public var employments: [EmploymentInput]
        public var properties: [PropertyInput]
        /// Other income taxed like pay (SA100 "other taxable income").
        public var otherNonSavingsIncome: Int
        /// UK and foreign interest, gross.
        public var savingsIncome: Int
        /// UK and foreign dividends.
        public var dividendIncome: Int
        /// UK tax taken off interest.
        public var savingsTaxDeducted: Int
        /// Relief-at-source pension contributions, gross (paid + basic-rate relief): extend the
        /// basic and higher rate bands and reduce adjusted net income.
        public var grossPensionContributions: Int
        public var financeCostsBroughtForward: Int
        public var propertyLossBroughtForward: Int
        /// Payments on account already made towards this year.
        public var paymentsOnAccountMade: Int
        /// Work on whole-pound box values as the return does (SA100 notes: income rounded
        /// down; expenses, tax paid, finance costs and losses rounded up), so the calculation
        /// matches HMRC's SA302.
        public var roundToWholePounds: Bool
        /// The return entered the foreign tax paid in pounds and pence: kept as it is when
        /// rounding to whole pounds (`TaxYear.foreignTaxInPence`).
        public var foreignTaxInPence: Bool
        /// Boxes of a filed return taken as filed (`TaxFiledBox`, by field key): the return's
        /// value replaces the computed one, which is kept beside it with the reason.
        public var filedBoxes: [String: FiledBox] = [:]
        /// The earlier year ("2024/25") whose filed return the brought-forward finance costs and
        /// loss come from: its boxes were taken as filed, so its carry-forward is the filed one.
        public var broughtForwardFromFiledReturn: String? = nil

        public init(startYear: Int, employments: [EmploymentInput] = [], properties: [PropertyInput] = [], otherNonSavingsIncome: Int = 0,
                    savingsIncome: Int = 0, dividendIncome: Int = 0, savingsTaxDeducted: Int = 0, grossPensionContributions: Int = 0,
                    financeCostsBroughtForward: Int = 0, propertyLossBroughtForward: Int = 0, paymentsOnAccountMade: Int = 0,
                    roundToWholePounds: Bool = true, foreignTaxInPence: Bool = false) {
            self.startYear = startYear
            self.employments = employments
            self.properties = properties
            self.otherNonSavingsIncome = otherNonSavingsIncome
            self.savingsIncome = savingsIncome
            self.dividendIncome = dividendIncome
            self.savingsTaxDeducted = savingsTaxDeducted
            self.grossPensionContributions = grossPensionContributions
            self.financeCostsBroughtForward = financeCostsBroughtForward
            self.propertyLossBroughtForward = propertyLossBroughtForward
            self.paymentsOnAccountMade = paymentsOnAccountMade
            self.roundToWholePounds = roundToWholePounds
            self.foreignTaxInPence = foreignTaxInPence
        }

        /// Pence rounded down to whole pounds (towards zero for a negative amount).
        static func down(_ pence: Int) -> Int { pence >= 0 ? pence / 100 * 100 : -((-pence) / 100 * 100) }
        /// Pence rounded up to whole pounds (a negative amount's magnitude rounds down).
        static func up(_ pence: Int) -> Int { pence >= 0 ? (pence + 99) / 100 * 100 : down(pence) }

        /// The box values as the return holds them: whole pounds.
        public var wholePounds: Inputs {
            var rounded = self
            rounded.employments = employments.map { employment in
                var e = employment
                e.pay = Self.down(e.pay)
                e.taxDeducted = Self.up(e.taxDeducted)
                e.benefitsByBox = e.benefitsByBox.mapValues(Self.down)
                return e
            }
            rounded.properties = properties.map { property in
                var p = property
                p.income = Self.down(p.income)
                p.expenses = Self.up(p.expenses)
                p.financeCosts = Self.up(p.financeCosts)
                p.foreignTax = foreignTaxInPence ? p.foreignTax : Self.up(p.foreignTax)
                return p
            }
            rounded.otherNonSavingsIncome = Self.down(otherNonSavingsIncome)
            rounded.savingsIncome = Self.down(savingsIncome)
            rounded.dividendIncome = Self.down(dividendIncome)
            rounded.savingsTaxDeducted = Self.up(savingsTaxDeducted)
            // A relief: rounded up, to the taxpayer's benefit.
            rounded.grossPensionContributions = Self.up(grossPensionContributions)
            rounded.financeCostsBroughtForward = Self.up(financeCostsBroughtForward)
            rounded.propertyLossBroughtForward = Self.up(propertyLossBroughtForward)
            return rounded
        }
    }

    // MARK: Outputs

    public enum Form: String, Codable, CaseIterable, Sendable {
        case sa100 = "SA100"
        case sa102 = "SA102"
        case sa106 = "SA106"
        case sa110 = "SA110"
    }

    public enum BoxValue: Equatable, Sendable {
        /// Pence; the return takes whole pounds.
        case amount(Int)
        case text(String)
        /// An "X" box.
        case cross
    }

    /// A figure entered as the return filed it, with why it differs from the computed one.
    public struct FiledBox: Equatable, Sendable {
        public var value: Int
        public var note: String

        public init(value: Int, note: String) {
            self.value = value
            self.note = note
        }
    }

    /// What a box shows when it is taken as filed: the value the app works out and the reason.
    public struct AsFiled: Equatable, Sendable {
        public var computed: Int
        public var note: String

        public init(computed: Int, note: String) {
            self.computed = computed
            self.note = note
        }
    }

    /// One box of the return, grouped like HMRC online ("Employment 1", "Land and property abroad").
    public struct Box: Equatable, Sendable {
        public var form: Form
        public var section: String
        public var number: String
        public var label: String
        public var value: BoxValue
        /// The title of the calculation step the value comes from (drill-down).
        public var step: String? = nil
        /// Set when the value is the return's, not the computed one.
        public var asFiled: AsFiled? = nil
    }

    /// A line of the income tax charge: an amount in a band at a rate.
    public struct BandLine: Equatable, Sendable {
        public enum Kind: String, Sendable { case nonSavings, savings, dividends }
        public var kind: Kind
        public var band: String
        public var amount: Int
        public var rate: Int
        public var tax: Int
    }

    /// Foreign Tax Credit Relief for one source (an overseas property).
    public struct ForeignTaxCredit: Equatable, Sendable {
        public var propertyId: Int64?
        public var name: String
        /// ISO 3166-1 alpha-3 (the SA106 code, "PRT").
        public var countryCode: String
        /// Column B: the adjusted profit.
        public var income: Int
        /// Column C.
        public var foreignTax: Int
        /// UK tax with the income less UK tax without it (after the finance cost reduction).
        public var ukTaxOnIncome: Int
        /// The lower of the two.
        public var credit: Int
        public var explanation: String
    }

    public struct Calculation: Equatable, Sendable {
        public var totalEmploymentIncome: Int
        /// SA106 box 27: property profits after losses brought forward.
        public var propertyProfit: Int
        public var totalIncome: Int
        public var adjustedNetIncome: Int
        public var personalAllowance: Int
        public var taxableIncome: Int
        public var bandLines: [BandLine]
        public var incomeTaxCharged: Int
        public var financeCosts: Int
        /// The lower of finance costs, property profit and adjusted total income above the allowance.
        public var financeCostReliefBase: Int
        public var financeCostReduction: Int
        public var financeCostsCarriedForward: Int
        public var foreignTaxCreditRelief: Int
        public var incomeTaxDue: Int
        public var taxDeducted: Int
        /// SA110 box 1 (box 2 when negative): tax due before payments on account.
        public var selfAssessmentLiability: Int
        public var paymentsOnAccountMade: Int
        /// Due 31 January after the year (negative: repayable).
        public var balancingPayment: Int
        /// Each of the two payments on account for the next year (31 January, 31 July).
        public var nextPaymentOnAccount: Int
        public var propertyLossCarriedForward: Int
    }

    public struct Step: Equatable, Sendable {
        public var title: String
        public var detail: String
        public var amount: Int?
    }

    public struct Result: Equatable, Sendable {
        public var taxYear: UKTaxYear
        public var personId: Int64?
        public var inputs: Inputs
        public var calculation: Calculation
        public var foreignTaxCredits: [ForeignTaxCredit]
        public var boxes: [Box]
        public var steps: [Step]
        public var warnings: [String]

        public func boxes(_ form: Form) -> [Box] { boxes.filter { $0.form == form } }
        public func box(_ form: Form, _ number: String, section: String? = nil) -> Box? {
            boxes.first { $0.form == form && $0.number == number && (section == nil || $0.section == section) }
        }
    }

    public enum ComputeError: Error, Equatable {
        case noRulesForYear(Int)
        case personNotFound
    }

    // MARK: The liability

    /// Income tax for a given mix of income, before tax deducted: by band, then the finance
    /// cost reduction.
    struct Liability {
        var personalAllowance: Int
        var adjustedNetIncome: Int
        var taxable: Int
        var lines: [BandLine]
        var charged: Int
        var financeBase: Int
        var financeReduction: Int
        var due: Int
    }

    static func liability(nonSavings: Int, savings: Int, dividends: Int, propertyProfit: Int, financeCosts: Int, pension: Int,
                          rules: UKTaxRules) -> Liability {
        let total = nonSavings + savings + dividends
        let adjustedNet = max(0, total - pension)
        let allowance = rules.personalAllowance(adjustedNetIncome: adjustedNet)
        var left = allowance
        func use(_ income: Int) -> Int {
            let used = min(left, max(0, income))
            left -= used
            return max(0, income) - used
        }
        let taxableNS = use(nonSavings), taxableSV = use(savings), taxableDV = use(dividends)
        let basicLimit = rules.basicRateBand + pension
        let additionalThreshold = rules.additionalRateThreshold + pension
        let bandOfTotal: UKTaxRules.Band = taxableNS + taxableSV + taxableDV > additionalThreshold ? .additional
            : (taxableNS + taxableSV + taxableDV > basicLimit ? .higher : .basic)

        var lines: [BandLine] = []
        var position = 0
        /// Taxes `amount` from `position` up, across the bands, at `rates`.
        func slice(_ amount: Int, kind: BandLine.Kind, rates: (Int, Int, Int)) {
            var rest = amount
            for (band, top, rate) in [("Basic rate", basicLimit, rates.0), ("Higher rate", additionalThreshold, rates.1),
                                      ("Additional rate", Int.max, rates.2)] where rest > 0 {
                let room = max(0, top - position)
                let part = min(rest, room)
                guard part > 0 else { continue }
                lines.append(BandLine(kind: kind, band: band, amount: part, rate: rate, tax: UKTaxRules.apply(rate, to: part)))
                position += part
                rest -= part
            }
        }
        func zeroRate(_ amount: Int, kind: BandLine.Kind, band: String) {
            guard amount > 0 else { return }
            lines.append(BandLine(kind: kind, band: band, amount: amount, rate: 0, tax: 0))
            position += amount
        }

        slice(taxableNS, kind: .nonSavings, rates: (rules.basicRate, rules.higherRate, rules.additionalRate))
        // Savings: the starting rate band is cut by non-savings income above the allowance;
        // the personal savings allowance depends on the band of the whole taxable income.
        let startingRoom = max(0, rules.startingRateForSavingsLimit - taxableNS)
        let starting = min(taxableSV, startingRoom)
        zeroRate(starting, kind: .savings, band: "Starting rate for savings")
        let psa = min(taxableSV - starting, rules.personalSavingsAllowance(band: bandOfTotal))
        zeroRate(psa, kind: .savings, band: "Personal Savings Allowance")
        slice(taxableSV - starting - psa, kind: .savings, rates: (rules.savingsBasicRate, rules.savingsHigherRate, rules.savingsAdditionalRate))
        let dividendAllowance = min(taxableDV, rules.dividendAllowance)
        zeroRate(dividendAllowance, kind: .dividends, band: "Dividend Allowance")
        slice(taxableDV - dividendAllowance, kind: .dividends, rates: (rules.dividendOrdinaryRate, rules.dividendUpperRate, rules.dividendAdditionalRate))

        let charged = lines.reduce(0) { $0 + $1.tax }
        // Adjusted total income here: non-savings, non-dividend income above the allowance.
        let atiAboveAllowance = max(0, nonSavings - allowance)
        let base = max(0, min(financeCosts, propertyProfit, atiAboveAllowance))
        let reduction = min(UKTaxRules.apply(rules.residentialFinanceCostReliefRate, to: base), charged)
        return Liability(personalAllowance: allowance, adjustedNetIncome: adjustedNet, taxable: taxableNS + taxableSV + taxableDV, lines: lines,
                         charged: charged, financeBase: base, financeReduction: reduction, due: charged - reduction)
    }

    // MARK: Calculating

    public static func calculate(_ given: Inputs, rules: UKTaxRules, personId: Int64? = nil) -> Result {
        // Before 2020/21 part (or all) of the residential finance costs is still an expense; only
        // the rest is restricted to the basic-rate reduction (the 2017/18–2019/20 phasing). Split
        // in pence, before the whole-pound rounding, so the two parts round like any expense and
        // finance cost would.
        var split = given
        var deducted = 0, restricted = 0
        if rules.residentialFinanceCostsDeductibleShare > 0 {
            split.properties = given.properties.map { property in
                var property = property
                let deductible = UKTaxRules.apply(rules.residentialFinanceCostsDeductibleShare, to: property.financeCosts)
                property.expenses += deductible
                property.financeCosts -= deductible
                deducted += deductible
                restricted += property.financeCosts
                return property
            }
        }
        var inputs = given.roundToWholePounds ? split.wholePounds : split
        // Compared before the boxes as filed replace any value: only the rounding counts here.
        let roundedToWholePounds = given.roundToWholePounds && inputs != split
        var steps: [Step] = []
        var warnings: [String] = []
        var boxes: [Box] = []
        func money(_ pence: Int) -> String { Money.format(pence, currency: .gbp) }
        func rate(_ basisPoints: Int) -> String { UKTaxRulesFormat.percent(basisPoints) }

        // Boxes as filed: the return's figure replaces the computed one (kept for the box's note).
        // Pay and tax need one employment, the property boxes one property; the FTCR and the
        // SA302's foreign income are applied where they are worked out below.
        var asFiled: [String: AsFiled] = [:]
        var asFiledLines: [String] = []
        func takeAsFiled(_ key: String, computed: Int, apply: (Int) -> Void) {
            guard let filed = inputs.filedBoxes[key] else { return }
            // Tagged only when the return's figure differs from the computed one (as the FTCR is).
            if filed.value != computed {
                asFiled[key] = AsFiled(computed: computed, note: filed.note)
                asFiledLines.append("\(TaxFiledBoxes.label(key)) \(money(filed.value)) as filed (computed \(money(computed))): \(filed.note)")
            }
            apply(filed.value)
        }
        for key in ["sa102.1", "sa102.2"] where inputs.filedBoxes[key] != nil {
            if inputs.employments.count == 1 {
                takeAsFiled(key, computed: key == "sa102.1" ? inputs.employments[0].pay : inputs.employments[0].taxDeducted) { value in
                    if key == "sa102.1" { inputs.employments[0].pay = value } else { inputs.employments[0].taxDeducted = value }
                }
            } else {
                warnings.append("\(TaxFiledBoxes.label(key)) is stored as filed, but the year has \(inputs.employments.count) employments: left aside.")
            }
        }
        for key in ["sa106.14", "sa106.17", "sa106.24.1", "sa106.28"] where inputs.filedBoxes[key] != nil {
            if inputs.properties.count == 1 {
                let p = inputs.properties[0]
                let computed = key == "sa106.14" ? p.income : key == "sa106.17" ? p.expenses : key == "sa106.24.1" ? p.financeCosts : p.foreignTax
                takeAsFiled(key, computed: computed) { value in
                    switch key {
                    case "sa106.14": inputs.properties[0].income = value
                    case "sa106.17": inputs.properties[0].expenses = value
                    case "sa106.24.1": inputs.properties[0].financeCosts = value
                    default: inputs.properties[0].foreignTax = value
                    }
                }
            } else {
                warnings.append("\(TaxFiledBoxes.label(key)) is stored as filed, but the year has \(inputs.properties.count) properties: left aside.")
            }
        }
        if roundedToWholePounds {
            steps.append(Step(title: "Whole pounds",
                              detail: "The return takes whole pounds: income is rounded down; expenses, tax paid, finance costs and losses are rounded up. The calculation uses those box values, as HMRC's does."
                                + (given.foreignTaxInPence ? " The foreign tax paid stays in pounds and pence, as this year's return entered it." : ""),
                              amount: nil))
        }
        if deducted > 0 {
            let share = rate(rules.residentialFinanceCostsDeductibleShare)
            steps.append(Step(title: "Finance costs",
                              detail: share == "100%"
                                ? "In \(UKTaxYear(startYear: inputs.startYear).label) finance costs are an ordinary expense: \(money(deducted)) is deducted with the other expenses (the restriction starts in 2017/18)."
                                : "In \(UKTaxYear(startYear: inputs.startYear).label) \(share) of the finance costs, \(money(deducted)), is deducted as an expense; the other \(money(restricted)) gets the \(rate(rules.residentialFinanceCostReliefRate)) tax reduction.",
                              amount: deducted))
        }

        // Employment (SA102).
        for (index, employment) in inputs.employments.enumerated() {
            let section = "Employment \(index + 1): \(employment.employerName)"
            boxes.append(Box(form: .sa102, section: section, number: "1", label: "Pay from this employment", value: .amount(employment.pay)))
            boxes.append(Box(form: .sa102, section: section, number: "2", label: "UK tax taken off pay", value: .amount(employment.taxDeducted)))
            if let reference = employment.payeReference {
                boxes.append(Box(form: .sa102, section: section, number: "4", label: "PAYE tax reference of your employer", value: .text(reference)))
            }
            boxes.append(Box(form: .sa102, section: section, number: "5", label: "Your employer's name", value: .text(employment.employerName)))
            for box in employment.benefitsByBox.keys.sorted() where employment.benefitsByBox[box]! != 0 {
                boxes.append(Box(form: .sa102, section: section, number: "\(box)", label: sa102BoxLabels[box] ?? "Benefits",
                                 value: .amount(employment.benefitsByBox[box]!)))
            }
            steps.append(Step(title: employmentStepTitle(index, employment),
                              detail: "Pay \(money(employment.pay)) + benefits \(money(employment.benefits)) = \(money(employment.total)); tax taken off \(money(employment.taxDeducted)).",
                              amount: employment.total))
        }
        let employmentIncome = inputs.employments.reduce(0) { $0 + $1.total }

        // Land and property abroad (SA106).
        let properties = inputs.properties
        let totalRents = properties.reduce(0) { $0 + $1.income }
        let totalExpenses = properties.reduce(0) { $0 + $1.expenses }
        let adjustedProfit = properties.reduce(0) { $0 + $1.profit }
        let financeCosts = properties.reduce(0) { $0 + $1.financeCosts }
        let foreignTax = properties.reduce(0) { $0 + $1.foreignTax }
        func taxableProperty(_ profit: Int) -> (taxable: Int, lossCarriedForward: Int) {
            let afterLoss = profit - inputs.propertyLossBroughtForward
            return afterLoss >= 0 ? (afterLoss, 0) : (0, -afterLoss)
        }
        var (propertyProfit, lossCarriedForward) = taxableProperty(adjustedProfit)
        // The SA106 boxes (27, 30) always show the profit the boxes give.
        let boxedProfit = propertyProfit
        // The SA302's "foreign income" as the return's calculation used it (a pack whose
        // calculation and boxes disagree): the boxes keep their values, the calculation takes this.
        if inputs.filedBoxes["calc.propertyProfit"] != nil {
            takeAsFiled("calc.propertyProfit", computed: propertyProfit) { propertyProfit = $0 }
        }
        let reducedProfits = columnF(properties)
        if !properties.isEmpty {
            let section = "Land and property abroad"
            boxes.append(Box(form: .sa106, section: section, number: "14", label: "Total rents and other receipts", value: .amount(totalRents)))
            if properties.contains(where: \.usesTraditionalAccounting) {
                boxes.append(Box(form: .sa106, section: section, number: "14.2", label: "Traditional accounting rather than cash basis", value: .cross))
            }
            boxes += [
                Box(form: .sa106, section: section, number: "15", label: "Number of overseas let properties", value: .text("\(properties.count)")),
                Box(form: .sa106, section: section, number: "17", label: "Allowable property expenses", value: .amount(totalExpenses)),
                Box(form: .sa106, section: section, number: "18", label: "Net profit or loss", value: .amount(adjustedProfit)),
                Box(form: .sa106, section: section, number: "24", label: "Adjusted profit or loss for the year", value: .amount(adjustedProfit)),
                Box(form: .sa106, section: section, number: "24.1", label: "Residential property finance costs", value: .amount(financeCosts))
            ]
            if inputs.financeCostsBroughtForward > 0 {
                boxes.append(Box(form: .sa106, section: section, number: "24.2", label: "Unused residential property finance costs brought forward",
                                 value: .amount(inputs.financeCostsBroughtForward)))
            }
            for (index, property) in properties.enumerated() {
                let row = "Foreign Tax Credit Relief: \(property.name)"
                boxes += [
                    Box(form: .sa106, section: row, number: "A", label: "Country or territory code", value: .text(countryCode(property.country))),
                    Box(form: .sa106, section: row, number: "B", label: "Adjusted profit or loss", value: .amount(property.profit)),
                    Box(form: .sa106, section: row, number: "C", label: "Foreign tax taken off or paid", value: .amount(property.foreignTax))
                ]
                if property.foreignTax > 0 {
                    boxes.append(Box(form: .sa106, section: row, number: "E", label: "To claim Foreign Tax Credit Relief", value: .cross))
                }
                // Column F: the profit after the year's losses on other properties are set off
                // (`columnF`), the foreign tax being claimed as a credit (never deducted as an
                // expense here); blank for a loss or a profit the losses cover.
                if reducedProfits[index] > 0 {
                    boxes.append(Box(form: .sa106, section: row, number: "F", label: "Taxable amount", value: .amount(reducedProfits[index])))
                }
            }
            boxes.append(Box(form: .sa106, section: section, number: "25", label: "Total of column B", value: .amount(adjustedProfit)))
            if inputs.propertyLossBroughtForward > 0 {
                boxes.append(Box(form: .sa106, section: section, number: "26", label: "Total loss brought forward from earlier years",
                                 value: .amount(inputs.propertyLossBroughtForward)))
            }
            if adjustedProfit >= 0 {
                boxes.append(Box(form: .sa106, section: section, number: "27", label: "Total taxable profits", value: .amount(boxedProfit)))
            }
            boxes.append(Box(form: .sa106, section: section, number: "28", label: "Total foreign tax", value: .amount(foreignTax)))
            let totalF = reducedProfits.reduce(0, +)
            let lossUsed = min(inputs.propertyLossBroughtForward, max(0, adjustedProfit))
            boxes.append(Box(form: .sa106, section: section, number: "30", label: "Total taxable amount", value: .amount(max(0, totalF - lossUsed))))
            if lossCarriedForward > 0 {
                boxes.append(Box(form: .sa106, section: section, number: "32", label: "Total loss to carry forward", value: .amount(lossCarriedForward)))
            }
            steps.append(Step(title: "Land and property abroad",
                              detail: "Rents \(money(totalRents)) − expenses \(money(totalExpenses)) = \(money(adjustedProfit))"
                                + (inputs.propertyLossBroughtForward > 0 ? " − loss brought forward \(money(inputs.propertyLossBroughtForward))" : "")
                                + ": taxable \(money(propertyProfit)). Finance costs \(money(financeCosts)) aren't deducted: they get a \(rate(rules.residentialFinanceCostReliefRate)) tax reduction.",
                              amount: propertyProfit))
        }

        // Income and allowances.
        let nonSavings = employmentIncome + propertyProfit + inputs.otherNonSavingsIncome
        let costsAvailable = financeCosts + inputs.financeCostsBroughtForward
        let full = liability(nonSavings: nonSavings, savings: inputs.savingsIncome, dividends: inputs.dividendIncome, propertyProfit: propertyProfit,
                             financeCosts: costsAvailable, pension: inputs.grossPensionContributions, rules: rules)
        let totalIncome = nonSavings + inputs.savingsIncome + inputs.dividendIncome
        steps.append(Step(title: "Total income", detail: "Employment \(money(employmentIncome)) + property \(money(propertyProfit))"
                            + (inputs.otherNonSavingsIncome != 0 ? " + other \(money(inputs.otherNonSavingsIncome))" : "")
                            + (inputs.savingsIncome != 0 ? " + savings \(money(inputs.savingsIncome))" : "")
                            + (inputs.dividendIncome != 0 ? " + dividends \(money(inputs.dividendIncome))" : "") + " = \(money(totalIncome)).",
                          amount: totalIncome))
        var taperNote = inputs.grossPensionContributions > 0
            ? "Total income \(money(totalIncome)) − gross pension contributions \(money(inputs.grossPensionContributions)) = adjusted net income \(money(full.adjustedNetIncome)). "
            : ""
        if full.adjustedNetIncome > rules.personalAllowanceIncomeLimit {
            taperNote += "Adjusted net income \(money(full.adjustedNetIncome)) is over \(money(rules.personalAllowanceIncomeLimit)): the allowance of \(money(rules.personalAllowance)) goes down £1 for every £2 over, to \(money(full.personalAllowance))."
        } else {
            taperNote += "Adjusted net income \(money(full.adjustedNetIncome)) is within the \(money(rules.personalAllowanceIncomeLimit)) limit: the full allowance."
        }
        steps.append(Step(title: "Personal Allowance", detail: taperNote, amount: full.personalAllowance))
        if inputs.grossPensionContributions > 0 {
            steps.append(Step(title: "Pension contributions",
                              detail: "Relief-at-source contributions of \(money(inputs.grossPensionContributions)) gross extend the basic and higher rate bands.",
                              amount: inputs.grossPensionContributions))
        }
        steps.append(Step(title: "Taxable income", detail: "\(money(totalIncome)) − allowance \(money(full.personalAllowance)) = \(money(full.taxable)).",
                          amount: full.taxable))
        for line in full.lines {
            let what = line.kind == .nonSavings ? "Pay, pensions, property" : (line.kind == .savings ? "Savings" : "Dividends")
            steps.append(Step(title: "\(what): \(line.band)", detail: "\(money(line.amount)) × \(rate(line.rate)) = \(money(line.tax)).", amount: line.tax))
        }
        steps.append(Step(title: "Income Tax charged", detail: "The bands above add up to \(money(full.charged)).", amount: full.charged))

        // Finance cost reduction.
        // The carry-forward (finance costs here, the property loss above) is worked out from the
        // figures the calculation used: on a filed year with boxes taken as filed, the filed
        // return's (finance costs, profit, the SA302's foreign income). HMRC holds those, and
        // they are what the next year's return builds on.
        let carriedForward = max(0, costsAvailable - full.financeBase)
        if let filedYear = inputs.broughtForwardFromFiledReturn,
           inputs.financeCostsBroughtForward > 0 || inputs.propertyLossBroughtForward > 0 {
            var parts: [String] = []
            if inputs.financeCostsBroughtForward > 0 { parts.append("finance costs \(money(inputs.financeCostsBroughtForward))") }
            if inputs.propertyLossBroughtForward > 0 { parts.append("property loss \(money(inputs.propertyLossBroughtForward))") }
            steps.append(Step(title: "Brought forward from the filed return",
                              detail: "The \(parts.joined(separator: " and ")) brought forward come from the \(filedYear) return as filed (its boxes taken as filed), the figures HMRC holds.",
                              amount: nil))
        }
        if costsAvailable > 0 {
            let limit = [("finance costs", costsAvailable), ("property profits", propertyProfit),
                         ("adjusted total income above the allowance", max(0, nonSavings - full.personalAllowance))]
            let lowest = limit.min { $0.1 < $1.1 }!
            var detail = "\(rate(rules.residentialFinanceCostReliefRate)) of the lowest of finance costs \(money(costsAvailable)), property profits \(money(propertyProfit)) and adjusted total income above the allowance \(money(max(0, nonSavings - full.personalAllowance))) — \(lowest.0), \(money(full.financeBase)) — = \(money(full.financeReduction))."
            if carriedForward > 0 { detail += " Unused finance costs \(money(carriedForward)) carry forward to next year." }
            steps.append(Step(title: "Relief for finance costs", detail: detail, amount: full.financeReduction))
        }

        if foreignTax > 0 {
            steps.append(Step(title: "Foreign tax basis",
                              detail: "Foreign tax set against this UK year's rent as the rental accounts attribute it (by default each calendar year's tax time-apportioned to the UK years it straddles, HMRC INTM161220; the Foreign tax line shows the rule and its sources): \(money(foreignTax)).",
                              amount: foreignTax))
        }
        // Foreign Tax Credit Relief, per source: the highest foreign rate is the top slice.
        var credits: [ForeignTaxCredit] = []
        var remaining = properties.enumerated().filter { $0.element.foreignTax > 0 }
            .sorted { lhs, rhs in
                let l = Double(lhs.element.foreignTax) / Double(max(1, lhs.element.profit))
                let r = Double(rhs.element.foreignTax) / Double(max(1, rhs.element.profit))
                return l != r ? l > r : lhs.offset < rhs.offset
            }
        var included = Array(properties.indices)
        func dueWith(_ indices: [Int]) -> Int {
            let subset = indices.map { properties[$0] }
            var profit = taxableProperty(subset.reduce(0) { $0 + $1.profit }).taxable
            // With every property in, the profit the calculation uses (the SA302's, when taken as filed).
            if subset.count == properties.count { profit = propertyProfit }
            let costs = subset.reduce(0) { $0 + $1.financeCosts } + (subset.isEmpty ? 0 : inputs.financeCostsBroughtForward)
            return liability(nonSavings: employmentIncome + profit + inputs.otherNonSavingsIncome, savings: inputs.savingsIncome,
                             dividends: inputs.dividendIncome, propertyProfit: profit, financeCosts: costs,
                             pension: inputs.grossPensionContributions, rules: rules).due
        }
        var ftcrTotal = 0
        while !remaining.isEmpty {
            let (index, property) = remaining.removeFirst()
            let with = dueWith(included)
            included.removeAll { $0 == index }
            let without = dueWith(included)
            let ukTax = max(0, with - without)
            let credit = min(property.foreignTax, ukTax, max(0, full.due - ftcrTotal))
            ftcrTotal += credit
            let capped = credit < property.foreignTax
            let explanation = "UK tax with this income \(money(with)) − without it \(money(without)) = \(money(ukTax)) on \(money(reducedProfits[index])); foreign tax \(money(property.foreignTax)): relief \(money(credit))"
                + (capped ? " (limited to the UK tax on the income)." : ".")
            credits.append(ForeignTaxCredit(propertyId: property.propertyId, name: property.name, countryCode: countryCode(property.country),
                                            income: property.profit, foreignTax: property.foreignTax, ukTaxOnIncome: ukTax, credit: credit,
                                            explanation: explanation))
            steps.append(Step(title: "Foreign Tax Credit Relief: \(property.name)", detail: explanation, amount: credit))
        }

        // The relief as the return claimed it, when it differs from the HS263 limit above: a
        // filed year is reproduced as filed; the step keeps the app's own figure in view.
        if let filed = inputs.filedBoxes["sa106.F1.2"], filed.value != ftcrTotal {
            let taken = min(filed.value, full.due)
            var detail = "The return claimed \(money(filed.value)) of Foreign Tax Credit Relief"
            if taken < filed.value { detail += " (\(money(taken)) of it within the tax due)" }
            detail += "; the HS263 limit — the UK tax on the foreign income — works out as \(money(ftcrTotal)). The claim is taken as filed: \(filed.note)"
            if filed.value > ftcrTotal {
                warnings.append("Foreign Tax Credit Relief is taken as filed, \(money(filed.value)): \(money(filed.value - ftcrTotal)) more than the UK tax on the foreign income allows under HS263.")
            }
            steps.append(Step(title: "Foreign Tax Credit Relief as filed", detail: detail, amount: taken))
            asFiled["sa106.F1.2"] = AsFiled(computed: ftcrTotal, note: filed.note)
            ftcrTotal = taken
        }
        if ftcrTotal > 0 {
            // SA106 page F 1 box 2, in whole pounds (HMRC works out its own relief from the columns).
            boxes.append(Box(form: .sa106, section: "Foreign Tax Credit Relief", number: "2", label: "Total Foreign Tax Credit Relief on your income",
                             value: .amount(Inputs.down(ftcrTotal)), asFiled: asFiled["sa106.F1.2"].map { AsFiled(computed: Inputs.down($0.computed), note: $0.note) }))
        }
        if !asFiledLines.isEmpty {
            steps.append(Step(title: "As filed", detail: asFiledLines.joined(separator: " "), amount: nil))
        }
        let incomeTaxDue = full.due - ftcrTotal
        steps.append(Step(title: "Income Tax due after tax reductions",
                          detail: "\(money(full.charged)) − finance costs \(money(full.financeReduction)) − FTCR \(money(ftcrTotal)) = \(money(incomeTaxDue)).",
                          amount: incomeTaxDue))
        let taxDeducted = inputs.employments.reduce(0) { $0 + $1.taxDeducted } + inputs.savingsTaxDeducted
        let liabilityAfterDeductions = incomeTaxDue - taxDeducted
        steps.append(Step(title: "Tax deducted", detail: "PAYE and other tax taken off \(money(taxDeducted)): \(liabilityAfterDeductions >= 0 ? "owed" : "overpaid") \(money(abs(liabilityAfterDeductions))).",
                          amount: taxDeducted))

        let balancing = liabilityAfterDeductions - inputs.paymentsOnAccountMade
        let nextPOA = rules.paymentOnAccount(selfAssessmentLiability: max(0, liabilityAfterDeductions), totalIncomeTax: incomeTaxDue)
        let deadlines = UKTaxYear(startYear: inputs.startYear).deadlines
        var balanceDetail = "\(money(liabilityAfterDeductions))"
        if inputs.paymentsOnAccountMade != 0 { balanceDetail += " − payments on account made \(money(inputs.paymentsOnAccountMade))" }
        balanceDetail += " = \(money(balancing)) \(balancing >= 0 ? "due" : "to be repaid") by \(day(deadlines.onlineReturnAndBalancingPayment))."
        steps.append(Step(title: "Balancing payment", detail: balanceDetail, amount: balancing))
        let poaDetail: String
        if nextPOA > 0 {
            poaDetail = "Half of \(money(liabilityAfterDeductions)) each: \(money(nextPOA)) by \(day(deadlines.onlineReturnAndBalancingPayment)) and by \(day(deadlines.secondPaymentOnAccount))."
        } else if liabilityAfterDeductions < rules.paymentsOnAccountThreshold {
            poaDetail = "None: the tax owed through Self Assessment is under \(money(rules.paymentsOnAccountThreshold))."
        } else {
            poaDetail = "None: more than \(rate(rules.paymentsOnAccountDeductedAtSourceShare)) of the tax was deducted at source."
        }
        steps.append(Step(title: "Payments on account for \(UKTaxYear(startYear: inputs.startYear + 1).label)", detail: poaDetail, amount: nextPOA))

        // SA110 and SA100.
        if liabilityAfterDeductions >= 0 {
            boxes.append(Box(form: .sa110, section: "Self Assessment", number: "1", label: "Total tax due before any payments on account",
                             value: .amount(liabilityAfterDeductions)))
        } else {
            boxes.append(Box(form: .sa110, section: "Self Assessment", number: "2", label: "Total tax overpaid", value: .amount(-liabilityAfterDeductions)))
        }
        if !inputs.employments.isEmpty {
            boxes.append(Box(form: .sa100, section: "What makes up your tax return", number: "Q1",
                             label: "Employment: Yes, number of pages \(inputs.employments.count)", value: .text("\(inputs.employments.count)")))
        }
        if !properties.isEmpty {
            boxes.append(Box(form: .sa100, section: "What makes up your tax return", number: "Q5", label: "Foreign: Yes", value: .text("Yes")))
        }
        if inputs.savingsIncome > 0 || inputs.dividendIncome > 0 {
            warnings.append("Savings and dividends are in the calculation; their SA100 / SA106 boxes aren't listed yet.")
        }

        // Boxes taken as filed carry the computed value and the reason.
        for index in boxes.indices {
            let box = boxes[index]
            let key: String?
            switch (box.form, box.number) {
            case (.sa102, "1"): key = "sa102.1"
            case (.sa102, "2"): key = "sa102.2"
            case (.sa106, "14"): key = "sa106.14"
            case (.sa106, "17"): key = "sa106.17"
            case (.sa106, "24.1"): key = "sa106.24.1"
            case (.sa106, "28"): key = "sa106.28"
            default: key = nil
            }
            if let key, let filed = asFiled[key], box.asFiled == nil { boxes[index].asFiled = filed }
        }
        // Each box points at the step that explains it.
        for index in boxes.indices {
            let section = boxes[index].section
            switch boxes[index].form {
            case .sa102:
                if let position = inputs.employments.indices.first(where: { section == "Employment \($0 + 1): \(inputs.employments[$0].employerName)" }) {
                    boxes[index].step = employmentStepTitle(position, inputs.employments[position])
                }
            case .sa106:
                boxes[index].step = section == "Foreign Tax Credit Relief" ? "Income Tax due after tax reductions"
                    : (section.hasPrefix("Foreign Tax Credit Relief") ? section : "Land and property abroad")
            case .sa110: boxes[index].step = "Tax deducted"
            case .sa100: boxes[index].step = nil
            }
            // A row without its own step (no foreign tax, so no relief step) explains with the property's.
            if let step = boxes[index].step, !steps.contains(where: { $0.title == step }) {
                boxes[index].step = boxes[index].form == .sa106 ? "Land and property abroad" : nil
            }
        }

        let calculation = Calculation(totalEmploymentIncome: employmentIncome, propertyProfit: propertyProfit, totalIncome: totalIncome,
                                      adjustedNetIncome: full.adjustedNetIncome, personalAllowance: full.personalAllowance, taxableIncome: full.taxable,
                                      bandLines: full.lines, incomeTaxCharged: full.charged, financeCosts: costsAvailable,
                                      financeCostReliefBase: full.financeBase, financeCostReduction: full.financeReduction,
                                      financeCostsCarriedForward: carriedForward, foreignTaxCreditRelief: ftcrTotal, incomeTaxDue: incomeTaxDue,
                                      taxDeducted: taxDeducted, selfAssessmentLiability: liabilityAfterDeductions,
                                      paymentsOnAccountMade: inputs.paymentsOnAccountMade, balancingPayment: balancing,
                                      nextPaymentOnAccount: nextPOA, propertyLossCarriedForward: lossCarriedForward)
        return Result(taxYear: UKTaxYear(startYear: inputs.startYear), personId: personId, inputs: inputs, calculation: calculation,
                      foreignTaxCredits: credits, boxes: boxes, steps: steps, warnings: warnings)
    }

    /// "Employment 1: Example Ltd" (numbered, so two jobs with one employer stay apart).
    static func employmentStepTitle(_ index: Int, _ employment: EmploymentInput) -> String {
        "Employment \(index + 1): \(employment.employerName)"
    }

    /// Column F of each property: its profit, less the year's losses on the other properties,
    /// set off against the profits with the lowest foreign tax rate first (keeping the relief
    /// where the foreign tax is highest); 0 for a loss.
    static func columnF(_ properties: [PropertyInput]) -> [Int] {
        var reduced = properties.map { max(0, $0.profit) }
        var losses = properties.reduce(0) { $0 + max(0, -$1.profit) }
        let order = properties.indices.filter { properties[$0].profit > 0 }.sorted { a, b in
            let ra = Double(properties[a].foreignTax) / Double(properties[a].profit)
            let rb = Double(properties[b].foreignTax) / Double(properties[b].profit)
            return ra != rb ? ra < rb : a < b
        }
        for index in order where losses > 0 {
            let used = min(losses, reduced[index])
            reduced[index] -= used
            losses -= used
        }
        return reduced
    }

    static let sa102BoxLabels: [Int: String] = [
        9: "Company cars and vans", 10: "Fuel for company cars and vans", 11: "Private medical and dental insurance",
        12: "Vouchers, credit cards and excess mileage allowance", 13: "Goods and other assets provided by your employer",
        14: "Accommodation provided by your employer", 15: "Other benefits", 16: "Expenses payments received and balancing charges"
    ]

    /// The SA106 country code (ISO 3166-1 alpha-3) of an alpha-2 code; the input when unknown.
    public static func countryCode(_ alpha2: String) -> String {
        let codes = ["PT": "PRT", "ES": "ESP", "FR": "FRA", "IT": "ITA", "DE": "DEU", "IE": "IRL", "NL": "NLD", "BE": "BEL", "CH": "CHE",
                     "US": "USA", "GB": "GBR", "BR": "BRA", "AR": "ARG", "GR": "GRC", "CY": "CYP", "MT": "MLT", "AT": "AUT", "PL": "POL"]
        return codes[alpha2.uppercased()] ?? alpha2.uppercased()
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: date)
    }

    // MARK: From the records

    public struct Options: Equatable, Sendable {
        /// `nil`: worked out from the year before (back to the first year with rules).
        public var financeCostsBroughtForward: Int?
        public var propertyLossBroughtForward: Int?

        public init(financeCostsBroughtForward: Int? = nil, propertyLossBroughtForward: Int? = nil) {
            self.financeCostsBroughtForward = financeCostsBroughtForward
            self.propertyLossBroughtForward = propertyLossBroughtForward
        }
    }

    /// The person's return for the year from the records.
    public static func compute(db: Database, startYear: Int, personId: Int64, options: Options = Options()) throws -> Result {
        try compute(db: db, startYear: startYear, personId: personId, options: options, memo: nil)
    }

    /// `compute`, reusing (and keeping) in `memo` each year's return worked out with the brought-forward
    /// figures from the records, and each rental account: for working out several years in one
    /// unchanged state of the database (`TaxFigures.snapshot`), where each year otherwise works
    /// out every earlier one again.
    static func compute(db: Database, startYear: Int, personId: Int64, options: Options = Options(),
                        memo: TaxComputationMemo?) throws -> Result {
        let fromRecords = options.financeCostsBroughtForward == nil && options.propertyLossBroughtForward == nil
        if fromRecords, let known = memo?.knownReturn(TaxComputationMemo.ReturnKey(startYear: startYear, personId: personId)) {
            return known
        }
        guard let rules = UKTaxRules.forYear(startYear) else { throw ComputeError.noRulesForYear(startYear) }
        guard try Person.exists(db, key: personId) else { throw ComputeError.personNotFound }
        var (inputs, warnings) = try gather(db: db, startYear: startYear, personId: personId, rules: rules, memo: memo)
        if options.financeCostsBroughtForward == nil || options.propertyLossBroughtForward == nil {
            var previous: Result?
            if UKTaxRules.forYear(startYear - 1) != nil {
                previous = try compute(db: db, startYear: startYear - 1, personId: personId, memo: memo)
            }
            // The previous year's carry-forward as its calculation left it: for a filed year with
            // boxes taken as filed, the filed return's figures (what HMRC holds).
            inputs.financeCostsBroughtForward = options.financeCostsBroughtForward ?? previous?.calculation.financeCostsCarriedForward ?? 0
            inputs.propertyLossBroughtForward = options.propertyLossBroughtForward ?? previous?.calculation.propertyLossCarriedForward ?? 0
            if let previous, !previous.inputs.filedBoxes.isEmpty { inputs.broughtForwardFromFiledReturn = previous.taxYear.label }
        } else {
            inputs.financeCostsBroughtForward = options.financeCostsBroughtForward!
            inputs.propertyLossBroughtForward = options.propertyLossBroughtForward!
        }
        var result = calculate(inputs, rules: rules, personId: personId)
        result.warnings = warnings + result.warnings
        if fromRecords { memo?.keep(result, for: TaxComputationMemo.ReturnKey(startYear: startYear, personId: personId)) }
        return result
    }

    static func gather(db: Database, startYear: Int, personId: Int64, rules: UKTaxRules,
                       memo: TaxComputationMemo? = nil) throws -> (Inputs, [String]) {
        var warnings: [String] = []
        var inputs = Inputs(startYear: startYear)
        let year = UKTaxYear(startYear: startYear)
        let taxYear = try TaxYears.year(db: db, startYear: startYear, personId: personId)
        inputs.foreignTaxInPence = taxYear?.foreignTaxInPence ?? false
        // Boxes as filed stand only for a filed or paid year: an open year is computed by the rules.
        let filedBoxes = try TaxFiledBoxes.boxes(db: db, startYear: startYear, personId: personId)
        if !filedBoxes.isEmpty {
            if taxYear?.status == .filed || taxYear?.status == .paid {
                for box in filedBoxes { inputs.filedBoxes[box.field] = FiledBox(value: box.valueMinorUnits, note: box.note) }
            } else {
                warnings.append("\(filedBoxes.count) box\(filedBoxes.count == 1 ? "" : "es") stored as filed (\(filedBoxes.map { TaxFiledBoxes.label($0.field) }.joined(separator: ", "))) are left aside: \(year.label) isn't filed, so it is worked out by the rules.")
            }
        }

        for employment in try Employments.employments(db: db, startYear: startYear, personId: personId) {
            let income = try Employments.effectiveIncome(db: db, employmentId: employment.id!)
            if income == nil { warnings.append("\(employment.employerName): no pay and tax yet (add the P60, P45 or payslips).") }
            var byBox: [Int: Int] = [:]
            for benefit in try Employments.benefits(db: db, employmentId: employment.id!) { byBox[benefit.sa102Box, default: 0] += benefit.cashEquivalentMinorUnits }
            inputs.employments.append(EmploymentInput(employmentId: employment.id, employerName: employment.employerName,
                                                      payeReference: employment.payeReference, pay: income?.payMinorUnits ?? 0,
                                                      taxDeducted: income?.taxDeductedMinorUnits ?? 0, benefitsByBox: byBox))
        }

        for property in try Properties.all(db: db) {
            let owners = try memo?.reads?.owners(db: db, propertyId: property.id!) ?? Properties.owners(db: db, propertyId: property.id!)
            guard owners.contains(where: { $0.personId == personId }) else { continue }
            if property.country == "GB" {
                warnings.append("\(property.name) is in the UK: UK property (SA105) isn't computed.")
                continue
            }
            let accounts = try RentalAccounts.compute(db: db, taxYear: year, personId: personId, propertyId: property.id!, memo: memo)
            let totals = accounts.totals
            func gbp(_ amount: RentalAccounts.Amount, _ what: String) -> Int {
                if let value = amount.gbp { return value }
                warnings.append("\(property.name): \(what) needs the HMRC rate for \(year.label); left at £0.")
                return 0
            }
            let input = PropertyInput(propertyId: property.id, name: property.name, country: property.country,
                                      income: gbp(totals.income, "rent"), expenses: gbp(totals.expenses, "expenses"),
                                      financeCosts: gbp(totals.financeCosts, "finance costs"), foreignTax: gbp(totals.foreignTax, "foreign tax"),
                                      usesTraditionalAccounting: true)
            if input.income == 0 && input.expenses == 0 && input.financeCosts == 0 && input.foreignTax == 0 { continue }
            inputs.properties.append(input)
            warnings += accounts.warnings.map { "\(property.name): \($0)" }
        }

        for income in try OtherIncomes.incomes(db: db, startYear: startYear, personId: personId) {
            guard income.currency == .gbp else {
                warnings.append("\(income.payer ?? income.kind.displayName): only GBP other income is computed; enter it in pounds.")
                continue
            }
            switch income.kind {
            case .ukInterest, .foreignInterest:
                inputs.savingsIncome += income.amountMinorUnits
                if income.kind == .ukInterest { inputs.savingsTaxDeducted += income.taxDeductedMinorUnits }
            case .ukDividends, .foreignDividends:
                inputs.dividendIncome += income.amountMinorUnits
            case .other:
                inputs.otherNonSavingsIncome += income.amountMinorUnits
            }
            if income.kind == .foreignInterest || income.kind == .foreignDividends, income.taxDeductedMinorUnits > 0 {
                warnings.append("Foreign tax on \(income.kind.displayName.lowercased()) isn't claimed as FTCR yet.")
            }
        }

        for contribution in try PensionContributions.contributions(db: db, startYear: startYear, personId: personId) {
            switch contribution.kind {
            case .reliefAtSource:
                inputs.grossPensionContributions += contribution.paidMinorUnits * 10_000 / (10_000 - rules.basicRate)
            case .netPay:
                break
            case .noReliefAtSource, .overseas:
                warnings.append("\(contribution.kind.displayName) pension contributions aren't computed yet.")
            }
        }

        inputs.paymentsOnAccountMade = try HMRCPayments.payments(db: db, personId: personId, startYear: startYear)
            .filter { $0.kind == .firstPaymentOnAccount || $0.kind == .secondPaymentOnAccount }
            .reduce(0) { $0 + $1.amountMinorUnits }
        return (inputs, warnings)
    }
}

enum UKTaxRulesFormat {
    /// 2 000 → "20%", 875 → "8.75%".
    static func percent(_ basisPoints: Int) -> String {
        basisPoints % 100 == 0 ? "\(basisPoints / 100)%" : String(format: "%g%%", Double(basisPoints) / 100)
    }
}

/// Returns and rental accounts already worked out in one unchanged state of the database
/// (`SelfAssessment.compute(…, memo:)`, `TaxFigures.snapshot(…, memo:)`).
///
/// The filed-year guard records what each year's figures read (`TaxFiguresReads`) with one
/// memo across the years: each entry carries the `tag` (the year being recorded) it was worked
/// out under, and a hit on another tag's entry is noted in `usedTags` (that year's reads count
/// too); `keeping(excluding:)` keeps the entries whose reads haven't changed.
final class TaxComputationMemo {
    struct ReturnKey: Hashable {
        var startYear: Int
        var personId: Int64
    }

    struct AccountsKey: Hashable {
        var startYear: Int
        var personId: Int64
        var propertyId: Int64
    }

    private var returns: [ReturnKey: (result: SelfAssessment.Result, tag: Int?)] = [:]
    private var accounts: [AccountsKey: (result: RentalAccounts.Result, tag: Int?)] = [:]
    /// The tag of the entries kept from now on.
    var tag: Int?
    /// What the current `TaxFigures.snapshot` call has read (`TaxReadCache`): set for that call
    /// only, and never kept by `keeping(excluding:)`.
    var reads: TaxReadCache?
    /// The other tags whose entries were used since `tag` was set.
    var usedTags: Set<Int> = []

    init(tag: Int? = nil) {
        self.tag = tag
    }

    func knownReturn(_ key: ReturnKey) -> SelfAssessment.Result? {
        guard let entry = returns[key] else { return nil }
        used(entry.tag)
        return entry.result
    }

    func keep(_ result: SelfAssessment.Result, for key: ReturnKey) {
        returns[key] = (result, tag)
    }

    func knownAccounts(_ key: AccountsKey) -> RentalAccounts.Result? {
        guard let entry = accounts[key] else { return nil }
        used(entry.tag)
        return entry.result
    }

    func keep(_ result: RentalAccounts.Result, for key: AccountsKey) {
        accounts[key] = (result, tag)
    }

    /// A memo with the tagged entries whose tag isn't in `tags` (untagged ones are left out too).
    func keeping(excluding tags: Set<Int>) -> TaxComputationMemo {
        let kept = TaxComputationMemo()
        kept.returns = returns.filter { $0.value.tag.map { !tags.contains($0) } ?? false }
        kept.accounts = accounts.filter { $0.value.tag.map { !tags.contains($0) } ?? false }
        return kept
    }

    private func used(_ entryTag: Int?) {
        if let entryTag, entryTag != tag { usedTags.insert(entryTag) }
    }
}
