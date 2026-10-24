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

        XCTAssertThrowsError(try manager.dbQueue.read { try SelfAssessment.compute(db: $0, startYear: 2014, personId: 1) }) {
            XCTAssertEqual($0 as? SelfAssessment.ComputeError, .noRulesForYear(2014))
        }
    }

    // MARK: The relief as filed

    /// A return that claimed the whole foreign tax although HS263 limits the relief to the UK
    /// tax on the foreign income: the year is reproduced as filed, with a warning and the
    /// app's own limit in the step.
    func testForeignTaxCreditReliefTakenAsFiledWhenTheReturnClaimedMore() {
        var inputs = SelfAssessment.Inputs(
            startYear: 2023,
            employments: [.init(employerName: "Example Ltd", pay: pounds(14_000), taxDeducted: pounds(300))],
            properties: [.init(name: "Property A", country: "PT", income: pounds(12_000), expenses: pounds(1_500),
                               financeCosts: pounds(4_000), foreignTax: pounds(1_500))])
        // Taxable £11,930 × 20% = £2,386; finance relief £800; UK tax on the rent £1,586 − £286 = £1,300: the limit.
        let own = SelfAssessment.calculate(inputs, rules: UKTaxRules.forYear(2023)!)
        XCTAssertEqual(own.calculation.foreignTaxCreditRelief, pounds(1_300))
        XCTAssertEqual(own.calculation.balancingPayment, -pounds(14))

        inputs.filedBoxes["sa106.F1.2"] = .init(value: pounds(1_500), note: "The accountant claimed the whole foreign tax.")
        let asFiled = SelfAssessment.calculate(inputs, rules: UKTaxRules.forYear(2023)!)
        XCTAssertEqual(asFiled.calculation.foreignTaxCreditRelief, pounds(1_500))
        XCTAssertEqual(asFiled.calculation.incomeTaxDue, pounds(86))
        XCTAssertEqual(asFiled.calculation.balancingPayment, -pounds(214))
        XCTAssertEqual(asFiled.box(.sa106, "2", section: "Foreign Tax Credit Relief")?.value, .amount(pounds(1_500)))
        XCTAssertTrue(asFiled.steps.contains { $0.title == "Foreign Tax Credit Relief as filed" && $0.detail.contains("£1,300.00") && $0.detail.contains("whole foreign tax") })
        XCTAssertEqual(asFiled.box(.sa106, "2", section: "Foreign Tax Credit Relief")?.asFiled, .init(computed: pounds(1_300), note: "The accountant claimed the whole foreign tax."))
        XCTAssertTrue(asFiled.warnings.contains { $0.contains("£200.00 more") }, asFiled.warnings.joined())
        // A claim above the tax due is cut to it.
        inputs.filedBoxes["sa106.F1.2"] = .init(value: pounds(5_000), note: "n")
        XCTAssertEqual(SelfAssessment.calculate(inputs, rules: UKTaxRules.forYear(2023)!).calculation.foreignTaxCreditRelief, pounds(1_586))
        // The same claim as the limit changes nothing and says nothing.
        inputs.filedBoxes["sa106.F1.2"] = .init(value: pounds(1_300), note: "n")
        let same = SelfAssessment.calculate(inputs, rules: UKTaxRules.forYear(2023)!)
        XCTAssertEqual(same.calculation, own.calculation)
        XCTAssertFalse(same.steps.contains { $0.title == "Foreign Tax Credit Relief as filed" })
    }

    /// Boxes entered as the return filed them: the rent and expenses of the one property replace
    /// the computed ones (the box keeps the computed value and the reason), and the SA302's
    /// foreign income can differ from the boxes without moving them.
    func testBoxesAsFiledReplaceTheComputedOnesAndKeepThem() {
        var inputs = SelfAssessment.Inputs(
            startYear: 2021,
            employments: [.init(employerName: "Example Ltd", pay: pounds(50_000), taxDeducted: pounds(8_000))],
            properties: [.init(name: "Property A", country: "PT", income: 1_000_050, expenses: 300_050, financeCosts: pounds(500), foreignTax: pounds(600))])
        let computed = SelfAssessment.calculate(inputs, rules: UKTaxRules.forYear(2021)!)
        XCTAssertEqual(computed.box(.sa106, "14")?.value, .amount(pounds(10_000)))
        XCTAssertEqual(computed.box(.sa106, "17")?.value, .amount(pounds(3_001)))
        XCTAssertNil(computed.box(.sa106, "14")?.asFiled)

        inputs.filedBoxes["sa106.14"] = .init(value: pounds(10_001), note: "The accountant rounded the half share up.")
        inputs.filedBoxes["sa106.17"] = .init(value: pounds(3_000), note: "The accountant rounded the half share down.")
        let asFiled = SelfAssessment.calculate(inputs, rules: UKTaxRules.forYear(2021)!)
        XCTAssertEqual(asFiled.box(.sa106, "14")?.value, .amount(pounds(10_001)))
        XCTAssertEqual(asFiled.box(.sa106, "14")?.asFiled, .init(computed: pounds(10_000), note: "The accountant rounded the half share up."))
        XCTAssertEqual(asFiled.box(.sa106, "17")?.value, .amount(pounds(3_000)))
        XCTAssertEqual(asFiled.box(.sa106, "17")?.asFiled?.computed, pounds(3_001))
        XCTAssertEqual(asFiled.box(.sa106, "24")?.value, .amount(pounds(7_001)))
        XCTAssertEqual(asFiled.calculation.propertyProfit, pounds(7_001))
        XCTAssertEqual(asFiled.calculation.totalIncome, pounds(57_001))
        XCTAssertTrue(asFiled.steps.contains { $0.title == "As filed" && $0.detail.contains("£10,001.00 as filed (computed £10,000.00)") })

        // The SA302 used another foreign income than the boxes give: the boxes stay, the calculation follows it.
        inputs.filedBoxes = ["calc.propertyProfit": .init(value: pounds(7_005), note: "The accountant's SA302 used £7,005.")]
        let sa302 = SelfAssessment.calculate(inputs, rules: UKTaxRules.forYear(2021)!)
        XCTAssertEqual(sa302.box(.sa106, "24")?.value, .amount(pounds(6_999)))
        XCTAssertEqual(sa302.box(.sa106, "27")?.value, .amount(pounds(6_999)))
        XCTAssertEqual(sa302.calculation.propertyProfit, pounds(7_005))
        XCTAssertEqual(sa302.calculation.totalIncome, pounds(57_005))
        // The UK tax on the foreign income (the FTCR limit) follows the profit the calculation used:
        // £270 of the £7,005 at 20% and £6,735 at 40%, less the £100 relief = £2,648.
        XCTAssertEqual(sa302.foreignTaxCredits.first?.ukTaxOnIncome, pounds(2_648))

        // Two properties: the property boxes can't be placed; a warning says so and nothing moves.
        inputs.filedBoxes = ["sa106.14": .init(value: pounds(1), note: "n")]
        inputs.properties.append(.init(name: "Property B", country: "PT", income: pounds(100), expenses: 0, financeCosts: 0, foreignTax: 0))
        let two = SelfAssessment.calculate(inputs, rules: UKTaxRules.forYear(2021)!)
        XCTAssertEqual(two.box(.sa106, "14")?.value, .amount(pounds(10_100)))
        XCTAssertTrue(two.warnings.contains { $0.contains("2 properties: left aside") })
    }

    /// Boxes stored as filed are read for a filed year only; an open year is worked out by the rules.
    func testBoxesAsFiledAreReadForFiledYearsOnly() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let (personId, propertyId) = try manager.dbQueue.write { db -> (Int64, Int64) in
            var person = Person(name: "Person A")
            try People.save(db: db, &person)
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            _ = try Properties.setOwners(db: db, propertyId: property.id!, [PropertyOwner(propertyId: property.id!, personId: person.id!, shareBasisPoints: 10_000)])
            try HMRCRates.set(db: db, startYear: 2024, currencyCode: "EUR", gbpPerUnit: 0.85, unitsPerPound: nil, source: .manual)
            var rent = TaxManualItem(startYear: 2024, personId: person.id!, propertyId: property.id!, expenseType: .rentalIncome, label: "Rent",
                                     amountMinorUnits: 1_000_000, currency: .gbp, isWholeProperty: true)
            try TaxManualItems.save(db: db, &rent)
            _ = try TaxFiledBoxes.set(db: db, startYear: 2024, personId: person.id!, field: "sa106.14", valueMinorUnits: 1_000_100, note: "Rounded up on the return.")
            return (person.id!, property.id!)
        }
        _ = propertyId
        let open = try manager.dbQueue.read { db in try SelfAssessment.compute(db: db, startYear: 2024, personId: personId) }
        XCTAssertEqual(open.box(.sa106, "14")?.value, .amount(1_000_000))
        XCTAssertTrue(open.warnings.contains { $0.contains("stored as filed") && $0.contains("isn't filed") }, open.warnings.joined())
        try manager.dbQueue.write { db in try TaxOverview.setStatus(db: db, startYear: 2024, personId: personId, status: .filed) }
        let filed = try manager.dbQueue.read { db in try SelfAssessment.compute(db: db, startYear: 2024, personId: personId) }
        XCTAssertEqual(filed.box(.sa106, "14")?.value, .amount(1_000_100))
        XCTAssertEqual(filed.box(.sa106, "14")?.asFiled?.note, "Rounded up on the return.")
    }

    /// A box stored as filed with the computed value is not tagged and adds no "As filed" line;
    /// whole-pound inputs with a box as filed add no "Whole pounds" step.
    func testBoxAsFiledTaggedOnlyWhenItDiffersAndNoSpuriousWholePounds() {
        var inputs = SelfAssessment.Inputs(
            startYear: 2021,
            employments: [.init(employerName: "Example Ltd", pay: pounds(50_000), taxDeducted: pounds(8_000))],
            properties: [.init(name: "Property A", country: "PT", income: pounds(10_000), expenses: pounds(3_000), financeCosts: pounds(500), foreignTax: pounds(600))])
        let computed = SelfAssessment.calculate(inputs, rules: UKTaxRules.forYear(2021)!)
        XCTAssertFalse(computed.steps.contains { $0.title == "Whole pounds" })

        inputs.filedBoxes["sa106.14"] = .init(value: pounds(10_000), note: "Same as computed.")
        let same = SelfAssessment.calculate(inputs, rules: UKTaxRules.forYear(2021)!)
        XCTAssertNil(same.box(.sa106, "14")?.asFiled)
        XCTAssertFalse(same.steps.contains { $0.title == "As filed" })
        XCTAssertEqual(same.calculation, computed.calculation)

        inputs.filedBoxes["sa106.14"] = .init(value: pounds(10_001), note: "Rounded up on the return.")
        let differs = SelfAssessment.calculate(inputs, rules: UKTaxRules.forYear(2021)!)
        XCTAssertEqual(differs.box(.sa106, "14")?.asFiled?.computed, pounds(10_000))
        XCTAssertTrue(differs.steps.contains { $0.title == "As filed" })
        // The inputs were whole pounds already: the filed box doesn't count as rounding.
        XCTAssertFalse(differs.steps.contains { $0.title == "Whole pounds" })
    }

    /// The carry-forward follows the filed return: a 2024/25 finance-cost box as filed changes
    /// the finance costs brought into 2025/26, with a step saying where they come from; with no
    /// boxes as filed nothing changes and no step is added.
    func testCarryForwardFollowsTheFiledReturn() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let personId = try manager.dbQueue.write { db -> Int64 in
            var person = Person(name: "Person A")
            try People.save(db: db, &person)
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            _ = try Properties.setOwners(db: db, propertyId: property.id!, [PropertyOwner(propertyId: property.id!, personId: person.id!, shareBasisPoints: 10_000)])
            try HMRCRates.set(db: db, startYear: 2024, currencyCode: "EUR", gbpPerUnit: 0.85, unitsPerPound: nil, source: .manual)
            var rent = TaxManualItem(startYear: 2024, personId: person.id!, propertyId: property.id!, expenseType: .rentalIncome, label: "Rent",
                                     amountMinorUnits: pounds(20_000), currency: .gbp, isWholeProperty: true)
            try TaxManualItems.save(db: db, &rent)
            var interest = TaxManualItem(startYear: 2024, personId: person.id!, propertyId: property.id!, expenseType: .financeCost, label: "Interest",
                                         amountMinorUnits: pounds(25_000), currency: .gbp, isWholeProperty: true)
            try TaxManualItems.save(db: db, &interest)
            try TaxOverview.setStatus(db: db, startYear: 2024, personId: person.id!, status: .filed)
            return person.id!
        }
        func years() throws -> (SelfAssessment.Result, SelfAssessment.Result) {
            try manager.dbQueue.read { db in
                (try SelfAssessment.compute(db: db, startYear: 2024, personId: personId),
                 try SelfAssessment.compute(db: db, startYear: 2025, personId: personId))
            }
        }
        // No boxes as filed: profit £20,000, income above the allowance £7,430 → £17,570 carried forward.
        let (plain2024, plain2025) = try years()
        XCTAssertEqual(plain2024.calculation.financeCostsCarriedForward, pounds(17_570))
        XCTAssertEqual(plain2025.inputs.financeCostsBroughtForward, pounds(17_570))
        XCTAssertNil(plain2025.inputs.broughtForwardFromFiledReturn)
        XCTAssertFalse(plain2025.steps.contains { $0.title == "Brought forward from the filed return" })

        // The filed return entered £24,000 of finance costs: £16,570 carried forward, and 2025/26 brings that in.
        try manager.dbQueue.write { db in
            _ = try TaxFiledBoxes.set(db: db, startYear: 2024, personId: personId, field: "sa106.24.1", valueMinorUnits: pounds(24_000),
                                      note: "The return entered less interest.")
        }
        let (filed2024, filed2025) = try years()
        XCTAssertEqual(filed2024.calculation.financeCostsCarriedForward, pounds(16_570))
        XCTAssertEqual(filed2025.inputs.financeCostsBroughtForward, pounds(16_570))
        XCTAssertEqual(filed2025.inputs.broughtForwardFromFiledReturn, "2024/25")
        XCTAssertTrue(filed2025.steps.contains { $0.title == "Brought forward from the filed return" && $0.detail.contains("£16,570.00") && $0.detail.contains("2024/25") },
                      filed2025.steps.map(\.title).joined(separator: ", "))
    }

    // MARK: Years before 2020/21: finance costs partly deductible

    /// 2017/18: 75% of the finance costs are an expense and the other 25% get the 20%
    /// reduction (the phasing of 2017/18–2019/20); the SA106 boxes show the split.
    func testFinanceCostsPartlyDeductibleIn2017() throws {
        let rules = try XCTUnwrap(UKTaxRules.forYear(2017))
        let inputs = SelfAssessment.Inputs(
            startYear: 2017,
            employments: [.init(employerName: "Example Ltd", pay: pounds(80_000), taxDeducted: pounds(20_000))],
            properties: [.init(name: "Property A", country: "PT", income: pounds(17_000), expenses: pounds(3_000),
                               financeCosts: pounds(2_000), foreignTax: 0)])
        let result = SelfAssessment.calculate(inputs, rules: rules)
        let c = result.calculation
        // 75% of £2,000 deducted: expenses £4,500, profit £12,500; £500 restricted → £100 reduction.
        XCTAssertEqual(result.box(.sa106, "17")?.value, .amount(pounds(4_500)))
        XCTAssertEqual(result.box(.sa106, "24")?.value, .amount(pounds(12_500)))
        XCTAssertEqual(result.box(.sa106, "24.1")?.value, .amount(pounds(500)))
        XCTAssertEqual(c.propertyProfit, pounds(12_500))
        XCTAssertEqual(c.financeCosts, pounds(500))
        XCTAssertEqual(c.financeCostReduction, pounds(100))
        XCTAssertEqual(c.totalIncome, pounds(92_500))
        XCTAssertEqual(c.personalAllowance, pounds(11_500))
        XCTAssertTrue(result.steps.contains { $0.title == "Finance costs" && $0.detail.contains("75%") })
    }

    /// 2015/16: finance costs are an ordinary expense (nothing restricted); a loss carries forward whole.
    func testFinanceCostsFullyDeductibleIn2015AndLossCarriesForward() throws {
        let rules = try XCTUnwrap(UKTaxRules.forYear(2015))
        let inputs = SelfAssessment.Inputs(
            startYear: 2015,
            employments: [.init(employerName: "Example Ltd", pay: pounds(60_000), taxDeducted: pounds(12_000))],
            properties: [.init(name: "Property A", country: "PT", income: pounds(3_000), expenses: pounds(4_000),
                               financeCosts: pounds(3_000), foreignTax: 0)])
        let result = SelfAssessment.calculate(inputs, rules: rules)
        let c = result.calculation
        XCTAssertEqual(result.box(.sa106, "17")?.value, .amount(pounds(7_000)))
        XCTAssertEqual(result.box(.sa106, "24")?.value, .amount(-pounds(4_000)))
        XCTAssertEqual(result.box(.sa106, "24.1")?.value, .amount(0))
        XCTAssertEqual(c.propertyProfit, 0)
        XCTAssertEqual(c.financeCostReduction, 0)
        XCTAssertEqual(c.financeCostsCarriedForward, 0)
        XCTAssertEqual(c.propertyLossCarriedForward, pounds(4_000))
        XCTAssertEqual(c.personalAllowance, pounds(10_600))
        XCTAssertEqual(c.incomeTaxCharged, pounds(31_785) * 20 / 100 + (pounds(60_000) - pounds(10_600) - pounds(31_785)) * 40 / 100)
    }
}
