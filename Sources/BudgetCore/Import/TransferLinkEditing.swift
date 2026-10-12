import Foundation
import GRDB

/// The other side of a linked transaction, for "↔ <account> · <date> · <amount>".
public struct TransferCounterpart: Equatable, Identifiable, Sendable {
    public let linkId: Int64
    public let origin: TransferLinkOrigin
    public let transactionId: Int64
    public let accountName: String
    public let currency: Currency
    public let date: Date
    public let amountMinorUnits: Int
    public var id: Int64 { linkId }
}

/// A transaction Link to transfer… offers.
public struct TransferCandidate: Equatable, Identifiable, Sendable {
    public let transactionId: Int64
    public let accountName: String
    public let currency: Currency
    public let date: Date
    public let rawDescription: String
    public let amountMinorUnits: Int
    public var id: Int64 { transactionId }
}

public enum TransferLinkError: LocalizedError, Equatable {
    case transactionNotFound
    case notOppositeAmounts
    case sameAccount
    case alreadyLinked

    public var errorDescription: String? {
        switch self {
        case .transactionNotFound: return "That transaction no longer exists."
        case .notOppositeAmounts: return "A transfer links money sent with money received."
        case .sameAccount: return "A transfer links two different accounts."
        case .alreadyLinked: return "That transaction is already linked to a transfer."
        }
    }
}

extension TransferLinks {
    /// Manual candidates: ±7 days and ±3% amount for bank rows; the same pay month for a
    /// spreadsheet-history row.
    public static let candidateDayWindow: TimeInterval = 7 * 86_400

