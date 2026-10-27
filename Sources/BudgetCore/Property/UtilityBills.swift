import GRDB
import Foundation

/// How far one utility bill has got on its way from the landlord's payment to the tenant's
/// (user, 2026-10-26: "invoice in Mango, linked to payment, added to tenant recharge is prep done,
/// sent to the tenant is next and then is reconciled with tenant payment last").
public enum UtilityBillStage: Int, CaseIterable, Comparable, Sendable {
    /// A utility payment with no invoice recorded for it.
    case missingInvoice
    /// The invoice is recorded; no payment is linked to it yet.
    case invoiceIn
    /// The invoice and the payment that settled it are linked.
    case linkedToPayment
    /// On the tenancy's draft statement: the preparation is done.
    case inRecharge
    /// On a statement emailed to the tenant, who hasn't covered it.
    case sentToTenant
    /// The statement is covered by the tenant's credits.
    case paidByTenant

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var displayName: String {
        switch self {
        case .missingInvoice: return "Missing invoice"
        case .invoiceIn: return "Invoice in"
        case .linkedToPayment: return "Linked to payment"
        case .inRecharge: return "In recharge"
        case .sentToTenant: return "Sent to tenant"
        case .paidByTenant: return "Paid by tenant"
        }
    }
}

/// One utility bill of a tenancy, read from what is recorded: an invoice (with its payment,
/// statement line and the tenant's credits) or a utility payment still without an invoice.
public struct UtilityBill: Equatable, Identifiable, Sendable {
    public var id: String
    /// `nil`: a payment no provider's bank description or invoice explains.
    public var providerId: Int64?
    public var providerName: String
    public var kind: UtilityKind
    /// The first day of the month the bill belongs to: the day it was paid (its invoice's
    /// recharge date), else its issue date.
    public var month: Date
    public var stage: UtilityBillStage
    public var invoice: UtilityInvoice?
    /// The bank movements that paid it (the missing-invoice payment, else the invoice's).
    public var payments: [Transaction]
    /// The tenancy's share (a statement line's amount), else what the bill costs.
    public var amountMinorUnits: Int
    public var statement: RechargeStatement?
    /// What the tenant's credits paid of the statement, and the statement's total.
    public var tenantPaidMinorUnits: Int
    public var statementTotalMinorUnits: Int

    /// The statement is sent and the tenant has covered part of it, not all.
    public var isPartiallyPaid: Bool {
        stage == .sentToTenant && tenantPaidMinorUnits > 0 && tenantPaidMinorUnits < statementTotalMinorUnits
    }
}

/// A provider × month of the grid: its bills, shown at the least advanced stage among them.
public struct UtilityBillCell: Equatable, Identifiable, Sendable {
    public var providerKey: String
    public var month: Date
    public var bills: [UtilityBill]
    public var id: String { "\(providerKey)|\(month.timeIntervalSince1970)" }
    public var stage: UtilityBillStage { bills.map(\.stage).min() ?? .missingInvoice }
}

public struct UtilityBillRow: Equatable, Identifiable, Sendable {
    public var providerId: Int64?
    public var name: String
    public var kind: UtilityKind
    public var id: String { UtilityBills.key(providerId) }
}

public struct UtilityBillsGrid: Equatable, Sendable {
    public var bills: [UtilityBill]
    public var rows: [UtilityBillRow]

    public init(bills: [UtilityBill], rows: [UtilityBillRow]) {
        self.bills = bills
        self.rows = rows
    }

    /// Bills per stage.
    public func count(_ stage: UtilityBillStage) -> Int { bills.filter { $0.stage == stage }.count }

    /// The years with bills, latest first.
    public var years: [Int] { Array(Set(bills.map { MonthRange.components(of: $0.month).year })).sorted(by: >) }

    public func cell(row: UtilityBillRow, month: Date) -> UtilityBillCell? {
        let found = bills.filter { $0.providerId == row.providerId && $0.month == month }
        return found.isEmpty ? nil : UtilityBillCell(providerKey: row.id, month: month, bills: found)
    }

    /// "3 bills need invoices · 2 ready to send · 1 waiting for the tenant"; the stages with
    /// nothing in them are left out, and "All bills are settled" when none is open.
    public var summaryText: String {
        func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        var parts: [String] = []
        let missing = count(.missingInvoice), waiting = count(.invoiceIn), toAdd = count(.linkedToPayment)
        let ready = count(.inRecharge), sent = count(.sentToTenant)
        if missing > 0 { parts.append(plural(missing, "bill needs an invoice", "bills need invoices")) }
        if waiting > 0 { parts.append(plural(waiting, "invoice waits for its payment", "invoices wait for their payment")) }
        if toAdd > 0 { parts.append(plural(toAdd, "bill to add to a recharge", "bills to add to a recharge")) }
        if ready > 0 { parts.append("\(ready) ready to send") }
        if sent > 0 { parts.append("\(sent) waiting for the tenant") }
        if parts.isEmpty { return bills.isEmpty ? "No utility bills yet" : "All bills are settled" }
        return parts.joined(separator: " · ")
    }
}

/// The utility bills tracker's read model: every bill of a tenancy by provider and month with
/// its stage, derived from the recorded invoices, utility payments, recharge statements and
/// the tenant's credits (nothing of its own is stored).
public enum UtilityBills {
    public static func key(_ providerId: Int64?) -> String { providerId.map { "p\($0)" } ?? "none" }

