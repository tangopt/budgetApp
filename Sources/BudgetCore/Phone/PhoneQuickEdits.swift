import Foundation
import GRDB

/// A quick edit the phone can't make.
public enum QuickEditError: Error, Equatable, LocalizedError {
    /// Update balance on an account that takes its balance from statements.
    case notManual

    public var errorDescription: String? {
        switch self {
        case .notManual: return "This account is updated from statements. Import one on the Mac."
        }
    }
}

/// The iPhone's quick edits (step 7b spec §2.2): categorise and note a transaction, the quick-sort queue with its
/// Undo, and a manual account's balance. Every one writes through `DeviceWriter.writeCheckingFiledYears` with no
/// resolution: outside the actor's Edit areas it throws `AccessDenied`, on a filed return
/// `DeviceWriteRefusal.filedYear`, and either way writes nothing.
public enum PhoneQuickEdits {
    // MARK: Areas

    /// The area an edit of the transaction's category or note needs: Property for property money
    /// (`AccessAreaMap.isPropertyMoney`, the test the Mac's re-validation judges it by), else Budget & accounts.
    public static func area(forTransaction id: Int64, db: Database) throws -> AccessArea {
        guard let transaction = try Transaction.fetchOne(db, key: id) else { throw TransactionEditError.transactionNotFound }
        var row: [String: SyncValue] = ["accountId": .int(transaction.accountId)]
        if let categoryId = transaction.categoryId { row["categoryId"] = .int(categoryId) }
        return try AccessAreaMap.isPropertyMoney(row, db: db) ? .property : .budgetAndAccounts
    }

    /// Whether the actor may categorise or note the transaction (false with no actor, or when it can't be read).
    public static func canEditTransaction(_ id: Int64, writer: DeviceWriter, dbReader: any DatabaseReader) async -> Bool {
        guard let area = try? await dbReader.read({ db in try area(forTransaction: id, db: db) }) else { return false }
        return await writer.canEdit(area)
    }

    // MARK: Categorise and note

    /// The categorise sheet's Save: category and note together (`TransactionEditing.update`), in the transaction's
    /// area (`area(forTransaction:)`).
    public static func categorise(writer: DeviceWriter, transactionId: Int64, categoryId: Int64?, note: String?) async throws {
        let (area, edit) = try await writer.reader.read { db -> (AccessArea, String) in
            let area = try area(forTransaction: transactionId, db: db)
            let current = try Transaction.fetchOne(db, key: transactionId)?.categoryId
            guard let categoryId, categoryId != current else { return (area, "Edited by hand") }
            guard let category = try Category.fetchOne(db, key: categoryId) else { throw TransactionEditError.categoryNotFound }
            return (area, DeviceWriteCopy.categorisedToast(category.name))
        }
        try await writer.writeCheckingFiledYears(area, edit: edit, scope: .categorising([transactionId], as: categoryId)) { db in
            try TransactionEditing.update(db: db, id: transactionId, categoryId: categoryId, note: note)
        }
    }

    // MARK: Quick sort

    /// One card of the quick-sort queue.
    public struct QuickSortCard: Equatable, Identifiable, Sendable {
        /// The transaction's id.
        public let id: Int64
        public let description: String
        public let accountName: String
        public let date: Date
        /// In the account's currency, signed like `Transaction.amountMinorUnits`.
        public let amountMinorUnits: Int
        public let currency: Currency

        public init(id: Int64, description: String, accountName: String, date: Date, amountMinorUnits: Int, currency: Currency) {
            self.id = id
            self.description = description
            self.accountName = accountName
            self.date = date
            self.amountMinorUnits = amountMinorUnits
            self.currency = currency
        }
    }

    /// The quick-sort queue: the pay month's transactions with no category (the Uncategorized screen's, budget-facing),
    /// newest first; only on accounts the viewer sees in full, and only those whose area the actor can edit
    /// (`canEdit`, decided by the caller from `DeviceWriter.canEdit`).
    public static func quickSortQueue(db: Database, viewer: PhoneViewer, payMonth range: PayMonthReview.DayRange,
                                      canEdit: (AccessArea) -> Bool) throws -> [QuickSortCard] {
        let sharing = try viewer.resolve(db: db)
        let accounts = Dictionary(try Account.fetchAll(db).filter(sharing.seesInFull).compactMap { account in account.id.map { ($0, account) } },
                                  uniquingKeysWith: { first, _ in first })
        let found = try UncategorizedTransactions.request
            .filter(Column("categoryId") == nil && Column("date") >= range.start && Column("date") <= range.end)
            .order(Column("date").desc, Column("id").desc)
            .fetchAll(db)
        return try found.compactMap { transaction in
            guard let id = transaction.id, let account = accounts[transaction.accountId],
                  canEdit(try area(forTransaction: id, db: db)) else { return nil }
            return QuickSortCard(id: id, description: transaction.rawDescription, accountName: account.displayName, date: transaction.date,
                                 amountMinorUnits: transaction.amountMinorUnits, currency: account.currency)
        }
    }

