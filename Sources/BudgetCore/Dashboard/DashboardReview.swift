import Foundation
import GRDB

/// What the Mac Dashboard's review cards read (step 12): the current UK tax year's position, each tenancy's month,
/// the tax year's evidence and the documents waiting for their payment, the mortgages, the files waiting to import,
/// and the lines they add to "Needs attention". Composed from the read models the other screens use; never stored,
/// reads only. A section the viewer can't see (Property, Documents, a person's Tax) — or one with nothing in it (no
/// property, no tenancy, no mortgage, no one with a tax year) — is nil, so its card is not drawn. Tenancies are named
/// by their reference label, never by the tenant.
public struct DashboardReview: Equatable, Sendable {
    public struct TaxPosition: Equatable, Sendable {
        public struct PersonLine: Equatable, Identifiable, Sendable {
            public var personId: Int64
            public var name: String
            public var status: TaxYearStatus
            /// The year's balancing figure (`SelfAssessment.Calculation.balancingPayment`): positive due, negative a
            /// refund; nil when it can't be computed (`unavailableReason`).
            public var estimateMinorUnits: Int?
            /// Why there's no estimate ("The UK tax rules for 2026/27 aren't in the app yet.").
            public var unavailableReason: String?
            public var id: Int64 { personId }

            public init(personId: Int64, name: String, status: TaxYearStatus, estimateMinorUnits: Int?, unavailableReason: String?) {
                self.personId = personId
                self.name = name
                self.status = status
                self.estimateMinorUnits = estimateMinorUnits
                self.unavailableReason = unavailableReason
            }
        }

        public struct NextPayment: Equatable, Sendable {
            public var date: Date
            /// The people's payments due that day, added up.
            public var amountMinorUnits: Int
            /// "1st payment on account for 2026/27".
            public var label: String

            public init(date: Date, amountMinorUnits: Int, label: String) {
                self.date = date
                self.amountMinorUnits = amountMinorUnits
                self.label = label
            }
        }

        public var year: UKTaxYear
        public var people: [PersonLine]
        /// The earliest payment on account due today or later: each person's `nextPaymentOnAccount` of this year and
        /// the two before, on those years' deadlines (31 January, 31 July), added up across the people due that day.
        public var nextPaymentOnAccount: NextPayment?
    }

    public struct PropertyRow: Equatable, Identifiable, Sendable {
        public enum Rent: Equatable, Sendable { case received, late, notDueYet, notApplicable }

        public var tenancyId: Int64
        /// The tenancy's reference label, never the tenant's name.
        public var tenancyName: String
        /// The This-month checklist's steps done, out of those that apply this month.
        public var stepsDone: Int
        public var stepsTotal: Int
        public var rent: Rent
        /// This month's recharge statement: "Sent", "Drafted", "Not drafted" or "Not applicable".
        public var statementStatus: String
        public var id: Int64 { tenancyId }
    }

    public struct EvidenceSummary: Equatable, Sendable {
        public var taxYear: UKTaxYear
        /// The tax year's missing evidence that can change its figures (not kept for the recharges), neither found
        /// nor waived.
        public var missingCount: Int
        /// Documents waiting for their payment (`WaitingDocuments`), lapsed ones left out.
        public var waitingForPayment: Int
        /// Documents the waiting-documents job linked after a sync since the last visit (`WaitingDocuments.recentAutoLinks`,
        /// all of them without a last visit). Nil when not derivable.
        public var linkedSinceLastVisit: Int?
    }

    public struct MortgageSummary: Equatable, Sendable {
        public var propertyName: String
        /// What the mortgage accounts owe at the end of today; nil when they have no balance or movement at all.
        public var owedMinorUnits: Int?
        public var currency: Currency
        public var nextDue: Date?
        public var nextInstalmentMinorUnits: Int?
        public var ratePercent: Double?
        /// The next revision of a variable rate (none for a fixed rate or without rate rules).
        public var nextReview: Date?
    }

    public struct AttentionLine: Equatable, Identifiable, Sendable {
        public enum Kind: String, Sendable { case taxDeadline, rentLate, evidenceMissing, documentsWaiting, importsWaiting, mortgageReview }
        public var kind: Kind
        public var text: String
        /// One line per kind.
        public var id: String { kind.rawValue }
    }

    public var tax: TaxPosition?
    public var property: [PropertyRow]?
    public var evidence: EvidenceSummary?
    public var mortgages: [MortgageSummary]?
    /// Files waiting for the Mac to import (`ImportWaitingList`), whoever views.
    public var importsWaiting: Int
    public var attention: [AttentionLine]

