import GRDB
import Foundation

/// Which part of a month's cash flow a transaction counts in (`PropertyMonthBreakdown`).
public enum PropertyFlowGroupKind: String, CaseIterable, Sendable {
    /// The rent part of the rent credits: the Cash flow chart's bar above the line.
    case rent
    /// The rest of the income: the recharge part of the rent credits, other income.
    case otherIncome
    /// The property's expense transactions (the interest on the loan included): the bar below.
    case costs
    /// The instalments paid into the loan, less the interest already in Costs.
    case mortgage

    public var title: String {
        switch self {
        case .rent: return "Rent"
        case .otherIncome: return "Other income"
        case .costs: return "Costs"
        case .mortgage: return "Mortgage"
        }
    }
}

/// A transaction as it counts in one group of a month's cash flow.
public struct PropertyFlowLine: Equatable, Identifiable, Sendable {
    /// "<group>/<transaction id>".
    public var id: String
    public var transaction: Transaction
    public var categoryName: String?
    /// The currency of the transaction's account (its own amount is in it).
    public var accountCurrency: Currency
    /// What the line adds to the month's net cash flow, signed, in the property's currency
    /// (and GBP): a rent credit's rent part, a cost as given, an instalment as money out, the
    /// interest already in Costs added back.
    public var counted: PropertyAmount
    /// Why `counted` isn't the transaction's own amount, when it isn't.
    public var note: String?
}

public struct PropertyFlowGroup: Equatable, Identifiable, Sendable {
    public var kind: PropertyFlowGroupKind
    /// Oldest first.
    public var lines: [PropertyFlowLine]
    /// The lines' `counted` added up.
    public var total: PropertyAmount
    public var id: PropertyFlowGroupKind { kind }
}

/// The transactions behind one month of the Cash flow by month chart (or any interval):
/// grouped Rent / Other income / Costs / Mortgage, each line counted the way
/// `PropertyFinance.summary` counts it, so `rentReceived` is the bar above the line, `costs`
/// the bar below and `netCashFlow` the line's point, to the cent.
public struct PropertyMonthBreakdown: Equatable, Sendable {
    public var interval: DateInterval
    public var currency: Currency
    /// The groups with lines, in `PropertyFlowGroupKind` order.
    public var groups: [PropertyFlowGroup]
    /// The rent group's total (the summary's `rentReceived`).
    public var rentReceived: PropertyAmount
    /// The costs, positive (the summary's `costs`).
    public var costs: PropertyAmount
    /// Every group's total added up (the summary's `netCashFlow`).
    public var netCashFlow: PropertyAmount

    public func group(_ kind: PropertyFlowGroupKind) -> PropertyFlowGroup? { groups.first { $0.kind == kind } }
}

