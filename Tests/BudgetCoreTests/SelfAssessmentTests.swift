import XCTest
import GRDB
@testable import BudgetCore

/// The Self Assessment computation (plan phase 4 Task 3) on synthetic cases shaped like the
/// two returns the app must reproduce: a high earner whose personal allowance is fully
/// tapered, and a basic-rate taxpayer whose Foreign Tax Credit Relief is capped at the UK tax
/// on the rent. Amounts in pence.
final class SelfAssessmentTests: XCTestCase {
    private let rules2024 = UKTaxRules.forYear(2024)!

    private func pounds(_ value: Int) -> Int { value * 100 }

    // MARK: Shapes of the filed returns

    func testHighEarnerWithAllowanceFullyTapered() {
        let inputs = SelfAssessment.Inputs(
            startYear: 2024,
            employments: [.init(employerName: "Example Ltd", payeReference: "123/AB456", pay: pounds(150_000), taxDeducted: pounds(40_000),
                                benefitsByBox: [11: pounds(2_000)])],
            properties: [.init(name: "Property A", country: "PT", income: pounds(12_000), expenses: pounds(2_000),
                               financeCosts: pounds(3_000), foreignTax: pounds(2_500))],
            paymentsOnAccountMade: pounds(3_000))
        let result = SelfAssessment.calculate(inputs, rules: rules2024)
        let c = result.calculation
        XCTAssertEqual(c.totalEmploymentIncome, pounds(152_000))
        XCTAssertEqual(c.propertyProfit, pounds(10_000))
        XCTAssertEqual(c.totalIncome, pounds(162_000))
        XCTAssertEqual(c.personalAllowance, 0)
        XCTAssertEqual(c.taxableIncome, pounds(162_000))
        XCTAssertEqual(c.bandLines.map(\.amount), [pounds(37_700), pounds(87_440), pounds(36_860)])
        XCTAssertEqual(c.bandLines.map(\.tax), [pounds(7_540), pounds(34_976), pounds(16_587)])
        XCTAssertEqual(c.incomeTaxCharged, pounds(59_103))
        XCTAssertEqual(c.financeCostReliefBase, pounds(3_000))
        XCTAssertEqual(c.financeCostReduction, pounds(600))
        XCTAssertEqual(c.financeCostsCarriedForward, 0)
        // Without the rent: £152,000 all taxed, no finance reduction → £54,603; with it £58,503.
        XCTAssertEqual(result.foreignTaxCredits.first?.ukTaxOnIncome, pounds(3_900))
        XCTAssertEqual(result.foreignTaxCredits.first?.credit, pounds(2_500))
        XCTAssertEqual(c.foreignTaxCreditRelief, pounds(2_500))
        XCTAssertEqual(c.incomeTaxDue, pounds(56_003))
        XCTAssertEqual(c.taxDeducted, pounds(40_000))
        XCTAssertEqual(c.selfAssessmentLiability, pounds(16_003))
        XCTAssertEqual(c.balancingPayment, pounds(13_003))
        // 71% deducted at source: payments on account of half the £16,003 each.
        XCTAssertEqual(c.nextPaymentOnAccount, 800_150)

        XCTAssertEqual(result.box(.sa102, "1")?.value, .amount(pounds(150_000)))
        XCTAssertEqual(result.box(.sa102, "2")?.value, .amount(pounds(40_000)))
        XCTAssertEqual(result.box(.sa102, "4")?.value, .text("123/AB456"))
        XCTAssertEqual(result.box(.sa102, "11")?.value, .amount(pounds(2_000)))
        XCTAssertEqual(result.box(.sa106, "14")?.value, .amount(pounds(12_000)))
        XCTAssertEqual(result.box(.sa106, "15")?.value, .text("1"))
        XCTAssertEqual(result.box(.sa106, "17")?.value, .amount(pounds(2_000)))
        XCTAssertEqual(result.box(.sa106, "24")?.value, .amount(pounds(10_000)))
        XCTAssertEqual(result.box(.sa106, "24.1")?.value, .amount(pounds(3_000)))
        XCTAssertEqual(result.box(.sa106, "27")?.value, .amount(pounds(10_000)))
        XCTAssertEqual(result.box(.sa106, "28")?.value, .amount(pounds(2_500)))
        XCTAssertEqual(result.box(.sa106, "A")?.value, .text("PRT"))
        XCTAssertEqual(result.box(.sa106, "E")?.value, .cross)
        XCTAssertEqual(result.box(.sa106, "F")?.value, .amount(pounds(10_000)))
        XCTAssertEqual(result.box(.sa110, "1")?.value, .amount(pounds(16_003)))
        XCTAssertNil(result.box(.sa106, "24.2"))

        let titles = result.steps.map(\.title)
        for expected in ["Employment 1: Example Ltd", "Personal Allowance", "Relief for finance costs", "Foreign Tax Credit Relief: Property A", "Balancing payment",
                         "Payments on account for 2025/26"] {
            XCTAssertTrue(titles.contains(expected), expected)
        }
        XCTAssertTrue(result.steps.first { $0.title == "Personal Allowance" }!.detail.contains("£1 for every £2"))
        XCTAssertEqual(result.warnings, [])
    }

