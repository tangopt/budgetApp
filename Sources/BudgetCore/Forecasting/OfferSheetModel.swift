import Foundation
import Observation

/// The state of the "Try in Forecast…" sheet (spec 2026-10-28-step14-job-offer-forecast-design.md), kept apart
/// from SwiftUI so it can be tested: which salary entry the offer replaces, when it starts, a notice-period
/// gap, a signing bonus and the scenario's name. `spec()` is what `OfferScenarioBuilder` is given.
///
/// In edit mode ("Edit offer…" on a scenario) the salaries are the simulator's (the person has just edited them
/// there) and everything else starts from the stored spec and the scenario's name.
@MainActor @Observable
public final class OfferSheetModel {
    /// The one-off label the sheet's signing bonus field writes (and reads back when editing).
    public static let signingBonusLabel = "Signing bonus"

    public let offer: SalaryInputs
    public let current: SalaryInputs
    public let salaryCandidates: [ForecastEntry]
    public let pensionCandidates: [OfferPensionCandidate]
    /// Set in edit mode: the scenario being rebuilt.
    public let editingScenarioId: Int64?

    public var name: String
    /// The budget salary entry the offer replaces; nil = none (the offer is new income, in `newIncomeCategoryId`).
    public var salaryEntryId: Int64? {
        didSet { if let id = pensionEntryId, !pensionChoices.contains(where: { $0.id == id }) { pensionEntryId = nil } }
    }
    /// The budget pension entry the offer changes; nil = leave the pension alone (the default).
    public var pensionEntryId: Int64?
    /// The income category for "Add as new income" when `salaryEntryId` is nil.
    public var newIncomeCategoryId: Int64?
    /// First day of the new job's month (UTC); moving it renames a name still at its default.
    public var startMonth: Date {
        didSet {
            let month = Self.firstOfMonth(startMonth)
            if month != startMonth { startMonth = month; return }
            if name == Self.defaultName(for: oldValue) { name = Self.defaultName(for: startMonth) }
        }
    }
    /// Months from `startMonth` with no salary.
    public var noticeGapMonths: Int { didSet { if noticeGapMonths < 0 { noticeGapMonths = 0 } } }
    /// Pence; nil or 0 = none.
    public var signingBonus: Int?

    /// One-offs of a stored spec other than the signing bonus: kept as they were.
    private let otherOneOffs: [OfferOneOff]

    public init(offer: SalaryInputs, current: SalaryInputs, candidates: [ForecastEntry], pensionCandidates: [OfferPensionCandidate],
                editing: (scenarioId: Int64, spec: OfferScenarioSpec)?, scenarioName: String? = nil,
                newIncomeCategoryId: Int64? = nil, today: Date = Date()) {
        self.salaryCandidates = candidates
        self.pensionCandidates = pensionCandidates
        if let editing {
            let spec = editing.spec
            self.offer = offer
            self.current = current
            self.editingScenarioId = editing.scenarioId
            self.name = scenarioName ?? Self.defaultName(for: spec.startMonth)
            // An entry that has since left the budget is no longer a choice.
            let salary = candidates.first { $0.id == spec.salaryEntryId }
            self.salaryEntryId = salary?.id
            self.pensionEntryId = pensionCandidates.contains { $0.id == spec.pensionEntryId && $0.fits(salary: salary) } ? spec.pensionEntryId : nil
            self.newIncomeCategoryId = spec.newIncomeCategoryId ?? newIncomeCategoryId
            self.startMonth = Self.firstOfMonth(spec.startMonth)
            self.noticeGapMonths = max(0, spec.noticeGapMonths)
            let bonus = spec.oneOffs.first { $0.label == Self.signingBonusLabel }
            self.signingBonus = bonus?.amountMinorUnits
            self.otherOneOffs = spec.oneOffs.filter { $0.label != Self.signingBonusLabel }
        } else {
            self.offer = offer
            self.current = current
            self.editingScenarioId = nil
            let start = MonthRange.calendar.date(byAdding: .month, value: 1, to: Self.firstOfMonth(today))!
            self.name = Self.defaultName(for: start)
            self.salaryEntryId = Self.mostRecent(candidates)?.id
            self.pensionEntryId = nil
            self.newIncomeCategoryId = newIncomeCategoryId
            self.startMonth = start
            self.noticeGapMonths = 0
            self.signingBonus = nil
            self.otherOneOffs = []
        }
    }

    public var isEditing: Bool { editingScenarioId != nil }

