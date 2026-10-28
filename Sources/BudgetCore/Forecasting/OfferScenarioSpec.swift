import Foundation

/// A one-off payment that comes with a job offer (a signing bonus): a positive amount, planned as a
/// `once` income entry on the first day of `month`.
public struct OfferOneOff: Codable, Equatable, Sendable {
    public var label: String
    public var amountMinorUnits: Int
    public var month: Date

    public init(label: String, amountMinorUnits: Int, month: Date) {
        self.label = label
        self.amountMinorUnits = amountMinorUnits
        self.month = month
    }
}

/// What a job-offer scenario was made from (spec 2026-10-28-step14-job-offer-forecast-design.md): the two
/// salaries as the simulator had them, the budget entries the offer replaces, and when it starts. Stored as
/// JSON in `scenario.offerInputs`, so "Edit offer…" can reopen it and `OfferScenarioBuilder.rebuild` redo it.
public struct OfferScenarioSpec: Codable, Equatable, Sendable {
    /// The salary the person has now (kept for the simulator; the forecast already holds its take-home).
    public var current: SalaryInputs
    public var offer: SalaryInputs
    /// The **budget** salary entry the offer replaces; nil = no salary to replace (the offer is new income).
    public var salaryEntryId: Int64?
    /// The **budget** pension entry whose amount becomes the offer's pension; nil = leave pension alone.
    public var pensionEntryId: Int64?
    /// The first month without the old salary (first day of the month, UTC). With no gap it is the new job's
    /// first month; otherwise the offer's salary starts `noticeGapMonths` later.
    public var startMonth: Date
    /// Months from `startMonth` with no salary (a notice-period gap); the offer's salary starts after them.
    public var noticeGapMonths: Int
    public var oneOffs: [OfferOneOff]
    /// The income category the offer's salary goes in when there is no salary entry to replace (or it
    /// has since been deleted from the budget): "Add as new income".
    public var newIncomeCategoryId: Int64?
    /// The scenario entries the builder added (salary, pension, one-offs), set by `OfferScenarioBuilder`: what
    /// "Edit offer…" deletes before building again. Empty in a spec not built yet.
    public var addedEntryIds: [Int64]

    public init(current: SalaryInputs, offer: SalaryInputs, salaryEntryId: Int64?, pensionEntryId: Int64?, startMonth: Date,
                noticeGapMonths: Int = 0, oneOffs: [OfferOneOff] = [], newIncomeCategoryId: Int64? = nil, addedEntryIds: [Int64] = []) {
        self.current = current
        self.offer = offer
        self.salaryEntryId = salaryEntryId
        self.pensionEntryId = pensionEntryId
        self.startMonth = startMonth
        self.noticeGapMonths = noticeGapMonths
        self.oneOffs = oneOffs
        self.newIncomeCategoryId = newIncomeCategoryId
        self.addedEntryIds = addedEntryIds
    }

    private enum CodingKeys: String, CodingKey {
        case current, offer, salaryEntryId, pensionEntryId, startMonth, noticeGapMonths, oneOffs, newIncomeCategoryId, addedEntryIds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        current = try c.decode(SalaryInputs.self, forKey: .current)
        offer = try c.decode(SalaryInputs.self, forKey: .offer)
        salaryEntryId = try c.decodeIfPresent(Int64.self, forKey: .salaryEntryId)
        pensionEntryId = try c.decodeIfPresent(Int64.self, forKey: .pensionEntryId)
        startMonth = try c.decode(Date.self, forKey: .startMonth)
        noticeGapMonths = try c.decodeIfPresent(Int.self, forKey: .noticeGapMonths) ?? 0
        oneOffs = try c.decodeIfPresent([OfferOneOff].self, forKey: .oneOffs) ?? []
        newIncomeCategoryId = try c.decodeIfPresent(Int64.self, forKey: .newIncomeCategoryId)
        addedEntryIds = try c.decodeIfPresent([Int64].self, forKey: .addedEntryIds) ?? []
    }

    /// The spec without the builder's bookkeeping (`addedEntryIds`): what the person chose.
    public var inputs: OfferScenarioSpec {
        var copy = self
        copy.addedEntryIds = []
        return copy
    }

    /// The JSON stored in `scenario.offerInputs`: sorted keys, ISO 8601 dates.
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// `json()` read back; nil when `text` isn't one.
    public static func decode(_ text: String) -> OfferScenarioSpec? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OfferScenarioSpec.self, from: Data(text.utf8))
    }
}
