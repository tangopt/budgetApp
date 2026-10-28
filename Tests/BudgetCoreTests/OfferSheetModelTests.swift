import XCTest
@testable import BudgetCore

/// The "Try in Forecast…" sheet's state: what it preselects, when Save is allowed, the preview line and the
/// spec it hands the builder.
@MainActor
final class OfferSheetModelTests: XCTestCase {
    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private let current = SalaryInputs(grossAnnual: 3_200_000, taxYearStart: 2026)
    private let offer = SalaryInputs(grossAnnual: 4_200_000, taxYearStart: 2026)

    private func entry(id: Int64, amount: Int = 200_000, start: Date, group: Int64 = 1, account: Int64? = nil) -> ForecastEntry {
        ForecastEntry(id: id, groupId: group, categoryId: 1, amountMinorUnits: amount, frequency: .monthly, interval: 1,
                      startDate: start, endDate: nil, isEnabled: true, status: .confirmed, note: nil, accountId: account)
    }

    private func model(candidates: [ForecastEntry], offer: SalaryInputs? = nil, editing: (scenarioId: Int64, spec: OfferScenarioSpec)? = nil,
                       name: String? = nil, pensions: [OfferPensionCandidate] = []) -> OfferSheetModel {
        OfferSheetModel(offer: offer ?? self.offer, current: current, candidates: candidates, pensionCandidates: pensions,
                        editing: editing, scenarioName: name, today: utc(2026, 3, 14))
    }

    func testPreselectsMostRecentSalaryEntry() {
        let m = model(candidates: [entry(id: 1, start: utc(2024, 1, 1)), entry(id: 2, start: utc(2026, 1, 1)), entry(id: 3, start: utc(2025, 1, 1))])
        XCTAssertEqual(m.salaryEntryId, 2)
        XCTAssertEqual(m.startMonth, utc(2026, 4, 1))
        XCTAssertEqual(m.name, "Job offer Apr 2026")
        XCTAssertTrue(m.canSave)
    }

    func testCannotSaveWithEmptyNameOrNoSalaryAndNoNewIncome() {
        let m = model(candidates: [entry(id: 1, start: utc(2026, 1, 1))])
        m.name = "   "
        XCTAssertFalse(m.canSave)
        m.name = "Offer"
        XCTAssertTrue(m.canSave)
        m.salaryEntryId = nil
        XCTAssertFalse(m.canSave)
        m.newIncomeCategoryId = 5
        XCTAssertTrue(m.canSave)
        XCTAssertEqual(model(candidates: []).canSave, false)
    }

    func testPreviewWording() {
        let takeHome = SalaryCalculator.calculate(offer).takeHomeMonthly
        let m = model(candidates: [entry(id: 1, amount: 200_000, start: utc(2026, 1, 1))])
        XCTAssertEqual(m.preview, "From Apr 2026: \(Money.format(takeHome, currency: .gbp)) a month net, was £2,000.00")
        m.startMonth = utc(2026, 6, 9)
        XCTAssertEqual(m.startMonth, utc(2026, 6, 1))
        m.noticeGapMonths = 1
        XCTAssertTrue(m.preview.hasPrefix("From Jul 2026: "))
        // The entry pays more than the offer: said as "less".
        let higher = entry(id: 1, amount: takeHome + 20_000, start: utc(2026, 1, 1))
        let lower = model(candidates: [higher])
        XCTAssertEqual(lower.preview, "From Apr 2026: \(Money.format(takeHome, currency: .gbp)) a month net, £200.00 less than \(Money.format(takeHome + 20_000, currency: .gbp))")
        m.salaryEntryId = nil
        XCTAssertTrue(m.preview.hasSuffix("new income"))
    }

