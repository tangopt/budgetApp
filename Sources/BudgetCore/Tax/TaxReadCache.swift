import GRDB
import Foundation

/// What working out the rental accounts and returns of several years reads again and again,
/// read once: ownership, splits, attribution rules, HMRC rates, category types, the documents
/// linked to records, and the like. Each year's accounts read them for every person and
/// property, and each return works out every earlier year (brought-forward figures).
///
/// Lives for one `TaxFigures.snapshot` call only (`TaxComputationMemo.reads`), in which the
/// database doesn't change; never across calls, so a later state is always read afresh (the
/// filed-year checks take "before" and "after" snapshots around a write in a savepoint). The
/// filed-year guard records each year's call on its own (`TaxFiguresReads`), so a year's
/// statements are still all run, and recorded, in that year's call. Every value is what the
/// uncached read returns: the same rows, in the same order.
final class TaxReadCache {
    private struct ShareKey: Hashable {
        var startYear: Int
        var personId: Int64
        var propertyId: Int64
        var expenseType: TaxExpenseType
    }

    private struct RuleKey: Hashable {
        var expenseType: TaxExpenseType
        var startYear: Int
    }

    private struct RateKey: Hashable {
        var startYear: Int
        var currency: Currency
    }

    private struct SplitsKey: Hashable {
        var startYear: Int
        var personId: Int64
        var propertyId: Int64
    }

    private var owners: [Int64: [PropertyOwner]] = [:]
    private var splitRows: [SplitsKey: [String?: Row]] = [:]
    private var ruleRows: [Int: [String?: Row]] = [:]
    private var storedRules: [String?: Row]?
    private var shares: [ShareKey: TaxShare] = [:]
    private var rules: [RuleKey: TaxAttributionRule] = [:]
    private var rates: [RateKey: HMRCRate?] = [:]
    private var properties: [Int64: Property?] = [:]
    private var persons: [Int64: Person?] = [:]
    private var everyone: [Person]?
    private var currencies: [Int64: Currency]?
    private var typeEntries: [Int64: [TaxExpenseTypeMap.Entry]] = [:]
    private var policyReceipts: [Int64: [TaxPolicyReceipt]] = [:]
    private var transactionOwners: [Int64: Int64]?
    private var rechargedByCredit: [Int64: Int]?
    private var unmatchedCredits: [Int64: [Transaction]] = [:]
    private var statementDocuments: [Int64: [Int64]] = [:]
    /// Per record type, the documents of each record read so far (records without any absent),
    /// and which records were read.
    private var documents: [EvidenceEntityType: [Int64: [EvidenceDocument]]] = [:]
    private var documentsRead: [EvidenceEntityType: Set<Int64>] = [:]

    private func cached<Key: Hashable, Value>(_ store: inout [Key: Value], _ key: Key, _ read: () throws -> Value) rethrows -> Value {
        if let known = store[key] { return known }
        let value = try read()
        store[key] = value
        return value
    }

    func owners(db: Database, propertyId: Int64) throws -> [PropertyOwner] {
        try cached(&owners, propertyId) { try Properties.owners(db: db, propertyId: propertyId) }
    }

    /// `TaxSplits.share`: the year's splits of the person and property read in one statement
    /// (at most one per type and one for every type: unique index), each decoded when asked for.
    func share(db: Database, startYear: Int, personId: Int64, propertyId: Int64, expenseType: TaxExpenseType) throws -> TaxShare {
        try cached(&shares, ShareKey(startYear: startYear, personId: personId, propertyId: propertyId, expenseType: expenseType)) {
            let rows = try cached(&splitRows, SplitsKey(startYear: startYear, personId: personId, propertyId: propertyId)) {
                try Self.byType(Row.fetchAll(db, sql: """
                    SELECT * FROM taxYearSplit WHERE startYear = ? AND personId = ? AND propertyId = ? ORDER BY id
                    """, arguments: [startYear, personId, propertyId]))
            }
            if let row = rows[expenseType.rawValue] {
                return TaxShare(shareBasisPoints: try TaxYearSplit(row: row).shareBasisPoints, origin: .splitForType)
            }
            if let row = rows[nil] {
                return TaxShare(shareBasisPoints: try TaxYearSplit(row: row).shareBasisPoints, origin: .splitForAllTypes)
            }
            return TaxShare(shareBasisPoints: try TaxSplits.ownershipShare(db: db, startYear: startYear, personId: personId,
                                                                           propertyId: propertyId, reads: self),
                            origin: .ownership)
        }
    }

