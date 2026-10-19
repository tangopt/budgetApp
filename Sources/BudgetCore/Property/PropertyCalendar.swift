import GRDB
import Foundation

public enum PropertyObligationKind: String, Codable, CaseIterable, Sendable {
    /// Portuguese property tax instalment (May, August, November).
    case imiInstalment
    /// Portuguese income tax return (IRS), by 30 June for the previous year.
    case ptIncomeTaxReturn
    /// UK Self Assessment, 31 January: online return, balancing payment, 1st payment on account.
    case ukSelfAssessmentJanuary
    /// UK Self Assessment, 31 July: 2nd payment on account.
    case ukSelfAssessmentJuly
    /// The mortgage's variable rate is revised: on the 1st of the property's revision months
    /// (`PropertyMortgageTerms.revisionMonths`, by default 1 January, April, July and October).
    case mortgageRateReset
    case mortgageInstalment
    /// An insurance cover period ends: renew (from the documents' cover periods, else a year
    /// after the last payment).
    case insuranceRenewal
    /// A cost that recurs in the property's history (condomínio, utilities…).
    case recurringCost
}

/// Something due on a date (spec 2026-10-16 §1 "Obligations calendar").
public struct PropertyObligation: Equatable, Identifiable, Sendable {
    /// Stable: kind, date and source.
    public var id: String
    public var date: Date
    public var kind: PropertyObligationKind
    public var title: String
    /// Expected amount (positive, in `currency`) when one can be told.
    public var expectedMinorUnits: Int?
    public var currency: Currency?
    public var categoryId: Int64?
    /// Projected from history or a rule rather than known.
    public var isEstimate: Bool
}

/// A cost that repeats in the property's history.
public struct PropertyRecurringPattern: Equatable, Sendable {
    /// "category:<id>" or "mortgage:<account id>".
    public var key: String
    public var title: String
    public var categoryId: Int64?
    public var accountId: Int64?
    /// 1, 3 or 12.
    public var everyMonths: Int
    public var lastDate: Date
    /// Positive, in the transaction's account currency.
    public var lastAmountMinorUnits: Int
    public var currency: Currency
    public var occurrences: Int

    /// The first date after the last occurrence it's due again.
    public var nextDate: Date { MonthRange.calendar.date(byAdding: .month, value: everyMonths, to: lastDate)! }
}

/// The property's obligations: fixed rules (IMI, PT IRS, UK Self Assessment), mortgage rate
/// resets and instalments, insurance renewals, and costs that recur in its history.
public enum PropertyCalendar {
    /// How far back history is read for recurring costs.
    /// Long enough for a yearly cost to show two payments a year apart and still be read
    /// months after the latest (2 × 365 + 35 days).
    public static let historyDays = 765

