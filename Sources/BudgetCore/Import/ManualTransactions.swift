import Foundation
import GRDB

public enum ManualTransactionError: Error, Equatable, LocalizedError {
    case transactionNotFound
    case accountNotFound
    case categoryNotFound
    /// Reserves are forecast-only and never hold transactions.
    case reservedCategory
    case zeroAmount
    case emptyDescription
    /// Only transactions added by hand can be edited this way or deleted.
    case notManual
    /// Add the other side…: the transaction is filed under an external-transfer category.
    case externalTransferCategory
    /// Add the other side…: the transaction is filed under an income or expense category.
    case notATransfer
    /// Add the other side…: the transaction is already a leg of a transfer.
    case alreadyLinked
    /// Add the other side…: the other side must be in another account.
    case sameAccount

    public var errorDescription: String? {
        switch self {
        case .transactionNotFound: return "That transaction no longer exists."
        case .accountNotFound: return "That account no longer exists."
        case .categoryNotFound: return "That category no longer exists."
        case .reservedCategory: return "Reserved categories can't hold transactions."
        case .zeroAmount: return "Enter an amount."
        case .emptyDescription: return "Enter a description."
        case .notManual: return "Only transactions you added by hand can be changed or deleted here."
        case .externalTransferCategory: return "This transaction's category is for an account you don't import, so it has no other side."
        case .notATransfer: return "Set a transfer category first — only transfers have another side."
        case .alreadyLinked: return "That transaction is already linked to a transfer."
        case .sameAccount: return "The other side of a transfer is in another account."
        }
    }
}

/// A row an import would save in place of a manual entry (spec §3): same account, same amount
/// and sign, dated within ±3 days.
public struct StagedManualReplacement: Equatable, Sendable {
    public let transactionId: Int64
    public let date: Date
    public let categoryId: Int64?
    public let note: String?
    /// The manual entry is a leg of an active transfer link (repointed to the imported row).
    public let isLinked: Bool

    public init(transactionId: Int64, date: Date, categoryId: Int64?, note: String?, isLinked: Bool) {
        self.transactionId = transactionId
        self.date = date
        self.categoryId = categoryId
        self.note = note
        self.isLinked = isLinked
    }
}

/// Transactions added by hand (spec §1): each lives in its account's "Manual entries" batch,
/// with a `manual-<uuid>` fingerprint that never collides with a bank row's.
public enum ManualTransactions {
    public static let batchSourceFileName = "Manual entries"
    /// How far apart an imported row and the manual entry it replaces may be dated.
    public static let replacementDayWindow: TimeInterval = 3 * 86_400

    /// Adds a transaction by hand: confirmed (`.manual`) when categorised, otherwise pending
    /// review. The description and note are trimmed.
    /// Never into a built-in adjustment category (only Update balance files there).
    @discardableResult
    public static func add(db: Database, accountId: Int64, date: Date, description: String, amountMinorUnits: Int,
                           categoryId: Int64?, note: String?) throws -> Transaction {
        try add(db: db, accountId: accountId, date: date, description: description, amountMinorUnits: amountMinorUnits,
                categoryId: categoryId, note: note, allowBuiltIn: false)
    }

    /// `add`; `allowBuiltIn` lets Update balance (`BalanceUpdates.save`) file into a built-in
    /// adjustment category.
    @discardableResult
    static func add(db: Database, accountId: Int64, date: Date, description: String, amountMinorUnits: Int,
                    categoryId: Int64?, note: String?, allowBuiltIn: Bool) throws -> Transaction {
        let trimmed = try validate(db: db, accountId: accountId, description: description, amountMinorUnits: amountMinorUnits, categoryId: categoryId, allowBuiltIn: allowBuiltIn)
        var transaction = Transaction(importBatchId: try batchId(db: db, accountId: accountId), accountId: accountId, date: date,
                                      rawDescription: trimmed, amountMinorUnits: amountMinorUnits, categoryId: categoryId,
                                      status: categoryId == nil ? .pendingReview : .confirmed,
                                      categorizedBy: categoryId == nil ? .none : .manual,
                                      fingerprint: "manual-\(UUID().uuidString)", note: Transaction.normalizedNote(note), isManual: true)
        try transaction.insert(db)
        return transaction
    }