    /// "Edit offer…": the salaries are the simulator's (just edited there); the rest is the stored spec's.
    func testEditModeKeepsNameAndSpecAndTakesTheSimulatorsSalaries() {
        let stored = OfferScenarioSpec(current: current, offer: offer, salaryEntryId: 2, pensionEntryId: nil, startMonth: utc(2026, 9, 1),
                                       noticeGapMonths: 2, oneOffs: [OfferOneOff(label: "Relocation", amountMinorUnits: 100_000, month: utc(2026, 9, 1))],
                                       addedEntryIds: [40, 41])
        let edited = SalaryInputs(grossAnnual: 9_900_000, taxYearStart: 2026)
        let m = model(candidates: [entry(id: 2, start: utc(2026, 1, 1))], offer: edited, editing: (7, stored), name: "Better job")
        XCTAssertEqual(m.name, "Better job")
        XCTAssertEqual(m.editingScenarioId, 7)
        XCTAssertEqual(m.offer, edited)
        XCTAssertEqual(m.current, current)
        m.startMonth = utc(2026, 9, 1)
        XCTAssertEqual(m.name, "Better job")
        var expected = stored.inputs
        expected.offer = edited
        XCTAssertEqual(m.spec(), expected)
        XCTAssertTrue(m.subtitle.contains("are replaced"))
        XCTAssertFalse(model(candidates: []).subtitle.contains("replaced"))
    }

    /// The pension is left alone unless chosen; an expense is a choice only with a salary in its group or account,
    /// a transfer into a pension account always; a choice that no longer fits the salary goes.
    func testPensionChoices() {
        let salaryA = entry(id: 1, start: utc(2026, 1, 1), group: 1, account: 9)
        let salaryB = entry(id: 2, start: utc(2025, 1, 1), group: 2)
        let sameGroup = OfferPensionCandidate(entry: entry(id: 10, amount: -10_000, start: utc(2026, 1, 1), group: 1), isTransfer: false)
        let sameAccount = OfferPensionCandidate(entry: entry(id: 11, amount: -10_000, start: utc(2026, 1, 1), group: 5, account: 9), isTransfer: false)
        let elsewhere = OfferPensionCandidate(entry: entry(id: 12, amount: -10_000, start: utc(2026, 1, 1), group: 6), isTransfer: false)
        let transfer = OfferPensionCandidate(entry: entry(id: 13, amount: -10_000, start: utc(2026, 1, 1), group: 6), isTransfer: true)
        let m = model(candidates: [salaryA, salaryB], pensions: [sameGroup, sameAccount, elsewhere, transfer])
        XCTAssertEqual(m.salaryEntryId, 1)
        XCTAssertNil(m.pensionEntryId)
        XCTAssertNil(m.pensionNote)
        XCTAssertEqual(m.pensionChoices.map(\.id), [10, 11, 13])
        m.pensionEntryId = 10
        XCTAssertEqual(m.pensionNote?.contains("difference"), true)
        m.salaryEntryId = 2
        XCTAssertEqual(m.pensionChoices.map(\.id), [13])
        XCTAssertNil(m.pensionEntryId)
        m.pensionEntryId = 13
        XCTAssertEqual(m.pensionNote?.contains("employer"), true)
        m.salaryEntryId = nil
        XCTAssertEqual(m.pensionEntryId, 13)
        XCTAssertEqual(m.spec().pensionEntryId, 13)
    }

    func testSpecCarriesOneOffAndGap() {
        let m = model(candidates: [entry(id: 1, start: utc(2026, 1, 1))])
        m.noticeGapMonths = 2
        m.signingBonus = 500_000
        let spec = m.spec()
        XCTAssertEqual(spec.noticeGapMonths, 2)
        // Paid with the first new salary: after the gap.
        XCTAssertEqual(spec.oneOffs, [OfferOneOff(label: "Signing bonus", amountMinorUnits: 500_000, month: utc(2026, 6, 1))])
        XCTAssertEqual(spec.salaryEntryId, 1)
        XCTAssertEqual(spec.startMonth, utc(2026, 4, 1))
        m.signingBonus = 0
        XCTAssertTrue(m.spec().oneOffs.isEmpty)
        m.noticeGapMonths = -3
        XCTAssertEqual(m.noticeGapMonths, 0)
    }
}
