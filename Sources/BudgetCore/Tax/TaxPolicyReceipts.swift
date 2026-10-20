import GRDB
import Foundation

// Per-payment tax details the bank movement can't carry (2026-10-17 follow-ups):
//
// - `TaxPolicyReceipt`: an insurer's receipt — its policy year, "instalment n of m" and the
//   cover period it pays for. Linked to its bank debit, it tells the insurance rules which
//   months the debit covers; without a debit (a receipt paid before the bank history starts,
//   or from another account) it is a source of its own. A debit that settles several items
//   (a condomínio payment of a year's quotas and an extra charge) has one receipt per item,
//   each with its amount and the months it is for: the items, adding up to the debit, are
//   the sources then, each attributed by its own months.
// - `TaxTransactionOwner`: whose a payment is for tax (a person's own PT IRS paid from the
//   joint account): that person takes the whole of it, the other owners none.

/// An insurer's receipt (or any premium paid by instalments) of a property.
public struct TaxPolicyReceipt: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var propertyId: Int64
    /// The tax line it belongs to (insurance by default).
    public var expenseType: TaxExpenseType
    /// The bank debit that paid it; `nil` = paid outside the bank history (the receipt is the source).
    /// Several receipts on one debit are its items (amounts adding up to the debit's).
    public var transactionId: Int64?
    /// The payment (or receipt) date.
    public var date: Date
    /// Positive, in `currency`. With a transaction, the transaction's amount is used — unless
    /// the debit has several receipts (its items): then each item's own amount.
    public var amountMinorUnits: Int
    public var currency: Currency
    /// The policy (calendar) year the receipt is for.
    public var policyYear: Int?
    /// "Instalment n of m" within the policy year.
    public var instalment: Int?
    public var instalmentCount: Int?
    /// The cover the receipt pays for: `coverStart` to `coverEnd` (exclusive: the next cover
    /// starts that day, as the insurer's receipts print it).
    public var coverStart: Date?
    public var coverEnd: Date?
    public var notes: String?

    public init(id: Int64? = nil, propertyId: Int64, expenseType: TaxExpenseType = .insurance, transactionId: Int64? = nil, date: Date,
                amountMinorUnits: Int, currency: Currency, policyYear: Int? = nil, instalment: Int? = nil, instalmentCount: Int? = nil,
                coverStart: Date? = nil, coverEnd: Date? = nil, notes: String? = nil) {
        self.id = id
        self.propertyId = propertyId
        self.expenseType = expenseType
        self.transactionId = transactionId
        self.date = date
        self.amountMinorUnits = amountMinorUnits
        self.currency = currency
        self.policyYear = policyYear
        self.instalment = instalment
        self.instalmentCount = instalmentCount
        self.coverStart = coverStart
        self.coverEnd = coverEnd
        self.notes = notes
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "taxPolicyReceipt"

    /// The cover period as `[start, end)`, when both ends are known and in order.
    public var cover: DateInterval? {
        guard let coverStart, let coverEnd else { return nil }
        let start = PropertyDates.day(coverStart), end = PropertyDates.day(coverEnd)
        return start < end ? DateInterval(start: start, end: end) : nil
    }

    /// The policy year: the stored one, else the year of the cover's first month, else the
    /// year of the month after the payment (a December debit pays next year's first instalment).
    public var effectivePolicyYear: Int {
        if let policyYear { return policyYear }
        let calendar = MonthRange.calendar
        if let cover, let first = RentalAccounts.monthSpan(cover).first { return calendar.component(.year, from: first) }
        return TaxPolicyReceipts.policyYear(afterDebit: date)
    }

    /// "instalment 2 of 3, policy year 2025".
    public var label: String {
        var parts: [String] = []
        if let instalment { parts.append("instalment \(instalment)" + (instalmentCount.map { " of \($0)" } ?? "")) }
        parts.append("policy year \(effectivePolicyYear)")
        return parts.joined(separator: ", ")
    }
}

/// Whose a transaction is for tax: the person takes all of it, the other owners none.
public struct TaxTransactionOwner: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var transactionId: Int64
    public var personId: Int64
    public var notes: String?

    public init(id: Int64? = nil, transactionId: Int64, personId: Int64, notes: String? = nil) {
        self.id = id
        self.transactionId = transactionId
        self.personId = personId
        self.notes = notes
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "taxTransactionOwner"
}

public extension EvidenceEntity {
    static func taxPolicyReceipt(_ id: Int64) -> EvidenceEntity { EvidenceEntity(type: .taxPolicyReceipt, id: id) }
}