    /// Obligations dated in `[from, to)`, by date then kind. Recurring and mortgage items are
    /// projected from the history up to `today`.
    public static func obligations(db: Database, propertyId: Int64, from: Date, to: Date, today: Date = Date()) throws -> [PropertyObligation] {
        guard let property = try Property.fetchOne(db, key: propertyId) else { throw PropertyError.propertyNotFound }
        let calendar = MonthRange.calendar
        var result: [PropertyObligation] = []
        func add(_ date: Date, _ kind: PropertyObligationKind, _ title: String, amount: Int? = nil, currency: Currency? = nil,
                 categoryId: Int64? = nil, estimate: Bool, source: String = "") {
            guard date >= from && date < to else { return }
            result.append(PropertyObligation(id: "\(kind.rawValue)/\(MissingEvidence.day(date))/\(source)", date: date, kind: kind, title: title,
                                             expectedMinorUnits: amount, currency: currency, categoryId: categoryId, isEstimate: estimate))
        }
        let firstYear = calendar.component(.year, from: from)
        let lastYear = calendar.component(.year, from: to)
        func lastDay(_ year: Int, _ month: Int) -> Date { PropertyDates.day(MonthRange.of(year: year, month: month).end) }

        let categories = try propertyCategories(db: db, propertyId: propertyId)
        let imiCategoryIds = categories.filter { words($0.name).contains("imi") }.compactMap(\.id)
        if property.country == "PT" {
            let imi = imiCategoryIds.isEmpty ? [] : try Transaction.filter(imiCategoryIds.contains(Column("categoryId")))
                .order(Column("date")).fetchAll(db)
            // The span the IMI history covers: a month outside it says nothing about skipping.
            let covered = imi.first.map { first in DateInterval(start: PropertyDates.day(first.date), end: PropertyDates.nextDay(imi.last!.date)) }
            for year in firstYear...lastYear {
                for month in [5, 8, 11] {
                    // Estimate: what was paid in the same month a year before. With history,
                    // a month nothing was paid in last year is skipped (fewer instalments).
                    // Last year's payment for this instalment, a month either side (paid early or late).
                    let monthStart = MonthRange.of(year: year - 1, month: month).start
                    let start = calendar.date(byAdding: .month, value: -1, to: monthStart)!
                    let end = calendar.date(byAdding: .month, value: 2, to: monthStart)!
                    let paid = imi.filter { $0.date >= start && $0.date < end }
                    if paid.isEmpty, let covered, covered.start <= start, covered.end >= end { continue }
                    let amount = paid.isEmpty ? nil : abs(paid.reduce(0) { $0 + $1.amountMinorUnits })
                    add(lastDay(year, month), .imiInstalment, "IMI instalment", amount: amount, currency: amount == nil ? nil : property.currency,
                        categoryId: imiCategoryIds.first, estimate: true)
                }
                add(lastDay(year, 6), .ptIncomeTaxReturn, "PT IRS return for \(year - 1)", estimate: false)
            }
        }
        if try hasUKTaxpayer(db: db, propertyId: propertyId) {
            for year in firstYear...lastYear {
                let ended = UKTaxYear(startYear: year - 2)
                add(lastDay(year, 1), .ukSelfAssessmentJanuary,
                    "UK Self Assessment: \(ended.label) return and balancing payment, 1st payment on account", estimate: false)
                add(lastDay(year, 7), .ukSelfAssessmentJuly, "UK Self Assessment: 2nd payment on account", estimate: false)
            }
        }

        // Mortgage: instalments as a recurring pattern; the rate revised on the 1st of the
        // property's revision months (`PropertyMortgageTerms`, by default every quarter), while
        // a mortgage account has instalments and until the final one when it's known (without
        // one, while something is still owed).
        let terms = try MortgageTerms.terms(db: db, propertyId: propertyId)
        let mortgageIds = try Properties.accounts(db: db, propertyId: propertyId, role: .mortgage).map(\.accountId)
        var hasInstalments = false
        for accountId in mortgageIds {
            if try !mortgageLegs(db: db, accountId: accountId, before: today).isEmpty { hasInstalments = true }
        }
        if hasInstalments, terms.finalInstalmentDate == nil {
            let owed = try PropertyFinance.balance(db: db, property: property, conversion: try CurrencyConversion.current(db: db),
                                                   accountIds: mortgageIds, asOf: PropertyDates.day(today))
            if owed.native <= 0 { hasInstalments = false }
        }
        if hasInstalments {
            let end = terms.finalInstalmentDate.map { min(to, PropertyDates.nextDay($0)) } ?? to
            for date in terms.revisionDates(from: from, to: end) {
                add(date, .mortgageRateReset, "Mortgage rate revision", estimate: false, source: "\(propertyId)")
            }
        }

        let patterns = try recurringPatterns(db: db, propertyId: propertyId, asOf: today)
        for pattern in patterns {
            let kind: PropertyObligationKind = pattern.key.hasPrefix("mortgage:") ? .mortgageInstalment : .recurringCost
            var k = 1
            while let date = calendar.date(byAdding: .month, value: k * pattern.everyMonths, to: pattern.lastDate), date < to {
                add(date, kind, pattern.title, amount: pattern.lastAmountMinorUnits, currency: pattern.currency, categoryId: pattern.categoryId,
                    estimate: true, source: pattern.key)
                k += 1
            }
        }

        // Insurance: renew when the last documented cover ends, else a year after the last
        // payment when payments recur yearly (monthly or quarterly ones are recurring costs).
        let yearly = Set(try recurringPatterns(db: db, propertyId: propertyId, asOf: today, includeYearlyInsurance: true)
            .filter { $0.everyMonths == 12 }.compactMap(\.categoryId))
        for category in categories where isInsurance(category.name) {
            guard let categoryId = category.id else { continue }
            let payments = try Transaction.filter(Column("categoryId") == categoryId && Column("amountMinorUnits") < 0)
                .order(Column("date")).fetchAll(db)
            guard let last = payments.last else { continue }
            let coverEnd = try Date.fetchOne(db, sql: """
                SELECT MAX(document.periodEnd) FROM document JOIN documentLink ON documentLink.documentId = document.id
                WHERE documentLink.entityType = ? AND documentLink.entityId IN (SELECT id FROM transaction_ WHERE categoryId = ?)
                """, arguments: [EvidenceEntityType.transaction.rawValue, categoryId])
            guard coverEnd != nil || yearly.contains(categoryId) else { continue }
            let first = coverEnd.map(PropertyDates.nextDay) ?? calendar.date(byAdding: .month, value: 12, to: PropertyDates.day(last.date))!
            let currency = try Account.fetchOne(db, key: last.accountId)?.currency
            var k = 0
            while let date = calendar.date(byAdding: .month, value: 12 * k, to: first), date < to {
                add(date, .insuranceRenewal, "\(category.name) renewal", amount: abs(last.amountMinorUnits), currency: currency,
                    categoryId: categoryId, estimate: coverEnd == nil, source: "\(categoryId)")
                k += 1
            }
        }
        return result.sorted { ($0.date, $0.kind.rawValue, $0.id) < ($1.date, $1.kind.rawValue, $1.id) }
    }

