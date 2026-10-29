import Foundation
import GRDB

/// One property's cash flow by month for a year: what came in (rent and recharges received) and went out (costs and
/// bills, the mortgage interest included, never the capital), in the property's currency. Labelled by the property's
/// tenancies (their reference labels), never the tenant.
public struct TenancyCashFlow: Equatable, Identifiable, Sendable {
    public struct Month: Equatable, Sendable {
        /// 1...12.
        public var month: Int
        public var rent: Int
        public var recharges: Int
        public var paidOut: Int
        public var received: Int { rent + recharges }
        public var net: Int { rent + recharges - paidOut }
    }

    public var propertyName: String
    public var currency: Currency
    public var year: Int
    /// The reference labels of the tenancies that ran during the year (all of them when none did).
    public var tenancyNames: [String]
    /// January to December; months that haven't happened are zero.
    public var months: [Month]
    public var id: String { propertyName }

    public var totalReceived: Int { months.reduce(0) { $0 + $1.received } }
    public var totalPaidOut: Int { months.reduce(0) { $0 + $1.paidOut } }
    public var totalNet: Int { totalReceived - totalPaidOut }
}

/// One property's return for a year: net rental income so far and projected for the whole year (rent and recharges less
/// costs, the mortgage interest counted as a cost, the capital repaid left out), the yields on the property's value, a
/// monthly running total and last year's to compare.
public struct PropertyReturn: Equatable, Identifiable, Sendable {
    public enum ValueBasis: Equatable, Sendable {
        /// The latest balance of the account that tracks the property's value (its name).
        case valuation(String)
        case purchasePrice
    }

    public var propertyName: String
    public var currency: Currency
    public var year: Int
    /// Income received so far this year (everything in the property's income categories).
    public var incomeToDate: Int
    /// Costs so far, mortgage interest included.
    public var costsToDate: Int
    /// Of `costsToDate`, the mortgage interest.
    public var mortgageInterestToDate: Int
    public var netToDate: Int
    /// The year's net at the pace so far; the actual for a finished year; nil with under a month of letting to go on.
    public var projectedNet: Int?
    /// The previous year's net, nil when the property had nothing then.
    public var lastYearNet: Int?
    /// What the property is worth (`valueBasis`) in the property's currency.
    public var value: Int?
    public var valueBasis: ValueBasis?
    /// Rent received, annualised over the time let so far, over the value.
    public var grossYield: Double?
    /// Net income, annualised likewise, over the value.
    public var netYield: Double?
    /// The net so far at the end of each month, January to December; nil for the months to come.
    public var cumulative: [Int?]
    /// Last year's, all twelve.
    public var lastYearCumulative: [Int]
    public var id: String { propertyName }
}

/// The Dashboard's Property widgets with figures (the cash flow by month and the return for a year), as the person
/// signed in may see them.
public struct DashboardPropertyWidgets: Equatable, Sendable {
    public var cashFlows: [TenancyCashFlow]
    public var returns: [PropertyReturn]

    public init(cashFlows: [TenancyCashFlow] = [], returns: [PropertyReturn] = []) {
        self.cashFlows = cashFlows
        self.returns = returns
    }

    public var isEmpty: Bool { cashFlows.isEmpty && returns.isEmpty }
}

extension DashboardPropertyWidgets {
    /// The widgets for `year` on `today`. `viewer` nil reads everything (the Mac, no sign-in); a member needs View on
    /// Property, as in `DashboardReview`. Properties without a tenancy are left out; no property is empty. Reads only.
    public static func load(db: Database, today: Date, year: Int, viewer: AccessActor? = nil) throws -> DashboardPropertyWidgets {
        if let viewer, try AccessPolicy.level(viewer, .property, db: db) < .view { return DashboardPropertyWidgets() }
        let day = PropertyDates.day(today)
        guard year <= MonthRange.components(of: day).year else { return DashboardPropertyWidgets() }
        let conversion = try CurrencyConversion.current(db: db)
        var result = DashboardPropertyWidgets()
        for property in try Properties.all(db: db) {
            guard let propertyId = property.id else { continue }
            let tenancies = try Tenancies.all(db: db, propertyId: propertyId)
            guard !tenancies.isEmpty else { continue }
            let this = try PropertyFinance.summary(db: db, propertyId: propertyId, period: .calendarYear(year), conversion: conversion, today: day)
            let last = try PropertyFinance.summary(db: db, propertyId: propertyId, period: .calendarYear(year - 1), conversion: conversion, today: day)
            result.cashFlows.append(cashFlow(property: property, tenancies: tenancies, summary: this, year: year))
            result.returns.append(try propertyReturn(db: db, property: property, tenancies: tenancies, conversion: conversion,
                                                     this: this, last: last, year: year, today: day))
        }
        return result
    }

    // MARK: Figures

    static func paidOut(_ figures: PropertyFigures) -> Int { figures.costs.native + figures.interestOutsideCosts.native }
    static func net(_ figures: PropertyFigures) -> Int { figures.income.native - paidOut(figures) }

