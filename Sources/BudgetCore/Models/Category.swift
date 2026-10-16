import GRDB

public enum CategoryType: String, Codable, CaseIterable, Sendable {
    case expense
    case transfer
    case income
    /// Built-in balance corrections (`CategoryBuiltInRole`): shown in their own Adjustments
    /// sections, never counted as income, expenses or transfers, never planned.
    case adjustment

    /// Income and expense: the types that count toward the budget's flows and the plan's
    /// net worth impact (transfers move money between the user's own accounts; adjustments
    /// correct balances).
    public var isFlow: Bool { self == .income || self == .expense }
}

/// The app's built-in categories (spec 2026-10-14 §1), one each, created by migration. They
/// hold Update balance's adjustment transactions and can't be renamed, moved, deleted or
/// picked by hand.
public enum CategoryBuiltInRole: String, Codable, CaseIterable, Sendable {
    /// A cash or credit account's balance corrected to what the bank says.
    case balanceAdjustment
    /// An investment account's change in value.
    case marketMovement

    public var defaultName: String {
        switch self {
        case .balanceAdjustment: return "Balance adjustment"
        case .marketMovement: return "Market movement"
        }
    }

    /// Market movement for investment accounts, Balance adjustment otherwise.
    public static func forAccount(kind: AccountKind) -> CategoryBuiltInRole {
        kind == .investment ? .marketMovement : .balanceAdjustment
    }
}

public struct Category: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var name: String
    public var type: CategoryType
    public var groupId: Int64?
    /// A forecast-only expense bucket for expected but uncategorised spending. It never
    /// holds transactions or rules (database triggers enforce this).
    public var isReserved: Bool
    /// The auto-forecast never creates, updates or deletes entries for this category
    /// (its spending is covered by a reserve, or its forecast is maintained by hand).
    public var excludeFromAutoForecast: Bool
    /// A transfer category for money to or from an account that's never imported (spec §6):
    /// its transactions are never matched as transfers, so both directions count.
    public var isExternalTransfer: Bool
    /// The SF Symbol the user chose for this category (`CategoryIcons`); nil shows the
    /// type's generic symbol.
    public var iconName: String?
    /// Set on the built-in adjustment categories only (type `.adjustment`).
    public var builtInRole: CategoryBuiltInRole?
    /// The account this transfer category is for (spec 2026-10-14 §4, `TransferCategories`):
    /// a linked transfer's leg is filed under the other account's category. At most one
    /// category per account; never on an external-transfer or built-in category.
    public var transferAccountId: Int64?
    /// Not stored: whether this transfer category's account (`transferAccountId`) is left out
    /// of net worth (`Account.includeInNetWorth` off). Money filed under it leaves or enters
    /// net worth, so the net-worth figures and the Budget's Totals count it like an external
    /// transfer. Set by `markingNetWorthExclusions(accounts:)` where the calculations' inputs
    /// are built (`DashboardInput`, `ComparisonData`, the Budget grid); false as loaded.
    public var isTiedToAccountOutsideNetWorth = false

    /// The stored columns (`isTiedToAccountOutsideNetWorth` is derived, never persisted).
    private enum CodingKeys: String, CodingKey {
        case id, name, type, groupId, isReserved, excludeFromAutoForecast, isExternalTransfer, iconName, builtInRole, transferAccountId
    }

    public init(id: Int64? = nil, name: String, type: CategoryType, groupId: Int64? = nil, isReserved: Bool = false, excludeFromAutoForecast: Bool = false, isExternalTransfer: Bool = false, iconName: String? = nil, builtInRole: CategoryBuiltInRole? = nil, transferAccountId: Int64? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.groupId = groupId
        self.isReserved = isReserved
        self.excludeFromAutoForecast = excludeFromAutoForecast
        self.isExternalTransfer = isExternalTransfer
        self.iconName = iconName
        self.builtInRole = builtInRole
        self.transferAccountId = transferAccountId
    }

    /// Whether transactions and rules may be filed into this category by hand (pickers,
    /// rules, suggestions). Built-in categories are filled only by the app.
    public var isAssignable: Bool { !isReserved && builtInRole == nil }

    public var isBuiltIn: Bool { builtInRole != nil }

    /// Whether the net-worth figures count this transfer category's money (money to or from
    /// outside net worth): an external transfer, or one tied to an account left out of net worth.
    public var movesMoneyOutsideNetWorth: Bool { isExternalTransfer || isTiedToAccountOutsideNetWorth }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "category"
}

