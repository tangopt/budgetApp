import GRDB
import Foundation

// What the Recharges tab's side panel shows (read only: the matching stays in `Recharges`).
// A statement: its charges (invoice and one-off lines) with the debits that paid the
// invoices, and the tenant credits that paid it with each credit's rent / recharge split. A
// month of the "Paid and recharged by month" chart: the statements for the month (the bar
// above the line), the tenancy's share of the invoices paid in the month (the bar below),
// and the recharges received on credits dated in the month.

/// A statement line: the invoice (provider, number, issue day, period) or a one-off line,
/// the amount it charges the tenant, the debit that paid the invoice and the line's document.
public struct RechargeChargeLine: Equatable, Identifiable, Sendable {
    public var id: String
    public var detail: Recharges.LineDetail
    /// What the line charges (the tenancy's share of the invoice).
    public var amountMinorUnits: Int
    /// The day the invoice was paid (its debit, else its issue day): when it counts as paid.
    public var rechargeDate: Date?
    /// The utility debit that paid the invoice, when matched.
    public var debit: Transaction?
    /// The statement it's on; nil while it waits for the next statement.
    public var statementId: Int64?
    /// That statement's month (its first day).
    public var statementMonth: Date?
}

/// A tenant credit that paid recharges: the part of it that paid the statement(s) and the
/// part that paid rent (its receipt links).
public struct RechargeCreditLine: Equatable, Identifiable, Sendable {
    public var id: String
    public var transaction: Transaction
    /// What it paid of the statement in question (or, for a month, of every statement).
    public var rechargeMinorUnits: Int
    /// What it paid of rent receipts.
    public var rentMinorUnits: Int
    /// The statements it paid, by month (the first day), with the amounts.
    public var statements: [(month: Date, amountMinorUnits: Int)]

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.transaction == rhs.transaction && lhs.rechargeMinorUnits == rhs.rechargeMinorUnits
            && lhs.rentMinorUnits == rhs.rentMinorUnits && lhs.statements.map(\.month) == rhs.statements.map(\.month)
            && lhs.statements.map(\.amountMinorUnits) == rhs.statements.map(\.amountMinorUnits)
    }
}

/// One statement in full, its totals reconciled: `chargesTotal` is the statement's total,
/// `paid` the credits' recharge parts, `outstanding` what it still needs.
public struct RechargeStatementDetail: Equatable, Sendable {
    public var statement: RechargeStatement
    public var charges: [RechargeChargeLine]
    public var credits: [RechargeCreditLine]
    public var chargesTotal: Int { charges.reduce(0) { $0 + $1.amountMinorUnits } }
    public var paid: Int { credits.reduce(0) { $0 + $1.rechargeMinorUnits } }
    /// `Recharges.outstanding` (0 for a draft: nothing is asked yet).
    public var outstanding: Int
}

/// A month of the tenancy's recharges chart.
public struct RechargeMonthDetail: Equatable, Sendable {
    public var month: Date
    /// The statements for the month, sent or paid (drafts aren't recharged yet): the bar above.
    public var statements: [RechargeStatement]
    /// The tenancy's share of the invoices paid in the month, on statements or waiting: the bar below.
    public var charges: [RechargeChargeLine]
    /// Recharges received on credits dated in the month (whatever month they paid).
    public var credits: [RechargeCreditLine]
    public var recharged: Int { statements.reduce(0) { $0 + $1.totalMinorUnits } }
    public var paid: Int { charges.reduce(0) { $0 + $1.amountMinorUnits } }
    public var received: Int { credits.reduce(0) { $0 + $1.rechargeMinorUnits } }
}

public enum RechargeDetails {
    /// The statement's lines, the debits behind its invoices and the credits that paid it.
    public static func statement(db: Database, statementId: Int64) throws -> RechargeStatementDetail {
        guard let statement = try RechargeStatement.fetchOne(db, key: statementId) else { throw RechargeError.statementNotFound }
        let charges = try Recharges.lineDetails(db: db, statementId: statementId).map { detail in
            try chargeLine(db: db, detail: detail, amount: detail.line.amountMinorUnits, statementId: statementId, month: statement.month)
        }
        let payments = try RechargePayment.filter(Column("statementId") == statementId && Column("isDismissed") == false)
            .order(Column("id")).fetchAll(db)
        let credits = try payments.compactMap { payment -> RechargeCreditLine? in
            guard let transaction = try Transaction.fetchOne(db, key: payment.transactionId) else { return nil }
            return RechargeCreditLine(id: "\(payment.id ?? 0)", transaction: transaction, rechargeMinorUnits: payment.amountMinorUnits,
                                      rentMinorUnits: try rent(db: db, transactionId: payment.transactionId),
                                      statements: [(statement.month, payment.amountMinorUnits)])
        }
        let outstanding = statement.status == .draft ? 0 : try Recharges.outstanding(db: db, statementId: statementId)
        return RechargeStatementDetail(statement: statement, charges: charges, credits: credits, outstanding: outstanding)
    }

