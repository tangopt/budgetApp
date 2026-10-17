import GRDB
import Foundation

/// A person's rental accounts for a property and UK tax year (spec §2, §4; plan phase 3
/// Task 2): the rent by rent period, each expense type through its attribution rule, the
/// finance costs apart (residential finance cost relief), the PT tax that feeds foreign tax
/// credit relief, and manual items — each line with its sources and the rule applied, in
/// the property's currency and in GBP at the year's HMRC average rate.
public enum RentalAccounts {
    /// An amount split by where it comes from: the property's currency (`native`), and items
    /// already in pounds (`gbpNative`, kept apart and never converted). `gbp` is
    /// `native × HMRC rate + gbpNative`, `nil` when a rate is needed and missing.
    public struct Amount: Equatable, Sendable {
        public var native: Int
        public var gbpNative: Int
        public var gbp: Int?

        public init(native: Int = 0, gbpNative: Int = 0, gbp: Int? = 0) {
            self.native = native
            self.gbpNative = gbpNative
            self.gbp = gbp
        }

        public static let zero = Amount()

        public static func + (lhs: Amount, rhs: Amount) -> Amount {
            Amount(native: lhs.native + rhs.native, gbpNative: lhs.gbpNative + rhs.gbpNative,
                   gbp: lhs.gbp.flatMap { a in rhs.gbp.map { a + $0 } })
        }

        public static func - (lhs: Amount, rhs: Amount) -> Amount {
            Amount(native: lhs.native - rhs.native, gbpNative: lhs.gbpNative - rhs.gbpNative,
                   gbp: lhs.gbp.flatMap { a in rhs.gbp.map { a - $0 } })
        }
    }

    /// What a line's amount comes from.
    public enum SourceReference: Hashable, Sendable {
        case transaction(Int64)
        case rentReceipt(Int64)
        case manualItem(Int64)
        /// An insurer's receipt paid outside the bank history (`TaxPolicyReceipt`).
        case policyReceipt(Int64)

        var isManualItem: Bool {
            if case .manualItem = self { return true }
            return false
        }

        public var entity: EvidenceEntity {
            switch self {
            case let .transaction(id): return .transaction(id)
            case let .rentReceipt(id): return .rentReceipt(id)
            case let .manualItem(id): return .taxManualItem(id)
            case let .policyReceipt(id): return .taxPolicyReceipt(id)
            }
        }
    }

    /// One transaction, receipt or manual item feeding a line.
    public struct Source: Equatable, Sendable {
        public var reference: SourceReference
        public var date: Date?
        public var description: String
        public var currency: Currency
        /// The whole amount, positive in the line's direction (a cost or the rent; a refund is negative).
        public var amountMinorUnits: Int
        /// The part attributed to this tax year, for the whole property.
        public var attributedMinorUnits: Int
        /// The person's share of this source.
        public var shareBasisPoints: Int
        /// How the rule attributed it ("3 of 6 cover months, Jan 2025 – Jun 2025, from the note").
        public var explanation: String
        /// The documents linked to the record.
        public var documentIds: [Int64]
    }

    public struct Line: Equatable, Sendable {
        public var expenseType: TaxExpenseType
        public var label: String
        /// The type's rule (manual items belong to the year they're entered for).
        public var rule: TaxAttributionRuleKind
        public var ruleExplanation: String
        /// The person's share of the line (sources may differ: manual items, named PT tax).
        public var share: TaxShare
        public var shareExplanation: String
        /// The whole property's figure.
        public var whole: Amount
        /// The person's figure.
        public var amount: Amount
        public var sources: [Source]
    }

    /// Rent by rent period, one month April–March.
    public struct RentMonth: Equatable, Sendable {
        public var start: Date
        /// The property's, in its currency.
        public var whole: Int
        /// The person's share (rounded so the months add up to the rent line's share).
        public var amount: Int
    }

    public struct Totals: Equatable, Sendable {
        public var income: Amount
        /// The deductible expenses (finance costs excluded).
        public var expenses: Amount
        /// `income − expenses`: the template's "Profit/loss from rental income".
        public var profit: Amount
        /// Mortgage interest, relieved at the basic rate.
        public var financeCosts: Amount
        /// PT tax for the calendar year the UK year starts in: the FTCR input.
        public var foreignTax: Amount
    }

    /// How the year's utilities met the recharges received (`RechargeNetting`), in the
    /// property's currency for the whole property.
    public struct UtilityNetting: Equatable, Sendable {
        /// The mode applied: `nil` = none (no stored mode, and a filed or paid year or no
        /// recharges: each utility category on its own line, as before phase 5).
        public var mode: RechargeNettingMode?
        /// Whether the mode came from the data (no stored mode).
        public var isAutomatic: Bool
        /// Utility costs attributed to the year (under `netOfRecharges`: before the recharges).
        public var utilitiesPaid: Int
        /// Statement-linked parts of tenant credits received in the year.
        public var rechargesReceived: Int
        /// The part of them deducted from the utilities (at most `utilitiesPaid`).
        public var rechargesApplied: Int
        /// `rechargesReceived − rechargesApplied`: on the rental income line ("Recharges above
        /// utilities paid").
        public var excess: Int

        public init(mode: RechargeNettingMode? = nil, isAutomatic: Bool = true, utilitiesPaid: Int = 0, rechargesReceived: Int = 0,
                    rechargesApplied: Int = 0, excess: Int = 0) {
            self.mode = mode
            self.isAutomatic = isAutomatic
            self.utilitiesPaid = utilitiesPaid
            self.rechargesReceived = rechargesReceived
            self.rechargesApplied = rechargesApplied
            self.excess = excess
        }
    }

    public struct Result: Equatable, Sendable {
        public var taxYear: UKTaxYear
        public var personId: Int64
        public var propertyId: Int64
        public var currency: Currency
        /// The HMRC average rate used (pounds per unit of `currency`); `nil` when not needed or missing.
        public var rate: HMRCRate?
        public var income: Line
        /// One line per deductible type, in `TaxExpenseType.expenseLines` order.
        public var expenses: [Line]
        public var financeCosts: Line
        public var foreignTax: Line
        /// Not on the return (life insurance, recharged utilities, other income), for information.
        public var notDeductible: Line
        public var rentMonths: [RentMonth]
        public var totals: Totals
        public var utilityNetting: UtilityNetting
        public var warnings: [String]

