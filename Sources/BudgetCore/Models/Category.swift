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

    public init(id: Int64? = nil, name: String, type: CategoryType) {
        self.id = id
        self.name = name
        self.type = type
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "category"
}
