import GRDB
import Foundation

// What the Self Assessment tabs of a tax year read and write (plan phase 4 Task 4): the
// person's income records with their documents, the computation, and the HMRC online filing
// checklist. The App only lays these out.

public enum SelfAssessmentOverview {
    public struct EmploymentRow: Equatable, Identifiable, Sendable {
        public var employment: Employment
        /// By the precedence of their source.
        public var incomes: [EmploymentIncome]
        public var benefits: [BenefitInKind]
        /// Documents linked to the employment and its pay-and-tax rows.
        public var documentCount: Int
        public var id: Int64 { employment.id ?? 0 }
    }

    public struct IncomePage: Equatable, Sendable {
        public var employments: [EmploymentRow] = []
        public var otherIncomes: [OtherIncome] = []
        public var pensions: [PensionContribution] = []
        /// Payments for this year and the payments on account towards the next one.
        public var payments: [HMRCPayment] = []
        /// Document counts by record (employment income rows counted on their employment).
        public var documentCounts: [EvidenceEntity: Int] = [:]
        /// Whether the personal-income evidence rules are all stored.
        public var hasEvidenceRules = false

        public init() {}
    }

    public static func incomePage(db: Database, startYear: Int, personId: Int64) throws -> IncomePage {
        var page = IncomePage()
        let incomeCounts = try EvidenceLinks.linkCounts(db: db, .employmentIncome)
        let employmentCounts = try EvidenceLinks.linkCounts(db: db, .employment)
        for employment in try Employments.employments(db: db, startYear: startYear, personId: personId) {
            let incomes = try Employments.incomes(db: db, employmentId: employment.id!)
            let count = (employmentCounts[employment.id!] ?? 0) + incomes.reduce(0) { $0 + (incomeCounts[$1.id!] ?? 0) }
            page.employments.append(EmploymentRow(employment: employment, incomes: incomes,
                                                  benefits: try Employments.benefits(db: db, employmentId: employment.id!), documentCount: count))
        }
        page.otherIncomes = try OtherIncomes.incomes(db: db, startYear: startYear, personId: personId)
        page.pensions = try PensionContributions.contributions(db: db, startYear: startYear, personId: personId)
        page.payments = try HMRCPayments.payments(db: db, personId: personId).filter { $0.startYear == startYear || $0.startYear == startYear + 1 }
        for (type, ids) in [(EvidenceEntityType.otherIncome, page.otherIncomes.compactMap(\.id)),
                            (.pensionContribution, page.pensions.compactMap(\.id)), (.hmrcPayment, page.payments.compactMap(\.id))] {
            let counts = try EvidenceLinks.linkCounts(db: db, type)
            for id in ids { page.documentCounts[EvidenceEntity(type: type, id: id)] = counts[id] ?? 0 }
        }
        page.hasEvidenceRules = try PersonalIncomeEvidence.defaultRules(db: db).isEmpty
        return page
    }

    /// The year's computation, or why there's none.
    public static func selfAssessment(db: Database, startYear: Int, personId: Int64) -> (SelfAssessment.Result?, String?) {
        do {
            return (try SelfAssessment.compute(db: db, startYear: startYear, personId: personId), nil)
        } catch SelfAssessment.ComputeError.noRulesForYear(let year) {
            return (nil, "The UK tax rules for \(UKTaxYear(startYear: year).label) aren't in the app yet.")
        } catch {
            return (nil, "Couldn't compute the return: \(error.localizedDescription)")
        }
    }
}

// MARK: - Saving with documents

extension Employments {
    public static func save(db: Database, _ employment: inout Employment, documents: EvidenceLinkChanges) throws {
        try save(db: db, &employment)
        try documents.apply(db: db, to: .employment(employment.id!))
    }

    public static func save(db: Database, _ income: inout EmploymentIncome, documents: EvidenceLinkChanges) throws {
        try save(db: db, &income)
        try documents.apply(db: db, to: .employmentIncome(income.id!))
    }
}

extension OtherIncomes {
    public static func save(db: Database, _ income: inout OtherIncome, documents: EvidenceLinkChanges) throws {
        try save(db: db, &income)
        try documents.apply(db: db, to: .otherIncome(income.id!))
    }
}

extension PensionContributions {
    public static func save(db: Database, _ contribution: inout PensionContribution, documents: EvidenceLinkChanges) throws {
        try save(db: db, &contribution)
        try documents.apply(db: db, to: .pensionContribution(contribution.id!))
    }
}

extension HMRCPayments {
    /// Saves the payment with its proof; with `markYear`, sets the person's year to that status too.
    public static func save(db: Database, _ payment: inout HMRCPayment, documents: EvidenceLinkChanges, markYear status: TaxYearStatus? = nil) throws {
        try save(db: db, &payment)
        try documents.apply(db: db, to: .hmrcPayment(payment.id!))
        if let status { try TaxOverview.setStatus(db: db, startYear: payment.startYear, personId: payment.personId, status: status) }
    }
}

extension SelfAssessment.BoxValue {
    /// What a box's copy button puts on the clipboard: whole pounds ("12345", "-500"; the
    /// return's boxes take whole pounds), the text, or "X".
    public var copyText: String { copyText(wholePounds: true) }