    func testBasicRateTaxpayerWithForeignTaxCreditCapped() {
        let inputs = SelfAssessment.Inputs(
            startYear: 2024,
            employments: [.init(employerName: "Example Ltd", pay: pounds(20_000), taxDeducted: pounds(1_486))],
            properties: [.init(name: "Property A", country: "PT", income: pounds(10_000), expenses: pounds(1_000),
                               financeCosts: pounds(2_000), foreignTax: pounds(2_500))])
        let result = SelfAssessment.calculate(inputs, rules: rules2024)
        let c = result.calculation
        XCTAssertEqual(c.personalAllowance, pounds(12_570))
        XCTAssertEqual(c.taxableIncome, pounds(16_430))
        XCTAssertEqual(c.incomeTaxCharged, pounds(3_286))
        XCTAssertEqual(c.financeCostReduction, pounds(400))
        // UK tax on the rent: £2,886 with it − £1,486 without = £1,400, below the £2,500 PT tax.
        let credit = try! XCTUnwrap(result.foreignTaxCredits.first)
        XCTAssertEqual(credit.ukTaxOnIncome, pounds(1_400))
        XCTAssertEqual(credit.credit, pounds(1_400))
        XCTAssertTrue(credit.explanation.contains("limited to the UK tax on the income"))
        XCTAssertEqual(c.incomeTaxDue, pounds(1_486))
        XCTAssertEqual(c.selfAssessmentLiability, 0)
        XCTAssertEqual(c.balancingPayment, 0)
        XCTAssertEqual(c.nextPaymentOnAccount, 0)
        XCTAssertTrue(result.steps.last!.detail.contains("under £1,000"))
    }

    // MARK: Rules

    func testFinanceCostsLimitedByProfitCarryForward() {
        var inputs = SelfAssessment.Inputs(
            startYear: 2024,
            employments: [.init(employerName: "Example Ltd", pay: pounds(30_000), taxDeducted: pounds(3_486))],
            properties: [.init(name: "Property A", country: "PT", income: pounds(5_000), expenses: pounds(4_000),
                               financeCosts: pounds(3_000), foreignTax: 0)])
        var c = SelfAssessment.calculate(inputs, rules: rules2024).calculation
        XCTAssertEqual(c.financeCostReliefBase, pounds(1_000))
        XCTAssertEqual(c.financeCostReduction, pounds(200))
        XCTAssertEqual(c.financeCostsCarriedForward, pounds(2_000))

        // Brought forward costs add to the year's.
        inputs.properties[0].expenses = pounds(1_000)
        inputs.financeCostsBroughtForward = pounds(2_000)
        let result = SelfAssessment.calculate(inputs, rules: rules2024)
        c = result.calculation
        XCTAssertEqual(c.financeCosts, pounds(5_000))
        XCTAssertEqual(c.financeCostReliefBase, pounds(4_000))
        XCTAssertEqual(c.financeCostsCarriedForward, pounds(1_000))
        XCTAssertEqual(result.box(.sa106, "24.2")?.value, .amount(pounds(2_000)))
    }