        /// Every line: income, expenses, finance costs, foreign tax, not deductible.
        public var allLines: [Line] { [income] + expenses + [financeCosts, foreignTax, notDeductible] }

        public func line(_ type: TaxExpenseType) -> Line? { allLines.first { $0.expenseType == type } }
    }

    // MARK: - Computing

    public static func compute(db: Database, taxYear: UKTaxYear, personId: Int64, propertyId: Int64) throws -> Result {
        guard let property = try Property.fetchOne(db, key: propertyId) else { throw TaxError.propertyNotFound }
        guard let person = try Person.fetchOne(db, key: personId) else { throw TaxError.personNotFound }
        var warnings: [String] = []

        // Rates: every non-GBP currency's, keyed by currency (a GBP property can have EUR sources).
        var rates: [Currency: HMRCRate] = [:]
        for currency in Currency.allCases where currency != .gbp {
            rates[currency] = try HMRCRates.rate(db: db, startYear: taxYear.startYear, currencyCode: currency.rawValue)
        }
        let rate = property.currency == .gbp ? nil : rates[property.currency]
        let context = Context(db: db, taxYear: taxYear, person: person, property: property, rates: rates)
        let owners = try Properties.owners(db: db, propertyId: propertyId).map(\.personId)
        let people = try Person.filter(keys: owners).fetchAll(db)
        let otherNames = people.filter { $0.id != personId }.map(\.name)
        if try TaxSplits.share(db: db, startYear: taxYear.startYear, personId: personId, propertyId: propertyId, expenseType: .rentalIncome)
            == TaxShare(shareBasisPoints: 0, origin: .ownership) {
            warnings.append("\(person.name) owns no share of \(property.name) in \(taxYear.label) (ownership weighted by days owned): set a split if they should have one.")
        }

        // Categories and their types.
        let entries = try TaxExpenseTypeMap.entries(db: db, propertyId: propertyId)
        let typeByCategory = Dictionary(uniqueKeysWithValues: entries.map { ($0.category.id!, $0.expenseType) })
        let categoryType = Dictionary(uniqueKeysWithValues: entries.map { ($0.category.id!, $0.category.type) })
        // Names the guess can't settle: refunds of unknown kind, loan instalments (capital and interest).
        for entry in entries where !entry.isStored {
            let name = fold(entry.category.name)
            if entry.category.type == .income, entry.expenseType == .notDeductible,
               ["refund", "reembolso", "devolucao"].contains(where: name.contains) {
                warnings.append("“\(entry.category.name)” looks like a refund: check its tax line (a tax refund reduces the foreign tax, a cost refund its cost).")
            }
            if TaxExpenseTypeMap.needsReview(entry.category.name) {
                warnings.append("“\(entry.category.name)” looks like loan instalments (capital and interest): it's left out until you set its tax line — put the interest part under a finance-cost category.")
            }
        }
        let suggested = entries.filter { !$0.isStored }.map(\.category.name)
        if !suggested.isEmpty {
            warnings.append("Tax types suggested from the category names (not yet confirmed): \(suggested.joined(separator: ", ")).")
        }

        // Transactions in a wide window: rules can reach years back (previous calendar year,
        // cover and quota periods) or forward (a quota paid after the year).
        let calendar = MonthRange.calendar
        let windowStart = calendar.date(byAdding: .year, value: -3, to: taxYear.start)!
        let windowEnd = calendar.date(byAdding: .year, value: 3, to: taxYear.end)!
        let categoryIds = Array(typeByCategory.keys)
        let transactions = categoryIds.isEmpty ? [] : try Transaction
            .filter(categoryIds.contains(Column("categoryId")) && Column("date") >= windowStart && Column("date") < windowEnd)
            .order(Column("date"), Column("id")).fetchAll(db)
        let currencies = Dictionary(uniqueKeysWithValues: try Account.fetchAll(db).compactMap { a in a.id.map { ($0, a.currency) } })
        let documents = try linkedDocuments(db: db, type: .transaction, ids: transactions.compactMap(\.id))
        // Insurers' receipts (cover periods, policy years) and per-person assignments.
        let policyReceipts = try TaxPolicyReceipts.receipts(db: db, propertyId: propertyId)
        let receiptByTransaction = Dictionary(policyReceipts.compactMap { r in r.transactionId.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        let assignedOwners = try TaxTransactionOwners.all(db: db)
        let ownerNames = Dictionary(uniqueKeysWithValues: try Person.fetchAll(db).compactMap { p in p.id.map { ($0, p.name) } })

        var sourcesByType: [TaxExpenseType: [Source]] = [:]
        var rules: [TaxExpenseType: TaxAttributionRule] = [:]
        var shares: [TaxExpenseType: TaxShare] = [:]
        for type in TaxExpenseType.allCases {
            rules[type] = try TaxAttributionRules.effective(db: db, expenseType: type, startYear: taxYear.startYear)
            shares[type] = try TaxSplits.share(db: db, startYear: taxYear.startYear, personId: personId, propertyId: propertyId, expenseType: type)
        }

        // Utilities and the recharges received for them (phase 5): the mode decides each
        // utility category's line. Recharges count in the window the Utilities rule uses.
        let utilityCategoryIds = try RechargeNetting.utilityCategoryIds(db: db, propertyId: propertyId)
        let rechargeWindow = rules[.utilities]!.rule == .byDebitMonth ? taxYear.monthsInterval : taxYear.interval
        let rechargesReceived = try Recharges.received(db: db, propertyId: propertyId, in: rechargeWindow)
        let storedNetting = try RechargeNetting.mode(db: db, startYear: taxYear.startYear)
        // Automatic: a filed (or paid) year keeps every category on its own line, exactly as
        // before phase 5, so filed figures don't move; an open year nets once it has recharges.
        let yearStatus = try TaxYears.year(db: db, startYear: taxYear.startYear, personId: personId)?.status
        let isFiled = yearStatus == .filed || yearStatus == .paid
        // Foreign tax: a year's own rule wins; otherwise a filed (or paid) year keeps the basis
        // it was filed on (the whole previous calendar year, before the time-apportioned
        // default), so filed figures don't move when the default changes.
        if isFiled, rules[.foreignTax]!.startYear == nil, rules[.foreignTax]!.rule == .apportionCalendarYear {
            rules[.foreignTax] = TaxAttributionRule(expenseType: .foreignTax, startYear: taxYear.startYear, rule: .previousCalendarYear,
                                                    notes: "Kept for a filed year")
            warnings.append("\(taxYear.label) is \(yearStatus!.displayName.lowercased()): foreign tax stays on the previous-calendar-year basis it was filed on; set the year's rule to apportion it by days (HMRC INTM161220).")
        }
        let nettingMode = storedNetting ?? (isFiled || rechargesReceived.isEmpty ? nil : .netOfRecharges)
        // Statement-linked recharge parts of credits: not rent when the rent comes from credits.
        let rechargedByCredit = nettingMode == nil ? [:] : try RentReceiptMatching.rechargedByCredit(db: db)
        var utilityNotDeductibleSources = 0
        var utilityNetting = UtilityNetting(mode: nettingMode, isAutomatic: storedNetting == nil)
        var utilitySources = 0

        // Rent by rent period: the receipts.
        let incomeRule = rules[.rentalIncome]!
        var rentMonths: [RentMonth] = []
        if incomeRule.rule == .byRentPeriod {
            let window = taxYear.monthsInterval
            let receipts = try RentReceipts.receipts(db: db, propertyId: propertyId, overlapping: window)
            let receiptDocs = try linkedDocumentIds(db: db, type: .rentReceipt, ids: receipts.compactMap(\.id))
            let share = shares[.rentalIncome]!.shareBasisPoints
            for receipt in receipts {
                let attributed = PropertyFinance.apportioned(receipt.amountMinorUnits, start: receipt.periodStart, lastDay: receipt.periodEnd, to: window)
                guard attributed != 0 else { continue }
                let total = PropertyFinance.days(receipt.periodStart, PropertyDates.nextDay(receipt.periodEnd))
                let inside = PropertyFinance.days(max(receipt.periodStart, window.start), min(PropertyDates.nextDay(receipt.periodEnd), window.end))
                sourcesByType[.rentalIncome, default: []].append(Source(
                    reference: .rentReceipt(receipt.id!), date: receipt.receiptDate,
                    description: "Rent receipt \(receipt.receiptNumber)", currency: property.currency,
                    amountMinorUnits: receipt.amountMinorUnits, attributedMinorUnits: attributed, shareBasisPoints: share,
                    explanation: "Rent period \(day(receipt.periodStart)) – \(day(receipt.periodEnd)): \(inside) of \(total) days in \(monthsLabel(window))",
                    documentIds: receiptDocs[receipt.id!] ?? []))
            }
            // The person's months are rounded cumulatively, so they add up to the line's share.
            var monthStart = window.start
            var cumulative = 0
            while monthStart < window.end {
                let next = calendar.date(byAdding: .month, value: 1, to: monthStart)!
                let bucket = DateInterval(start: monthStart, end: next)
                let whole = receipts.reduce(0) { $0 + PropertyFinance.apportioned($1.amountMinorUnits, start: $1.periodStart, lastDay: $1.periodEnd, to: bucket) }
                let amount = shareOf(cumulative + whole, share) - shareOf(cumulative, share)
                cumulative += whole
                rentMonths.append(RentMonth(start: monthStart, whole: whole, amount: amount))
                monthStart = next
            }
            // Rent credits in the months without a receipt: rent the receipts don't show.
            let unmatched = try RentReceiptMatching.unmatchedCredits(db: db, propertyId: propertyId)
                .filter { within($0.date, window) }
            if !unmatched.isEmpty {
                warnings.append("\(unmatched.count) rent credit\(unmatched.count == 1 ? "" : "s") in \(taxYear.label) match no rent receipt: rent by rent period may be incomplete.")
            }
        }

        // PT tax withheld by the tenant on the receipts (retenção IRS): PT tax on the rent of
        // calendar year N by rent period — the same basis as the rent the FTCR compares it
        // with (`calendarYearRent`). Under the time-apportioned rule each calendar year's
        // withholding goes to the UK years by days, like the PT IRS payments; otherwise the
        // calendar year the UK year starts in counts whole. A receipt spanning two calendar
        // years is spread by days. At the rent share.
        let foreignRule = rules[.foreignTax]!.rule
        let withholdingYears = foreignRule == .apportionCalendarYear ? [taxYear.startYear, taxYear.startYear + 1] : [taxYear.startYear]
        for year in withholdingYears {
            let calendarYear = Self.calendarYearInterval(year)
            let withheld = try RentReceipts.receipts(db: db, propertyId: propertyId, overlapping: calendarYear).filter { $0.withholdingMinorUnits > 0 }
            let withheldDocs = try linkedDocumentIds(db: db, type: .rentReceipt, ids: withheld.compactMap(\.id))
            for receipt in withheld {
                let inYear = PropertyFinance.apportioned(receipt.withholdingMinorUnits, start: receipt.periodStart, lastDay: receipt.periodEnd, to: calendarYear)
                guard inYear != 0 else { continue }
                var attributed = inYear
                var basis = "PT tax for \(year) → \(taxYear.label)"
                if foreignRule == .apportionCalendarYear {
                    guard let (part, days) = Self.timeApportioned(inYear, calendarYear: year, to: taxYear), part != 0 else { continue }
                    attributed = part
                    basis = "PT tax for \(year): \(days) in \(taxYear.label)"
                }
                let total = PropertyFinance.days(receipt.periodStart, PropertyDates.nextDay(receipt.periodEnd))
                let inside = PropertyFinance.days(max(receipt.periodStart, calendarYear.start), min(PropertyDates.nextDay(receipt.periodEnd), calendarYear.end))
                sourcesByType[.foreignTax, default: []].append(Source(
                    reference: .rentReceipt(receipt.id!), date: receipt.receiptDate,
                    description: "Withheld by the tenant, rent receipt \(receipt.receiptNumber)", currency: property.currency,
                    amountMinorUnits: receipt.withholdingMinorUnits, attributedMinorUnits: attributed,
                    shareBasisPoints: shares[.rentalIncome]!.shareBasisPoints,
                    explanation: "Rent period \(day(receipt.periodStart)) – \(day(receipt.periodEnd)): \(inside) of \(total) days in \(year), \(basis); at the rent share",
                    documentIds: withheldDocs[receipt.id!] ?? []))
            }
        }
        var foreignTaxYears: Set<Int> = []
        var splitConflicts: Set<TaxExpenseType> = []

        // Transactions through their type's rule.
        for transaction in transactions {
            guard let categoryId = transaction.categoryId, var type = typeByCategory[categoryId] else { continue }
            let isUtility = utilityCategoryIds.contains(categoryId)
            if isUtility, let nettingMode { type = nettingMode == .netOfRecharges ? .utilities : .notDeductible }
            let rule = rules[type]!
            // Under byRentPeriod the receipts are the rent; the credits are their payments.
            if type == .rentalIncome && rule.rule == .byRentPeriod { continue }
            // Rent (and not-deductible income) counts credits up; every other line counts costs
            // up, so a credit filed under it (a refund) reduces it.
            let isIncome = categoryType[categoryId] == .income
            var natural = (type == .rentalIncome || type == .notDeductible) && isIncome ? transaction.amountMinorUnits : -transaction.amountMinorUnits
            // A rent credit's recharge part is netted against the utilities (or left out with
            // them), so it isn't rent as well.
            var rechargePart = 0
            if type == .rentalIncome, isIncome, let part = rechargedByCredit[transaction.id!], part > 0 {
                rechargePart = min(part, natural)
                natural -= rechargePart
            }
            let docs = documents[transaction.id!] ?? []
            // A payment (not a refund) says that calendar year's tax is recorded.
            if type == .foreignTax, rule.rule == .apportionCalendarYear, natural > 0 {
                foreignTaxYears.insert(context.liabilityYear(item: Item(transaction), documents: docs).0)
            }
            guard let (attributed, explanation) = context.attribute(item: Item(transaction), amount: natural, rule: rule, documents: docs,
                                                                   receipt: receiptByTransaction[transaction.id!]) else { continue }
            var share = shares[type]!.shareBasisPoints
            var explained = explanation
            if rechargePart > 0 {
                explained += "; less \(Money.format(rechargePart, currency: currencies[transaction.accountId] ?? .gbp)) of utilities recharged (its recharge statement links)"
            }
            if let owner = assignedOwners[transaction.id!] {
                // Assigned to one person (their own PT IRS from the joint account): all theirs.
                if shares[type]!.origin != .ownership {
                    splitConflicts.insert(type)
                }
                share = owner == personId ? PropertyOwner.wholeShare : 0
                explained += owner == personId ? "; \(person.name)'s (assigned)" : "; \(ownerNames[owner] ?? "another person")'s (assigned)"
            } else if type == .foreignTax {
                switch named(person: person.name, others: otherNames, note: transaction.note, documents: docs) {
                case .this:
                    share = PropertyOwner.wholeShare
                    explained += "; \(person.name)'s (named)"
                case .other:
                    share = 0
                    explained += "; another person's (named)"
                case .none:
                    break
                }
            }
            let currency = currencies[transaction.accountId] ?? .gbp
            sourcesByType[type, default: []].append(Source(
                reference: .transaction(transaction.id!), date: transaction.date, description: transaction.rawDescription,
                currency: currency, amountMinorUnits: natural, attributedMinorUnits: attributed, shareBasisPoints: share,
                explanation: explained, documentIds: docs.compactMap(\.id)))
            if isUtility {
                utilitySources += 1
                if type == .notDeductible { utilityNotDeductibleSources += 1 }
                if let value = context.nativeValue(attributed, currency: currency) { utilityNetting.utilitiesPaid += value }
            }
        }

        for type in TaxExpenseType.allCases where splitConflicts.contains(type) {
            warnings.append("\(type.displayName): payments assigned to one person override the \(taxYear.label) split (\(shares[type]!.explanation(year: taxYear))) for those payments — check which one is meant.")
        }

        // Insurers' receipts paid outside the bank history: sources of their own.
        let unlinkedReceipts = policyReceipts.filter { $0.transactionId == nil }
        let unlinkedDocs = try linkedDocuments(db: db, type: .taxPolicyReceipt, ids: unlinkedReceipts.compactMap(\.id))
        for receipt in unlinkedReceipts {
            let type = receipt.expenseType
            let docs = unlinkedDocs[receipt.id!] ?? []
            let description = "\(type == .insurance ? "Insurance" : type.displayName) receipt (\(receipt.label)), paid outside the bank history"
            // Its cover is the period; without one, the user's notes may give it. The generated
            // description is never read for a period (it names the policy year).
            if let match = transactions.first(where: { t in
                t.categoryId.flatMap { typeByCategory[$0] } == type && -t.amountMinorUnits == receipt.amountMinorUnits
                    && abs(t.date.timeIntervalSince(receipt.date)) <= 30 * 86_400 }) {
                warnings.append("The \(type.displayName.lowercased()) receipt of \(day(receipt.date)) (\(Money.format(receipt.amountMinorUnits, currency: receipt.currency)), kept on its own) matches the debit of \(day(match.date)) “\(match.rawDescription)”: link the receipt to it, or it counts twice.")
            }
            guard let (attributed, explanation) = context.attribute(item: Item(date: receipt.date, note: receipt.cover == nil ? receipt.notes : nil, description: ""),
                                                                   amount: receipt.amountMinorUnits, rule: rules[type]!, documents: docs,
                                                                   receipt: receipt) else { continue }
            sourcesByType[type, default: []].append(Source(
                reference: .policyReceipt(receipt.id!), date: receipt.date, description: description, currency: receipt.currency,
                amountMinorUnits: receipt.amountMinorUnits, attributedMinorUnits: attributed, shareBasisPoints: shares[type]!.shareBasisPoints,
                explanation: explanation, documentIds: docs.compactMap(\.id)))
        }

        // Manual items: the person's own, and whole-property ones entered under anyone.
        let items = try TaxManualItem
            .filter(Column("startYear") == taxYear.startYear && Column("propertyId") == propertyId
                    && (Column("personId") == personId || Column("isWholeProperty") == true))
            .order(Column("date") == nil, Column("date"), Column("id")).fetchAll(db)
        let itemDocs = try linkedDocumentIds(db: db, type: .taxManualItem, ids: items.compactMap(\.id))
        for item in items {
            let share = item.isWholeProperty ? shares[item.expenseType]!.shareBasisPoints : PropertyOwner.wholeShare
            sourcesByType[item.expenseType, default: []].append(Source(
                reference: .manualItem(item.id!), date: item.date, description: item.label, currency: item.currency,
                amountMinorUnits: item.amountMinorUnits, attributedMinorUnits: item.amountMinorUnits, shareBasisPoints: share,
                explanation: item.isWholeProperty ? "Entered for \(taxYear.label), whole property" : "Entered for \(taxYear.label), \(person.name)'s own",
                documentIds: itemDocs[item.id!] ?? []))
        }

        // Net the recharges received against the Utilities line (manual utility items count as
        // paid too), never below zero: each recharge is a negative source, capped by what's
        // left; the part above the utilities paid is rental income.
        if nettingMode == .netOfRecharges {
            for source in sourcesByType[.utilities] ?? [] where source.reference.isManualItem {
                if let value = context.nativeValue(source.attributedMinorUnits, currency: source.currency) { utilityNetting.utilitiesPaid += value }
            }
            var room = max(0, utilityNetting.utilitiesPaid)
            let share = shares[.utilities]!.shareBasisPoints
            for recharge in rechargesReceived {
                let currency = currencies[recharge.transaction.accountId] ?? property.currency
                let amount = recharge.payment.amountMinorUnits
                var applied = amount
                let received = "Recharge received \(day(recharge.transaction.date)), in \(day(rechargeWindow.start)) – \(day(rechargeWindow.end.addingTimeInterval(-1)))"
                var explanation = received
                if let value = context.nativeValue(amount, currency: currency) {
                    let appliedValue = min(max(value, 0), room)
                    room -= appliedValue
                    utilityNetting.rechargesReceived += value
                    utilityNetting.rechargesApplied += appliedValue
                    if appliedValue < value {
                        applied = value == 0 ? 0 : Int((Double(amount) * Double(appliedValue) / Double(value)).rounded())
                        explanation += "; capped at the utilities left to offset, the rest is rental income"
                        sourcesByType[.rentalIncome, default: []].append(Source(
                            reference: .transaction(recharge.transaction.id!), date: recharge.transaction.date,
                            description: "Recharges above utilities paid, \(month(recharge.statement.month)) statement",
                            currency: currency, amountMinorUnits: amount, attributedMinorUnits: amount - applied,
                            shareBasisPoints: shares[.rentalIncome]!.shareBasisPoints,
                            explanation: "\(received); the part above the utilities paid in \(taxYear.label) (utilities offset first)",
                            documentIds: []))
                    }
                }
                sourcesByType[.utilities, default: []].append(Source(
                    reference: .transaction(recharge.transaction.id!), date: recharge.transaction.date,
                    description: "Utilities recharged to the tenant, \(month(recharge.statement.month)) statement",
                    currency: currency, amountMinorUnits: -amount, attributedMinorUnits: -applied, shareBasisPoints: share,
                    explanation: explanation, documentIds: try statementDocumentIds(db: db, statementId: recharge.statement.id!)))
            }
            utilityNetting.excess = utilityNetting.rechargesReceived - utilityNetting.rechargesApplied
            if utilityNetting.excess > 0 {
                warnings.append("Recharges received in \(taxYear.label) exceed the utilities paid by \(Money.format(utilityNetting.excess, currency: property.currency)): the excess is rental income (“Recharges above utilities paid”). An invoice paid in another year?")
            }
        } else if storedNetting == nil && isFiled && !rechargesReceived.isEmpty {
            warnings.append("\(taxYear.label) is \(yearStatus!.displayName.lowercased()): utilities stay on their own tax lines, as filed, although recharges were received. Set the year's netting to net them.")
        } else if nettingMode == nil && !isFiled && utilityNotDeductibleSources > 0 {
            warnings.append("No utility recharges received in \(taxYear.label): utilities stay on their own tax lines (recharged utilities are not deductible). Record the recharge statements and their payments to deduct the unrecovered part, or set the year's netting.")
        }

        // Time-apportioned foreign tax needs next calendar year's tax too, which is assessed
        // after the return is due: say so while it's missing.
        if foreignRule == .apportionCalendarYear, !foreignTaxYears.isEmpty || sourcesByType[.foreignTax]?.isEmpty == false,
           !foreignTaxYears.contains(taxYear.startYear + 1),
           !(sourcesByType[.foreignTax] ?? []).contains(where: { $0.reference.isManualItem }) {
            let next = taxYear.startYear + 1
            let days = PropertyFinance.days(Self.calendarYearInterval(next).start, taxYear.end)
            let total = PropertyFinance.days(Self.calendarYearInterval(next).start, Self.calendarYearInterval(next).end)
            warnings.append("No PT tax for \(next) recorded yet: \(days) of its \(total) days belong to \(taxYear.label) (HMRC INTM161220, time apportionment). It is usually assessed and paid in the summer of \(next + 1): until then enter an estimate as a foreign-tax manual item and amend the return when it's known, or set the year's rule to Previous calendar year.")
        }

        let missingRates = Set(sourcesByType.values.joined().map(\.currency).filter { $0 != .gbp && rates[$0] == nil })
        for currency in missingRates.sorted(by: { $0.rawValue < $1.rawValue }) {
            warnings.append("No HMRC average rate for \(currency.rawValue.uppercased()) \(taxYear.label): GBP figures are missing.")
        }

        func line(_ type: TaxExpenseType) -> Line {
            let sources = sourcesByType[type] ?? []
            let (whole, amount) = context.amounts(sources)
            return Line(expenseType: type, label: type.displayName, rule: rules[type]!.rule,
                        ruleExplanation: ruleExplanation(rules[type]!, type: type),
                        share: shares[type]!, shareExplanation: shares[type]!.explanation(year: taxYear),
                        whole: whole, amount: amount, sources: sources)
        }
        let income = line(.rentalIncome)
        var expenses = TaxExpenseType.expenseLines.map(line)
        if nettingMode == .netOfRecharges, let index = expenses.firstIndex(where: { $0.expenseType == .utilities }) {
            expenses[index].ruleExplanation += " Net of the utilities recharged to the tenant (the statement-linked parts of tenant credits received), never below zero."
        }
        let financeCosts = line(.financeCost)
        let foreignTax = line(.foreignTax)
        let notDeductible = line(.notDeductible)
        let expenseTotal = expenses.reduce(Amount.zero) { $0 + $1.amount }
        let totals = Totals(income: income.amount, expenses: expenseTotal, profit: income.amount - expenseTotal,
                            financeCosts: financeCosts.amount, foreignTax: foreignTax.amount)
        return Result(taxYear: taxYear, personId: personId, propertyId: propertyId, currency: property.currency, rate: rate,
                      income: income, expenses: expenses, financeCosts: financeCosts, foreignTax: foreignTax,
                      notDeductible: notDeductible, rentMonths: rentMonths, totals: totals, utilityNetting: utilityNetting,
                      warnings: warnings)
    }

    // MARK: - Rules

    /// The year, the property and the rate: attribution and conversion.
    struct Context {
        let db: Database
        let taxYear: UKTaxYear
        let person: Person
        let property: Property
        /// HMRC rates of the non-GBP currencies (missing ones absent).
        let rates: [Currency: HMRCRate]

        /// The part of `amount` the rule gives this year, with why; `nil` when none.
        func attribute(item transaction: Item, amount: Int, rule: TaxAttributionRule, documents: [EvidenceDocument],
                       receipt: TaxPolicyReceipt? = nil) -> (Int, String)? {
            let date = transaction.date
            switch rule.rule {
            case .byDate, .byRentPeriod:
                // byRentPeriod on a transaction (an income category under another type): its date.
                // A linked invoice's own date wins over the payment's.
                if let invoice = documents.first(where: { $0.docDate != nil && RentalAccounts.invoiceKinds.contains($0.kind) }),
                   let invoiceDate = invoice.docDate {
                    guard within(invoiceDate, taxYear.interval) else { return nil }
                    return (amount, "Invoice dated \(day(invoiceDate)) (\(invoice.displayName)), in \(day(taxYear.start)) – \(day(taxYear.lastDay))")
                }
                guard within(date, taxYear.interval) else { return nil }
                return (amount, "Dated \(day(date)), in \(day(taxYear.start)) – \(day(taxYear.lastDay))")
            case .byDebitMonth:
                guard within(date, taxYear.monthsInterval) else { return nil }
                return (amount, "Debit month \(month(date)), in \(monthsLabel(taxYear.monthsInterval))")
            case .previousCalendarYear:
                let (liability, origin) = liabilityYear(item: transaction, documents: documents)
                guard liability == taxYear.startYear else { return nil }
                return (amount, "Paid \(day(date)) \(origin) → \(taxYear.label)")
            case .apportionCalendarYear:
                let (liability, origin) = liabilityYear(item: transaction, documents: documents)
                guard let (part, days) = RentalAccounts.timeApportioned(amount, calendarYear: liability, to: taxYear) else { return nil }
                return (part, "Paid \(day(date)) \(origin): \(days) in \(taxYear.label) (time-apportioned)")
            case .byQuotaMonth:
                // The note first, then the receipt's period, then a document or the description.
                let receiptPeriod = TaxPeriodHint.period(in: transaction.note) == nil
                    ? receipt?.cover.map { ($0, "from the receipt") } : nil
                let (period, from) = receiptPeriod ?? hint(transaction: transaction, documents: documents, useDescription: true)
                    ?? (monthOf(date), "the debit month")
                return apportionByMonths(amount, period: period, from: from, noun: "quota months")
            case .apportionByCover:
                let months = rule.defaultCoverMonths ?? TaxAttributionRules.defaultCoverMonths
                // The note first, then the insurer's receipt, then a linked document.
                if let period = TaxPeriodHint.period(in: transaction.note) {
                    return apportionByMonths(amount, period: period, from: "from the note", noun: "cover months")
                }
                if let receipt, let cover = receipt.cover {
                    return apportionByMonths(amount, period: cover, from: "from the receipt, \(receipt.label)", noun: "cover months")
                }
                if let (period, from) = hint(transaction: transaction, documents: documents, useDescription: false) {
                    return apportionByMonths(amount, period: period, from: from, noun: "cover months")
                }
                let start = MonthRange.calendar.date(byAdding: .month, value: 1, to: monthOf(date).start)!
                let assumed = DateInterval(start: start, end: MonthRange.calendar.date(byAdding: .month, value: months, to: start)!)
                return apportionByMonths(amount, period: assumed, from: "assumed: \(months) months from the month after the debit", noun: "cover months")
            case .apportionPolicyYear:
                let calendar = MonthRange.calendar
                let year: Int
                let from: String
                if let receipt {
                    year = receipt.effectivePolicyYear
                    from = receipt.policyYear != nil ? "from the receipt, \(receipt.label)" : "\(receipt.label), from its cover"
                } else if let (period, origin) = hint(transaction: transaction, documents: documents, useDescription: false),
                          let first = RentalAccounts.monthSpan(period).first {
                    year = calendar.component(.year, from: first)
                    from = "policy year \(year), the cover's first month (\(origin))"
                } else {
                    year = TaxPolicyReceipts.policyYear(afterDebit: date)
                    from = "assumed: policy year \(year), the year of the month after the debit"
                }
                let policy = DateInterval(start: calendar.date(from: DateComponents(year: year, month: 1, day: 1))!,
                                          end: calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))!)
                return apportionByMonths(amount, period: policy, from: from, noun: "months of policy year \(year)")
            }
        }

        /// The calendar year a payment is the tax of, with why: a whole calendar year in the
        /// note or a linked document's period, else the year before payment.
        func liabilityYear(item transaction: Item, documents: [EvidenceDocument]) -> (Int, String) {
            if let (period, from) = hint(transaction: transaction, documents: documents, useDescription: false),
               let year = RentalAccounts.calendarYear(of: period) {
                return (year, "for \(year) (\(from))")
            }
            let year = MonthRange.calendar.component(.year, from: transaction.date) - 1
            return (year, "for \(year), the year before payment")
        }

        /// The period a transaction covers: its note, else a linked document's period, else
        /// (quota) a year in its description.
        func hint(transaction: Item, documents: [EvidenceDocument], useDescription: Bool) -> (DateInterval, String)? {
            if let period = TaxPeriodHint.period(in: transaction.note) { return (period, "from the note") }
            if let document = documents.first(where: { $0.periodStart != nil && $0.periodEnd != nil }),
               let start = document.periodStart, let end = document.periodEnd, start <= end {
                return (DateInterval(start: PropertyDates.day(start), end: PropertyDates.nextDay(end)), "from the document \(document.displayName)")
            }
            if useDescription, let period = TaxPeriodHint.period(in: transaction.rawDescription) { return (period, "from the description") }
            return nil
        }

        func apportionByMonths(_ amount: Int, period: DateInterval, from: String, noun: String) -> (Int, String)? {
            let months = monthSpan(period)
            let window = taxYear.monthsInterval
            let inside = months.filter { within($0, window) }.count
            guard inside > 0, !months.isEmpty else { return nil }
            // Cumulative rounding (as `PropertyFinance.apportioned`): the years' parts add up to the payment.
            let before = months.filter { $0 < window.start }.count
            func upTo(_ count: Int) -> Int { Int((Double(amount) * Double(count) / Double(months.count)).rounded()) }
            let attributed = upTo(before + inside) - upTo(before)
            let span = "\(month(months.first!)) – \(month(months.last!))"
            return (attributed, "\(inside) of \(months.count) \(noun), \(span) (\(from))")
        }

        /// Whole and person's amounts of a line's sources: native and GBP-native apart, the
        /// share applied per group of sources with the same share, rounded per group. GBP is
        /// converted once per line (the line's native total at the HMRC rate, rounded to the
        /// penny), as the accountant does, so totals are the sum of rounded lines. A source in
        /// a currency without a rate leaves the GBP figures `nil`.
        func amounts(_ sources: [Source]) -> (Amount, Amount) {
            var wholeNative = 0, wholeGBP = 0
            var byShare: [Int: (native: Int, gbp: Int)] = [:]
            var unconvertible = false
            for source in sources {
                guard let (native, gbp) = split(source.attributedMinorUnits, currency: source.currency) else {
                    unconvertible = true
                    continue
                }
                wholeNative += native
                wholeGBP += gbp
                byShare[source.shareBasisPoints, default: (0, 0)].native += native
                byShare[source.shareBasisPoints, default: (0, 0)].gbp += gbp
            }
            let native = byShare.reduce(0) { $0 + shareOf($1.value.native, $1.key) }
            let gbpNative = byShare.reduce(0) { $0 + shareOf($1.value.gbp, $1.key) }
            var whole = amount(native: wholeNative, gbpNative: wholeGBP)
            var share = amount(native: native, gbpNative: gbpNative)
            if unconvertible { whole.gbp = nil; share.gbp = nil }
            return (whole, share)
        }

        /// An amount in `currency` as the property's currency (through the HMRC rate when it
        /// differs), `nil` without the rate.
        func nativeValue(_ value: Int, currency: Currency) -> Int? {
            if currency == property.currency { return value }
            if property.currency == .gbp { return rates[currency].map { $0.gbp(value) } }
            guard currency == .gbp, let rate = rates[property.currency], rate.gbpPerUnit > 0 else { return nil }
            return Int((Double(value) / rate.gbpPerUnit).rounded())
        }

        /// A source's amount as (property currency, already GBP); `nil` when it needs a rate
        /// that's missing (a EUR source of a GBP property).
        func split(_ value: Int, currency: Currency) -> (Int, Int)? {
            if currency == property.currency { return (value, 0) }
            if currency == .gbp { return (0, value) }
            guard let rate = rates[currency] else { return nil }
            return (rate.gbp(value), 0)
        }

        func amount(native: Int, gbpNative: Int) -> Amount {
            if property.currency == .gbp { return Amount(native: native, gbpNative: gbpNative, gbp: native + gbpNative) }
            guard let rate = rates[property.currency] else { return Amount(native: native, gbpNative: gbpNative, gbp: native == 0 ? gbpNative : nil) }
            return Amount(native: native, gbpNative: gbpNative, gbp: rate.gbp(native) + gbpNative)
        }
    }

