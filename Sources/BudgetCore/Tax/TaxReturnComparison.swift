import Foundation

/// A tax year's return and calculation compared with the year before (the Calculation tab's
/// "Compared with …" tile): for each figure the previous year's, this year's and the difference,
/// with a short reason where one can be told from the two computations. Pure and read-only: it
/// reads two `SelfAssessment.Result`s (and, for the expense categories, the two rental accounts)
/// and changes nothing, so the filed years' figures are untouched.
public enum TaxReturnComparison {
    public enum Section: String, CaseIterable, Sendable {
        case income = "Income"
        case expenses = "Expenses"
        case allowances = "Allowances and taxable income"
        case tax = "Tax"
        case payments = "Payments"
    }

    /// One figure in both years, in GBP pence.
    public struct Line: Equatable, Identifiable, Sendable {
        public var id: String
        public var section: Section
        public var label: String
        public var previous: Int
        public var current: Int
        /// Whether the figure exists in each year (an income source, an expense category, a band).
        public var inPrevious: Bool
        public var inCurrent: Bool
        /// A total or headline line (shown in bold).
        public var isTotal: Bool
        /// Why it differs, where that can be told.
        public var why: String?

        public var difference: Int { current - previous }
        public var isChanged: Bool { previous != current || inPrevious != inCurrent }
    }

    public struct Group: Equatable, Identifiable, Sendable {
        public var section: Section
        public var lines: [Line]
        public var id: String { section.rawValue }
        public var changedCount: Int { lines.filter(\.isChanged).count }
    }

    public struct Result: Equatable, Sendable {
        public var previousLabel: String
        public var currentLabel: String
        public var groups: [Group]
        public var changedCount: Int { groups.reduce(0) { $0 + $1.changedCount } }
        public var lineCount: Int { groups.reduce(0) { $0 + $1.lines.count } }
    }

    /// Whether `result` holds anything to compare against: income, or a source of it.
    public static func hasData(_ result: SelfAssessment.Result) -> Bool {
        let i = result.inputs
        return !i.employments.isEmpty || !i.properties.isEmpty || result.calculation.totalIncome != 0 || i.otherNonSavingsIncome != 0
            || i.savingsIncome != 0 || i.dividendIncome != 0
    }

