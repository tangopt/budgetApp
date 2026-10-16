import Foundation
import GRDB

public enum TransactionEditError: Error, Equatable, LocalizedError {
    case transactionNotFound
    case categoryNotFound
    /// Reserves are forecast-only and never hold transactions.
    case reservedCategory
    /// Balance adjustment and Market movement are only ever set by the Accounts screen.
    case builtInCategory

    public var errorDescription: String? {
        switch self {
        case .transactionNotFound: return "That transaction no longer exists."
        case .categoryNotFound: return "That category no longer exists."
        case .reservedCategory: return "Reserved categories can't hold transactions."
        case .builtInCategory: return "Balance adjustments and market movements are recorded from the Accounts screen, not chosen as a category."
        }
    }
}

/// The Edit transaction sheet's save (spec §5). It never learns a rule.
public enum TransactionEditing {
    /// Sets the category and note. A changed category makes the transaction confirmed and
    /// manual, or sends it back to review (`pendingReview`, `.none`) when cleared; an
    /// unchanged one keeps its status and `categorizedBy`. The note is trimmed; blank clears it.
    public static func update(db: Database, id: Int64, categoryId: Int64?, note: String?) throws {
        guard var transaction = try Transaction.fetchOne(db, key: id) else { throw TransactionEditError.transactionNotFound }
        if categoryId == transaction.categoryId {
            // A note-only edit: how it was categorised stays as it was.
        } else if let categoryId {
            guard let category = try Category.fetchOne(db, key: categoryId) else { throw TransactionEditError.categoryNotFound }
            guard !category.isBuiltIn else { throw TransactionEditError.builtInCategory }
            guard category.isAssignable else { throw TransactionEditError.reservedCategory }
            transaction.status = .confirmed
            transaction.categorizedBy = .manual
        } else {
            transaction.status = .pendingReview
            transaction.categorizedBy = .none
        }
        transaction.categoryId = categoryId
        transaction.note = Transaction.normalizedNote(note)
        try transaction.update(db)
    }
}

/// What Search's Set category… changed.
public struct SetCategoryResult: Equatable, Sendable {
    /// Transactions given the category.
    public let updatedCount: Int
    /// Transactions left alone because they're a balance adjustment or market movement
    /// (a built-in category, set only by the Accounts screen).
    public let skippedBuiltInCount: Int

    public init(updatedCount: Int, skippedBuiltInCount: Int) {
        self.updatedCount = updatedCount
        self.skippedBuiltInCount = skippedBuiltInCount
    }
}

extension TransactionEditing {
    /// Search's Set category… (spec 2026-10-15): each transaction gets `categoryId`, confirmed
    /// and manual, its note kept. Rows in a built-in category (balance adjustments, market
    /// movements) are skipped and counted. With `remember`, a rule is learned from each
    /// description (`RuleLearner.learn`, as on Uncategorized) — never from a leg of an active
    /// transfer link, whose description names the transfer, not a merchant. Call inside one
    /// write: a missing transaction or category, a reserve or a built-in target throws and
    /// rolls everything back.
    @discardableResult
    public static func setCategory(db: Database, ids: [Int64], categoryId: Int64, remember: Bool) throws -> SetCategoryResult {
        guard let category = try Category.fetchOne(db, key: categoryId) else { throw TransactionEditError.categoryNotFound }
        guard !category.isBuiltIn else { throw TransactionEditError.builtInCategory }
        guard category.isAssignable else { throw TransactionEditError.reservedCategory }
        let builtInIds = Set(try Category.fetchAll(db).filter(\.isBuiltIn).compactMap(\.id))
        let linkedIds = Set(try TransferLink.active.fetchAll(db).flatMap { [$0.outTransactionId, $0.inTransactionId] })
        var updated = 0
        var skipped = 0
        for id in ids {
            guard var transaction = try Transaction.fetchOne(db, key: id) else { throw TransactionEditError.transactionNotFound }
            if let current = transaction.categoryId, builtInIds.contains(current) {
                skipped += 1
                continue
            }
            transaction.categoryId = categoryId
            transaction.status = .confirmed
            transaction.categorizedBy = .manual
            try transaction.update(db)
            updated += 1
            if remember, !linkedIds.contains(id) {
                try RuleLearner.learn(description: transaction.rawDescription, categoryId: categoryId, db: db)
            }
        }
        return SetCategoryResult(updatedCount: updated, skippedBuiltInCount: skipped)
    }
}

/// A transfer change Edit transaction holds until Save (at most one at a time).
public enum PendingTransferChange: Equatable, Sendable {
    /// Add the other side… in `accountId` (`ManualTransactions.addOtherSide`).
    case addOtherSide(accountId: Int64)
    /// Unlink (`TransferLinks.unlink`) — each link must involve the transaction.
    case unlink(linkIds: [Int64])
    /// Link to transfer… with `transactionId` (`TransferLinks.link`).
    case link(transactionId: Int64)
}

/// Everything Edit transaction's Save writes.
public struct TransactionEditChanges: Equatable, Sendable {
    /// A manual transaction's account, date (the stored UTC day), description and signed amount.
    public struct ManualFields: Equatable, Sendable {
        public var accountId: Int64
        public var date: Date
        public var description: String
        public var amountMinorUnits: Int

        public init(accountId: Int64, date: Date, description: String, amountMinorUnits: Int) {
            self.accountId = accountId
            self.date = date
            self.description = description
            self.amountMinorUnits = amountMinorUnits
        }
    }

    public var categoryId: Int64?
    public var note: String?
    /// Only for a transaction added by hand (`ManualTransactions.update`); nil = category and note only.
    public var manual: ManualFields?
    public var transfer: PendingTransferChange?
    /// Documents linked and unlinked in the sheet (spec 2026-10-16 §2), applied last.
    public var documents: EvidenceLinkChanges

    public init(categoryId: Int64?, note: String?, manual: ManualFields? = nil, transfer: PendingTransferChange? = nil,
                documents: EvidenceLinkChanges = EvidenceLinkChanges()) {
        self.categoryId = categoryId
        self.note = note
        self.manual = manual
        self.transfer = transfer
        self.documents = documents
    }
}

extension TransactionEditing {
    /// Edit transaction's Save: the fields first (`ManualTransactions.update` for manual
    /// fields, else `update`), then the pending transfer change — so Add the other side… sees
    /// the saved category — then the staged document links and unlinks. Call inside one write: any refusal throws and rolls everything back.
    public static func save(db: Database, id: Int64, changes: TransactionEditChanges) throws {
        if let manual = changes.manual {
            try ManualTransactions.update(db: db, id: id, date: manual.date, description: manual.description,
                                          amountMinorUnits: manual.amountMinorUnits, accountId: manual.accountId,
                                          categoryId: changes.categoryId, note: changes.note)
        } else {
            try update(db: db, id: id, categoryId: changes.categoryId, note: changes.note)
        }
        switch changes.transfer {
        case nil:
            break
        case .addOtherSide(let accountId):
            _ = try ManualTransactions.addOtherSide(db: db, transactionId: id, accountId: accountId)
        case .unlink(let linkIds):
            for linkId in linkIds {
                guard let link = try TransferLink.fetchOne(db, key: linkId),
                      link.outTransactionId == id || link.inTransactionId == id else { throw TransferLinkError.linkNotFound }
                try TransferLinks.unlink(db: db, linkId: linkId)
            }
        case .link(let otherId):
            _ = try TransferLinks.link(db: db, transactionId: id, with: otherId)
        }
        try changes.documents.apply(db: db, to: .transaction(id))
    }
}