    static func cashFlow(property: Property, tenancies: [Tenancy], summary: PropertySummary, year: Int) -> TenancyCashFlow {
        let calendar = MonthRange.calendar
        let yearStart = MonthRange.of(year: year, month: 1).start
        let yearEnd = MonthRange.of(year: year + 1, month: 1).start
        let running = tenancies.filter { $0.startDate < yearEnd && ($0.endDate.map { $0 >= yearStart } ?? true) }
        let names = (running.isEmpty ? tenancies : running).map(\.referenceLabel)
        let months = (1...12).map { number -> TenancyCashFlow.Month in
            let figures = summary.months.first { calendar.component(.month, from: $0.start) == number }?.figures
            return TenancyCashFlow.Month(month: number, rent: figures?.rentReceived.native ?? 0, recharges: figures?.recharges.native ?? 0,
                                         paidOut: figures.map(paidOut) ?? 0)
        }
        return TenancyCashFlow(propertyName: property.name, currency: property.currency, year: year, tenancyNames: names, months: months)
    }

    /// The running total of each month's net, January to December.
    static func cumulative(_ summary: PropertySummary) -> [Int] {
        let calendar = MonthRange.calendar
        var total = 0
        return (1...12).map { number in
            total += summary.months.first { calendar.component(.month, from: $0.start) == number }.map { net($0.figures) } ?? 0
            return total
        }
    }

    static func propertyReturn(db: Database, property: Property, tenancies: [Tenancy], conversion: CurrencyConversion,
                               this: PropertySummary, last: PropertySummary, year: Int, today: Date) throws -> PropertyReturn {
        let figures = this.totals
        let netToDate = net(figures)
        let (todayYear, todayMonth) = MonthRange.components(of: today)
        let elapsedMonths = year < todayYear ? 12 : todayMonth
        let all = cumulative(this)
        let lastCumulative = cumulative(last)
        let hadLastYear = last.totals.income.native != 0 || last.totals.costs.native != 0

        // The pace so far over the time the property has been let this year, carried to the year's end.
        var projected: Int?
        if year < todayYear {
            projected = netToDate
        } else if let interval = this.yieldInterval {
            let letDays = PropertyFinance.days(interval.start, interval.end)
            let yearEnd = MonthRange.of(year: year + 1, month: 1).start
            let remaining = PropertyFinance.days(interval.end, yearEnd)
            if letDays >= 28 { projected = netToDate + Int((Double(netToDate) / Double(letDays) * Double(max(remaining, 0))).rounded()) }
        }

        let (value, basis) = try propertyValue(db: db, property: property, conversion: conversion, asOf: min(today, MonthRange.of(year: year, month: 12).end))
        var gross: Double?, netYield: Double?
        if let value, value > 0, let interval = this.yieldInterval {
            let years = Double(PropertyFinance.days(interval.start, interval.end)) / 365
            if years > 0 {
                gross = Double(figures.rentReceived.native) / Double(value) / years
                netYield = Double(netToDate) / Double(value) / years
            }
        }
        return PropertyReturn(propertyName: property.name, currency: property.currency, year: year,
                              incomeToDate: figures.income.native, costsToDate: paidOut(figures), mortgageInterestToDate: figures.mortgageInterest.native,
                              netToDate: netToDate, projectedNet: projected, lastYearNet: hadLastYear ? net(last.totals) : nil,
                              value: value, valueBasis: basis, grossYield: gross, netYield: netYield,
                              cumulative: (0..<12).map { $0 < elapsedMonths ? all[$0] : nil }, lastYearCumulative: lastCumulative)
    }

    /// What the property is worth in its own currency: the latest balance of the account that tracks its value (an
    /// investment-kind account among its "other" accounts, or the one named "<property> valuation"), else its purchase
    /// price.
    static func propertyValue(db: Database, property: Property, conversion: CurrencyConversion, asOf day: Date) throws -> (Int?, PropertyReturn.ValueBasis?) {
        guard let propertyId = property.id else { return (nil, nil) }
        var candidates: [Account] = []
        for link in try Properties.accounts(db: db, propertyId: propertyId, role: .other) {
            if let account = try Account.fetchOne(db, key: link.accountId), account.kind == .investment { candidates.append(account) }
        }
        let wanted = (property.name + " valuation").lowercased()
        if candidates.isEmpty, let named = try Account.fetchAll(db).first(where: { $0.name.lowercased() == wanted || $0.alias?.lowercased() == wanted }) {
            candidates = [named]
        }
        if let account = candidates.first, let id = account.id {
            let signed = try BalanceUpdates.computedBalance(db: db, accountId: id, asOf: day)
            let entered = NetWorthCalculator.enteredBalance(signedMinorUnits: signed, accountKind: account.kind)
            let value = PropertyFinance.convert(entered, currency: account.currency, property: property, conversion: conversion).native
            if value > 0 { return (value, .valuation(account.displayName)) }
        }
        if let price = property.purchasePriceMinorUnits, price > 0 { return (price, .purchasePrice) }
        return (nil, nil)
    }
}
