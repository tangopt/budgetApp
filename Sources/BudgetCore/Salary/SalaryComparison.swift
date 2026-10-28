import Foundation

/// Two salaries side by side: what the person has now and an offer. Amounts pence.
public struct SalaryComparison: Equatable, Sendable {
    public var current: SalaryResult
    public var offer: SalaryResult
    /// Offer take-home minus current, a month (negative when the offer pays less).
    public var monthlyDifference: Int
    /// Offer take-home minus current, a year.
    public var annualDifference: Int
    /// Of each extra £1 of gross pay on the offer, how much is kept, in basis points (5 800 = 58p).
    public var keepPerExtraPound: Int

    public static func make(current: SalaryResult, offer: SalaryResult) -> SalaryComparison {
        let annual = offer.takeHomeAnnual - current.takeHomeAnnual
        return SalaryComparison(
            current: current, offer: offer,
            monthlyDifference: SalaryCalculator.roundHalfUp(annual, 12),
            annualDifference: annual,
            keepPerExtraPound: offer.keepPerExtraPoundBP)
    }
}

/// Where a year's gross pay goes, for the "where the money goes" bar.
public enum SalaryBarSegments {
    /// Take-home, income tax, NI, loans and the employee pension: they add up to the gross pay.
    public static func segments(_ result: SalaryResult) -> [(label: String, pence: Int)] {
        [
            (label: "Take-home", pence: result.takeHomeAnnual),
            (label: "Income tax", pence: result.incomeTax),
            (label: "National Insurance", pence: result.employeeNI),
            (label: "Loans", pence: result.studentLoan + result.postgraduateLoan),
            (label: "Pension", pence: result.employeePension)
        ]
    }
}

extension SalaryInputs {
    /// The tax year in force on `today`, among the years the rules cover (the earliest when none
    /// has started yet).
    public static func defaultTaxYear(today: Date = Date()) -> Int {
        let years = SalaryRules.all.map(\.startYear).sorted()
        return years.last { UKTaxYear(startYear: $0).start <= today } ?? years[0]
    }

    /// A starting point to edit: £40,000 in the current tax year, England, 1257L.
    public static func typicalCurrent(today: Date = Date()) -> SalaryInputs {
        SalaryInputs(grossAnnual: 4_000_000, taxYearStart: defaultTaxYear(today: today))
    }
}

/// "Edit offer…" on a job-offer scenario: the scenario and the spec whose salaries the simulator shows.
public struct SalaryOfferEdit: Equatable, Sendable {
    public let scenarioId: Int64
    public let scenarioName: String
    public let spec: OfferScenarioSpec

    public init(scenarioId: Int64, scenarioName: String, spec: OfferScenarioSpec) {
        self.scenarioId = scenarioId
        self.scenarioName = scenarioName
        self.spec = spec
    }
}

/// The salary simulator's two columns. The offer starts as a copy of the current salary; the
/// comparison is recomputed whenever either side changes.
///
/// With a `SalaryDraftStore` the two salaries are kept on this device as they change (after `saveDelay`) and come
/// back next time; the draft wins over the prefill until "Reset". The prefill is the signed-in person's own latest
/// P60 or payslip (`SalaryPrefill`), offered by the host through `loadPrefill`; nothing is written back to the database.
///
/// "Edit offer…" (`beginOfferEdit`) shows a scenario's stored salaries without touching the draft: what was on show
/// is kept aside and comes back when editing stops without saving (`endOfferEdit(saved: false)`).
@MainActor @Observable
public final class SalaryComparisonViewModel {
    public var current: SalaryInputs { didSet { changed() } }
    public var offer: SalaryInputs { didSet { changed() } }
    public private(set) var comparison: SalaryComparison
    /// The signed-in person's latest pay as inputs; nil when there is none or the person isn't known.
    public private(set) var prefill: SalaryInputs?

    /// The host's way to read the signed-in person's prefill (their own employment data only); nil person means unknown.
    @ObservationIgnored public var loadPrefill: (() async -> (personId: Int64?, inputs: SalaryInputs?))?
    /// Drafts are written only while this is true (off in demo data).
    @ObservationIgnored public var savesDrafts = true

    @ObservationIgnored private let store: SalaryDraftStore?
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var applying = false
    /// Edited or restored from a draft: the prefill no longer replaces the columns by itself.
    @ObservationIgnored private var touched = false
    @ObservationIgnored private var owner: Int64?
    /// The job-offer scenario being edited; nil when the simulator shows the person's own draft.
    public private(set) var offerEdit: SalaryOfferEdit?
    /// What was on show before `beginOfferEdit`, and whether it had been edited.
    @ObservationIgnored private var stashed: (current: SalaryInputs, offer: SalaryInputs, touched: Bool)?

