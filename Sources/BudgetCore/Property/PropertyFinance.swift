import GRDB
import Foundation

/// The period a property summary covers.
public enum PropertyPeriod: Hashable, Sendable {
    case calendarYear(Int)
    case ukTaxYear(UKTaxYear)
    /// Any `[start, end)` range.
    case custom(DateInterval)

    public var interval: DateInterval {
        switch self {
        case let .calendarYear(year):
            return DateInterval(start: MonthRange.of(year: year, month: 1).start, end: MonthRange.of(year: year + 1, month: 1).start)
        case let .ukTaxYear(year):
            return year.interval
        case let .custom(interval):
            return interval
        }
    }

    /// "2025", "2025/26", or "1 Jan 2025 – 31 Mar 2025" style ISO days for custom.
    public var label: String {
        switch self {
        case let .calendarYear(year): return String(year)
        case let .ukTaxYear(year): return year.label
        case let .custom(interval):
            let lastDay = interval.end.addingTimeInterval(-1)
            return "\(MissingEvidence.day(interval.start)) – \(MissingEvidence.day(lastDay))"
        }
    }
}

/// An amount in the property's currency and in GBP.
public struct PropertyAmount: Equatable, Sendable {
    public var native: Int
    public var gbp: Int

    public init(native: Int = 0, gbp: Int = 0) {
        self.native = native
        self.gbp = gbp
    }

    public static let zero = PropertyAmount()

    public static func + (lhs: PropertyAmount, rhs: PropertyAmount) -> PropertyAmount {
        PropertyAmount(native: lhs.native + rhs.native, gbp: lhs.gbp + rhs.gbp)
    }

    public static func - (lhs: PropertyAmount, rhs: PropertyAmount) -> PropertyAmount {
        PropertyAmount(native: lhs.native - rhs.native, gbp: lhs.gbp - rhs.gbp)
    }

    public static prefix func - (value: PropertyAmount) -> PropertyAmount {
        PropertyAmount(native: -value.native, gbp: -value.gbp)
    }

    public static func += (lhs: inout PropertyAmount, rhs: PropertyAmount) { lhs = lhs + rhs }
}

/// The money figures of a property over a period (spec 2026-10-16 §1 "Money"). Every figure
/// is positive in its natural direction (rent and costs both positive).
public struct PropertyFigures: Equatable, Sendable {
    /// Rent on the issued receipts, by rent period (a receipt spanning months is spread over
    /// its days): what the tenant was charged for the period.
    public var rentPerReceipts = PropertyAmount.zero
    /// The rent credits (property's current account, rent categories) dated in the period.
    public var rentCredits = PropertyAmount.zero
    /// The part of those credits that isn't rent: per credit, the larger of the `otherMinorUnits`
    /// of its receipt links and its recharge statement links (utility recharges and the like).
    public var recharges = PropertyAmount.zero
    /// The utility costs: transactions in the property's utility categories
    /// (`RechargeNetting.utilityCategoryIds`), as a positive cost. Part of `costs`.
    public var utilities = PropertyAmount.zero
    /// Utilities recharged and received: the statement-linked parts of credits dated in the period.
    public var utilityRecharges = PropertyAmount.zero
    /// `utilities − utilityRecharges`, never below zero: what the utilities cost the landlord.
    public var netUtilities = PropertyAmount.zero
    /// `rentCredits − recharges`.
    public var rentReceived = PropertyAmount.zero
    /// Every transaction in the property's income categories (rent credits included).
    public var income = PropertyAmount.zero
    /// Every transaction in the property's expense categories, as a positive cost (refunds
    /// reduce it). Includes the mortgage interest rows on the loan.
    public var costs = PropertyAmount.zero
    /// The interest (and the bank's fees and taxes) charged on the mortgage accounts: their
    /// expense rows.
    public var mortgageInterest = PropertyAmount.zero
    /// Capital repaid: the instalments paid into the mortgage accounts (their incoming
    /// transfer legs) less the interest.
    public var mortgageCapital = PropertyAmount.zero
    /// The part of `mortgageInterest` filed under a category that isn't one of the property's
    /// expense categories (so not in `costs`).
    public var interestOutsideCosts = PropertyAmount.zero
    /// `income − costs − interestOutsideCosts − mortgageCapital`: the cash the property made
    /// or needed (all the interest and the capital part of the instalments leave).
    public var netCashFlow = PropertyAmount.zero