    static func ruleExplanation(_ rule: TaxAttributionRule, type: TaxExpenseType) -> String {
        switch rule.rule {
        case .byRentPeriod:
            return type == .rentalIncome
                ? "Rent by rent period: the issued receipts' periods, spread by days over April–March."
                : "By date (6 April – 5 April)."
        case .byDebitMonth: return "By debit month: the instalments debited April–March."
        case .byQuotaMonth:
            return "By quota month: the months each payment covers (from the note, a linked document or a year in the description; else the debit month), apportioned to April–March."
        case .apportionByCover:
            let months = rule.defaultCoverMonths ?? TaxAttributionRules.defaultCoverMonths
            return "Apportioned by months of cover (from the note, the insurer's receipt or a linked document; else \(months) months from the month after the debit)."
        case .apportionPolicyYear:
            return "Apportioned by policy year: each policy year's receipts spread evenly over January–December of that year (from the insurer's receipt; else the cover's first month, else the month after the debit), April–March."
        case .previousCalendarYear:
            return "Previous calendar year: a payment in year Y is for Y − 1 (unless the note or a document says otherwise) and counts, whole, in the UK year starting in that year."
        case .apportionCalendarYear:
            return "Calendar year, time-apportioned (HMRC INTM161220): a payment in year Y is the tax of Y − 1 (unless the note or a document says otherwise); each calendar year's tax goes to the UK years it straddles by days — 6 April – 31 December to the UK year starting in it, 1 January – 5 April to the one before."
        case .byDate:
            return type == .financeCost
                ? "By payment date (cash basis): the interest paid 6 April – 5 April."
                : "By date (6 April – 5 April)."
        }
    }

