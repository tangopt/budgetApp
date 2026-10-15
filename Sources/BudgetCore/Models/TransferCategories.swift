import Foundation
import GRDB

public enum TransferCategoryError: Error, Equatable, LocalizedError {
    case categoryNotFound
    case accountNotFound
    /// Only (non-built-in, non-reserve) transfer categories can be linked to an account.
    case notATransferCategory
    /// External-transfer categories are for accounts the user doesn't import.
    case externalCategory
    /// A category linked to an account can't become an external-transfer one.
    case linkedCategory
    /// The account already has a transfer category.
    case accountAlreadyLinked(categoryName: String)
    /// `tie`: no category has this exact name.
    case noCategoryNamed(String)
    /// `tie`: no account has this exact name or alias.
    case noAccountNamed(String)

    public var errorDescription: String? {
        switch self {
        case .categoryNotFound: return "That category no longer exists."
        case .accountNotFound: return "That account no longer exists."
        case .notATransferCategory: return "Only transfer categories can be linked to an account."
        case .externalCategory: return "This category is for an account you don't import — it can't be linked to one of yours."
        case .linkedCategory: return "This category is linked to one of your accounts — set its linked account to None first."
        case .accountAlreadyLinked(let name): return "That account is already linked to “\(name)”."
        case .noCategoryNamed(let name): return "No category named “\(name)”."
        case .noAccountNamed(let name): return "No account named or aliased “\(name)”."
        }
    }
}

/// Transfer categories per account (spec 2026-10-14 §4). Each account has one transfer category
/// ("Transfer: <displayName>", `Category.transferAccountId`), and a linked transfer's legs are
/// filed under the *other* account's: money sent from Current to Joint is "Transfer: Joint" in
/// Current and "Transfer: Current" in Joint. External-transfer and built-in categories are
/// never tied, and a leg filed under one keeps it.
public enum TransferCategories {
    /// The name an account's transfer category should have.
    public static func name(for account: Account) -> String {
        "Transfer: \(account.displayName)"
    }

    /// The account's transfer category, if it has one.
    public static func category(db: Database, forAccountId accountId: Int64) throws -> Category? {
        try Category.filter(Column("transferAccountId") == accountId).fetchOne(db)
    }