    func testFinanceCostsLimitedByIncomeAboveTheAllowance() {
        // Pay £10,000 + rent profit £4,000 = £14,000: only £1,430 is above the allowance.
        let inputs = SelfAssessment.Inputs(
            startYear: 2024,
            employments: [.init(employerName: "Example Ltd", pay: pounds(10_000), taxDeducted: 0)],
            properties: [.init(name: "Property A", country: "PT", income: pounds(5_000), expenses: pounds(1_000),
                               financeCosts: pounds(3_000), foreignTax: 0)])
        let c = SelfAssessment.calculate(inputs, rules: rules2024).calculation
        XCTAssertEqual(c.incomeTaxCharged, pounds(286))
        XCTAssertEqual(c.financeCostReliefBase, pounds(1_430))
        XCTAssertEqual(c.financeCostReduction, pounds(286))
        XCTAssertEqual(c.financeCostsCarriedForward, pounds(1_570))
        XCTAssertEqual(c.incomeTaxDue, 0)
    }

    func testPropertyLossCarriesForwardAndIsUsedNextYear() {
        var inputs = SelfAssessment.Inputs(
            startYear: 2024,
            employments: [.init(employerName: "Example Ltd", pay: pounds(30_000), taxDeducted: pounds(3_486))],
            properties: [.init(name: "Property A", country: "PT", income: pounds(1_000), expenses: pounds(1_500), financeCosts: 0, foreignTax: 0)])
        var result = SelfAssessment.calculate(inputs, rules: rules2024)
        XCTAssertEqual(result.calculation.propertyProfit, 0)
        XCTAssertEqual(result.calculation.propertyLossCarriedForward, pounds(500))
        XCTAssertEqual(result.box(.sa106, "32")?.value, .amount(pounds(500)))

        inputs.properties[0].expenses = pounds(200)
        inputs.propertyLossBroughtForward = pounds(500)
        result = SelfAssessment.calculate(inputs, rules: rules2024)
        XCTAssertEqual(result.calculation.propertyProfit, pounds(300))
        XCTAssertEqual(result.box(.sa106, "26")?.value, .amount(pounds(500)))
        XCTAssertEqual(result.calculation.propertyLossCarriedForward, 0)
    }

    func testPartialTaperAndPensionContributionsRestoreTheAllowance() {
        var inputs = SelfAssessment.Inputs(startYear: 2024, employments: [.init(employerName: "Example Ltd", pay: pounds(110_000), taxDeducted: 0)])
        XCTAssertEqual(SelfAssessment.calculate(inputs, rules: rules2024).calculation.personalAllowance, pounds(7_570))
        inputs.grossPensionContributions = pounds(10_000)
        let c = SelfAssessment.calculate(inputs, rules: rules2024).calculation
        XCTAssertEqual(c.adjustedNetIncome, pounds(100_000))
        XCTAssertEqual(c.personalAllowance, pounds(12_570))
        // The basic rate band is extended by the gross contributions.
        XCTAssertEqual(c.bandLines.first?.amount, pounds(47_700))
    }

    func testSavingsStartingRatePersonalSavingsAllowanceAndDividends() {
        let inputs = SelfAssessment.Inputs(startYear: 2024, employments: [.init(employerName: "Example Ltd", pay: pounds(15_000), taxDeducted: 0)],
                                           savingsIncome: pounds(6_000), dividendIncome: pounds(3_000))
        let c = SelfAssessment.calculate(inputs, rules: rules2024).calculation
        // Non-savings £2,430 above the allowance cuts the £5,000 starting band to £2,570.
        let lines = c.bandLines.map { "\($0.kind.rawValue) \($0.band) \($0.amount / 100) \($0.tax)" }
        XCTAssertEqual(lines, [
            "nonSavings Basic rate 2430 48600",
            "savings Starting rate for savings 2570 0",
            "savings Personal Savings Allowance 1000 0",
            "savings Basic rate 2430 48600",
            "dividends Dividend Allowance 500 0",
            "dividends Basic rate 2500 21875"
        ])
        XCTAssertEqual(c.incomeTaxCharged, 48_600 + 48_600 + 21_875)

        // A higher-rate taxpayer gets £500 of savings allowance and no starting rate.
        let higher = SelfAssessment.calculate(.init(startYear: 2024, employments: [.init(employerName: "Example Ltd", pay: pounds(60_000), taxDeducted: 0)],
                                                    savingsIncome: pounds(1_000)), rules: rules2024).calculation
        XCTAssertEqual(higher.bandLines.filter { $0.kind == .savings }.map(\.band), ["Personal Savings Allowance", "Higher rate"])
        XCTAssertEqual(higher.bandLines.filter { $0.kind == .savings }.map(\.amount), [pounds(500), pounds(500)])
    }

