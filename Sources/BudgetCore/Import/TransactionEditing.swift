import Foundation
import GRDB

public enum TransactionEditError: Error, Equatable, LocalizedError {
    case transactionNotFound
    case categoryNotFound
    /// Reserves are forecast-only and never hold transactions.
    case reservedCategory

    public var errorDescription: String? {
        switch self {
        case .transactionNotFound: return "That transaction no longer exists."
        case .categoryNotFound: return "That category no longer exists."
        case .reservedCategory: return "Reserved categories can't hold transactions."
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