    public static func read(db: Database, propertyId: Int64, tenancyId: Int64) throws -> UtilityBillsGrid {
        guard let tenancy = try Tenancy.fetchOne(db, key: tenancyId) else { throw RechargeError.tenancyNotFound }
        let providers = try Recharges.providers(db: db, propertyId: propertyId)
        let byId = Dictionary(uniqueKeysWithValues: providers.compactMap { provider in provider.id.map { ($0, provider) } })
        var bills: [UtilityBill] = []
        var statementsCache: [Int64: (RechargeStatement, Int)] = [:]
        func statementInfo(_ id: Int64) throws -> (RechargeStatement, Int)? {
            if let cached = statementsCache[id] { return cached }
            guard let statement = try RechargeStatement.fetchOne(db, key: id) else { return nil }
            let paid = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(amountMinorUnits), 0) FROM rechargePayment WHERE statementId = ? AND isDismissed = 0",
                                        arguments: [id]) ?? 0
            statementsCache[id] = (statement, paid)
            return (statement, paid)
        }

        // Invoices of the tenancy: stage by how far the invoice has got.
        let lineStatements = Dictionary(grouping: try Row.fetchAll(db, sql: """
            SELECT rechargeLine.invoiceId, rechargeLine.amountMinorUnits, rechargeLine.statementId FROM rechargeLine
            JOIN rechargeStatement ON rechargeStatement.id = rechargeLine.statementId
            WHERE rechargeStatement.tenancyId = ? AND rechargeLine.invoiceId IS NOT NULL
            """, arguments: [tenancyId]), by: { $0["invoiceId"] as Int64 })
        for invoice in try Recharges.invoices(db: db, propertyId: propertyId) {
            let date = try Recharges.rechargeDate(db: db, invoice)
            let line = lineStatements[invoice.id!]?.first
            let share = Recharges.share(of: invoice, rechargeDate: date, tenancy: tenancy)
            guard share != nil || line != nil else { continue }
            let payments = try Recharges.payments(db: db, invoice)
            var stage: UtilityBillStage = payments.isEmpty ? .invoiceIn : .linkedToPayment
            var statement: RechargeStatement?
            var tenantPaid = 0
            if let line, let info = try statementInfo(line["statementId"] as Int64) {
                statement = info.0
                tenantPaid = info.1
                stage = info.0.status == .draft ? .inRecharge : info.0.status == .paid ? .paidByTenant : .sentToTenant
            }
            let provider = byId[invoice.providerId]
            bills.append(UtilityBill(
                id: "invoice\(invoice.id!)", providerId: invoice.providerId, providerName: provider?.name ?? "Provider",
                kind: provider?.kind ?? .other, month: monthStart(date), stage: stage, invoice: invoice, payments: payments,
                amountMinorUnits: line.map { $0["amountMinorUnits"] as Int } ?? share?.amount ?? invoice.amountMinorUnits,
                statement: statement, tenantPaidMinorUnits: tenantPaid, statementTotalMinorUnits: statement?.totalMinorUnits ?? 0))
        }

        // Utility payments no invoice (or one-off line) accounts for.
        let accountIds = try Properties.accounts(db: db, propertyId: propertyId, role: .current).map(\.accountId)
        if !accountIds.isEmpty {
            let categories = try RechargeNetting.utilityCategoryIds(db: db, propertyId: propertyId)
            var taken = try Recharges.paymentsTaken(db: db, excludingInvoice: nil)
            taken.formUnion(try Int64.fetchAll(db, sql: "SELECT transactionId FROM rechargeLine WHERE transactionId IS NOT NULL"))
            let debits = try Transaction.filter(accountIds.contains(Column("accountId")) && Column("amountMinorUnits") < 0).fetchAll(db)
            for debit in debits where !taken.contains(debit.id!) {
                let day = PropertyDates.day(debit.date)
                guard tenancy.covers(day) else { continue }
                let provider = providers.first { $0.matchesBankDescription(debit.rawDescription) }
                guard provider != nil || categories.contains(debit.categoryId ?? -1) else { continue }
                bills.append(UtilityBill(
                    id: "payment\(debit.id!)", providerId: provider?.id, providerName: provider?.name ?? "Other utilities",
                    kind: provider?.kind ?? .other, month: monthStart(day), stage: .missingInvoice, invoice: nil, payments: [debit],
                    amountMinorUnits: -debit.amountMinorUnits, statement: nil, tenantPaidMinorUnits: 0, statementTotalMinorUnits: 0))
            }
        }

        var rows: [UtilityBillRow] = []
        for provider in providers where bills.contains(where: { $0.providerId == provider.id }) {
            rows.append(UtilityBillRow(providerId: provider.id, name: provider.name, kind: provider.kind))
        }
        let order = UtilityKind.allCases
        rows.sort { (order.firstIndex(of: $0.kind)!, $0.name.lowercased()) < (order.firstIndex(of: $1.kind)!, $1.name.lowercased()) }
        if bills.contains(where: { $0.providerId == nil }) {
            rows.append(UtilityBillRow(providerId: nil, name: "Other utilities", kind: .other))
        }
        bills.sort { ($0.month, $0.id) < ($1.month, $1.id) }
        return UtilityBillsGrid(bills: bills, rows: rows)
    }

    private static func monthStart(_ date: Date) -> Date {
        let parts = MonthRange.components(of: date)
        return MonthRange.of(year: parts.year, month: parts.month).start
    }
}