    /// Active links' other legs, keyed by each linked transaction id (a historical monthly
    /// total can have several).
    public static func counterparts(db: Database) throws -> [Int64: [TransferCounterpart]] {
        let links = try TransferLink.active.fetchAll(db)
        guard !links.isEmpty else { return [:] }
        let ids = Set(links.flatMap { [$0.outTransactionId, $0.inTransactionId] })
        let transactions = Dictionary(try Transaction.filter(ids.contains(Column("id"))).fetchAll(db).compactMap { t in t.id.map { ($0, t) } },
                                      uniquingKeysWith: { a, _ in a })
        let accounts = Dictionary(try Account.fetchAll(db).compactMap { a in a.id.map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
        var result: [Int64: [TransferCounterpart]] = [:]
        for link in links {
            guard let linkId = link.id else { continue }
            for (this, other) in [(link.outTransactionId, link.inTransactionId), (link.inTransactionId, link.outTransactionId)] {
                guard let transaction = transactions[other], let account = accounts[transaction.accountId] else { continue }
                result[this, default: []].append(TransferCounterpart(linkId: linkId, origin: link.origin, transactionId: other,
                                                                     accountName: account.name, currency: account.currency,
                                                                     date: transaction.date, amountMinorUnits: transaction.amountMinorUnits))
            }
        }
        return result.mapValues { $0.sorted { $0.date < $1.date } }
    }

    /// Unlink: an auto link is kept dismissed (never auto-linked again); a manual one is deleted.
    public static func unlink(db: Database, linkId: Int64) throws {
        guard var link = try TransferLink.fetchOne(db, key: linkId) else { return }
        switch link.origin {
        case .auto:
            link.isDismissed = true
            try link.update(db)
        case .manual:
            try link.delete(db)
        }
    }

    /// Transactions `transactionId` could be linked with by hand, closest date first: the
    /// opposite sign in another account, not already the leg of an active link (a historical
    /// monthly total sent can take more). Bank rows: within ±7 days and ±3% amount (converted
    /// at the stored rate across currencies); spreadsheet-history rows: within the same pay month.
    public static func candidates(db: Database, for transactionId: Int64, today: Date = Date()) throws -> [TransferCandidate] {
        guard let transaction = try Transaction.fetchOne(db, key: transactionId) else { throw TransferLinkError.transactionNotFound }
        guard transaction.amountMinorUnits != 0 else { return [] }
        let accounts = Dictionary(try Account.fetchAll(db).compactMap { a in a.id.map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
        let historicalBatchIds = Set(try ImportBatch.fetchAll(db).filter(TransferMatcher.isHistoricalSource).compactMap(\.id))
        let links = try TransferLink.active.fetchAll(db)
        let linkedIns = Set(links.map(\.inTransactionId))
        let linkedOuts = Set(links.map(\.outTransactionId))
        let rate = try ExchangeRateSetting.currentOrDefault(db: db).eurToGbpRate
        let isHistorical = { (t: Transaction) in historicalBatchIds.contains(t.importBatchId) }
        let isFree = { (t: Transaction) -> Bool in
            guard let id = t.id else { return false }
            return t.amountMinorUnits > 0 ? !linkedIns.contains(id) : (isHistorical(t) || !linkedOuts.contains(id))
        }
        guard isFree(transaction), let account = accounts[transaction.accountId] else { return [] }

        let thisHistorical = isHistorical(transaction)
        let calendar = try PayCalendar.load(db: db, today: today)
        let payMonth = calendar.range(of: calendar.month(containing: transaction.date))
        let wide = thisHistorical ? (payMonth.start.addingTimeInterval(-40 * 86_400), payMonth.end.addingTimeInterval(40 * 86_400))
                                  : (transaction.date.addingTimeInterval(-40 * 86_400), transaction.date.addingTimeInterval(40 * 86_400))
        let nearby = try Transaction
            .filter(Column("accountId") != transaction.accountId && Column("date") >= wide.0 && Column("date") <= wide.1)
            .fetchAll(db)
        let candidates = nearby.filter { other in
            guard (other.amountMinorUnits > 0) != (transaction.amountMinorUnits > 0), other.amountMinorUnits != 0, isFree(other),
                  let otherAccount = accounts[other.accountId] else { return false }
            if thisHistorical || isHistorical(other) {
                // A monthly total sent is made of smaller amounts received.
                let (historical, partner) = thisHistorical ? (transaction, other) : (other, transaction)
                let range = calendar.range(of: calendar.month(containing: historical.date))
                return partner.date >= range.start && partner.date <= range.end
                    && (historical.amountMinorUnits > 0 || abs(partner.amountMinorUnits) <= abs(historical.amountMinorUnits))
            }
            guard abs(other.date.timeIntervalSince(transaction.date)) <= candidateDayWindow else { return false }
            let (out, outCurrency, inLeg, inCurrency) = transaction.amountMinorUnits < 0
                ? (transaction, account.currency, other, otherAccount.currency)
                : (other, otherAccount.currency, transaction, account.currency)
            return Self.withinTolerance(out.amountMinorUnits, outCurrency, inLeg.amountMinorUnits, inCurrency, rate: rate)
        }
        return candidates
            .sorted { (abs($0.date.timeIntervalSince(transaction.date)), $0.id ?? 0) < (abs($1.date.timeIntervalSince(transaction.date)), $1.id ?? 0) }
            .compactMap { other in
                guard let id = other.id, let otherAccount = accounts[other.accountId] else { return nil }
                return TransferCandidate(transactionId: id, accountName: otherAccount.name, currency: otherAccount.currency, date: other.date,
                                         rawDescription: other.rawDescription, amountMinorUnits: other.amountMinorUnits)
            }
    }

    /// ±3% of the amount sent (converted into the receiving currency), whatever the currencies.
    static func withinTolerance(_ outAmount: Int, _ outCurrency: Currency, _ inAmount: Int, _ inCurrency: Currency, rate: Double) -> Bool {
        let converted = TransferMatcher.convert(Double(abs(outAmount)), from: outCurrency, to: inCurrency, rate: rate)
        return abs(Double(abs(inAmount)) - converted) <= converted * TransferMatcher.fxTolerance
    }

    /// Link to transfer…: links the two by hand (origin `manual`), whichever was sent.
    @discardableResult
    public static func link(db: Database, transactionId: Int64, with otherId: Int64) throws -> TransferLink {
        guard let first = try Transaction.fetchOne(db, key: transactionId), let second = try Transaction.fetchOne(db, key: otherId) else {
            throw TransferLinkError.transactionNotFound
        }
        guard first.amountMinorUnits != 0, second.amountMinorUnits != 0, (first.amountMinorUnits > 0) != (second.amountMinorUnits > 0) else {
            throw TransferLinkError.notOppositeAmounts
        }
        guard first.accountId != second.accountId else { throw TransferLinkError.sameAccount }
        let (out, inLeg) = first.amountMinorUnits < 0 ? (first, second) : (second, first)
        let historicalBatchIds = Set(try ImportBatch.fetchAll(db).filter(TransferMatcher.isHistoricalSource).compactMap(\.id))
        if try TransferLink.active.filter(Column("inTransactionId") == inLeg.id!).fetchCount(db) > 0 { throw TransferLinkError.alreadyLinked }
        if !historicalBatchIds.contains(out.importBatchId),
           try TransferLink.active.filter(Column("outTransactionId") == out.id!).fetchCount(db) > 0 { throw TransferLinkError.alreadyLinked }
        var link = TransferLink(outTransactionId: out.id!, inTransactionId: inLeg.id!, origin: .manual)
        try link.insert(db)
        return link
    }

    /// The Categories screen's "Money goes to an account you don't import — never match".
    /// Turning it on removes the auto links involving the category (either leg); turning it
    /// off lets the matcher look at its transactions again (and runs it).
    public static func setExternalTransfer(db: Database, categoryId: Int64, _ isExternal: Bool, today: Date = Date()) throws {
        try db.execute(sql: "UPDATE category SET isExternalTransfer = ? WHERE id = ?", arguments: [isExternal, categoryId])
        if isExternal {
            try db.execute(sql: """
                DELETE FROM transferLink WHERE origin = ? AND isDismissed = 0 AND (
                    outTransactionId IN (SELECT id FROM transaction_ WHERE categoryId = ?)
                    OR inTransactionId IN (SELECT id FROM transaction_ WHERE categoryId = ?))
                """, arguments: [TransferLinkOrigin.auto.rawValue, categoryId, categoryId])
        } else {
            try TransferMatcher.match(db: db, today: today)
        }
    }
}