extension PropertyFinance {
    /// The month's (or `interval`'s) transactions behind the cash flow figures, grouped and
    /// counted as the summary counts them. `conversion` defaults to the stored rate.
    public static func monthBreakdown(db: Database, propertyId: Int64, interval: DateInterval,
                                      conversion: CurrencyConversion? = nil) throws -> PropertyMonthBreakdown {
        guard let property = try Property.fetchOne(db, key: propertyId) else { throw PropertyError.propertyNotFound }
        let conversion = try conversion ?? CurrencyConversion.current(db: db)
        let ledger = try Ledger(db: db, property: property, conversion: conversion, interval: interval)
        let allNames = Dictionary(uniqueKeysWithValues: try Category.fetchAll(db).compactMap { c in c.id.map { ($0, c.name) } })
        func currency(_ transaction: Transaction) -> Currency { ledger.accounts[transaction.accountId]?.currency ?? property.currency }
        func line(_ kind: PropertyFlowGroupKind, _ transaction: Transaction, _ counted: PropertyAmount, note: String? = nil) -> PropertyFlowLine {
            PropertyFlowLine(id: "\(kind.rawValue)/\(transaction.id ?? 0)", transaction: transaction,
                             categoryName: transaction.categoryId.flatMap { allNames[$0] }, accountCurrency: currency(transaction),
                             counted: counted, note: note ?? conversionNote(transaction, counted: counted, property: property, conversion: conversion,
                                                                            currency: currency(transaction)))
        }
        func format(_ minorUnits: Int, _ currency: Currency) -> String { Money.format(minorUnits, currency: currency).unbroken }

        var lines: [PropertyFlowGroupKind: [PropertyFlowLine]] = [:]
        // Rent: each credit's rent part (the summary's rentCredits − recharges, credit by credit).
        var rentPart: [Int64: PropertyAmount] = [:]
        for credit in ledger.rentCredits {
            let nonRent = max(ledger.otherByCredit[credit.id!] ?? 0, ledger.rechargeByCredit[credit.id!] ?? 0)
            let part = ledger.amount(credit) - ledger.amount(nonRent, currency: currency(credit))
            rentPart[credit.id!] = part
            let note = nonRent == 0 ? nil
                : "\(format(credit.amountMinorUnits, currency(credit))) credit less \(format(nonRent, currency(credit))) recharges and other"
            lines[.rent, default: []].append(line(.rent, credit, part, note: note))
        }
        // Other income: the income transactions less what Rent counted of them.
        for transaction in ledger.transactions {
            let category = transaction.categoryId ?? -1
            let income = ledger.incomeCategoryIds.contains(category) ? ledger.amount(transaction) : .zero
            let rent = rentPart[transaction.id!] ?? .zero
            let counted = income - rent
            guard counted != .zero else { continue }
            let note: String? = rent == .zero ? nil : "The recharge and other part of a \(format(transaction.amountMinorUnits, currency(transaction))) rent credit"
            lines[.otherIncome, default: []].append(line(.otherIncome, transaction, counted, note: note))
        }
        // A rent credit outside the income categories: the summary's income leaves it out.
        for credit in ledger.rentCredits where !ledger.incomeCategoryIds.contains(credit.categoryId ?? -1) {
            let part = rentPart[credit.id!] ?? .zero
            guard part != .zero else { continue }
            lines[.otherIncome, default: []].append(line(.otherIncome, credit, -part,
                                                          note: "A rent credit outside the property's income categories: not in its income"))
        }
        // Costs: every expense transaction as given.
        for transaction in ledger.transactions where ledger.expenseCategoryIds.contains(transaction.categoryId ?? -1) {
            lines[.costs, default: []].append(line(.costs, transaction, ledger.amount(transaction)))
        }
        // Mortgage: instalments leave; the interest in them already counted in Costs comes back.
        for row in ledger.loanRows {
            guard let category = row.categoryId else { continue }
            if ledger.anyExpenseCategoryIds.contains(category) {
                if ledger.expenseCategoryIds.contains(category) {
                    lines[.mortgage, default: []].append(line(.mortgage, row, -ledger.amount(row),
                                                              note: "Interest in the instalment, already counted in Costs"))
                } else {
                    lines[.mortgage, default: []].append(line(.mortgage, row, .zero,
                                                              note: "Interest in the instalment, filed outside the property's categories"))
                }
            } else if ledger.transferCategoryIds.contains(category) && row.amountMinorUnits > 0 {
                lines[.mortgage, default: []].append(line(.mortgage, row, -ledger.amount(row), note: "Instalment paid into the loan"))
            }
        }

        let groups = PropertyFlowGroupKind.allCases.compactMap { kind -> PropertyFlowGroup? in
            guard let rows = lines[kind], !rows.isEmpty else { return nil }
            let sorted = rows.sorted { ($0.transaction.date, $0.transaction.id ?? 0) < ($1.transaction.date, $1.transaction.id ?? 0) }
            return PropertyFlowGroup(kind: kind, lines: sorted, total: sorted.reduce(.zero) { $0 + $1.counted })
        }
        let rent = groups.first { $0.kind == .rent }?.total ?? .zero
        let costs = -(groups.first { $0.kind == .costs }?.total ?? .zero)
        return PropertyMonthBreakdown(interval: interval, currency: property.currency, groups: groups, rentReceived: rent, costs: costs,
                                      netCashFlow: groups.reduce(.zero) { $0 + $1.total })
    }

    /// "£50.00 at 0.85" for a line converted from another currency.
    private static func conversionNote(_ transaction: Transaction, counted: PropertyAmount, property: Property,
                                       conversion: CurrencyConversion, currency: Currency) -> String? {
        guard currency != property.currency else { return nil }
        let rate = property.currency == .gbp ? conversion.eurToGbpRate : 1 / max(conversion.eurToGbpRate, 0.0001)
        return "\(Money.format(transaction.amountMinorUnits, currency: currency).unbroken) at \(String(format: "%.4f", rate))"
    }
}