    public init() {}
}

/// A month of the summary's series (clipped to the period).
public struct PropertyMonthFigures: Equatable, Sendable {
    /// The month's first day, or the period's start for a partial first month.
    public var start: Date
    public var end: Date
    public var figures: PropertyFigures
}

/// Costs of one category over the period.
public struct PropertyCategoryTotal: Equatable, Sendable {
    public var categoryId: Int64
    public var name: String
    public var amount: PropertyAmount
}

public struct PropertySummary: Equatable, Sendable {
    public var propertyId: Int64
    public var period: PropertyPeriod
    public var currency: Currency
    /// The EUR → GBP rate used.
    public var eurToGbpRate: Double
    public var totals: PropertyFigures
    public var months: [PropertyMonthFigures]
    /// Largest first.
    public var costsByCategory: [PropertyCategoryTotal]
    /// What's owed on the mortgage accounts at the end of the period's last day.
    public var outstandingLoan: PropertyAmount
    /// The balance of the deposit-role accounts (amount held for the tenant) at the period's end.
    public var depositHeld: PropertyAmount
    public var purchasePrice: Int?
    /// Rent per receipts over the purchase price, annualised over the elapsed part of the
    /// period (`yieldInterval`); `nil` without a price or elapsed time.
    public var grossYield: Double?
    /// `income − costs − interestOutsideCosts` over the purchase price, annualised likewise.
    public var netYield: Double?
    /// The part of the period yields are measured over: from the latest of the period's
    /// start, the purchase date and the first tenancy's start, to the earlier of its end and today.
    public var yieldInterval: DateInterval?
}

/// The property's money over a period: rent charged, received and recharged, costs by
/// category, mortgage interest versus capital, cash flow, loan and deposit balances, yields,
/// and a monthly series for charts. Amounts in the property's currency and in GBP.
public enum PropertyFinance {
    /// The summary of `period`. `conversion` defaults to the stored rate
    /// (`CurrencyConversion.current`); the tax phase passes HMRC's rate instead.
    public static func summary(db: Database, propertyId: Int64, period: PropertyPeriod,
                               conversion: CurrencyConversion? = nil, today: Date = Date()) throws -> PropertySummary {
        guard let property = try Property.fetchOne(db, key: propertyId) else { throw PropertyError.propertyNotFound }
        let conversion = try conversion ?? CurrencyConversion.current(db: db)
        let ledger = try Ledger(db: db, property: property, conversion: conversion, interval: period.interval)
        let interval = period.interval

        var months: [PropertyMonthFigures] = []
        let calendar = MonthRange.calendar
        let (year, month) = MonthRange.components(of: interval.start)
        var monthStart = MonthRange.of(year: year, month: month).start
        while monthStart < interval.end {
            let next = calendar.date(byAdding: .month, value: 1, to: monthStart)!
            let bucket = DateInterval(start: max(monthStart, interval.start), end: min(next, interval.end))
            months.append(PropertyMonthFigures(start: bucket.start, end: bucket.end, figures: ledger.figures(in: bucket)))
            monthStart = next
        }

        var costs: [Int64: PropertyAmount] = [:]
        for transaction in ledger.transactions where ledger.expenseCategoryIds.contains(transaction.categoryId ?? -1) {
            costs[transaction.categoryId!, default: .zero] += -ledger.amount(transaction)
        }
        let costsByCategory = costs.map { PropertyCategoryTotal(categoryId: $0.key, name: ledger.categoryNames[$0.key] ?? "", amount: $0.value) }
            .sorted { ($0.amount.native, $1.name) > ($1.amount.native, $0.name) }

        let totals = ledger.figures(in: interval)
        let lastDay = PropertyDates.day(interval.end.addingTimeInterval(-1))
        let outstanding = try balance(db: db, property: property, conversion: conversion, accountIds: ledger.mortgageAccountIds, asOf: lastDay)
        let deposit = try balance(db: db, property: property, conversion: conversion, accountIds: ledger.depositAccountIds, asOf: lastDay)

        // Yields over the elapsed, owned-and-let part of the period.
        let firstTenancy = try Tenancies.all(db: db, propertyId: propertyId).map(\.startDate).min()
        let yieldStart = [interval.start, property.purchaseDate, firstTenancy].compactMap { $0 }.max()!
        let yieldEnd = min(interval.end, PropertyDates.nextDay(today))
        let yieldInterval = yieldStart < yieldEnd ? DateInterval(start: yieldStart, end: yieldEnd) : nil
        let price = property.purchasePriceMinorUnits
        var grossYield: Double?, netYield: Double?
        if let yieldInterval, let price, price > 0 {
            let years = Double(days(yieldInterval.start, yieldInterval.end)) / 365
            let figures = ledger.figures(in: yieldInterval)
            grossYield = Double(figures.rentPerReceipts.native) / Double(price) / years
            netYield = Double(figures.income.native - figures.costs.native - figures.interestOutsideCosts.native) / Double(price) / years
        }
        return PropertySummary(propertyId: propertyId, period: period, currency: property.currency, eurToGbpRate: conversion.eurToGbpRate,
                               totals: totals, months: months, costsByCategory: costsByCategory, outstandingLoan: outstanding,
                               depositHeld: deposit, purchasePrice: price, grossYield: grossYield, netYield: netYield,
                               yieldInterval: yieldInterval)
    }