    /// What a quick-sort pick changed, for its Undo: the transaction as it was before.
    public struct UndoToken: Equatable, Sendable {
        public let transactionId: Int64
        public let categoryId: Int64?
        public let note: String?
        public let status: TransactionStatus
        public let categorizedBy: CategorizedBy
    }

    /// A quick-sort category button: `categorise` with the card's note kept. Returns what Undo puts back.
    public static func pick(writer: DeviceWriter, card: QuickSortCard, categoryId: Int64) async throws -> UndoToken {
        let before = try await writer.reader.read { db in try Transaction.fetchOne(db, key: card.id) }
        guard let before else { throw TransactionEditError.transactionNotFound }
        try await categorise(writer: writer, transactionId: card.id, categoryId: categoryId, note: before.note)
        return UndoToken(transactionId: card.id, categoryId: before.categoryId, note: before.note, status: before.status,
                         categorizedBy: before.categorizedBy)
    }

    /// The Undo toast: the transaction back as `token` holds it, through the same guarded write (a year filed since
    /// the pick refuses it; so does Edit lost since).
    public static func undo(writer: DeviceWriter, token: UndoToken) async throws {
        let area = try await writer.reader.read { db in try area(forTransaction: token.transactionId, db: db) }
        let scope = FiledYearEditCheck.Scope.categorising([token.transactionId], as: token.categoryId)
        try await writer.writeCheckingFiledYears(area, edit: "Undo category", scope: scope) { db in
            guard var transaction = try Transaction.fetchOne(db, key: token.transactionId) else { throw TransactionEditError.transactionNotFound }
            transaction.categoryId = token.categoryId
            transaction.note = token.note
            transaction.status = token.status
            transaction.categorizedBy = token.categorizedBy
            try transaction.update(db)
        }
    }

    // MARK: Manual balance

    /// Update balance on a manual account (`BalanceUpdates.save`, in Budget & accounts): the difference becomes a
    /// Balance adjustment (Market movement for an investment) dated `asOf`. An account updated from statements
    /// throws `QuickEditError.notManual` and writes nothing.
    public static func updateManualBalance(writer: DeviceWriter, accountId: Int64, enteredMinorUnits: Int, asOf: Date,
                                           note: String?) async throws -> BalanceUpdates.Outcome {
        let categoryId = try await writer.reader.read { db -> Int64? in
            guard let account = try Account.fetchOne(db, key: accountId) else { throw AccountEditError.accountNotFound }
            guard account.trackingMode == .manual else { throw QuickEditError.notManual }
            return try BuiltInCategories.category(db: db, role: CategoryBuiltInRole.forAccount(kind: account.kind)).id
        }
        let outcomes = try await writer.writeCheckingFiledYears(.budgetAndAccounts, edit: "Update balance",
                                                                scope: .adding(date: asOf, categoryId: categoryId)) { db in
            try BalanceUpdates.save(db: db, entries: [BalanceUpdates.Entry(accountId: accountId, enteredMinorUnits: enteredMinorUnits, note: note)],
                                    asOf: asOf)
        }
        return outcomes[0]
    }

    /// Whether the account shows "Update balance": a manual account the viewer sees in full, and Edit on Budget &
    /// accounts (false with no actor, or when it can't be read).
    public static func canUpdateBalance(accountId: Int64, writer: DeviceWriter, dbReader: any DatabaseReader) async -> Bool {
        let viewer = writer.viewerNow()
        let eligible = (try? await dbReader.read { db -> Bool in
            guard let account = try Account.fetchOne(db, key: accountId), account.trackingMode == .manual else { return false }
            return try viewer.resolve(db: db).seesInFull(account)
        }) ?? false
        guard eligible else { return false }
        return await writer.canEdit(.budgetAndAccounts)
    }
}