    /// `current` against `previous`; nil when the previous year has no return data. The accounts
    /// (the person's rental accounts of the same property in each year) give the expense
    /// categories; without both, the expenses are compared per property.
    public static func compare(previous: SelfAssessment.Result?, current: SelfAssessment.Result,
                               previousAccounts: RentalAccounts.Result? = nil, currentAccounts: RentalAccounts.Result? = nil) -> Result? {
        guard let previous, hasData(previous) else { return nil }
        let p = previous.taxYear.label
        let c = current.taxYear.label
        var lines: [Line] = []

        func sourceWhy(_ inPrev: Bool, _ inCur: Bool, noun: String) -> String? {
            if inCur && !inPrev { return "New \(noun) this year: none in \(p)" }
            if inPrev && !inCur { return "No \(noun) in \(c): it was in \(p)" }
            return nil
        }
        func add(_ id: String, _ section: Section, _ label: String, previous pv: Int, current cv: Int, inPrevious: Bool = true,
                 inCurrent: Bool = true, total: Bool = false, why: String? = nil) {
            lines.append(Line(id: "\(section.rawValue)|\(id)", section: section, label: label, previous: pv, current: cv,
                              inPrevious: inPrevious, inCurrent: inCurrent, isTotal: total, why: why))
        }

        // Income, by source.
        // An employer is matched across the years by its name with the legal suffix and punctuation
        // set aside ("Example Ltd" and "Example Limited" are one employer); it shows under this year's name.
        func employmentKeys(_ r: SelfAssessment.Result) -> [String] { r.inputs.employments.map { employerKey($0.employerName) } }
        for key in union(employmentKeys(previous), employmentKeys(current)) {
            let pe = previous.inputs.employments.filter { employerKey($0.employerName) == key }
            let ce = current.inputs.employments.filter { employerKey($0.employerName) == key }
            let name = (ce.first ?? pe.first)?.employerName ?? key
            add("employment|\(key)", .income, name, previous: pe.reduce(0) { $0 + $1.total }, current: ce.reduce(0) { $0 + $1.total },
                inPrevious: !pe.isEmpty, inCurrent: !ce.isEmpty, why: sourceWhy(!pe.isEmpty, !ce.isEmpty, noun: "employment"))
        }
        func propertyKeys(_ r: SelfAssessment.Result) -> [String] { r.inputs.properties.map(\.name) }
        for name in union(propertyKeys(previous), propertyKeys(current)) {
            let pp = previous.inputs.properties.first { $0.name == name }
            let cp = current.inputs.properties.first { $0.name == name }
            add("property|\(name)", .income, name, previous: pp?.income ?? 0, current: cp?.income ?? 0, inPrevious: pp != nil, inCurrent: cp != nil,
                why: sourceWhy(pp != nil, cp != nil, noun: "property"))
        }
        for (id, label, pv, cv) in [("other", "Other taxable income", previous.inputs.otherNonSavingsIncome, current.inputs.otherNonSavingsIncome),
                                    ("savings", "Savings interest", previous.inputs.savingsIncome, current.inputs.savingsIncome),
                                    ("dividends", "Dividends", previous.inputs.dividendIncome, current.inputs.dividendIncome)] where pv != 0 || cv != 0 {
            add(id, .income, label, previous: pv, current: cv, inPrevious: pv != 0, inCurrent: cv != 0, why: sourceWhy(pv != 0, cv != 0, noun: "income"))
        }
        add("total", .income, "Total income", previous: previous.calculation.totalIncome, current: current.calculation.totalIncome, total: true)

        // Expenses, by category when both years' accounts are known, else per property.
        if let pa = previousAccounts, let ca = currentAccounts {
            var types: [TaxExpenseType] = []
            for line in pa.expenses + ca.expenses where !types.contains(line.expenseType) { types.append(line.expenseType) }
            for type in types {
                let pv = pa.line(type)?.amount.gbp ?? 0
                let cv = ca.line(type)?.amount.gbp ?? 0
                guard pv != 0 || cv != 0 else { continue }
                let label = ca.line(type)?.label ?? pa.line(type)?.label ?? type.displayName
                add("category|\(type.rawValue)", .expenses, label, previous: pv, current: cv, inPrevious: pv != 0, inCurrent: cv != 0,
                    why: pv == 0 ? "No \(label.lowercased()) claimed in \(p)" : (cv == 0 ? "No \(label.lowercased()) claimed in \(c)" : nil))
            }
        } else {
            for name in union(propertyKeys(previous), propertyKeys(current)) {
                let pp = previous.inputs.properties.first { $0.name == name }
                let cp = current.inputs.properties.first { $0.name == name }
                add("expenses|\(name)", .expenses, "\(name): allowable expenses", previous: pp?.expenses ?? 0, current: cp?.expenses ?? 0,
                    inPrevious: pp != nil, inCurrent: cp != nil, why: sourceWhy(pp != nil, cp != nil, noun: "property"))
            }
        }
        let pExpenses = previous.inputs.properties.reduce(0) { $0 + $1.expenses }
        let cExpenses = current.inputs.properties.reduce(0) { $0 + $1.expenses }
        add("total", .expenses, "Allowable expenses", previous: pExpenses, current: cExpenses, total: true)
        add("finance", .expenses, "Residential finance costs", previous: previous.calculation.financeCosts, current: current.calculation.financeCosts)
        add("foreignTax", .expenses, "Foreign tax paid", previous: previous.inputs.properties.reduce(0) { $0 + $1.foreignTax },
            current: current.inputs.properties.reduce(0) { $0 + $1.foreignTax })
        add("pension", .expenses, "Pension contributions (gross)", previous: previous.inputs.grossPensionContributions,
            current: current.inputs.grossPensionContributions)

        // Allowances and taxable income.
        let pc = previous.calculation
        let cc = current.calculation
        add("property", .allowances, "Property profit after losses", previous: pc.propertyProfit, current: cc.propertyProfit)
        add("ani", .allowances, "Adjusted net income", previous: pc.adjustedNetIncome, current: cc.adjustedNetIncome)
        var allowanceWhy: String?
        if pc.personalAllowance != cc.personalAllowance {
            let standardPrevious = UKTaxRules.forYear(previous.taxYear.startYear)?.personalAllowance
            let standardCurrent = UKTaxRules.forYear(current.taxYear.startYear)?.personalAllowance
            if let sp = standardPrevious, let sc = standardCurrent, sp != sc {
                allowanceWhy = "The standard allowance moved from \(Money.format(sp, currency: .gbp)) to \(Money.format(sc, currency: .gbp))"
            } else if let sc = standardCurrent, cc.personalAllowance < sc, pc.personalAllowance >= (standardPrevious ?? 0) {
                allowanceWhy = "Reduced this year: adjusted net income is over the allowance limit"
            } else if let sp = standardPrevious, pc.personalAllowance < sp {
                allowanceWhy = "Reduced in \(p) by adjusted net income over the limit; not this year"
            }
        }
        add("allowance", .allowances, "Personal allowance", previous: pc.personalAllowance, current: cc.personalAllowance, why: allowanceWhy)
        add("taxable", .allowances, "Taxable income", previous: pc.taxableIncome, current: cc.taxableIncome, total: true)

        // Tax: by band (a band is its kind and name), then the totals.
        func bandKey(_ b: SelfAssessment.BandLine) -> String { "\(b.kind.rawValue)|\(b.band)" }
        func bandName(_ b: SelfAssessment.BandLine) -> String {
            switch b.kind {
            case .nonSavings: return b.band
            case .savings: return "Savings \(b.band.lowercased())"
            case .dividends: return "Dividends \(b.band.lowercased())"
            }
        }
        var bandKeys: [String] = []
        for b in pc.bandLines + cc.bandLines where b.tax != 0 || b.amount != 0 { if !bandKeys.contains(bandKey(b)) { bandKeys.append(bandKey(b)) } }
        for key in bandKeys {
            let pb = pc.bandLines.first { bandKey($0) == key && ($0.tax != 0 || $0.amount != 0) }
            let cb = cc.bandLines.first { bandKey($0) == key && ($0.tax != 0 || $0.amount != 0) }
            var why: String?
            if let pb, let cb {
                if pb.rate != cb.rate {
                    why = "Rate \(percent(pb.rate)) in \(p), \(percent(cb.rate)) in \(c)"
                } else if pb.amount != cb.amount {
                    why = "\(Money.format(cb.amount, currency: .gbp)) falls in this band (\(Money.format(pb.amount, currency: .gbp)) in \(p))"
                }
            } else if cb != nil {
                why = "Income reaches this band in \(c); it did not in \(p)"
            } else {
                why = "No income in this band in \(c)"
            }
            add("band|\(key)", .tax, "\((cb ?? pb).map(bandName) ?? key) tax", previous: pb?.tax ?? 0, current: cb?.tax ?? 0,
                inPrevious: pb != nil, inCurrent: cb != nil, why: why)
        }
        add("charged", .tax, "Income Tax charged", previous: pc.incomeTaxCharged, current: cc.incomeTaxCharged)
        add("financeRelief", .tax, "Finance cost relief", previous: -pc.financeCostReduction, current: -cc.financeCostReduction)
        add("ftcr", .tax, "Foreign Tax Credit Relief", previous: -pc.foreignTaxCreditRelief, current: -cc.foreignTaxCreditRelief)
        add("due", .tax, "Income Tax due", previous: pc.incomeTaxDue, current: cc.incomeTaxDue, total: true)
        add("deducted", .tax, "Tax deducted", previous: pc.taxDeducted, current: cc.taxDeducted)
        add("liability", .tax, "Tax due before payments on account", previous: pc.selfAssessmentLiability, current: cc.selfAssessmentLiability, total: true)

        // Payments.
        add("poaMade", .payments, "Payments on account made", previous: pc.paymentsOnAccountMade, current: cc.paymentsOnAccountMade,
            why: pc.paymentsOnAccountMade != cc.paymentsOnAccountMade ? "Set by \(p)'s liability" : nil)
        add("balancing", .payments, "Balancing payment (negative: repayment)",
            previous: pc.balancingPayment, current: cc.balancingPayment, total: true,
            why: pc.paymentsOnAccountMade != cc.paymentsOnAccountMade && pc.balancingPayment != cc.balancingPayment
                ? "Payments on account made were \(Money.format(pc.paymentsOnAccountMade, currency: .gbp)), now \(Money.format(cc.paymentsOnAccountMade, currency: .gbp))" : nil)
        add("poaNext", .payments, "Each payment on account for the next year", previous: pc.nextPaymentOnAccount, current: cc.nextPaymentOnAccount)

        let groups = Section.allCases.compactMap { section -> Group? in
            let sectionLines = lines.filter { $0.section == section }
            return sectionLines.isEmpty ? nil : Group(section: section, lines: sectionLines)
        }
        return Result(previousLabel: p, currentLabel: c, groups: groups)
    }

    /// An employer's name for matching: lower case, punctuation dropped, "limited" read as "ltd" and
    /// "public limited company" as "plc", spaces collapsed.
    static func employerKey(_ name: String) -> String {
        var words = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").map(String.init)
        if words.suffix(3) == ["public", "limited", "company"] { words.removeLast(3); words.append("plc") }
        words = words.map { $0 == "limited" ? "ltd" : $0 }
        return words.joined(separator: " ")
    }

    private static func union(_ a: [String], _ b: [String]) -> [String] {
        var seen: [String] = []
        for key in a + b where !seen.contains(key) { seen.append(key) }
        return seen
    }

    private static func percent(_ basisPoints: Int) -> String {
        basisPoints % 100 == 0 ? "\(basisPoints / 100)%" : String(format: "%g%%", Double(basisPoints) / 100)
    }
}