    // MARK: - Helpers

    /// What a rule reads of a source: its date, note and description (a transaction's, or an
    /// insurer's receipt paid outside the bank history).
    struct Item {
        var date: Date
        var note: String?
        var rawDescription: String

        init(date: Date, note: String?, description: String) {
            self.date = date
            self.note = note
            self.rawDescription = description
        }

        init(_ transaction: Transaction) {
            self.init(date: transaction.date, note: transaction.note, description: transaction.rawDescription)
        }
    }

    enum Named { case this, other, none }

    /// Whether a PT tax payment names the person alone (a linked document's persons, or the
    /// note, as whole words): `.this` / `.other` when exactly one side is named; `.none` when
    /// nobody is, or the person and another owner both are (a joint payment: the split applies).
    static func named(person: String, others: [String], note: String?, documents: [EvidenceDocument]) -> Named {
        let folded = note.map(fold) ?? ""
        func mentions(_ name: String) -> Bool {
            if documents.contains(where: { $0.persons.contains { fold($0) == fold(name) } }) { return true }
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: fold(name)) + "(?![\\p{L}\\p{N}])"
            return folded.range(of: pattern, options: .regularExpression) != nil
        }
        let this = mentions(person)
        let other = others.contains(where: mentions)
        switch (this, other) {
        case (true, false): return .this
        case (false, true): return .other
        default: return .none
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Kinds whose document date is an invoice date (the by-date rule prefers it).
    static let invoiceKinds: Set<DocumentKind> = [.accountantInvoice, .legalInvoice, .utilityInvoice, .courtFee, .lettingAgentFee]

    /// The person's rent on the basis their foreign tax line uses, for the FTCR rate check: the
    /// calendar year the UK year starts in (previous-calendar-year basis), or calendar years N
    /// and N + 1 apportioned to the UK year by days, as the tax is (time-apportioned basis).
    public static func foreignTaxBasisRent(db: Database, accounts: Result) throws -> Int {
        let year = accounts.taxYear
        func rent(_ calendarYear: Int) throws -> Int {
            try calendarYearRent(db: db, calendarYear: calendarYear, personId: accounts.personId, propertyId: accounts.propertyId)
        }
        guard accounts.foreignTax.rule == .apportionCalendarYear else { return try rent(year.startYear) }
        return try [year.startYear, year.startYear + 1].reduce(0) { total, calendarYear in
            total + (timeApportioned(try rent(calendarYear), calendarYear: calendarYear, to: year)?.0 ?? 0)
        }
    }

    /// 1 January of `year` to 1 January of the next.
    static func calendarYearInterval(_ year: Int) -> DateInterval {
        let calendar = MonthRange.calendar
        return DateInterval(start: calendar.date(from: DateComponents(year: year, month: 1, day: 1))!,
                            end: calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))!)
    }

    /// The part of calendar year `calendarYear`'s `amount` that falls in `taxYear` by days,
    /// with "270 of 365 days"; `nil` when the years don't overlap. Rounded cumulatively, so
    /// the two UK years' parts add up to the amount.
    static func timeApportioned(_ amount: Int, calendarYear: Int, to taxYear: UKTaxYear) -> (Int, String)? {
        let year = calendarYearInterval(calendarYear)
        let from = max(year.start, taxYear.start), to = min(year.end, taxYear.end)
        guard from < to else { return nil }
        let total = PropertyFinance.days(year.start, year.end)
        let before = PropertyFinance.days(year.start, from)
        let inside = PropertyFinance.days(from, to)
        func upTo(_ days: Int) -> Int { Int((Double(amount) * Double(days) / Double(total)).rounded()) }
        return (upTo(before + inside) - upTo(before), "\(inside) of \(total) days")
    }

    /// The year of a period that is exactly one calendar year (1 Jan – 31 Dec), else `nil`.
    static func calendarYear(of period: DateInterval) -> Int? {
        let calendar = MonthRange.calendar
        let year = calendar.component(.year, from: period.start)
        guard period.start == calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              period.end == calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else { return nil }
        return year
    }

    /// The documents linked to each record of `type` in `ids`, by document date.
    static func linkedDocuments(db: Database, type: EvidenceEntityType, ids: [Int64]) throws -> [Int64: [EvidenceDocument]] {
        guard !ids.isEmpty else { return [:] }
        let wanted = Set(ids)
        let rows = try Row.fetchAll(db, sql: """
            SELECT documentLink.entityId AS entityId, document.* FROM documentLink JOIN document ON document.id = documentLink.documentId
            WHERE documentLink.entityType = ?
            ORDER BY document.docDate IS NULL, document.docDate, document.id
            """, arguments: [type.rawValue])
        var result: [Int64: [EvidenceDocument]] = [:]
        for row in rows {
            let entityId: Int64 = row["entityId"]
            guard wanted.contains(entityId) else { continue }
            result[entityId, default: []].append(try EvidenceDocument(row: row))
        }
        return result
    }

    /// The documents of a recharge statement: its invoices' and its manual lines'.
    static func statementDocumentIds(db: Database, statementId: Int64) throws -> [Int64] {
        try Int64.fetchAll(db, sql: """
            SELECT COALESCE(utilityInvoice.documentId, rechargeLine.documentId) AS documentId FROM rechargeLine
            LEFT JOIN utilityInvoice ON utilityInvoice.id = rechargeLine.invoiceId
            WHERE rechargeLine.statementId = ? AND COALESCE(utilityInvoice.documentId, rechargeLine.documentId) IS NOT NULL
            ORDER BY rechargeLine.id
            """, arguments: [statementId])
    }

    static func linkedDocumentIds(db: Database, type: EvidenceEntityType, ids: [Int64]) throws -> [Int64: [Int64]] {
        try linkedDocuments(db: db, type: type, ids: ids).mapValues { $0.compactMap(\.id) }
    }

    /// `[start, end)` (`DateInterval.contains` includes the end).
    static func within(_ date: Date, _ interval: DateInterval) -> Bool {
        date >= interval.start && date < interval.end
    }

    static func shareOf(_ value: Int, _ basisPoints: Int) -> Int {
        Int((Double(value) * Double(basisPoints) / Double(PropertyOwner.wholeShare)).rounded())
    }

    /// The months a period covers: from the month of its start (the next one when it starts
    /// after the 15th), as many as its length in months, rounded (at least one).
    static func monthSpan(_ period: DateInterval) -> [Date] {
        let calendar = MonthRange.calendar
        let start = PropertyDates.day(period.start)
        var first = monthOf(start).start
        if calendar.component(.day, from: start) > 15 { first = calendar.date(byAdding: .month, value: 1, to: first)! }
        let days = Double(PropertyFinance.days(start, period.end))
        let count = max(1, Int((days / (365.25 / 12)).rounded()))
        return (0..<count).map { calendar.date(byAdding: .month, value: $0, to: first)! }
    }

    static func monthOf(_ date: Date) -> DateInterval {
        let (year, month) = MonthRange.components(of: date)
        let start = MonthRange.of(year: year, month: month).start
        return DateInterval(start: start, end: MonthRange.calendar.date(byAdding: .month, value: 1, to: start)!)
    }

    static func day(_ date: Date) -> String { MissingEvidence.day(date) }

    static func month(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = MonthRange.calendar
        formatter.timeZone = MonthRange.calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }

    static func monthsLabel(_ window: DateInterval) -> String {
        "\(month(window.start)) – \(month(window.end.addingTimeInterval(-1)))"
    }
}