    /// How far ahead a payment on account counts as needing attention.
    public static let taxDeadlineAttentionDays = 60
    /// How far ahead a mortgage rate review counts as needing attention.
    public static let mortgageReviewAttentionDays = 30
}

extension DashboardReview {
    /// The review on `today`. `lastVisit` is when the Dashboard was last seen (nil: never). `viewer` nil reads
    /// everything (the Mac, no sign-in); a member sees Property, Documents and each person's Tax only with View.
    /// Reads only.
    public static func load(db: Database, today: Date, lastVisit: Date?, viewer: AccessActor? = nil) throws -> DashboardReview {
        func canView(_ area: AccessArea) throws -> Bool {
            guard let viewer else { return true }
            return try AccessPolicy.level(viewer, area, db: db) >= .view
        }
        let day = PropertyDates.day(today)
        var review = DashboardReview(tax: nil, property: nil, evidence: nil, mortgages: nil,
                                     importsWaiting: try ImportWaitingList.waitingCount(db: db), attention: [])
        review.tax = try taxPosition(db: db, today: day, canView: canView)
        if try canView(.property) {
            let rows = try propertyRows(db: db, today: day, viewer: viewer)
            review.property = rows.isEmpty ? nil : rows
            let mortgages = try mortgageSummaries(db: db, today: day)
            review.mortgages = mortgages.isEmpty ? nil : mortgages
        }
        if try canView(.documents) {
            review.evidence = try evidenceSummary(db: db, today: day, lastVisit: lastVisit)
        }
        review.attention = attention(review, today: day)
        return review
    }

    // MARK: Tax

    static func taxPosition(db: Database, today: Date, canView: (AccessArea) throws -> Bool) throws -> TaxPosition? {
        let year = UKTaxYear.containing(today)
        let rows = try TaxOverview.rows(db: db, now: today)
        var people: [TaxPosition.PersonLine] = []
        var payments: [(date: Date, amount: Int, label: String)] = []
        for row in rows where row.year == year {
            guard let personId = row.person.id, try canView(try AccessArea.tax(ofPerson: personId, db: db)) else { continue }
            let (result, error) = SelfAssessmentOverview.selfAssessment(db: db, startYear: year.startYear, personId: personId)
            people.append(TaxPosition.PersonLine(personId: personId, name: row.person.name, status: row.status,
                                                 estimateMinorUnits: result?.calculation.balancingPayment,
                                                 unavailableReason: result == nil ? error : nil))
            // A year's payments on account fall due up to 16 months after it ends: the two years before can still have one.
            var results = [result]
            for earlier in [year.startYear - 1, year.startYear - 2]
            where rows.contains(where: { $0.person.id == personId && $0.year.startYear == earlier }) {
                results.append(SelfAssessmentOverview.selfAssessment(db: db, startYear: earlier, personId: personId).0)
            }
            for case let result? in results where result.calculation.nextPaymentOnAccount > 0 {
                let deadlines = result.taxYear.deadlines
                let towards = UKTaxYear(startYear: result.taxYear.startYear + 1).label
                let amount = result.calculation.nextPaymentOnAccount
                payments.append((deadlines.onlineReturnAndBalancingPayment, amount, "1st payment on account for \(towards)"))
                payments.append((deadlines.secondPaymentOnAccount, amount, "2nd payment on account for \(towards)"))
            }
        }
        guard !people.isEmpty else { return nil }
        let upcoming = payments.filter { $0.date >= today }
        let next = upcoming.map(\.date).min().map { date -> TaxPosition.NextPayment in
            let due = upcoming.filter { $0.date == date }
            return TaxPosition.NextPayment(date: date, amountMinorUnits: due.reduce(0) { $0 + $1.amount }, label: due[0].label)
        }
        return TaxPosition(year: year, people: people, nextPaymentOnAccount: next)
    }

    // MARK: Property

