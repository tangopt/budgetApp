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

    public init(id: Int64? = nil, name: String, type: CategoryType, groupId: Int64? = nil, isCatchAll: Bool = false) {
        self.id = id
        self.name = name
        self.type = type
        self.groupId = groupId
        self.isCatchAll = isCatchAll
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "category"
}