    /// Edits a manual transaction (never into a built-in adjustment category, though an
    /// adjustment keeps its own). Moving it to another account moves it into that account's
    /// Manual entries batch. Its transfer links stay unless the change breaks one (the out leg
    /// must be money sent, the in leg money received, in different accounts): that link is removed.
    public static func update(db: Database, id: Int64, date: Date, description: String, amountMinorUnits: Int,
                              accountId: Int64, categoryId: Int64?, note: String?) throws {
        guard var transaction = try Transaction.fetchOne(db, key: id) else { throw ManualTransactionError.transactionNotFound }
        guard transaction.isManual else { throw ManualTransactionError.notManual }
        // An adjustment may keep its built-in category; nothing else may move into one.
        let trimmed = try validate(db: db, accountId: accountId, description: description, amountMinorUnits: amountMinorUnits, categoryId: categoryId,
                                   allowBuiltIn: categoryId != nil && categoryId == transaction.categoryId)
        if accountId != transaction.accountId {
            transaction.importBatchId = try batchId(db: db, accountId: accountId)
            transaction.accountId = accountId
        }
        transaction.date = date
        transaction.rawDescription = trimmed
        transaction.amountMinorUnits = amountMinorUnits
        if categoryId != transaction.categoryId {
            transaction.status = categoryId == nil ? .pendingReview : .confirmed
            transaction.categorizedBy = categoryId == nil ? .none : .manual
        }
        transaction.categoryId = categoryId
        transaction.note = Transaction.normalizedNote(note)
        try transaction.update(db)
        try removeBrokenLinks(db: db, transaction: transaction)
    }

    /// Deletes a manual transaction; its transfer links go with it.
    public static func delete(db: Database, id: Int64) throws {
        guard let transaction = try Transaction.fetchOne(db, key: id) else { throw ManualTransactionError.transactionNotFound }
        guard transaction.isManual else { throw ManualTransactionError.notManual }
        _ = try Transaction.deleteOne(db, key: id)
    }

    /// Add the other side…: for a transaction in no active link, uncategorised or in a
    /// (non-external) transfer category, creates the opposite leg by hand in `accountId` —
    /// same date and category, the amount converted at the stored
    /// exchange rate across currencies, described "Transfer from/to <account>" — and links
    /// the two (origin `manual`: out = money sent, in = money received).
    @discardableResult
    public static func addOtherSide(db: Database, transactionId: Int64, accountId: Int64) throws -> Transaction {
        guard let source = try Transaction.fetchOne(db, key: transactionId), let sourceId = source.id else {
            throw ManualTransactionError.transactionNotFound
        }
        guard let target = try Account.fetchOne(db, key: accountId) else { throw ManualTransactionError.accountNotFound }
        guard accountId != source.accountId else { throw ManualTransactionError.sameAccount }
        guard let sourceAccount = try Account.fetchOne(db, key: source.accountId) else { throw ManualTransactionError.accountNotFound }
        guard source.amountMinorUnits != 0 else { throw ManualTransactionError.zeroAmount }
        if let categoryId = source.categoryId, let category = try Category.fetchOne(db, key: categoryId) {
            guard !category.isExternalTransfer else { throw ManualTransactionError.externalTransferCategory }
            guard category.type == .transfer else { throw ManualTransactionError.notATransfer }
        }
        let linked = try TransferLink.active
            .filter(Column("outTransactionId") == sourceId || Column("inTransactionId") == sourceId)
            .fetchCount(db)
        guard linked == 0 else { throw ManualTransactionError.alreadyLinked }

        let rate = try ExchangeRateSetting.currentOrDefault(db: db).eurToGbpRate
        let isIncoming = source.amountMinorUnits < 0
        let description = isIncoming ? "Transfer from \(sourceAccount.displayName)" : "Transfer to \(sourceAccount.displayName)"
        var other = Transaction(importBatchId: try batchId(db: db, accountId: accountId), accountId: accountId, date: source.date,
                                rawDescription: description,
                                amountMinorUnits: otherSideAmount(source.amountMinorUnits, from: sourceAccount.currency, to: target.currency, rate: rate),
                                categoryId: source.categoryId, status: source.categoryId == nil ? .pendingReview : .confirmed,
                                categorizedBy: source.categoryId == nil ? .none : .manual,
                                fingerprint: "manual-\(UUID().uuidString)", isManual: true)
        try other.insert(db)
        var link = TransferLink(outTransactionId: isIncoming ? sourceId : other.id!, inTransactionId: isIncoming ? other.id! : sourceId, origin: .manual)
        try link.insert(db)
        return other
    }

    /// The other side's signed amount: the opposite sign, converted at `rate` (EUR→GBP) across
    /// currencies, at least one minor unit.
    public static func otherSideAmount(_ amountMinorUnits: Int, from: Currency, to: Currency, rate: Double) -> Int {
        let converted = max(Int(TransferMatcher.convert(Double(abs(amountMinorUnits)), from: from, to: to, rate: rate).rounded()), 1)
        return amountMinorUnits < 0 ? converted : -converted
    }

    // MARK: Imports replacing manual entries (spec §3)