    func testRefundWhenTooMuchWasDeducted() {
        let inputs = SelfAssessment.Inputs(startYear: 2024, employments: [.init(employerName: "Example Ltd", pay: pounds(20_000), taxDeducted: pounds(2_000))])
        let result = SelfAssessment.calculate(inputs, rules: rules2024)
        XCTAssertEqual(result.calculation.selfAssessmentLiability, -pounds(514))
        XCTAssertEqual(result.box(.sa110, "2")?.value, .amount(pounds(514)))
        XCTAssertEqual(result.calculation.nextPaymentOnAccount, 0)
    }

    func testTwoForeignSourcesHighestRateIsTheTopSlice() {
        let inputs = SelfAssessment.Inputs(
            startYear: 2024,
            employments: [.init(employerName: "Example Ltd", pay: pounds(50_000), taxDeducted: pounds(7_486))],
            properties: [.init(name: "Property A", country: "PT", income: pounds(5_000), expenses: 0, financeCosts: 0, foreignTax: pounds(500)),
                         .init(name: "Property B", country: "ES", income: pounds(5_000), expenses: 0, financeCosts: 0, foreignTax: pounds(2_500))])
        let result = SelfAssessment.calculate(inputs, rules: rules2024)
        // £60,000 total, £47,430 taxable: £9,730 at the higher rate. B (50% foreign rate) is the
        // top slice: its £5,000 is all higher rate → £2,000; then A: £4,730 higher + £270 basic → £1,946.
        XCTAssertEqual(result.foreignTaxCredits.map(\.name), ["Property B", "Property A"])
        XCTAssertEqual(result.foreignTaxCredits.map(\.ukTaxOnIncome), [pounds(2_000), pounds(1_946)])
        XCTAssertEqual(result.foreignTaxCredits.map(\.credit), [pounds(2_000), pounds(500)])
        XCTAssertEqual(result.box(.sa106, "A", section: "Foreign Tax Credit Relief: Property B")?.value, .text("ESP"))
    }

    // MARK: Review fixes

    func testWholePoundRoundingFollowsTheReturnNotes() {
        let inputs = SelfAssessment.Inputs(
            startYear: 2024,
            employments: [.init(employerName: "Example Ltd", pay: 3_000_099, taxDeducted: 348_601, benefitsByBox: [11: 10_050])],
            properties: [.init(name: "Property A", country: "PT", income: 500_075, expenses: 100_001, financeCosts: 50_001, foreignTax: 25_001,
                               usesTraditionalAccounting: true)],
            propertyLossBroughtForward: 10_001)
        let result = SelfAssessment.calculate(inputs, rules: rules2024)
        XCTAssertEqual(result.box(.sa102, "1")?.value, .amount(3_000_000))
        XCTAssertEqual(result.box(.sa102, "2")?.value, .amount(348_700))
        XCTAssertEqual(result.box(.sa102, "11")?.value, .amount(10_000))
        XCTAssertEqual(result.box(.sa106, "14")?.value, .amount(500_000))
        XCTAssertEqual(result.box(.sa106, "14.2")?.value, .cross)
        XCTAssertEqual(result.box(.sa106, "17")?.value, .amount(100_100))
        XCTAssertEqual(result.box(.sa106, "24.1")?.value, .amount(50_100))
        XCTAssertEqual(result.box(.sa106, "26")?.value, .amount(10_100))
        XCTAssertEqual(result.box(.sa106, "C")?.value, .amount(25_100))
        // Profit £3,999; less £101 brought forward = £3,898 (boxes 27 and 30).
        XCTAssertEqual(result.box(.sa106, "F")?.value, .amount(399_900))
        XCTAssertEqual(result.box(.sa106, "27")?.value, .amount(389_800))
        XCTAssertEqual(result.box(.sa106, "30")?.value, .amount(389_800))
        XCTAssertEqual(result.steps.first?.title, "Whole pounds")
        XCTAssertEqual(result.inputs.employments[0].pay, 3_000_000)

        // A refund on the P60 (negative box 2) rounds its size down.
        XCTAssertEqual(SelfAssessment.Inputs.up(-12_345), -12_300)
        var exact = inputs
        exact.roundToWholePounds = false
        XCTAssertEqual(SelfAssessment.calculate(exact, rules: rules2024).box(.sa102, "1")?.value, .amount(3_000_099))
    }