extension Sequence where Element == Category {
    /// The categories with `isTiedToAccountOutsideNetWorth` set from `accounts`: on each
    /// transfer category tied to an account that doesn't count toward net worth, off elsewhere.
    public func markingNetWorthExclusions(accounts: [Account]) -> [Category] {
        let excluded = accounts.excludedFromNetWorthIds
        return map { category in
            var marked = category
            marked.isTiedToAccountOutsideNetWorth = category.type == .transfer && (category.transferAccountId.map(excluded.contains) ?? false)
            return marked
        }
    }
}

func registerCategoryIconMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addCategoryIconName") { db in
        try db.alter(table: "category") { t in
            t.add(column: "iconName", .text)
        }
    }
}

func registerCategoryBuiltInRoleMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addCategoryBuiltInRole") { db in
        try db.alter(table: "category") { t in
            t.add(column: "builtInRole", .text)
        }
        try db.create(index: "category_builtInRole", on: "category", columns: ["builtInRole"], unique: true, condition: Column("builtInRole") != nil)
        // Raw SQL, not `Category`: later migrations may add columns this one doesn't know.
        for role in CategoryBuiltInRole.allCases {
            // A category the user already named this way becomes the built-in one — unless it
            // is a reserve, is planned (forecast entries or moved occurrences) or holds a
            // linked transfer leg: then the built-in one gets a distinct name instead.
            let adoptable = try Int64.fetchOne(db, sql: """
                SELECT c.id FROM category c
                WHERE c.name = ? COLLATE NOCASE AND c.isReserved = 0
                  AND NOT EXISTS (SELECT 1 FROM forecastEntry WHERE categoryId = c.id)
                  AND NOT EXISTS (SELECT 1 FROM plannedOccurrenceException WHERE categoryId = c.id)
                  AND NOT EXISTS (SELECT 1 FROM transferLink l JOIN transaction_ t ON t.id IN (l.outTransactionId, l.inTransactionId) WHERE t.categoryId = c.id)
                """, arguments: [role.defaultName])
            if let id = adoptable {
                try db.execute(sql: "UPDATE category SET type = ?, builtInRole = ?, groupId = NULL, isExternalTransfer = 0 WHERE id = ?",
                               arguments: [CategoryType.adjustment.rawValue, role.rawValue, id])
                // Built-in categories are filled only by the app.
                try db.execute(sql: "DELETE FROM rule WHERE categoryId = ?", arguments: [id])
            } else {
                let taken = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM category WHERE name = ? COLLATE NOCASE", arguments: [role.defaultName]) ?? 0
                try db.execute(sql: "INSERT INTO category (name, type, builtInRole) VALUES (?, ?, ?)",
                               arguments: [taken == 0 ? role.defaultName : "\(role.defaultName) (built-in)", CategoryType.adjustment.rawValue, role.rawValue])
            }
        }
    }
}

/// Looks up the built-in categories (`CategoryBuiltInRole`).
public enum BuiltInCategories {
    public enum LookupError: Error, Equatable { case missing(CategoryBuiltInRole) }

    /// The category holding `role`; the migration creates both, so a missing one is an error.
    public static func category(db: Database, role: CategoryBuiltInRole) throws -> Category {
        guard let category = try Category.filter(Column("builtInRole") == role.rawValue).fetchOne(db) else {
            throw LookupError.missing(role)
        }
        return category
    }
}