public enum TaxPolicyReceipts {
    /// The policy year a debit without a receipt record pays for: the year of the month after it.
    public static func policyYear(afterDebit date: Date) -> Int {
        let calendar = MonthRange.calendar
        let next = calendar.date(byAdding: .month, value: 1, to: RentalAccounts.monthOf(date).start)!
        return calendar.component(.year, from: next)
    }

    /// Inserts or updates the receipt (positive amount, day-normalised dates, a valid instalment).
    public static func save(db: Database, _ receipt: inout TaxPolicyReceipt) throws {
        guard try Property.exists(db, key: receipt.propertyId) else { throw TaxError.propertyNotFound }
        guard receipt.amountMinorUnits >= 0 else { throw TaxError.negativeAmount }
        if let transactionId = receipt.transactionId, try !Transaction.exists(db, key: transactionId) { throw TaxError.transactionNotFound }
        if let n = receipt.instalment, n < 1 || (receipt.instalmentCount.map { n > $0 } ?? false) { throw TaxError.invalidInstalment }
        if let m = receipt.instalmentCount, m < 1 { throw TaxError.invalidInstalment }
        receipt.date = PropertyDates.day(receipt.date)
        receipt.coverStart = receipt.coverStart.map(PropertyDates.day)
        receipt.coverEnd = receipt.coverEnd.map(PropertyDates.day)
        if let start = receipt.coverStart, let end = receipt.coverEnd, start >= end { throw TaxError.invalidCoverPeriod }
        // A debit's items never add up to more than the debit.
        if let transactionId = receipt.transactionId {
            var others = TaxPolicyReceipt.filter(Column("transactionId") == transactionId)
            if let id = receipt.id { others = others.filter(Column("id") != id) }
            let otherAmounts = try others.fetchAll(db).map(\.amountMinorUnits)
            if !otherAmounts.isEmpty, let debit = try Transaction.fetchOne(db, key: transactionId),
               otherAmounts.reduce(receipt.amountMinorUnits, +) > abs(debit.amountMinorUnits) {
                throw TaxError.itemsExceedPayment
            }
        }
        receipt.notes = Transaction.normalizedNote(receipt.notes)
        try receipt.save(db)
    }

    /// A debit's receipts by transaction id (several = its items), each list by date then id.
    public static func byTransaction(_ receipts: [TaxPolicyReceipt]) -> [Int64: [TaxPolicyReceipt]] {
        Dictionary(grouping: receipts.filter { $0.transactionId != nil }, by: { $0.transactionId! })
    }

    /// The property's receipts, by date then id.
    public static func receipts(db: Database, propertyId: Int64) throws -> [TaxPolicyReceipt] {
        try TaxPolicyReceipt.filter(Column("propertyId") == propertyId).order(Column("date"), Column("id")).fetchAll(db)
    }

    @discardableResult
    public static func delete(db: Database, id: Int64) throws -> Bool {
        try TaxPolicyReceipt.deleteOne(db, key: id)
    }
}

public enum TaxTransactionOwners {
    /// Sets (or, with `nil`, clears) whose the transaction is.
    public static func set(db: Database, transactionId: Int64, personId: Int64?, notes: String? = nil) throws {
        guard try Transaction.exists(db, key: transactionId) else { throw TaxError.transactionNotFound }
        let existing = try TaxTransactionOwner.filter(Column("transactionId") == transactionId).fetchOne(db)
        guard let personId else {
            if let existing { try existing.delete(db) }
            return
        }
        guard try Person.exists(db, key: personId) else { throw TaxError.personNotFound }
        // Only someone who owns a property paid from that account on the payment's date.
        let transaction = try Transaction.fetchOne(db, key: transactionId)!
        let day = PropertyDates.day(transaction.date)
        let propertyIds = try PropertyAccount.filter(Column("accountId") == transaction.accountId).fetchAll(db).map(\.propertyId)
        if !propertyIds.isEmpty {
            let owns = try propertyIds.contains { propertyId in
                try Properties.owners(db: db, propertyId: propertyId).contains {
                    $0.personId == personId && ($0.fromDate.map { $0 <= day } ?? true) && ($0.toDate.map { day <= $0 } ?? true)
                }
            }
            guard owns else { throw TaxError.notAnOwner }
        }
        var row = existing ?? TaxTransactionOwner(transactionId: transactionId, personId: personId)
        row.personId = personId
        row.notes = Transaction.normalizedNote(notes)
        try row.save(db)
    }

    /// Transaction id → person id, for every assigned transaction.
    public static func all(db: Database) throws -> [Int64: Int64] {
        Dictionary(try TaxTransactionOwner.fetchAll(db).map { ($0.transactionId, $0.personId) }, uniquingKeysWith: { a, _ in a })
    }
}

func registerTaxPolicyReceiptMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addTaxPolicyReceiptsAndOwners") { db in
        try db.create(table: "taxPolicyReceipt") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("propertyId", .integer).notNull().indexed().references("property", onDelete: .cascade)
            t.column("expenseType", .text).notNull()
            t.column("transactionId", .integer).unique().references("transaction_", onDelete: .cascade)
            t.column("date", .datetime).notNull()
            t.column("amountMinorUnits", .integer).notNull()
            t.column("currency", .text).notNull()
            t.column("policyYear", .integer)
            t.column("instalment", .integer)
            t.column("instalmentCount", .integer)
            t.column("coverStart", .datetime)
            t.column("coverEnd", .datetime)
            t.column("notes", .text)
        }
        try db.create(table: "taxTransactionOwner") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("transactionId", .integer).notNull().unique().references("transaction_", onDelete: .cascade)
            t.column("personId", .integer).notNull().indexed().references("person", onDelete: .cascade)
            t.column("notes", .text)
        }
        let value = EvidenceEntityType.taxPolicyReceipt.rawValue
        try db.execute(sql: """
            CREATE TRIGGER documentLink_delete_\(value) AFTER DELETE ON taxPolicyReceipt
            BEGIN DELETE FROM documentLink WHERE entityType = '\(value)' AND entityId = OLD.id; END
            """)
        try db.execute(sql: """
            CREATE TRIGGER evidenceWaiver_delete_\(value) AFTER DELETE ON taxPolicyReceipt
            BEGIN DELETE FROM evidenceWaiver WHERE entityType = '\(value)' AND entityId = OLD.id; END
            """)
    }
}

/// Several receipts on one debit (its items): `transactionId` no longer unique. The table is
/// rebuilt (SQLite can't drop a constraint), its rows, indexes and triggers kept; GRDB runs
/// migrations with foreign keys off, so the not-claimed marks and links that point at
/// receipts stay.
func registerTaxPolicyReceiptItemsMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("taxPolicyReceiptItems") { db in
        try db.create(table: "taxPolicyReceipt_new") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("propertyId", .integer).notNull().references("property", onDelete: .cascade)
            t.column("expenseType", .text).notNull()
            t.column("transactionId", .integer).references("transaction_", onDelete: .cascade)
            t.column("date", .datetime).notNull()
            t.column("amountMinorUnits", .integer).notNull()
            t.column("currency", .text).notNull()
            t.column("policyYear", .integer)
            t.column("instalment", .integer)
            t.column("instalmentCount", .integer)
            t.column("coverStart", .datetime)
            t.column("coverEnd", .datetime)
            t.column("notes", .text)
        }
        let columns = "id, propertyId, expenseType, transactionId, date, amountMinorUnits, currency, policyYear, instalment, instalmentCount, coverStart, coverEnd, notes"
        try db.execute(sql: "INSERT INTO taxPolicyReceipt_new (\(columns)) SELECT \(columns) FROM taxPolicyReceipt")
        // AUTOINCREMENT: ids of deleted receipts are never reused; keep the counter.
        let sequence = try Int64.fetchOne(db, sql: "SELECT seq FROM sqlite_sequence WHERE name = 'taxPolicyReceipt'") ?? 0
        try db.drop(table: "taxPolicyReceipt")
        try db.rename(table: "taxPolicyReceipt_new", to: "taxPolicyReceipt")
        try db.execute(sql: "DELETE FROM sqlite_sequence WHERE name IN ('taxPolicyReceipt', 'taxPolicyReceipt_new')")
        let maxId = try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM taxPolicyReceipt") ?? 0
        try db.execute(sql: "INSERT INTO sqlite_sequence (name, seq) VALUES ('taxPolicyReceipt', ?)", arguments: [max(sequence, maxId)])
        try db.create(index: "taxPolicyReceipt_on_propertyId", on: "taxPolicyReceipt", columns: ["propertyId"])
        try db.create(index: "taxPolicyReceipt_on_transactionId", on: "taxPolicyReceipt", columns: ["transactionId"])
        let value = EvidenceEntityType.taxPolicyReceipt.rawValue
        try db.execute(sql: """
            CREATE TRIGGER documentLink_delete_\(value) AFTER DELETE ON taxPolicyReceipt
            BEGIN DELETE FROM documentLink WHERE entityType = '\(value)' AND entityId = OLD.id; END
            """)
        try db.execute(sql: """
            CREATE TRIGGER evidenceWaiver_delete_\(value) AFTER DELETE ON taxPolicyReceipt
            BEGIN DELETE FROM evidenceWaiver WHERE entityType = '\(value)' AND entityId = OLD.id; END
            """)
    }
}
