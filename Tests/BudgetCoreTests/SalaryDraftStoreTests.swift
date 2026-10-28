import XCTest
@testable import BudgetCore

@MainActor
final class SalaryDraftStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "salary-draft-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private var draft: SalaryDraft {
        var offer = SalaryInputs(grossAnnual: 6_000_000, bonusAnnual: 500_000, taxYearStart: 2025, region: .scotland, taxCode: "S1257L")
        offer.pension = .fixedAnnual(pence: 300_000)
        offer.studentLoan = .plan2
        return SalaryDraft(current: SalaryInputs(grossAnnual: 4_000_000, taxYearStart: 2025), offer: offer, personId: 3)
    }

    func testRoundTrip() {
        let store = SalaryDraftStore(defaults: defaults)
        XCTAssertNil(store.load())
        store.save(draft)
        XCTAssertEqual(store.load(), draft)
    }

    func testCorruptDataIgnored() {
        defaults.set(Data("not json".utf8), forKey: SalaryDraftStore.defaultKey)
        XCTAssertNil(SalaryDraftStore(defaults: defaults).load())
        defaults.set("a string", forKey: SalaryDraftStore.defaultKey)
        XCTAssertNil(SalaryDraftStore(defaults: defaults).load())
    }

    func testClear() {
        let store = SalaryDraftStore(defaults: defaults)
        store.save(draft)
        store.clear()
        XCTAssertNil(store.load())
    }

    // MARK: View model

    func testEditsAreSavedAfterTheDelayAndRestored() async throws {
        let store = SalaryDraftStore(defaults: defaults)
        let model = SalaryComparisonViewModel(store: store, saveDelay: .milliseconds(20))
        model.setPrefill(nil, for: 3)
        model.offer.grossAnnual = 7_000_000
        XCTAssertNil(store.load(), "debounced")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(store.load()?.offer.grossAnnual, 7_000_000)
        let again = SalaryComparisonViewModel(store: store)
        XCTAssertEqual(again.offer.grossAnnual, 7_000_000)
    }

    /// "Edit offer…": the scenario's salaries are shown without touching the draft; stopping without saving brings
    /// back what was on show, saving keeps the edited salaries as the draft.
    func testOfferEditKeepsTheDraftAside() async throws {
        let store = SalaryDraftStore(defaults: defaults)
        store.save(draft)
        let model = SalaryComparisonViewModel(store: store, saveDelay: .milliseconds(1))
        model.setPrefill(nil, for: 3)
        let spec = OfferScenarioSpec(current: SalaryInputs(grossAnnual: 3_000_000, taxYearStart: 2026),
                                     offer: SalaryInputs(grossAnnual: 8_000_000, taxYearStart: 2026),
                                     salaryEntryId: 1, pensionEntryId: nil, startMonth: Date(timeIntervalSince1970: 1_800_000_000))
        let edit = SalaryOfferEdit(scenarioId: 4, scenarioName: "Big job", spec: spec)
        model.beginOfferEdit(edit)
        XCTAssertEqual(model.offerEdit, edit)
        XCTAssertEqual(model.offer, spec.offer)
        XCTAssertEqual(model.current, spec.current)
        model.offer.grossAnnual = 8_500_000
        model.setPrefill(SalaryInputs(grossAnnual: 1, taxYearStart: 2026), for: 3)
        XCTAssertEqual(model.offer.grossAnnual, 8_500_000, "the prefill doesn't replace what is being edited")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.load(), draft, "edits to a scenario's salaries aren't the draft")

        model.endOfferEdit(saved: false)
        XCTAssertNil(model.offerEdit)
        XCTAssertEqual(model.offer, draft.offer)
        XCTAssertEqual(model.current, draft.current)
        XCTAssertEqual(store.load(), draft)

        model.beginOfferEdit(edit)
        model.offer.grossAnnual = 9_000_000
        model.endOfferEdit(saved: true)
        XCTAssertNil(model.offerEdit)
        XCTAssertEqual(model.offer.grossAnnual, 9_000_000)
        XCTAssertEqual(store.load()?.offer.grossAnnual, 9_000_000)
    }

    func testDraftWinsOverPrefillUntilReset() {
        let store = SalaryDraftStore(defaults: defaults)
        store.save(draft)
        let model = SalaryComparisonViewModel(store: store)
        let pay = SalaryInputs(grossAnnual: 5_000_000, taxYearStart: 2025)
        model.setPrefill(pay, for: 3)
        XCTAssertEqual(model.current.grossAnnual, 4_000_000, "the draft stays")
        XCTAssertTrue(model.canUsePrefill)
        model.reset()
        XCTAssertEqual(model.current, pay)
        XCTAssertEqual(model.offer, pay)
        XCTAssertNil(store.load())
    }

    func testPrefillFillsBothColumnsWithoutADraftAndSavesNothing() {
        let store = SalaryDraftStore(defaults: defaults)
        let model = SalaryComparisonViewModel(store: store, saveDelay: .milliseconds(1))
        let pay = SalaryInputs(grossAnnual: 5_000_000, taxYearStart: 2025)
        model.setPrefill(pay, for: 3)
        model.flushDraft()
        XCTAssertEqual(model.current, pay)
        XCTAssertEqual(model.offer, pay)
        XCTAssertFalse(model.canUsePrefill)
        model.usePrefill()
        XCTAssertEqual(model.current, pay)
    }

    func testAnotherPersonsDraftIsDropped() {
        let store = SalaryDraftStore(defaults: defaults)
        store.save(draft)
        let model = SalaryComparisonViewModel(store: store)
        model.setPrefill(nil, for: 9)
        XCTAssertNil(store.load())
        XCTAssertEqual(model.current, .typicalCurrent())
    }

    func testUnknownViewerDropsAnOwnedDraftAndSavesNone() {
        let store = SalaryDraftStore(defaults: defaults)
        store.save(draft)
        let model = SalaryComparisonViewModel(store: store, saveDelay: .milliseconds(1))
        model.setPrefill(nil, for: nil)
        XCTAssertNil(store.load())
        XCTAssertEqual(model.current, .typicalCurrent())
        XCTAssertEqual(model.offer, .typicalCurrent())
        model.offer.grossAnnual = 9_000_000
        model.flushDraft()
        XCTAssertNil(store.load(), "no owner, no draft")
    }

    func testForgetClearsDraftAndPrefill() {
        let store = SalaryDraftStore(defaults: defaults)
        store.save(draft)
        let model = SalaryComparisonViewModel(store: store)
        model.setPrefill(SalaryInputs(grossAnnual: 5_000_000, taxYearStart: 2025), for: 3)
        model.forget()
        XCTAssertNil(store.load())
        XCTAssertNil(model.prefill)
        XCTAssertEqual(model.current, .typicalCurrent())
        XCTAssertFalse(model.canUsePrefill)
    }

    func testNothingSavedWhenDraftsAreOff() {
        let store = SalaryDraftStore(defaults: defaults)
        let model = SalaryComparisonViewModel(store: store, saveDelay: .milliseconds(1))
        model.savesDrafts = false
        model.current.grossAnnual = 1_000_000
        model.flushDraft()
        XCTAssertNil(store.load())
    }
}