    /// One row per tenancy running this month, by property then tenancy (`Tenancies.all`'s order).
    static func propertyRows(db: Database, today: Date, viewer: AccessActor?) throws -> [PropertyRow] {
        let calendar = MonthRange.calendar
        let (year, monthNumber) = MonthRange.components(of: today)
        let start = MonthRange.of(year: year, month: monthNumber).start
        let month = DateInterval(start: start, end: calendar.date(byAdding: .month, value: 1, to: start)!)
        var rows: [PropertyRow] = []
        for property in try Properties.all(db: db) {
            guard let propertyId = property.id else { continue }
            let running = try Tenancies.all(db: db, propertyId: propertyId).filter { runs($0, in: month) }
            for tenancy in running {
                guard let tenancyId = tenancy.id else { continue }
                let checklist = try ThisMonthChecklist.build(db: db, tenancyId: tenancyId, today: today, trayCount: 0, viewer: viewer)
                guard !checklist.isHidden else { continue }
                let applying = checklist.steps.filter { $0.state != .notApplicable }
                let rent = try rentState(db: db, tenancy: tenancy, month: month, today: today, onlyTenancy: running.count == 1)
                rows.append(PropertyRow(tenancyId: tenancyId, tenancyName: checklist.tenancyName,
                                        stepsDone: applying.filter { $0.state == .done }.count, stepsTotal: applying.count,
                                        rent: rent, statementStatus: try statementStatus(db: db, checklist: checklist)))
            }
        }
        return rows
    }

    static func runs(_ tenancy: Tenancy, in month: DateInterval) -> Bool {
        tenancy.startDate < month.end && (tenancy.endDate.map { $0 >= month.start } ?? true)
    }

    /// This month's statement (the checklist's step 4): sent (or paid), drafted, not drafted — or not applicable
    /// when there's nothing to recharge this month.
    static func statementStatus(db: Database, checklist: ThisMonthChecklist) throws -> String {
        if let id = checklist.statementId, let statement = try RechargeStatement.fetchOne(db, key: id) {
            return statement.status == .draft ? "Drafted" : "Sent"
        }
        return checklist.step(.emailTenant)?.state == .notApplicable ? "Not applicable" : "Not drafted"
    }

    /// This month's rent: received once a rent credit linked to one of the tenancy's receipts falls in the month (or
    /// pays a receipt whose period covers it) — or, for a property's only tenancy this month, once the month's cash
    /// flow has a rent line (`PropertyFinance.monthBreakdown`, as `PropertyGlance` reads it). Otherwise due on the
    /// tenancy's rent day: the day of the month its last linked rent credit came (in the three months before), else
    /// the day of the month it started, never before it starts; late after that day, not due yet until then. Not
    /// applicable when the tenancy ends before its rent day.
    static func rentState(db: Database, tenancy: Tenancy, month: DateInterval, today: Date, onlyTenancy: Bool) throws -> PropertyRow.Rent {
        guard let tenancyId = tenancy.id else { return .notApplicable }
        let calendar = MonthRange.calendar
        let links = try Row.fetchAll(db, sql: """
            SELECT t.date AS date, r.periodStart AS periodStart, r.periodEnd AS periodEnd
            FROM rentReceiptPayment p
            JOIN rentReceipt r ON r.id = p.rentReceiptId
            JOIN transaction_ t ON t.id = p.transactionId
            WHERE p.isDismissed = 0 AND p.rentMinorUnits > 0 AND r.tenancyId = ? AND r.status = ?
            ORDER BY t.date
            """, arguments: [tenancyId, RentReceiptStatus.issued.rawValue])
            .map { (date: PropertyDates.day($0["date"] as Date), periodStart: $0["periodStart"] as Date, periodEnd: $0["periodEnd"] as Date) }
        let received = links.contains {
            month.contains($0.date) || ($0.periodStart < month.end && PropertyDates.nextDay($0.periodEnd) > month.start)
        }
        if received { return .received }
        if onlyTenancy, let propertyRent = try PropertyFinance.monthBreakdown(db: db, propertyId: tenancy.propertyId, interval: month).group(.rent),
           propertyRent.lines.contains(where: { $0.counted.native > 0 }) {
            return .received
        }

        let threeMonthsBefore = calendar.date(byAdding: .month, value: -3, to: month.start)!
        let lastCredit = links.last { $0.date >= threeMonthsBefore && $0.date < month.start }?.date
        let length = calendar.range(of: .day, in: .month, for: month.start)!.count
        let rentDay = min(calendar.component(.day, from: lastCredit ?? tenancy.startDate), length)
        let due = max(calendar.date(byAdding: .day, value: rentDay - 1, to: month.start)!, PropertyDates.day(tenancy.startDate))
        if let end = tenancy.endDate, PropertyDates.day(end) < due { return .notApplicable }
        return today > due ? .late : .notDueYet
    }

