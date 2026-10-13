import GRDB

public enum CategoryType: String, Codable, CaseIterable, Sendable {
    case expense
    case transfer
    case income
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

    public init(id: Int64? = nil, name: String, type: CategoryType, groupId: Int64? = nil, isReserved: Bool = false, excludeFromAutoForecast: Bool = false, isExternalTransfer: Bool = false, iconName: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.groupId = groupId
        self.isReserved = isReserved
        self.excludeFromAutoForecast = excludeFromAutoForecast
        self.isExternalTransfer = isExternalTransfer
        self.iconName = iconName
    }

    /// Whether transactions and rules may be filed into this category.
    public var isAssignable: Bool { !isReserved }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "category"
}

func registerCategoryIconMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addCategoryIconName") { db in
        try db.alter(table: "category") { t in
            t.add(column: "iconName", .text)
        }
    }
}