    /// What's owed or held on `accountIds` at the end of `day`, in entered terms (owed on a
    /// credit account is positive), in the property's currency and GBP.
    public static func balance(db: Database, property: Property, conversion: CurrencyConversion, accountIds: [Int64],
                               asOf day: Date) throws -> PropertyAmount {
        var total = PropertyAmount.zero
        for id in accountIds {
            guard let account = try Account.fetchOne(db, key: id) else { continue }
            let signed = try BalanceUpdates.computedBalance(db: db, accountId: id, asOf: day)
            let entered = NetWorthCalculator.enteredBalance(signedMinorUnits: signed, accountKind: account.kind)
            total += convert(entered, currency: account.currency, property: property, conversion: conversion)
        }
        return total
    }

    /// `balance` for many days at once (a loan's history): what `accountIds` owe or hold at
    /// the end of each of `days`, in entered terms, in the property's currency and GBP. Each
    /// account's snapshots and transactions are read once and its balance worked out per day
    /// in memory, by the same rule as `balance` (`NetWorthCalculator.balance`). In `days`' order.
    public static func loanBalances(db: Database, property: Property, accountIds: [Int64], days: [Date]) throws -> [PropertyAmount] {
        guard !days.isEmpty else { return [] }
        let conversion = try CurrencyConversion.current(db: db)
        var totals = Array(repeating: PropertyAmount.zero, count: days.count)
        for id in accountIds {
            guard let account = try Account.fetchOne(db, key: id) else { continue }
            let snapshots = try BalanceSnapshot.filter(Column("accountId") == id).fetchAll(db)
            let transactions = try Transaction.filter(Column("accountId") == id).fetchAll(db)
            for (index, day) in days.enumerated() {
                let signed = NetWorthCalculator.balance(accountId: id, at: BalanceUpdates.endOfDay(day), snapshots: snapshots,
                                                        transactions: transactions)?.native ?? 0
                let entered = NetWorthCalculator.enteredBalance(signedMinorUnits: signed, accountKind: account.kind)
                totals[index] += convert(entered, currency: account.currency, property: property, conversion: conversion)
            }
        }
        return totals
    }

    /// An amount in `currency` as the property's currency and GBP.
    static func convert(_ value: Int, currency: Currency, property: Property, conversion: CurrencyConversion) -> PropertyAmount {
        let gbp = NetWorthCalculator.gbp(value, currency: currency, eurToGbpRate: conversion.eurToGbpRate)
        let native: Int
        if currency == property.currency {
            native = value
        } else if property.currency == .gbp {
            native = gbp
        } else {
            // A GBP amount for a EUR property: back through the rate.
            native = conversion.eurToGbpRate > 0 ? Int((Double(value) / conversion.eurToGbpRate).rounded()) : value
        }
        return PropertyAmount(native: native, gbp: gbp)
    }