    /// The month (any day in it) of the tenancy's chart: as `RechargesModel` counts it, the
    /// statements for the month and the invoices paid in it — on its statements, or waiting
    /// for the next one up to `today` — and the credits dated in it that paid recharges.
    public static func month(db: Database, tenancyId: Int64, month: Date, today: Date) throws -> RechargeMonthDetail {
        guard try Tenancy.fetchOne(db, key: tenancyId) != nil else { throw RechargeError.tenancyNotFound }
        let (year, number) = MonthRange.components(of: month)
        let start = MonthRange.of(year: year, month: number).start
        let end = MonthRange.calendar.date(byAdding: .month, value: 1, to: start)!
        func within(_ date: Date) -> Bool { date >= start && date < end }

        let rows = try Recharges.overview(db: db, tenancyId: tenancyId)
        let statements = rows.map(\.statement).filter { $0.status != .draft && within($0.month) }.sorted { $0.month < $1.month }
        var charges: [RechargeChargeLine] = []
        for row in rows {
            for detail in try Recharges.lineDetails(db: db, statementId: row.id) {
                guard let invoice = detail.invoice else { continue }
                let date = try Recharges.rechargeDate(db: db, invoice)
                guard within(date) else { continue }
                charges.append(try chargeLine(db: db, detail: detail, amount: detail.line.amountMinorUnits, statementId: row.id,
                                              month: row.statement.month))
            }
        }
        for pending in try Recharges.pendingLines(db: db, tenancyId: tenancyId, through: today) where within(pending.rechargeDate) {
            let provider = try UtilityProvider.fetchOne(db, key: pending.invoice.providerId)
            let line = RechargeLine(statementId: 0, invoiceId: pending.invoice.id, amountMinorUnits: pending.amountMinorUnits, note: pending.note)
            charges.append(try chargeLine(db: db, detail: Recharges.LineDetail(line: line, invoice: pending.invoice, provider: provider),
                                          amount: pending.amountMinorUnits, statementId: nil, month: nil))
        }
        charges.sort { ($0.rechargeDate ?? .distantPast, $0.id) < ($1.rechargeDate ?? .distantPast, $1.id) }

        // Credits dated in the month that paid any of the tenancy's statements.
        let monthsById = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.statement.month) })
        var byCredit: [Int64: [RechargePayment]] = [:]
        for row in rows { for payment in row.payments { byCredit[payment.transactionId, default: []].append(payment) } }
        var credits: [RechargeCreditLine] = []
        for (transactionId, payments) in byCredit {
            guard let transaction = try Transaction.fetchOne(db, key: transactionId), within(transaction.date) else { continue }
            let paid = payments.sorted { (monthsById[$0.statementId] ?? .distantPast) < (monthsById[$1.statementId] ?? .distantPast) }
            credits.append(RechargeCreditLine(id: "\(transactionId)", transaction: transaction,
                                              rechargeMinorUnits: paid.reduce(0) { $0 + $1.amountMinorUnits },
                                              rentMinorUnits: try rent(db: db, transactionId: transactionId),
                                              statements: paid.map { (monthsById[$0.statementId] ?? start, $0.amountMinorUnits) }))
        }
        credits.sort { ($0.transaction.date, $0.id) < ($1.transaction.date, $1.id) }
        return RechargeMonthDetail(month: start, statements: statements, charges: charges, credits: credits)
    }

    private static func chargeLine(db: Database, detail: Recharges.LineDetail, amount: Int, statementId: Int64?,
                                   month: Date?) throws -> RechargeChargeLine {
        let debit = try detail.invoice?.transactionId.flatMap { try Transaction.fetchOne(db, key: $0) }
        let date = try detail.invoice.map { try Recharges.rechargeDate(db: db, $0) }
        let id = detail.invoice?.id.map { "invoice/\($0)/\(statementId ?? 0)" } ?? "line/\(detail.line.id ?? 0)"
        return RechargeChargeLine(id: id, detail: detail, amountMinorUnits: amount, rechargeDate: date, debit: debit, statementId: statementId,
                                  statementMonth: month)
    }

    /// What the credit paid of rent receipts.
    private static func rent(db: Database, transactionId: Int64) throws -> Int {
        try RentReceiptMatching.payments(db: db, transactionId: transactionId).reduce(0) { $0 + $1.rentMinorUnits }
    }
}