    /// `TaxAttributionRules.effective`: the year's rules and the stored defaults each read in one
    /// statement (at most one per type and year: unique index), each decoded when asked for.
    func rule(db: Database, expenseType: TaxExpenseType, startYear: Int) throws -> TaxAttributionRule {
        try cached(&rules, RuleKey(expenseType: expenseType, startYear: startYear)) {
            let year = try cached(&ruleRows, startYear) {
                try Self.byType(Row.fetchAll(db, sql: "SELECT * FROM taxAttributionRule WHERE startYear = ? ORDER BY id", arguments: [startYear]))
            }
            if let row = year[expenseType.rawValue] { return try TaxAttributionRule(row: row) }
            if storedRules == nil {
                storedRules = try Self.byType(Row.fetchAll(db, sql: "SELECT * FROM taxAttributionRule WHERE startYear IS NULL ORDER BY id"))
            }
            if let row = storedRules?[expenseType.rawValue] { return try TaxAttributionRule(row: row) }
            return TaxAttributionRule(expenseType: expenseType, rule: TaxAttributionRules.defaultRule(for: expenseType))
        }
    }

    /// Rows by their `expenseType` text (the first of each, as `fetchOne` would take).
    private static func byType(_ rows: [Row]) -> [String?: Row] {
        var result: [String?: Row] = [:]
        for row in rows {
            let type: String? = row["expenseType"]
            if result[type] == nil { result[type] = row }
        }
        return result
    }

    func rate(db: Database, startYear: Int, currency: Currency) throws -> HMRCRate? {
        try cached(&rates, RateKey(startYear: startYear, currency: currency)) {
            try HMRCRates.rate(db: db, startYear: startYear, currencyCode: currency.rawValue)
        }
    }

    func property(db: Database, id: Int64) throws -> Property? {
        try cached(&properties, id) { try Property.fetchOne(db, key: id) }
    }

    func person(db: Database, id: Int64) throws -> Person? {
        try cached(&persons, id) { try Person.fetchOne(db, key: id) }
    }

    /// Every person, as `Person.fetchAll`.
    func everyone(db: Database) throws -> [Person] {
        if let everyone { return everyone }
        let all = try Person.fetchAll(db)
        everyone = all
        return all
    }

    /// Each account's currency.
    func currencies(db: Database) throws -> [Int64: Currency] {
        if let currencies { return currencies }
        let all = Dictionary(uniqueKeysWithValues: try Account.fetchAll(db).compactMap { a in a.id.map { ($0, a.currency) } })
        currencies = all
        return all
    }

    func typeEntries(db: Database, propertyId: Int64) throws -> [TaxExpenseTypeMap.Entry] {
        try cached(&typeEntries, propertyId) { try TaxExpenseTypeMap.entries(db: db, propertyId: propertyId) }
    }

    func policyReceipts(db: Database, propertyId: Int64) throws -> [TaxPolicyReceipt] {
        try cached(&policyReceipts, propertyId) { try TaxPolicyReceipts.receipts(db: db, propertyId: propertyId) }
    }

    func transactionOwners(db: Database) throws -> [Int64: Int64] {
        if let transactionOwners { return transactionOwners }
        let all = try TaxTransactionOwners.all(db: db)
        transactionOwners = all
        return all
    }

    func rechargedByCredit(db: Database) throws -> [Int64: Int] {
        if let rechargedByCredit { return rechargedByCredit }
        let all = try RentReceiptMatching.rechargedByCredit(db: db)
        rechargedByCredit = all
        return all
    }

    func unmatchedCredits(db: Database, propertyId: Int64) throws -> [Transaction] {
        try cached(&unmatchedCredits, propertyId) { try RentReceiptMatching.unmatchedCredits(db: db, propertyId: propertyId) }
    }

    func statementDocumentIds(db: Database, statementId: Int64) throws -> [Int64] {
        try cached(&statementDocuments, statementId) { try RentalAccounts.statementDocumentIds(db: db, statementId: statementId) }
    }

    /// `RentalAccounts.linkedDocuments`: only the records not read before are read.
    func linkedDocuments(db: Database, type: EvidenceEntityType, ids: [Int64]) throws -> [Int64: [EvidenceDocument]] {
        let read = documentsRead[type] ?? []
        let missing = Set(ids).subtracting(read)
        if !missing.isEmpty {
            let found = try RentalAccounts.linkedDocuments(db: db, type: type, ids: Array(missing))
            documents[type, default: [:]].merge(found) { _, new in new }
            documentsRead[type] = read.union(missing)
        }
        let known = documents[type] ?? [:]
        var result: [Int64: [EvidenceDocument]] = [:]
        for id in ids { if let docs = known[id] { result[id] = docs } }
        return result
    }
}
