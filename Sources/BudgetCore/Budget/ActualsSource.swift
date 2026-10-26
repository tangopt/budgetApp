import Foundation
import GRDB

/// Where the Dashboard, Budget grid and Forecast get the actuals they total from, and the balance snapshots net
/// worth starts from. `LocalActualsSource` is every row in the local database; `SharedActualsSource` replaces the
/// accounts the viewer can't see in full with their summaries (sync spec §6.1, "How totals count"), so the screens
/// need no change.
public protocol ActualsSource {
    func transactions(_ db: Database) throws -> [Transaction]
    func balanceSnapshots(_ db: Database) throws -> [BalanceSnapshot]
    /// Pay-month closes published by the other person's devices for accounts this device doesn't hold in full,
    /// for the pay calendar (`PayCalendar.forData(publishedCloses:)`): the reader's pay months follow the owner's.
    func publishedCloses(_ db: Database) throws -> [Date]
    /// The accounts the screens list: every one, or (`SharedActualsSource`) all but the other person's Hidden ones.
    func accounts(_ db: Database) throws -> [Account]
}

extension ActualsSource {
    public func balanceSnapshots(_ db: Database) throws -> [BalanceSnapshot] {
        try BalanceSnapshot.fetchAll(db)
    }

    public func publishedCloses(_ db: Database) throws -> [Date] { [] }

    public func accounts(_ db: Database) throws -> [Account] {
        try Account.fetchAll(db)
    }
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