    /// For each row about to be imported into `accountId` (keyed by index), the manual entry it
    /// replaces: same amount and sign, dated within ±3 days; closest dates pair first, each
    /// manual entry at most once, none of `excluding` (already claimed by other staged rows)
    /// and never an adjustment (a built-in category's entry).
    public static func stagedReplacements(db: Database, accountId: Int64, staged: [(date: Date, amountMinorUnits: Int)],
                                          excluding: Set<Int64> = []) throws -> [Int: StagedManualReplacement] {
        // Update balance's adjustments (built-in categories) are never a bank row's stand-in.
        let builtInIds = Set(try Int64.fetchAll(db, sql: "SELECT id FROM category WHERE builtInRole IS NOT NULL"))
        let manual = try Transaction.filter(Column("accountId") == accountId && Column("isManual") == true).fetchAll(db)
            .filter { $0.id.map { !excluding.contains($0) } ?? false }
            .filter { $0.categoryId.map { !builtInIds.contains($0) } ?? true }
        guard !manual.isEmpty, !staged.isEmpty else { return [:] }
        let linkedIds = Set(try TransferLink.active.fetchAll(db).flatMap { [$0.outTransactionId, $0.inTransactionId] })
        var candidates: [(distance: TimeInterval, row: Int, manual: Int)] = []
        for (row, item) in staged.enumerated() where item.amountMinorUnits != 0 {
            for (index, entry) in manual.enumerated() where entry.amountMinorUnits == item.amountMinorUnits {
                let distance = abs(entry.date.timeIntervalSince(item.date))
                if distance <= replacementDayWindow { candidates.append((distance, row, index)) }
            }
        }
        candidates.sort { ($0.distance, $0.row, manual[$0.manual].id!) < ($1.distance, $1.row, manual[$1.manual].id!) }
        var result: [Int: StagedManualReplacement] = [:]
        var claimed = Set<Int>()
        for candidate in candidates where result[candidate.row] == nil && !claimed.contains(candidate.manual) {
            claimed.insert(candidate.manual)
            let entry = manual[candidate.manual]
            result[candidate.row] = StagedManualReplacement(transactionId: entry.id!, date: entry.date, categoryId: entry.categoryId,
                                                            note: entry.note, isLinked: linkedIds.contains(entry.id!))
        }
        return result
    }

    /// Finish import: the imported transaction takes over the manual entry — its transfer
    /// links are repointed to the imported one — then the manual entry is deleted. Skipped
    /// when the entry is gone or is no longer manual in that account.
    static func replace(db: Database, manualId: Int64, with importedId: Int64) throws {
        guard let entry = try Transaction.fetchOne(db, key: manualId), entry.isManual,
              let imported = try Transaction.fetchOne(db, key: importedId), entry.accountId == imported.accountId else { return }
        try db.execute(sql: "UPDATE transferLink SET outTransactionId = ? WHERE outTransactionId = ?", arguments: [importedId, manualId])
        try db.execute(sql: "UPDATE transferLink SET inTransactionId = ? WHERE inTransactionId = ?", arguments: [importedId, manualId])
        _ = try Transaction.deleteOne(db, key: manualId)
        try removeBrokenLinks(db: db, transaction: imported)
    }

    // MARK: Helpers

    /// The account's "Manual entries" batch, created on first use.
    static func batchId(db: Database, accountId: Int64) throws -> Int64 {
        if let existing = try ImportBatch
            .filter(Column("accountId") == accountId && Column("sourceFileName") == batchSourceFileName)
            .order(Column("id"))
            .fetchOne(db), let id = existing.id {
            return id
        }
        var batch = ImportBatch(accountId: accountId, sourceFileName: batchSourceFileName, importedAt: Date())
        try batch.insert(db)
        return batch.id!
    }

    /// The trimmed description, once the account, amount and category check out.
    private static func validate(db: Database, accountId: Int64, description: String, amountMinorUnits: Int, categoryId: Int64?, allowBuiltIn: Bool) throws -> String {
        guard try Account.fetchOne(db, key: accountId) != nil else { throw ManualTransactionError.accountNotFound }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ManualTransactionError.emptyDescription }
        guard amountMinorUnits != 0 else { throw ManualTransactionError.zeroAmount }
        if let categoryId {
            guard let category = try Category.fetchOne(db, key: categoryId) else { throw ManualTransactionError.categoryNotFound }
            guard category.isAssignable || (allowBuiltIn && category.isBuiltIn) else { throw ManualTransactionError.reservedCategory }
        }
        return trimmed
    }

    /// Removes the links involving `transaction` that no longer hold: the out leg sends money,
    /// the in leg receives it, from two different accounts.
    private static func removeBrokenLinks(db: Database, transaction: Transaction) throws {
        guard let id = transaction.id else { return }
        let links = try TransferLink.filter(Column("outTransactionId") == id || Column("inTransactionId") == id).fetchAll(db)
        for link in links {
            let otherId = link.outTransactionId == id ? link.inTransactionId : link.outTransactionId
            guard let other = try Transaction.fetchOne(db, key: otherId) else { continue }
            let (out, inLeg) = link.outTransactionId == id ? (transaction, other) : (other, transaction)
            if out.amountMinorUnits >= 0 || inLeg.amountMinorUnits <= 0 || out.accountId == inLeg.accountId {
                try link.delete(db)
            }
        }
    }
}
