import GRDB

/// Where the Dashboard, Budget grid and Forecast get the actuals they total from. Today that
/// is every transaction in the local database. In build step 5, private accounts below
/// "Everything" contribute summary rows here instead of their transactions (sync spec §6.1,
/// "How totals count"), so the screens need no change when that arrives.
public protocol ActualsSource {
    func transactions(_ db: Database) throws -> [Transaction]
}

/// All local transactions: the same set the screens read before the seam existed.
public struct LocalActualsSource: ActualsSource {
    public init() {}

    public func transactions(_ db: Database) throws -> [Transaction] {
        try Transaction.fetchAll(db)
    }
}

extension ActualsSource where Self == LocalActualsSource {
    public static var local: LocalActualsSource { LocalActualsSource() }
}