    /// Costs that repeat monthly, quarterly or yearly in the `historyDays` before `today`: per
    /// expense category of the property (IMI has its own rule; yearly insurance is a renewal,
    /// not a recurring cost, unless `includeYearlyInsurance`; rows on the mortgage accounts are
    /// left out), plus each mortgage account's instalments. The typical (median) gap decides:
    /// 25–35 days monthly, 80–100 quarterly (3+ occurrences), 330–400 yearly (2+). A pattern
    /// whose last occurrence is more than two periods before `today` has stopped and is dropped
    /// (unless `dropStopped` is false: the checks keep chasing it until it occurs again).
    public static func recurringPatterns(db: Database, propertyId: Int64, asOf today: Date,
                                         includeYearlyInsurance: Bool = false, dropStopped: Bool = true) throws -> [PropertyRecurringPattern] {
        let since = MonthRange.calendar.date(byAdding: .day, value: -historyDays, to: today)!
        let mortgageIds = try Properties.accounts(db: db, propertyId: propertyId, role: .mortgage).map(\.accountId)
        let currencies = Dictionary(uniqueKeysWithValues: try Account.fetchAll(db).compactMap { a in a.id.map { ($0, a.currency) } })
        var patterns: [PropertyRecurringPattern] = []
        for category in try propertyCategories(db: db, propertyId: propertyId) where category.type == .expense {
            guard let id = category.id, !words(category.name).contains("imi") else { continue }
            let rows = try Transaction.filter(Column("categoryId") == id && Column("amountMinorUnits") < 0
                                              && Column("date") >= since && Column("date") <= today
                                              && !mortgageIds.contains(Column("accountId")))
                .order(Column("date"), Column("id")).fetchAll(db)
            if let pattern = detect(rows, key: "category:\(id)", title: category.name, categoryId: id, currencies: currencies, asOf: today, dropStopped: dropStopped),
               includeYearlyInsurance || !(isInsurance(category.name) && pattern.everyMonths == 12) {
                patterns.append(pattern)
            }
        }
        for accountId in mortgageIds {
            let legs = try mortgageLegs(db: db, accountId: accountId, before: today).filter { $0.date >= since }
            if let pattern = detect(legs, key: "mortgage:\(accountId)", title: "Mortgage instalment", categoryId: nil, currencies: currencies, asOf: today,
                                     dropStopped: dropStopped) {
                patterns.append(pattern)
            }
        }
        return patterns
    }

    static func detect(_ rows: [Transaction], key: String, title: String, categoryId: Int64?, currencies: [Int64: Currency],
                       asOf today: Date, dropStopped: Bool = true) -> PropertyRecurringPattern? {
        guard rows.count >= 2, let last = rows.last else { return nil }
        let days = rows.map { PropertyDates.day($0.date) }
        let gaps = zip(days.dropFirst(), days).map { PropertyFinance.days($1, $0) }.sorted()
        let median = gaps[gaps.count / 2]
        let months: Int
        switch median {
        case 25...35 where rows.count >= 3: months = 1
        case 80...100 where rows.count >= 3: months = 3
        case 330...400: months = 12
        default: return nil
        }
        let lastDay = PropertyDates.day(last.date)
        if dropStopped {
            guard MonthRange.calendar.date(byAdding: .month, value: 2 * months, to: lastDay)! >= PropertyDates.day(today) else { return nil }
        }
        return PropertyRecurringPattern(key: key, title: title, categoryId: categoryId, accountId: last.accountId, everyMonths: months,
                                        lastDate: PropertyDates.day(last.date), lastAmountMinorUnits: abs(last.amountMinorUnits),
                                        currency: currencies[last.accountId] ?? .gbp, occurrences: rows.count)
    }

    /// The instalments paid into a mortgage account: its incoming transfer legs, oldest first.
    static func mortgageLegs(db: Database, accountId: Int64, before today: Date) throws -> [Transaction] {
        try Transaction.fetchAll(db, sql: """
            SELECT * FROM transaction_ WHERE accountId = ? AND amountMinorUnits > 0 AND date <= ?
            AND categoryId IN (SELECT id FROM category WHERE type = ?) ORDER BY date, id
            """, arguments: [accountId, today, CategoryType.transfer.rawValue])
    }

    static func propertyCategories(db: Database, propertyId: Int64) throws -> [Category] {
        let groupIds = try Properties.categoryGroupIds(db: db, propertyId: propertyId)
        return try Category.filter(groupIds.contains(Column("groupId"))).order(Column("name"), Column("id")).fetchAll(db)
    }

    /// Whether anyone who owns (or owned) the property has a UK tax identifier.
    static func hasUKTaxpayer(db: Database, propertyId: Int64) throws -> Bool {
        let owners = try Properties.owners(db: db, propertyId: propertyId)
        guard !owners.isEmpty else { return false }
        return try Person.filter(owners.map(\.personId).contains(Column("id"))).fetchAll(db)
            .contains { $0.ukUtr != nil || $0.ukNino != nil }
    }

    static func words(_ name: String) -> Set<String> {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return Set(folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    static func isInsurance(_ name: String) -> Bool {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.contains("insurance") || folded.contains("seguro")
    }
}