    /// The share of `amount` (spread evenly over the days `start`…`lastDay`) that falls in
    /// `interval`. Shares of adjacent intervals add up exactly to the whole.
    static func apportioned(_ amount: Int, start: Date, lastDay: Date, to interval: DateInterval) -> Int {
        let first = PropertyDates.day(start)
        let end = PropertyDates.nextDay(lastDay)
        let total = days(first, end)
        guard total > 0 else { return 0 }
        func boundary(_ date: Date) -> Date {
            let day = PropertyDates.day(date)
            return day == date ? day : PropertyDates.nextDay(date)
        }
        func cumulative(_ date: Date) -> Int {
            let clamped = min(max(boundary(date), first), end)
            return Int((Double(amount) * Double(days(first, clamped)) / Double(total)).rounded())
        }
        return cumulative(interval.end) - cumulative(interval.start)
    }

    static func days(_ from: Date, _ to: Date) -> Int {
        MonthRange.calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    /// Everything a summary reads, loaded once.
    struct Ledger {
        let property: Property
        let conversion: CurrencyConversion
        let accounts: [Int64: Account]
        let incomeCategoryIds: Set<Int64>
        let expenseCategoryIds: Set<Int64>
        let transferCategoryIds: Set<Int64>
        /// Every expense category (interest rows on the loan count wherever they're filed).
        let anyExpenseCategoryIds: Set<Int64>
        let categoryNames: [Int64: String]
        let mortgageAccountIds: [Int64]
        let depositAccountIds: [Int64]
        /// Income and expense transactions of the property's categories in the interval.
        let transactions: [Transaction]
        /// Rows on the mortgage accounts in the interval.
        let loanRows: [Transaction]
        let rentCredits: [Transaction]
        let otherByCredit: [Int64: Int]
        let receipts: [RentReceipt]
        let utilityCategoryIds: Set<Int64>
        /// Recharge statement links by credit.
        let rechargeByCredit: [Int64: Int]
        /// The recharge statement links on credits dated in the interval.
        let rechargesReceived: [Recharges.Received]

        init(db: Database, property: Property, conversion: CurrencyConversion, interval: DateInterval) throws {
            let propertyId = property.id!
            self.property = property
            self.conversion = conversion
            accounts = Dictionary(uniqueKeysWithValues: try Account.fetchAll(db).compactMap { a in a.id.map { ($0, a) } })
            let groupIds = try Properties.categoryGroupIds(db: db, propertyId: propertyId)
            let categories = try Category.filter(groupIds.contains(Column("groupId"))).fetchAll(db)
            incomeCategoryIds = Set(categories.filter { $0.type == .income }.compactMap(\.id))
            expenseCategoryIds = Set(categories.filter { $0.type == .expense }.compactMap(\.id))
            let all = try Category.fetchAll(db)
            transferCategoryIds = Set(all.filter { $0.type == .transfer }.compactMap(\.id))
            anyExpenseCategoryIds = Set(all.filter { $0.type == .expense && !$0.isBuiltIn }.compactMap(\.id))
            categoryNames = Dictionary(uniqueKeysWithValues: categories.compactMap { c in c.id.map { ($0, c.name) } })
            mortgageAccountIds = try Properties.accounts(db: db, propertyId: propertyId, role: .mortgage).map(\.accountId)
            depositAccountIds = try Properties.accounts(db: db, propertyId: propertyId, role: .deposit).map(\.accountId)
            let ids = Array(incomeCategoryIds.union(expenseCategoryIds))
            transactions = ids.isEmpty ? [] : try Transaction
                .filter(ids.contains(Column("categoryId")) && Column("date") >= interval.start && Column("date") < interval.end)
                .order(Column("date"), Column("id")).fetchAll(db)
            loanRows = mortgageAccountIds.isEmpty ? [] : try Transaction
                .filter(mortgageAccountIds.contains(Column("accountId")) && Column("date") >= interval.start && Column("date") < interval.end)
                .order(Column("date"), Column("id")).fetchAll(db)
            rentCredits = try RentReceiptMatching.candidateCredits(db: db, propertyId: propertyId)
                .filter { $0.date >= interval.start && $0.date < interval.end }
            let rows = try Row.fetchAll(db, sql: """
                SELECT transactionId, SUM(otherMinorUnits) FROM rentReceiptPayment WHERE isDismissed = 0 GROUP BY transactionId
                """)
            otherByCredit = Dictionary(uniqueKeysWithValues: rows.map { ($0[0] as Int64, $0[1] as Int) })
            receipts = try RentReceipts.receipts(db: db, propertyId: propertyId, overlapping: interval)
            utilityCategoryIds = try RechargeNetting.utilityCategoryIds(db: db, propertyId: propertyId)
            rechargesReceived = try Recharges.received(db: db, propertyId: propertyId, in: interval)
            let rechargeRows = try Row.fetchAll(db, sql: "SELECT transactionId, SUM(amountMinorUnits) FROM rechargePayment WHERE isDismissed = 0 GROUP BY transactionId")
            rechargeByCredit = Dictionary(uniqueKeysWithValues: rechargeRows.map { ($0[0] as Int64, $0[1] as Int) })
        }

        /// A transaction's amount in the property's currency and GBP.
        func amount(_ transaction: Transaction) -> PropertyAmount {
            amount(transaction.amountMinorUnits, currency: accounts[transaction.accountId]?.currency ?? .gbp)
        }

        func amount(_ value: Int, currency: Currency) -> PropertyAmount {
            PropertyFinance.convert(value, currency: currency, property: property, conversion: conversion)
        }

        func figures(in interval: DateInterval) -> PropertyFigures {
            func within(_ transaction: Transaction) -> Bool { transaction.date >= interval.start && transaction.date < interval.end }
            var figures = PropertyFigures()
            for receipt in receipts {
                let share = PropertyFinance.apportioned(receipt.amountMinorUnits, start: receipt.periodStart, lastDay: receipt.periodEnd, to: interval)
                figures.rentPerReceipts += amount(share, currency: property.currency)
            }
            for credit in rentCredits where within(credit) {
                figures.rentCredits += amount(credit)
                let nonRent = max(otherByCredit[credit.id!] ?? 0, rechargeByCredit[credit.id!] ?? 0)
                figures.recharges += amount(nonRent, currency: accounts[credit.accountId]?.currency ?? property.currency)
            }
            figures.rentReceived = figures.rentCredits - figures.recharges
            for transaction in transactions where within(transaction) {
                guard let category = transaction.categoryId else { continue }
                if incomeCategoryIds.contains(category) { figures.income += amount(transaction) }
                if expenseCategoryIds.contains(category) { figures.costs += -amount(transaction) }
                if utilityCategoryIds.contains(category) { figures.utilities += -amount(transaction) }
            }
            for recharge in rechargesReceived where within(recharge.transaction) {
                figures.utilityRecharges += amount(recharge.payment.amountMinorUnits,
                                                   currency: accounts[recharge.transaction.accountId]?.currency ?? property.currency)
            }
            let net = figures.utilities - figures.utilityRecharges
            figures.netUtilities = PropertyAmount(native: max(0, net.native), gbp: max(0, net.gbp))
            var legs = PropertyAmount.zero
            for row in loanRows where within(row) {
                guard let category = row.categoryId else { continue }
                if anyExpenseCategoryIds.contains(category) {
                    figures.mortgageInterest += -amount(row)
                    if !expenseCategoryIds.contains(category) { figures.interestOutsideCosts += -amount(row) }
                } else if transferCategoryIds.contains(category) && row.amountMinorUnits > 0 {
                    legs += amount(row)
                }
            }
            figures.mortgageCapital = legs - figures.mortgageInterest
            figures.netCashFlow = figures.income - figures.costs - figures.interestOutsideCosts - figures.mortgageCapital
            return figures
        }
    }
}