    /// With `wholePounds` false, pounds and pence ("12345.67") — for SA110 and the figures
    /// HMRC's calculation shows.
    public func copyText(wholePounds: Bool) -> String {
        switch self {
        case let .amount(pence):
            let sign = pence < 0 ? "-" : ""
            return wholePounds ? "\(sign)\(abs(pence) / 100)" : String(format: "%@%d.%02d", sign, abs(pence) / 100, abs(pence) % 100)
        case let .text(text): return text
        case .cross: return "X"
        }
    }
}

extension SelfAssessment.Box {
    /// Whether the box takes whole pounds: every form but SA110, which keeps pence.
    public var isWholePounds: Bool { form != .sa110 }
    /// Whole pounds, but SA110 keeps pence.
    public var copyText: String { value.copyText(wholePounds: isWholePounds) }
}

extension SelfAssessmentFiling.Value {
    /// Whether the value is a return box in whole pounds (SA110 aside); the other figures keep pence.
    public var isWholePounds: Bool { box.map { !$0.hasPrefix("SA110") } ?? false }
    /// Whole pounds for a return box (SA110 aside); pounds and pence for the other figures.
    public var copyText: String { value.copyText(wholePounds: isWholePounds) }
}

extension SelfAssessment.Result {
    /// The boxes by form then section, in the order HMRC online asks for them.
    public var boxGroups: [(form: SelfAssessment.Form, section: String, boxes: [SelfAssessment.Box])] {
        var groups: [(form: SelfAssessment.Form, section: String, boxes: [SelfAssessment.Box])] = []
        for form in [SelfAssessment.Form.sa100, .sa102, .sa106, .sa110] {
            for box in boxes where box.form == form {
                if let index = groups.firstIndex(where: { $0.form == form && $0.section == box.section }) {
                    groups[index].boxes.append(box)
                } else {
                    groups.append((form, box.section, [box]))
                }
            }
        }
        return groups
    }
}

// MARK: - Filing checklist

/// The HMRC online filing steps for a computed return, with the values to enter.
public enum SelfAssessmentFiling {
    public struct Value: Equatable, Sendable {
        public var label: String
        public var box: String?
        public var value: SelfAssessment.BoxValue
    }

    public struct Step: Equatable, Identifiable, Sendable {
        public var id: Int
        public var title: String
        public var detail: String
        public var values: [Value]
        public var deadline: Date?
    }

    public static func steps(_ result: SelfAssessment.Result) -> [Step] {
        let deadlines = result.taxYear.deadlines
        let c = result.calculation
        var steps: [(String, String, [Value], Date?)] = []
        steps.append(("Sign in to HMRC online",
                      "Go to gov.uk/log-in-file-self-assessment-tax-return and open the \(result.taxYear.label) return.", [], nil))
        var tailor: [Value] = []
        if let box = result.box(.sa100, "Q1") { tailor.append(Value(label: "Employment: number of pages", box: nil, value: box.value)) }
        if result.box(.sa100, "Q5") != nil { tailor.append(Value(label: "Foreign income (land and property abroad)", box: nil, value: .text("Yes"))) }
        steps.append(("Tailor your return", "Answer the questions about what's in your return; everything else is No.", tailor, nil))
        for group in result.boxGroups where group.form == .sa102 {
            steps.append((group.section, "Add an employment and enter the P60 / P45 and P11D figures.",
                          group.boxes.map { Value(label: $0.label, box: $0.number, value: $0.value) }, nil))
        }
        let property = result.boxGroups.filter { $0.form == .sa106 }
        if !property.isEmpty {
            steps.append(("Foreign: land and property abroad", "Under Foreign, enter the overseas property figures, then the Foreign Tax Credit Relief rows.",
                          property.flatMap { group in group.boxes.map { Value(label: "\(group.section) · \($0.label)", box: $0.number, value: $0.value) } }, nil))
        }
        steps.append(("Check HMRC's calculation", "HMRC's tax calculation should show these figures before you submit.", [
            Value(label: "Income Tax due after tax reductions", box: nil, value: .amount(c.incomeTaxDue)),
            Value(label: "Tax deducted", box: nil, value: .amount(c.taxDeducted)),
            Value(label: c.selfAssessmentLiability >= 0 ? "Total tax due" : "Total tax overpaid", box: c.selfAssessmentLiability >= 0 ? "SA110 1" : "SA110 2",
                  value: .amount(abs(c.selfAssessmentLiability)))
        ], nil))
        steps.append(("Submit the return", "Submit online and keep the submission receipt; then mark the year as Filed.", [], deadlines.onlineReturnAndBalancingPayment))
        var pay = [Value(label: c.balancingPayment >= 0 ? "Balancing payment" : "Repayment due to you", box: nil, value: .amount(abs(c.balancingPayment)))]
        if c.nextPaymentOnAccount > 0 {
            pay.append(Value(label: "1st payment on account for \(UKTaxYear(startYear: result.taxYear.startYear + 1).label)", box: nil,
                             value: .amount(c.nextPaymentOnAccount)))
        }
        steps.append(("Pay by 31 January", "Pay HMRC with your UTR followed by K as the reference; record each payment with its proof.", pay,
                      deadlines.onlineReturnAndBalancingPayment))
        if c.nextPaymentOnAccount > 0 {
            steps.append(("Pay the 2nd payment on account", "The second half of next year's payments on account.",
                          [Value(label: "2nd payment on account", box: nil, value: .amount(c.nextPaymentOnAccount))], deadlines.secondPaymentOnAccount))
        }
        return steps.enumerated().map { Step(id: $0.offset + 1, title: $0.element.0, detail: $0.element.1, values: $0.element.2, deadline: $0.element.3) }
    }
}