    /// A name, and a salary to replace or an income category for the offer to go in (in edit mode, the
    /// scenario's own earlier salary entry stands in when the budget's has gone).
    public var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return salaryEntryId != nil || newIncomeCategoryId != nil || isEditing
    }

    public var salaryEntry: ForecastEntry? { salaryCandidates.first { $0.id == salaryEntryId } }

    /// The pension entries the picker offers for the chosen salary (`OfferPensionCandidate.fits`).
    public var pensionChoices: [ForecastEntry] {
        pensionCandidates.filter { $0.fits(salary: salaryEntry) }.map(\.entry)
    }

    /// The month the offer's salary starts: `startMonth` after any months without salary.
    public var offerStart: Date { MonthRange.calendar.date(byAdding: .month, value: noticeGapMonths, to: startMonth)! }

    /// The sheet's subtitle.
    public var subtitle: String {
        isEditing
            ? "Builds this scenario's new salary again. Any changes you made in the scenario to the new salary's entries, or to the salary and pension it replaces, are replaced. The budget is not changed."
            : "Makes a scenario where this new salary replaces your salary from the start month. The budget is not changed."
    }

    /// Said under the salary picker: a budget salary edited later isn't followed by the scenario.
    public static let refreshNote = "If you later change this salary in the budget and use Refresh from budget, open Edit new salary again so the new salary replaces the new salary."

    /// What a pension choice does, said under the picker; nil when the pension is left alone.
    public var pensionNote: String? {
        guard let id = pensionEntryId, let candidate = pensionCandidates.first(where: { $0.id == id }) else { return nil }
        return candidate.isTransfer
            ? "Becomes the new salary's employee and employer contributions a month."
            : "Changes by the difference in what you pay in (the employer's share isn't your spending)."
    }

    /// "From Apr 2026: £2,600.00 a month net, was £2,000.00": the offer's take-home from the month its salary
    /// starts (after any gap), against the entry it replaces; "£200.00 less than …" when it pays less.
    /// With a yearly bonus, "; plus £3,000.00 net a year in Mar" follows.
    public var preview: String {
        let result = SalaryCalculator.calculate(offer)
        let takeHome = result.takeHomeMonthly
        let from = offerStart
        let head = "From \(Self.monthLabel(from)): \(Money.format(takeHome, currency: .gbp)) a month net"
        let bonus = bonusPreview(result)
        guard let was = salaryEntry?.amountMinorUnits else { return head + ", new income" + bonus }
        if takeHome < was { return head + ", \(Money.format(was - takeHome, currency: .gbp)) less than \(Money.format(was, currency: .gbp))" + bonus }
        return head + ", was \(Money.format(was, currency: .gbp))" + bonus
    }

    private func bonusPreview(_ result: SalaryResult) -> String {
        guard let payslips = result.payslipsTakeHome, let month = offer.bonusPayment.month else { return "" }
        let bonus = payslips - 12 * result.takeHomeMonthly
        guard bonus > 0 else { return "" }
        return "; plus \(Money.format(bonus, currency: .gbp)) net a year in \(BonusPayment.shortMonth(month))"
    }

    /// The spec to build (or rebuild) the scenario from.
    public func spec() -> OfferScenarioSpec {
        var oneOffs = otherOneOffs
        if let signingBonus, signingBonus > 0 {
            oneOffs.insert(OfferOneOff(label: Self.signingBonusLabel, amountMinorUnits: signingBonus, month: offerStart), at: 0)
        }
        return OfferScenarioSpec(current: current, offer: offer, salaryEntryId: salaryEntryId, pensionEntryId: pensionEntryId,
                                 startMonth: startMonth, noticeGapMonths: noticeGapMonths, oneOffs: oneOffs,
                                 newIncomeCategoryId: salaryEntryId == nil ? newIncomeCategoryId : nil)
    }

    /// The scenario name to save, trimmed.
    public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The months the start picker offers: from this month a few years ahead, plus `startMonth` itself.
    public func monthOptions(today: Date = Date(), count: Int = 36) -> [Date] {
        let first = Self.firstOfMonth(today)
        var months = (0..<count).map { MonthRange.calendar.date(byAdding: .month, value: $0, to: first)! }
        if !months.contains(startMonth) { months = ([startMonth] + months).sorted() }
        return months
    }

    // MARK: Wording

    public static func defaultName(for month: Date) -> String { "New salary \(monthLabel(month))" }

    public static func monthLabel(_ month: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = MonthRange.calendar.timeZone
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: month)
    }

    private static func mostRecent(_ entries: [ForecastEntry]) -> ForecastEntry? {
        entries.max { ($0.startDate, $0.id ?? 0) < ($1.startDate, $1.id ?? 0) }
    }

    private static func firstOfMonth(_ date: Date) -> Date {
        let (year, month) = MonthRange.components(of: date)
        return MonthRange.calendar.date(from: DateComponents(year: year, month: month, day: 1))!
    }
}