    /// Every tied category id by its account id.
    public static func categoryIdsByAccount(db: Database) throws -> [Int64: Int64] {
        let rows = try Row.fetchAll(db, sql: "SELECT transferAccountId, id FROM category WHERE transferAccountId IS NOT NULL")
        return Dictionary(rows.map { ($0["transferAccountId"] as Int64, $0["id"] as Int64) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Ensure

    /// The group most tied transfer categories sit in (e.g. "Own accounts"), so a new account's
    /// category joins its siblings; nil when none are grouped.
    private static func sharedGroupId(db: Database) throws -> Int64? {
        try Int64.fetchOne(db, sql: """
            SELECT groupId FROM category
            WHERE transferAccountId IS NOT NULL AND groupId IS NOT NULL
            GROUP BY groupId ORDER BY COUNT(*) DESC, groupId LIMIT 1
            """)
    }

    /// Gives every account a transfer category and keeps their names current. An account
    /// without one ties an untied, non-external transfer category named "Transfer: <displayName>"
    /// when there is one, or gets a new one (" (<account name>)" appended when that name is
    /// taken by any other category), in the group most tied categories use. A tied category whose name isn't "Transfer: <displayName>"
    /// is renamed when that name is free. Idempotent. Runs at launch (before transfer matching)
    /// and after an account is added, renamed or re-aliased (`AccountEditing`). Returns what it
    /// did, one line each (for the conversion tool).
    @discardableResult
    public static func ensure(db: Database) throws -> [String] {
        var log: [String] = []
        for account in try Account.order(Column("id")).fetchAll(db) {
            guard let accountId = account.id else { continue }
            let target = name(for: account)
            if var tied = try category(db: db, forAccountId: accountId) {
                if tied.name != target, try isNameFree(db: db, target, excluding: tied.id) {
                    log.append("Renamed “\(tied.name)” → “\(target)” (\(account.name))")
                    tied.name = target
                    try tied.update(db, columns: ["name"])
                }
                continue
            }
            var candidate = target
            var attempt = 1
            while true {
                if let existing = try categoryNamed(db: db, candidate) {
                    if isTieable(existing), let id = existing.id {
                        try db.execute(sql: "UPDATE category SET transferAccountId = ? WHERE id = ?", arguments: [accountId, id])
                        log.append("Tied “\(existing.name)” to \(account.name)")
                        break
                    }
                    attempt += 1
                    candidate = attempt == 2 ? "\(target) (\(account.name))" : "\(target) (\(account.name)) \(attempt - 1)"
                } else {
                    var created = Category(name: candidate, type: .transfer, groupId: try sharedGroupId(db: db), transferAccountId: accountId)
                    try created.insert(db)
                    log.append("Created “\(candidate)” for \(account.name)")
                    break
                }
            }
        }
        return log
    }

    /// Categories screen → Linked account: ties the transfer category to `accountId` (renaming
    /// it "Transfer: <displayName>" when that name is free), or unties it (nil; its name stays).
    public static func setLinkedAccount(db: Database, categoryId: Int64, accountId: Int64?) throws {
        guard var category = try Category.fetchOne(db, key: categoryId) else { throw TransferCategoryError.categoryNotFound }
        guard category.type == .transfer, !category.isBuiltIn, !category.isReserved else { throw TransferCategoryError.notATransferCategory }
        guard let accountId else {
            category.transferAccountId = nil
            try category.update(db, columns: ["transferAccountId"])
            return
        }
        guard !category.isExternalTransfer else { throw TransferCategoryError.externalCategory }
        guard let account = try Account.fetchOne(db, key: accountId) else { throw TransferCategoryError.accountNotFound }
        if let other = try self.category(db: db, forAccountId: accountId), other.id != categoryId {
            throw TransferCategoryError.accountAlreadyLinked(categoryName: other.name)
        }
        category.transferAccountId = accountId
        let target = name(for: account)
        if category.name != target, try isNameFree(db: db, target, excluding: categoryId) {
            category.name = target
        }
        try category.update(db, columns: ["name", "transferAccountId"])
    }

    /// The conversion tool's `--tie`: ties the category named exactly `categoryName` to the
    /// account named or aliased exactly `accountNameOrAlias` (`setLinkedAccount`, renaming it
    /// when the name is free). The account's previous category is untied, and deleted only when
    /// nothing uses it — no transaction, forecast entry, moved planned occurrence or rule.
    /// Returns what it did, one line each. Re-running with the same names is a no-op: a
    /// category already renamed by an earlier tie isn't found, and the account is tied — that's
    /// logged, not thrown.
    @discardableResult
    public static func tie(db: Database, categoryName: String, accountNameOrAlias: String) throws -> [String] {
        guard let account = try Account.fetchAll(db).first(where: { $0.name == accountNameOrAlias || $0.alias == accountNameOrAlias }),
              let accountId = account.id else {
            throw TransferCategoryError.noAccountNamed(accountNameOrAlias)
        }
        guard let category = try Category.filter(Column("name") == categoryName).fetchOne(db), let categoryId = category.id else {
            if let tied = try self.category(db: db, forAccountId: accountId) {
                return ["“\(categoryName)” not found; \(account.name) already tied to “\(tied.name)”"]
            }
            throw TransferCategoryError.noCategoryNamed(categoryName)
        }
        var log: [String] = []
        if let previous = try self.category(db: db, forAccountId: accountId), let previousId = previous.id, previousId != categoryId {
            try setLinkedAccount(db: db, categoryId: previousId, accountId: nil)
            let uses = try Int.fetchOne(db, sql: """
                SELECT (SELECT COUNT(*) FROM transaction_ WHERE categoryId = ?)
                     + (SELECT COUNT(*) FROM forecastEntry WHERE categoryId = ?)
                     + (SELECT COUNT(*) FROM plannedOccurrenceException WHERE categoryId = ?)
                     + (SELECT COUNT(*) FROM rule WHERE categoryId = ?)
                """, arguments: [previousId, previousId, previousId, previousId]) ?? 0
            if uses == 0 {
                _ = try Category.deleteOne(db, key: previousId)
                log.append("Deleted the unused “\(previous.name)” (was tied to \(account.name))")
            } else {
                log.append("Untied “\(previous.name)” from \(account.name) (in use, kept)")
            }
        }
        try setLinkedAccount(db: db, categoryId: categoryId, accountId: accountId)
        let tiedName = try Category.fetchOne(db, key: categoryId)?.name ?? categoryName
        log.append("Tied “\(categoryName)” to \(account.name)\(tiedName == categoryName ? "" : ", renamed “\(tiedName)”")")
        return log
    }

    // MARK: Apply on link

    /// One leg moved to another category.
    struct Change {
        let transactionId: Int64
        let fromCategoryId: Int64?
        let toCategoryId: Int64
    }

    /// A pair was just linked (auto match, Link to transfer…, Add the other side…): the out
    /// leg goes to the receiving account's transfer category, the in leg to the sending
    /// account's — confirmed, `categorizedBy` `.transfer`. Only an uncategorised leg or one in a
    /// (non-external) transfer category is re-filed: an income or expense leg, an
    /// external-transfer or built-in one, or one whose partner's account has no tied category
    /// is left alone; so is a historical out leg linked to money received in more than one account.
    public static func applyOnLink(db: Database, outTransactionId: Int64, inTransactionId: Int64) throws {
        guard let out = try Transaction.fetchOne(db, key: outTransactionId),
              let inLeg = try Transaction.fetchOne(db, key: inTransactionId) else { return }
        let byAccount = try categoryIdsByAccount(db: db)
        guard !byAccount.isEmpty else { return }
        let protected = try protectedCategoryIds(db: db)
        let inAccounts = try Int64.fetchAll(db, sql: """
            SELECT DISTINCT t.accountId FROM transferLink l JOIN transaction_ t ON t.id = l.inTransactionId
            WHERE l.isDismissed = 0 AND l.outTransactionId = ?
            """, arguments: [outTransactionId])
        if inAccounts.count <= 1 {
            _ = try apply(db: db, out, to: byAccount[inLeg.accountId], protected: protected)
        }
        _ = try apply(db: db, inLeg, to: byAccount[out.accountId], protected: protected)
    }

    /// Files `transaction` under `categoryId` (confirmed, `.transfer`) unless it's protected or
    /// already there; returns the change when its category changed.
    private static func apply(db: Database, _ transaction: Transaction, to categoryId: Int64?, protected: Set<Int64>) throws -> Change? {
        guard let categoryId, let id = transaction.id else { return nil }
        if let current = transaction.categoryId, protected.contains(current) { return nil }
        var updated = transaction
        if transaction.categoryId == categoryId {
            guard transaction.status != .confirmed else { return nil }
            updated.status = .confirmed
            try updated.update(db, columns: ["status"])
            return nil
        }
        updated.categoryId = categoryId
        updated.status = .confirmed
        updated.categorizedBy = .transfer
        try updated.update(db, columns: ["categoryId", "status", "categorizedBy"])
        return Change(transactionId: id, fromCategoryId: transaction.categoryId, toCategoryId: categoryId)
    }

    /// Every category a leg keeps: income, expense and built-in ones, and external transfers.
    private static func protectedCategoryIds(db: Database) throws -> Set<Int64> {
        Set(try Int64.fetchAll(db, sql: "SELECT id FROM category WHERE type <> ? OR isExternalTransfer = 1 OR builtInRole IS NOT NULL",
                               arguments: [CategoryType.transfer.rawValue]))
    }

    // MARK: Existing links (one-off data step)

    /// Legs moved from one category to another, by name ("Uncategorised" when nil).
    public struct Move: Hashable, Sendable {
        public let fromCategory: String?
        public let toCategory: String
        public let count: Int

        public init(fromCategory: String?, toCategory: String, count: Int) {
            self.fromCategory = fromCategory
            self.toCategory = toCategory
            self.count = count
        }
    }

    public struct Report: Equatable, Sendable {
        /// Most legs first.
        public let moves: [Move]
        public let changedTransactionIds: [Int64]

        public var text: String {
            guard !moves.isEmpty else { return "Transfer categories: no linked leg to move." }
            var lines = ["Transfer categories: \(changedTransactionIds.count) leg\(changedTransactionIds.count == 1 ? "" : "s") moved"]
            for move in moves {
                lines.append("  \(move.count) leg\(move.count == 1 ? "" : "s") moved from \(move.fromCategory ?? "Uncategorised") → \(move.toCategory)")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Applies the on-link rule to every active link already saved (not run automatically —
    /// the conversion tool's `--apply-transfer-categories`). Idempotent.
    public static func applyToExistingLinks(db: Database) throws -> Report {
        let byAccount = try categoryIdsByAccount(db: db)
        let links = try TransferLink.active.fetchAll(db)
        guard !byAccount.isEmpty, !links.isEmpty else { return Report(moves: [], changedTransactionIds: []) }
        let ids = Set(links.flatMap { [$0.outTransactionId, $0.inTransactionId] })
        let transactions = Dictionary(try Transaction.filter(ids.contains(Column("id"))).fetchAll(db).compactMap { t in t.id.map { ($0, t) } },
                                      uniquingKeysWith: { a, _ in a })
        // Each leg's target; an out leg linked into several accounts has none (nil).
        var targets: [Int64: Int64?] = [:]
        for link in links {
            guard let out = transactions[link.outTransactionId], let inLeg = transactions[link.inTransactionId] else { continue }
            let outTarget = byAccount[inLeg.accountId]
            if let existing = targets[link.outTransactionId], existing != outTarget {
                targets[link.outTransactionId] = .some(nil)
            } else {
                targets[link.outTransactionId] = outTarget
            }
            targets[link.inTransactionId] = byAccount[out.accountId]
        }
        let protected = try protectedCategoryIds(db: db)
        var changes: [Change] = []
        for (id, target) in targets.sorted(by: { $0.key < $1.key }) {
            guard let transaction = transactions[id], let change = try apply(db: db, transaction, to: target, protected: protected) else { continue }
            changes.append(change)
        }
        let names = Dictionary(try Category.fetchAll(db).compactMap { c in c.id.map { ($0, c.name) } }, uniquingKeysWith: { a, _ in a })
        var counts: [Pair: Int] = [:]
        for change in changes {
            counts[Pair(from: change.fromCategoryId.flatMap { names[$0] }, to: names[change.toCategoryId] ?? "#\(change.toCategoryId)"), default: 0] += 1
        }
        let moves = counts.map { Move(fromCategory: $0.key.from, toCategory: $0.key.to, count: $0.value) }
            .sorted { ($1.count, $0.toCategory, $0.fromCategory ?? "") < ($0.count, $1.toCategory, $1.fromCategory ?? "") }
        return Report(moves: moves, changedTransactionIds: changes.map(\.transactionId))
    }

    private struct Pair: Hashable {
        let from: String?
        let to: String
    }

    // MARK: Helpers

    private static func isTieable(_ category: Category) -> Bool {
        category.type == .transfer && !category.isExternalTransfer && !category.isBuiltIn && !category.isReserved && category.transferAccountId == nil
    }

    private static func categoryNamed(db: Database, _ name: String) throws -> Category? {
        try Category.fetchAll(db).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// No other category has `name` (ignoring case, as `Categories` requires).
    private static func isNameFree(db: Database, _ name: String, excluding id: Int64?) throws -> Bool {
        try !Category.fetchAll(db).contains { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

func registerCategoryTransferAccountMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addCategoryTransferAccountId") { db in
        try db.alter(table: "category") { t in
            t.add(column: "transferAccountId", .integer).references("account", onDelete: .setNull)
        }
        try db.execute(sql: "CREATE UNIQUE INDEX category_transferAccountId ON category(transferAccountId) WHERE transferAccountId IS NOT NULL")
        // Ties existing transfer categories (not external, not built-in, not reserves) named
        // exactly "Transfer: <account name>" or "Transfer: <alias>" — the name first; one per
        // account and one account per category. Never creates categories (`TransferCategories.ensure` does).
        let accounts = try Row.fetchAll(db, sql: "SELECT id, name, alias FROM account ORDER BY id")
        for account in accounts {
            let id: Int64 = account["id"]
            let name: String = account["name"]
            let alias = (account["alias"] as String?)?.trimmingCharacters(in: .whitespacesAndNewlines)
            for candidate in [name, alias].compactMap({ $0 }).filter({ !$0.isEmpty }) {
                let categoryId = try Int64.fetchOne(db, sql: """
                    SELECT id FROM category
                    WHERE name = ? AND type = ? AND isExternalTransfer = 0 AND builtInRole IS NULL AND isReserved = 0
                      AND transferAccountId IS NULL
                    """, arguments: ["Transfer: \(candidate)", CategoryType.transfer.rawValue])
                if let categoryId {
                    try db.execute(sql: "UPDATE category SET transferAccountId = ? WHERE id = ?", arguments: [id, categoryId])
                    break
                }
            }
        }
    }
}
