import GRDB

public enum CategoryType: String, Codable, CaseIterable {
    case expense
    case transfer
    case income
}

public struct Category: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var name: String
    public var type: CategoryType
    public var groupId: Int64?
    /// The one expense category that stands in for unplanned, never-itemised spending: its
    /// monthly allowance stays in the forecast and the auto-forecast never changes it.
    public var isCatchAll: Bool
    /// A forecast-only expense bucket for expected but uncategorised spending. It never
    /// holds transactions or rules (database triggers enforce this).
    public var isReserved: Bool
    /// The auto-forecast never creates, updates or deletes entries for this category
    /// (its spending is covered by a reserve, or its forecast is maintained by hand).
    public var excludeFromAutoForecast: Bool

    public init(id: Int64? = nil, name: String, type: CategoryType, groupId: Int64? = nil, isCatchAll: Bool = false, isReserved: Bool = false, excludeFromAutoForecast: Bool = false) {
        self.id = id
        self.name = name
        self.type = type
        self.groupId = groupId
        self.isCatchAll = isCatchAll
        self.isReserved = isReserved
        self.excludeFromAutoForecast = excludeFromAutoForecast
    }

    /// Whether transactions and rules may be filed into this category.
    public var isAssignable: Bool { !isReserved }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "category"
}
