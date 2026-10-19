import GRDB
import Foundation

// "Deductible, not claimed" (2026-10-19): a cost the return could have deducted but that was
// left off it for a UK tax year — the accountant didn't claim it on a filed return, so the
// figures must stay as filed. The rental accounts leave the source out of that year's line
// and list it apart, with its amount, for information. One mark per source and year; it
// applies to every owner (a return leaves a cost out for the property, not for one person).

/// A source of a deductible line (a bank transaction, a manual item or an insurer's receipt
/// kept on its own) left off the year's return. Exactly one source column is set.
public struct TaxNotClaimed: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    /// The UK tax year it wasn't claimed in (2021 = 2021/22).
    public var startYear: Int
    public var transactionId: Int64?
    public var manualItemId: Int64?
    public var policyReceiptId: Int64?
    /// Why (the evidence: "not on the filed return's accountancy line").
    public var notes: String?

    public init(id: Int64? = nil, startYear: Int, transactionId: Int64? = nil, manualItemId: Int64? = nil, policyReceiptId: Int64? = nil,
                notes: String? = nil) {
        self.id = id
        self.startYear = startYear
        self.transactionId = transactionId
        self.manualItemId = manualItemId
        self.policyReceiptId = policyReceiptId
        self.notes = notes
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "taxNotClaimed"

    /// The source it marks; `nil` for a row without one (never stored).
    public var reference: RentalAccounts.SourceReference? {
        if let transactionId { return .transaction(transactionId) }
        if let manualItemId { return .manualItem(manualItemId) }
        if let policyReceiptId { return .policyReceipt(policyReceiptId) }
        return nil
    }
}

public enum TaxNotClaimedSources {
    /// The lines a source can be left off: the deductible expenses and the finance costs.
    public static func isClaimable(_ type: TaxExpenseType) -> Bool {
        type.isDeductibleExpense || type == .financeCost
    }

    /// Marks the source as not claimed in the year (`notClaimed`), or claimed again (removes
    /// the mark). The source must feed one of that year's rental-account lines (any owner's, as
    /// the year computes it — a utility debit netted against recharges is on the Utilities
    /// line), and that line must be a deductible expense or the finance costs: otherwise it's
    /// refused (`notASourceOfTheYear`, `notClaimable`). Idempotent: marking a marked source
    /// updates its notes.
    public static func set(db: Database, startYear: Int, reference: RentalAccounts.SourceReference, notClaimed: Bool,
                           notes: String? = nil) throws {
        let existing = try request(startYear: startYear, reference: reference)?.fetchOne(db)
        guard notClaimed else {
            if let existing { try existing.delete(db) }
            return
        }
        guard let type = try lineType(db: db, startYear: startYear, reference: reference) else { throw TaxError.notASourceOfTheYear }
        guard isClaimable(type) else { throw TaxError.notClaimable }
        var row = existing ?? TaxNotClaimed(startYear: startYear)
        switch reference {
        case let .transaction(id): row.transactionId = id
        case let .manualItem(id): row.manualItemId = id
        case let .policyReceipt(id): row.policyReceiptId = id
        case .rentReceipt: throw TaxError.notClaimable
        }
        row.notes = Transaction.normalizedNote(notes)
        try row.save(db)
    }

    /// The line the source feeds in the year's rental accounts (any owner of its property),
    /// `nil` when it feeds none that year. A missing record throws.
    static func lineType(db: Database, startYear: Int, reference: RentalAccounts.SourceReference) throws -> TaxExpenseType? {
        let propertyIds: [Int64]
        switch reference {
        case let .transaction(id):
            guard let transaction = try Transaction.fetchOne(db, key: id) else { throw TaxError.transactionNotFound }
            propertyIds = try PropertyAccount.filter(Column("accountId") == transaction.accountId).fetchAll(db).map(\.propertyId)
        case let .manualItem(id):
            guard let item = try TaxManualItem.fetchOne(db, key: id) else { throw TaxError.sourceNotFound }
            propertyIds = item.propertyId.map { [$0] } ?? []
        case let .policyReceipt(id):
            guard let receipt = try TaxPolicyReceipt.fetchOne(db, key: id) else { throw TaxError.sourceNotFound }
            propertyIds = [receipt.propertyId]
        case .rentReceipt:
            throw TaxError.notClaimable
        }
        for propertyId in Array(Set(propertyIds)).sorted() {
            for personId in Array(Set(try Properties.owners(db: db, propertyId: propertyId).map(\.personId))).sorted() {
                let accounts = try RentalAccounts.compute(db: db, taxYear: UKTaxYear(startYear: startYear), personId: personId, propertyId: propertyId)
                if let line = accounts.allLines.first(where: { line in
                    (line.sources + line.notClaimedSources).contains { $0.reference == reference }
                }) {
                    return line.expenseType
                }
            }
        }
        return nil
    }

    /// The year's marks, by the source they mark.
    public static func marks(db: Database, startYear: Int) throws -> [RentalAccounts.SourceReference: TaxNotClaimed] {
        var result: [RentalAccounts.SourceReference: TaxNotClaimed] = [:]
        for row in try TaxNotClaimed.filter(Column("startYear") == startYear).fetchAll(db) {
            if let reference = row.reference { result[reference] = row }
        }
        return result
    }

    /// Whether the source is marked not claimed in the year.
    public static func isMarked(db: Database, startYear: Int, reference: RentalAccounts.SourceReference) throws -> Bool {
        try request(startYear: startYear, reference: reference)?.fetchCount(db) ?? 0 > 0
    }

    private static func request(startYear: Int, reference: RentalAccounts.SourceReference) -> QueryInterfaceRequest<TaxNotClaimed>? {
        let base = TaxNotClaimed.filter(Column("startYear") == startYear)
        switch reference {
        case let .transaction(id): return base.filter(Column("transactionId") == id)
        case let .manualItem(id): return base.filter(Column("manualItemId") == id)
        case let .policyReceipt(id): return base.filter(Column("policyReceiptId") == id)
        case .rentReceipt: return nil
        }
    }
}

func registerTaxNotClaimedMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addTaxNotClaimed") { db in
        try db.create(table: "taxNotClaimed") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("startYear", .integer).notNull()
            t.column("transactionId", .integer).indexed().references("transaction_", onDelete: .cascade)
            t.column("manualItemId", .integer).indexed().references("taxManualItem", onDelete: .cascade)
            t.column("policyReceiptId", .integer).indexed().references("taxPolicyReceipt", onDelete: .cascade)
            t.column("notes", .text)
            t.uniqueKey(["startYear", "transactionId"])
            t.uniqueKey(["startYear", "manualItemId"])
            t.uniqueKey(["startYear", "policyReceiptId"])
            t.check(sql: "(transactionId IS NOT NULL) + (manualItemId IS NOT NULL) + (policyReceiptId IS NOT NULL) = 1")
        }
    }
}