    // MARK: Mortgage

    /// Each property with a mortgage account (`MortgageRate.status`), by property name; a repaid loan (nothing owed and
    /// no instalment left) is left out.
    static func mortgageSummaries(db: Database, today: Date) throws -> [MortgageSummary] {
        var result: [MortgageSummary] = []
        for property in try Properties.all(db: db) {
            guard let propertyId = property.id, let status = try MortgageRate.status(db: db, propertyId: propertyId, today: today) else { continue }
            let accountIds = try Properties.accounts(db: db, propertyId: propertyId, role: .mortgage).map(\.accountId)
            let hasBalance = try BalanceSnapshot.filter(accountIds.contains(Column("accountId"))).fetchCount(db) > 0
                || Transaction.filter(accountIds.contains(Column("accountId"))).fetchCount(db) > 0
            let owed = hasBalance
                ? try PropertyFinance.balance(db: db, property: property, conversion: try CurrencyConversion.current(db: db),
                                              accountIds: accountIds, asOf: today).native
                : nil
            if let owed, owed <= 0, (status.remainingInstalments ?? 0) <= 0 { continue }
            let variable = status.terms.hasRateRules && status.terms.rateIndex != .fixed
            result.append(MortgageSummary(propertyName: property.name, owedMinorUnits: owed, currency: property.currency,
                                          nextDue: status.nextDue, nextInstalmentMinorUnits: status.nextInstalmentMinorUnits,
                                          ratePercent: status.current?.ratePercent, nextReview: variable ? status.nextRevision : nil))
        }
        return result
    }

    // MARK: Evidence

    static func evidenceSummary(db: Database, today: Date, lastVisit: Date?) throws -> EvidenceSummary {
        let year = UKTaxYear.containing(today)
        let missing = try MissingEvidence.items(db: db, taxYear: year).filter { !$0.isForRecharges && !$0.isDone }.count
        let waiting = try WaitingDocuments.states(db: db, now: today).values.filter { $0 == .waiting }.count
        let linked = try WaitingDocuments.recentAutoLinks(db: db).filter { link in lastVisit.map { link.linkedAt > $0 } ?? true }.count
        return EvidenceSummary(taxYear: year, missingCount: missing, waitingForPayment: waiting, linkedSinceLastVisit: linked)
    }

    // MARK: Needs attention

    /// One line per kind, in this order: a payment on account due within `taxDeadlineAttentionDays`, rent late, tax
    /// evidence missing, documents linked automatically since the last visit (to check, with Undo, in Documents),
    /// files waiting to import, a mortgage rate review within `mortgageReviewAttentionDays`.
    static func attention(_ review: DashboardReview, today: Date) -> [AttentionLine] {
        let calendar = MonthRange.calendar
        func within(_ date: Date, days: Int) -> Bool { date >= today && date <= calendar.date(byAdding: .day, value: days, to: today)! }
        func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        var lines: [AttentionLine] = []
        if let payment = review.tax?.nextPaymentOnAccount, within(payment.date, days: taxDeadlineAttentionDays) {
            lines.append(AttentionLine(kind: .taxDeadline, text: "Payment on account due \(MortgageTerms.dayText(payment.date))"))
        }
        let late = (review.property ?? []).filter { $0.rent == .late }.map(\.tenancyName)
        if !late.isEmpty {
            lines.append(AttentionLine(kind: .rentLate, text: "Rent not received for \(late.joined(separator: ", "))"))
        }
        if let evidence = review.evidence {
            if evidence.missingCount > 0 {
                lines.append(AttentionLine(kind: .evidenceMissing,
                                           text: count(evidence.missingCount, "tax document missing", "tax documents missing")))
            }
            if let linked = evidence.linkedSinceLastVisit, linked > 0 {
                lines.append(AttentionLine(kind: .documentsWaiting,
                                           text: count(linked, "document linked automatically since your last visit",
                                                       "documents linked automatically since your last visit")))
            }
        }
        if review.importsWaiting > 0 {
            lines.append(AttentionLine(kind: .importsWaiting, text: count(review.importsWaiting, "file waiting to import", "files waiting to import")))
        }
        if let review = (review.mortgages ?? []).compactMap(\.nextReview).filter({ within($0, days: mortgageReviewAttentionDays) }).min() {
            lines.append(AttentionLine(kind: .mortgageReview, text: "Mortgage rate review \(MortgageTerms.dayText(review))"))
        }
        return lines
    }
}
