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

        public var entity: EvidenceEntity {
            switch self {
            case let .transaction(id): return .transaction(id)
            case let .rentReceipt(id): return .rentReceipt(id)
            case let .manualItem(id): return .taxManualItem(id)
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

        var sourcesByType: [TaxExpenseType: [Source]] = [:]
        var rules: [TaxExpenseType: TaxAttributionRule] = [:]
        var shares: [TaxExpenseType: TaxShare] = [:]
        for type in TaxExpenseType.allCases {
            rules[type] = try TaxAttributionRules.effective(db: db, expenseType: type, startYear: taxYear.startYear)
            shares[type] = try TaxSplits.share(db: db, startYear: taxYear.startYear, personId: personId, propertyId: propertyId, expenseType: type)
        }

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
        // with (`calendarYearRent`) — so, like the PT IRS payments for N, it feeds UK year
        // N/N+1. A receipt spanning two years is spread by days. At the rent share.
        let calendarYear = DateInterval(start: calendar.date(from: DateComponents(year: taxYear.startYear, month: 1, day: 1))!,
                                        end: calendar.date(from: DateComponents(year: taxYear.startYear + 1, month: 1, day: 1))!)
        let withheld = try RentReceipts.receipts(db: db, propertyId: propertyId, overlapping: calendarYear).filter { $0.withholdingMinorUnits > 0 }
        let withheldDocs = try linkedDocumentIds(db: db, type: .rentReceipt, ids: withheld.compactMap(\.id))
        for receipt in withheld {
            let attributed = PropertyFinance.apportioned(receipt.withholdingMinorUnits, start: receipt.periodStart, lastDay: receipt.periodEnd, to: calendarYear)
            guard attributed != 0 else { continue }
            let total = PropertyFinance.days(receipt.periodStart, PropertyDates.nextDay(receipt.periodEnd))
            let inside = PropertyFinance.days(max(receipt.periodStart, calendarYear.start), min(PropertyDates.nextDay(receipt.periodEnd), calendarYear.end))
            sourcesByType[.foreignTax, default: []].append(Source(
                reference: .rentReceipt(receipt.id!), date: receipt.receiptDate,
                description: "Withheld by the tenant, rent receipt \(receipt.receiptNumber)", currency: property.currency,
                amountMinorUnits: receipt.withholdingMinorUnits, attributedMinorUnits: attributed,
                shareBasisPoints: shares[.rentalIncome]!.shareBasisPoints,
                explanation: "Rent period \(day(receipt.periodStart)) – \(day(receipt.periodEnd)): \(inside) of \(total) days in \(taxYear.startYear), PT tax for \(taxYear.startYear) → \(taxYear.label); at the rent share",
                documentIds: withheldDocs[receipt.id!] ?? []))
        }

        // Transactions through their type's rule.
        for transaction in transactions {
            guard let categoryId = transaction.categoryId, let type = typeByCategory[categoryId] else { continue }
            let rule = rules[type]!
            // Under byRentPeriod the receipts are the rent; the credits are their payments.
            if type == .rentalIncome && rule.rule == .byRentPeriod { continue }
            // Rent (and not-deductible income) counts credits up; every other line counts costs
            // up, so a credit filed under it (a refund) reduces it.
            let isIncome = categoryType[categoryId] == .income
            let natural = (type == .rentalIncome || type == .notDeductible) && isIncome ? transaction.amountMinorUnits : -transaction.amountMinorUnits
            let docs = documents[transaction.id!] ?? []
            guard let (attributed, explanation) = context.attribute(transaction: transaction, amount: natural, rule: rule, documents: docs) else { continue }
            var share = shares[type]!.shareBasisPoints
            var explained = explanation
            if type == .foreignTax {
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
        let expenses = TaxExpenseType.expenseLines.map(line)
        let financeCosts = line(.financeCost)
        let foreignTax = line(.foreignTax)
        let notDeductible = line(.notDeductible)
        let expenseTotal = expenses.reduce(Amount.zero) { $0 + $1.amount }
        let totals = Totals(income: income.amount, expenses: expenseTotal, profit: income.amount - expenseTotal,
                            financeCosts: financeCosts.amount, foreignTax: foreignTax.amount)
        return Result(taxYear: taxYear, personId: personId, propertyId: propertyId, currency: property.currency, rate: rate,
                      income: income, expenses: expenses, financeCosts: financeCosts, foreignTax: foreignTax,
                      notDeductible: notDeductible, rentMonths: rentMonths, totals: totals, warnings: warnings)
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
        func attribute(transaction: Transaction, amount: Int, rule: TaxAttributionRule, documents: [EvidenceDocument]) -> (Int, String)? {
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
                let liability: Int
                let origin: String
                // Only a whole calendar year says which year a payment is for.
                if let (period, from) = hint(transaction: transaction, documents: documents, useDescription: false),
                   let year = RentalAccounts.calendarYear(of: period) {
                    liability = year
                    origin = "for \(liability) (\(from))"
                } else {
                    liability = MonthRange.calendar.component(.year, from: date) - 1
                    origin = "for \(liability), the year before payment"
                }
                guard liability == taxYear.startYear else { return nil }
                return (amount, "Paid \(day(date)) \(origin) → \(taxYear.label)")
            case .byQuotaMonth:
                let (period, from) = hint(transaction: transaction, documents: documents, useDescription: true)
                    ?? (monthOf(date), "the debit month")
                return apportionByMonths(amount, period: period, from: from, noun: "quota months")
            case .apportionByCover:
                let months = rule.defaultCoverMonths ?? TaxAttributionRules.defaultCoverMonths
                if let (period, from) = hint(transaction: transaction, documents: documents, useDescription: false) {
                    return apportionByMonths(amount, period: period, from: from, noun: "cover months")
                }
                let start = MonthRange.calendar.date(byAdding: .month, value: 1, to: monthOf(date).start)!
                let assumed = DateInterval(start: start, end: MonthRange.calendar.date(byAdding: .month, value: months, to: start)!)
                return apportionByMonths(amount, period: assumed, from: "assumed: \(months) months from the month after the debit", noun: "cover months")
            }
        }

        /// The period a transaction covers: its note, else a linked document's period, else
        /// (quota) a year in its description.
        func hint(transaction: Transaction, documents: [EvidenceDocument], useDescription: Bool) -> (DateInterval, String)? {
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
            return "Apportioned by months of cover (from the note or a linked document; else \(months) months from the month after the debit)."
        case .previousCalendarYear:
            return "Previous calendar year: a payment in year Y is for Y − 1 (unless the note or a document says otherwise) and counts, whole, in the UK year starting in that year."
        case .byDate:
            return type == .financeCost
                ? "By payment date (cash basis): the interest paid 6 April – 5 April."
                : "By date (6 April – 5 April)."
        }
    }

    // MARK: - Helpers

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