    public init(current: SalaryInputs = .typicalCurrent(), offer: SalaryInputs? = nil,
                store: SalaryDraftStore? = nil, saveDelay: Duration = .milliseconds(500)) {
        self.store = store
        self.saveDelay = saveDelay
        let draft = store?.load()
        let start = draft?.current ?? current
        let second = draft?.offer ?? offer ?? current
        self.current = start
        self.offer = second
        owner = draft?.personId
        touched = draft != nil
        comparison = .make(current: SalaryCalculator.calculate(start), offer: SalaryCalculator.calculate(second))
    }

    /// Whether each side has pay to work from.
    public var ready: (current: Bool, offer: Bool) {
        (current.grossAnnual + current.bonusPay > 0, offer.grossAnnual + offer.bonusPay > 0)
    }

    /// The "Use my latest payslip/P60" button shows when there is a prefill the Current column doesn't already hold.
    public var canUsePrefill: Bool { prefill != nil && prefill != current }

    public var resetTitle: String { prefill == nil ? "Reset" : "Reset to my latest pay" }

    /// Said under the button: what the prefill can't know.
    public static let prefillNote = "Pension and student loan aren't on your payslip data; check them."

    /// Puts the latest pay in the Current column (the offer follows when it still equalled Current).
    public func usePrefill() {
        guard let prefill else { return }
        let followed = offer == current
        current = prefill
        if followed { offer = prefill }
    }

    /// Shows `edit`'s stored salaries to edit for its scenario. The draft (and what was on show) is kept aside, a
    /// pending draft write done first; edits made meanwhile are not saved as the draft.
    public func beginOfferEdit(_ edit: SalaryOfferEdit) {
        if offerEdit == nil {
            if touched { flushDraft() }
            stashed = (current, offer, touched)
        }
        offerEdit = edit
        touched = true   // the prefill doesn't replace what is being edited
        applying = true
        current = edit.spec.current
        offer = edit.spec.offer
        applying = false
        recompute()
    }

    /// Stops editing the scenario. Saved: the salaries on show stay and become the draft. Not saved: what was on
    /// show before comes back, and the draft is as it was.
    public func endOfferEdit(saved: Bool) {
        guard offerEdit != nil else { return }
        offerEdit = nil
        let before = stashed
        stashed = nil
        if saved {
            flushDraft()
        } else if let before {
            applying = true
            current = before.current
            offer = before.offer
            applying = false
            touched = before.touched
            recompute()
        }
    }

    /// Back to the starting point: the person's latest pay (else the typical salary) on both sides; the draft goes.
    public func reset() {
        offerEdit = nil
        stashed = nil
        saveTask?.cancel()
        store?.clear()
        touched = false
        apply(prefill ?? .typicalCurrent())
    }

    /// Reads the prefill through `loadPrefill`. A draft made for another person goes; with no draft or edit yet, the
    /// prefill fills both columns.
    public func refreshPrefill() async {
        guard let loadPrefill else { return }
        let loaded = await loadPrefill()
        setPrefill(loaded.inputs, for: loaded.personId)
    }

    func setPrefill(_ inputs: SalaryInputs?, for personId: Int64?) {
        var dropped = false
        // A draft made for someone else, or shown to a viewer who isn't known, goes.
        if let owner, owner != personId { discard(); dropped = true }
        owner = personId
        let hadPrefill = prefill != nil
        prefill = inputs
        guard !touched else { return }
        if let inputs { apply(inputs) } else if hadPrefill || dropped { apply(.typicalCurrent()) }
    }

    /// Sign-out, leaving the household, demo data: the draft, the prefill and what is on show all go.
    public func forget() {
        offerEdit = nil
        stashed = nil
        discard()
        prefill = nil
        owner = nil
        apply(.typicalCurrent())
    }

    /// Writes the draft now (what the delay would do).
    public func flushDraft() {
        saveTask?.cancel()
        // No owner, no draft: what an unknown viewer types isn't kept for whoever comes next. A scenario's
        // salaries being edited aren't the draft.
        guard savesDrafts, let store, owner != nil, offerEdit == nil else { return }
        store.save(SalaryDraft(current: current, offer: offer, personId: owner))
    }

    private func discard() {
        saveTask?.cancel()
        store?.clear()
        touched = false
    }

    private func apply(_ inputs: SalaryInputs) {
        applying = true
        current = inputs
        offer = inputs
        applying = false
        recompute()
    }

    private func changed() {
        recompute()
        guard !applying else { return }
        touched = true
        guard store != nil, savesDrafts, offerEdit == nil else { return }
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flushDraft()
        }
    }

    private func recompute() {
        comparison = .make(current: SalaryCalculator.calculate(current), offer: SalaryCalculator.calculate(offer))
    }
}