    func testLossLeavesColumnFAndBox27Blank() {
        let inputs = SelfAssessment.Inputs(
            startYear: 2024, employments: [.init(employerName: "Example Ltd", pay: pounds(30_000), taxDeducted: 0)],
            properties: [.init(name: "Property A", country: "PT", income: pounds(1_000), expenses: pounds(1_500), financeCosts: 0, foreignTax: pounds(50))])
        let result = SelfAssessment.calculate(inputs, rules: rules2024)
        XCTAssertNil(result.box(.sa106, "F"))
        XCTAssertNil(result.box(.sa106, "27"))
        XCTAssertEqual(result.box(.sa106, "25")?.value, .amount(-pounds(500)))
        XCTAssertEqual(result.box(.sa106, "30")?.value, .amount(0))
        XCTAssertNil(result.box(.sa106, "14.2"))
    }

    func testQuestionsPensionStepAndForeignTaxBasis() {
        let inputs = SelfAssessment.Inputs(
            startYear: 2024, employments: [.init(employerName: "Example Ltd", pay: pounds(110_000), taxDeducted: 0)],
            properties: [.init(name: "Property A", country: "PT", income: pounds(1_000), expenses: 0, financeCosts: 0, foreignTax: pounds(100))],
            grossPensionContributions: pounds(10_000))
        let result = SelfAssessment.calculate(inputs, rules: rules2024)
        XCTAssertEqual(result.box(.sa100, "Q1")?.label, "Employment: Yes, number of pages 1")
        XCTAssertEqual(result.box(.sa100, "Q5")?.label, "Foreign: Yes")
        let allowance = result.steps.first { $0.title == "Personal Allowance" }!.detail
        XCTAssertTrue(allowance.hasPrefix("Total income £111,000.00 − gross pension contributions £10,000.00 = adjusted net income £101,000.00."), allowance)
        XCTAssertTrue(result.steps.contains { $0.title == "Foreign tax basis" && $0.detail.contains("INTM161220") })
    }

    func testLossOnOnePropertyIsSetOffInColumnFLowestForeignRateFirst() {
        let inputs = SelfAssessment.Inputs(
            startYear: 2024, employments: [.init(employerName: "Example Ltd", pay: pounds(30_000), taxDeducted: 0)],
            properties: [.init(name: "Property A", country: "PT", income: pounds(6_000), expenses: pounds(1_000), financeCosts: 0, foreignTax: pounds(500)),
                         .init(name: "Property B", country: "ES", income: pounds(1_000), expenses: pounds(3_000), financeCosts: 0, foreignTax: 0),
                         .init(name: "Property C", country: "FR", income: pounds(1_000), expenses: 0, financeCosts: 0, foreignTax: pounds(300))])
        let result = SelfAssessment.calculate(inputs, rules: rules2024)
        // A +£5,000 (10% foreign tax), B −£2,000, C +£1,000 (30%): the loss comes off A first.
        XCTAssertEqual(result.box(.sa106, "F", section: "Foreign Tax Credit Relief: Property A")?.value, .amount(pounds(3_000)))
        XCTAssertNil(result.box(.sa106, "F", section: "Foreign Tax Credit Relief: Property B"))
        XCTAssertEqual(result.box(.sa106, "F", section: "Foreign Tax Credit Relief: Property C")?.value, .amount(pounds(1_000)))
        XCTAssertEqual(result.box(.sa106, "B", section: "Foreign Tax Credit Relief: Property B")?.value, .amount(-pounds(2_000)))
        XCTAssertEqual(result.box(.sa106, "30")?.value, .amount(pounds(4_000)))
        XCTAssertEqual(result.box(.sa106, "27")?.value, .amount(pounds(4_000)))
        // B has no relief step: its rows explain with the property step.
        XCTAssertEqual(result.box(.sa106, "B", section: "Foreign Tax Credit Relief: Property B")?.step, "Land and property abroad")
        XCTAssertEqual(result.box(.sa106, "B", section: "Foreign Tax Credit Relief: Property A")?.step, "Foreign Tax Credit Relief: Property A")
        XCTAssertEqual(SelfAssessment.columnF([.init(name: "A", country: "PT", income: pounds(5_000), expenses: 0, financeCosts: 0, foreignTax: 0),
                                               .init(name: "B", country: "PT", income: 0, expenses: pounds(2_000), financeCosts: 0, foreignTax: 0)]),
                       [pounds(3_000), 0])
    }

    func testTwoJobsGetTheirOwnStepsAndPensionsRoundUp() {
        let inputs = SelfAssessment.Inputs(startYear: 2024, employments: [.init(employerName: "Example Ltd", pay: pounds(10_000), taxDeducted: 0),
                                                                          .init(employerName: "Example Ltd", pay: pounds(5_000), taxDeducted: 0)],
                                           grossPensionContributions: 100_001)
        let result = SelfAssessment.calculate(inputs, rules: rules2024)
        XCTAssertEqual(result.inputs.grossPensionContributions, 100_100)
        XCTAssertEqual(result.box(.sa102, "1", section: "Employment 2: Example Ltd")?.step, "Employment 2: Example Ltd")
        XCTAssertTrue(result.steps.contains { $0.title == "Employment 1: Example Ltd" })
        XCTAssertEqual(result.box(.sa100, "Q1")?.value, .text("2"))
    }

    // MARK: From the records

    func testComputeFromTheRecordsBringsForwardFinanceCosts() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let result = try manager.dbQueue.write { db -> SelfAssessment.Result in
            var person = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &person)
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            _ = try Properties.setOwners(db: db, propertyId: property.id!, [PropertyOwner(propertyId: property.id!, personId: person.id!, shareBasisPoints: 10_000)])
            for year in [2023, 2024] {
                var rate = HMRCRate(startYear: year, currencyCode: "EUR", gbpPerUnit: 0.85, source: .manual)
                try rate.insert(db)
                var employment = Employment(startYear: year, personId: person.id!, employerName: "Example Ltd")
                try Employments.save(db: db, &employment)
                var income = EmploymentIncome(employmentId: employment.id!, source: .p60, payMinorUnits: pounds(30_000), taxDeductedMinorUnits: pounds(3_486))
                try Employments.save(db: db, &income)
                for (type, amount) in [(TaxExpenseType.rentalIncome, 5_000), (.otherExpense, year == 2023 ? 4_000 : 1_000), (.financeCost, 3_000)] {
                    var item = TaxManualItem(startYear: year, personId: person.id!, propertyId: property.id!, expenseType: type, label: "\(type.rawValue)",
                                             amountMinorUnits: pounds(amount), currency: .gbp)
                    try TaxManualItems.save(db: db, &item)
                }
            }
            var poa = HMRCPayment(personId: person.id!, startYear: 2024, date: MonthRange.calendar.date(from: DateComponents(year: 2025, month: 1, day: 31))!,
                                  amountMinorUnits: pounds(100), kind: .firstPaymentOnAccount)
            try HMRCPayments.save(db: db, &poa)
            return try SelfAssessment.compute(db: db, startYear: 2024, personId: person.id!)
        }
        // 2023/24: profit £1,000 limits the relief; £2,000 carried into 2024/25.
        XCTAssertEqual(result.inputs.financeCostsBroughtForward, pounds(2_000))
        XCTAssertEqual(result.inputs.properties.map(\.income), [pounds(5_000)])
        XCTAssertEqual(result.calculation.financeCostReliefBase, pounds(4_000))
        XCTAssertEqual(result.calculation.financeCostReduction, pounds(800))
        XCTAssertEqual(result.calculation.paymentsOnAccountMade, pounds(100))
        // Charged: £34,000 − £12,570 = £21,430 × 20% = £4,286; − £800 = £3,486 = PAYE.
        XCTAssertEqual(result.calculation.selfAssessmentLiability, 0)
        XCTAssertEqual(result.calculation.balancingPayment, -pounds(100))

        XCTAssertThrowsError(try manager.dbQueue.read { try SelfAssessment.compute(db: $0, startYear: 2019, personId: 1) }) {
            XCTAssertEqual($0 as? SelfAssessment.ComputeError, .noRulesForYear(2019))
        }
    }
}
